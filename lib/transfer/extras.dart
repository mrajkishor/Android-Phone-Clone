import 'dart:io';

import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';

import 'native.dart';
import 'protocol.dart';

/// Data beyond files and contacts.
enum Extra { messages, calls, calendar, apps, wallpaper, ringtones }

extension ExtraInfo on Extra {
  String get label => switch (this) {
        Extra.messages => 'Messages (SMS & MMS)',
        Extra.calls => 'Call history',
        Extra.calendar => 'Calendar events',
        Extra.apps => 'Installed apps',
        Extra.wallpaper => 'Wallpaper',
        Extra.ringtones => 'Ringtones & sounds',
      };

  /// What the user is asked on the NEW phone before this can be restored.
  String get newPhonePrompt => switch (this) {
        Extra.messages =>
          'To restore your messages, Phone Clone must briefly be your default SMS app. You will be asked to switch back afterwards.',
        Extra.calls => 'Allow Phone Clone to add your call history.',
        Extra.calendar => 'Allow Phone Clone to add your calendar events.',
        Extra.ringtones => 'Allow Phone Clone to set your ringtone, notification and alarm sounds ("Modify system settings").',
        Extra.apps || Extra.wallpaper => '',
      };

  /// Restoring this needs a permission on the new phone, asked for during the transfer.
  bool get needsNewPhonePermission => this == Extra.messages || this == Extra.calls || this == Extra.calendar || this == Extra.ringtones;
}

/// Progress of one extra (both phones).
class ExtraTally {
  int total = 0;
  int added = 0;
  int existing = 0;
  int failed = 0;
  String state = 'pending'; // pending | waiting | running | done | skipped
  String? note;

  Map<String, dynamic> toJson() =>
      {'total': total, 'added': added, 'existing': existing, 'failed': failed, 'state': state, 'note': note};

  void absorb(Map result) {
    added += (result['added'] as num? ?? 0).toInt();
    existing += (result['existing'] as num? ?? 0).toInt();
    failed += (result['failed'] as num? ?? 0).toInt();
  }
}

/// An installed app on the old phone.
class AppInfo {
  final String package;
  final String label;
  final String? versionName;
  final int versionCode;
  final bool fromPlay;
  final List<FileEntry> files; // base.apk + split APKs, sent like any other file
  int get size => files.fold(0, (s, f) => s + f.size);

  AppInfo(this.package, this.label, this.versionName, this.versionCode, this.fromPlay, this.files);

  Map<String, dynamic> toJson() => {
        'package': package,
        'label': label,
        'versionName': versionName,
        'versionCode': versionCode,
        'fromPlay': fromPlay,
        'files': [for (final f in files) f.rel],
      };
}

/// What the old phone found beyond files.
class ExtrasScan {
  int sms = 0, mms = 0, calls = 0, calendarEvents = 0, contactGroups = 0;
  List<AppInfo> apps = [];
  List<Map<String, dynamic>> ringtones = [];
  bool wallpaper = true;
  final Map<Extra, String> unavailable = {}; // reason, e.g. permission denied

  int count(Extra e) => switch (e) {
        Extra.messages => sms + mms,
        Extra.calls => calls,
        Extra.calendar => calendarEvents,
        Extra.apps => apps.length,
        Extra.wallpaper => wallpaper ? 1 : 0,
        Extra.ringtones => ringtones.length,
      };

  String summary(Extra e) => switch (e) {
        Extra.messages => '$sms SMS • $mms MMS',
        Extra.calls => '$calls calls',
        Extra.calendar => '$calendarEvents events stored on this phone (Google/Outlook calendars come back when you sign in)',
        Extra.apps => '${apps.length} apps • ${formatBytes(apps.fold(0, (s, a) => s + a.size))}. '
            'Reinstalled on the new phone (app data and logins are not included)',
        Extra.wallpaper => 'Home and lock screen',
        Extra.ringtones => [for (final r in ringtones) '${r['type']}: ${r['title'] ?? '?'}'].join(' • '),
      };

  /// Asks for the old phone's permissions (popups), then counts everything.
  static Future<ExtrasScan> scan(List<String> storageRoots) async {
    final s = ExtrasScan();
    await [Permission.sms, Permission.phone, Permission.calendarFullAccess].request();
    try {
      final c = await NativeExtras.counts();
      s.sms = (c['sms'] as num).toInt();
      s.mms = (c['mms'] as num).toInt();
      s.calls = (c['calls'] as num).toInt();
      s.calendarEvents = (c['calendarEvents'] as num).toInt();
    } catch (_) {}
    if (s.sms < 0 || s.mms < 0) s.unavailable[Extra.messages] = 'Allow SMS access to include messages';
    if (s.calls < 0) s.unavailable[Extra.calls] = 'Allow call-log access to include call history';
    if (s.calendarEvents < 0) s.unavailable[Extra.calendar] = 'Allow calendar access to include events';
    s.sms = s.sms.clamp(0, 1 << 31);
    s.mms = s.mms.clamp(0, 1 << 31);
    s.calls = s.calls.clamp(0, 1 << 31);
    s.calendarEvents = s.calendarEvents.clamp(0, 1 << 31);

    try {
      for (final a in await NativeExtras.listApps()) {
        final pkg = a['package'] as String;
        final files = <FileEntry>[];
        for (final path in (a['files'] as List).cast<String>()) {
          final st = File(path).statSync();
          if (st.type != FileSystemEntityType.file) continue;
          final name = path.split('/').last;
          files.add(FileEntry(path, 'PhoneClone/Apps/$pkg/$name', st.size, st.modified.millisecondsSinceEpoch, Category.apps));
        }
        if (files.isEmpty) continue;
        s.apps.add(AppInfo(pkg, a['label'] as String? ?? pkg, a['versionName'] as String?,
            (a['versionCode'] as num? ?? 0).toInt(), a['fromPlay'] == true, files));
      }
      s.apps.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    } catch (_) {}

    try {
      s.ringtones = [
        for (final r in await NativeExtras.readRingtones())
          {
            ...r,
            if (r['path'] is String) 'rel': _relativeTo(r['path'] as String, storageRoots),
          },
      ];
    } catch (_) {}

    try {
      s.contactGroups = (await FlutterContacts.groups.getAll()).length;
    } catch (_) {}
    return s;
  }

  static String? _relativeTo(String path, List<String> roots) {
    for (final r in roots) {
      if (path.startsWith('$r/')) return path.substring(r.length + 1);
    }
    return null;
  }
}

/// Group names each contact belongs to (old phone), keyed by contact id.
Future<Map<String, List<String>>> contactGroupNames(List<Contact> contacts) async {
  final out = <String, List<String>>{};
  try {
    if ((await FlutterContacts.groups.getAll()).isEmpty) return out;
    for (final c in contacts) {
      final id = c.id;
      if (id == null) continue;
      final names = [for (final g in await FlutterContacts.groups.getOf(id)) g.name];
      if (names.isNotEmpty) out[id] = names;
    }
  } catch (_) {}
  return out;
}

/// WhatsApp keeps its local chat backup in shared storage; it is copied like any
/// other file, and WhatsApp can restore from it on the new phone.
bool isWhatsAppBackup(String rel) {
  final l = rel.toLowerCase();
  return l.contains('whatsapp') && l.contains('/databases/') && l.contains('msgstore');
}
