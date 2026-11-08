import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:phone_transfer/screens/tab_widgets.dart';
import 'package:phone_transfer/transfer/extras.dart';
import 'package:phone_transfer/transfer/protocol.dart';
import 'package:phone_transfer/transfer/receiver.dart';
import 'package:phone_transfer/transfer/scanner.dart';
import 'package:phone_transfer/transfer/session_store.dart';
import 'package:phone_transfer/transfer/sender.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  final String dir;
  _FakePaths(this.dir);
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

/// rel path -> (sha, mtime) for every file under [root]
Map<String, (String, int)> snapshot(Directory root, {bool skipTmp = true}) {
  final out = <String, (String, int)>{};
  for (final e in root.listSync(recursive: true)) {
    if (e is! File) continue;
    final rel = p.relative(e.path, from: root.path);
    if (skipTmp && rel.startsWith('.phonetransfer_tmp')) continue;
    if (rel.startsWith('Documents/Phone Clone/')) continue; // transfer snapshots
    out[rel] = (sha256.convert(e.readAsBytesSync()).toString(), e.lastModifiedSync().millisecondsSinceEpoch);
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // allow real sockets
  ReceiverService.ipLookup = () async => '127.0.0.1';

  late Directory tmp, oldRoot, newRoot, support;
  String currentRoot = '';
  final scanned = <String>[];
  Future<Object?> Function(MethodCall call)? extraNative; // native calls a test wants to answer

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pt');
    oldRoot = Directory(p.join(tmp.path, 'old'))..createSync();
    newRoot = Directory(p.join(tmp.path, 'new'))..createSync();
    support = Directory(p.join(tmp.path, 'support'))..createSync();
    PathProviderPlatform.instance = _FakePaths(support.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('phone_transfer/native'), (call) async {
      switch (call.method) {
        case 'storageRoots':
          return [currentRoot];
        case 'listMedia':
          return [
            {'path': p.join(oldRoot.path, 'DCIM/Camera/IMG_1.jpg'), 'kind': 'photo'},
            {'path': p.join(oldRoot.path, 'DCIM/Camera/VID_1.mp4'), 'kind': 'video'},
            {'path': p.join(oldRoot.path, 'DCIM/Camera/deleted.jpg'), 'kind': 'photo'}, // stale entry
          ];
        case 'scanFiles':
          scanned.addAll(((call.arguments as Map)['paths'] as List).cast<String>());
          return null;
        case 'sdkInt':
          return 34;
        default:
          return extraNative?.call(call);
      }
    });

    void make(String rel, List<int> bytes, DateTime mtime) {
      final f = File(p.join(oldRoot.path, rel))..createSync(recursive: true);
      f.writeAsBytesSync(bytes);
      f.setLastModifiedSync(mtime);
    }

    make('DCIM/Camera/IMG_1.jpg', List.generate(300000, (i) => i % 251), DateTime(2019, 5, 4, 10, 30));
    make('DCIM/Camera/VID_1.mp4', List.generate(2500000, (i) => (i * 7) % 256), DateTime(2020, 1, 2));
    make('Documents/Bills/march.pdf', 'pdf'.codeUnits, DateTime(2021, 3, 1));
    make('Download/setup.apk', List.filled(5000, 3), DateTime(2022, 6, 6));
    make('Download/photos.zip', List.filled(7000, 4), DateTime(2022, 6, 7));
    make('WhatsApp/Media/notes.bin', List.filled(10, 9), DateTime(2023, 1, 1));
    make('Pictures/.thumbnails/t1.jpg', List.filled(10, 1), DateTime(2023, 1, 1));
    make('Music/song.mp3', List.filled(42, 5), DateTime(2018, 8, 8)); // not in media index -> other media
    make('empty.txt', [], DateTime(2017, 1, 1));
    make('Android/data/com.app/secret.db', [1, 2, 3], DateTime(2023, 1, 1)); // must be skipped
  });

  tearDown(() {
    ReceiverService.debugBeforeReceive = null;
    ReceiverService.debugProtocolVersion = kProtocolVersion;
    ReceiverService.ipLookup = () async => '127.0.0.1';
    ReceiverService.senderSilenceLimit = const Duration(seconds: 15);
    scanned.clear();
    extraNative = null;
    tmp.deleteSync(recursive: true);
  });

  Future<ReceiverService> startReceiver() async {
    currentRoot = newRoot.path;
    final r = ReceiverService();
    await r.start();
    expect(r.fatalError, isNull, reason: r.fatalError);
    return r;
  }

  Future<(SenderService, SendPlan)> prepareSender(ReceiverService r) async {
    currentRoot = oldRoot.path;
    final scan = await scanDevice();
    final files = [for (final c in Category.values) ...scan.byCategory[c]!];
    final s = SenderService(PairingInfo(host: '127.0.0.1', port: r.pairing!.port, code: r.pairing!.code))
      ..stallTimeout = const Duration(milliseconds: 600)
      ..retryDelays = const [Duration(milliseconds: 50)];
    await s.ping();
    return (s, SendPlan(files, const []));
  }

  final expectedFromSetup = <String>[];

  Map<String, (String, int)> expectedCopy(Map<String, (String, int)> before) =>
      Map.of(before)..remove('Android/data/com.app/secret.db');

  test('scan finds everything, classifies it, skips private and stale entries', () async {
    currentRoot = oldRoot.path;
    final scan = await scanDevice();
    String rels(Category c) => (scan.byCategory[c]!.map((f) => f.rel).toList()..sort()).join(',');
    expect(rels(Category.photos), 'DCIM/Camera/IMG_1.jpg');
    expect(rels(Category.videos), 'DCIM/Camera/VID_1.mp4');
    expect(rels(Category.documents), 'Documents/Bills/march.pdf,empty.txt');
    expect(rels(Category.apps), 'Download/setup.apk');
    expect(rels(Category.archives), 'Download/photos.zip');
    expect(rels(Category.otherMedia), 'Music/song.mp3');
    expect(rels(Category.otherFiles), 'WhatsApp/Media/notes.bin');
    expect(rels(Category.hidden), 'Pictures/.thumbnails/t1.jpg');
    expect(scan.restricted.map((x) => x.rel), ['Android/data/com.app'], reason: 'shown as restricted, not copied');
    expect(expectedFromSetup, isEmpty);
  });

  test('QR code: a v3 phone can still read it, a newer phone sees the newest version', () {
    final qr = const PairingInfo(host: '10.0.0.2', port: 8765, code: '123456').toQr();
    expect((jsonDecode(qr) as Map)['v'], 3, reason: 'v3 apps only accept v == 3');
    expect(PairingInfo.fromQr(qr)!.version, kProtocolVersion);
    // A QR code from a v3 phone.
    final v3 = jsonEncode({'app': 'phone_transfer', 'v': 3, 'host': 'h', 'port': 1, 'code': '000000'});
    expect(PairingInfo.fromQr(v3)!.version, 3);
  });

  test('exact copy, old phone untouched, re-runs never duplicate', () async {
    final before = snapshot(oldRoot);
    var r = await startReceiver();
    var (s, plan) = await prepareSender(r);

    // Run 1: everything copied.
    await s.run(plan);
    expect(s.phase, SendPhase.done, reason: '${s.fatalError} ${s.dlq.map((d) => d.lastError)}');
    expect(s.fastMode, isTrue);
    expect(s.dlq, isEmpty);
    expect(s.filesSent, 9);
    expect(r.savedTotal, 9);
    expect(snapshot(newRoot), expectedCopy(before), reason: 'same paths, same bytes, same modified times');
    expect(snapshot(oldRoot), before, reason: 'old phone unchanged');
    expect(scanned, hasLength(9), reason: 'media index told about every file, in batches');

    // Run 2: nothing re-sent.
    await s.run(plan);
    expect(s.filesSent, 0);
    expect(s.filesAlready, 9);
    expect(snapshot(newRoot), expectedCopy(before));

    // Run 3: receiver lost its records (e.g. app data cleared) -> content check still prevents copies.
    s.dispose();
    await r.stop();
    support.deleteSync(recursive: true);
    support.createSync();
    r = await startReceiver();
    (s, plan) = await prepareSender(r);
    await s.run(plan);
    expect(r.bytesReceived, 0, reason: 'found on disk by name, size and date: nothing is sent again');
    expect(s.filesSent, 0, reason: 'identical files must not be written again');
    expect(s.filesAlready, 9);
    expect(snapshot(newRoot), expectedCopy(before));

    // A DIFFERENT file with the same name already on the new phone is kept, and ours is saved beside it.
    File(p.join(newRoot.path, 'Documents/Bills/march.pdf')).writeAsStringSync('someone else');
    support.deleteSync(recursive: true);
    support.createSync();
    s.dispose();
    await r.stop();
    r = await startReceiver();
    (s, plan) = await prepareSender(r);
    await s.run(plan);
    expect(File(p.join(newRoot.path, 'Documents/Bills/march.pdf')).readAsStringSync(), 'someone else');
    expect(File(p.join(newRoot.path, 'Documents/Bills/march (1).pdf')).readAsStringSync(), 'pdf');
    expect(s.filesSent, 1);
    expect(snapshot(oldRoot), before, reason: 'old phone still unchanged');
    s.dispose();
    await r.stop();
  });

  test('stop halfway, then continue: everything arrives exactly once', () async {
    final before = snapshot(oldRoot);
    final r = await startReceiver();
    final (s, plan) = await prepareSender(r);
    s.debugOnChunk = (sender, f, bytes) {
      if (f.rel == 'DCIM/Camera/VID_1.mp4' && bytes > 2000000) sender.cancel();
    };
    await s.run(plan);
    expect(s.phase, SendPhase.cancelled);

    s.debugOnChunk = null;
    await s.run(plan); // "Continue"
    expect(s.phase, SendPhase.done);
    expect(s.filesSent + s.filesAlready, 9);
    expect(s.dlq, isEmpty);
    expect(snapshot(newRoot), expectedCopy(before));
    expect(newRoot.listSync(recursive: true).where((e) => e.path.contains(' (1)')), isEmpty);
    s.dispose();
    await r.stop();
  });

  test('a file that stalls is skipped, queued, and recovered after the others', () async {
    final before = snapshot(oldRoot);
    var stalled = false;
    ReceiverService.debugBeforeReceive = (name) async {
      if (name == 'Download/photos.zip' && !stalled) {
        stalled = true;
        await Future.delayed(const Duration(seconds: 2)); // no progress -> sender times out
      }
    };
    final r = await startReceiver();
    final (s, plan) = await prepareSender(r);
    await s.run(plan);

    expect(s.phase, SendPhase.done, reason: '${s.fatalError}');
    expect(s.dlq, hasLength(1));
    expect(s.dlq.single.file.rel, 'Download/photos.zip');
    expect(s.dlq.single.lastError, contains('Timed out'));
    expect(s.dlq.single.status, DlqStatus.recovered);
    expect(s.dlq.single.attempts, 2);
    // ignore: avoid_print
    print('RECENT: ${s.recent.map((r) => r.rel).toList()}');
    expect(s.recent.first.rel, 'Download/photos.zip', reason: 'retried after all other files');
    expect(s.failedItems, isEmpty);
    expect(s.filesSent + s.filesAlready, 9);
    expect(snapshot(newRoot), expectedCopy(before));
    expect(r.complete, isTrue);
    s.dispose();
    await r.stop();
  });

  test('a file that keeps failing ends up in the final list with its path and error', () async {
    final r = await startReceiver();
    final (s, plan) = await prepareSender(r);
    s.maxAttempts = 3;
    File(p.join(oldRoot.path, 'Download/setup.apk')).deleteSync(); // vanished after the scan
    await s.run(plan);

    expect(s.phase, SendPhase.done);
    expect(s.filesSent, 8);
    expect(s.failedItems, hasLength(1));
    final failed = s.failedItems.single;
    expect(failed.file.path, p.join(oldRoot.path, 'Download/setup.apk'));
    expect(failed.attempts, 3);
    expect(failed.lastError, contains('Could not read the file'));
    expect(s.tally[Category.apps]!.failed, 1);
    expect(r.complete, isFalse);
    expect(r.finalFailures.single['rel'], 'Download/setup.apk');
    s.dispose();
    await r.stop();
  });

  test('pause in the middle of a file, resume, and it continues from the same byte', () async {
    final before = snapshot(oldRoot);
    final r = await startReceiver();
    final (s, plan) = await prepareSender(r);
    var pausedAt = 0;
    var sawPausedState = false;
    s.debugOnChunk = (sender, f, bytes) {
      if (f.rel == 'DCIM/Camera/VID_1.mp4' && bytes > 2000000 && pausedAt == 0) {
        pausedAt = bytes;
        sender.pause();
        Future.delayed(const Duration(milliseconds: 1500), () {
          sawPausedState = sender.paused;
          sender.resume();
        });
      }
    };
    await s.run(plan);

    expect(pausedAt, greaterThan(0));
    expect(sawPausedState, isTrue, reason: 'stays paused until Resume (no timeout while paused)');
    expect(s.phase, SendPhase.done);
    expect(s.dlq, isEmpty, reason: 'pausing is not a failure');
    expect(s.resumedBytes, greaterThan(0), reason: 'continued from the bytes already received');
    expect(snapshot(newRoot), expectedCopy(before), reason: 'the resumed file is byte-for-byte identical');
    expect(s.filesAlready, 0, reason: 'files copied before the pause count as copied, not "already there"');
    expect(r.alreadyTotal, 0);
    s.dispose();
    await r.stop();
  });

  test('v4 speed: parallel lanes, batches of small files, identical content sent once', () async {
    void make(String rel, List<int> bytes, DateTime mtime) {
      final f = File(p.join(oldRoot.path, rel))..createSync(recursive: true);
      f.writeAsBytesSync(bytes);
      f.setLastModifiedSync(mtime);
    }

    for (var i = 0; i < 450; i++) {
      make('Documents/Many/note_$i.txt', utf8.encode('note $i ' * (i % 50 + 1)), DateTime(2022, 1, 1, 0, i % 60));
    }
    final dupBytes = List.generate(200000, (i) => (i * 13) % 256);
    make('WhatsApp/Media/Images/IMG-2024.jpg', dupBytes, DateTime(2024, 2, 2));
    make('Pictures/Backup/IMG-2024.jpg', dupBytes, DateTime(2024, 2, 3));
    make('Movies/clip_a.mp4', List.generate(3000000, (i) => (i * 3) % 256), DateTime(2021, 7, 7));
    make('Movies/clip_b.mp4', List.generate(3500000, (i) => (i * 5) % 256), DateTime(2021, 7, 8));

    final before = snapshot(oldRoot);
    final r = await startReceiver();
    final (s, plan) = await prepareSender(r);
    var maxLanes = 0;
    s.addListener(() => maxLanes = s.lanes.length > maxLanes ? s.lanes.length : maxLanes);
    await s.run(plan);

    expect(s.phase, SendPhase.done, reason: '${s.fatalError} ${s.dlq.map((d) => d.lastError)}');
    expect(s.dlq, isEmpty);
    expect(s.filesSent, plan.files.length);
    expect(s.batchesSent, greaterThanOrEqualTo(2), reason: '450+ small files go in batches of up to 300');
    expect(s.clonedFiles, 1, reason: 'the second identical picture is copied on the new phone');
    expect(s.dupCheckTotalFiles, 2);
    expect(s.dupCheckDoneFiles, 2, reason: 'identical-file check reports its progress');
    expect(s.dupCheckDoneBytes, s.dupCheckTotalBytes);
    expect(r.clonedFiles, 1);
    expect(maxLanes, greaterThanOrEqualTo(2), reason: 'several files in flight at once');
    expect(snapshot(newRoot), expectedCopy(before), reason: 'every file exact, including the cloned one');
    expect(snapshot(oldRoot), before);
    s.dispose();
    await r.stop();
  });

  test('update from v3: half-sent file and old index records are picked up, nothing re-sent', () async {
    // What the v3 (and v2) app left behind on the new phone.
    currentRoot = oldRoot.path;
    final scan = await scanDevice();
    final vid = scan.byCategory[Category.videos]!.single;
    final img = scan.byCategory[Category.photos]!.single;
    final tmpDir = Directory(p.join(newRoot.path, '.phonetransfer_tmp'))..createSync(recursive: true);
    final vidBytes = File(vid.path).readAsBytesSync();
    final partId = sha1.convert(utf8.encode(vid.key)).toString();
    File(p.join(tmpDir.path, '$partId.part')).writeAsBytesSync(vidBytes.sublist(0, 1000000));
    final imgCopy = File(p.join(newRoot.path, img.rel))..createSync(recursive: true);
    File(img.path).copySync(imgCopy.path);
    imgCopy.setLastModifiedSync(DateTime.fromMillisecondsSinceEpoch(img.mtime));
    File(p.join(support.path, 'received_v2.jsonl')).writeAsStringSync('${jsonEncode({
          'key': img.key,
          'path': imgCopy.path,
          'sha': sha256.convert(File(img.path).readAsBytesSync()).toString(),
        })}\n');

    final before = snapshot(oldRoot);
    final r = await startReceiver(); // the v4 app, after the update
    final (s, plan) = await prepareSender(r);
    await s.run(plan);

    expect(s.phase, SendPhase.done);
    expect(s.filesAlready, 1, reason: 'the photo recorded by the older app is skipped');
    expect(s.filesSent, 8);
    expect(s.resumedBytes, 1000000, reason: 'the video continues from the byte v3 stopped at');
    expect(snapshot(newRoot), expectedCopy(before));
    expect(newRoot.listSync(recursive: true).where((e) => e.path.contains(' (1)')), isEmpty);
    s.dispose();
    await r.stop();
  });

  test('new phone still on v3: v4 falls back to one file at a time and still works', () async {
    ReceiverService.debugProtocolVersion = 3;
    final before = snapshot(oldRoot);
    final r = await startReceiver();
    final (s, plan) = await prepareSender(r);
    var maxLanes = 0;
    s.addListener(() => maxLanes = s.lanes.length > maxLanes ? s.lanes.length : maxLanes);
    await s.run(plan);

    expect(s.fastMode, isFalse);
    expect(s.phase, SendPhase.done);
    expect(s.filesSent, 9);
    expect(s.batchesSent, 0);
    expect(maxLanes, 1);
    expect(snapshot(newRoot), expectedCopy(before));
    s.dispose();
    await r.stop();
  });

  test('old phone vanishes, new phone address changes: lost view, fresh QR, same code, transfer completes', () async {
    final before = snapshot(oldRoot);
    ReceiverService.senderSilenceLimit = const Duration(milliseconds: 600);
    final r = await startReceiver();
    final code = r.pairing!.code;
    final (s1, plan) = await prepareSender(r);
    s1.debugOnChunk = (sender, f, bytes) {
      if (f.rel == 'DCIM/Camera/VID_1.mp4' && bytes > 2000000) sender.cancel(); // battery dies mid-file
    };
    // Simulate the battery dying: the old phone stops abruptly, without telling the new phone.
    s1.debugSkipDone = true;
    await s1.run(plan);
    s1.dispose();
    expect(r.phase, ReceivePhase.receiving);

    // Hotspot restarted: the new phone gets a different address.
    ReceiverService.ipLookup = () async => '127.0.0.2';
    await r.refreshAddress();
    await Future.delayed(const Duration(milliseconds: 1600));
    expect(r.senderLost, isTrue, reason: 'screen switches to "connection lost" with the QR code');
    expect(r.addressChanged, isTrue);
    expect(r.pairing!.host, '127.0.0.2', reason: 'QR shows the new address');
    expect(r.pairing!.code, code, reason: 'same pairing code');
    expect(PairingInfo.fromQr(r.pairing!.toQr())!.host, '127.0.0.2');

    // The old phone scans the fresh QR (127.0.0.2 also reaches this test machine) and continues.
    final s2 = SenderService(PairingInfo.fromQr(r.pairing!.toQr())!)
      ..stallTimeout = const Duration(milliseconds: 600)
      ..retryDelays = const [Duration(milliseconds: 50)];
    await s2.ping();
    await s2.run(plan);
    expect(s2.phase, SendPhase.done);
    expect(r.senderLost, isFalse);
    expect(r.addressChanged, isFalse);
    expect(s2.resumedBytes, greaterThan(0), reason: 'the interrupted video continues');
    expect(snapshot(newRoot), expectedCopy(before));
    s2.dispose();
    await r.stop();
  });

  test('two senders at once: the second is turned away, progress never jumps around', () async {
    final before = snapshot(oldRoot);
    final r = await startReceiver();
    final (s1, plan) = await prepareSender(r);
    final seen = <int>[];
    var firstRunning = true;
    r.addListener(() {
      final b = r.sender['bytesDone'];
      if (firstRunning && b is int) seen.add(b);
    });
    // Slow the first transfer down a little so the second one arrives while it runs.
    s1.debugOnChunk = (sender, f, bytes) {};
    ReceiverService.debugBeforeReceive = (name) => Future.delayed(const Duration(milliseconds: 150));
    final first = s1.run(plan).whenComplete(() => firstRunning = false);
    while (r.phase != ReceivePhase.receiving) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    // e.g. the older app, or an earlier transfer still running in the background
    final s2 = SenderService(PairingInfo(host: '127.0.0.1', port: r.pairing!.port, code: r.pairing!.code))
      ..debugActAsOtherApp = true;
    await s2.ping();
    await s2.run(plan);
    expect(r.refusedRequests, greaterThan(0), reason: 'the second sender was turned away while the first ran');
    if (s2.phase == SendPhase.error) {
      expect(s2.fatalError, contains('Another transfer is already sending'));
    } else {
      // It waited until the first finished, then found everything already there.
      expect(s2.phase, SendPhase.done);
      expect(s2.filesSent, 0);
    }

    await first;
    expect(s1.phase, SendPhase.done, reason: 'the first transfer is not disturbed');
    expect(snapshot(newRoot), expectedCopy(before));
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i], greaterThanOrEqualTo(seen[i - 1]), reason: 'progress on the new phone never goes backwards');
    }
    s1.dispose();
    s2.dispose();
    await r.stop();
  });

  test('v5 extras: messages, calls, calendar, apps, wallpaper, ringtone; popup on the new phone; Files tab outcomes',
      () async {
    // Answers both phones' native calls (they share one process in tests).
    var defaultSms = false;
    final written = <String, List>{};
    final wallpapers = <String>[];
    final ringtones = <String?>[];
    Map page(int after, List<Map> all) {
      final items = [for (final i in all) if ((i['id'] as int) > after) i];
      return {'items': items, 'last': items.isEmpty ? after : items.last['id']};
    }

    final sms = [
      {'id': 1, 'address': '+911', 'body': 'hi', 'date': 1, 'type': 1},
      {'id': 2, 'address': '+912', 'body': 'yo', 'date': 2, 'type': 2},
    ];
    final calls = [
      {'id': 1, 'number': '+911', 'date': 10, 'duration': 5, 'type': 1},
      {'id': 2, 'number': '+913', 'date': 11, 'duration': 0, 'type': 3},
    ];
    extraNative = (call) async {
      final a = (call.arguments as Map?) ?? const {};
      Map wrote(String k) {
        final items = (a['items'] ?? a['events']) as List;
        written.putIfAbsent(k, () => []).addAll(items);
        return {'added': items.length, 'existing': 0, 'failed': 0};
      }

      return switch (call.method) {
        'extrasCounts' => {'sms': 2, 'mms': 0, 'calls': 2, 'calendarEvents': 1},
        'readSms' => page(a['after'] as int, sms),
        'readMms' => page(a['after'] as int, const []),
        'readCalls' => page(a['after'] as int, calls),
        'readCalendar' => {
            'events': [
              {'title': 'Birthday', 'dtstart': 100, 'dtend': 200},
            ],
          },
        'listApps' => [
            {
              'package': 'com.example.x',
              'label': 'X',
              'versionName': '1.0',
              'versionCode': 3,
              'fromPlay': true,
              'files': [p.join(oldRoot.path, 'Download/setup.apk')],
            },
          ],
        'readWallpaper' => a['which'] == 'home' ? Uint8List.fromList([1, 2, 3]) : null,
        'readRingtones' => [
            {'type': 'ringtone', 'title': 'Song', 'path': p.join(oldRoot.path, 'Music/song.mp3')},
          ],
        'isDefaultSmsApp' => defaultSms,
        'requestDefaultSmsApp' => defaultSms = true,
        'canWriteSettings' => true,
        'writeSms' => wrote('sms'),
        'writeMms' => wrote('mms'),
        'writeCalls' => wrote('calls'),
        'writeCalendar' => wrote('calendar'),
        'setWallpaper' => () {
            wallpapers.add(a['which'] as String);
            return true;
          }(),
        'setRingtone' => () {
            ringtones.add(a['path'] as String?);
            return true;
          }(),
        'installedVersion' => -1,
        _ => null,
      };
    };
    // Every runtime permission is granted.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/permissions/methods'), (call) async {
      if (call.method == 'checkPermissionStatus') return 1;
      if (call.method == 'requestPermissions') return {for (final x in call.arguments as List) x: 1};
      return null;
    });

    var r = await startReceiver();
    // The new phone asks before restoring messages (default-SMS role). The user first
    // taps "Skip", then changes their mind and taps "Try again" on the old phone.
    final asked = <Extra>[];
    var answering = false;
    r.addListener(() {
      final e = r.pendingPrompt;
      if (e != null && !answering) {
        answering = true;
        asked.add(e);
        r.answerPrompt(e, asked.length > 1).whenComplete(() => answering = false);
      }
    });
    var (s, base) = await prepareSender(r);
    currentRoot = oldRoot.path;
    final x = await ExtrasScan.scan([oldRoot.path]);
    expect(x.count(Extra.messages), 2);
    expect(x.apps.single.files.single.rel, 'PhoneClone/Apps/com.example.x/setup.apk');
    final plan = SendPlan([...base.files, ...x.apps.single.files], const [],
        extras: Extra.values.toSet(), extrasScan: x);

    await s.run(plan);
    expect(s.phase, SendPhase.done, reason: '${s.fatalError}');
    expect(asked, [Extra.messages], reason: 'only what is not yet allowed is asked for');
    expect(s.extraTally[Extra.messages]!.state, 'skipped');
    expect(r.extraTally[Extra.messages]!.state, 'skipped', reason: 'both phones agree');
    expect(written['sms'], isNull);
    for (final e in [Extra.calendar, Extra.calls, Extra.apps, Extra.wallpaper, Extra.ringtones]) {
      expect(r.extraTally[e]!.state, 'done', reason: '$e: no spinner left on the new phone');
      expect(s.extraTally[e]!.state, 'done', reason: '$e on the old phone');
    }

    // "Try again" after the transfer: asked again, allowed this time.
    await s.retryExtra(Extra.messages);
    expect(asked, [Extra.messages, Extra.messages]);
    expect(s.extraTally[Extra.messages]!.state, 'done');
    expect(r.extraTally[Extra.messages]!.state, 'done');
    expect(written['calendar'], hasLength(1));
    expect(written['calls'], hasLength(2));
    expect(written['sms'], hasLength(2));
    expect(r.extraTally[Extra.calls]!.added, 2);
    expect(r.extraTally[Extra.messages]!.added, 2);
    expect(r.smsRoleToHandBack, isTrue, reason: 'offers to give the SMS role back');
    expect(s.extraTally[Extra.messages]!.added, 2);
    expect(s.extraTally[Extra.calendar]!.state, 'done');
    expect(wallpapers, ['home']);
    expect(ringtones, [p.join(newRoot.path, 'Music/song.mp3')], reason: 'the copied file becomes the ringtone');
    expect(r.apps.single.paths.single, p.join(newRoot.path, 'PhoneClone/Apps/com.example.x/setup.apk'));
    expect(File(r.apps.single.paths.single).readAsBytesSync(), File(p.join(oldRoot.path, 'Download/setup.apk')).readAsBytesSync());

    // Files tab: every chosen file, compared with the new phone.
    expect(s.outcomes, hasLength(plan.files.length));
    expect(s.outcomes.values.every((o) => o.onNewPhone), isTrue, reason: '${s.outcomes.values.map((o) => o.status)}');
    expect(r.sessionFiles.map((f) => f.rel).toSet(), {for (final f in plan.files) f.rel});

    // The new phone keeps a report for the home screen's "Last transfer" card.
    final report = await TransferReport.load();
    expect(report, isNotNull);
    expect(report!.sent, isFalse);
    expect(report.files, hasLength(plan.files.length));
    expect(report.onNewPhone, plan.files.length);
    // It's a full snapshot (Progress, Files, Extras) in Documents/Phone Clone/Snapshots.
    expect(report.path, contains('Documents/Phone Clone/Snapshots/Phone Clone - Received '));
    expect(report.rows.map((x) => x.label), contains('Call history'));
    expect(report.extras[Extra.calls.name]!['added'], 2);
    expect(report.apps.single.package, 'com.example.x');
    // Export / import: the same snapshot imported again is kept once; other files are refused.
    final bytes = File(report.path!).readAsBytesSync();
    final again = await TransferReport.import(bytes);
    expect(again!.path, report.path);
    expect(await TransferReport.import('{"hello": 1}'.codeUnits), isNull);
    expect((await TransferReport.all()).where((x) => !x.sent), hasLength(1));
    // Shared from another phone: imported as a new file, never overwriting one that's here.
    File(report.path!).deleteSync();
    final imported = await TransferReport.import(bytes);
    expect(imported, isNotNull);
    expect(File(imported!.path!).readAsBytesSync().length, bytes.length);

    // Again: nothing new; the Files tab shows "already there".
    await s.run(plan);
    expect(s.outcomes.values.map((o) => o.status).toSet(), {'already'});
    expect(r.sessionFiles, hasLength(plan.files.length), reason: 'the new phone lists them too');
    // Files already there from the first run still count: apps are ready to install, and
    // both phones show exactly the same numbers for every extra.
    expect(r.apps, hasLength(1));
    expect(r.extraTally[Extra.apps]!.added, 1);
    for (final e in Extra.values) {
      final a = s.extraTally[e]!, b = r.extraTally[e]!;
      expect([a.added, a.existing, a.failed, a.state], [b.added, b.existing, b.failed, b.state], reason: '$e');
    }
    expect(r.sessionFiles.map((f) => f.status).toSet(), {'already'});
    expect(r.sessionFiles.every((f) => File(f.path).existsSync()), isTrue, reason: 'with their place on this phone');

    // The new phone's app was closed and opened again (or reinstalled): files from before
    // are found on disk, so the apps are still ready to install and both phones agree.
    s.dispose();
    await r.stop();
    r = await startReceiver();
    r.addListener(() {
      final e = r.pendingPrompt;
      if (e != null && !answering) {
        answering = true;
        r.answerPrompt(e, true).whenComplete(() => answering = false);
      }
    });
    s = (await prepareSender(r)).$1;
    await s.run(plan);
    expect(s.phase, SendPhase.done);
    expect(r.apps, hasLength(1), reason: 'installer found on disk from the earlier transfer');
    for (final e in Extra.values) {
      final a = s.extraTally[e]!, b = r.extraTally[e]!;
      expect([a.added, a.existing, a.failed, a.state], [b.added, b.existing, b.failed, b.state], reason: '$e after restart');
    }
    expect(ringtones.last, p.join(newRoot.path, 'Music/song.mp3'), reason: 'ringtone file found on disk too');

    // A new phone that is still on v4 just skips the extras.
    s.dispose();
    await r.stop();
    ReceiverService.debugProtocolVersion = 4;
    final r4 = await startReceiver();
    final (s4, _) = await prepareSender(r4);
    await s4.run(plan);
    expect(s4.phase, SendPhase.done);
    expect(s4.extraTally[Extra.calls]!.state, 'skipped');
    s4.dispose();
    await r4.stop();
  });

  testWidgets('Files tab: grouped by type, folder and status, with filters', (tester) async {
    final rows = [
      const FileRow('DCIM/Camera/a.jpg', 10, 'sent', category: Category.photos),
      const FileRow('DCIM/Camera/b.jpg', 10, 'already', category: Category.photos),
      const FileRow('Documents/x.pdf', 10, 'failed', error: 'boom', category: Category.documents),
      const FileRow('Download/y.zip', 10, 'waiting', category: Category.archives),
      const FileRow('Android/data/com.app', 0, 'restricted', error: 'App-private storage'),
    ];
    tester.view.physicalSize = const Size(1080, 2340); // a phone screen, 360 dp wide
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: FileCompareList(rows: rows))));
    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('Restricted by Android'), findsOneWidget);
    expect(find.text('2/2'), findsOneWidget, reason: 'both photos are on the new phone');
    await tester.tap(find.text('Photos'));
    await tester.pump();
    expect(find.text('a.jpg'), findsOneWidget);

    await tester.tap(find.text('Folder'));
    await tester.pump();
    expect(find.text('DCIM'), findsOneWidget);
    expect(find.text('Android/data'), findsOneWidget);

    await tester.tap(find.text('Status'));
    await tester.pump();
    expect(find.text('Failed'), findsWidgets);
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Restricted 1'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Restricted 1'));
    await tester.pump();
    expect(find.text('com.app'), findsOneWidget, reason: 'single group opens by itself');
    expect(tester.takeException(), isNull);
  });

  test('the version shown in the app matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final v = RegExp(r'^version: ([^+\s]+)', multiLine: true).firstMatch(pubspec)!.group(1);
    expect(kAppVersion, v);
  });

  testWidgets('Files tab: tap a file to open it in the phone\'s own app; folders open in the Files app', (tester) async {
    final calls = <String>[];
    extraNative = (call) async {
      calls.add('${call.method} ${(call.arguments as Map).values.first}');
      return call.method == 'openFile' ? 'ok' : true;
    };
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    const rows = [
      FileRow('Documents/x.pdf', 10, 'sent', category: Category.documents, path: '/storage/emulated/0/Documents/x.pdf'),
      FileRow('Download/y.zip', 10, 'waiting', category: Category.archives),
    ];
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: FileCompareList(rows: rows))));
    await tester.tap(find.text('Documents'));
    await tester.pump();
    await tester.tap(find.text('x.pdf'));
    await tester.pump();
    expect(calls, ['openFile /storage/emulated/0/Documents/x.pdf']);
    await tester.tap(find.byTooltip('Open').first);
    await tester.pump();
    await tester.tap(find.byTooltip('Show in Files app').first);
    await tester.pump();
    expect(calls.sublist(1), ['openFile /storage/emulated/0/Documents/x.pdf', 'openFilesApp /storage/emulated/0/Documents']);

    await tester.tap(find.text('Archives'));
    await tester.pump();
    await tester.tap(find.text('y.zip'));
    await tester.pump();
    expect(find.text('This file isn’t on this phone yet.'), findsOneWidget);

    await tester.tap(find.text('Folder'));
    await tester.pump();
    await tester.tap(find.byTooltip('Open this folder in the Files app').first);
    await tester.pump();
    expect(calls.last, 'openFilesApp Documents');
  });
}
