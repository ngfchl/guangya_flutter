import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide showShadDialog, showShadSheet;

import '../core/utils/guangya_share_link.dart';
import 'app_dialog.dart';

Future<GuangyaShareLink?> showShareQRScannerDialog(BuildContext context) =>
    showShadDialog<GuangyaShareLink>(
      context: context,
      builder: (_) => const ShareQRScannerDialog(),
    );

class ShareQRScannerDialog extends StatefulWidget {
  const ShareQRScannerDialog({super.key});

  @override
  State<ShareQRScannerDialog> createState() => _ShareQRScannerDialogState();
}

class _ShareQRScannerDialogState extends State<ShareQRScannerDialog> {
  var _handled = false;
  String? _message;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue?.trim();
      if (raw == null || raw.isEmpty) continue;
      final share = GuangyaShareLink.tryParse(raw);
      if (share != null) {
        _handled = true;
        Navigator.of(context).pop(share);
        return;
      }
      if (mounted) {
        setState(() => _message = '仅支持光鸭云盘分享二维码');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final scannerSize = (size.width - 64).clamp(250.0, 440.0);
    return ShadDialog(
      title: const Text('扫一扫'),
      description: const Text('将光鸭分享二维码放入取景框'),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
      child: SizedBox(
        width: scannerSize,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox.square(
                dimension: scannerSize,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MobileScanner(
                      fit: BoxFit.cover,
                      tapToFocus: true,
                      onDetect: _onDetect,
                      errorBuilder: (context, error) => ColoredBox(
                        color: Colors.black,
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Text(
                              '无法启动相机\n${error.errorCode.name}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                    ),
                    IgnorePointer(
                      child: Center(
                        child: Container(
                          width: scannerSize * 0.68,
                          height: scannerSize * 0.68,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              height: 34,
              child: Center(
                child: Text(
                  _message ?? '识别成功后将自动打开分享文件',
                  style: TextStyle(
                    fontSize: 12,
                    color: _message == null
                        ? cs.mutedForeground
                        : cs.destructive,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
