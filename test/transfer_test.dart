import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:phone_transfer/transfer/protocol.dart';
import 'package:phone_transfer/transfer/receiver.dart';
import 'package:phone_transfer/transfer/scanner.dart';
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
          return null;
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
    expect(expectedFromSetup, isEmpty);
  });

  test('QR code: a v3 phone can still read it, a v4 phone sees v4', () {
    final qr = const PairingInfo(host: '10.0.0.2', port: 8765, code: '123456').toQr();
    expect((jsonDecode(qr) as Map)['v'], 3, reason: 'v3 apps only accept v == 3');
    expect(PairingInfo.fromQr(qr)!.version, 4);
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
}
