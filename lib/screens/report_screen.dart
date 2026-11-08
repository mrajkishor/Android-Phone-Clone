import 'package:flutter/material.dart';

import '../transfer/extras.dart';
import '../transfer/native.dart';
import '../transfer/protocol.dart';
import '../transfer/receiver.dart' show ReceivedApp, installReceivedApp;
import '../transfer/session_store.dart';
import 'file_visuals.dart';
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
// One snapshot: the same Progress, Files and Extras tabs as during the transfer
// ---------------------------------------------------------------------------

/// The transfer as it looked on this phone when it ended, with the same three tabs,
/// without the other phone. Apps can still be installed from it.
class SnapshotScreen extends StatefulWidget {
  final TransferReport report;
  const SnapshotScreen({super.key, required this.report});

  @override
  State<SnapshotScreen> createState() => _SnapshotScreenState();
}

class _SnapshotScreenState extends State<SnapshotScreen> {
  late final List<ReceivedApp> _apps = [
    for (final a in widget.report.installableApps)
      ReceivedApp(a.package, a.label, a.versionName, a.versionCode, a.fromPlay, a.paths)..state = a.state,
  ];
  bool _defaultSms = false;

  TransferReport get r => widget.report;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// What's true on this phone now: which apps are installed, whether PhoneHop is
  /// still the SMS app, and the real app names for apps found from their installers.
  Future<void> _refresh() async {
    for (var i = 0; i < _apps.length; i++) {
      var a = _apps[i];
      // Found from its installer files only: read the real name from the APK.
      if (a.label == a.package && a.paths.isNotEmpty) {
        final look = await FileVisuals.app(a.paths.first);
        if (look != null) {
          a = _apps[i] = ReceivedApp(look.package, look.label, look.versionName, a.versionCode, a.fromPlay, a.paths)
            ..state = a.state;
        }
      }
      try {
        final v = await NativeExtras.installedVersion(a.package);
        if (v >= 0 && (a.versionCode == 0 || v >= a.versionCode)) a.state = 'installed';
      } catch (_) {}
    }
    try {
      _defaultSms = !r.sent && await NativeExtras.isDefaultSmsApp();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _install(ReceivedApp a) => installReceivedApp(a, () {
        if (mounted) setState(() {});
      });

  Future<void> _share() async {
    final path = r.path;
    final ok = path != null && await NativeExtras.shareFile(path, title: 'PhoneHop snapshot · ${r.name}');
    if (!ok && mounted) _say(context, 'Couldn’t share this snapshot.');
  }

  Future<void> _showFolder() async {
    final path = r.path;
    final ok = path != null && await NativeExtras.showInFilesApp(path);
    if (!ok && mounted) _say(context, 'Couldn’t open the Files app on this phone.');
  }

  @override
  Widget build(BuildContext context) {
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
      for (final e in Extra.values) e: ExtraTally.fromJson(r.extras[e.name] ?? const {'state': 'pending'}),
    };
    final shownExtras = [
      for (final e in Extra.values)
        if (r.extras.containsKey(e.name)) e
    ];
    final whatsapp = r.files.any((f) => isWhatsAppBackup(f.rel));
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(r.sent ? 'Sent' : 'Received'),
          Text(_when(r.when), style: Theme.of(context).textTheme.bodySmall),
        ]),
        actions: [
          IconButton(tooltip: 'Export (share)', icon: const Icon(Icons.share_outlined), onPressed: _share),
          IconButton(
              tooltip: 'Show in Files app', icon: const Icon(Icons.folder_open_outlined), onPressed: _showFolder),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: TransferTabs(
          progress: _Progress(report: r, onShare: _share, onShowFolder: _showFolder),
          files: FileCompareList(
            rows: rows,
            note: r.sent
                ? 'Every file you chose on this phone, and whether it reached the new phone.'
                : 'Files from the old phone: copied in this transfer, or already here from before.',
          ),
          extras: ExtrasStatusList(
            tally: tally,
            shown: shownExtras,
            newPhone: !r.sent,
            emptyText: r.sent
                ? null
                : r.partial
                    ? 'This transfer was made with an older version of PhoneHop, which didn’t keep the results for '
                        'messages, call history, calendar, wallpaper and ringtones. Apps and WhatsApp are below.'
                    : null,
            footer: [
              if (_defaultSms)
                Card(
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  child: ListTile(
                    leading: const Icon(Icons.sms),
                    title: const Text('PhoneHop is still your SMS app'),
                    subtitle: const Text('Make your usual messaging app the default SMS app again.'),
                    trailing: FilledButton(
                      onPressed: () async {
                        await NativeExtras.restoreDefaultSmsApp();
                        await _refresh();
                      },
                      child: const Text('Switch back'),
                    ),
                  ),
                ),
              if (_apps.isNotEmpty) AppsInstallCard(apps: _apps, onInstall: _install),
              if (!r.sent) WhatsAppCard(backupCopied: whatsapp),
            ],
          ),
        ),
      ),
    );
  }
}

