import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    builder: (dialogContext) => ShadDialog(
      title: const Text('分享链接已生成'),
      description: const Text('链接有效期与访问权限以云盘分享设置为准。'),
      actions: [
        ShadButton.outline(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: link));
            if (dialogContext.mounted) Navigator.of(dialogContext).pop();
          },
          leading: const Icon(Icons.copy_rounded, size: 16),
          child: const Text('复制'),
        ),
        ShadButton.outline(
          onPressed: () => SharePlus.instance.share(ShareParams(text: link)),
          leading: const Icon(Icons.ios_share_rounded, size: 16),
          child: const Text('分享'),
        ),
        ShadButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('关闭'),
        ),
      ],
      child: Container(
        width: 460,
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: ShadTheme.of(dialogContext).colorScheme.muted,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: ShadTheme.of(dialogContext).colorScheme.border,
          ),
        ),
        child: SelectableText(link, style: const TextStyle(fontSize: 12)),
      ),
    ),
  );
}
