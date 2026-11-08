import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../transfer/protocol.dart';

/// Coloured strip at the top: paused / reconnecting / retrying / sending.
class StatusBanner extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Color color;

  const StatusBanner({super.key, required this.icon, required this.title, this.subtitle, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Icon(icon, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontWeight: FontWeight.bold, color: color)),
            if (subtitle != null) Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      ]),
    );
  }
}

/// Overall progress: bar, bytes, percentage, speed, time left, file count.
class OverallProgress extends StatelessWidget {
  final int bytesDone;
  final int totalBytes;
  final double speed;
  final Duration? eta;
  final String filesLine;
  final List<String> extraLines;

  const OverallProgress({
    super.key,
    required this.bytesDone,
    required this.totalBytes,
    required this.speed,
    required this.eta,
    required this.filesLine,
    this.extraLines = const [],
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final value = totalBytes == 0 ? null : (bytesDone / totalBytes).clamp(0.0, 1.0);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Text(value == null ? '…' : '${(value * 100).floor()}%', style: t.headlineMedium),
        const Spacer(),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${formatBytes(bytesDone)} of ${formatBytes(totalBytes)}'),
          Text(
            speed > 0 ? '${formatBytes(speed)}/s${eta == null ? '' : ' • ${formatDuration(eta!)} left'}' : '—',
            style: t.bodySmall,
          ),
        ]),
      ]),
      const SizedBox(height: 8),
      LinearProgressIndicator(value: value, minHeight: 10, borderRadius: BorderRadius.circular(5)),
      const SizedBox(height: 8),
      Text(filesLine),
      for (final l in extraLines) Text(l, style: t.bodySmall),
    ]);
  }
}

/// The file being transferred right now, byte by byte.
class CurrentFileCard extends StatelessWidget {
  final String name;
  final int bytes;
  final int total;
  final int resumedFrom;
  final String? note;

  const CurrentFileCard({
    super.key,
    required this.name,
    required this.bytes,
    required this.total,
    this.resumedFrom = 0,
    this.note,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final value = total == 0 ? 1.0 : (bytes / total).clamp(0.0, 1.0);
    final fileName = name.split('/').last;
    final folder = name.contains('/') ? name.substring(0, name.lastIndexOf('/')) : '';
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.insert_drive_file_outlined, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(fileName,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ]),
          if (folder.isNotEmpty)
            Text(folder, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: value, minHeight: 6, borderRadius: BorderRadius.circular(3)),
          const SizedBox(height: 6),
          Row(children: [
            Text('${formatBytes(bytes)} of ${formatBytes(total)}', style: t.bodySmall),
            const Spacer(),
            Text('${(value * 100).floor()}%', style: t.bodySmall),
          ]),
          if (resumedFrom > 0)
            Text('Continued from ${formatBytes(resumedFrom)} — the first part had already arrived',
                style: t.bodySmall?.copyWith(color: Colors.green)),
          if (note != null) Text(note!, style: t.bodySmall),
        ]),
      ),
    );
  }
}

/// Last few finished files.
class RecentFilesList extends StatelessWidget {
  final List<(String rel, int size, bool alreadyThere)> items;
  const RecentFilesList({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Just finished', style: t.labelLarge),
      for (final (rel, size, already) in items)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Icon(already ? Icons.done_all : Icons.check, size: 16, color: Colors.green),
            const SizedBox(width: 6),
            Expanded(child: Text(rel.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall)),
            Text(already ? 'already there' : formatBytes(size), style: t.bodySmall),
          ]),
        ),
    ]);
  }
}

/// One entry of the retry queue or of the final failed list.
class QueueEntry {
  final String rel;
  final String error;
  final int attempts;
  final int maxAttempts;
  final String status; // waiting | retrying | recovered | failed
  const QueueEntry(this.rel, this.error, this.attempts, this.maxAttempts, this.status);
}

/// The retry queue (DLQ), visible while the transfer runs.
class RetryQueuePanel extends StatelessWidget {
  final List<QueueEntry> entries;
  final String? header;
  const RetryQueuePanel({super.key, required this.entries, this.header});

  @override
  Widget build(BuildContext context) {
    final open = entries.where((e) => e.status != 'recovered').length;
    final t = Theme.of(context).textTheme;
    return Card(
      elevation: 0,
      color: Colors.orange.withValues(alpha: 0.08),
      child: ExpansionTile(
        initiallyExpanded: true,
        leading: const Icon(Icons.replay_circle_filled_outlined, color: Colors.orange),
        title: Text('Retry queue ($open)'),
        subtitle: Text(header ?? 'Skipped for now. Retried after all other files are done.'),
        children: [
          for (final e in entries)
            ListTile(
              dense: true,
              leading: Icon(
                switch (e.status) {
                  'recovered' => Icons.check_circle,
                  'retrying' => Icons.sync,
                  'failed' => Icons.error,
                  _ => Icons.schedule,
                },
                color: switch (e.status) {
                  'recovered' => Colors.green,
                  'failed' => Colors.red,
                  _ => Colors.orange,
                },
              ),
              title: Text(e.rel.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${e.rel}\n'
                '${switch (e.status) {
                  'recovered' => 'Transferred on attempt ${e.attempts}',
                  'retrying' => 'Retrying now (attempt ${e.attempts} of ${e.maxAttempts})',
                  'failed' => 'Gave up after ${e.attempts} attempts',
                  _ => 'Tried ${e.attempts} of ${e.maxAttempts}',
                }}'
                '${e.status == 'recovered' ? '' : '\n${e.error}'}',
                style: t.bodySmall,
              ),
              isThreeLine: true,
            ),
        ],
      ),
    );
  }
}

/// Final list of files that could not be transferred, with path and error,
/// and a button to copy it so they can be moved manually.
class FailedFilesCard extends StatelessWidget {
  final List<(String path, String error)> items;
  const FailedFilesCard({super.key, required this.items});

  String get _asText =>
      [for (final (path, error) in items) '$path\n    → $error'].join('\n');

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.error_outline, color: Colors.red),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${items.length} file(s) could not be transferred',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ]),
          const SizedBox(height: 4),
          Text('You can copy these manually (USB cable or a memory card).', style: t.bodySmall),
          const SizedBox(height: 8),
          for (final (path, error) in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SelectableText(path, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(error, style: t.bodySmall?.copyWith(color: Colors.red.shade700)),
              ]),
            ),
          const SizedBox(height: 4),
          OutlinedButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _asText));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('List copied')));
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy list'),
          ),
        ]),
      ),
    );
  }
}

/// Big celebration when everything made it.
class HurrayHeader extends StatelessWidget {
  final String detail;
  const HurrayHeader({super.key, required this.detail});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(children: [
      const Text('🎉', style: TextStyle(fontSize: 72)),
      Text('Hurray!', style: t.displaySmall?.copyWith(fontWeight: FontWeight.bold, color: Colors.green)),
      const SizedBox(height: 4),
      Text('Everything was transferred', style: t.titleMedium, textAlign: TextAlign.center),
      const SizedBox(height: 8),
      Text(detail, textAlign: TextAlign.center, style: t.bodySmall),
    ]);
  }
}
