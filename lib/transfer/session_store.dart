import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

  static Future<File> _file() async =>
      File(p.join((await getApplicationSupportDirectory()).path, 'last_session.json'));

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

/// What the last transfer did, kept on each phone so the home screen can show it
/// after the phones are no longer connected. Replaced by the next transfer.
class TransferReport {
  final bool sent; // true on the old phone
  final DateTime when;
  final String outcome; // done | stopped | interrupted
  final List<ReportFile> files;

  const TransferReport(this.sent, this.when, this.outcome, this.files);

  int get onNewPhone => files.where((f) => const {'sent', 'saved', 'already', 'cloned'}.contains(f.status)).length;
  int get failed => files.where((f) => f.status == 'failed').length;
  int get bytes => files.fold(0, (s, f) => s + f.size);

  static Future<File> _file() async =>
      File(p.join((await getApplicationSupportDirectory()).path, 'last_report.json'));

  static Future<TransferReport?> load() async {
    try {
      final m = jsonDecode(await (await _file()).readAsString()) as Map;
      return TransferReport(
        m['sent'] as bool,
        DateTime.fromMillisecondsSinceEpoch(m['when'] as int),
        m['outcome'] as String,
        [for (final f in (m['files'] as List).cast<Map>()) ReportFile.fromJson(f)],
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> save() async {
    try {
      await (await _file()).writeAsString(jsonEncode({
        'sent': sent,
        'when': when.millisecondsSinceEpoch,
        'outcome': outcome,
        'files': [for (final f in files.take(60000)) f.toJson()],
      }));
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      await (await _file()).delete();
    } catch (_) {}
  }
}
