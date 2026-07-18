import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import '../models/cloud_file.dart';
import 'file_icon.dart';

/// A single file row in the file list with context menu support.
class FileListTile extends StatelessWidget {
  final CloudFile file;
  final bool isSelected;
  final VoidCallback? onSelect;
  final VoidCallback? onOpen;
  final VoidCallback? onRename;
  final VoidCallback? onCopy;
  final VoidCallback? onCut;
  final VoidCallback? onDownload;
  final VoidCallback? onShare;
  final VoidCallback? onDelete;
  final bool isRecycleItem;

  const FileListTile({
    super.key,
    required this.file,
    this.isSelected = false,
    this.onSelect,
    this.onOpen,
    this.onRename,
    this.onCopy,
    this.onCut,
    this.onDownload,
    this.onShare,
    this.onDelete,
    this.isRecycleItem = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return ShadContextMenuRegion(
      items: [
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.folderOpen, size: 16),
          trailing: const Icon(LucideIcons.chevronRight),
          onPressed: onOpen,
          child: const Text('打开'),
        ),
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.pencil, size: 16),
          onPressed: onRename,
          child: Text('重命名'),
        ),
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.copy, size: 16),
          trailing: const Icon(LucideIcons.chevronRight),
          onPressed: onCopy,
          child: const Text('复制'),
        ),
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.scissors, size: 16),
          trailing: const Icon(LucideIcons.chevronRight),
          onPressed: onCut,
          child: const Text('剪切'),
        ),
        const Divider(height: 8),
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.download, size: 16),
          trailing: const Icon(LucideIcons.chevronRight),
          onPressed: onDownload,
          child: const Text('下载'),
        ),
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.share2, size: 16),
          trailing: const Icon(LucideIcons.chevronRight),
          onPressed: onShare,
          child: const Text('分享'),
        ),
        const Divider(height: 8),
        ShadContextMenuItem.inset(
          leading: Icon(
            isRecycleItem ? LucideIcons.rotateCcw : LucideIcons.trash2,
            size: 16,
            color: isRecycleItem
                ? theme.colorScheme.primary
                : theme.colorScheme.destructive,
          ),
          trailing: Icon(
            LucideIcons.chevronRight,
            color: isRecycleItem
                ? theme.colorScheme.primary
                : theme.colorScheme.destructive,
          ),
          onPressed: onDelete,
          child: Text(
            isRecycleItem ? '恢复' : '删除',
            style: TextStyle(
              color: isRecycleItem
                  ? theme.colorScheme.primary
                  : theme.colorScheme.destructive,
            ),
          ),
        ),
      ],
      child: GestureDetector(
        onTap: () => onSelect?.call(),
        onDoubleTap: onOpen,
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: isSelected
                ? (isDark
                      ? theme.colorScheme.primary.withAlpha(30)
                      : theme.colorScheme.primary.withAlpha(15))
                : (isDark
                      ? Colors.white.withAlpha(3)
                      : Colors.black.withAlpha(2)),
            border: Border(
              bottom: BorderSide(
                color: isDark
                    ? Colors.white.withAlpha(10)
                    : Colors.black.withAlpha(8),
                width: 0.5,
              ),
            ),
          ),
          child: Row(
            children: [
              // Selection indicator
              if (isSelected)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(
                    LucideIcons.checkCircle,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                ),

              // File icon
              SizedBox(width: 32, height: 32, child: FileIcon(file: file)),
              const SizedBox(width: 12),

              // File name
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: theme.colorScheme.foreground,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (file.isDirectory && file.subFileCount != null)
                      Text(
                        '${file.subFileCount} 个项目',
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.mutedForeground,
                        ),
                      ),
                  ],
                ),
              ),

              // Folder sizes are enriched in the background just like files.
              SizedBox(
                width: 80,
                child: Text(
                  file.formattedSize,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.mutedForeground,
                  ),
                ),
              ),

              const SizedBox(width: 12),

              // Modified date
              SizedBox(
                width: 120,
                child: Text(
                  file.modifiedAt,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.mutedForeground,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
