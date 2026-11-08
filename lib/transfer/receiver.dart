import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'native.dart';
import 'protocol.dart';

enum ReceivePhase { starting, waiting, receiving, done, error }

class ReceiveTally {
  int saved = 0;
  int already = 0;
  int failed = 0;
}

class ReceivedFile {
  final String rel;
  final int size;
  final bool alreadyThere;
  const ReceivedFile(this.rel, this.size, this.alreadyThere);
}

/// A file (or batch of small files) arriving right now.
class InFlight {
  String name;
  int bytes;
  int total;
  final bool batch;
  int batchDone = 0;
  final int batchCount;
  InFlight(this.name, this.bytes, this.total, {this.batch = false, this.batchCount = 0});
}

/// An upload being written right now, so a newer request for the same file
/// (after a pause, timeout or reconnect) can take over cleanly.
class _ActiveUpload {
  final StreamIterator<List<int>> it;
  final Completer<void> finished = Completer<void>();
  final Completer<void> superseded = Completer<void>();
  _ActiveUpload(this.it);

  Future<void> supersede() async {
    if (!superseded.isCompleted) superseded.complete();
    await it.cancel();
    await finished.future;
  }
}

/// Reads length-prefixed frames out of a batch upload.
class _FrameReader {
  final StreamIterator<List<int>> it;
  final Duration idle;
  List<int> _buf = const [];
  int _pos = 0;

  _FrameReader(this.it, this.idle);

  Future<bool> _fill() async {
    if (_pos < _buf.length) return true;
    if (!await it.moveNext().timeout(idle)) return false;
    _buf = it.current;
    _pos = 0;
    return true;
  }

  /// Exactly [n] bytes, or null if the stream ended cleanly before the first byte.
  Future<Uint8List?> readExact(int n) async {
    final out = BytesBuilder(copy: false);
    while (out.length < n) {
      if (!await _fill()) {
        if (out.length == 0) return null;
        throw 'batch cut off mid-header';
      }
      final take = min(n - out.length, _buf.length - _pos);
      out.add(_buf.sublist(_pos, _pos + take));
      _pos += take;
    }
    return out.takeBytes();
  }

  /// Copies exactly [n] bytes into [sink], hashing them on the way.
  Future<void> copyTo(IOSink sink, Sha256Stream hash, int n, void Function(int) onBytes) async {
    var left = n;
    while (left > 0) {
      if (!await _fill()) throw 'batch cut off mid-file';
      final take = min(left, _buf.length - _pos);
      final part = (_pos == 0 && take == _buf.length) ? _buf : _buf.sublist(_pos, _pos + take);
      sink.add(part);
      hash.add(part);
      _pos += take;
      left -= take;
      onBytes(take);
    }
  }
}

/// Runs on the NEW phone.
///
/// * Each file is written to the SAME folder it had on the old phone, and only
///   kept if its SHA-256 matches what the old phone computed.
/// * Partly received files are kept in a hidden staging folder, so a paused,
///   timed-out or interrupted file continues from the last byte received —
///   even after the app restarts or is updated.
/// * An index of every received file (path + size + modified time → SHA-256)
///   lets the old phone skip anything already here on later runs.
/// * v4: several uploads at once, many small files per request (`/batch`),
///   identical content copied locally (`/clone`), media index updated in batches.
///   Every v3 endpoint still works, so a v3 phone can send to this one.
class ReceiverService extends ChangeNotifier {
  /// Replaced in tests, where there is no Wi-Fi.
  @visibleForTesting
  static Future<String?> Function() ipLookup = localIpAddress;

  /// No request from the old phone for this long during a transfer = connection lost.
  @visibleForTesting
  static Duration senderSilenceLimit = const Duration(seconds: 15);

  /// Test hook: runs before an upload's bytes are read.
  @visibleForTesting
  static Future<void> Function(String name)? debugBeforeReceive;

  /// Test hook: behave like a v3 phone (no batches, no cloning).
  @visibleForTesting
  static int debugProtocolVersion = kProtocolVersion;

  /// An upload with no incoming bytes for this long is closed (the old phone resumes it).
  static const _receiveIdleTimeout = Duration(seconds: 60);

