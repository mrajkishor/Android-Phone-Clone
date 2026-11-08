import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../transfer/extras.dart';
import '../transfer/native.dart';
import '../transfer/protocol.dart';
import '../transfer/receiver.dart';
import 'permission_gate.dart';
import 'report_table.dart';
import 'tab_widgets.dart';
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
  Extra? _prompting; // a popup is open for this

  /// The old phone is waiting for an OK here (messages, call history, calendar, ringtones).
  void _maybePrompt() {
    final e = _service.pendingPrompt;
    if (e == null || _prompting != null || !mounted) return;
    _prompting = e;
    showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: Icon(ExtrasStatusList.iconOf(e)),
        title: Text('Restore ${e.label.toLowerCase()}?'),
        content: Text('${e.newPhonePrompt}\n\nNothing already on this phone is changed or removed; '
            'only missing items are added.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Skip')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Allow')),
        ],
      ),
    ).then((allow) async {
      await _service.answerPrompt(e, allow == true);
      _prompting = null;
      // "Modify system settings" is a switch in Settings: ask again if it is still off.
      if (_service.pendingPrompt != null) {
        await Future<void>.delayed(const Duration(seconds: 2));
        _maybePrompt();
      }
    });
  }

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
        if (_service.pendingPrompt != null && _prompting == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _maybePrompt());
        }
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
              ReceivePhase.receiving => _tabs(_ProgressView(service: _service)),
              ReceivePhase.done => _tabs(_DoneView(service: _service)),
            },
          ),
        );
      },
    );
  }
}

extension on _ReceiveBodyState {
  Widget _tabs(Widget progress) {
    final s = _service;
    final rows = [
      for (final f in s.sessionFiles) FileRow(f.rel, f.size, f.status, category: f.category, path: f.path),
      for (final f in s.finalFailures) FileRow('${f['rel']}', 0, 'failed', error: '${f['error']}'),
    ];
    final fromOld = ((s.sender['extras'] as Map?) ?? const {}).keys.toSet();
    final shown = [
      for (final e in Extra.values)
        if (fromOld.contains(e.name) || s.extraTally[e]!.state != 'pending') e,
    ];
    return TransferTabs(
      progress: progress,
      files: FileCompareList(
        rows: rows,
        note: 'Files from the old phone: copied in this transfer, or already here from before (not sent again).',
      ),
      extras: ExtrasStatusList(
          tally: s.extraTally,
          shown: shown,
          newPhone: true,
          onRetry: s.phase == ReceivePhase.receiving && !s.senderLost ? s.requestRetry : null,
          retryHint: 'To try again, tap “Try again” on the old phone.',
          footer: [
        if (s.smsRoleToHandBack)
          Card(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: ListTile(
              leading: const Icon(Icons.sms),
              title: const Text('Messages restored'),
              subtitle: const Text('Make your usual messaging app the default SMS app again.'),
              trailing: FilledButton(onPressed: s.handBackSmsRole, child: const Text('Switch back')),
            ),
          ),
        if (s.apps.isNotEmpty) _AppsCard(service: s),
        _WhatsAppCard(backupCopied: s.whatsappBackup),
      ]),
      extrasBadge: (s.pendingPrompt != null ? 1 : 0) + s.apps.where((a) => a.state == 'ready').length,
    );
  }
}

/// WhatsApp chats: the built-in "Transfer chats" (recommended), or the local backup.
class _WhatsAppCard extends StatelessWidget {
  final bool backupCopied;
  const _WhatsAppCard({required this.backupCopied});

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          leading: const Icon(Icons.chat),
          title: const Text('WhatsApp chats'),
          subtitle: Text('Recommended: WhatsApp’s own Transfer chats. Install WhatsApp here, verify your number and '
              'choose “Transfer from old phone”; on the old phone open WhatsApp → Settings → Chats → '
              'Transfer chats and scan the code. Same Wi-Fi, Location on, no Google Drive needed.\n\n'
              '${backupCopied ? 'A local WhatsApp backup was also copied: if WhatsApp offers it during setup, tap Restore. '
                  'Check its date: an older Google Drive backup may be offered first.' : 'Or: make a local backup on the old phone '
                  '(Chats → Chat backup → Back up) before the transfer, and restore it here during setup.'}'),
          isThreeLine: true,
        ),
      );
}

class _AppsCard extends StatelessWidget {
  final ReceiverService service;
  const _AppsCard({required this.service});

