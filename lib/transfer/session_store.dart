import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'native.dart';
import 'protocol.dart';
import 'scanner.dart';

/// The last transfer started on the old phone: which phone it went to and what
/// was selected. It survives app restarts and updates, so an unfinished
/// transfer can be continued with one tap instead of scanning the QR code again.
class LastSession {
  final PairingInfo pairing;
  final Set<Category> categories;
  final bool contacts;
  final DateTime startedAt;

  const LastSession(this.pairing, this.categories, this.contacts, this.startedAt);

  static Future<File> _file() async => File(p.join((await getApplicationSupportDirectory()).path, 'last_session.json'));

  static Future<LastSession?> load() async {
    try {
      final m = jsonDecode(await (await _file()).readAsString()) as Map;
      final started = DateTime.fromMillisecondsSinceEpoch(m['startedAt'] as int);
      if (DateTime.now().difference(started) > const Duration(days: 7)) return null;
      return LastSession(
        PairingInfo.fromJson(m['pairing'] as Map),
        {for (final c in (m['categories'] as List).cast<String>()) Category.values.byName(c)},
        m['contacts'] as bool,
        started,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> save() async {
    try {
      await (await _file()).writeAsString(jsonEncode({
        'pairing': pairing.toJson(),
        'categories': [for (final c in categories) c.name],
        'contacts': contacts,
        'startedAt': startedAt.millisecondsSinceEpoch,
      }));
    } catch (_) {}
  }

  /// Called when a transfer finished with nothing left to do.
  static Future<void> clear() async {
    try {
      await (await _file()).delete();
    } catch (_) {}
  }
}

/// One file in the saved report of the last transfer.
class ReportFile {
  final String rel;
  final int size;
  final String status; // sent | saved | already | cloned | waiting | queued | failed | restricted
  final String? category; // Category.name, null for restricted
  final String? path; // where it is on this phone
  final String? error;
  const ReportFile(this.rel, this.size, this.status, {this.category, this.path, this.error});

  Map<String, dynamic> toJson() => {
        'r': rel,
        's': size,
        't': status,
        if (category != null) 'c': category,
        if (path != null) 'p': path,
        if (error != null) 'e': error,
      };

  static ReportFile fromJson(Map m) => ReportFile(m['r'] as String, m['s'] as int, m['t'] as String,
      category: m['c'] as String?, path: m['p'] as String?, error: m['e'] as String?);
}

/// One row of a snapshot's summary table: copied / already there / failed.
class SummaryRow {
  final String label;
  final int copied, already, failed;
  const SummaryRow(this.label, this.copied, this.already, this.failed);
  List<Object> toJson() => [label, copied, already, failed];
  static SummaryRow fromJson(List j) => SummaryRow(j[0] as String, j[1] as int, j[2] as int, j[3] as int);
}

/// An app listed on the new phone (name and what happened to it).
class SnapshotApp {
  final String label, package, state; // state: ready | installed | failed | installing
  final String? versionName;
  final int versionCode;
  final bool fromPlay;
  final List<String> paths; // its APK files on the new phone, so it can still be installed
  const SnapshotApp(this.label, this.package, this.state, this.versionName,
      {this.versionCode = 0, this.fromPlay = false, this.paths = const []});
  Map<String, dynamic> toJson() => {
        'label': label,
        'package': package,
        'state': state,
        'versionName': versionName,
        'versionCode': versionCode,
        'fromPlay': fromPlay,
        'paths': paths,
      };
  static SnapshotApp fromJson(Map m) => SnapshotApp(
        m['label'] as String,
        m['package'] as String,
        m['state'] as String,
        m['versionName'] as String?,
        versionCode: (m['versionCode'] as num? ?? 0).toInt(),
        fromPlay: m['fromPlay'] == true,
        paths: [for (final x in (m['paths'] as List? ?? const [])) '$x'],
      );
}

/// A read-only snapshot of one transfer: everything the Progress, Files and Extras
/// tabs showed when it ended. Saved as a JSON file in shared storage
/// ([TransferReport.folderName]) so it stays after the old phone is gone and even
/// after the app is uninstalled. Never changed once written; can be shared and imported.
class TransferReport {
  static const format = 'phone-clone-snapshot';
  static const folderName = 'Documents/PhoneHop/Snapshots';

  /// Where 5.6.0 (still called Phone Clone) kept them; still read.
  static const oldFolderName = 'Documents/Phone Clone/Snapshots';

  final bool sent; // true on the old phone
  final DateTime when;
  final String outcome; // done | stopped | interrupted
  final List<ReportFile> files;
  final List<SummaryRow> rows;
  final List<String> lines;
  final Map<String, Map<String, dynamic>> extras; // Extra.name -> ExtraTally json
  final List<SnapshotApp> apps;
  final String appVersion;

  /// transfer: saved at the end of a transfer · records: rebuilt from this phone's
  /// record of received files (transfers made before snapshots existed).
  final String source;

  /// Where this snapshot is stored on this phone (null until saved or loaded).
  final String? path;

  const TransferReport(
    this.sent,
    this.when,
    this.outcome,
    this.files, {
    this.rows = const [],
    this.lines = const [],
    this.extras = const {},
    this.apps = const [],
    this.appVersion = '',
    this.source = 'transfer',
    this.path,
  });

  /// Saved by a version that kept only the file list (5.3–5.5), or rebuilt from records.
  bool get partial => rows.isEmpty || source == 'records';

  /// The per-type table; worked out from the file list when the snapshot doesn't have one.
  List<SummaryRow> get table {
    if (rows.isNotEmpty) return rows;
    final out = <SummaryRow>[];
    for (final c in Category.values) {
      final fs = [for (final f in files) if (f.category == c.name) f];
      if (fs.isEmpty) continue;
      out.add(SummaryRow(
        c.label,
        fs.where((f) => const {'sent', 'saved', 'cloned'}.contains(f.status)).length,
        fs.where((f) => f.status == 'already').length,
        fs.where((f) => f.status == 'failed').length,
      ));
    }
    return out;
  }

  /// Apps that can be installed on the new phone; found from the copied installers when
  /// the snapshot doesn't list them.
  List<SnapshotApp> get installableApps {
    if (sent) return const [];
    if (apps.isNotEmpty) return apps;
    final byPkg = <String, List<String>>{};
    for (final f in files) {
      final parts = f.rel.split('/');
      if (parts.length >= 4 && parts[0] == 'PhoneClone' && parts[1] == 'Apps' && f.path != null) {
        byPkg.putIfAbsent(parts[2], () => []).add(f.path!);
      }
    }
    return [
      for (final e in byPkg.entries)
        SnapshotApp(e.key, e.key, 'ready', null, paths: e.value..sort((a, b) => a.endsWith('base.apk') ? -1 : 1)),
    ];
  }

  int get onNewPhone => files.where((f) => const {'sent', 'saved', 'already', 'cloned'}.contains(f.status)).length;
  int get failed => files.where((f) => f.status == 'failed').length;
  int get bytes => files.fold(0, (s, f) => s + f.size);

  /// "Sent 2026-11-09 01.04" — also the file name, so snapshots sort by date.
  String get name {
    String two(int v) => v.toString().padLeft(2, '0');
    final w = when;
    return '${sent ? 'Sent' : 'Received'} ${w.year}-${two(w.month)}-${two(w.day)} ${two(w.hour)}.${two(w.minute)}.${two(w.second)}';
  }

  Map<String, dynamic> toJson() => {
        'format': format,
        'version': 1,
        'appVersion': appVersion,
        'source': source,
        'sent': sent,
        'when': when.millisecondsSinceEpoch,
        'outcome': outcome,
        'rows': [for (final r in rows) r.toJson()],
        'lines': lines,
        'extras': extras,
        'apps': [for (final a in apps) a.toJson()],
        'files': [for (final f in files.take(100000)) f.toJson()],
      };

  static TransferReport fromJson(Map m, {String? path}) => TransferReport(
        m['sent'] as bool,
        DateTime.fromMillisecondsSinceEpoch(m['when'] as int),
        m['outcome'] as String,
        [for (final f in (m['files'] as List).cast<Map>()) ReportFile.fromJson(f)],
        rows: [for (final r in (m['rows'] as List? ?? const [])) SummaryRow.fromJson(r as List)],
        lines: [for (final l in (m['lines'] as List? ?? const [])) '$l'],
        extras: {
          for (final e in ((m['extras'] as Map?) ?? const {}).entries)
            '${e.key}': (e.value as Map).cast<String, dynamic>(),
        },
        apps: [for (final a in (m['apps'] as List? ?? const [])) SnapshotApp.fromJson(a as Map)],
        appVersion: m['appVersion'] as String? ?? '',
        source: m['source'] as String? ?? 'transfer',
        path: path,
      );

  // ---------------- storage ----------------

  /// Documents/PhoneHop/Snapshots on internal storage.
  static Future<Directory> folder() async {
    final roots = await Native.storageRoots();
    return Directory(p.join(roots.first, folderName));
  }

  /// Snapshots of 5.3–5.5, kept inside the app before snapshots moved to shared storage.
  static Future<File> _legacy() async =>
      File(p.join((await getApplicationSupportDirectory()).path, 'last_report.json'));

  /// Saves this snapshot as a new file, or updates [into] (the same transfer's snapshot,
  /// e.g. after an app was installed from it). Other snapshots are never overwritten.
  Future<TransferReport?> save({String? into}) async {
    try {
      final dir = await folder();
      await dir.create(recursive: true);
      var f = File(into ?? p.join(dir.path, 'PhoneHop - $name.json'));
      for (var i = 2; into == null && await f.exists(); i++) {
        f = File(p.join(dir.path, 'PhoneHop - $name ($i).json'));
      }
      // Written to a temporary file first, so a reader never sees half a snapshot.
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(toJson()));
      await tmp.rename(f.path);
      return TransferReport.fromJson(toJson(), path: f.path);
    } catch (_) {
      return null;
    }
  }

  static Future<TransferReport?> _read(File f) async {
    try {
      final m = jsonDecode(await f.readAsString()) as Map;
      if (m['format'] != null && m['format'] != format) return null;
      return fromJson(m, path: f.path);
    } catch (_) {
      return null;
    }
  }

  /// All snapshots on this phone, newest first.
  static Future<List<TransferReport>> all() async {
    final out = <TransferReport>[];
    try {
      final roots = await Native.storageRoots();
      for (final name in [folderName, oldFolderName]) {
        final dir = Directory(p.join(roots.first, name));
        if (!await dir.exists()) continue;
        for (final e in dir.listSync()) {
          if (e is File && e.path.toLowerCase().endsWith('.json')) {
            final r = await _read(e);
            if (r != null) out.add(r);
          }
        }
      }
    } catch (_) {}
    if (out.isEmpty) {
      final legacy = await _read(await _legacy());
      if (legacy != null) out.add(legacy);
    }
    // No full snapshot of a received transfer yet (it was made before 5.6): rebuild one
    // from the new phone's records, once, and keep it with the others.
    if (!out.any((r) => !r.sent && !r.partial) && !out.any((r) => r.source == 'records')) {
      final rebuilt = await fromRecords();
      if (rebuilt != null) {
        final saved = await rebuilt.save();
        if (saved != null) out.add(saved);
      }
    }
    out.sort((a, b) => b.when.compareTo(a.when));
    return out;
  }

  /// The new phone's record of every file it received (the index it uses to skip
  /// duplicates), as a snapshot. Used for transfers made before snapshots existed.
  static Future<TransferReport?> fromRecords() async {
    try {
      final support = (await getApplicationSupportDirectory()).path;
      final files = <String, ReportFile>{};
      DateTime? newest;
      for (final f in [File(p.join(support, 'received_v2.jsonl')), File(p.join(support, 'received_index.jsonl'))]) {
        if (!await f.exists()) continue;
        final m = await f.lastModified();
        if (newest == null || m.isAfter(newest)) newest = m;
        for (final line in await f.readAsLines()) {
          try {
            final j = jsonDecode(line) as Map;
            final key = j['key'] as String, path = j['path'] as String;
            final a = key.lastIndexOf('|'), b = key.lastIndexOf('|', a - 1);
            final rel = key.substring(0, b);
            final st = FileStat.statSync(path);
            if (st.type != FileSystemEntityType.file) continue; // deleted since
            files[path] = ReportFile(rel, st.size, 'saved', category: categoryOfFile(rel).name, path: path);
          } catch (_) {}
        }
      }
      if (files.isEmpty) return null;
      return TransferReport(false, newest!, 'done', files.values.toList(),
          source: 'records', appVersion: kAppVersion,
          lines: ['Rebuilt from this phone’s record of received files. Counts for contacts, messages and other '
              'extras weren’t kept by the version that made this transfer.']);
    } catch (_) {
      return null;
    }
  }

  /// The newest snapshot, for the home screen.
  static Future<TransferReport?> load() async {
    final all = await TransferReport.all();
    return all.isEmpty ? null : all.first;
  }

  /// Adds a snapshot file someone shared (e.g. from Drive or WhatsApp). Returns it, or
  /// null if the file isn't a PhoneHop snapshot. Importing the same one twice keeps one copy.
  static Future<TransferReport?> import(List<int> bytes) async {
    try {
      final m = jsonDecode(utf8.decode(bytes)) as Map;
      if (m['format'] != format) return null;
      final incoming = fromJson(m);
      for (final r in await all()) {
        if (r.sent == incoming.sent && r.when == incoming.when && r.path != null) return r;
      }
      return await incoming.save();
    } catch (_) {
      return null;
    }
  }
}
