import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide showShadDialog, showShadSheet;

import '../models/cloud_file.dart';
import 'app_dialog.dart';
import 'file_icon.dart';
import 'share_qr_code_panel.dart';

/// A dedicated tile for share records, showing title, link and actions.
class ShareListTile extends StatelessWidget {
  final CloudFile share;
  final bool isSelected;
  final VoidCallback? onSelect;
  final VoidCallback? onDelete;

  const ShareListTile({
    super.key,
    required this.share,
    this.isSelected = false,
    this.onSelect,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 720;
    final link = share.shareUrl ?? '';
    final linkDisplay = link.isNotEmpty
        ? Uri.tryParse(link)?.host ?? link
        : '无链接';
    final dateStr = share.modifiedAt.isNotEmpty ? share.modifiedAt : '';
    final sizeText = share.size == null ? '计算中' : share.formattedSize;
    final kindIcon = share.shareIsDirectory == true
        ? LucideIcons.folder
        : LucideIcons.file;
    final kindColor = share.shareIsDirectory == true
        ? const Color(0xFFF59E0B)
        : cs.mutedForeground;

    return ShadContextMenuRegion(
      tapEnabled: false,
      items: [
        if (link.isNotEmpty)
          ShadContextMenuItem.inset(
            leading: const Icon(LucideIcons.link, size: 16),
            trailing: const Icon(LucideIcons.chevronRight),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: link));
              if (context.mounted) {
                ShadToaster.of(
                  context,
                ).show(const ShadToast(title: Text('分享链接已复制')));
              }
            },
            child: const Text('复制链接'),
          ),
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.qrCode, size: 16),
          trailing: const Icon(LucideIcons.chevronRight),
          onPressed: () => _showShareQrDialog(context, link, share.name),
          child: const Text('显示二维码'),
        ),
        if (link.isNotEmpty) ...[
          const Divider(height: 8),
          ShadContextMenuItem.inset(
            leading: const Icon(LucideIcons.externalLink, size: 16),
            trailing: const Icon(LucideIcons.chevronRight),
            onPressed: () async {
              final uri = Uri.tryParse(link);
              if (uri != null) {
                await Clipboard.setData(ClipboardData(text: link));
                if (context.mounted) {
                  ShadToaster.of(
                    context,
                  ).show(const ShadToast(title: Text('链接已复制，可在浏览器中打开')));
                }
              }
            },
            child: const Text('在浏览器中打开'),
          ),
        ],
        if (onDelete != null) ...[
          const Divider(height: 8),
          ShadContextMenuItem.inset(
            leading: Icon(LucideIcons.trash2, size: 16, color: cs.destructive),
            onPressed: onDelete,
            child: Text('删除分享', style: TextStyle(color: cs.destructive)),
          ),
        ],
      ],
      child: Semantics(
        button: true,
        selected: isSelected,
        label: '分享 ${share.name}',
        child: GestureDetector(
          onTap: onSelect,
          child: Container(
            height: compact ? 74 : 62,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: isSelected ? cs.primary.withValues(alpha: 0.14) : cs.card,
              border: Border(bottom: BorderSide(color: cs.border, width: 0.5)),
            ),
            child: compact
                ? _buildCompact(theme, linkDisplay, sizeText, dateStr)
                : Row(
                    children: [
                      if (isSelected)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Icon(
                            LucideIcons.checkCircle,
                            size: 18,
                            color: cs.primary,
                          ),
                        ),
                      SizedBox(
                        width: 32,
                        height: 32,
                        child: FileIcon(file: share),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              share.name,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: cs.foreground,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                Icon(kindIcon, size: 11, color: kindColor),
                                const SizedBox(width: 4),
                                Text(
                                  share.shareKindName,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: cs.mutedForeground,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(
                                  LucideIcons.link,
                                  size: 11,
                                  color: cs.mutedForeground,
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    linkDisplay,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: cs.mutedForeground,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: 86,
                        child: Text(
                          sizeText,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.mutedForeground,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 12),
                      if (share.downloadCount != null &&
                          share.downloadCount! > 0)
                        SizedBox(
                          width: 60,
                          child: Text(
                            '${share.downloadCount} 次',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.mutedForeground,
                            ),
                          ),
                        ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 120,
                        child: Text(
                          dateStr,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.mutedForeground,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildCompact(
    ShadThemeData theme,
    String linkDisplay,
    String sizeText,
    String dateStr,
  ) {
    final cs = theme.colorScheme;
    final metadata = [
      share.shareKindName,
      linkDisplay,
      sizeText,
      if (share.downloadCount != null && share.downloadCount! > 0)
        '${share.downloadCount} 次下载',
      if (dateStr.isNotEmpty) dateStr,
    ].join(' · ');

    return Row(
      children: [
        if (isSelected)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Icon(LucideIcons.checkCircle, size: 18, color: cs.primary),
          ),
        SizedBox(width: 38, height: 38, child: FileIcon(file: share)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                share.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: cs.foreground,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                metadata,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: cs.mutedForeground),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static void _showShareQrDialog(
    BuildContext context,
    String link,
    String title,
  ) {
    showShadDialog<void>(
      context: context,
      builder: (ctx) {
        return ShadDialog(
          title: const Text('分享二维码'),
          description: Text(link.isNotEmpty ? '扫描二维码打开分享链接' : '该分享暂无链接'),
          actions: [
            if (link.isNotEmpty)
              ShadButton.outline(
                onPressed: () async {
                  await copyShareQRCodeToClipboard(link, title: title);
                  if (ctx.mounted) {
                    ShadToaster.of(
                      ctx,
                    ).show(const ShadToast(title: Text('二维码已复制')));
                  }
                },
                leading: const Icon(Icons.qr_code_2_rounded, size: 16),
                child: const Text('复制二维码'),
              ),
            if (link.isNotEmpty)
              ShadButton.outline(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: link));
                  if (ctx.mounted) {
                    ShadToaster.of(
                      ctx,
                    ).show(const ShadToast(title: Text('链接已复制')));
                  }
                },
                leading: const Icon(Icons.copy_rounded, size: 16),
                child: const Text('复制链接'),
              ),
            ShadButton.outline(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭'),
            ),
          ],
          child: link.isNotEmpty
              ? SizedBox(
                  width: (MediaQuery.sizeOf(ctx).width - 48).clamp(
                    260.0,
                    460.0,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: ShareQRCodePanel(
                      link: link,
                      title: title,
                      size: 220,
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        );
      },
    );
  }
}
