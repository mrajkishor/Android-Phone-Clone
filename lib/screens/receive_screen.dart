import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../transfer/native.dart';
import '../transfer/protocol.dart';
import '../transfer/receiver.dart';
import 'permission_gate.dart';
import 'report_table.dart';
import 'transfer_widgets.dart';

class ReceiveScreen extends StatelessWidget {
  const ReceiveScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Receive on new phone')),
      body: const PermissionGate(
        reason: 'The new phone needs it to put every file back in the same folder it was in on the old phone.',
        child: _ReceiveBody(),
      ),
    );
  }
}

class _ReceiveBody extends StatefulWidget {
  const _ReceiveBody();

  @override
  State<_ReceiveBody> createState() => _ReceiveBodyState();
}

class _ReceiveBodyState extends State<_ReceiveBody> {
  final _service = ReceiverService();

  @override
  void initState() {
    super.initState();
    _service.start();
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final busy = _service.phase == ReceivePhase.receiving;
        return PopScope(
          canPop: !busy,
          onPopInvokedWithResult: (didPop, _) {
            // Back during a transfer: go to the background, keep receiving.
            if (!didPop) Native.moveToBackground();
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: switch (_service.phase) {
              ReceivePhase.starting => const Center(child: CircularProgressIndicator()),
              ReceivePhase.error => _ErrorView(message: _service.fatalError ?? 'Unknown error'),
              ReceivePhase.waiting => _WaitingView(pairing: _service.pairing!),
              ReceivePhase.receiving => _ProgressView(service: _service),
              ReceivePhase.done => _DoneView(service: _service),
            },
          ),
        );
      },
    );
  }
}

class _WaitingView extends StatelessWidget {
  final PairingInfo pairing;
  const _WaitingView({required this.pairing});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListView(
      children: [
        Text('On the OLD phone, open this app, tap “This is the OLD phone” and scan this code.',
            style: t.titleMedium, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        Center(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: QrImageView(data: pairing.toQr(), size: 240, backgroundColor: Colors.white),
          ),
        ),
        const SizedBox(height: 24),
        Text('Can’t scan? Enter manually:', style: t.bodyMedium, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        SelectableText('Address  ${pairing.host}:${pairing.port}', style: t.titleMedium, textAlign: TextAlign.center),
        SelectableText('Code  ${pairing.code}',
            style: t.headlineSmall?.copyWith(letterSpacing: 4, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Card(
          elevation: 0,
          color: Colors.green.withValues(alpha: 0.08),
          child: const ListTile(
            leading: Icon(Icons.bolt, color: Colors.green),
            title: Text('Tip for the fastest transfer'),
            subtitle: Text('Turn on this phone’s hotspot (5 GHz if offered), join it from the old phone, '
                'and keep the phones next to each other.'),
          ),
        ),
        const SizedBox(height: 16),
        const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 12),
          Text('Waiting for the old phone…'),
        ]),
      ],
    );
  }
}

class _ProgressView extends StatelessWidget {
  final ReceiverService service;
  const _ProgressView({required this.service});

