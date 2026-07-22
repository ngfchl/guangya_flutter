import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide showShadDialog, showShadSheet;

import 'app_dialog.dart';
import 'share_qr_code_panel.dart';

Future<void> showShareLinkDialog(
  BuildContext context, {
  required Future<String?> Function() createLink,
  String? title,
}) async {
  final link = await createLink();
  if (!context.mounted || link == null || link.isEmpty) return;
  await showShadDialog<void>(
    context: context,
    builder: (_) => _ShareResultDialog(link: link, title: title),
  );
}

class _ShareResultDialog extends StatelessWidget {
  final String link;
  final String? title;

  const _ShareResultDialog({required this.link, this.title});

  @override
  Widget build(BuildContext context) {
    return ShadDialog(
      title: const Text('分享二维码已生成'),
      description: const Text('有效期与访问权限以云盘分享设置为准。'),
      actions: [
        ShadButton.outline(
          onPressed: () async {
            await copyShareQRCodeToClipboard(link, title: title);
            if (context.mounted) {
              ShadToaster.of(
                context,
              ).show(const ShadToast(title: Text('二维码已复制')));
            }
          },
          leading: const Icon(Icons.qr_code_2_rounded, size: 16),
          child: const Text('复制二维码'),
        ),
        ShadButton.outline(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: link));
            if (context.mounted) {
              ShadToaster.of(
                context,
              ).show(const ShadToast(title: Text('链接已复制')));
            }
          },
          leading: const Icon(Icons.copy_rounded, size: 16),
          child: const Text('复制链接'),
        ),
        ShadButton.outline(
          onPressed: () => SharePlus.instance.share(ShareParams(text: link)),
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
        child: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: ShareQRCodePanel(link: link, title: title, size: 230),
        ),
      ),
    );
  }
}
