import 'package:flutter/material.dart';

import '../transfer/protocol.dart';
import '../transfer/session_store.dart';
import 'tab_widgets.dart';

String _when(DateTime t) {
  final now = DateTime.now();
  final d = DateTime(now.year, now.month, now.day).difference(DateTime(t.year, t.month, t.day)).inDays;
  final hm = '${t.hour % 12 == 0 ? 12 : t.hour % 12}:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'am' : 'pm'}';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  if (d == 0) return 'Today, $hm';
  if (d == 1) return 'Yesterday, $hm';
  return '${t.day} ${months[t.month - 1]}, $hm';
}

/// 14422 -> "14,422"
String _n(int v) => v.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');

String _outcomeText(TransferReport r) => switch (r.outcome) {
      'done' => r.failed == 0 ? 'Completed' : 'Completed, ${_n(r.failed)} failed',
      'stopped' => 'Stopped',
      _ => 'Interrupted',
    };

/// Home-screen card: the last transfer on this phone. Tap to see its files.
class LastTransferCard extends StatelessWidget {
  final TransferReport report;
  final VoidCallback onOpen;
  const LastTransferCard({super.key, required this.report, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final r = report;
    final ok = r.outcome == 'done' && r.failed == 0;
    return Card(
      elevation: 0,
      color: cs.surfaceContainerHigh,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            CircleAvatar(
              backgroundColor: ok ? Colors.green.withValues(alpha: 0.15) : Colors.orange.withValues(alpha: 0.15),
              child: Icon(ok ? Icons.check : Icons.history, color: ok ? Colors.green : Colors.orange),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Last transfer · ${r.sent ? 'sent' : 'received'}', style: t.titleSmall),
                const SizedBox(height: 2),
                Text('${_when(r.when)} · ${_outcomeText(r)}', style: t.bodySmall),
                Text(
                  '${_n(r.files.length)} files · ${formatBytes(r.bytes)} · ${_n(r.onNewPhone)} on the new phone',
                  style: t.bodySmall,
                ),
              ]),
            ),
            const Icon(Icons.chevron_right),
          ]),
        ),
      ),
    );
  }
}

/// The files of the last transfer, grouped like the Files tab. Read-only.
class ReportScreen extends StatelessWidget {
  final TransferReport report;
  const ReportScreen({super.key, required this.report});

  Future<void> _clear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear this list?'),
        content: const Text('Only the list is removed. No files are deleted from either phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true) return;
    await TransferReport.clear();
    if (context.mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final r = report;
    final rows = [
      for (final f in r.files)
        FileRow(
          f.rel,
          f.size,
          f.status,
          error: f.error,
          path: f.path,
          category: Category.values.where((c) => c.name == f.category).firstOrNull,
        ),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Last transfer'),
        actions: [
          IconButton(tooltip: 'Clear list', icon: const Icon(Icons.delete_outline), onPressed: () => _clear(context)),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: FileCompareList(
          rows: rows,
          note: '${r.sent ? 'Sent from this phone' : 'Received on this phone'} · ${_when(r.when)} · ${_outcomeText(r)}. '
              '${r.sent ? 'Status as it was when the transfer ended.' : 'Files copied then, or already here from before.'}',
        ),
      ),
    );
  }
}