  @override
  Widget build(BuildContext context) {
    final s = service;
    final st = s.sender;
    final retrying = st['phase'] == 'retrying';
    final banner = s.senderPaused
        ? const StatusBanner(
            icon: Icons.pause_circle_filled,
            color: Colors.amber,
            title: 'Paused on the old phone',
            subtitle: 'It will continue from exactly where it stopped.')
        : s.senderReconnecting
            ? const StatusBanner(
                icon: Icons.wifi_find,
                color: Colors.deepOrange,
                title: 'Reconnecting…',
                subtitle: 'Keep both phones on the same Wi-Fi.')
            : retrying
                ? StatusBanner(
                    icon: Icons.replay,
                    color: Colors.orange,
                    title: 'Retrying failed files — round ${st['retryRound']} of ${st['retryRounds']}',
                    subtitle: st['nextRetryIn'] == null ? 'Retrying now' : 'Next try in ${(st['nextRetryIn'] as int) + 1} s',
                  )
                : const StatusBanner(
                    icon: Icons.download_rounded,
                    color: Colors.blue,
                    title: 'Receiving',
                    subtitle: 'You can leave the app. Receiving continues in the background.');

    final bytesDone = st['bytesDone'] as int? ?? s.bytesReceived;
    final totalBytes = st['totalBytes'] as int? ?? s.expectedBytes;
    final speed = (st['speed'] as num?)?.toDouble() ?? 0;
    final eta = speed > 0 ? Duration(seconds: ((totalBytes - bytesDone) / speed).ceil()) : null;
    final dlq = s.senderDlq;

    return ListView(children: [
      banner,
      const SizedBox(height: 16),
      OverallProgress(
        bytesDone: bytesDone,
        totalBytes: totalBytes,
        speed: s.senderPaused ? 0 : speed,
        eta: eta,
        filesLine: '${s.filesProcessed} of ${s.expectedFiles} files saved and verified',
        extraLines: [
          if (s.alreadyBeforeStart > 0) '${s.alreadyBeforeStart} files were already here — skipped',
          if (s.expectedContacts > 0) 'Contacts: ${s.contactsAdded} added, ${s.contactsExisting} already here',
        ],
      ),
      const SizedBox(height: 12),
      if (s.inFlight.length > 1)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(children: [
            const Icon(Icons.bolt, size: 18, color: Colors.green),
            const SizedBox(width: 6),
            Text('${s.inFlight.length} arriving at once', style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      for (final f in s.inFlight.values)
        CurrentFileCard(
          name: f.name.isEmpty ? 'Starting batch…' : f.name,
          bytes: f.bytes,
          total: f.total,
          note: f.batch
              ? 'Batch of ${f.batchCount} small files • ${f.batchDone} saved'
              : (f.total > 0 && f.bytes >= f.total ? 'Verifying checksum and saving…' : null),
        ),
      const SizedBox(height: 8),
      RecentFilesList(items: [for (final r in s.recent) (r.rel, r.size, r.alreadyThere)]),
      if (dlq.isNotEmpty) ...[
        const SizedBox(height: 12),
        RetryQueuePanel(entries: [
          for (final d in dlq)
            QueueEntry(d['rel'] as String, d['error'] as String, d['attempts'] as int,
                (st['retryRounds'] as int? ?? 4) + 1, d['status'] as String),
        ]),
      ],
      const SizedBox(height: 16),
      const Text('Keep both phones near each other until the transfer finishes.', textAlign: TextAlign.center),
    ]);
  }
}

class _DoneView extends StatelessWidget {
  final ReceiverService service;
  const _DoneView({required this.service});

  @override
  Widget build(BuildContext context) {
    final s = service;
    final t = Theme.of(context).textTheme;
    final allGood = s.complete && s.contactsFailed == 0;
    return ListView(
      children: [
        if (allGood)
          HurrayHeader(
            detail: '${s.savedTotal} files copied, ${s.alreadyTotal} were already here'
                '${s.contactsAdded > 0 ? ', ${s.contactsAdded} contacts added' : ''}. '
                'Every file is in the same folder it had on the old phone, with its original date.',
          )
        else ...[
          Icon(s.senderCancelled ? Icons.stop_circle_outlined : Icons.info_rounded, size: 64, color: Colors.orange),
          const SizedBox(height: 8),
          Text(
            s.senderCancelled ? 'Transfer stopped on the old phone' : 'Finished — some files need attention',
            style: t.headlineSmall,
            textAlign: TextAlign.center,
          ),
          if (s.senderCancelled)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Start again from the old phone to continue. Files already here are skipped.'),
            ),
        ],
        const SizedBox(height: 16),
        ReportTable(rows: [
          for (final c in Category.values)
            if (s.tally[c]!.saved + s.tally[c]!.already > 0) (c.label, s.tally[c]!.saved, s.tally[c]!.already, 0),
          if (s.contactsAdded + s.contactsExisting + s.contactsFailed > 0)
            ('Contacts', s.contactsAdded, s.contactsExisting, s.contactsFailed),
        ]),
        if (s.alreadyBeforeStart > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Plus ${s.alreadyBeforeStart} files that were already here from an earlier transfer.'),
          ),
        if (s.clonedFiles > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('${s.clonedFiles} identical files were copied here instead of being sent again '
                '(${formatBytes(s.clonedBytes)} saved).'),
          ),
        const SizedBox(height: 8),
        if (s.finalFailures.isNotEmpty)
          FailedFilesCard(items: [
            for (final f in s.finalFailures) ('${f['rel']}', '${f['error']}'),
          ]),
        if (s.errors.isNotEmpty)
          ExpansionTile(
            title: Text('${s.errors.length} other problem(s)'),
            children: [for (final e in s.errors) ListTile(dense: true, title: Text(e))],
          ),
        const SizedBox(height: 16),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Finish')),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  const _ErrorView({required this.message});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.wifi_off_rounded, size: 64),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Back')),
        ]),
      );
}
