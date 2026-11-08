import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

/// An upload being written right now, so a newer request for the same file
/// (after a pause or reconnect) can take over cleanly.
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

/// Runs on the NEW phone.
///
/// * Each file is written to the SAME folder it had on the old phone, and only
///   kept if its SHA-256 matches what the old phone computed.
/// * Partly received files are kept in a hidden staging folder, so a paused,
///   timed-out or interrupted file continues from the last byte received —
///   even after the app restarts.
/// * An index of every received file (path + size + modified time → SHA-256)
///   lets the old phone skip anything already here on later runs.
class ReceiverService extends ChangeNotifier {
  /// Replaced in tests, where there is no Wi-Fi.
  @visibleForTesting
  static Future<String?> Function() ipLookup = localIpAddress;

  /// Test hook: runs before an upload's bytes are read.
  @visibleForTesting
  static Future<void> Function(String name)? debugBeforeReceive;

  /// An upload with no incoming bytes for this long is closed (the old phone
  /// will resume it).
  static const _receiveIdleTimeout = Duration(seconds: 60);

  HttpServer? _server;
  late Directory _root; // internal storage, e.g. /storage/emulated/0
  late Directory _tmp; // hidden staging folder on the same storage
  late File _indexFile;
  IOSink? _indexSink;
  final Map<String, ({String path, String sha})> _index = {};
  final Map<String, _ActiveUpload> _active = {};
  final Map<String, String> _fullHashes = {}; // uploadId -> sha of a complete, uninterrupted upload
  DateTime _lastTick = DateTime(0);
  Timer? _notifyTimer;

  PairingInfo? pairing;
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
  final Map<Category, ReceiveTally> tally = {for (final c in Category.values) c: ReceiveTally()};
  int contactsAdded = 0, contactsExisting = 0, contactsFailed = 0;
  final List<String> errors = [];
  final List<ReceivedFile> recent = [];

  // Current file, byte by byte.
  String? currentName;
  int currentBytes = 0;
  int currentTotal = 0;

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
  List<Map> get senderDlq => ((sender['dlq'] as List?) ?? const []).cast<Map>();

