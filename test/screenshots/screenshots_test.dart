// Renders the README screenshots from the real app screens, driving two real
// transfers over localhost with sample data (nothing from a real phone).
//
//   SCREENSHOTS=1 flutter test test/screenshots/screenshots_test.dart
//
// Output: docs/screenshots/*.png. Skipped in a normal `flutter test` run.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:phone_transfer/main.dart';
import 'package:phone_transfer/screens/receive_screen.dart';
import 'package:phone_transfer/screens/send_screen.dart';
import 'package:phone_transfer/transfer/extras.dart';
import 'package:phone_transfer/transfer/protocol.dart';
import 'package:phone_transfer/transfer/receiver.dart';
import 'package:phone_transfer/transfer/scanner.dart';
import 'package:phone_transfer/transfer/sender.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  String dir;
  _FakePaths(this.dir);
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

const _fonts = '/opt/sdk/flutter/bin/cache/artifacts/material_fonts';
final _out = Directory('docs/screenshots');

Future<void> _loadFonts() async {
  final roboto = FontLoader('Roboto');
  for (final w in ['Regular', 'Medium', 'Bold']) {
    roboto.addFont(Future.value(ByteData.sublistView(File('$_fonts/Roboto-$w.ttf').readAsBytesSync())));
  }
  await roboto.load();
  final emoji = FontLoader('NotoColorEmoji')
    ..addFont(Future.value(ByteData.sublistView(File('/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf').readAsBytesSync())));
  await emoji.load();
  final symbols = FontLoader('DejaVuSans')
    ..addFont(Future.value(ByteData.sublistView(File('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf').readAsBytesSync())));
  await symbols.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(File('$_fonts/MaterialIcons-Regular.otf').readAsBytesSync())));
  await icons.load();
}

/// A colourful sample "photo".
Future<List<int>> _photo(int seed, {int w = 480, int h = 360}) async {
  final rnd = Random(seed);
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  final hue = rnd.nextDouble() * 360;
  c.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, Offset(w.toDouble(), h.toDouble()), [
        HSVColor.fromAHSV(1, hue, 0.55, 0.95).toColor(),
        HSVColor.fromAHSV(1, (hue + 60) % 360, 0.7, 0.6).toColor(),
      ]),
  );
  for (var i = 0; i < 6; i++) {
    c.drawCircle(Offset(rnd.nextDouble() * w, rnd.nextDouble() * h), 20 + rnd.nextDouble() * 70,
        Paint()..color = Colors.white.withValues(alpha: 0.18 + rnd.nextDouble() * 0.2));
  }
  final img = await rec.endRecording().toImage(w, h);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

