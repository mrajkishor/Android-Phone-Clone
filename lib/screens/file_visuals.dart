import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../transfer/native.dart';
import '../transfer/protocol.dart';

/// Name and icon of an app, read from its APK.
class AppLook {
  final String package;
  final String label;
  final String? versionName;
  final Uint8List? icon;
  const AppLook(this.package, this.label, this.versionName, this.icon);
}

/// Thumbnails and friendly names for the Files tab, cached so scrolling stays smooth.
class FileVisuals {
  static final _apps = <String, Future<AppLook?>>{}; // folder -> app
  static final _videos = <String, Future<Uint8List?>>{};

  static bool isApk(String rel) => rel.toLowerCase().endsWith('.apk');

  static String _folder(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? '' : path.substring(0, i);
  }

  /// The app an APK belongs to. Split parts (split_config.*.apk) carry no name or
  /// icon, so the app's base.apk next to them is read instead.
  static Future<AppLook?> app(String path) {
    final folder = _folder(path);
    final base = '$folder/base.apk';
    final source = File(base).existsSync() ? base : path;
    final key = source == base ? folder : path;
    return _apps[key] ??= () async {
      try {
        final m = await NativeExtras.apkMeta(source);
        if (m == null) {
          _apps.remove(key); // base.apk may not have arrived yet: try again later
          return null;
        }
        return AppLook(m['package'] as String, m['label'] as String, m['versionName'] as String?, m['icon'] as Uint8List?);
      } catch (_) {
        _apps.remove(key);
        return null;
      }
    }();
  }

  static Future<Uint8List?> video(String path) {
    if (_videos.length > 300) _videos.remove(_videos.keys.first);
    return _videos[path] ??= NativeExtras.videoThumb(path).catchError((_) => null);
  }

  /// "split_config.arm64_v8a.apk" -> "arm64_v8a"
  static String splitName(String fileName) {
    var n = fileName.replaceAll(RegExp(r'\.apk$', caseSensitive: false), '');
    n = n.replaceFirst(RegExp(r'^split_'), '').replaceFirst(RegExp(r'^config\.'), '');
    return n;
  }

  /// "com.whatsapp" -> "Whatsapp" when the real name isn't known yet.
  static String packageGuess(String rel) {
    final parts = rel.split('/');
    final pkg = parts.length >= 3 && parts[0] == 'PhoneClone' && parts[1] == 'Apps' ? parts[2] : null;
    if (pkg == null) return parts.last;
    final last = pkg.split('.').last;
    return last.isEmpty ? pkg : '${last[0].toUpperCase()}${last.substring(1)}';
  }
}

const _imageExt = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif'};
const _videoExt = {'mp4', 'mkv', 'mov', '3gp', 'webm', 'avi', 'm4v'};

String _ext(String rel) {
  final name = rel.split('/').last;
  final i = name.lastIndexOf('.');
  return i < 0 ? '' : name.substring(i + 1).toLowerCase();
}

/// Icon and colour for a file without a picture.
(IconData, Color) iconForFile(String rel, Category? c) {
  final e = _ext(rel);
  if (c == null) return (Icons.lock_outline, Colors.purple);
  if (e == 'pdf') return (Icons.picture_as_pdf, Colors.red);
  if ({'doc', 'docx', 'odt', 'rtf', 'txt', 'md'}.contains(e)) return (Icons.article, Colors.blue);
  if ({'xls', 'xlsx', 'ods', 'csv'}.contains(e)) return (Icons.table_chart, Colors.green);
  if ({'ppt', 'pptx', 'odp'}.contains(e)) return (Icons.slideshow, Colors.deepOrange);
  if ({'epub', 'mobi', 'azw', 'azw3', 'fb2'}.contains(e)) return (Icons.menu_book, Colors.brown);
  if (e == 'vcf') return (Icons.contact_page, Colors.indigo);
  if (e == 'apk' || e == 'xapk' || e == 'apks') return (Icons.android, Colors.green);
  return switch (c) {
    Category.photos => (Icons.image, Colors.teal),
    Category.videos => (Icons.movie, Colors.pink),
    Category.music => (Icons.music_note, Colors.deepPurple),
    Category.documents => (Icons.description, Colors.blue),
    Category.archives => (Icons.folder_zip, Colors.amber),
    Category.apps => (Icons.android, Colors.green),
    Category.otherMedia => (Icons.perm_media, Colors.cyan),
    Category.otherFiles => (Icons.insert_drive_file, Colors.blueGrey),
    Category.hidden => (Icons.visibility_off, Colors.grey),
  };
}

