import 'package:flutter/material.dart';

import '../transfer/extras.dart';
import 'file_visuals.dart';
import '../transfer/native.dart';
import '../transfer/protocol.dart';

/// Progress / Files / Extras, on both phones.
class TransferTabs extends StatelessWidget {
  final Widget progress;
  final Widget files;
  final Widget extras;
  final int filesBadge;
  final int extrasBadge;

  const TransferTabs({
    super.key,
    required this.progress,
    required this.files,
    required this.extras,
    this.filesBadge = 0,
    this.extrasBadge = 0,
  });

  @override
  Widget build(BuildContext context) {
    Tab tab(IconData i, String label, int n) => Tab(
          icon: Icon(i),
          child: Text(n > 0 ? '$label ($n)' : label, maxLines: 1, overflow: TextOverflow.fade, softWrap: false),
        );
    return DefaultTabController(
      length: 3,
      child: Column(children: [
        TabBar(tabs: [
          tab(Icons.speed, 'Progress', 0),
          tab(Icons.compare_arrows, 'Files', filesBadge),
          tab(Icons.apps, 'Extras', extrasBadge),
        ]),
        const SizedBox(height: 8),
        Expanded(child: TabBarView(children: [progress, files, extras])),
      ]),
    );
  }
}

/// One row of the Files tab.
class FileRow {
  final String rel;
  final int size;
  final String status; // sent | saved | already | cloned | waiting | sending | queued | failed | restricted
  final String? error;
  final Category? category; // null: restricted or unknown
  final String? path; // where the file is on this phone (for thumbnails), if it is here
  const FileRow(this.rel, this.size, this.status, {this.error, this.category, this.path});
}

enum _Filter { all, onNew, sent, already, pending, failed, restricted }

enum _GroupBy { type, folder, status }

/// The four buckets used for the bars and the legend.
enum _Bucket { onNew, pending, failed, restricted }

_Bucket _bucketOf(String s) => switch (s) {
      'sent' || 'saved' || 'already' || 'cloned' => _Bucket.onNew,
      'failed' => _Bucket.failed,
      'restricted' => _Bucket.restricted,
      _ => _Bucket.pending,
    };

Color _bucketColor(_Bucket b) => switch (b) {
      _Bucket.onNew => Colors.green,
      _Bucket.pending => Colors.blue,
      _Bucket.failed => Colors.red,
      _Bucket.restricted => Colors.purple,
    };

String _bucketLabel(_Bucket b) => switch (b) {
      _Bucket.onNew => 'On new phone',
      _Bucket.pending => 'Pending',
      _Bucket.failed => 'Failed',
      _Bucket.restricted => 'Restricted',
    };

/// A thin bar split into on-new / pending / failed / restricted.
class _StackBar extends StatelessWidget {
  final Map<_Bucket, int> counts;
  final double height;
  const _StackBar(this.counts, {this.height = 8});

  @override
  Widget build(BuildContext context) {
    final total = counts.values.fold(0, (a, b) => a + b);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: total == 0
            ? ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest)
            : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final b in _Bucket.values)
                  if ((counts[b] ?? 0) > 0) Expanded(flex: counts[b]!, child: ColoredBox(color: _bucketColor(b))),
              ]),
      ),
    );
  }
}

class _Group {
  final String key;
  final String title;
  final IconData icon;
  final List<FileRow> rows = [];
  final Map<_Bucket, int> counts = {for (final b in _Bucket.values) b: 0};
  int bytes = 0;
  _Group(this.key, this.title, this.icon);
}

/// Compare the old phone with the new phone: grouped by type, folder or status,
/// with a bar per group, filters and search.
class FileCompareList extends StatefulWidget {
  final List<FileRow> rows;

  /// Shown above the list, e.g. "1 204 files were already on this phone".
  final String? note;

  const FileCompareList({super.key, required this.rows, this.note});

  @override
  State<FileCompareList> createState() => _FileCompareListState();
}

class _FileCompareListState extends State<FileCompareList> {
  _Filter _filter = _Filter.all;
  _GroupBy _groupBy = _GroupBy.type;
  String _query = '';
  final Set<String> _open = {};

  static bool _match(_Filter f, String s) => switch (f) {
        _Filter.all => true,
        _Filter.onNew => _bucketOf(s) == _Bucket.onNew,
        _Filter.sent => s == 'sent' || s == 'saved' || s == 'cloned',
        _Filter.already => s == 'already',
        _Filter.pending => _bucketOf(s) == _Bucket.pending,
        _Filter.failed => s == 'failed',
        _Filter.restricted => s == 'restricted',
      };

