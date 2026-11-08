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

/// Runs on the OLD phone. It only ever READS from this phone: there is no code
/// here that deletes, moves or edits anything on it.
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

  @visibleForTesting
  void Function(SenderService sender, FileEntry file, int fileBytes)? debugOnChunk;

  final PairingInfo pairing;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..idleTimeout = const Duration(seconds: 30);
  final Random _random = Random();

  SenderService(this.pairing);

  // ---- state shown on screen ----
  SendPhase phase = SendPhase.idle;
  String? fatalError;
  String? statusLine;

  bool get paused => _paused;
  bool reconnecting = false;
  int retryRound = 0;
  int get retryRounds => maxAttempts - 1;
  Duration? nextRetryIn;

  // Overall progress.
  int totalBytes = 0;
  int _completedBytes = 0;
  int filesToSend = 0;
  int filesProcessed = 0;
  int resumedBytes = 0; // bytes that didn't need re-sending thanks to resume
  int get bytesDone => min(totalBytes, _completedBytes + currentFileBytes);

  // Current file, byte by byte.
  FileEntry? currentFile;
  int currentFileBytes = 0;
  int currentFileResumedFrom = 0;

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
  Completer<void>? _resumeSignal;
  HttpClientRequest? _activeReq;
  Object? _abortReason;
  DateTime _lastProgress = DateTime.now();
  DateTime _lastTick = DateTime(0);
  int _netBytes = 0;
  final List<(int, int)> _speedSamples = []; // (ms, netBytes)
  Timer? _heartbeat;
  bool _heartbeatBusy = false;

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
    _abort(_PauseSignal()); // the file resumes from this exact byte later
    _speedSamples.clear();
    _tick(force: true);
    _sendHeartbeat();
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    _lastProgress = DateTime.now();
    _resumeSignal?.complete();
    _tick(force: true);
    _sendHeartbeat();
  }

  void cancel() {
    _cancel = true;
    _abort(_CancelSignal());
    if (_paused) {
      _paused = false;
      _resumeSignal?.complete();
    }
  }

  void _abort(Object reason) {
    final req = _activeReq;
    if (req == null) return;
    _abortReason = reason;
    req.abort(reason);
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
    if (pairing.version != kProtocolVersion) {
      throw 'The other phone has a different version of this app. Install the same version on both phones.';
    }
    final req = await _client.getUrl(pairing.uri('/ping'));
    req.headers.set('x-code', pairing.code);
    final res = await req.close().timeout(const Duration(seconds: 8));
    final body = await utf8.decodeStream(res);
    if (res.statusCode == HttpStatus.forbidden) throw 'Wrong pairing code.';
    if (res.statusCode != 200) throw 'New phone answered: $body';
  }

  Future<bool> _reachable() async {
    try {
      await ping().timeout(const Duration(seconds: 5));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The new phone disappeared (Wi-Fi dropped, screen locked, out of range…).
  /// Wait for it instead of failing every remaining file.
  Future<void> _waitForReconnect() async {
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
    _lastProgress = DateTime.now();
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

  // ---------------- one file ----------------

  static String _uploadId(FileEntry f) => sha1.convert(utf8.encode(f.key)).toString();

  /// Streams the file, continuing from whatever the new phone already has.
  /// Returns the SHA-256 of the whole file.
  Future<String> _upload(FileEntry f) async {
    _abortReason = null;
    final id = _uploadId(f);
    final file = File(f.path);
    final size = await file.length();
    if (size != f.size) {
      throw _FileFailure('The file changed after the scan (${formatBytes(f.size)} → ${formatBytes(size)}). '
          'Scan again to include the new version.');
    }

    final status = await _request('GET', '/status', query: {'id': id}) as Map;
    var offset = status['received'] as int;
    if (offset > size) offset = 0;

    final hash = Sha256Stream();
    if (offset > 0) {
      await for (final chunk in file.openRead(0, offset)) {
        hash.add(chunk);
      }
      resumedBytes += offset;
    }
    currentFile = f;
    currentFileBytes = offset;
    currentFileResumedFrom = offset;
    _lastProgress = DateTime.now();
    _tick(force: true);

    final req = await _client.postUrl(pairing.uri('/upload', {
      'id': id,
      'offset': '$offset',
      'total': '$size',
      'name': f.rel,
    }));
    _activeReq = req;
    req.headers.set('x-code', pairing.code);
    req.headers.contentType = ContentType.binary;
    req.contentLength = size - offset;
    // Pause or Stop pressed while we were getting ready.
    if (_cancel) _abort(_CancelSignal());
    if (_paused) _abort(_PauseSignal());

    final watchdog = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!_paused && DateTime.now().difference(_lastProgress) > stallTimeout) {
        _abort(_Stall(stallTimeout));
      }
    });
    try {
      await req.addStream(file.openRead(offset).map((chunk) {
        hash.add(chunk);
        currentFileBytes += chunk.length;
        _netBytes += chunk.length;
        _lastProgress = DateTime.now();
        debugOnChunk?.call(this, f, currentFileBytes);
        _tick();
        return chunk;
      }));
      final res = await req.close();
      final text = await utf8.decodeStream(res);
      if (res.statusCode != 200) throw _Rejected(text);
      final received = (jsonDecode(text) as Map)['received'] as int;
      if (received != size) throw _RetryNow();
      return hash.finish();
    } catch (e) {
      final reason = _abortReason;
      _abortReason = null;
      if (reason != null) throw reason;
      rethrow;
    } finally {
      watchdog.cancel();
      _activeReq = null;
    }
  }

  /// Uploads and commits one file. Pauses and short connection drops are
  /// handled here; anything specific to this file becomes a [_FileFailure].
  Future<String> _processFile(FileEntry f) async {
    var quickRetries = 0;
    while (true) {
      await _waitIfPaused();
      if (_cancel) throw _CancelSignal();
      try {
        final sha = await _upload(f);
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
        if (e is _Rejected || e is FileSystemException) throw _FileFailure(_describe(e));
        // Timeout or network error: is the new phone still there?
        if (await _reachable()) throw _FileFailure(_describe(e));
        await _waitForReconnect(); // then retry this file; it doesn't count as a failure
      }
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
    if (status == 'saved') {
      tally[f.category]!.sent++;
    } else {
      tally[f.category]!.already++;
    }
    _completedBytes += f.size;
    recent.insert(0, RecentFile(f.rel, f.size, status != 'saved'));
    if (recent.length > 6) recent.removeLast();
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
    _completedBytes = totalBytes = filesProcessed = filesToSend = resumedBytes = 0;
    currentFile = null;
    currentFileBytes = 0;
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

    try {
      // 1. Index check: skip files the new phone already has.
      final present = <String>{};
      for (var i = 0; i < plan.files.length && !_cancel; i += 1000) {
        final chunk = plan.files.sublist(i, min(i + 1000, plan.files.length));
        final res = await _requestReliably('POST', '/check', body: {
          'items': [for (final f in chunk) {'key': f.key, 'size': f.size}],
        }) as Map;
        present.addAll((res['present'] as List).cast<String>());
      }
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

      await _requestReliably('POST', '/hello', body: {
        'files': filesToSend,
        'bytes': totalBytes,
        'contacts': contactsTotal,
        'already': present.length,
      });
      phase = SendPhase.sending;
      statusLine = null;

      // 2. Contacts.
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

      // 3. Main pass. A file that times out or fails is parked in the retry queue.
      for (final f in toSend) {
        if (_cancel) break;
        try {
          _recordSuccess(f, await _processFile(f));
        } on _FileFailure catch (e) {
          dlq.add(DlqItem(f, e.message));
        } on _CancelSignal {
          break;
        }
        filesProcessed++;
        currentFile = null;
        currentFileBytes = 0;
        _tick(force: true);
      }

      // 4. Retry queue: rounds with exponential backoff.
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
              _recordSuccess(item.file, await _processFile(item.file));
              item.status = DlqStatus.recovered;
            } on _FileFailure catch (e) {
              item.lastError = e.message;
              item.status = item.attempts >= maxAttempts ? DlqStatus.failed : DlqStatus.waiting;
            } on _CancelSignal {
              item.attempts--;
              item.status = DlqStatus.waiting;
              break;
            }
            currentFile = null;
            currentFileBytes = 0;
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

      currentFile = null;
      final complete = !_cancel && failedItems.isEmpty;
      try {
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
          'Tap "Try again" to continue. Files that already arrived are skipped.';
      phase = SendPhase.error;
    } finally {
      _heartbeat?.cancel();
      _heartbeat = null;
      currentFile = null;
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
    _client.close(force: true);
    super.dispose();
  }
}