/// 40 × 40 rounded preview: the photo itself, a video frame, the app's icon, or a file-type icon.
class FileThumb extends StatelessWidget {
  final String rel;
  final String? path; // where the file is on this phone, if it is here
  final Category? category;
  const FileThumb({super.key, required this.rel, this.path, this.category});

  static const double size = 40;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = iconForFile(rel, category);
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
      child: Icon(icon, color: color, size: 22),
    );
    final p = path;
    if (p == null) return fallback;
    final e = _ext(rel);
    Widget clip(Widget w) => ClipRRect(borderRadius: BorderRadius.circular(8), child: SizedBox.square(dimension: size, child: w));

    if (_imageExt.contains(e) && e != 'heic' && e != 'heif') {
      return clip(Image.file(
        File(p),
        fit: BoxFit.cover,
        cacheWidth: 120, // decoded small: smooth scrolling, little memory
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => fallback,
      ));
    }
    if (_videoExt.contains(e)) {
      return _FutureThumb(future: FileVisuals.video(p), fallback: fallback, cover: true, badge: Icons.play_arrow);
    }
    if (e == 'apk') {
      return _FutureThumb(
        future: FileVisuals.app(p).then((a) => a?.icon),
        fallback: fallback,
        cover: false,
      );
    }
    return fallback;
  }
}

class _FutureThumb extends StatelessWidget {
  final Future<Uint8List?> future;
  final Widget fallback;
  final bool cover;
  final IconData? badge;
  const _FutureThumb({required this.future, required this.fallback, required this.cover, this.badge});

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
        future: future,
        builder: (context, snap) {
          final bytes = snap.data;
          if (bytes == null) return fallback;
          return SizedBox.square(
            dimension: FileThumb.size,
            child: Stack(fit: StackFit.expand, children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(bytes, fit: cover ? BoxFit.cover : BoxFit.contain, gaplessPlayback: true),
              ),
              if (badge != null)
                Center(
                  child: Container(
                    decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                    child: Icon(badge, color: Colors.white, size: 16),
                  ),
                ),
            ]),
          );
        },
      );
}

/// The title line of a file: the file name, or for an app installer the app's name.
class FileTitle extends StatelessWidget {
  final String rel;
  final String? path;
  final TextStyle? style;
  const FileTitle({super.key, required this.rel, this.path, this.style});

  @override
  Widget build(BuildContext context) {
    final name = rel.split('/').last;
    final p = path;
    if (!FileVisuals.isApk(rel) || p == null) {
      return Text(FileVisuals.isApk(rel) && rel.startsWith('PhoneClone/Apps/') ? _appTitle(FileVisuals.packageGuess(rel), name) : name,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    }
    return FutureBuilder<AppLook?>(
      future: FileVisuals.app(p),
      builder: (context, snap) {
        final label = snap.data?.label ?? (rel.startsWith('PhoneClone/Apps/') ? FileVisuals.packageGuess(rel) : null);
        return Text(label == null ? name : _appTitle(label, name), maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
      },
    );
  }

  /// The app's name for its installer files (base.apk and split parts), else "Name (file.apk)".
  static String _appTitle(String label, String fileName) {
    final lower = fileName.toLowerCase();
    if (lower == 'base.apk' || lower.startsWith('split_')) return label;
    return '$label ($fileName)';
  }

  /// What an app installer file is, in plain words: "App installer" or "Extra part (arm64_v8a)".
  static String partName(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower == 'base.apk') return 'App installer';
    if (lower.startsWith('split_')) return 'Extra part (${FileVisuals.splitName(fileName)})';
    return fileName;
  }
}