  Future<void> start() async {
    try {
      final roots = await Native.storageRoots();
      if (roots.isEmpty) throw 'Could not find this phone’s storage.';
      _root = Directory(roots.first);
      _tmp = Directory(p.join(_root.path, '.phonetransfer_tmp'));
      await _tmp.create(recursive: true); // kept between sessions so partial files can resume
      await _loadIndex();

      final host = await ipLookup();
      if (host == null) {
        throw 'Not connected to Wi-Fi. Connect both phones to the same Wi-Fi, '
            'or turn on hotspot on this phone and join it from the old phone.';
      }
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, kDefaultPort);
      } on SocketException {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      }
      pairing = PairingInfo(host: host, port: _server!.port, code: newPairingCode());
      _server!.listen(_handle);
      await Native.keepScreenOn(true);
      await Native.startBackgroundService('Ready to receive', 'Waiting for the old phone…', sending: false);
      _notifyTimer = Timer.periodic(const Duration(seconds: 1), (_) => _updateNotification());
      phase = ReceivePhase.waiting;
    } catch (e) {
      fatalError = '$e';
      phase = ReceivePhase.error;
    }
    notifyListeners();
  }

  Future<void> stop() async {
    _notifyTimer?.cancel();
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
    if (senderPaused) {
      Native.updateNotification('Transfer paused on the old phone', '${formatBytes(done)} of ${formatBytes(total)}', -1);
    } else if (senderReconnecting) {
      Native.updateNotification('Reconnecting to the old phone…', 'Keep both phones on the same Wi-Fi', -1);
    } else {
      Native.updateNotification('Receiving • $pct%', currentName ?? '${formatBytes(done)} of ${formatBytes(total)}', pct);
    }
  }

  // ---------------- index of received files ----------------

  Future<void> _loadIndex() async {
    final dir = await getApplicationSupportDirectory();
    _indexFile = File(p.join(dir.path, 'received_index.jsonl'));
    if (await _indexFile.exists()) {
      for (final line in await _indexFile.readAsLines()) {
        try {
          final m = jsonDecode(line) as Map;
          _index[m['key'] as String] = (path: m['path'] as String, sha: m['sha'] as String);
        } catch (_) {
          // a half-written last line from a crash: ignore it
        }
      }
    }
    _indexSink = _indexFile.openWrite(mode: FileMode.append);
  }

  void _remember(String key, String path, String sha) {
    _index[key] = (path: path, sha: sha);
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
    try {
      Object? reply;
      switch (req.uri.path) {
        case '/ping':
          reply = {'ok': true, 'v': kProtocolVersion};
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
          currentName = 'Contacts';
          reply = await _importContacts((await _json(req) as List).cast<Map>());
        case '/status':
          final f = _partFile(req.uri.queryParameters['id']!);
          reply = {'received': await f.exists() ? await f.length() : 0};
        case '/upload':
          final received = await _receiveUpload(req);
          reply = {'received': received};
        case '/commit':
          final result = await _commit(await _json(req) as Map);
          if (result is int) {
            res.statusCode = result; // 409 checksum mismatch / 410 partial file missing
            reply = {'error': result == 409 ? 'checksum mismatch' : 'partial file missing'};
          } else {
            reply = {'status': result};
          }
        case '/done':
          final body = await _json(req) as Map;
          senderCancelled = body['cancelled'] == true;
          complete = body['complete'] == true;
          finalFailures = ((body['failed'] as List?) ?? const []).cast<Map>();
          await _indexSink?.flush();
          if (complete) {
            // Nothing left to resume: clear the staging folder.
            try {
              await _tmp.delete(recursive: true);
              await _tmp.create();
            } catch (_) {}
          }
          phase = ReceivePhase.done;
          currentName = null;
          _updateNotification();
          await Native.keepScreenOn(false);
          reply = {
            'saved': savedTotal,
            'already': alreadyTotal,
            'contactsAdded': contactsAdded,
            'contactsExisting': contactsExisting,
            'contactsFailed': contactsFailed,
          };
        default:
          res.statusCode = HttpStatus.notFound;
      }
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(reply));
    } catch (e) {
      errors.add('${currentName ?? req.uri.path}: $e');
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
    filesProcessed = bytesReceived = 0;
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

  // ---------------- files ----------------

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
        // An even newer request took over while we waited: step aside.
        await it.cancel();
        return await part.exists() ? await part.length() : 0;
      }

      final have = await part.exists() ? await part.length() : 0;
      if (offset != 0 && offset != have) {
        await req.drain<void>();
        return have; // the old phone re-reads the right offset and tries again
      }
      _fullHashes.remove(id);

      currentName = name;
      currentBytes = offset;
      currentTotal = total;
      _tick(force: true);

      final sink = part.openWrite(mode: offset == 0 ? FileMode.write : FileMode.append);
      final hash = offset == 0 ? Sha256Stream() : null;
      var clean = true;
      try {
        while (await it.moveNext().timeout(_receiveIdleTimeout)) {
          final chunk = it.current;
          sink.add(chunk);
          hash?.add(chunk);
          currentBytes += chunk.length;
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
    final rel = _safeRel(body['rel'] as String);
    final mtime = body['mtime'] as int;
    final category = Category.values.byName(body['category'] as String);
    final part = _partFile(id);
    currentName = rel;

    // A repeated commit (the reply to the first one got lost) is recognised here.
    final known = _index[key];
    if (known != null && known.sha == sha && File(known.path).existsSync()) {
      if (await part.exists()) await part.delete();
      return 'already';
    }
    if (!await part.exists() || await part.length() != size) return 410;
    final actual = _fullHashes.remove(id) ?? await sha256OfFile(part);
    if (actual != sha) {
      await part.delete();
      return 409;
    }

    try {
      final (status, path) = await _place(part, rel, sha, mtime);
      _remember(key, path, sha);
      if (status == 'saved') {
        tally[category]!.saved++;
      } else {
        tally[category]!.already++;
      }
      filesProcessed++;
      recent.insert(0, ReceivedFile(rel, size, status != 'saved'));
      if (recent.length > 6) recent.removeLast();
      currentName = null;
      return status;
    } catch (e) {
      tally[category]!.failed++;
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
      if (await dest.length() == await part.length() && await sha256OfFile(dest) == sha) {
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
      await Native.finalizeFile(dest.path, mtime).timeout(const Duration(seconds: 15));
    } catch (_) {
      // The file is in place; the media index will catch up on its own.
    }
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
