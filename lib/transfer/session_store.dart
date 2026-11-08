import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'native.dart';
import 'protocol.dart';

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
  const SnapshotApp(this.label, this.package, this.state, this.versionName);
  Map<String, dynamic> toJson() => {'label': label, 'package': package, 'state': state, 'versionName': versionName};
  static SnapshotApp fromJson(Map m) =>
      SnapshotApp(m['label'] as String, m['package'] as String, m['state'] as String, m['versionName'] as String?);
}

/// A read-only snapshot of one transfer: everything the Progress, Files and Extras
/// tabs showed when it ended. Saved as a JSON file in shared storage
/// ([TransferReport.folderName]) so it stays after the old phone is gone and even
/// after the app is uninstalled. Never changed once written; can be shared and imported.
class TransferReport {
  static const format = 'phone-clone-snapshot';
  static const folderName = 'Documents/Phone Clone/Snapshots';

  final bool sent; // true on the old phone
  final DateTime when;
  final String outcome; // done | stopped | interrupted
  final List<ReportFile> files;
  final List<SummaryRow> rows;
  final List<String> lines;
  final Map<String, Map<String, dynamic>> extras; // Extra.name -> ExtraTally json
  final List<SnapshotApp> apps;
  final String appVersion;

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
    this.path,
  });

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
        path: path,
      );

  // ---------------- storage ----------------

  /// Documents/Phone Clone/Snapshots on internal storage.
  static Future<Directory> folder() async {
    final roots = await Native.storageRoots();
    return Directory(p.join(roots.first, folderName));
  }

  /// Snapshots of 5.3–5.5, kept inside the app before snapshots moved to shared storage.
  static Future<File> _legacy() async =>
      File(p.join((await getApplicationSupportDirectory()).path, 'last_report.json'));

  /// Saves this snapshot as a new file. Existing snapshots are never overwritten.
  Future<TransferReport?> save() async {
    try {
      final dir = await folder();
      await dir.create(recursive: true);
      var f = File(p.join(dir.path, 'Phone Clone - $name.json'));
      for (var i = 2; await f.exists(); i++) {
        f = File(p.join(dir.path, 'Phone Clone - $name ($i).json'));
      }
      await f.writeAsString(jsonEncode(toJson()));
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
      final dir = await folder();
      if (await dir.exists()) {
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
    out.sort((a, b) => b.when.compareTo(a.when));
    return out;
  }

  /// The newest snapshot, for the home screen.
  static Future<TransferReport?> load() async {
    final all = await TransferReport.all();
    return all.isEmpty ? null : all.first;
  }

  /// Adds a snapshot file someone shared (e.g. from Drive or WhatsApp). Returns it, or
  /// null if the file isn't a Phone Clone snapshot. Importing the same one twice keeps one copy.
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
