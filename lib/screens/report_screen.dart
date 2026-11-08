import 'package:flutter/material.dart';

import '../transfer/extras.dart';
import '../transfer/native.dart';
import '../transfer/protocol.dart';
import '../transfer/session_store.dart';
import 'report_table.dart';
import 'tab_widgets.dart';
import 'transfer_widgets.dart';

String _when(DateTime t) {
  final now = DateTime.now();
  final d = DateTime(now.year, now.month, now.day).difference(DateTime(t.year, t.month, t.day)).inDays;
  final hm =
      '${t.hour % 12 == 0 ? 12 : t.hour % 12}:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'am' : 'pm'}';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  if (d == 0) return 'Today, $hm';
  if (d == 1) return 'Yesterday, $hm';
  return '${t.day} ${months[t.month - 1]} ${t.year == now.year ? '' : '${t.year} '}· $hm';
}

/// 14422 -> "14,422"
String _n(int v) => v.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');

String _outcomeText(TransferReport r) => switch (r.outcome) {
      'done' => r.failed == 0 ? 'Completed' : 'Completed, ${_n(r.failed)} failed',
      'stopped' => 'Stopped',
      _ => 'Interrupted',
    };

/// Where snapshots are kept, in words people can find in their Files app.
const snapshotFolderText = 'Internal storage › Documents › PhoneHop › Snapshots';

void _say(BuildContext context, String text) => ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));

/// Import a snapshot file someone shared; opens it when it's valid.
Future<TransferReport?> importSnapshot(BuildContext context) async {
  final picked = await NativeExtras.pickFile();
  if (picked == null || !context.mounted) return null;
  final r = await TransferReport.import(picked.$2);
  if (!context.mounted) return null;
  if (r == null) {
    _say(context, '“${picked.$1 ?? 'This file'}” isn’t a PhoneHop snapshot.');
    return null;
  }
  _say(context, 'Snapshot imported into $snapshotFolderText');
  await Navigator.push(context, MaterialPageRoute(builder: (_) => SnapshotScreen(report: r)));
  return r;
}

// ---------------------------------------------------------------------------
// Home-screen card
// ---------------------------------------------------------------------------

/// Home-screen card: the newest snapshot, plus "All snapshots" and "Import".
class LastTransferCard extends StatelessWidget {
  final TransferReport report;
  final int count;
  final VoidCallback onOpen;
  final VoidCallback onAll;
  final VoidCallback onImport;
  const LastTransferCard({
    super.key,
    required this.report,
    required this.count,
    required this.onOpen,
    required this.onAll,
    required this.onImport,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final r = report;
    final ok = r.outcome == 'done' && r.failed == 0;
    return Card(
      elevation: 0,
      color: cs.surfaceContainerHigh,
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
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
                  Text('${_n(r.files.length)} files · ${formatBytes(r.bytes)} · ${_n(r.onNewPhone)} on the new phone',
                      style: t.bodySmall),
                ]),
              ),
              const Icon(Icons.chevron_right),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: Row(children: [
            TextButton.icon(
              onPressed: onAll,
              icon: const Icon(Icons.history, size: 18),
              label: Text(count > 1 ? 'All snapshots ($count)' : 'Snapshots'),
            ),
            const Spacer(),
            TextButton.icon(
                onPressed: onImport, icon: const Icon(Icons.file_open_outlined, size: 18), label: const Text('Import')),
          ]),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// One snapshot: Summary / Files / Extras, read-only
// ---------------------------------------------------------------------------

class SnapshotScreen extends StatelessWidget {
  final TransferReport report;
  const SnapshotScreen({super.key, required this.report});

  Future<void> _share(BuildContext context) async {
    final path = report.path;
    final ok = path != null && await NativeExtras.shareFile(path, title: 'PhoneHop snapshot · ${report.name}');
    if (!ok && context.mounted) _say(context, 'Couldn’t share this snapshot.');
  }

