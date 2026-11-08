import 'package:flutter/material.dart';

import '../transfer/extras.dart';
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
  const FileRow(this.rel, this.size, this.status, {this.error, this.category});
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
            : Row(children: [
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
            key, () => _Group(key, c?.label ?? (r.status == 'restricted' ? 'Restricted by Android' : 'Other'), _categoryIcon(c)));
      case _GroupBy.folder:
        final i = r.rel.indexOf('/');
        var top = i < 0 ? '(main folder)' : r.rel.substring(0, i);
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
            () => _Group(b.name, _bucketLabel(b), switch (b) {
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
      if (widget.note != null) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(widget.note!, style: t.bodySmall)),
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
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: _GroupBy.type, label: Text('By type'), icon: Icon(Icons.category_outlined)),
          ButtonSegment(value: _GroupBy.folder, label: Text('By folder'), icon: Icon(Icons.folder_outlined)),
          ButtonSegment(value: _GroupBy.status, label: Text('By status'), icon: Icon(Icons.rule)),
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
      TextField(
        decoration: const InputDecoration(
          isDense: true,
          prefixIcon: Icon(Icons.search),
          hintText: 'Search by name or folder',
          border: OutlineInputBorder(),
        ),
        onChanged: (v) => setState(() => _query = v),
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
                Text('$done/$n', style: t.labelMedium),
              ]),
              const SizedBox(height: 4),
              _StackBar(g.counts),
              const SizedBox(height: 2),
              Text(
                [
                  '$n files • ${formatBytes(g.bytes)}',
                  for (final b in _Bucket.values)
                    if (g.counts[b]! > 0 && b != _Bucket.onNew) '${g.counts[b]} ${_bucketLabel(b).toLowerCase()}',
                ].join(' • '),
                style: t.bodySmall,
              ),
            ]),
          ),
          Icon(open ? Icons.expand_less : Icons.expand_more),
        ]),
      ),
    );
  }

  Widget _row(FileRow r) {
    final (icon, color, label) = _look(r.status);
    final slash = r.rel.lastIndexOf('/');
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 36, right: 8),
      leading: Icon(icon, color: color, size: 20),
      title: Text(slash < 0 ? r.rel : r.rel.substring(slash + 1), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${slash < 0 ? '' : '${r.rel.substring(0, slash)} • '}${r.size > 0 ? '${formatBytes(r.size)} • ' : ''}$label'
        '${r.error == null ? '' : '\n${r.error}'}',
        maxLines: r.error == null ? 1 : 4,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Messages, calls, calendar, apps, wallpaper and ringtones.
class ExtrasStatusList extends StatelessWidget {
  final Map<Extra, ExtraTally> tally;
  final Iterable<Extra> shown;
  final List<Widget> footer;

  const ExtrasStatusList({super.key, required this.tally, required this.shown, this.footer = const []});

  static IconData iconOf(Extra e) => switch (e) {
        Extra.messages => Icons.sms_outlined,
        Extra.calls => Icons.call_outlined,
        Extra.calendar => Icons.event_outlined,
        Extra.apps => Icons.apps,
        Extra.wallpaper => Icons.wallpaper,
        Extra.ringtones => Icons.music_note_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final items = shown.toList();
    return ListView(children: [
      if (items.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text('No extras in this transfer. Messages, call history, calendar, apps, wallpaper and ringtones '
              'can be chosen on the old phone before starting.'),
        ),
      for (final e in items) _row(context, e, tally[e]!),
      ...footer,
    ]);
  }

  Widget _row(BuildContext context, Extra e, ExtraTally t) {
    final (Widget trailing, String state) = switch (t.state) {
      'running' => (const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)), 'In progress'),
      'waiting' => (const Icon(Icons.touch_app, color: Colors.orange), 'Waiting for an OK on the new phone'),
      'done' => (Icon(t.failed > 0 ? Icons.info : Icons.check_circle, color: t.failed > 0 ? Colors.orange : Colors.green), 'Done'),
      'skipped' => (const Icon(Icons.block, color: Colors.grey), 'Skipped'),
      _ => (const Icon(Icons.schedule, color: Colors.grey), 'Waiting'),
    };
    final numbers = t.total == 0 && t.added == 0
        ? ''
        : '${t.added} added • ${t.existing} already there${t.failed > 0 ? ' • ${t.failed} failed' : ''}'
            '${t.total > 0 ? ' • of ${t.total}' : ''}\n';
    return ListTile(
      leading: Icon(iconOf(e)),
      title: Row(children: [Flexible(child: Text(e.label)), if (e.restriction != null) ...[const SizedBox(width: 6), RestrictedChip(e)]]),
      subtitle: Text('$numbers$state${t.note == null ? '' : ' — ${t.note}'}'),
      isThreeLine: numbers.isNotEmpty,
      trailing: trailing,
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
