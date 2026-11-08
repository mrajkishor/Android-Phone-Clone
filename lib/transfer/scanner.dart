import 'dart:io';
import 'dart:isolate';

import 'native.dart';
import 'protocol.dart';

/// Result of scanning the old phone.
class ScanResult {
  final Map<Category, List<FileEntry>> byCategory;
  final int unreadable;

  const ScanResult(this.byCategory, this.unreadable);

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
      return;
    }
    for (final e in entries) {
      final name = e.path.split('/').last;
      final rel = e.path.substring(root.length + 1);
      if (e is Directory) {
        if (_isPrivateFolder(rel) || name == '.phonetransfer_tmp') continue;
        walk(e, root, hidden || name.startsWith('.'));
      } else if (e is File) {
        if (mediaPaths.contains(e.path)) continue;
        final FileStat st;
        try {
          st = e.statSync();
        } catch (_) {
          unreadable++;
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
  return ScanResult(out, unreadable);
}
