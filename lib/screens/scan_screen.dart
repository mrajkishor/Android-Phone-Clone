import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../transfer/protocol.dart';

/// Scans the QR code shown on the new phone. Pops with a [PairingInfo].
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final b in capture.barcodes) {
      final info = PairingInfo.fromQr(b.rawValue ?? '');
      if (info != null) {
        _handled = true;
        Navigator.pop(context, info);
        return;
      }
    }
  }

  Future<void> _manualEntry() async {
    final addr = TextEditingController();
    final code = TextEditingController();
    final info = await showDialog<PairingInfo>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter manually'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: addr,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'Address', hintText: '192.168.1.5:8765'),
          ),
          TextField(
            controller: code,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: const InputDecoration(labelText: '6-digit code'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final parts = addr.text.trim().split(':');
              final port = parts.length > 1 ? int.tryParse(parts[1]) : kDefaultPort;
              if (parts[0].isEmpty || port == null || code.text.trim().length != 6) return;
              Navigator.pop(ctx, PairingInfo(host: parts[0], port: port, code: code.text.trim()));
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    if (info != null && mounted) Navigator.pop(context, info);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan the new phone’s code')),
      body: Stack(
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 32,
            child: FilledButton.tonal(onPressed: _manualEntry, child: const Text('Enter address and code instead')),
          ),
        ],
      ),
    );
  }
}
