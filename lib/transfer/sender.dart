import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter_contacts/flutter_contacts.dart';

import 'native.dart';
import 'protocol.dart';

enum SendPhase { idle, checking, sending, retrying, done, cancelled, error }

enum DlqStatus { waiting, retrying, recovered, failed }

/// A file that timed out or failed. It is retried after all other files are done.
class DlqItem {
  final FileEntry file;
  int attempts = 1;
  String lastError;
  DlqStatus status = DlqStatus.waiting;

  DlqItem(this.file, this.lastError);

  Map<String, dynamic> toJson() =>
      {'rel': file.rel, 'size': file.size, 'error': lastError, 'attempts': attempts, 'status': status.name};
}

class RecentFile {
  final String rel;
  final int size;
  final bool alreadyThere;
  const RecentFile(this.rel, this.size, this.alreadyThere);
}

/// What one parallel lane is sending right now.
class LaneView {
  String rel;
  int bytes;
  int total;
  int resumedFrom;
  final bool batch;
  int batchIndex;
  final int batchCount;

  LaneView(this.rel, this.bytes, this.total,
      {this.resumedFrom = 0, this.batch = false, this.batchIndex = 0, this.batchCount = 0});
}

class SendPlan {
  final List<FileEntry> files;
  final List<Contact> contacts;
  const SendPlan(this.files, this.contacts);
}

class CategoryTally {
  int selected = 0; // chosen by the user
  int sent = 0; // copied and checksum-verified on the new phone
  int already = 0; // identical file already on the new phone, skipped
  int failed = 0; // still failing after every retry
}

// ---- internal signals ----
class _PauseSignal implements Exception {}

class _CancelSignal implements Exception {}

/// The new phone had a different number of bytes than expected: re-check and continue.
class _RetryNow implements Exception {}

class _Stall implements Exception {
  final Duration after;
  _Stall(this.after);
  @override
  String toString() => 'Timed out: no progress for ${after.inSeconds} s';
}

/// The new phone answered with an error.
class _Rejected implements Exception {
  final String reason;
  _Rejected(this.reason);
  @override
  String toString() => 'New phone refused the file: $reason';
}

/// A problem with this particular file. It goes to the retry queue.
class _FileFailure implements Exception {
  final String message;
  _FileFailure(this.message);
}

/// One request in flight, so Pause / Stop / the stall watchdog can abort it.
class _Inflight {
  final HttpClientRequest req;
  DateTime lastProgress = DateTime.now();
  Object? abortReason;
  _Inflight(this.req);

  void abort(Object reason) {
    if (abortReason != null) return;
    abortReason = reason;
    req.abort(reason);
  }
}

/// A unit of work for a lane: one large file, or a batch of small ones.
class _Work {
  final FileEntry? file;
  final List<FileEntry>? batch;
  const _Work.file(FileEntry this.file) : batch = null;
  const _Work.batch(List<FileEntry> this.batch) : file = null;
}

/// Runs on the OLD phone. It only ever READS from this phone: there is no code
/// here that deletes, moves or edits anything on it.
///
/// v4 speed-ups (used when the new phone also runs v4):
/// * several lanes at once (2–6, adjusted automatically), lane 1 for large files
/// * small files sent many-per-request
/// * checksums computed in background isolates
/// * identical content sent once and copied on the new phone
/// With a v3 phone it falls back to v3 behaviour (one file at a time).
class SenderService extends ChangeNotifier {
  // ---- tunables (tests use smaller values) ----
  /// A file with no progress for this long is skipped and queued for retry.
  Duration stallTimeout = const Duration(seconds: 20);

  /// Total tries per file, including the first one.
  int maxAttempts = 5;