  HttpServer? _server;
  late Directory _root; // internal storage, e.g. /storage/emulated/0
  late Directory _tmp; // hidden staging folder on the same storage
  late Directory _support;
  late File _indexFile;
  IOSink? _indexSink;
  final Map<String, ({String path, String sha})> _index = {};
  final Map<String, String> _bySha = {}; // sha -> a saved path with that content
  final Map<String, _ActiveUpload> _active = {};
  final Map<String, String> _fullHashes = {}; // uploadId -> sha of a complete, uninterrupted upload
  final List<String> _scanQueue = [];
  DateTime _lastTick = DateTime(0);
  Timer? _notifyTimer;
  Timer? _scanTimer;

  PairingInfo? pairing;

  /// True when this phone's address changed since the transfer started
  /// (e.g. the hotspot was restarted): the old phone must scan the new QR code.
  bool addressChanged = false;
  DateTime _lastSenderContact = DateTime.now();
  bool _wasLost = false;
  Timer? _addressTimer;
  ReceivePhase phase = ReceivePhase.starting;
  String? fatalError;
  bool senderCancelled = false;
  bool complete = false;

  // Session totals.
  int expectedFiles = 0;
  int expectedBytes = 0;
  int expectedContacts = 0;
  int alreadyBeforeStart = 0;
  int filesProcessed = 0;
  int bytesReceived = 0;
  int clonedFiles = 0;
  int clonedBytes = 0;
  final Map<Category, ReceiveTally> tally = {for (final c in Category.values) c: ReceiveTally()};
  int contactsAdded = 0, contactsExisting = 0, contactsFailed = 0;
  final List<String> errors = [];
  final List<ReceivedFile> recent = [];

  /// Everything arriving right now (one entry per parallel upload or batch).
  final Map<String, InFlight> inFlight = {};

  /// Latest status reported by the old phone (overall progress, paused, retry queue…).
  Map<String, dynamic> sender = const {};

  /// Files the old phone gave up on, with their errors (sent at the end).
  List<Map> finalFailures = const [];

  Set<String>? _contactKeys;

  int get savedTotal => tally.values.fold(0, (s, t) => s + t.saved);
  int get alreadyTotal => tally.values.fold(0, (s, t) => s + t.already) + alreadyBeforeStart;
  int get failedTotal => finalFailures.length;
  bool get senderPaused => sender['paused'] == true;
  bool get senderReconnecting => sender['reconnecting'] == true;

  /// The old phone has gone quiet in the middle of a transfer (battery died,
  /// Wi-Fi or hotspot dropped…). The screen then offers the QR code again.
  bool get senderLost =>
      phase == ReceivePhase.receiving && DateTime.now().difference(_lastSenderContact) > senderSilenceLimit;

  /// Re-reads this phone's address. The pairing code and port stay the same, so
  /// only the address in the QR code changes.
  Future<void> refreshAddress() async {
    final p = pairing;
    if (p == null) return;
    final host = await ipLookup();
    if (host == null || host == p.host) return;
    pairing = PairingInfo(host: host, port: p.port, code: p.code);
    if (phase == ReceivePhase.receiving) addressChanged = true;
    await _savePairing();
    notifyListeners();
  }
  List<Map> get senderDlq => ((sender['dlq'] as List?) ?? const []).cast<Map>();

  // Kept for screens that show a single "current file".
  String? get currentName => inFlight.isEmpty ? null : inFlight.values.first.name;

