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
  final String status; // sent | already | cloned | waiting | sending | queued | failed | saved
  final String? error;
  const FileRow(this.rel, this.size, this.status, [this.error]);
}

enum _Filter { all, onNew, sent, already, pending, failed }

/// Compare the old phone with the new phone, file by file.
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
  String _query = '';

  static bool _match(_Filter f, String s) => switch (f) {
        _Filter.all => true,
        _Filter.onNew => s == 'sent' || s == 'saved' || s == 'already' || s == 'cloned',
        _Filter.sent => s == 'sent' || s == 'saved' || s == 'cloned',
        _Filter.already => s == 'already',
        _Filter.pending => s == 'waiting' || s == 'sending' || s == 'queued',
        _Filter.failed => s == 'failed',
      };

  static String _label(_Filter f) => switch (f) {
        _Filter.all => 'All',
        _Filter.onNew => 'On new phone',
        _Filter.sent => 'Copied now',
        _Filter.already => 'Already there',
        _Filter.pending => 'Pending',
        _Filter.failed => 'Failed',
      };

  static (IconData, Color, String) _look(String s) => switch (s) {
        'sent' || 'saved' => (Icons.check_circle, Colors.green, 'Copied'),
        'cloned' => (Icons.copy_all, Colors.teal, 'Copied (identical file)'),
        'already' => (Icons.done_all, Colors.blueGrey, 'Already on the new phone'),
        'sending' => (Icons.upload, Colors.blue, 'Sending'),
        'queued' => (Icons.replay, Colors.orange, 'Will retry'),
        'failed' => (Icons.error, Colors.red, 'Failed'),
        _ => (Icons.schedule, Colors.grey, 'Waiting'),
      };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final counts = {for (final f in _Filter.values) f: widget.rows.where((r) => _match(f, r.status)).length};
    final q = _query.toLowerCase();
    final shown = [
      for (final r in widget.rows)
        if (_match(_filter, r.status) && (q.isEmpty || r.rel.toLowerCase().contains(q))) r,
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (widget.note != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(widget.note!, style: t.bodySmall)),
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
        child: shown.isEmpty
            ? Center(child: Text(widget.rows.isEmpty ? 'No files yet' : 'Nothing matches', style: t.bodyMedium))
            : ListView.builder(
                itemCount: shown.length,
                itemBuilder: (context, i) {
                  final r = shown[i];
                  final (icon, color, label) = _look(r.status);
                  final slash = r.rel.lastIndexOf('/');
                  return ListTile(
                    dense: true,
                    leading: Icon(icon, color: color),
                    title: Text(slash < 0 ? r.rel : r.rel.substring(slash + 1), maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '${slash < 0 ? '' : '${r.rel.substring(0, slash)} • '}${formatBytes(r.size)} • $label'
                      '${r.error == null ? '' : '\n${r.error}'}',
                      maxLines: r.error == null ? 1 : 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                },
              ),
      ),
    ]);
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
      title: Text(e.label),
      subtitle: Text('$numbers$state${t.note == null ? '' : ' — ${t.note}'}'),
      isThreeLine: numbers.isNotEmpty,
      trailing: trailing,
    );
  }
}