  static String _label(_Filter f) => switch (f) {
        _Filter.all => 'All',
        _Filter.onNew => 'On new phone',
        _Filter.sent => 'Copied now',
        _Filter.already => 'Already there',
        _Filter.pending => 'Pending',
        _Filter.failed => 'Failed',
        _Filter.restricted => 'Restricted',
      };

  static (IconData, Color, String) _look(String s) => switch (s) {
        'sent' || 'saved' => (Icons.check_circle, Colors.green, 'Copied'),
        'cloned' => (Icons.copy_all, Colors.teal, 'Copied (identical file)'),
        'already' => (Icons.done_all, Colors.blueGrey, 'Already on the new phone'),
        'sending' => (Icons.upload, Colors.blue, 'Sending'),
        'queued' => (Icons.replay, Colors.orange, 'Will retry'),
        'failed' => (Icons.error, Colors.red, 'Failed'),
        'restricted' => (Icons.lock, Colors.purple, 'Restricted'),
        _ => (Icons.schedule, Colors.grey, 'Waiting'),
      };

  static IconData _categoryIcon(Category? c) => switch (c) {
        Category.photos => Icons.photo_outlined,
        Category.videos => Icons.movie_outlined,
        Category.music => Icons.music_note_outlined,
        Category.documents => Icons.description_outlined,
        Category.archives => Icons.folder_zip_outlined,
        Category.apps => Icons.android,
        Category.otherMedia => Icons.perm_media_outlined,
        Category.otherFiles => Icons.insert_drive_file_outlined,
        Category.hidden => Icons.visibility_off_outlined,
        null => Icons.lock_outline,
      };

