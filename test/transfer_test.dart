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
        case 'finalizeFile':
          final a = call.arguments as Map;
          File(a['path'] as String).setLastModifiedSync(DateTime.fromMillisecondsSinceEpoch(a['mtime'] as int));
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
  });

  test('exact copy, old phone untouched, re-runs never duplicate', () async {
    final before = snapshot(oldRoot);
    var r = await startReceiver();
    var (s, plan) = await prepareSender(r);

    // Run 1: everything copied.
    await s.run(plan);
    expect(s.phase, SendPhase.done, reason: '${s.fatalError} ${s.dlq.map((d) => d.lastError)}');
    expect(s.dlq, isEmpty);
    expect(s.filesSent, 9);
    expect(r.savedTotal, 9);

    final expected = Map.of(before)..remove('Android/data/com.app/secret.db');
    expect(snapshot(newRoot), expected, reason: 'same paths, same bytes, same modified times');
    expect(snapshot(oldRoot), before, reason: 'old phone unchanged');

    // Run 2: nothing re-sent.
    await s.run(plan);
    expect(s.filesSent, 0);
    expect(s.filesAlready, 9);
    expect(snapshot(newRoot), expected);

    // Run 3: receiver lost its records (e.g. app reinstalled) -> content check still prevents copies.
    s.dispose();
    await r.stop();
    support.deleteSync(recursive: true);
    support.createSync();
    r = await startReceiver();
    (s, plan) = await prepareSender(r);
    await s.run(plan);
    expect(s.filesSent, 0, reason: 'identical files must not be written again');
    expect(s.filesAlready, 9);
    expect(snapshot(newRoot), expected);

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

  test('stop halfway, then resume: everything arrives exactly once', () async {
    final before = snapshot(oldRoot);
    final r = await startReceiver();
    final (s, plan) = await prepareSender(r);
    void stopEarly() {
      if (s.filesProcessed >= 3) s.cancel();
    }

    s.addListener(stopEarly);
    await s.run(plan);
    s.removeListener(stopEarly);
    expect(s.phase, SendPhase.cancelled);
    final firstRun = s.filesSent;
    expect(firstRun, inInclusiveRange(3, 8));

    await s.run(plan); // "Send again"
    expect(s.phase, SendPhase.done);
    expect(s.filesAlready, firstRun);
    expect(s.filesSent, 9 - firstRun);
    final expected = Map.of(before)..remove('Android/data/com.app/secret.db');
    expect(snapshot(newRoot), expected);
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
    final order = <String>[];
    s.addListener(() {
      final f = s.currentFile;
      if (f != null && (order.isEmpty || order.last != f.rel)) order.add(f.rel);
    });
    await s.run(plan);

    expect(s.phase, SendPhase.done, reason: '${s.fatalError}');
    expect(s.dlq, hasLength(1));
    expect(s.dlq.single.file.rel, 'Download/photos.zip');
    expect(s.dlq.single.status, DlqStatus.recovered);
    expect(s.dlq.single.attempts, 2);
    expect(order.last, 'Download/photos.zip', reason: 'retried after all other files');
    expect(s.failedItems, isEmpty);
    expect(s.filesSent, 9);
    final expected = Map.of(before)..remove('Android/data/com.app/secret.db');
    expect(snapshot(newRoot), expected);
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
      if (f.rel == 'DCIM/Camera/VID_1.mp4' && bytes > 1000000 && pausedAt == 0) {
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
    final expected = Map.of(before)..remove('Android/data/com.app/secret.db');
    expect(snapshot(newRoot), expected, reason: 'the resumed file is byte-for-byte identical');
    s.dispose();
    await r.stop();
  });
}
