import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Calls into MainActivity.kt for the few things Flutter plugins don't cover.
class Native {
  static const _c = MethodChannel('phone_transfer/native');

  static Future<void> keepScreenOn(bool on) async {
    try {
      await _c.invokeMethod('keepScreenOn', on);
    } catch (_) {}
  }

  static Future<int> sdkInt() async => await _c.invokeMethod<int>('sdkInt') ?? 0;

  /// Internal storage first, then any SD cards / USB drives.
  static Future<List<String>> storageRoots() async => await _c.invokeListMethod<String>('storageRoots') ?? [];

  /// Every photo, video and audio file in Android's media index.
  static Future<List<Map>> listMedia() async => await _c.invokeListMethod<Map>('listMedia') ?? [];

  /// Restores the original modified time and tells Android's media index about the file.
  static Future<void> finalizeFile(String path, int mtime) =>
      _c.invokeMethod('finalizeFile', {'path': path, 'mtime': mtime});

  /// Tells Android's media index about many new files at once, without waiting.
  static Future<void> scanFiles(List<String> paths) async {
    if (paths.isEmpty) return;
    try {
      await _c.invokeMethod('scanFiles', {'paths': paths});
    } catch (_) {}
  }

  // ---- background running ----

  /// Starts the foreground service that keeps the transfer alive when the app
  /// is in the background or swiped away. Must be called while the app is visible.
  static Future<void> startBackgroundService(String title, String text, {bool sending = true}) async {
    try {
      await Permission.notification.request();
      await _c.invokeMethod('startService', {'title': title, 'text': text, 'sending': sending});
    } catch (_) {}
  }

  /// [progress] 0–100, or -1 for an indeterminate bar.
  static Future<void> updateNotification(String title, String text, int progress) async {
    try {
      await _c.invokeMethod('updateNotification', {'title': title, 'text': text, 'progress': progress});
    } catch (_) {}
  }

  static Future<void> stopBackgroundService() async {
    try {
      await _c.invokeMethod('stopService');
    } catch (_) {}
  }

  /// Sends the app to the background (like pressing Home) without stopping anything.
  static Future<void> moveToBackground() async {
    try {
      await _c.invokeMethod('moveToBackground');
    } catch (_) {}
  }
}

/// "All files access" is what lets the app see and write every file.
class StoragePermission {
  static Future<bool> granted() async {
    final sdk = await Native.sdkInt();
    if (sdk >= 30) return Permission.manageExternalStorage.isGranted;
    return Permission.storage.isGranted;
  }

  static Future<bool> request() async {
    final sdk = await Native.sdkInt();
    if (sdk >= 30) return (await Permission.manageExternalStorage.request()).isGranted;
    return (await Permission.storage.request()).isGranted;
  }

  /// Read access to Android's media index (photos, videos, audio).
  static Future<void> requestMediaRead() async {
    final sdk = await Native.sdkInt();
    if (sdk >= 33) {
      await [Permission.photos, Permission.videos, Permission.audio].request();
    } else {
      await Permission.storage.request();
    }
  }
}