/// The finished screen of the transfer, as it was.
class _Progress extends StatelessWidget {
  final TransferReport report;
  final VoidCallback onShare;
  final VoidCallback onShowFolder;
  const _Progress({required this.report, required this.onShare, required this.onShowFolder});

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
    final copiedMedia = r.files.any((f) =>
        (f.category == 'photos' || f.category == 'videos') && const {'saved', 'sent', 'cloned'}.contains(f.status));
    final detail =
        r.lines.isNotEmpty ? r.lines.first : '${_n(r.onNewPhone)} files on the new phone · ${formatBytes(r.bytes)}.';
    return ListView(children: [
      if (ok)
        HurrayHeader(detail: detail)
      else ...[
        Icon(r.outcome == 'stopped' ? Icons.stop_circle_outlined : Icons.info_rounded, size: 64, color: Colors.orange),
        const SizedBox(height: 8),
        Text(
          switch (r.outcome) {
            'stopped' => 'Transfer stopped',
            'interrupted' => 'Transfer interrupted',
            _ => 'Finished — ${r.failed} file(s) need attention',
          },
          style: t.headlineSmall,
          textAlign: TextAlign.center,
        ),
        Padding(padding: const EdgeInsets.all(8), child: Text(detail, textAlign: TextAlign.center)),
      ],
      const SizedBox(height: 16),
      ReportTable(rows: [for (final x in r.table) (x.label, x.copied, x.already, x.failed)]),
      for (final l in r.lines.skip(1)) Padding(padding: const EdgeInsets.only(top: 8), child: Text(l)),
      if (!r.sent && copiedMedia)
        const ListTile(
          leading: Icon(Icons.photo_library_outlined),
          title: Text('Your albums are here too'),
          subtitle: Text('Photos and videos are in the same folders as on the old phone. '
              'In Google Photos, open Collections → On this device to see each folder as an album.'),
          isThreeLine: true,
        ),
      if (r.sent)
        const ListTile(
          leading: Icon(Icons.lock_outline),
          title: Text('Your files on this phone weren’t changed'),
          subtitle: Text('Files were only read, never moved or deleted.'),
        ),
      if (failed.isNotEmpty) ...[const SizedBox(height: 8), FailedFilesCard(items: failed)],
      const SizedBox(height: 16),
      // Where this snapshot is, so it can be found, shared or imported elsewhere.
      Card(
        elevation: 0,
        color: cs.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.inventory_2_outlined, size: 20),
              const SizedBox(width: 8),
              Text('Saved on this phone', style: t.titleSmall),
            ]),
            const SizedBox(height: 6),
            SelectableText(r.path ?? snapshotFolderText, style: t.bodySmall),
            const SizedBox(height: 4),
            Text(
              'Kept after the other phone is gone, even if PhoneHop is uninstalled.'
              '${r.source == 'records' ? ' Rebuilt from this phone’s record of received files.' : ''}',
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            Row(children: [
              TextButton.icon(
                  onPressed: onShare, icon: const Icon(Icons.share_outlined, size: 18), label: const Text('Export')),
              TextButton.icon(
                onPressed: onShowFolder,
                icon: const Icon(Icons.folder_open_outlined, size: 18),
                label: const Text('Show in Files app'),
              ),
            ]),
          ]),
        ),
      ),
    ]);
  }
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
