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