  /// Wait before each retry round (exponential backoff, ±20% jitter).
  List<Duration> retryDelays = const [
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 40),
  ];

  /// Parallel lanes: starts at [startLanes], adapts between [minLanes] and [maxLanes].
  int minLanes = 2;
  int startLanes = 3;
  int maxLanes = 6;

  @visibleForTesting
  void Function(SenderService sender, FileEntry file, int fileBytes)? debugOnChunk;

  /// Test hook: stop like a phone whose battery died (no goodbye to the new phone).
  @visibleForTesting
  bool debugSkipDone = false;

  final PairingInfo pairing;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..idleTimeout = const Duration(seconds: 30)
    ..maxConnectionsPerHost = 12;
  final Random _random = Random();

  SenderService(this.pairing);

  /// Protocol the new phone speaks (set by [ping]). Below 4 = v3 mode.
  int receiverVersion = kMinProtocolVersion;
  bool get fastMode => receiverVersion >= 4;

  // ---- state shown on screen ----
  SendPhase phase = SendPhase.idle;
  String? fatalError;
  String? statusLine;

  bool get paused => _paused;
  bool reconnecting = false;
  int retryRound = 0;
  int get retryRounds => maxAttempts - 1;
  Duration? nextRetryIn;
  int targetLanes = 1;

  // Overall progress.
  int totalBytes = 0;
  int _completedBytes = 0;
  int filesToSend = 0;
  int filesProcessed = 0;
  int resumedBytes = 0; // bytes that didn't need re-sending thanks to resume
  int clonedFiles = 0; // identical content copied on the new phone instead of sent
  int clonedBytes = 0;
  int batchesSent = 0;

  // Progress of the "looking for identical files" step (shown before sending starts).
  int dupCheckTotalFiles = 0;
  int dupCheckDoneFiles = 0;
  int dupCheckTotalBytes = 0;
  int dupCheckDoneBytes = 0;
  bool _skipDuplicateCheck = false;

  /// Skip the identical-file check and start sending right away (identical files
  /// are then simply sent like any other file).
  void skipDuplicateCheck() {
    _skipDuplicateCheck = true;
    statusLine = 'Skipping the identical-file check…';
    _tick(force: true);
  }
  int get bytesDone => min(totalBytes, _completedBytes + lanes.values.fold<int>(0, (s, l) => s + l.bytes));

  /// What each lane is sending right now.
  final Map<int, LaneView> lanes = {};

  // Kept for code that shows a single "current file".
  LaneView? get currentLane => lanes.isEmpty ? null : lanes.values.first;

  final List<RecentFile> recent = [];
  final List<DlqItem> dlq = [];
  final Map<Category, CategoryTally> tally = {for (final c in Category.values) c: CategoryTally()};
  int contactsTotal = 0, contactsAdded = 0, contactsExisting = 0, contactsFailed = 0;
  Map<String, dynamic>? receiverReport;

  int get filesSent => tally.values.fold(0, (s, t) => s + t.sent);
  int get filesAlready => tally.values.fold(0, (s, t) => s + t.already);
  int get filesFailed => tally.values.fold(0, (s, t) => s + t.failed);
  List<DlqItem> get failedItems => [for (final d in dlq) if (d.status == DlqStatus.failed) d];
  List<DlqItem> get openDlq => [for (final d in dlq) if (d.status != DlqStatus.recovered) d];

  // ---- internals ----
  bool _cancel = false;
  bool _paused = false;
  bool _mainPass = false;
  Completer<void>? _resumeSignal;
  final Map<int, _Inflight> _inflight = {};
  Future<void>? _reconnecting;
  DateTime _lastTick = DateTime(0);
  int _netBytes = 0;
  final List<(int, int)> _speedSamples = []; // (ms, netBytes)
  Timer? _heartbeat;
  Timer? _watchdog;
  Timer? _laneController;
  bool _heartbeatBusy = false;
  int _seq = 0;
  final String _session = DateTime.now().millisecondsSinceEpoch.toRadixString(36);

  // Work queues for the lanes.
  final List<_Work> _bigQueue = [];
  final List<_Work> _batchQueue = [];
  int _troubleSinceCheck = 0; // stalls / errors since the lane controller last looked
  int _bytesAtLastCheck = 0;
  double _rateAtLastCheck = 0;

  /// Bytes per second over the last few seconds.
  double get bytesPerSecond {
    if (_paused || reconnecting || _speedSamples.length < 2) return 0;
    final (t0, b0) = _speedSamples.first;
    final (t1, b1) = _speedSamples.last;
    return t1 == t0 ? 0 : (b1 - b0) * 1000 / (t1 - t0);
  }

  Duration? get eta {
    final speed = bytesPerSecond;
    if (speed <= 0) return null;
    return Duration(seconds: ((totalBytes - bytesDone) / speed).ceil());
  }

  void _tick({bool force = false}) {
    final now = DateTime.now();
    if (force || now.difference(_lastTick).inMilliseconds >= 100) {
      _lastTick = now;
      final ms = now.millisecondsSinceEpoch;
      _speedSamples.add((ms, _netBytes));
      while (_speedSamples.length > 2 && ms - _speedSamples.first.$1 > 5000) {
        _speedSamples.removeAt(0);
      }
      notifyListeners();
    }
  }

  // ---------------- controls ----------------

  bool get _running => phase == SendPhase.sending || phase == SendPhase.retrying || phase == SendPhase.checking;

  void pause() {
    if (_paused || !_running) return;
    _paused = true;
    _resumeSignal = Completer<void>();
    for (final f in _inflight.values.toList()) {
      f.abort(_PauseSignal()); // each file resumes from this exact byte later
    }
    _speedSamples.clear();
    _tick(force: true);
    _sendHeartbeat();
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    for (final f in _inflight.values) {
      f.lastProgress = DateTime.now();
    }
    _resumeSignal?.complete();
    _tick(force: true);
    _sendHeartbeat();
  }

  void cancel() {
    _cancel = true;
    for (final f in _inflight.values.toList()) {
      f.abort(_CancelSignal());
    }
    if (_paused) {
      _paused = false;
      _resumeSignal?.complete();
    }
  }

  Future<void> _waitIfPaused() async {
    while (_paused && !_cancel) {
      await _resumeSignal!.future;
    }
  }

  /// Sleeps for [d], but pauses with the transfer and wakes early on cancel.
  Future<void> _sleep(Duration d, {bool showCountdown = false}) async {
    var left = d;
    while (left > Duration.zero && !_cancel) {
      await _waitIfPaused();
      if (showCountdown) {
        nextRetryIn = left;
        _tick(force: true);
      }
      final step = left < const Duration(milliseconds: 200) ? left : const Duration(milliseconds: 200);
      await Future.delayed(step);
      left -= step;
    }
    nextRetryIn = null;
  }

  // ---------------- contacts ----------------

  static Future<List<Contact>> loadContacts() async {
    final status = await FlutterContacts.permissions.request(PermissionType.read);
    if (status != PermissionStatus.granted && status != PermissionStatus.limited) return [];
    return FlutterContacts.getAll(properties: {...ContactProperties.allProperties, ContactProperty.photoFullRes});
  }

  /// Contact data without anything tied to this specific phone.
  static Map<String, dynamic> _portableContact(Contact c) {
    final j = c.toJson();
    j.remove('id');
    j.remove('metadata');
    final a = j['android'];
    if (a is Map) {
      a.remove('identifiers');
      a.remove('customRingtone');
      a.remove('lastUpdatedTimestamp');
      a.remove('debugData');
    }
    return j;
  }

  // ---------------- network basics ----------------

  Future<void> ping() async {
    if (pairing.version < kMinProtocolVersion) {
      throw 'The new phone has an older version of this app. Install the same version on both phones.';
    }
    final req = await _client.getUrl(pairing.uri('/ping'));
    req.headers.set('x-code', pairing.code);
    final res = await req.close().timeout(const Duration(seconds: 8));
    final body = await utf8.decodeStream(res);
    if (res.statusCode == HttpStatus.forbidden) throw 'Wrong pairing code.';
    if (res.statusCode != 200) throw 'New phone answered: $body';
    try {
      receiverVersion = (jsonDecode(body) as Map)['v'] as int? ?? pairing.version;
    } catch (_) {
      receiverVersion = pairing.version;
    }
  }

  Future<bool> _reachable() async {
    try {
      await ping().timeout(const Duration(seconds: 5));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The new phone disappeared (Wi-Fi dropped, out of range…). Every lane waits
  /// on the same reconnect instead of failing its files.
  Future<void> _waitForReconnect() => _reconnecting ??= _reconnect().whenComplete(() => _reconnecting = null);

  Future<void> _reconnect() async {
    reconnecting = true;
    _speedSamples.clear();
    _tick(force: true);
    var delay = const Duration(seconds: 2);
    while (!_cancel) {
      await _sleep(delay);
      if (_cancel) break;
      if (await _reachable()) break;
      delay = Duration(seconds: min(delay.inSeconds * 2, 15));
    }
    reconnecting = false;
    for (final f in _inflight.values) {
      f.lastProgress = DateTime.now();
    }
    _tick(force: true);
  }

  Future<dynamic> _request(String method, String path,
      {Object? body, Map<String, String>? query, Duration timeout = const Duration(seconds: 30)}) async {
    Future<dynamic> go() async {
      final req = await _client.openUrl(method, pairing.uri(path, query));
      req.headers.set('x-code', pairing.code);
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        req.headers.contentType = ContentType.json;
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final res = await req.close();
      final text = await utf8.decodeStream(res);
      if (res.statusCode == 409) throw _FileFailure('Checksum mismatch: the file arrived damaged');
      if (res.statusCode == 410) throw _FileFailure('The new phone lost the partly received file');
      if (res.statusCode == 404) return null;
      if (res.statusCode != 200) throw _Rejected(text);
      return text.isEmpty ? null : jsonDecode(text);
    }

    return go().timeout(timeout);
  }

  /// Same as [_request], but rides out short network drops.
  Future<dynamic> _requestReliably(String method, String path, {Object? body}) async {
    while (true) {
      try {
        return await _request(method, path, body: body);
      } on _Rejected {
        rethrow;
      } on _FileFailure {
        rethrow;
      } catch (_) {
        if (_cancel) throw _CancelSignal();
        await _waitForReconnect();
        if (_cancel) throw _CancelSignal();
      }
    }
  }

  Future<Set<String>> _present(List<FileEntry> files) async {
    final present = <String>{};
    for (var i = 0; i < files.length && !_cancel; i += 1000) {
      final chunk = files.sublist(i, min(i + 1000, files.length));
      final res = await _requestReliably('POST', '/check', body: {
        'items': [for (final f in chunk) {'key': f.key, 'size': f.size}],
      }) as Map;
      present.addAll((res['present'] as List).cast<String>());
    }
    return present;
  }

  // ---------------- one large file (resumable) ----------------

  static String _uploadId(FileEntry f) => sha1.convert(utf8.encode(f.key)).toString();

  /// Streams the file, continuing from whatever the new phone already has.
  Future<void> _upload(FileEntry f, int lane) async {
    final id = _uploadId(f);
    final file = File(f.path);
    final status = await _request('GET', '/status', query: {'id': id}) as Map;
    var offset = status['received'] as int;
    if (offset > f.size) offset = 0;
    if (offset > 0) resumedBytes += offset;

    final view = LaneView(f.rel, offset, f.size, resumedFrom: offset);
    lanes[lane] = view;
    _tick(force: true);

    final req = await _client.postUrl(pairing.uri('/upload', {
      'id': id,
      'offset': '$offset',
      'total': '${f.size}',
      'name': f.rel,
    }));
    final flight = _Inflight(req);
    _inflight[lane] = flight;
    req.headers.set('x-code', pairing.code);
    req.headers.contentType = ContentType.binary;
    req.contentLength = f.size - offset;
    // Pause or Stop pressed while we were getting ready.
    if (_cancel) flight.abort(_CancelSignal());
    if (_paused) flight.abort(_PauseSignal());

    try {
      await req.addStream(readInBlocks(file, offset).map((chunk) {
        view.bytes += chunk.length;
        _netBytes += chunk.length;
        flight.lastProgress = DateTime.now();
        debugOnChunk?.call(this, f, view.bytes);
        _tick();
        return chunk;
      }));
      final res = await req.close();
      final text = await utf8.decodeStream(res);
      if (res.statusCode != 200) throw _Rejected(text);
      final received = (jsonDecode(text) as Map)['received'] as int;
      if (received != f.size) throw _RetryNow();
    } catch (e) {
      if (flight.abortReason != null) throw flight.abortReason!;
      rethrow;
    } finally {
      _inflight.remove(lane);
    }
  }

  /// Uploads and commits one file. Pauses and short connection drops are
  /// handled here; anything specific to this file becomes a [_FileFailure].
  Future<String> _processFile(FileEntry f, int lane) async {
    var quickRetries = 0;
    Future<String>? shaFuture;
    try {
      while (true) {
        await _waitIfPaused();
        if (_cancel) throw _CancelSignal();
        try {
          final size = await File(f.path).length();
          if (size != f.size) {
            throw _FileFailure('The file changed after the scan (${formatBytes(f.size)} → ${formatBytes(size)}). '
                'Scan again to include the new version.');
          }
          // The checksum is worked out in a background isolate while the bytes stream.
          shaFuture ??= sha256InBackground(f.path)..ignore();
          await _upload(f, lane);
          final sha = await shaFuture;
          final commitTimeout = Duration(seconds: 60 + f.size ~/ (20 * 1024 * 1024));
          final res = await _request('POST', '/commit', timeout: commitTimeout, body: {
            'id': _uploadId(f),
            'key': f.key,
            'rel': f.rel,
            'mtime': f.mtime,
            'size': f.size,
            'sha': sha,
            'category': f.category.name,
          }) as Map;
          return res['status'] as String;
        } on _PauseSignal {
          continue; // wait for Resume, then pick up from the same byte
        } on _RetryNow {
          if (++quickRetries > 3) throw _FileFailure('The new phone kept losing part of this file');
          continue;
        } on _CancelSignal {
          rethrow;
        } on _FileFailure {
          rethrow;
        } catch (e) {
          if (_cancel) throw _CancelSignal();
          if (_paused) continue;
          _troubleSinceCheck++;
          if (e is _Rejected || e is FileSystemException) throw _FileFailure(_describe(e));
          // Timeout or network error: is the new phone still there?
          if (await _reachable()) throw _FileFailure(_describe(e));
          await _waitForReconnect(); // then retry this file; it doesn't count as a failure
        }
      }
    } finally {
      lanes.remove(lane);
    }
  }

  // ---------------- a batch of small files ----------------

  /// Sends many small files in one request: [len][header][bytes] per file.
  /// Returns key -> 'saved' | 'already' | 'error: …' for the files the new phone handled.
  Future<Map<String, String>> _sendBatch(List<FileEntry> files, List<String> shas, int lane) async {
    final headers = [
      for (var i = 0; i < files.length; i++)
        utf8.encode(jsonEncode({
          'key': files[i].key,
          'rel': files[i].rel,
          'size': files[i].size,
          'mtime': files[i].mtime,
          'category': files[i].category.name,
          'sha': shas[i],
        })),
    ];
    var length = 0;
    var dataBytes = 0;
    for (var i = 0; i < files.length; i++) {
      length += 4 + headers[i].length + files[i].size;
      dataBytes += files[i].size;
    }
    final view = LaneView(files.first.rel, 0, dataBytes, batch: true, batchCount: files.length);
    lanes[lane] = view;
    _tick(force: true);

    final req = await _client.postUrl(pairing.uri('/batch', {
      'id': '${_session}_${_seq++}',
      'count': '${files.length}',
      'total': '$dataBytes',
    }));
    final flight = _Inflight(req);
    _inflight[lane] = flight;
    req.headers.set('x-code', pairing.code);
    req.headers.contentType = ContentType.binary;
    req.contentLength = length;
    if (_cancel) flight.abort(_CancelSignal());
    if (_paused) flight.abort(_PauseSignal());

    Stream<List<int>> frames() async* {
      for (var i = 0; i < files.length; i++) {
        view.rel = files[i].rel;
        view.batchIndex = i;
        final len = ByteData(4)..setUint32(0, headers[i].length);
        yield len.buffer.asUint8List();
        yield headers[i];
        await for (final chunk in readInBlocks(File(files[i].path))) {
          view.bytes += chunk.length;
          _netBytes += chunk.length;
          flight.lastProgress = DateTime.now();
          _tick();
          yield chunk;
        }
      }
    }

    try {
      await req.addStream(frames());
      final res = await req.close();
      final text = await utf8.decodeStream(res);
      if (res.statusCode != 200) throw _Rejected(text);
      batchesSent++;
      return ((jsonDecode(text) as Map)['results'] as Map).cast<String, String>();
    } catch (e) {
      if (flight.abortReason != null) throw flight.abortReason!;
      rethrow;
    } finally {
      _inflight.remove(lane);
    }
  }

  Future<void> _runBatch(List<FileEntry> files, int lane) async {
    var pending = List<FileEntry>.of(files);
    var cutOffs = 0;
    var stalled = false; // the batch timed out: the new phone was stuck on one file
    try {
      while (pending.isNotEmpty) {
        await _waitIfPaused();
        if (_cancel) throw _CancelSignal();

        // Drop files that vanished or changed since the scan.
        final ok = <FileEntry>[];
        for (final f in pending) {
          try {
            final size = await File(f.path).length();
            if (size == f.size) {
              ok.add(f);
            } else {
              _toDlq(f, 'The file changed after the scan. Scan again to include the new version.');
            }
          } on FileSystemException catch (e) {
            _toDlq(f, _describe(e));
          }
        }
        pending = ok;
        if (pending.isEmpty) return;

        List<String> shas;
        try {
          shas = await sha256ManyInBackground([for (final f in pending) f.path]);
        } catch (_) {
          // One of them can't be read: fall back to one at a time to find out which.
          for (final f in pending) {
            await _runSingle(f, lane);
          }
          return;
        }

        try {
          final results = await _sendBatch(pending, shas, lane);
          final missing = <FileEntry>[];
          for (final f in pending) {
            final r = results[f.key];
            if (r == null) {
              missing.add(f);
            } else if (r == 'saved' || r == 'already') {
              _recordSuccess(f, r);
            } else {
              _toDlq(f, r.startsWith('error: ') ? r.substring(7) : r);
            }
          }
          pending = missing;
          if (pending.isNotEmpty && ++cutOffs > 3) {
            for (final f in pending) {
              _toDlq(f, 'The batch kept being cut off');
            }
            return;
          }
        } on _PauseSignal {
          // fall through: on resume, skip what already arrived and send the rest
        } on _CancelSignal {
          rethrow;
        } catch (e) {
          if (_cancel) throw _CancelSignal();
          if (!_paused) {
            _troubleSinceCheck++;
            if (!await _reachable()) {
              await _waitForReconnect();
            } else if (e is _Stall) {
              stalled = true; // skip just the stuck file; the rest of the batch carries on
            } else if (++cutOffs > 3) {
              for (final f in pending) {
                _toDlq(f, _describe(e));
              }
              return;
            }
          }
        }
        // Whatever made it before the interruption is already saved: don't send it again.
        if (pending.isNotEmpty && !_cancel) {
          await _waitIfPaused();
          final present = await _present(pending);
          for (final f in pending.where((f) => present.contains(f.key))) {
            _recordSuccess(f, 'saved');
          }
          pending = pending.where((f) => !present.contains(f.key)).toList();
          if (stalled && pending.isNotEmpty) {
            // The new phone saves batch files in order, so the stuck one is the
            // first file it doesn't have yet.
            _toDlq(pending.removeAt(0), _Stall(stallTimeout).toString());
            stalled = false;
          }
        }
      }
    } finally {
      lanes.remove(lane);
    }
  }

  Future<void> _runSingle(FileEntry f, int lane) async {
    try {
      _recordSuccess(f, await _processFile(f, lane));
    } on _FileFailure catch (e) {
      _toDlq(f, e.message);
    }
  }

  static String _describe(Object e) {
    if (e is FileSystemException) {
      return 'Could not read the file: ${e.osError?.message ?? e.message}';
    }
    if (e is TimeoutException) return 'Timed out waiting for the new phone';
    if (e is SocketException) return 'Network error: ${e.osError?.message ?? e.message}';
    if (e is HttpException) return 'Network error: ${e.message}';
    return e.toString();
  }

  void _recordSuccess(FileEntry f, String status) {
    if (status == 'saved' || status == 'cloned') {
      tally[f.category]!.sent++;
    } else {
      tally[f.category]!.already++;
    }
    _completedBytes += f.size;
    if (_mainPass) filesProcessed++;
    recent.insert(0, RecentFile(f.rel, f.size, status == 'already'));
    if (recent.length > 8) recent.removeLast();
    _tick();
  }

  void _toDlq(FileEntry f, String error) {
    dlq.add(DlqItem(f, error));
    if (_mainPass) filesProcessed++;
    _tick(force: true);
  }

  // ---------------- lanes ----------------

  _Work? _nextWork(int lane) {
    // Lane 0 prefers large files, the others prefer batches; anyone takes what's left.
    final first = lane == 0 ? _bigQueue : _batchQueue;
    final second = lane == 0 ? _batchQueue : _bigQueue;
    if (first.isNotEmpty) return first.removeAt(0);
    if (second.isNotEmpty) return second.removeAt(0);
    return null;
  }

  Future<void> _lane(int lane) async {
    while (!_cancel) {
      await _waitIfPaused();
      if (_cancel) return;
      if (lane >= targetLanes) {
        if (_bigQueue.isEmpty && _batchQueue.isEmpty) return;
        await Future.delayed(const Duration(milliseconds: 300));
        continue;
      }
      final work = _nextWork(lane);
      if (work == null) return;
      try {
        if (work.file != null) {
          await _runSingle(work.file!, lane);
        } else {
          await _runBatch(work.batch!, lane);
        }
      } on _CancelSignal {
        return;
      }
    }
  }

  /// Adds a lane while speed keeps improving; removes one on stalls or errors.
  void _adjustLanes() {
    if (!fastMode || _paused || reconnecting) return;
    final rate = (_netBytes - _bytesAtLastCheck) / 4.0;
    _bytesAtLastCheck = _netBytes;
    final waiting = _bigQueue.length + _batchQueue.length;
    if (_troubleSinceCheck > 0) {
      targetLanes = max(minLanes, targetLanes - 1);
    } else if (rate > _rateAtLastCheck * 1.1 && waiting > 0) {
      targetLanes = min(maxLanes, targetLanes + 1);
    }
    _troubleSinceCheck = 0;
    _rateAtLastCheck = rate;
  }

  // ---------------- identical content ----------------

  /// Finds files with the same name, size and content. Each is sent once; the
  /// others are copied on the new phone. Returns duplicate -> (sha, original).
  Future<Map<FileEntry, String>> _findDuplicates(List<FileEntry> files) async {
    final groups = <String, List<FileEntry>>{};
    for (final f in files) {
      if (f.size < kDuplicateCheckMin) continue;
      groups.putIfAbsent('${f.size}|${f.rel.split('/').last.toLowerCase()}', () => []).add(f);
    }
    final candidates = [for (final g in groups.values) if (g.length > 1) ...g];
    if (candidates.isEmpty || _skipDuplicateCheck) return {};
    dupCheckTotalFiles = candidates.length;
    dupCheckTotalBytes = candidates.fold(0, (s, f) => s + f.size);
    dupCheckDoneFiles = dupCheckDoneBytes = 0;
    final shaOf = <FileEntry, String>{};
    // Small steps (at most 20 files or 64 MB) so the progress bar keeps moving.
    var i = 0;
    while (i < candidates.length && !_cancel && !_skipDuplicateCheck) {
      final chunk = <FileEntry>[];
      var chunkBytes = 0;
      while (i < candidates.length && chunk.length < 20 && (chunk.isEmpty || chunkBytes + candidates[i].size <= 64 << 20)) {
        chunkBytes += candidates[i].size;
        chunk.add(candidates[i++]);
      }
      statusLine = 'Looking for identical files: ${chunk.first.rel.split('/').last}';
      _tick(force: true);
      try {
        final shas = await sha256ManyInBackground([for (final f in chunk) f.path]);
        for (var j = 0; j < chunk.length; j++) {
          shaOf[chunk[j]] = shas[j];
        }
      } catch (_) {
        // unreadable file: leave this chunk to be sent normally
      }
      dupCheckDoneFiles += chunk.length;
      dupCheckDoneBytes += chunkBytes;
      _tick(force: true);
    }
    statusLine = null;
    final seen = <String>{};
    final dups = <FileEntry, String>{};
    for (final f in candidates) {
      final sha = shaOf[f];
      if (sha == null) continue;
      if (!seen.add(sha)) dups[f] = sha;
    }
    return dups;
  }

  // ---------------- heartbeat to the new phone ----------------

  Map<String, dynamic> _snapshot() => {
        'phase': phase.name,
        'paused': _paused,
        'reconnecting': reconnecting,
        'retryRound': retryRound,
        'retryRounds': retryRounds,
        'nextRetryIn': nextRetryIn?.inSeconds,
        'bytesDone': bytesDone,
        'totalBytes': totalBytes,
        'filesDone': filesProcessed,
        'filesTotal': filesToSend,
        'speed': bytesPerSecond.round(),
        'lanes': lanes.length,
        'dlq': [for (final d in openDlq.take(200)) d.toJson()],
      };

  Future<void> _sendHeartbeat() async {
    if (_heartbeatBusy) return;
    _heartbeatBusy = true;
    try {
      await _request('POST', '/state', body: _snapshot(), timeout: const Duration(seconds: 4));
    } catch (_) {
      // best effort
    } finally {
      _heartbeatBusy = false;
    }
  }

  void _updateNotification() {
    final pct = totalBytes == 0 ? -1 : (bytesDone * 100 ~/ totalBytes);
    final String title;
    final String text;
    if (_paused) {
      title = 'Transfer paused';
      text = '${formatBytes(bytesDone)} of ${formatBytes(totalBytes)}. Open the app to resume.';
    } else if (reconnecting) {
      title = 'Waiting for the new phone…';
      text = 'Keep both phones on the same Wi-Fi';
    } else if (phase == SendPhase.retrying) {
      title = 'Retrying ${openDlq.length} failed file(s)';
      text = 'Round $retryRound of $retryRounds';
    } else {
      final eta = this.eta;
      title = 'Sending to new phone • $pct%';
      text = '${formatBytes(bytesDone)} of ${formatBytes(totalBytes)}'
          '${lanes.length > 1 ? ' • ${lanes.length} at once' : ''}'
          '${eta == null ? '' : ' • ${formatDuration(eta)} left'}';
    }
    Native.updateNotification(title, text, _paused || reconnecting ? -1 : pct);
  }

  // ---------------- main transfer ----------------

  Future<void> run(SendPlan plan) async {
    _cancel = false;
    _paused = false;
    reconnecting = false;
    fatalError = null;
    receiverReport = null;
    dlq.clear();
    recent.clear();
    lanes.clear();
    _bigQueue.clear();
    _batchQueue.clear();
    _completedBytes = totalBytes = filesProcessed = filesToSend = resumedBytes = 0;
    clonedFiles = clonedBytes = batchesSent = 0;
    dupCheckTotalFiles = dupCheckDoneFiles = dupCheckTotalBytes = dupCheckDoneBytes = 0;
    _skipDuplicateCheck = false;
    retryRound = 0;
    contactsTotal = contactsAdded = contactsExisting = contactsFailed = 0;
    for (final t in tally.values) {
      t.selected = t.sent = t.already = t.failed = 0;
    }
    phase = SendPhase.checking;
    statusLine = 'Checking what is already on the new phone…';
    await Native.startBackgroundService('Preparing transfer', statusLine!);
    await Native.keepScreenOn(true);
    _tick(force: true);
    _heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
      _sendHeartbeat();
      _updateNotification();
    });
    _watchdog = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_paused || reconnecting) return;
      final now = DateTime.now();
      for (final f in _inflight.values.toList()) {
        if (now.difference(f.lastProgress) > stallTimeout) {
          _troubleSinceCheck++;
          f.abort(_Stall(stallTimeout));
        }
      }
    });

    try {
      // Which protocol does the new phone speak? (It may still be on v3.)
      await ping();

      // 1. Index check: skip files the new phone already has.
      final present = await _present(plan.files);
      final toSend = <FileEntry>[];
      for (final f in plan.files) {
        tally[f.category]!.selected++;
        if (present.contains(f.key)) {
          tally[f.category]!.already++;
        } else {
          toSend.add(f);
        }
      }
      filesToSend = toSend.length;
      totalBytes = toSend.fold(0, (s, f) => s + f.size);
      contactsTotal = plan.contacts.length;

      // 2. Identical content: send once, copy on the new phone.
      final duplicates = fastMode ? await _findDuplicates(toSend) : <FileEntry, String>{};

      await _requestReliably('POST', '/hello', body: {
        'files': filesToSend,
        'bytes': totalBytes,
        'contacts': contactsTotal,
        'already': present.length,
      });
      phase = SendPhase.sending;
      statusLine = null;

      // 3. Contacts.
      for (var i = 0; i < plan.contacts.length && !_cancel; i += 50) {
        await _waitIfPaused();
        final batch = plan.contacts.sublist(i, min(i + 50, plan.contacts.length));
        statusLine = 'Contacts ${i + 1}–${i + batch.length} of ${plan.contacts.length}';
        _tick(force: true);
        final res = await _requestReliably('POST', '/contacts', body: [for (final c in batch) _portableContact(c)])
            as Map;
        contactsAdded += res['added'] as int;
        contactsExisting += res['existing'] as int;
        contactsFailed += res['failed'] as int;
      }
      statusLine = null;

      // 4. Main pass: lanes in parallel. Failures are parked in the retry queue.
      final work = toSend.where((f) => !duplicates.containsKey(f)).toList();
      if (fastMode) {
        final small = <FileEntry>[];
        for (final f in work) {
          if (f.size <= kBatchFileMax) {
            small.add(f);
          } else {
            _bigQueue.add(_Work.file(f));
          }
        }
        var batch = <FileEntry>[];
        var batchBytes = 0;
        for (final f in small) {
          if (batch.length >= kBatchMaxFiles || batchBytes + f.size > kBatchMaxBytes) {
            _batchQueue.add(_Work.batch(batch));
            batch = [];
            batchBytes = 0;
          }
          batch.add(f);
          batchBytes += f.size;
        }
        if (batch.isNotEmpty) _batchQueue.add(_Work.batch(batch));
        targetLanes = min(startLanes, maxLanes);
      } else {
        _bigQueue.addAll(work.map(_Work.file)); // v3 phone: one file at a time, as before
        targetLanes = 1;
      }
      _mainPass = true;
      _laneController = Timer.periodic(const Duration(seconds: 4), (_) => _adjustLanes());
      final laneCount = fastMode ? maxLanes : 1;
      await Future.wait([for (var i = 0; i < laneCount; i++) _lane(i)]);
      _laneController?.cancel();

      // 5. Copies of identical content, after their originals are in place.
      for (final entry in duplicates.entries) {
        if (_cancel) break;
        final f = entry.key;
        try {
          final res = await _requestReliably('POST', '/clone', body: {
            'sha': entry.value,
            'key': f.key,
            'rel': f.rel,
            'size': f.size,
            'mtime': f.mtime,
            'category': f.category.name,
          });
          if (res != null) {
            final status = (res as Map)['status'] as String;
            if (status == 'saved') {
              clonedFiles++;
              clonedBytes += f.size;
            }
            _recordSuccess(f, status == 'saved' ? 'cloned' : status);
            continue;
          }
        } on _CancelSignal {
          break;
        } catch (_) {
          // fall back to sending it normally
        }
        try {
          await _runSingle(f, 0);
        } on _CancelSignal {
          break;
        }
      }
      _mainPass = false;

      // 6. Retry queue: rounds with exponential backoff, one file at a time.
      if (!_cancel && openDlq.isNotEmpty) {
        phase = SendPhase.retrying;
        for (retryRound = 1; retryRound <= retryRounds && !_cancel; retryRound++) {
          final waiting = [for (final d in dlq) if (d.status == DlqStatus.waiting) d];
          if (waiting.isEmpty) break;
          final base = retryDelays[min(retryRound - 1, retryDelays.length - 1)];
          final jitter = 0.8 + _random.nextDouble() * 0.4;
          await _sleep(base * jitter, showCountdown: true);
          for (final item in waiting) {
            if (_cancel) break;
            item.status = DlqStatus.retrying;
            item.attempts++;
            _tick(force: true);
            try {
              _recordSuccess(item.file, await _processFile(item.file, 0));
              item.status = DlqStatus.recovered;
            } on _FileFailure catch (e) {
              item.lastError = e.message;
              item.status = item.attempts >= maxAttempts ? DlqStatus.failed : DlqStatus.waiting;
            } on _CancelSignal {
              item.attempts--;
              item.status = DlqStatus.waiting;
              break;
            }
            _tick(force: true);
          }
        }
        retryRound = min(retryRound, retryRounds);
      }
      if (!_cancel) {
        for (final d in dlq) {
          if (d.status == DlqStatus.waiting) d.status = DlqStatus.failed;
        }
      }
      for (final d in failedItems) {
        tally[d.file.category]!.failed++;
      }

      final complete = !_cancel && failedItems.isEmpty;
      try {
        if (debugSkipDone) throw StateError('test: phone died before saying goodbye');
        receiverReport = await _request('POST', '/done', body: {
          'cancelled': _cancel,
          'complete': complete,
          'failed': [for (final d in failedItems) d.toJson()],
        }) as Map<String, dynamic>?;
      } catch (_) {
        // The summary on this phone is still accurate without the new phone's confirmation.
      }
      phase = _cancel ? SendPhase.cancelled : SendPhase.done;
    } on _CancelSignal {
      phase = SendPhase.cancelled;
    } catch (e) {
      fatalError = 'The transfer stopped: ${_describe(e)}\n\n'
          'Tap "Continue" to pick up where it stopped. Files that already arrived are skipped.';
      phase = SendPhase.error;
    } finally {
      _mainPass = false;
      _heartbeat?.cancel();
      _watchdog?.cancel();
      _laneController?.cancel();
      _heartbeat = _watchdog = _laneController = null;
      lanes.clear();
      statusLine = null;
      await Native.keepScreenOn(false);
      await Native.stopBackgroundService();
      _tick(force: true);
    }
  }

  @override
  void dispose() {
    cancel();
    _heartbeat?.cancel();
    _watchdog?.cancel();
    _laneController?.cancel();
    _client.close(force: true);
    super.dispose();
  }
}