void main() {
  final binding = LiveTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  HttpOverrides.global = null;
  ReceiverService.ipLookup = () async => '192.168.1.42';

  testWidgets('README screenshots', (tester) async {
    await _loadFonts();
    _out.createSync(recursive: true);
    await binding.setSurfaceSize(const Size(360, 780)); // a phone screen, in dp
    addTearDown(() => binding.setSurfaceSize(null));

    final tmp = Directory.systemTemp.createTempSync('shots');
    final oldRoot = Directory(p.join(tmp.path, 'old'))..createSync();
    var newRoot = Directory(p.join(tmp.path, 'new1'))..createSync();
    final oldSupport = Directory(p.join(tmp.path, 'old_support'))..createSync();
    var newSupport = Directory(p.join(tmp.path, 'new_support1'))..createSync();
    final paths = _FakePaths(newSupport.path);
    PathProviderPlatform.instance = paths;
    var currentRoot = newRoot.path;

    // ---- sample data on the "old phone" ----
    final photos = <String>[];
    Future<void> make(String rel, List<int> bytes, DateTime mtime) async {
      final f = File(p.join(oldRoot.path, rel))..createSync(recursive: true);
      f.writeAsBytesSync(bytes);
      f.setLastModifiedSync(mtime);
    }

    for (var i = 0; i < 14; i++) {
      final rel = 'DCIM/Camera/IMG_2026${(1101 + i).toString()}_${(90000 + i * 731).toString()}.jpg';
      await make(rel, await _photo(i), DateTime(2026, 10, 1 + i, 9, i));
      photos.add(rel);
    }
    for (var i = 0; i < 4; i++) {
      final rel = 'Pictures/Goa trip 2025/PXL_${20250312 + i}.png';
      await make(rel, await _photo(100 + i), DateTime(2025, 3, 12 + i));
      photos.add(rel);
    }
    await make('DCIM/Camera/VID_20261020.mp4', List.filled(9 * 1024 * 1024, 7), DateTime(2026, 10, 20));
    await make('Music/Recordings/Meeting notes.m4a', List.filled(2 * 1024 * 1024, 3), DateTime(2026, 9, 2));
    await make('Documents/Bills/Electricity March.pdf', List.filled(240 * 1024, 1), DateTime(2026, 3, 30));
    await make('Documents/Work/Budget 2026.xlsx', List.filled(80 * 1024, 2), DateTime(2026, 1, 5));
    await make('Documents/Work/Roadmap.pptx', List.filled(1400 * 1024, 4), DateTime(2026, 2, 9));
    await make('Download/Aadhaar update form.pdf', List.filled(130 * 1024, 5), DateTime(2026, 6, 1));
    await make('Download/photos-backup.zip', List.filled(6 * 1024 * 1024, 6), DateTime(2026, 7, 7));
    await make('WhatsApp/Media/WhatsApp Documents/Ticket.pdf', List.filled(60 * 1024, 8), DateTime(2026, 8, 8));
    await make('Android/data/com.example.game/save.dat', [1, 2, 3], DateTime(2026, 1, 1));
    final apk = p.join(oldRoot.path, 'Download/notes-app.apk');
    await make('Download/notes-app.apk', List.filled(3 * 1024 * 1024, 9), DateTime(2026, 5, 5));

    final contacts = [
      for (final n in ['Amma', 'Papa', 'Rahul Sharma', 'Priya (Office)', 'Dr. Mehta', 'Ankit', 'Sneha', 'Plumber'])
        Contact(displayName: n, name: Name(first: n), phones: [Phone(number: '+9198${n.hashCode.abs() % 100000000}')]),
    ];

    // ---- mocked platform ----
    var defaultSms = false;
    var oldPhoneReadsContacts = false; // the new phone starts with no contacts
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Map page(int after, List<Map> all) {
      final items = [for (final i in all) if ((i['id'] as int) > after) i];
      return {'items': items, 'last': items.isEmpty ? after : items.last['id']};
    }

    final sms = [for (var i = 1; i <= 120; i++) {'id': i, 'address': '+9198000${i % 9}', 'body': 'Message $i', 'date': i, 'type': 1}];
    final calls = [for (var i = 1; i <= 340; i++) {'id': i, 'number': '+9198000${i % 7}', 'date': i, 'duration': i % 60, 'type': 1}];
    messenger.setMockMethodCallHandler(const MethodChannel('phone_transfer/native'), (call) async {
      final a = (call.arguments as Map?) ?? const {};
      Map wrote() {
        final items = (a['items'] ?? a['events']) as List;
        return {'added': items.length, 'existing': 0, 'failed': 0};
      }

      return switch (call.method) {
        'storageRoots' => [currentRoot],
        'listMedia' => [
            for (final rel in photos) {'path': p.join(oldRoot.path, rel), 'kind': 'photo'},
            {'path': p.join(oldRoot.path, 'DCIM/Camera/VID_20261020.mp4'), 'kind': 'video'},
          ],
        'sdkInt' => 34,
        'extrasCounts' => {'sms': 120, 'mms': 0, 'calls': 340, 'calendarEvents': 26},
        'readSms' => page(a['after'] as int, sms),
        'readMms' => page(a['after'] as int, const []),
        'readCalls' => page(a['after'] as int, calls),
        'readCalendar' => {
            'events': [for (var i = 0; i < 26; i++) {'title': 'Event $i', 'dtstart': i, 'dtend': i + 1}],
          },
        'listApps' => [
            {
              'package': 'com.example.notes',
              'label': 'Notes',
              'versionName': '3.2',
              'versionCode': 32,
              'fromPlay': true,
              'files': [apk],
            },
          ],
        'readWallpaper' => a['which'] == 'home' ? Uint8List.fromList(await _photo(7)) : null,
        'readRingtones' => [
            {'type': 'ringtone', 'title': 'Over the Horizon', 'path': null},
            {'type': 'notification', 'title': 'Spaceline', 'path': null},
          ],
        'isDefaultSmsApp' => defaultSms,
        'requestDefaultSmsApp' => defaultSms = true,
        'canWriteSettings' => true,
        'writeSms' || 'writeMms' || 'writeCalls' || 'writeCalendar' => wrote(),
        'setWallpaper' || 'setRingtone' => true,
        'installedVersion' => -1,
        'canInstallApps' => true,
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(const MethodChannel('flutter.baseflow.com/permissions/methods'), (call) async {
      if (call.method == 'checkPermissionStatus') return 1;
      if (call.method == 'requestPermissions') return {for (final x in call.arguments as List) x: 1};
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('flutter_contacts'), (call) async {
      return switch (call.method) {
        'permissions.request' || 'permissions.check' => 'granted',
        'crud.getAll' => oldPhoneReadsContacts ? [for (final c in contacts) c.toJson()] : [],
        'crud.create' => '${Random().nextInt(1 << 30)}',
        'groups.getAll' => [],
        _ => null,
      };
    });

    // ---- helpers ----
    Future<void> wait(int ms) async {
      final end = DateTime.now().add(Duration(milliseconds: ms));
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 16));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    }

    Future<void> until(bool Function() cond, {int timeoutMs = 30000}) async {
      final end = DateTime.now().add(Duration(milliseconds: timeoutMs));
      while (!cond()) {
        if (DateTime.now().isAfter(end)) throw TimeoutException('waiting for screen');
        await wait(100);
      }
      await wait(300);
    }

    Future<void> shot(String name) async {
      await wait(400);
      final ro = tester.renderObject<RenderRepaintBoundary>(find.byKey(const Key('shot')));
      final img = await ro.toImage(pixelRatio: 2);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      File(p.join(_out.path, '$name.png')).writeAsBytesSync(bytes!.buffer.asUint8List());
    }

    Widget app(Widget home) => RepaintBoundary(
          key: const Key('shot'),
          child: MaterialApp(
            key: UniqueKey(), // a fresh navigator for every screen
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              colorSchemeSeed: const Color(0xFF1B6EF3),
              useMaterial3: true,
              fontFamily: 'Roboto',
              fontFamilyFallback: const ['NotoColorEmoji', 'DejaVuSans'],
            ),
            home: home,
          ),
        );

    Future<void> tapText(String text) async {
      final exact = find.text(text);
      await tester.tap(exact.evaluate().isNotEmpty ? exact.last : find.textContaining(text).last);
      await wait(300);
    }

    // ================= 1. New phone (receiving), old phone runs headless =================
    await tester.pumpWidget(app(const ReceiveScreen()));
    await until(() => ReceiverService.debugLatest?.phase == ReceivePhase.waiting);
    final r1 = ReceiverService.debugLatest!;
    await shot('new-01-qr');

    // The old phone (no screen): files, contacts and extras.
    currentRoot = oldRoot.path;
    final scan = await scanDevice();
    final x = await ExtrasScan.scan([oldRoot.path]);
    currentRoot = newRoot.path;
    ReceiverService.debugBeforeReceive = (_) => Future.delayed(const Duration(milliseconds: 260));
    final s1 = SenderService(PairingInfo(host: '127.0.0.1', port: r1.pairing!.port, code: r1.pairing!.code));
    await s1.ping();
    final plan1 = SendPlan([for (final c in Category.values) ...scan.byCategory[c]!, ...x.apps.single.files], contacts,
        extras: Extra.values.toSet(), extrasScan: x);
    final run1 = s1.run(plan1);

    await until(() => r1.pendingPrompt == Extra.messages);
    await shot('new-03-allow-popup');
    await tapText('Allow');
    await until(() => r1.filesProcessed >= 6 && r1.inFlight.isNotEmpty);
    await shot('new-02-receiving');
    await run1;
    ReceiverService.debugBeforeReceive = null;
    await until(() => r1.phase == ReceivePhase.done);
    await shot('new-04-done');
    await tapText('Extras');
    await shot('new-05-extras');
    await tester.drag(find.byType(ListView).last, const Offset(0, -900));
    await shot('new-06-extras-apps');
    await tapText('Files');
    await tapText('Photos');
    await shot('new-07-files');
    s1.dispose();

    // Leave the screen (the service stops and keeps the report).
    await tester.pumpWidget(app(const SizedBox()));
    await wait(500);

    // The new phone later, without the old phone: its snapshot shows the same tabs.
    await tester.pumpWidget(app(const HomeScreen()));
    await until(() => find.textContaining('Last transfer · received').evaluate().isNotEmpty);
    await tapText('Last transfer · received');
    await until(() => find.byTooltip('Export (share)').evaluate().isNotEmpty);
    await shot('snap-new-01-progress');
    await tapText('Extras');
    await tester.drag(find.byType(ListView).last, const Offset(0, -700));
    await shot('snap-new-02-extras');
    await tester.pumpWidget(app(const SizedBox()));
    await wait(300);

    // ================= 2. Old phone (sending), new phone runs headless =================
    newRoot = Directory(p.join(tmp.path, 'new2'))..createSync();
    newSupport = Directory(p.join(tmp.path, 'new_support2'))..createSync();
    paths.dir = newSupport.path;
    currentRoot = newRoot.path;
    defaultSms = false;
    final r2 = ReceiverService();
    await r2.start();
    r2.addListener(() {
      final e = r2.pendingPrompt;
      if (e != null) r2.answerPrompt(e, e != Extra.calls); // "Skip" call history, to show Try again
    });
    paths.dir = oldSupport.path;
    currentRoot = oldRoot.path;
    SendScreen.debugPairing = PairingInfo(host: '192.168.1.42', port: r2.pairing!.port, code: r2.pairing!.code);
    // The QR code says 192.168.1.42; in this test it is really on this machine.
    ReceiverService.ipLookup = () async => '127.0.0.1';
    SendScreen.debugPairing = PairingInfo(host: '127.0.0.1', port: r2.pairing!.port, code: r2.pairing!.code);

    await tester.pumpWidget(app(const SendScreen()));
    await until(() => find.text('Scan QR code').evaluate().isNotEmpty);
    await shot('old-01-connect');
    oldPhoneReadsContacts = true;
    await tapText('Scan QR code');
    await until(() => find.text('Start transfer').evaluate().isNotEmpty);
    oldPhoneReadsContacts = false;
    await shot('old-02-choose');
    await tester.drag(find.byType(ListView).first, const Offset(0, -1150));
    await shot('old-03-choose-extras');
    await tapText('Start transfer');
    ReceiverService.debugBeforeReceive = (_) => Future.delayed(const Duration(milliseconds: 260));
    await until(() => find.textContaining('of 2').evaluate().isNotEmpty || find.text('Pause').evaluate().isNotEmpty);
    await until(() => (r2.filesProcessed >= 5), timeoutMs: 60000);
    await shot('old-04-sending');
    await tapText('Pause');
    await shot('old-05-paused');
    await tapText('Resume');
    ReceiverService.debugBeforeReceive = null;
    await until(() => find.textContaining('Hurray').evaluate().isNotEmpty || find.textContaining('need attention').evaluate().isNotEmpty,
        timeoutMs: 120000);
    await shot('old-06-done');
    await tapText('Files');
    await tapText('Photos');
    await shot('old-07-files');
    await tapText('Folder');
    await shot('old-08-files-by-folder');
    await tapText('Extras');
    await shot('old-09-extras');
    await r2.stop();

    // ================= 3. Home screen and Last transfer (old phone) =================
    await tester.pumpWidget(app(const HomeScreen()));
    await until(() => find.textContaining('Last transfer').evaluate().isNotEmpty);
    await shot('home-01');
    await tapText('Last transfer · sent');
    await until(() => find.byTooltip('Export (share)').evaluate().isNotEmpty);
    await shot('home-02-snapshot-summary');
    await tapText('Files');
    await tapText('Documents');
    await shot('home-03-snapshot-files');
    await tapText('Extras');
    await shot('home-04-snapshot-extras');
    await tester.tap(find.byType(BackButton).first);
    await until(() => find.byType(BackButton).evaluate().isEmpty);
    await tester.tap(find
        .ancestor(of: find.textContaining('napshots'), matching: find.byWidgetPredicate((w) => w is TextButton))
        .first);
    await until(() => find.text('Transfer snapshots').evaluate().isNotEmpty);
    await shot('home-05-snapshots');
  }, skip: Platform.environment['SCREENSHOTS'] == null, timeout: const Timeout(Duration(minutes: 6)));
}