  @override
  Widget build(BuildContext context) {
    final apps = service.apps;
    final todo = apps.where((a) => a.state == 'ready' || a.state == 'failed').toList();
    return Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ListTile(
          leading: const Icon(Icons.apps),
          title: Text('${apps.length} apps to install'),
          subtitle: const Text('Android asks you to confirm each one. App data and logins are not included; '
              'apps from the Play Store keep updating from there.'),
          isThreeLine: true,
        ),
        if (todo.length > 1)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              onPressed: () async {
                for (final a in todo) {
                  await service.installApp(a);
                }
              },
              icon: const Icon(Icons.download_for_offline),
              label: Text('Install all ${todo.length}'),
            ),
          ),
        for (final a in apps)
          ListTile(
            dense: true,
            title: Text(a.label),
            subtitle: Text([
              if (a.versionName != null) 'v${a.versionName}',
              if (a.fromPlay) 'from Play Store',
              if (a.message != null && a.state == 'failed') a.message!,
            ].join(' • ')),
            trailing: switch (a.state) {
              'installed' => const Icon(Icons.check_circle, color: Colors.green),
              'installing' => const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              _ => Row(mainAxisSize: MainAxisSize.min, children: [
                  if (a.fromPlay)
                    IconButton(
                      tooltip: 'Open in Play Store',
                      icon: const Icon(Icons.shop),
                      onPressed: () => NativeExtras.openPlayStore(a.package),
                    ),
                  TextButton(onPressed: () => service.installApp(a), child: Text(a.state == 'failed' ? 'Retry' : 'Install')),
                ]),
            },
          ),
      ]),
    );
  }
}

/// QR code plus the address and code to type in by hand.
class _PairingCard extends StatelessWidget {
  final PairingInfo pairing;
  final double size;
  const _PairingCard({required this.pairing, this.size = 240});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Center(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
          child: QrImageView(data: pairing.toQr(), size: size, backgroundColor: Colors.white),
        ),
      ),
      const SizedBox(height: 16),
      Text('Can’t scan? Enter manually:', style: t.bodyMedium, textAlign: TextAlign.center),
      const SizedBox(height: 8),
      SelectableText('Address  ${pairing.host}:${pairing.port}', style: t.titleMedium, textAlign: TextAlign.center),
      SelectableText('Code  ${pairing.code}',
          style: t.headlineSmall?.copyWith(letterSpacing: 4, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
    ]);
  }
}

/// Shows the current QR code; it redraws itself if this phone's address changes.
void _showPairingDialog(BuildContext context, ReceiverService service) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Connect the old phone again'),
      content: SingleChildScrollView(
        child: ListenableBuilder(
          listenable: service,
          builder: (_, __) => Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('On the old phone: open Phone Clone → This is the OLD phone → Scan QR code. '
                'Files already here are skipped; an interrupted file continues where it stopped.'),
            const SizedBox(height: 16),
            _PairingCard(pairing: service.pairing!, size: 200),
          ]),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
    ),
  );
}

/// Top of the progress screen: this phone's address (to compare with the old
/// phone) and a one-tap way back to the QR code.
class _AddressBar extends StatelessWidget {
  final ReceiverService service;
  const _AddressBar({required this.service});

  @override
  Widget build(BuildContext context) {
    final p = service.pairing!;
    return Row(children: [
      FilledButton.tonalIcon(
        onPressed: () => _showPairingDialog(context, service),
        icon: const Icon(Icons.qr_code_2),
        label: const Text('Show QR'),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('This phone’s address', style: Theme.of(context).textTheme.labelSmall),
          SelectableText('${p.host}:${p.port}', style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
      ),
    ]);
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
        _PairingCard(pairing: pairing),
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

    if (s.senderLost) {
      return ListView(children: [
        StatusBanner(
          icon: Icons.link_off,
          color: Colors.red,
          title: 'Connection to the old phone lost',
          subtitle: s.addressChanged
              ? 'This phone’s address has changed. Scan the QR code below from the old phone to continue.'
              : 'Check both phones are on the same Wi-Fi or hotspot, then scan this QR code from the old phone.',
        ),
        const SizedBox(height: 16),
        const Text('On the old phone: open Phone Clone → This is the OLD phone → Scan QR code. '
            'Nothing is lost: files already here are skipped and the interrupted file continues where it stopped.'),
        const SizedBox(height: 16),
        _PairingCard(pairing: s.pairing!),
        const SizedBox(height: 16),
        Text('Received so far: ${s.filesProcessed} files • ${formatBytes(s.bytesReceived)}',
            textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
      ]);
    }

    return ListView(children: [
      _AddressBar(service: s),
      const SizedBox(height: 12),
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
          if (s.refusedRequests > 0) 'Another phone or app tried to send at the same time and was turned away',
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
          for (final e in Extra.values)
            if (s.extraTally[e]!.state != 'pending')
              (e.label, s.extraTally[e]!.added, s.extraTally[e]!.existing, s.extraTally[e]!.failed),
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
