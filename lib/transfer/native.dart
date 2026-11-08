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

/// Messages, call history, calendar, apps, wallpaper and ringtones (ExtrasBridge.kt).
class NativeExtras {
  static const _c = MethodChannel('phone_transfer/native');

  static Map<String, dynamic> _map(Object? v) => (v as Map).cast<String, dynamic>();
  static List<Map<String, dynamic>> _list(Object? v) =>
      [for (final e in (v as List? ?? const [])) (e as Map).cast<String, dynamic>()];

  // ---- old phone: reading ----
  static Future<Map<String, dynamic>> counts() async => _map(await _c.invokeMethod('extrasCounts'));

  /// A page of records after record id [after]: {items: [...], last: id}.
  static Future<Map<String, dynamic>> readPage(String what, int after, int limit) async =>
      _map(await _c.invokeMethod(what, {'after': after, 'limit': limit}));

  static Future<List<Map<String, dynamic>>> readCalendarEvents() async =>
      _list(_map(await _c.invokeMethod('readCalendar'))['events']);
  static Future<List<Map<String, dynamic>>> listApps() async => _list(await _c.invokeMethod('listApps'));
  static Future<Uint8List?> readWallpaper({required bool lock}) =>
      _c.invokeMethod<Uint8List>('readWallpaper', {'which': lock ? 'lock' : 'home'});
  static Future<List<Map<String, dynamic>>> readRingtones() async => _list(await _c.invokeMethod('readRingtones'));

  // ---- new phone: writing ----
  /// {added, existing, failed}
  static Future<Map<String, dynamic>> write(String what, Map<String, Object?> args) async =>
      _map(await _c.invokeMethod(what, args));

  static Future<bool> isDefaultSmsApp() async => await _c.invokeMethod<bool>('isDefaultSmsApp') ?? false;
  static Future<bool> requestDefaultSmsApp() async => await _c.invokeMethod<bool>('requestDefaultSmsApp') ?? false;
  static Future<void> restoreDefaultSmsApp() => _c.invokeMethod('restoreDefaultSmsApp');

  static Future<bool> canWriteSettings() async => await _c.invokeMethod<bool>('canWriteSettings') ?? false;
  static Future<void> openWriteSettings() => _c.invokeMethod('openWriteSettings');
  static Future<bool> setRingtone(String type, String? path, String? title) async =>
      await _c.invokeMethod<bool>('setRingtone', {'type': type, 'path': path, 'title': title}) ?? false;

  static Future<bool> setWallpaper(Uint8List bytes, {required bool lock}) async =>
      await _c.invokeMethod<bool>('setWallpaper', {'bytes': bytes, 'which': lock ? 'lock' : 'home'}) ?? false;

  static Future<int> installedVersion(String package) async =>
      await _c.invokeMethod<int>('installedVersion', {'package': package}) ?? -1;
  static Future<bool> canInstallApps() async => await _c.invokeMethod<bool>('canInstallApps') ?? false;
  static Future<void> openInstallPermission() => _c.invokeMethod('openInstallPermission');

  /// Installs one app; Android shows its own confirmation. Returns (ok, message).
  static Future<(bool, String?)> installApks(List<String> paths) async {
    final r = _map(await _c.invokeMethod('installApks', {'paths': paths}));
    return (r['ok'] == true, r['message'] as String?);
  }

  // ---- open in the phone's own apps ----
  /// "ok", "noApp" (nothing installed can open it) or "notHere" (not a file on this phone).
  static Future<String> openFile(String path) async =>
      await _c.invokeMethod<String>('openFile', {'path': path}) ?? 'noApp';

  /// Opens the phone's Files app, at [folder] (e.g. "DCIM/Camera") where the phone allows it.
  static Future<bool> openFilesApp([String? folder]) async =>
      await _c.invokeMethod<bool>('openFilesApp', {'folder': folder}) ?? false;

  /// Android's share sheet for a file (save to Drive, send by email, …).
  static Future<bool> shareFile(String path, {String? title}) async =>
      await _c.invokeMethod<bool>('shareFile', {'path': path, 'title': title}) ?? false;

  /// Lets the user pick a file. Returns its name and bytes, or null if cancelled.
  static Future<(String?, Uint8List)?> pickFile() async {
    final r = await _c.invokeMethod<Map>('pickFile');
    if (r == null) return null;
    return (r['name'] as String?, r['bytes'] as Uint8List);
  }

  /// Opens the phone's Files app in the folder that holds [path] (an absolute file path).
  static Future<bool> showInFilesApp(String path) async {
    final i = path.lastIndexOf('/');
    return await _c.invokeMethod<bool>('openFilesApp', {'dir': i <= 0 ? path : path.substring(0, i)}) ?? false;
  }

  // ---- thumbnails (both phones) ----
  /// {package, label, versionName, icon (PNG)} from an APK file, or null for a split part.
  static Future<Map<String, dynamic>?> apkMeta(String path) async {
    final v = await _c.invokeMethod('apkMeta', {'path': path});
    return v == null ? null : _map(v);
  }

  static Future<Uint8List?> appIcon(String package) => _c.invokeMethod<Uint8List>('appIcon', {'package': package});
  static Future<Uint8List?> videoThumb(String path, {int size = 160}) =>
      _c.invokeMethod<Uint8List>('videoThumb', {'path': path, 'size': size});

  static Future<void> openPlayStore(String package) => _c.invokeMethod('openPlayStore', {'package': package});
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