  Future<void> start() async {
    try {
      final roots = await Native.storageRoots();
      if (roots.isEmpty) throw 'Could not find this phone’s storage.';
      _root = Directory(roots.first);
      _tmp = Directory(p.join(_root.path, '.phonetransfer_tmp'));
      await _tmp.create(recursive: true); // kept between sessions so partial files can resume
      _support = await getApplicationSupportDirectory();
      await _loadIndex();

      final host = await ipLookup();
      if (host == null) {
        throw 'Not connected to Wi-Fi. Connect both phones to the same Wi-Fi, '
            'or turn on hotspot on this phone and join it from the old phone.';
      }
      // Reuse the last pairing code (and port) so the old phone can reconnect
      // after a restart or an app update without scanning again.
      final saved = await _loadSavedPairing();
      final wantPort = saved?.$2 ?? kDefaultPort;
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, wantPort);
      } on SocketException {
        try {
          _server = await HttpServer.bind(InternetAddress.anyIPv4, kDefaultPort);
        } on SocketException {
          _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
        }
      }
      pairing = PairingInfo(host: host, port: _server!.port, code: saved?.$1 ?? newPairingCode());
      await _savePairing();
      _server!.listen(_handle);
      await Native.keepScreenOn(true);
      await Native.startBackgroundService('Ready to receive', 'Waiting for the old phone…', sending: false);
      _notifyTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        _updateNotification();
        final lost = senderLost;
        if (lost != _wasLost) {
          _wasLost = lost;
          notifyListeners();
        }
      });
      // Networks change (hotspot restarted, Wi-Fi rejoined): keep the address and QR current.
      _addressTimer = Timer.periodic(const Duration(seconds: 3), (_) => refreshAddress());
      _scanTimer = Timer.periodic(const Duration(seconds: 2), (_) => _flushScans());
      phase = ReceivePhase.waiting;
    } catch (e) {
      fatalError = '$e';
      phase = ReceivePhase.error;
    }
    notifyListeners();
  }

  Future<void> stop() async {
    _notifyTimer?.cancel();
    _addressTimer?.cancel();
    _scanTimer?.cancel();
    _flushScans();
    for (final a in _active.values.toList()) {
      await a.it.cancel();
    }
    await _server?.close(force: true);
    _server = null;
    await _indexSink?.flush();
    await _indexSink?.close();
    _indexSink = null;
    await Native.keepScreenOn(false);
    await Native.stopBackgroundService();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  void _tick({bool force = false}) {
    final now = DateTime.now();
    if (force || now.difference(_lastTick).inMilliseconds >= 100) {
      _lastTick = now;
      notifyListeners();
    }
  }

  void _updateNotification() {
    if (phase == ReceivePhase.waiting) return;
    if (phase == ReceivePhase.done) {
      Native.updateNotification(
          complete ? 'Transfer complete' : 'Transfer finished', '$savedTotal files copied', 100);
      return;
    }
    final done = sender['bytesDone'] as int? ?? bytesReceived;
    final total = sender['totalBytes'] as int? ?? expectedBytes;
    final pct = total == 0 ? -1 : (done * 100 ~/ total);
    if (senderLost) {
      Native.updateNotification('Connection to the old phone lost', 'Open Phone Clone to reconnect', -1);
    } else if (senderPaused) {
      Native.updateNotification('Transfer paused on the old phone', '${formatBytes(done)} of ${formatBytes(total)}', -1);
    } else if (senderReconnecting) {
      Native.updateNotification('Reconnecting to the old phone…', 'Keep both phones on the same Wi-Fi', -1);
    } else {
      final n = inFlight.length;
      Native.updateNotification('Receiving • $pct%',
          n > 1 ? '$n files at once • ${formatBytes(done)} of ${formatBytes(total)}' : (currentName ?? ''), pct);
    }
  }

  // ---------------- media index (batched) ----------------

  void _queueScan(String path) {
    _scanQueue.add(path);
    if (_scanQueue.length >= 200) _flushScans();
  }

  void _flushScans() {
    if (_scanQueue.isEmpty) return;
    final batch = List<String>.of(_scanQueue);
    _scanQueue.clear();
    Native.scanFiles(batch);
  }

  // ---------------- saved pairing ----------------

  File get _pairingFile => File(p.join(_support.path, 'pairing.json'));

  Future<(String, int)?> _loadSavedPairing() async {
    try {
      final m = jsonDecode(await _pairingFile.readAsString()) as Map;
      final age = DateTime.now().millisecondsSinceEpoch - (m['savedAt'] as int);
      if (age > const Duration(days: 7).inMilliseconds) return null;
      return (m['code'] as String, m['port'] as int);
    } catch (_) {
      return null;
    }
  }

  Future<void> _savePairing() async {
    try {
      await _pairingFile.writeAsString(jsonEncode({
        'code': pairing!.code,
        'port': pairing!.port,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
      }));
    } catch (_) {}
  }

  // ---------------- index of received files ----------------

  Future<void> _loadIndex() async {
    _indexFile = File(p.join(_support.path, 'received_index.jsonl'));
    // v2 used a different file name: read it too, so nothing it received is sent again.
    for (final f in [File(p.join(_support.path, 'received_v2.jsonl')), _indexFile]) {
      if (!await f.exists()) continue;
      for (final line in await f.readAsLines()) {
        try {
          final m = jsonDecode(line) as Map;
          final path = m['path'] as String, sha = m['sha'] as String;
          _index[m['key'] as String] = (path: path, sha: sha);
          _bySha[sha] = path;
        } catch (_) {
          // a half-written last line from a crash: ignore it
        }
      }
    }
    _indexSink = _indexFile.openWrite(mode: FileMode.append);
  }

  void _remember(String key, String path, String sha) {
    _index[key] = (path: path, sha: sha);
    _bySha[sha] = path;
    _indexSink?.writeln(jsonEncode({'key': key, 'path': path, 'sha': sha}));
  }

  bool _alreadyHave(String key, int size) {
    final m = _index[key];
    if (m == null) return false;
    final f = File(m.path);
    return f.existsSync() && f.lengthSync() == size;
  }

  // ---------------- HTTP ----------------

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    if (req.headers.value('x-code') != pairing?.code) {
      res.statusCode = HttpStatus.forbidden;
      res.write('wrong pairing code');
      await res.close();
      return;
    }
    _lastSenderContact = DateTime.now();
    if (req.uri.path == '/hello') addressChanged = false; // the old phone has the current address
    final v4 = debugProtocolVersion >= 4;
    try {
      Object? reply;
      switch (req.uri.path) {
        case '/ping':
          reply = {'ok': true, 'v': debugProtocolVersion};
        case '/check':
          final body = await _json(req) as Map;
          reply = {
            'present': [
              for (final i in (body['items'] as List).cast<Map>())
                if (_alreadyHave(i['key'] as String, i['size'] as int)) i['key'],
            ],
          };
        case '/hello':
          final body = await _json(req) as Map;
          _resetSession();
          expectedFiles = body['files'] as int;
          expectedBytes = body['bytes'] as int;
          expectedContacts = body['contacts'] as int;
          alreadyBeforeStart = body['already'] as int;
          phase = ReceivePhase.receiving;
          reply = {'ok': true};
        case '/state':
          sender = (await _json(req) as Map).cast<String, dynamic>();
          reply = {'ok': true};
        case '/contacts':
          reply = await _importContacts((await _json(req) as List).cast<Map>());
        case '/status':
          final f = _partFile(req.uri.queryParameters['id']!);
          reply = {'received': await f.exists() ? await f.length() : 0};
        case '/upload':
          reply = {'received': await _receiveUpload(req)};
        case '/commit':
          final result = await _commit(await _json(req) as Map);
          if (result is int) {
            res.statusCode = result; // 409 checksum mismatch / 410 partial file missing
            reply = {'error': result == 409 ? 'checksum mismatch' : 'partial file missing'};
          } else {
            reply = {'status': result};
          }
        case '/batch' when v4:
          reply = {'results': await _receiveBatch(req)};
        case '/clone' when v4:
          final result = await _clone(await _json(req) as Map);
          if (result == null) {
            res.statusCode = HttpStatus.notFound;
            reply = {'error': 'no local copy'};
          } else {
            reply = {'status': result};
          }
        case '/done':
          final body = await _json(req) as Map;
          senderCancelled = body['cancelled'] == true;
          complete = body['complete'] == true;
          finalFailures = ((body['failed'] as List?) ?? const []).cast<Map>();
          await _indexSink?.flush();
          _flushScans();
          if (complete) {
            // Nothing left to resume: clear the staging folder.
            try {
              await _tmp.delete(recursive: true);
              await _tmp.create();
            } catch (_) {}
          }
          phase = ReceivePhase.done;
          inFlight.clear();
          _updateNotification();
          await Native.keepScreenOn(false);
          reply = {
            'saved': savedTotal,
            'already': alreadyTotal,
            'cloned': clonedFiles,
            'contactsAdded': contactsAdded,
            'contactsExisting': contactsExisting,
            'contactsFailed': contactsFailed,
          };
        default:
          await req.drain<void>();
          res.statusCode = HttpStatus.notFound;
      }
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(reply));
    } catch (e) {
      errors.add('${req.uri.path}: $e');
      res.statusCode = HttpStatus.internalServerError;
      res.write('$e');
    }
    try {
      await res.close();
    } catch (_) {
      // the old phone hung up (pause / timeout); nothing to tell it
    }
    _tick(force: true);
  }

  Future<dynamic> _json(HttpRequest req) async => jsonDecode(await utf8.decodeStream(req));

  void _resetSession() {
    filesProcessed = bytesReceived = clonedFiles = clonedBytes = 0;
    contactsAdded = contactsExisting = contactsFailed = 0;
    senderCancelled = complete = false;
    finalFailures = const [];
    sender = const {};
    errors.clear();
    recent.clear();
    for (final t in tally.values) {
      t.saved = t.already = t.failed = 0;
    }
  }

  // ---------------- single files (resumable) ----------------

  File _partFile(String id) => File(p.join(_tmp.path, '${id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '')}.part'));

  /// Appends the incoming bytes to the partial file and returns its new length.
  Future<int> _receiveUpload(HttpRequest req) async {
    final q = req.uri.queryParameters;
    final id = q['id']!;
    final offset = int.parse(q['offset'] ?? '0');
    final total = int.parse(q['total'] ?? '0');
    final name = q['name'] ?? 'file';
    final part = _partFile(id);
    final it = StreamIterator<List<int>>(req);
    final me = _ActiveUpload(it);

    // Only one writer per file: a newer request (after a pause, timeout or
    // reconnect) takes over from any older one that is stuck or still running.
    final previous = _active[id];
    _active[id] = me;
    try {
      if (previous != null) await previous.supersede();
      final hook = debugBeforeReceive;
      if (hook != null) await Future.any([hook(name), me.superseded.future]);
      if (!identical(_active[id], me)) {
        await it.cancel(); // an even newer request took over while we waited
        return await part.exists() ? await part.length() : 0;
      }

      final have = await part.exists() ? await part.length() : 0;
      if (offset != 0 && offset != have) {
        await req.drain<void>();
        return have; // the old phone re-reads the right offset and tries again
      }
      _fullHashes.remove(id);

      final flight = InFlight(name, offset, total);
      inFlight[id] = flight;
      _tick(force: true);

      final sink = part.openWrite(mode: offset == 0 ? FileMode.write : FileMode.append);
      final hash = offset == 0 ? Sha256Stream() : null;
      var clean = true;
      try {
        while (await it.moveNext().timeout(_receiveIdleTimeout)) {
          final chunk = it.current;
          sink.add(chunk);
          hash?.add(chunk);
          flight.bytes += chunk.length;
          bytesReceived += chunk.length;
          _tick();
        }
      } catch (_) {
        clean = false; // connection dropped, paused or idle: keep what we have
        await it.cancel();
      } finally {
        await sink.flush();
        await sink.close();
      }
      final length = await part.length();
      if (clean && hash != null && length == total && identical(_active[id], me)) {
        _fullHashes[id] = hash.finish();
      }
      if (length != total) inFlight.remove(id); // paused / cut off: no longer arriving
      _tick(force: true);
      return length;
    } finally {
      if (identical(_active[id], me)) _active.remove(id);
      me.finished.complete();
    }
  }

  /// Returns 'saved', 'already', or an HTTP status for the old phone to act on.
  Future<Object> _commit(Map body) async {
    final id = body['id'] as String;
    final key = body['key'] as String;
    final sha = body['sha'] as String;
    final size = body['size'] as int;
    final part = _partFile(id);
    try {
      // A repeated commit (the reply to the first one got lost) is recognised here.
      final known = _index[key];
      if (known != null && known.sha == sha && File(known.path).existsSync()) {
        if (await part.exists()) await part.delete();
        return 'already';
      }
      if (!await part.exists() || await part.length() != size) return 410;
      // A resumed file is checksummed in the background so receiving doesn't stutter.
      final actual = _fullHashes.remove(id) ?? await sha256InBackground(part.path);
      if (actual != sha) {
        await part.delete();
        return 409;
      }
      return await _finishFile(part,
          key: key,
          sha: sha,
          size: size,
          rel: body['rel'] as String,
          mtime: body['mtime'] as int,
          category: Category.values.byName(body['category'] as String));
    } finally {
      inFlight.remove(id);
    }
  }

  // ---------------- batches of small files ----------------

  /// Frames: [4-byte big-endian header length][header JSON][file bytes] …
  /// Each file is verified and saved as soon as it has arrived.
  Future<Map<String, String>> _receiveBatch(HttpRequest req) async {
    final count = int.tryParse(req.uri.queryParameters['count'] ?? '') ?? 0;
    final total = int.tryParse(req.uri.queryParameters['total'] ?? '') ?? 0;
    final flightId = 'batch:${req.uri.queryParameters['id'] ?? DateTime.now().microsecondsSinceEpoch}';
    final flight = InFlight('', 0, total, batch: true, batchCount: count);
    inFlight[flightId] = flight;
    final results = <String, String>{};
    final it = StreamIterator<List<int>>(req);
    final reader = _FrameReader(it, _receiveIdleTimeout);
    try {
      while (true) {
        final lenBytes = await reader.readExact(4);
        if (lenBytes == null) break;
        final headerLen = ByteData.sublistView(lenBytes).getUint32(0);
        final header = jsonDecode(utf8.decode((await reader.readExact(headerLen))!)) as Map;
        final key = header['key'] as String;
        final size = header['size'] as int;
        flight.name = header['rel'] as String;
        _tick();

        final hook = debugBeforeReceive;
        if (hook != null) await hook(header['rel'] as String);
        final part = File(p.join(_tmp.path, 'b${sha1.convert(utf8.encode(key))}.part'));
        final sink = part.openWrite();
        final hash = Sha256Stream();
        try {
          await reader.copyTo(sink, hash, size, (n) {
            flight.bytes += n;
            bytesReceived += n;
            _tick();
          });
        } finally {
          await sink.flush();
          await sink.close();
        }
        if (hash.finish() != header['sha']) {
          await part.delete();
          results[key] = 'error: checksum mismatch';
        } else {
          try {
            results[key] = await _finishFile(part,
                key: key,
                sha: header['sha'] as String,
                size: size,
                rel: header['rel'] as String,
                mtime: header['mtime'] as int,
                category: Category.values.byName(header['category'] as String));
          } catch (e) {
            results[key] = 'error: $e';
          }
        }
        flight.batchDone++;
      }
    } catch (e) {
      await it.cancel(); // cut off: the files already saved are in `results` and in the index
    } finally {
      inFlight.remove(flightId);
    }
    return results;
  }

  // ---------------- identical content ----------------

  /// Copies a file this phone already has with the same content to a new path,
  /// so the old phone doesn't send the same bytes twice.
  Future<String?> _clone(Map body) async {
    final sha = body['sha'] as String;
    final size = body['size'] as int;
    final srcPath = _bySha[sha];
    if (srcPath == null) return null;
    final src = File(srcPath);
    if (!await src.exists() || await src.length() != size) return null;
    final part = File(p.join(_tmp.path, 'c${sha1.convert(utf8.encode(body['key'] as String))}.part'));
    await src.copy(part.path);
    final status = await _finishFile(part,
        key: body['key'] as String,
        sha: sha,
        size: size,
        rel: body['rel'] as String,
        mtime: body['mtime'] as int,
        category: Category.values.byName(body['category'] as String));
    if (status == 'saved') {
      clonedFiles++;
      clonedBytes += size;
    }
    return status;
  }

  // ---------------- putting files in place ----------------

  /// Moves a verified staging file into place, records it in the index and
  /// updates the counters. Returns 'saved' or 'already'.
  Future<String> _finishFile(File part,
      {required String key,
      required String sha,
      required int size,
      required String rel,
      required int mtime,
      required Category category}) async {
    final known = _index[key];
    if (known != null && known.sha == sha && File(known.path).existsSync()) {
      if (await part.exists()) await part.delete();
      tally[category]!.already++;
      filesProcessed++;
      return 'already';
    }
    try {
      final safe = _safeRel(rel);
      final (status, path) = await _place(part, safe, sha, mtime);
      _remember(key, path, sha);
      if (status == 'saved') {
        tally[category]!.saved++;
      } else {
        tally[category]!.already++;
      }
      filesProcessed++;
      recent.insert(0, ReceivedFile(safe, size, status != 'saved'));
      if (recent.length > 6) recent.removeLast();
      return status;
    } catch (e) {
      tally[category]!.failed++;
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }

  /// Keeps paths inside this phone's storage and out of other apps' private folders.
  static String _safeRel(String rel) {
    var r = p.posix.normalize(rel.replaceAll('\\', '/'));
    if (r.startsWith('/') || r == '..' || r.startsWith('../')) r = 'PhoneTransfer/${p.posix.basename(r)}';
    final l = r.toLowerCase();
    if (l.startsWith('android/data/') || l.startsWith('android/obb/')) r = 'PhoneTransfer/$r';
    return r;
  }

  Future<(String, String)> _place(File part, String rel, String sha, int mtime) async {
    try {
      return await _placeAt(part, p.join(_root.path, rel), sha, mtime);
    } on FileSystemException {
      // Some folders (e.g. another app's Android/media) can be off-limits; keep the file anyway.
      return _placeAt(part, p.join(_root.path, 'PhoneTransfer', rel), sha, mtime);
    }
  }

  Future<(String, String)> _placeAt(File part, String destPath, String sha, int mtime) async {
    var dest = File(destPath);
    await dest.parent.create(recursive: true);
    if (await dest.exists()) {
      // Same name already here: if it's the same content, don't write a copy.
      if (await dest.length() == await part.length() && await sha256InBackground(dest.path) == sha) {
        await part.delete();
        return ('already', dest.path);
      }
      dest = await _freeName(dest);
    }
    try {
      await part.rename(dest.path);
    } on FileSystemException {
      await part.copy(dest.path);
      await part.delete();
    }
    try {
      await dest.setLastModified(DateTime.fromMillisecondsSinceEpoch(mtime));
    } catch (_) {}
    _queueScan(dest.path); // media index updated in batches, not after every file
    return ('saved', dest.path);
  }

  /// photo.jpg -> photo (1).jpg -> photo (2).jpg …
  static Future<File> _freeName(File f) async {
    final dir = f.parent.path;
    final base = p.basenameWithoutExtension(f.path);
    final ext = p.extension(f.path);
    for (var i = 1;; i++) {
      final candidate = File(p.join(dir, '$base ($i)$ext'));
      if (!await candidate.exists()) return candidate;
    }
  }

  // ---------------- contacts ----------------

  static Iterable<String> _keysOf(Contact c) sync* {
    var any = false;
    for (final ph in c.phones) {
      final digits = ph.number.replaceAll(RegExp(r'\D'), '');
      if (digits.length >= 6) {
        any = true;
        yield 'p:${digits.length > 10 ? digits.substring(digits.length - 10) : digits}';
      }
    }
    for (final e in c.emails) {
      final a = e.address.trim().toLowerCase();
      if (a.isNotEmpty) {
        any = true;
        yield 'e:$a';
      }
    }
    if (!any) {
      final n = (c.displayName ?? '').trim().toLowerCase();
      if (n.isNotEmpty) yield 'n:$n';
    }
  }

  Future<Map<String, int>> _importContacts(List<Map> batch) async {
    if (_contactKeys == null) {
      final status = await FlutterContacts.permissions.request(PermissionType.readWrite);
      if (status != PermissionStatus.granted && status != PermissionStatus.limited) {
        contactsFailed += batch.length;
        errors.add('Contacts: permission not granted on the new phone');
        return {'added': 0, 'existing': 0, 'failed': batch.length};
      }
      final existing = await FlutterContacts.getAll(
        properties: {ContactProperty.name, ContactProperty.phone, ContactProperty.email},
      );
      _contactKeys = {for (final c in existing) ..._keysOf(c)};
    }
    var added = 0, existing = 0, failed = 0;
    for (final json in batch) {
      try {
        final contact = Contact.fromJson(json);
        final keys = _keysOf(contact).toList();
        if (keys.isNotEmpty && keys.any(_contactKeys!.contains)) {
          existing++;
          continue;
        }
        await FlutterContacts.create(contact);
        _contactKeys!.addAll(keys);
        added++;
      } catch (e) {
        failed++;
        errors.add('Contact: $e');
      }
    }
    contactsAdded += added;
    contactsExisting += existing;
    contactsFailed += failed;
    _tick(force: true);
    return {'added': added, 'existing': existing, 'failed': failed};
  }
}
