import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

import '../transfer/extras.dart';
import '../transfer/native.dart';
import '../transfer/protocol.dart';
import '../transfer/scanner.dart';
import '../transfer/sender.dart';
import '../transfer/session_store.dart';
import 'permission_gate.dart';
import 'report_table.dart';
import 'scan_screen.dart';
import 'tab_widgets.dart';
import 'transfer_widgets.dart';

class SendScreen extends StatelessWidget {
  const SendScreen({super.key});

  /// Screenshots: connect to this new phone instead of scanning its QR code.
  @visibleForTesting
  static PairingInfo? debugPairing;

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
  ExtrasScan? _extras;
  final Set<Extra> _selectedExtras = {};
  SendPlan? _plan;
  LastSession? _last; // an unfinished transfer that can be continued

  @override
  void initState() {
    super.initState();
    LastSession.load().then((s) {
      if (mounted && s != null) setState(() => _last = s);
    });
  }

  @override
  void dispose() {
    _sender?.dispose();
    super.dispose();
  }

  Future<void> _scanAndConnect() async {
    final pairing = SendScreen.debugPairing ??
        await Navigator.push<PairingInfo>(context, MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (pairing == null) return;
    await _connect(pairing);
  }

  /// Continue the last unfinished transfer without scanning the QR code again.
  Future<void> _continueLast() async {
    final last = _last!;
    var ok = await _connect(last.pairing, quiet: true);
    if (!ok && mounted) {
      // The new phone's address probably changed (e.g. the hotspot restarted):
      // go straight to the scanner and keep the previous choices.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('The new phone isn’t at ${last.pairing.host} any more. Scan the QR code it shows now.'),
      ));
      final pairing =
          await Navigator.push<PairingInfo>(context, MaterialPageRoute(builder: (_) => const ScanScreen()));
      if (pairing == null) {
        setState(() => _error = 'Couldn’t reach the new phone at ${last.pairing.host}. '
            'On the new phone, tap “Show QR” and scan it from here.');
        return;
      }
      ok = await _connect(pairing);
      if (!ok) return;
    }
    setState(() {
      _selected
        ..clear()
        ..addAll(last.categories);
      _sendContacts = last.contacts;
    });
  }

  Future<bool> _connect(PairingInfo pairing, {bool quiet = false}) async {
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
        _error = quiet
            ? null
            : 'Couldn’t reach the new phone at ${pairing.host}.\n'
                'Make sure both phones are on the same Wi-Fi (or the old phone is on the new phone’s hotspot).\n\n$e';
      });
      return false;
    }
    _sender = sender;
    try {
      await StoragePermission.requestMediaRead();
      _contacts = await SenderService.loadContacts();
      _scan = await scanDevice();
      // Messages, calls, calendar (each asks for permission here), apps, wallpaper, ringtones.
      _extras = await ExtrasScan.scan(await Native.storageRoots());
      _selectedExtras
        ..clear()
        ..addAll([for (final e in Extra.values) if (_extras!.count(e) > 0) e]);
    } catch (e) {
      setState(() {
        _step = _Step.connect;
        _error = 'Couldn’t read this phone’s storage: $e';
      });
      return false;
    }
    setState(() => _step = _Step.choose);
    return true;
  }

  Future<void> _start() async {
    final files = [for (final c in _selected) ..._scan!.byCategory[c]!];
    final contacts = _sendContacts ? _contacts : <Contact>[];
    final extras = Set.of(_selectedExtras);
    if (files.isEmpty && contacts.isEmpty && extras.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nothing selected.')));
      return;
    }
    // Apps and ringtones travel as files first; the new phone installs / sets them afterwards.
    final keys = {for (final f in files) f.key};
    void addFile(FileEntry f) {
      if (keys.add(f.key)) files.add(f);
    }

    final x = _extras;
    if (x != null && extras.contains(Extra.apps)) {
      for (final a in x.apps) {
        a.files.forEach(addFile);
      }
    }
    if (x != null && extras.contains(Extra.ringtones)) {
      for (final r in x.ringtones) {
        final path = r['path'] as String?, rel = r['rel'] as String?;
        if (path == null || rel == null) continue;
        try {
          final st = File(path).statSync();
          if (st.type == FileSystemEntityType.file) {
            addFile(FileEntry(path, rel, st.size, st.modified.millisecondsSinceEpoch, Category.music));
          }
        } catch (_) {}
      }
    }
    setState(() => _step = _Step.preparing);
    final groups = contacts.isEmpty ? const <String, List<String>>{} : await contactGroupNames(contacts);
    _plan = SendPlan(files, contacts, extras: extras, extrasScan: x, contactGroups: groups);
    setState(() => _step = _Step.transfer);
    _runPlan();
  }

  Future<void> _runPlan() async {
    final s = _sender!;
    // Remember this transfer so it can be continued after a restart or an app update.
    await LastSession(s.pairing, Set.of(_selected), _sendContacts, DateTime.now()).save();
    await s.run(_plan!);
    await _saveReport(s);
    if (s.phase == SendPhase.done && s.failedItems.isEmpty && s.contactsFailed == 0) {
      await LastSession.clear();
    }
  }

  /// Kept for the home screen's "Last transfer" card.
  Future<void> _saveReport(SenderService s) => TransferReport(
        true,
        DateTime.now(),
        switch (s.phase) { SendPhase.done => 'done', SendPhase.cancelled => 'stopped', _ => 'interrupted' },
        [
          for (final o in s.outcomes.values)
            ReportFile(o.file.rel, o.file.size, o.status,
                category: o.file.category.name, path: o.file.path, error: o.error),
          for (final x in _scan?.restricted ?? const <RestrictedItem>[])
            ReportFile(x.rel, 0, 'restricted', error: x.reason),
        ],
      ).save();

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
              _Step.transfer => _buildTabs(),
            },
          ),
        );
      },
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} day(s) ago';
  }

  Widget _buildConnect() {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('1. On the new phone, open this app and tap “This is the NEW phone”.', style: t.bodyLarge),
        const SizedBox(height: 8),
        Text('2. Scan the QR code it shows.', style: t.bodyLarge),
        const SizedBox(height: 24),
        if (_last != null) ...[
          Card(
            elevation: 0,
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  const Icon(Icons.history),
                  const SizedBox(width: 8),
                  Text('Unfinished transfer', style: t.titleMedium),
                ]),
                const SizedBox(height: 4),
                Text('To ${_last!.pairing.host}, started ${_ago(_last!.startedAt)}. '
                    'Files already on the new phone are skipped and half-sent files continue where they stopped.'),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _continueLast,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Continue previous transfer'),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 16),
        ],
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
            if (_extras != null) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text('More than files', style: Theme.of(context).textTheme.titleSmall),
              ),
              for (final e in Extra.values) _extraSwitch(e),
              if (_extras!.contactGroups > 0)
                ListTile(
                  leading: const Icon(Icons.group_outlined),
                  title: const Text('Contact groups'),
                  subtitle: Text('${_extras!.contactGroups} groups, sent with the contacts'),
                ),
              const ListTile(
                leading: Icon(Icons.chat_outlined),
                title: Text('WhatsApp chats'),
                subtitle: Text('Best: WhatsApp’s own Transfer chats, phone to phone, no Google Drive needed. '
                    'After this transfer: install WhatsApp on the new phone, verify your number, choose '
                    '“Transfer from old phone”, then here open WhatsApp → Settings → Chats → Transfer chats '
                    'and scan its code (same Wi-Fi, Location on).\n'
                    'Or: WhatsApp → Settings → Chats → Chat backup → Back up before starting. The local backup '
                    'is copied with “Other files” and WhatsApp offers to restore it during setup.'),
                isThreeLine: true,
              ),
            ],
            if (scan.restricted.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.lock_outline, color: Colors.purple),
                title: const Text('Restricted by Android'),
                subtitle: Text('${scan.restricted.length} folders or files can’t be copied by any regular app '
                    '(apps’ private data in Android/data and Android/obb, protected files). '
                    'They are listed under “Restricted” in the Files tab.'),
                isThreeLine: true,
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

  Widget _extraSwitch(Extra e) {
    final x = _extras!;
    final why = x.unavailable[e];
    final n = x.count(e);
    final hint = e.needsNewPhonePermission ? '\nThe new phone asks you to allow this during the transfer.' : '';
    return SwitchListTile(
      secondary: Icon(ExtrasStatusList.iconOf(e)),
      title: Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(e.label),
        if (e.restriction != null) RestrictedChip(e),
      ]),
      subtitle: Text(why ?? (n == 0 ? 'Nothing found' : '${x.summary(e)}$hint')),
      isThreeLine: why == null && n > 0,
      value: n > 0 && _selectedExtras.contains(e),
      onChanged: n == 0 ? null : (v) => setState(() => v ? _selectedExtras.add(e) : _selectedExtras.remove(e)),
    );
  }

  Widget _buildTabs() {
    final s = _sender!;
    final progress = _busy || s.phase == SendPhase.idle ? _buildRunning() : _buildResult();
    final rows = [
      for (final o in s.outcomes.values) FileRow(o.file.rel, o.file.size, o.status, error: o.error, category: o.file.category, path: o.file.path),
      for (final x in _scan?.restricted ?? const <RestrictedItem>[]) FileRow(x.rel, 0, 'restricted', error: x.reason),
    ];
    final failed = rows.where((r) => r.status == 'failed').length;
    final waitingExtra = s.extraTally.entries.any((e) => s.selectedExtras.contains(e.key) && e.value.state == 'waiting');
    return TransferTabs(
      progress: progress,
      files: FileCompareList(
        rows: rows,
        note: 'Every file you chose on this phone, and whether it is on the new phone now.',
      ),
      extras: ExtrasStatusList(
        tally: s.extraTally,
        shown: [for (final e in Extra.values) if (s.selectedExtras.contains(e)) e],
        onRetry: s.canSendExtras ? s.retryExtra : null,
        retryHint: 'Update the new phone to Phone Clone 5 or later, then start the transfer again.',
      ),
      filesBadge: failed,
      extrasBadge: waitingExtra ? 1 : 0,
    );
  }

  List<QueueEntry> _queueEntries(SenderService s) => [
        for (final d in s.dlq)
          QueueEntry(d.file.rel, d.lastError, d.attempts, s.maxAttempts, d.status.name),
      ];

  Widget _buildRunning() {
    final s = _sender!;

    if (s.phase == SendPhase.checking || s.phase == SendPhase.idle) {
      if (s.dupCheckTotalFiles > 0) {
        // Checking for identical files: show real progress and let the user skip it.
        final t = Theme.of(context).textTheme;
        final value = s.dupCheckTotalBytes == 0 ? null : s.dupCheckDoneBytes / s.dupCheckTotalBytes;
        return Center(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Looking for identical files', style: t.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text('Files saved in more than one place are sent once and copied on the new phone.',
                style: t.bodySmall, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            LinearProgressIndicator(value: value, minHeight: 10, borderRadius: BorderRadius.circular(5)),
            const SizedBox(height: 10),
            Text('${s.dupCheckDoneFiles} of ${s.dupCheckTotalFiles} files • '
                '${formatBytes(s.dupCheckDoneBytes)} of ${formatBytes(s.dupCheckTotalBytes)}',
                textAlign: TextAlign.center),
            if (s.statusLine != null)
              Text(s.statusLine!, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: s.skipDuplicateCheck,
              icon: const Icon(Icons.skip_next),
              label: const Text('Skip this step and start sending'),
            ),
          ]),
        );
      }
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
            ? StatusBanner(
                icon: Icons.wifi_find,
                color: Colors.deepOrange,
                title: 'Waiting for the new phone…',
                subtitle: 'Trying ${s.pairing.host}:${s.pairing.port}. Keep both phones on the same Wi-Fi; '
                    'it continues automatically. If the new phone shows a different address, '
                    'tap Stop, then scan its QR code (tap “Show QR” on the new phone).')
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

    final lanes = s.lanes.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
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
              if (s.clonedFiles > 0)
                '${s.clonedFiles} identical files copied on the new phone (${formatBytes(s.clonedBytes)} not re-sent)',
              if (s.resumedBytes > 0) '${formatBytes(s.resumedBytes)} resumed, not re-sent',
              if (s.contactsTotal > 0) 'Contacts: ${s.contactsAdded} added, ${s.contactsExisting} already there',
              if (s.statusLine != null) s.statusLine!,
            ],
          ),
          const SizedBox(height: 12),
          Row(children: [
            Icon(s.fastMode ? Icons.bolt : Icons.speed, size: 18, color: s.fastMode ? Colors.green : Colors.grey),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                s.fastMode
                    ? 'Fast mode • ${lanes.length} in flight (up to ${s.targetLanes} lanes, adjusts to your Wi-Fi)'
                    : 'Compatibility mode • the new phone runs an older version, so one file at a time. '
                        'Update it to v4 for faster transfers.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ]),
          const SizedBox(height: 8),
          for (final MapEntry(value: l) in lanes)
            CurrentFileCard(
              name: l.rel,
              bytes: l.bytes,
              total: l.total,
              resumedFrom: l.resumedFrom,
              note: l.batch ? 'Batch of ${l.batchCount} small files • file ${l.batchIndex + 1} of ${l.batchCount}' : null,
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
        for (final e in Extra.values)
          if (s.selectedExtras.contains(e))
            (e.label, s.extraTally[e]!.added, s.extraTally[e]!.existing, s.extraTally[e]!.failed),
      ]),
      const SizedBox(height: 8),
      if (failed.isNotEmpty) FailedFilesCard(items: [for (final d in failed) (d.file.path, d.lastError)]),
      if (s.dlq.any((d) => d.status == DlqStatus.recovered))
        ListTile(
          leading: const Icon(Icons.replay, color: Colors.green),
          title: Text('${s.dlq.where((d) => d.status == DlqStatus.recovered).length} file(s) '
              'recovered from the retry queue'),
        ),
      if (s.clonedFiles > 0 || s.resumedBytes > 0 || s.batchesSent > 0)
        ListTile(
          leading: const Icon(Icons.bolt, color: Colors.green),
          title: const Text('Speed-ups'),
          subtitle: Text([
            if (s.batchesSent > 0) '${s.batchesSent} batches of small files',
            if (s.clonedFiles > 0) '${s.clonedFiles} identical files copied on the new phone (${formatBytes(s.clonedBytes)} not re-sent)',
            if (s.resumedBytes > 0) '${formatBytes(s.resumedBytes)} continued instead of re-sent',
          ].join('\n')),
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
          onPressed: _runPlan,
          icon: const Icon(Icons.refresh),
          label: Text(s.phase == SendPhase.done ? 'Try the failed files again' : 'Continue'),
        ),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
    ]);
  }
}
