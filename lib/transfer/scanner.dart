import 'dart:io';
import 'dart:isolate';

import 'native.dart';
import 'protocol.dart';

/// Result of scanning the old phone.
/// Something on the old phone that Android doesn't let a regular app read.
class RestrictedItem {
  final String rel;
  final String reason;
  const RestrictedItem(this.rel, this.reason);
}

class ScanResult {
  final Map<Category, List<FileEntry>> byCategory;
  final int unreadable;

  /// Folders and files that can't be copied, with the reason (shown as "Restricted").
  final List<RestrictedItem> restricted;

  const ScanResult(this.byCategory, this.unreadable, [this.restricted = const []]);

  int count(Category c) => byCategory[c]!.length;
  int bytes(Category c) => byCategory[c]!.fold(0, (s, f) => s + f.size);
}

/// Finds every file on the phone. Photos, videos and music come from Android's
/// media index (what the gallery and music apps show); everything else comes
/// from walking the storage folders. Runs in a background isolate.
Future<ScanResult> scanDevice() async {
  final roots = await Native.storageRoots();
  final media = [
    for (final m in await Native.listMedia()) (path: m['path'] as String, kind: m['kind'] as String),
  ];
  return Isolate.run(() => _scan(roots, media));
}

const _docExt = {
  'pdf', 'doc', 'docx', 'odt', 'rtf', 'txt', 'md', 'xls', 'xlsx', 'ods', 'csv', 'ppt', 'pptx', 'odp', 'epub',
  'mobi', 'azw', 'azw3', 'fb2', 'djvu', 'pages', 'numbers', 'key', 'json', 'xml', 'html', 'htm', 'vcf', 'ics',
  'log', 'tex', 'wps', 'hwp',
};
const _archiveExt = {'zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'xz', 'zst', 'iso'};
const _appExt = {'apk', 'xapk', 'apks', 'apkm', 'aab'};
const _mediaExt = {
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp', 'dng', 'raw', 'cr2', 'nef', 'arw', 'svg',
  'mp4', 'mkv', 'mov', '3gp', 'webm', 'avi', 'wmv', 'flv', 'm4v', 'ts',
  'mp3', 'm4a', 'aac', 'wav', 'ogg', 'oga', 'opus', 'flac', 'amr', 'wma', 'mid', 'midi', 'awb',
};

/// Folder (relative to its storage root) that no regular app may read or that
/// only holds other apps' private data.
bool _isPrivateFolder(String rel) {
  final l = rel.toLowerCase();
  return l == 'android/data' || l == 'android/obb';
}

String? _relativeTo(String path, List<String> roots) {
  for (final r in roots) {
    if (path.startsWith('$r/')) return path.substring(r.length + 1);
  }
  return null;
}

ScanResult _scan(List<String> roots, List<({String path, String kind})> media) {
  // Longest root first, so /storage/emulated/0 doesn't swallow a nested volume.
  roots = [...roots]..sort((a, b) => b.length.compareTo(a.length));
  final out = {for (final c in Category.values) c: <FileEntry>[]};
  final mediaPaths = <String>{};
  var unreadable = 0;
  final restricted = <RestrictedItem>[];
  const privateReason = 'App-private storage. Android lets only the app itself (or the phone maker\'s '
      'own transfer tool) read it. The app\'s own backup or sign-in restores it.';

  // 1. Media index.
  for (final m in media) {
    if (!mediaPaths.add(m.path)) continue;
    final st = FileStat.statSync(m.path);
    if (st.type != FileSystemEntityType.file) {
      continue; // stale index entry: the file no longer exists
    }
    final rel = _relativeTo(m.path, roots) ?? 'PhoneTransfer/Other storage/${m.path.split('/').last}';
    final cat = switch (m.kind) { 'photo' => Category.photos, 'video' => Category.videos, _ => Category.music };
    out[cat]!.add(FileEntry(m.path, rel, st.size, st.modified.millisecondsSinceEpoch, cat));
  }

  // 2. Everything else on every storage volume.
  void walk(Directory dir, String root, bool hidden) {
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      unreadable++;
      if (restricted.length < 5000) {
        final rel = dir.path.length > root.length ? dir.path.substring(root.length + 1) : dir.path;
        restricted.add(RestrictedItem(rel, 'Folder protected by Android: it can\'t be opened by apps.'));
      }
      return;
    }
    for (final e in entries) {
      final name = e.path.split('/').last;
      final rel = e.path.substring(root.length + 1);
      if (e is Directory) {
        if (_isPrivateFolder(rel)) {
          // Android 11+: the folder can't be listed at all. Older versions: list the apps in it.
          List<FileSystemEntity> apps = const [];
          try {
            apps = e.listSync(followLinks: false);
          } catch (_) {}
          if (apps.isEmpty) {
            restricted.add(RestrictedItem(rel, privateReason));
          } else {
            for (final a in apps) {
              restricted.add(RestrictedItem(a.path.substring(root.length + 1), privateReason));
            }
          }
          continue;
        }
        if (name == '.phonetransfer_tmp') continue;
        if (rel == 'Documents/Phone Clone/Snapshots') continue; // this phone's own transfer snapshots
        walk(e, root, hidden || name.startsWith('.'));
      } else if (e is File) {
        if (mediaPaths.contains(e.path)) continue;
        final FileStat st;
        try {
          st = e.statSync();
        } catch (_) {
          unreadable++;
          if (restricted.length < 5000) restricted.add(RestrictedItem(rel, 'Android refused to read this file.'));
          continue;
        }
        final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
        final Category cat;
        if (hidden || name.startsWith('.')) {
          cat = Category.hidden;
        } else if (_docExt.contains(ext)) {
          cat = Category.documents;
        } else if (_archiveExt.contains(ext)) {
          cat = Category.archives;
        } else if (_appExt.contains(ext)) {
          cat = Category.apps;
        } else if (_mediaExt.contains(ext)) {
          cat = Category.otherMedia;
        } else {
          cat = Category.otherFiles;
        }
        out[cat]!.add(FileEntry(e.path, rel, st.size, st.modified.millisecondsSinceEpoch, cat));
      }
    }
  }

  for (final r in roots) {
    walk(Directory(r), r, false);
  }
  return ScanResult(out, unreadable, restricted);
}