  Future<void> _showFolder(BuildContext context) async {
    final path = report.path;
    final ok = path != null && await NativeExtras.showInFilesApp(path);
    if (!ok && context.mounted) _say(context, 'Couldn’t open the Files app on this phone.');
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
    final tally = {
      for (final e in Extra.values) e: ExtraTally.fromJson(r.extras[e.name] ?? const {'state': 'pending'})
    };
    final shownExtras = [
      for (final e in Extra.values)
        if (r.extras.containsKey(e.name)) e
    ];
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(r.sent ? 'Sent' : 'Received'),
          Text(_when(r.when), style: Theme.of(context).textTheme.bodySmall),
        ]),
        actions: [
          IconButton(
              tooltip: 'Export (share)', icon: const Icon(Icons.share_outlined), onPressed: () => _share(context)),
          IconButton(
            tooltip: 'Show in Files app',
            icon: const Icon(Icons.folder_open_outlined),
            onPressed: () => _showFolder(context),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: TransferTabs(
          progress: _Summary(report: r),
          files: FileCompareList(
            rows: rows,
            note: r.sent
                ? 'Every file chosen on this phone, as it stood when the transfer ended.'
                : 'Files from the old phone: copied in this transfer, or already here from before.',
          ),
          extras: ExtrasStatusList(
            tally: tally,
            shown: shownExtras,
            newPhone: !r.sent,
            footer: [if (r.apps.isNotEmpty) _AppsList(apps: r.apps)],
          ),
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  final TransferReport report;
  const _Summary({required this.report});

  @override
  Widget build(BuildContext context) {
    final r = report;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final ok = r.outcome == 'done' && r.failed == 0;
    final failed = [
      for (final f in r.files)
        if (f.status == 'failed') (f.path ?? f.rel, f.error ?? 'Failed')
    ];
    return ListView(children: [
      Card(
        elevation: 0,
        color: cs.secondaryContainer,
        child: ListTile(
          leading: Icon(Icons.inventory_2_outlined, color: cs.onSecondaryContainer),
          title: Text('Snapshot · read-only', style: TextStyle(color: cs.onSecondaryContainer)),
          subtitle: Text(
            'Saved on this phone in $snapshotFolderText. It stays there after the other phone is gone '
            'and even if PhoneHop is uninstalled. Share it with the export button above.',
            style: TextStyle(color: cs.onSecondaryContainer),
          ),
          isThreeLine: true,
        ),
      ),
      const SizedBox(height: 16),
      Icon(ok ? Icons.check_circle : Icons.info_rounded, size: 56, color: ok ? Colors.green : Colors.orange),
      const SizedBox(height: 8),
      Text(_outcomeText(r), style: t.headlineSmall, textAlign: TextAlign.center),
      Text(
        '${r.sent ? 'Sent from this phone' : 'Received on this phone'} · ${_when(r.when)}'
        '${r.appVersion.isEmpty ? '' : ' · PhoneHop ${r.appVersion}'}',
        style: t.bodySmall,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 12),
      for (final l in r.lines)
        Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(l, textAlign: TextAlign.center)),
      const SizedBox(height: 12),
      if (r.rows.isNotEmpty)
        ReportTable(rows: [for (final x in r.rows) (x.label, x.copied, x.already, x.failed)])
      else
        Text('${_n(r.files.length)} files · ${formatBytes(r.bytes)} · ${_n(r.onNewPhone)} on the new phone',
            textAlign: TextAlign.center),
      if (failed.isNotEmpty) ...[const SizedBox(height: 12), FailedFilesCard(items: failed)],
    ]);
  }
}

class _AppsList extends StatelessWidget {
  final List<SnapshotApp> apps;
  const _AppsList({required this.apps});

  @override
  Widget build(BuildContext context) => Card(
        elevation: 0,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ListTile(
            leading: const Icon(Icons.apps),
            title: Text('${apps.length} ${apps.length == 1 ? 'app' : 'apps'} from the old phone'),
            subtitle: const Text('To install the ones still missing, open the Play Store, or start a new transfer.'),
          ),
          for (final a in apps)
            ListTile(
              dense: true,
              title: Text(a.label),
              subtitle: Text([if (a.versionName != null) 'v${a.versionName}', a.package].join(' • ')),
              trailing: a.state == 'installed'
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : Text('Not installed', style: Theme.of(context).textTheme.bodySmall),
            ),
        ]),
      );
}

// ---------------------------------------------------------------------------
// All snapshots
// ---------------------------------------------------------------------------

class SnapshotsScreen extends StatefulWidget {
  const SnapshotsScreen({super.key});

  @override
  State<SnapshotsScreen> createState() => _SnapshotsScreenState();
}

class _SnapshotsScreenState extends State<SnapshotsScreen> {
  List<TransferReport>? _all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await TransferReport.all();
    if (mounted) setState(() => _all = all);
  }

  Future<void> _open(TransferReport r) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => SnapshotScreen(report: r)));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final all = _all;
    return Scaffold(
      appBar: AppBar(title: const Text('Transfer snapshots')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await importSnapshot(context);
          await _load();
        },
        icon: const Icon(Icons.file_open_outlined),
        label: const Text('Import'),
      ),
      body: all == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 96), children: [
              Text(
                  'Each transfer leaves a read-only snapshot of its Progress, Files and Extras. '
                  'They are kept in $snapshotFolderText.',
                  style: t.bodySmall),
              const SizedBox(height: 8),
              if (all.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(24), child: Text('No snapshots yet.', textAlign: TextAlign.center)),
              for (final r in all)
                Card(
                  elevation: 0,
                  child: ListTile(
                    leading: Icon(r.sent ? Icons.upload_rounded : Icons.download_rounded),
                    title: Text('${r.sent ? 'Sent' : 'Received'} · ${_when(r.when)}'),
                    subtitle: Text('${_outcomeText(r)} · ${_n(r.files.length)} files · ${formatBytes(r.bytes)}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(r),
                  ),
                ),
            ]),
    );
  }
}