  _Group _groupFor(FileRow r, Map<String, _Group> groups) {
    switch (_groupBy) {
      case _GroupBy.type:
        final c = r.status == 'restricted' ? null : r.category;
        final key = c?.name ?? (r.status == 'restricted' ? 'restricted' : 'unknown');
        return groups.putIfAbsent(
            key,
            () => _Group(
                key, c?.label ?? (r.status == 'restricted' ? 'Restricted by Android' : 'Other'), _categoryIcon(c)));
      case _GroupBy.folder:
        final i = r.rel.indexOf('/');
        var top = i < 0 ? 'Main folder' : r.rel.substring(0, i);
        if (r.rel.startsWith('PhoneClone/Apps/')) {
          return groups.putIfAbsent('apps', () => _Group('apps', 'Installed apps', Icons.apps));
        }
        if (top == 'Android' || top == 'PhoneClone') {
          // Android/media/com.whatsapp, PhoneClone/Apps: one level deeper is more useful.
          final parts = r.rel.split('/');
          if (parts.length > 2) top = '${parts[0]}/${parts[1]}${parts.length > 3 ? '/${parts[2]}' : ''}';
        }
        return groups.putIfAbsent(top, () => _Group(top, top, Icons.folder_outlined));
      case _GroupBy.status:
        final b = _bucketOf(r.status);
        return groups.putIfAbsent(
            b.name,
            () => _Group(
                b.name,
                _bucketLabel(b),
                switch (b) {
                  _Bucket.onNew => Icons.check_circle_outline,
                  _Bucket.pending => Icons.schedule,
                  _Bucket.failed => Icons.error_outline,
                  _Bucket.restricted => Icons.lock_outline,
                }));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final all = widget.rows;
    final totals = {for (final b in _Bucket.values) b: 0};
    for (final r in all) {
      totals[_bucketOf(r.status)] = totals[_bucketOf(r.status)]! + 1;
    }
    final counts = {for (final f in _Filter.values) f: all.where((r) => _match(f, r.status)).length};
    final q = _query.toLowerCase();

    final groups = <String, _Group>{};
    for (final r in all) {
      if (!_match(_filter, r.status) || (q.isNotEmpty && !r.rel.toLowerCase().contains(q))) continue;
      final g = _groupFor(r, groups)..rows.add(r);
      g.counts[_bucketOf(r.status)] = g.counts[_bucketOf(r.status)]! + 1;
      g.bytes += r.size;
    }
    int rank(_Group g) => switch (_groupBy) {
          _GroupBy.type => Category.values.indexWhere((c) => c.name == g.key) + 1,
          _GroupBy.status => _Bucket.values.indexWhere((x) => x.name == g.key),
          _GroupBy.folder => -g.rows.length, // biggest folders first
        };
    final ordered = groups.values.toList()
      ..sort((a, b) {
        var ra = rank(a), rb = rank(b);
        if (_groupBy == _GroupBy.type) {
          if (ra == 0) ra = 99; // restricted / unknown at the end
          if (rb == 0) rb = 99;
        }
        return ra.compareTo(rb);
      });

    // Flatten: a header per group, then its files when open.
    final items = <Object>[];
    for (final g in ordered) {
      items.add(g);
      if (_open.contains(g.key) || ordered.length == 1 || q.isNotEmpty) items.addAll(g.rows);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (widget.note != null)
        Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(widget.note!, style: t.bodySmall)),
      // Overall picture.
      _StackBar(totals, height: 12),
      const SizedBox(height: 4),
      Wrap(spacing: 12, children: [
        for (final b in _Bucket.values)
          if (totals[b]! > 0)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.circle, size: 10, color: _bucketColor(b)),
              const SizedBox(width: 4),
              Text('${_bucketLabel(b)} ${totals[b]}', style: t.bodySmall),
            ]),
      ]),
      const SizedBox(height: 8),
      SegmentedButton<_GroupBy>(
        showSelectedIcon: true,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: const [
          ButtonSegment(value: _GroupBy.type, label: Text('Type')),
          ButtonSegment(value: _GroupBy.folder, label: Text('Folder')),
          ButtonSegment(value: _GroupBy.status, label: Text('Status')),
        ],
        selected: {_groupBy},
        onSelectionChanged: (v) => setState(() {
          _groupBy = v.first;
          _open.clear();
        }),
      ),
      const SizedBox(height: 6),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final f in _Filter.values)
            if (f == _Filter.all || counts[f]! > 0)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text('${_label(f)} ${counts[f]}'),
                  selected: _filter == f,
                  onSelected: (_) => setState(() => _filter = f),
                ),
              ),
        ]),
      ),
      const SizedBox(height: 6),
      Row(children: [
        Expanded(
          child: TextField(
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search),
              hintText: 'Search by name or folder',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'Open the Files app',
          icon: const Icon(Icons.folder_open_outlined),
          onPressed: () => _openFolder(context, null),
        ),
      ]),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text('Tap a file to open it, or use its folder icon to see it in the Files app.',
            style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ),
      const SizedBox(height: 6),
      Expanded(
        child: items.isEmpty
            ? Center(child: Text(all.isEmpty ? 'No files yet' : 'Nothing matches', style: t.bodyMedium))
            : ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final it = items[i];
                  if (it is _Group) return _header(context, it);
                  return _row(it as FileRow);
                },
              ),
      ),
    ]);
  }

  Widget _header(BuildContext context, _Group g) {
    final t = Theme.of(context).textTheme;
    final open = _open.contains(g.key);
    final n = g.rows.length;
    final done = g.counts[_Bucket.onNew]!;
    final onlyRestricted = g.counts[_Bucket.restricted] == n;
    return InkWell(
      onTap: () => setState(() => open ? _open.remove(g.key) : _open.add(g.key)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(children: [
          Icon(g.icon),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: Text(g.title, style: t.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (!onlyRestricted) Text('$done/$n', style: t.labelMedium),
              ]),
              const SizedBox(height: 4),
              _StackBar(g.counts),
              const SizedBox(height: 2),
              Text(
                onlyRestricted
                    ? '$n ${n == 1 ? 'item' : 'items'} • can’t be copied by any app'
                    : [
                        '$n ${n == 1 ? 'file' : 'files'} • ${formatBytes(g.bytes)}',
                        for (final b in _Bucket.values)
                          if (g.counts[b]! > 0 && b != _Bucket.onNew) '${g.counts[b]} ${_bucketLabel(b).toLowerCase()}',
                      ].join(' • '),
                style: t.bodySmall,
              ),
            ]),
          ),
          if (_groupBy == _GroupBy.folder && _realFolder(g.key))
            IconButton(
              tooltip: 'Open this folder in the Files app',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.folder_open_outlined, size: 20),
              onPressed: () => _openFolder(context, g.key),
            ),
          Icon(open ? Icons.expand_less : Icons.expand_more),
        ]),
      ),
    );
  }

  static bool _realFolder(String key) => key != 'apps' && key != 'Main folder' && !key.startsWith('Android/data');

  void _say(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));
  }

  Future<void> _openFolder(BuildContext context, String? folder) async {
    var ok = false;
    try {
      ok = await NativeExtras.openFilesApp(folder);
    } catch (_) {}
    if (!ok && context.mounted) _say(context, 'Couldn’t open the Files app on this phone.');
  }

  /// Opens the file in the phone's own app for it (Gallery, PDF viewer, player…).
  Future<void> _openFile(BuildContext context, FileRow r) async {
    if (r.status == 'restricted') {
      _say(context, r.error ?? 'Android doesn’t let apps open this.');
      return;
    }
    final path = r.path;
    if (path == null) {
      _say(context, r.status == 'failed' ? 'This file didn’t reach this phone.' : 'This file isn’t on this phone yet.');
      return;
    }
    if (r.rel.startsWith('PhoneClone/Apps/')) {
      _say(context, 'Apps are installed from the Extras tab on the new phone.');
      return;
    }
    var result = 'noApp';
    try {
      result = await NativeExtras.openFile(path);
    } catch (_) {}
    if (!context.mounted) return;
    if (result == 'noApp') _say(context, 'No app on this phone can open this type of file.');
    if (result == 'notHere') _say(context, 'This file isn’t on this phone any more.');
  }

  /// The file can be shown in the Files app: it is on this phone's shared storage.
  /// Not an installed app's own APK (in /data/app), which the Files app can't show.
  static bool _inSharedStorage(FileRow r) => r.path != null && !r.path!.startsWith('/data/');

  Future<void> _showInFolder(BuildContext context, FileRow r) async {
    var ok = false;
    try {
      ok = await NativeExtras.showInFilesApp(r.path!);
    } catch (_) {}
    if (!ok && context.mounted) _say(context, 'Couldn’t open the Files app on this phone.');
  }

  Widget _row(FileRow r) {
    final (icon, color, label) = _look(r.status);
    final apps = r.rel.startsWith('PhoneClone/Apps/');
    final slash = r.rel.lastIndexOf('/');
    final where = apps
        ? FileTitle.partName(r.rel.split('/').last)
        : slash < 0
            ? 'Main folder'
            : r.rel.substring(0, slash);
    final here = r.path != null && r.status != 'restricted';
    final canOpen = here && !apps;
    final canShow = here && _inSharedStorage(r);
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 12, right: 0),
      // Thumbnail with a small status badge, like a gallery.
      leading: SizedBox.square(
        dimension: FileThumb.size + 4,
        child: Stack(clipBehavior: Clip.none, children: [
          FileThumb(rel: r.rel, path: r.path, category: r.status == 'restricted' ? null : r.category),
          Positioned(
            right: -2,
            bottom: -2,
            child: Tooltip(
              message: label,
              child: Container(
                decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, shape: BoxShape.circle),
                padding: const EdgeInsets.all(1),
                child: Icon(icon, color: color, size: 16),
              ),
            ),
          ),
        ]),
      ),
      title: FileTitle(rel: r.rel, path: r.path),
      subtitle: Text(
        '${[where, if (r.size > 0) formatBytes(r.size)].join(' • ')}\n$label${r.error == null ? '' : ': ${r.error}'}',
        maxLines: r.error == null ? 2 : 3,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: true,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          tooltip: 'Open',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.open_in_new, size: 20),
          onPressed: canOpen ? () => _openFile(context, r) : null,
        ),
        IconButton(
          tooltip: 'Show in Files app',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.folder_open_outlined, size: 20),
          onPressed: canShow ? () => _showInFolder(context, r) : null,
        ),
      ]),
      onTap: () => _openFile(context, r),
    );
  }
}

