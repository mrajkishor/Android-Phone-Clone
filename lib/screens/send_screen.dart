import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

import '../transfer/native.dart';
import '../transfer/protocol.dart';
import '../transfer/scanner.dart';
import '../transfer/sender.dart';
import 'permission_gate.dart';
import 'report_table.dart';
import 'scan_screen.dart';
import 'transfer_widgets.dart';

class SendScreen extends StatelessWidget {
  const SendScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send from old phone')),
      body: const PermissionGate(
        reason: 'The old phone needs it to find every file: documents, downloads, WhatsApp files and more. '
            'The app only reads files. Nothing on this phone is changed or deleted.',
        child: _SendBody(),
      ),
    );
  }
}

enum _Step { connect, preparing, choose, transfer }

class _SendBody extends StatefulWidget {
  const _SendBody();

  @override
  State<_SendBody> createState() => _SendBodyState();
}

class _SendBodyState extends State<_SendBody> {
  _Step _step = _Step.connect;
  String? _error;
  SenderService? _sender;

  ScanResult? _scan;
  List<Contact> _contacts = [];
  final Set<Category> _selected = {for (final c in Category.values) if (c.onByDefault) c};
  bool _sendContacts = true;
  SendPlan? _plan;

  @override
  void dispose() {
    _sender?.dispose();
    super.dispose();
  }

