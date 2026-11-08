import 'package:flutter/material.dart';

import 'screens/receive_screen.dart';
import 'screens/report_screen.dart';
import 'screens/send_screen.dart';
import 'transfer/protocol.dart';
import 'transfer/session_store.dart';

void main() => runApp(const PhoneTransferApp());

class PhoneTransferApp extends StatelessWidget {
  const PhoneTransferApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF1B6EF3);
    return MaterialApp(
      title: 'Phone Clone',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  TransferReport? _report;
  int _count = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final all = await TransferReport.all();
    if (mounted) {
      setState(() {
        _report = all.isEmpty ? null : all.first;
        _count = all.length;
      });
    }
  }

  /// Opens a screen and refreshes the "Last transfer" card when coming back.
  Future<void> _open(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight - 40),
              child: IntrinsicHeight(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 24),
                    Text('Phone Clone', style: t.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(
                      'Install this app on both phones. Connect them to the same Wi-Fi, '
                      'or turn on hotspot on the new phone and join it from the old one.',
                      style: t.bodyMedium,
                    ),
                    const SizedBox(height: 32),
                    _RoleCard(
                      icon: Icons.download_rounded,
                      title: 'This is the NEW phone',
                      subtitle: 'Receive data — shows a QR code',
                      onTap: () => _open(const ReceiveScreen()),
                    ),
                    const SizedBox(height: 16),
                    _RoleCard(
                      icon: Icons.upload_rounded,
                      title: 'This is the OLD phone',
                      subtitle: 'Send data — scan the QR code on the new phone',
                      onTap: () => _open(const SendScreen()),
                    ),
                    if (_report != null) ...[
                      const SizedBox(height: 24),
                      LastTransferCard(
                        report: _report!,
                        count: _count,
                        onOpen: () => _open(SnapshotScreen(report: _report!)),
                        onAll: () => _open(const SnapshotsScreen()),
                        onImport: () async {
                          await importSnapshot(context);
                          await _reload();
                        },
                      ),
                    ] else ...[
                      const SizedBox(height: 16),
                      Center(
                        child: TextButton.icon(
                          onPressed: () async {
                            await importSnapshot(context);
                            await _reload();
                          },
                          icon: const Icon(Icons.file_open_outlined, size: 18),
                          label: const Text('Import a transfer snapshot'),
                        ),
                      ),
                    ],
                    const Spacer(),
                    Text(
                      'Copies photos, videos, music, documents, every other file and contacts, '
                      'checksum-verified and without duplicates. Your files on the old phone are never changed, '
                      'and nothing leaves your local network.  •  v$kAppVersion',
                      textAlign: TextAlign.center,
                      style: t.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _RoleCard({required this.icon, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: cs.primaryContainer,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            children: [
              Icon(icon, size: 40, color: cs.onPrimaryContainer),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold, color: cs.onPrimaryContainer)),
                    const SizedBox(height: 4),
                    Text(subtitle, style: TextStyle(color: cs.onPrimaryContainer)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: cs.onPrimaryContainer),
            ],
          ),
        ),
      ),
    );
  }
}
