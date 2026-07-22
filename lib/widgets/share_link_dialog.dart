import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide showShadDialog, showShadSheet;

import 'app_dialog.dart';

Future<void> showShareLinkDialog(
  BuildContext context, {
  required Future<String?> Function() createLink,
}) async {
  final link = await createLink();
  if (!context.mounted || link == null || link.isEmpty) return;
  await showShadDialog<void>(
    context: context,
    builder: (_) => _ShareResultDialog(link: link),
  );
}

class _ShareResultDialog extends StatefulWidget {
  final String link;

  const _ShareResultDialog({required this.link});

  @override
  State<_ShareResultDialog> createState() => _ShareResultDialogState();
}

class _ShareResultDialogState extends State<_ShareResultDialog> {
  var _showQRCode = false;

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ShadDialog(
      title: Text(_showQRCode ? '分享二维码已生成' : '分享链接已生成'),
      description: const Text('有效期与访问权限以云盘分享设置为准。'),
      actions: [
        ShadButton.outline(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: widget.link));
            if (context.mounted) Navigator.of(context).pop();
          },
          leading: const Icon(Icons.copy_rounded, size: 16),
          child: const Text('复制'),
        ),
        ShadButton.outline(
          onPressed: () =>
              SharePlus.instance.share(ShareParams(text: widget.link)),
          leading: const Icon(Icons.ios_share_rounded, size: 16),
          child: const Text('分享'),
        ),
        ShadButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
      child: SizedBox(
        width: (MediaQuery.sizeOf(context).width - 48).clamp(260.0, 460.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: false,
                  icon: Icon(Icons.link_rounded, size: 16),
                  label: Text('链接'),
                ),
                ButtonSegment(
                  value: true,
                  icon: Icon(Icons.qr_code_2_rounded, size: 16),
                  label: Text('二维码'),
                ),
              ],
              selected: {_showQRCode},
              onSelectionChanged: (value) =>
                  setState(() => _showQRCode = value.first),
            ),
            const SizedBox(height: 10),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: _showQRCode
                  ? Container(
                      key: const ValueKey('share-qr-code'),
                      padding: const EdgeInsets.all(18),
                      alignment: Alignment.center,
                      child: Container(
                        width: 230,
                        height: 230,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: cs.border),
                        ),
                        child: QrImageView(
                          data: widget.link,
                          backgroundColor: Colors.white,
                          eyeStyle: const QrEyeStyle(
                            eyeShape: QrEyeShape.square,
                            color: Colors.black,
                          ),
                          dataModuleStyle: const QrDataModuleStyle(
                            dataModuleShape: QrDataModuleShape.square,
                            color: Colors.black,
                          ),
                        ),
                      ),
                    )
                  : Container(
                      key: const ValueKey('share-link'),
                      width: double.infinity,
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.muted,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: cs.border),
                      ),
                      child: SelectableText(
                        widget.link,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