  Future<void> _scanAndConnect() async {
    final pairing = await Navigator.push<PairingInfo>(context, MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (pairing == null) return;
    setState(() {
      _step = _Step.preparing;
      _error = null;
    });
    final sender = SenderService(pairing);
    try {
      await sender.ping();
    } catch (e) {
      sender.dispose();
      setState(() {
        _step = _Step.connect;
        _error = 'Couldn’t reach the new phone at ${pairing.host}.\n'
            'Make sure both phones are on the same Wi-Fi (or the old phone is on the new phone’s hotspot).\n\n$e';
      });
      return;
    }
    _sender = sender;
    try {
      await StoragePermission.requestMediaRead();
      _contacts = await SenderService.loadContacts();
      _scan = await scanDevice();
    } catch (e) {
      setState(() {
        _step = _Step.connect;
        _error = 'Couldn’t read this phone’s storage: $e';
      });
      return;
    }
    setState(() => _step = _Step.choose);
  }

  void _start() {
    final files = [for (final c in _selected) ..._scan!.byCategory[c]!];
    final contacts = _sendContacts ? _contacts : <Contact>[];
    if (files.isEmpty && contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nothing selected.')));
      return;
    }
    _plan = SendPlan(files, contacts);
    setState(() => _step = _Step.transfer);
    _sender!.run(_plan!);
  }

  Future<void> _confirmStop() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop the transfer?'),
        content: const Text('Files already sent stay on the new phone. When you start again, '
            'they are skipped and half-sent files continue where they stopped.\n\n'
            'To take a break instead, use Pause.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep going')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Stop')),
        ],
      ),
    );
    if (ok == true) _sender?.cancel();
  }

  bool get _busy => switch (_sender?.phase) {
        SendPhase.checking || SendPhase.sending || SendPhase.retrying => true,
        _ => false,
      };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([if (_sender != null) _sender!]),
      builder: (context, _) {
        return PopScope(
          canPop: !_busy,
          onPopInvokedWithResult: (didPop, _) {
            // Back during a transfer: go to the background, keep transferring.
            if (!didPop) Native.moveToBackground();
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: switch (_step) {
              _Step.connect => _buildConnect(),
              _Step.preparing => const Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Connected. Finding everything on this phone…'),
                    SizedBox(height: 4),
                    Text('This can take a minute on phones with lots of files.'),
                  ]),
                ),
              _Step.choose => _buildChoose(),
              _Step.transfer => _busy || _sender!.phase == SendPhase.idle ? _buildRunning() : _buildResult(),
            },
          ),
        );
      },
    );
  }

  Widget _buildConnect() {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('1. On the new phone, open this app and tap “This is the NEW phone”.', style: t.bodyLarge),
        const SizedBox(height: 8),
        Text('2. Scan the QR code it shows.', style: t.bodyLarge),
        const SizedBox(height: 32),
        FilledButton.icon(
          onPressed: _scanAndConnect,
          icon: const Icon(Icons.qr_code_scanner),
          label: const Padding(padding: EdgeInsets.all(12), child: Text('Scan QR code')),
        ),
        if (_error != null) ...[
          const SizedBox(height: 24),
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
          ),
        ],
      ],
    );
  }

  Widget _buildChoose() {
    final scan = _scan!;
    final files = _selected.fold(0, (s, c) => s + scan.count(c));
    final bytes = _selected.fold(0, (s, c) => s + scan.bytes(c));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          const Icon(Icons.link, color: Colors.green),
          const SizedBox(width: 8),
          Expanded(child: Text('Connected to ${_sender!.pairing.host}')),
        ]),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(children: [
            for (final c in Category.values)
              SwitchListTile(
                title: Text(c.label),
                subtitle: Text('${scan.count(c)} files • ${formatBytes(scan.bytes(c))}\n${c.description}'),
                isThreeLine: true,
                value: scan.count(c) > 0 && _selected.contains(c),
                onChanged: scan.count(c) == 0
                    ? null
                    : (v) => setState(() => v ? _selected.add(c) : _selected.remove(c)),
              ),
            SwitchListTile(
              title: const Text('Contacts'),
              subtitle: Text('${_contacts.length} contacts\nWith photos. Contacts already on the new phone are skipped.'),
              isThreeLine: true,
              value: _contacts.isNotEmpty && _sendContacts,
              onChanged: _contacts.isEmpty ? null : (v) => setState(() => _sendContacts = v),
            ),
            if (scan.unreadable > 0)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('${scan.unreadable} folders or files couldn’t be read (protected by Android).',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
          ]),
        ),
        const SizedBox(height: 8),
        Text(
          '$files files • ${formatBytes(bytes)}${_sendContacts && _contacts.isNotEmpty ? ' • ${_contacts.length} contacts' : ''}',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _start,
          child: const Padding(padding: EdgeInsets.all(12), child: Text('Start transfer')),
        ),
      ],
    );
  }

  List<QueueEntry> _queueEntries(SenderService s) => [
        for (final d in s.dlq)
          QueueEntry(d.file.rel, d.lastError, d.attempts, s.maxAttempts, d.status.name),
      ];

  Widget _buildRunning() {
    final s = _sender!;

    if (s.phase == SendPhase.checking || s.phase == SendPhase.idle) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(s.statusLine ?? 'Starting…', textAlign: TextAlign.center),
        ]),
      );
    }

    final banner = s.paused
        ? const StatusBanner(
            icon: Icons.pause_circle_filled,
            color: Colors.amber,
            title: 'Paused',
            subtitle: 'Tap Resume to continue from exactly where it stopped.')
        : s.reconnecting
            ? const StatusBanner(
                icon: Icons.wifi_find,
                color: Colors.deepOrange,
                title: 'Waiting for the new phone…',
                subtitle: 'Keep both phones on the same Wi-Fi. The transfer continues automatically.')
            : s.phase == SendPhase.retrying
                ? StatusBanner(
                    icon: Icons.replay,
                    color: Colors.orange,
                    title: 'Retrying failed files — round ${s.retryRound} of ${s.retryRounds}',
                    subtitle: s.nextRetryIn == null
                        ? 'Retrying now'
                        : 'Next try in ${s.nextRetryIn!.inSeconds + 1} s',
                  )
                : const StatusBanner(
                    icon: Icons.upload_rounded,
                    color: Colors.blue,
                    title: 'Sending',
                    subtitle: 'You can leave the app. The transfer continues in the background.');

    final f = s.currentFile;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: ListView(children: [
          banner,
          const SizedBox(height: 16),
          OverallProgress(
            bytesDone: s.bytesDone,
            totalBytes: s.totalBytes,
            speed: s.bytesPerSecond,
            eta: s.eta,
            filesLine: '${s.filesProcessed} of ${s.filesToSend} files',
            extraLines: [
              if (s.filesAlready > 0) '${s.filesAlready} already on the new phone — skipped',
              if (s.contactsTotal > 0) 'Contacts: ${s.contactsAdded} added, ${s.contactsExisting} already there',
              if (s.statusLine != null) s.statusLine!,
            ],
          ),
          const SizedBox(height: 12),
          if (f != null)
            CurrentFileCard(
              name: f.rel,
              bytes: s.currentFileBytes,
              total: f.size,
              resumedFrom: s.currentFileResumedFrom,
            ),
          const SizedBox(height: 8),
          RecentFilesList(items: [for (final r in s.recent) (r.rel, r.size, r.alreadyThere)]),
          if (s.dlq.isNotEmpty) ...[
            const SizedBox(height: 12),
            RetryQueuePanel(entries: _queueEntries(s)),
          ],
        ]),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: FilledButton.tonalIcon(
            onPressed: s.paused ? s.resume : s.pause,
            icon: Icon(s.paused ? Icons.play_arrow : Icons.pause),
            label: Text(s.paused ? 'Resume' : 'Pause'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _confirmStop,
            icon: const Icon(Icons.stop),
            label: const Text('Stop'),
          ),
        ),
      ]),
    ]);
  }

  Widget _buildResult() {
    final s = _sender!;
    final t = Theme.of(context).textTheme;
    final failed = s.failedItems;
    final allGood = s.phase == SendPhase.done && failed.isEmpty && s.contactsFailed == 0;
    final r = s.receiverReport;

    final header = allGood
        ? HurrayHeader(
            detail: '${s.filesSent} files copied, ${s.filesAlready} were already there'
                '${s.contactsTotal > 0 ? ', ${s.contactsAdded} contacts added' : ''}. '
                'Every file was checksum-verified on the new phone.',
          )
        : Column(children: [
            Icon(
              s.phase == SendPhase.cancelled ? Icons.stop_circle_outlined : Icons.info_rounded,
              size: 64,
              color: s.phase == SendPhase.error ? Colors.red : Colors.orange,
            ),
            const SizedBox(height: 8),
            Text(
              switch (s.phase) {
                SendPhase.cancelled => 'Transfer stopped',
                SendPhase.error => 'Transfer interrupted',
                _ => 'Finished — ${failed.length} file(s) need attention',
              },
              style: t.headlineSmall,
              textAlign: TextAlign.center,
            ),
          ]);

    return ListView(children: [
      header,
      if (s.fatalError != null) Padding(padding: const EdgeInsets.all(12), child: Text(s.fatalError!)),
      if (s.phase == SendPhase.cancelled)
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text('Tap Continue to pick up where you left off. Files already on the new phone are skipped, '
              'and half-sent files continue from where they stopped.'),
        ),
      const SizedBox(height: 16),
      ReportTable(rows: [
        for (final c in Category.values)
          if (s.tally[c]!.selected > 0) (c.label, s.tally[c]!.sent, s.tally[c]!.already, s.tally[c]!.failed),
        if (s.contactsTotal > 0) ('Contacts', s.contactsAdded, s.contactsExisting, s.contactsFailed),
      ]),
      const SizedBox(height: 8),
      if (failed.isNotEmpty) FailedFilesCard(items: [for (final d in failed) (d.file.path, d.lastError)]),
      if (s.dlq.any((d) => d.status == DlqStatus.recovered))
        ListTile(
          leading: const Icon(Icons.replay, color: Colors.green),
          title: Text('${s.dlq.where((d) => d.status == DlqStatus.recovered).length} file(s) '
              'recovered from the retry queue'),
        ),
      if (r != null)
        ListTile(
          leading: const Icon(Icons.verified_outlined),
          title: const Text('Confirmed by the new phone'),
          subtitle: Text('${r['saved']} files copied and checksum-verified, ${r['already']} already there.'),
        ),
      const ListTile(
        leading: Icon(Icons.lock_outline),
        title: Text('Nothing on this phone was changed'),
        subtitle: Text('Files were only read, never moved or deleted.'),
      ),
      const SizedBox(height: 16),
      if (!allGood)
        FilledButton.icon(
          onPressed: () => _sender!.run(_plan!),
          icon: const Icon(Icons.refresh),
          label: Text(s.phase == SendPhase.done ? 'Try the failed files again' : 'Continue'),
        ),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
    ]);
  }
}