/// Messages, calls, calendar, apps, wallpaper and ringtones: one card each, with a
/// plain-language status and, where it helps, a "Try again" button.
class ExtrasStatusList extends StatelessWidget {
  final Map<Extra, ExtraTally> tally;
  final Iterable<Extra> shown;
  final List<Widget> footer;

  /// True on the new phone (changes the wording of "waiting for Allow").
  final bool newPhone;

  /// Try a skipped or partly failed extra again (null: not possible from this phone right now).
  final void Function(Extra e)? onRetry;

  /// Shown instead of the button when [onRetry] is null but trying again is possible elsewhere.
  final String? retryHint;

  const ExtrasStatusList({
    super.key,
    required this.tally,
    required this.shown,
    this.footer = const [],
    this.newPhone = false,
    this.onRetry,
    this.retryHint,
  });

  static IconData iconOf(Extra e) => switch (e) {
        Extra.messages => Icons.sms_outlined,
        Extra.calls => Icons.call_outlined,
        Extra.calendar => Icons.event_outlined,
        Extra.apps => Icons.apps,
        Extra.wallpaper => Icons.wallpaper,
        Extra.ringtones => Icons.music_note_outlined,
      };

  /// Calendar, calls and messages go before the files; the rest need the files first.
  static bool _afterFiles(Extra e) => e == Extra.apps || e == Extra.wallpaper || e == Extra.ringtones;

