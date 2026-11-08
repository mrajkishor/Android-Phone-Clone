import 'package:flutter/material.dart';

import '../transfer/native.dart';

/// Shows [child] once "All files access" is granted; otherwise explains why
/// it's needed and offers a button that opens the right Settings screen.
class PermissionGate extends StatefulWidget {
  final String reason;
  final Widget child;

  const PermissionGate({super.key, required this.reason, required this.child});

  @override
  State<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<PermissionGate> with WidgetsBindingObserver {
  bool? _granted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _granted != true) _check();
  }

  Future<void> _check() async {
    final ok = await StoragePermission.granted();
    if (mounted) setState(() => _granted = ok);
  }

  Future<void> _request() async {
    final ok = await StoragePermission.request();
    if (mounted) setState(() => _granted = ok);
  }

  @override
  Widget build(BuildContext context) {
    if (_granted == null) return const Center(child: CircularProgressIndicator());
    if (_granted!) return widget.child;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.folder_open_rounded, size: 64),
          const SizedBox(height: 16),
          Text('Allow access to all files', style: t.headlineSmall, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Text(widget.reason, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            'On the next screen, turn on “Allow access to manage all files” for PhoneHop, then come back.',
            textAlign: TextAlign.center,
            style: t.bodySmall,
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _request,
            child: const Padding(padding: EdgeInsets.all(12), child: Text('Open settings')),
          ),
        ],
      ),
    );
  }
}
