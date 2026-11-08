import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Default port the new phone listens on.
const int kDefaultPort = 8765;

/// Bumped whenever the wire format changes.
/// v4 adds parallel lanes, small-file batches and duplicate cloning, and still
/// talks to v3 phones in either direction (falling back to v3 behaviour).
const int kProtocolVersion = 5;

/// Shown in the app. Must match `version:` in pubspec.yaml (a test checks it).
const String kAppVersion = '5.4.0';

/// Oldest protocol this app can still talk to.
const int kMinProtocolVersion = 3;

/// Files up to this size are sent together in batches.
const int kBatchFileMax = 2 * 1024 * 1024;

/// A batch closes at this many files or bytes, whichever comes first.
const int kBatchMaxFiles = 300;
const int kBatchMaxBytes = 32 * 1024 * 1024;

/// Files at least this large, sharing a name and size, are checked for identical content.
const int kDuplicateCheckMin = 64 * 1024;

/// Groups shown on the old phone. Photos, videos and music are what Android's
/// media index knows about; everything else is found by scanning storage.
enum Category { photos, videos, music, documents, archives, apps, otherMedia, otherFiles, hidden }

extension CategoryInfo on Category {
  String get label => switch (this) {
        Category.photos => 'Photos',
        Category.videos => 'Videos',
        Category.music => 'Music & audio',
        Category.documents => 'Documents',
        Category.archives => 'Archives',
        Category.apps => 'App installers (APK)',
        Category.otherMedia => 'Other media',
        Category.otherFiles => 'Other files',
        Category.hidden => 'Hidden files',
      };

  String get description => switch (this) {
        Category.photos => 'Everything in your gallery',
        Category.videos => 'Everything in your gallery',
        Category.music => 'Songs, recordings and other audio',
        Category.documents => 'PDF, Word, Excel, PowerPoint, text, e-books…',
        Category.archives => 'ZIP, RAR, 7z…',
        Category.apps => 'APK files saved on the phone',
        Category.otherMedia => 'Pictures, videos and audio not shown in the gallery',
        Category.otherFiles => 'Anything else on the phone storage',
        Category.hidden => 'Files in hidden folders (mostly app caches)',
      };

  /// Hidden folders are mostly caches and thumbnails, so they're off unless chosen.
  bool get onByDefault => this != Category.hidden;
}

/// One file on the old phone.
class FileEntry {
  final String path; // absolute path on the old phone
  final String rel; // path relative to the storage root, e.g. DCIM/Camera/IMG_1.jpg
  final int size;
  final int mtime; // last modified, ms since epoch
  final Category category;

  const FileEntry(this.path, this.rel, this.size, this.mtime, this.category);

  /// Identifies this exact version of the file across runs.
  String get key => '$rel|$size|$mtime';
}

/// Everything the old phone needs to reach the new phone. Encoded in the QR code.
class PairingInfo {
  final String host;
  final int port;
  final String code; // 6-digit pairing code, sent as X-Code on every request
  final int version; // highest protocol version the new phone speaks

  const PairingInfo({required this.host, required this.port, required this.code, this.version = kProtocolVersion});

  /// 'v' stays at the oldest compatible version so a v3 phone can still pair;
  /// 'max' tells newer phones what this one can do.
  String toQr() => jsonEncode({
        'app': 'phone_transfer',
        'v': kMinProtocolVersion,
        'max': kProtocolVersion,
        'host': host,
        'port': port,
        'code': code,
      });

  Map<String, dynamic> toJson() => {'host': host, 'port': port, 'code': code, 'version': version};

  static PairingInfo fromJson(Map m) => PairingInfo(
        host: m['host'] as String,
        port: m['port'] as int,
        code: m['code'] as String,
        version: m['version'] as int? ?? kMinProtocolVersion,
      );

  static PairingInfo? fromQr(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      if (m['app'] != 'phone_transfer') return null;
      return PairingInfo(
        host: m['host'] as String,
        port: m['port'] as int,
        code: m['code'] as String,
        version: m['max'] as int? ?? m['v'] as int? ?? 1,
      );
    } catch (_) {
      return null;
    }
  }

  Uri uri(String path, [Map<String, String>? query]) =>
      Uri(scheme: 'http', host: host, port: port, path: path, queryParameters: query);
}

String newPairingCode() {
  final r = Random.secure();
  return List.generate(6, (_) => r.nextInt(10)).join();
}

/// This phone's address on the local network, whether it's on Wi-Fi or hosting a hotspot.
Future<String?> localIpAddress() async {
  final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  int score(NetworkInterface i) {
    final n = i.name.toLowerCase();
    if (n.startsWith('wlan') || n.startsWith('swlan') || n.startsWith('ap') || n.contains('softap')) return 0;
    if (n.startsWith('rmnet') || n.startsWith('ccmni')) return 2; // mobile data
    return 1;
  }

  ifaces.sort((a, b) => score(a).compareTo(score(b)));
  for (final i in ifaces) {
    for (final a in i.addresses) {
      if (!a.isLoopback && _isPrivate(a.address)) return a.address;
    }
  }
  return null;
}

bool _isPrivate(String ip) {
  final p = ip.split('.').map(int.tryParse).toList();
  if (p.length != 4 || p.contains(null)) return false;
  return p[0] == 10 || (p[0] == 172 && p[1]! >= 16 && p[1]! <= 31) || (p[0] == 192 && p[1] == 168);
}

/// Streaming SHA-256: feed chunks as they pass by, then read the hex digest.
class Sha256Stream {
  final _out = _DigestHolder();
  late final ByteConversionSink _in = sha256.startChunkedConversion(_out);

  void add(List<int> chunk) => _in.add(chunk);

  String finish() {
    _in.close();
    return _out.value.toString();
  }
}

class _DigestHolder implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

Future<String> sha256OfFile(File f) async {
  final h = Sha256Stream();
  await for (final chunk in f.openRead()) {
    h.add(chunk);
  }
  return h.finish();
}

String formatBytes(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

String formatDuration(Duration d) {
  if (d.inHours > 0) return '${d.inHours} h ${d.inMinutes.remainder(60)} min';
  if (d.inMinutes > 0) return '${d.inMinutes} min';
  return '${max(1, d.inSeconds)} s';
}

/// Reads [file] from [start] in large blocks (1 MB): fewer, bigger writes to the socket.
Stream<List<int>> readInBlocks(File file, [int start = 0, int block = 1024 * 1024]) async* {
  final raf = await file.open();
  try {
    await raf.setPosition(start);
    while (true) {
      final chunk = await raf.read(block);
      if (chunk.isEmpty) break;
      yield chunk;
    }
  } finally {
    await raf.close();
  }
}

/// SHA-256 of a whole file, computed in a background isolate so the UI thread stays free.
Future<String> sha256InBackground(String path) => Isolate.run(() => sha256OfFile(File(path)));

/// SHA-256 of several files in one background isolate.
Future<List<String>> sha256ManyInBackground(List<String> paths) =>
    Isolate.run(() async => [for (final p in paths) await sha256OfFile(File(p))]);