  @override
  Widget build(BuildContext context) {
    final items = shown.toList();
    return ListView(padding: const EdgeInsets.only(bottom: 16), children: [
      if (items.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text('Nothing extra in this transfer. Messages, call history, calendar, apps, wallpaper and '
              'ringtones can be chosen on the old phone before starting.'),
        ),
      for (final e in items) _card(context, e, tally[e]!),
      ...footer,
    ]);
  }

  Widget _card(BuildContext context, Extra e, ExtraTally t) {
    final cs = Theme.of(context).colorScheme;
    final txt = Theme.of(context).textTheme;
    final processed = t.added + t.existing + t.failed;
    final canRetry = t.state == 'skipped' || (t.state == 'done' && t.failed > 0);

    final (Widget badge, String headline) = switch (t.state) {
      'running' => (
          const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
          t.total > 0 ? 'Copying… $processed of ${t.total}' : 'Copying…'
        ),
      'waiting' => (
          const Icon(Icons.touch_app, color: Colors.orange),
          newPhone ? 'Tap “Allow” in the popup on this phone' : 'Waiting for you to tap “Allow” on the new phone'
        ),
      'done' when t.failed > 0 => (
          const Icon(Icons.error_outline, color: Colors.orange),
          'Done, but ${t.failed} couldn’t be ${e == Extra.apps ? 'copied' : 'added'}'
        ),
      'done' => (const Icon(Icons.check_circle, color: Colors.green), 'Done'),
      'skipped' => (Icon(Icons.do_not_disturb_on_outlined, color: cs.outline), 'Skipped'),
      _ => (
          Icon(Icons.schedule, color: cs.outline),
          _afterFiles(e) ? 'Waiting · starts after all files are copied' : 'Waiting · goes before the files'
        ),
    };

    final apps = e == Extra.apps;
    final numbers = [
      if (t.added > 0 || t.state == 'done') apps ? '${t.added} ready to install' : '${t.added} added',
      if (t.existing > 0) apps ? '${t.existing} already installed' : '${t.existing} already there',
      if (t.failed > 0) apps ? '${t.failed} not copied' : '${t.failed} not added',
    ].join(' · ');

    return Card(
      elevation: 0,
      color: cs.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: cs.secondaryContainer,
              child: Icon(iconOf(e), color: cs.onSecondaryContainer, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(e.label, style: txt.titleSmall),
                  if (e.restriction != null) RestrictedChip(e),
                ]),
                const SizedBox(height: 2),
                Text(headline, style: txt.bodyMedium),
                if (numbers.isNotEmpty) Text(numbers, style: txt.bodySmall),
                if (t.note != null) Text(t.note!, style: txt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ]),
            ),
            const SizedBox(width: 8),
            badge,
          ]),
          if (t.state == 'running' && t.total > 0) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: (processed / t.total).clamp(0.0, 1.0),
              borderRadius: BorderRadius.circular(4),
            ),
          ],
          if (canRetry && (onRetry != null || retryHint != null))
            Align(
              alignment: Alignment.centerRight,
              child: onRetry != null
                  ? TextButton.icon(
                      onPressed: () => onRetry!(e),
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Try again'),
                    )
                  : Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(retryHint!, style: txt.bodySmall),
                    ),
            ),
        ]),
      ),
    );
  }
}

/// "Restricted" (red) or "Sensitive" (amber) label; tap for the reason.
class RestrictedChip extends StatelessWidget {
  final Extra extra;
  const RestrictedChip(this.extra, {super.key});

  @override
  Widget build(BuildContext context) {
    final color = extra.isRestricted ? Colors.red : Colors.orange;
    return GestureDetector(
      onTap: () => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(Icons.lock_outline, color: color),
          title: Text('${extra.label}: ${extra.isRestricted ? 'restricted' : 'sensitive'}'),
          content: Text(extra.restriction!),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(8),
          color: color.withValues(alpha: 0.08),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.lock_outline, size: 12, color: color),
          const SizedBox(width: 2),
          Text(extra.isRestricted ? 'Restricted' : 'Sensitive', style: TextStyle(fontSize: 11, color: color)),
        ]),
      ),
    );
  }
}
