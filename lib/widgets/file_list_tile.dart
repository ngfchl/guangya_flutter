import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../models/cloud_file.dart';
import 'file_icon.dart';

/// A file row with Finder-style inline rename support and a context menu.
class FileListTile extends StatefulWidget {
  final CloudFile file;
  final bool isSelected;
  final VoidCallback? onSelect;
  final VoidCallback? onOpen;
  final VoidCallback? onRename;
  final Future<void> Function(String newName)? onRenameConfirm;
  final VoidCallback? onCopy;
  final VoidCallback? onCut;
  final VoidCallback? onDownload;
  final VoidCallback? onShare;
  final VoidCallback? onCopyFastTransfer;
  final VoidCallback? onDelete;
  final bool isRecycleItem;

  const FileListTile({
    super.key,
    required this.file,
    this.isSelected = false,
    this.onSelect,
    this.onOpen,
    this.onRename,
    this.onRenameConfirm,
    this.onCopy,
    this.onCut,
    this.onDownload,
    this.onShare,
    this.onCopyFastTransfer,
    this.onDelete,
    this.isRecycleItem = false,
  });

  @override
  State<FileListTile> createState() => _FileListTileState();
}

class _FileListTileState extends State<FileListTile> {
  late final TextEditingController _renameController;
  late final FocusNode _renameFocusNode;
  var _isRenaming = false;
  var _isSubmittingRename = false;

  @override
  void initState() {
    super.initState();
    _renameController = TextEditingController(text: widget.file.name);
    _renameFocusNode = FocusNode(debugLabel: 'rename-${widget.file.id}');
  }

  @override
  void didUpdateWidget(covariant FileListTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.id != widget.file.id ||
        (!_isRenaming && oldWidget.file.name != widget.file.name)) {
      _renameController.text = widget.file.name;
    }
  }

  @override
  void dispose() {
    _renameController.dispose();
    _renameFocusNode.dispose();
    super.dispose();
  }

  void _beginRename() {
    if (widget.onRenameConfirm == null) {
      widget.onRename?.call();
      return;
    }
    setState(() {
      _renameController.text = widget.file.name;
      _renameController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _renameController.text.length,
      );
      _isRenaming = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _renameFocusNode.requestFocus();
    });
  }

  void _cancelRename() {
    setState(() {
      _renameController.text = widget.file.name;
      _isRenaming = false;
    });
  }

  Future<void> _confirmRename() async {
    final newName = _renameController.text.trim();
    if (_isSubmittingRename || newName.isEmpty) return;
    if (newName == widget.file.name) {
      _cancelRename();
      return;
    }
    final confirmed = await showShadDialog<bool>(
      context: context,
      builder: (dialogContext) => ShadDialog(
        title: const Text('确认重命名？'),
        description: Text('“${widget.file.name}” 将重命名为 “$newName”'),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          ShadButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认重命名'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _isSubmittingRename = true);
    try {
      await widget.onRenameConfirm!(newName);
      if (mounted) setState(() => _isRenaming = false);
    } finally {
      if (mounted) setState(() => _isSubmittingRename = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 720;
    return ShadContextMenuRegion(
      items: [
        if (widget.isRecycleItem)
          ShadContextMenuItem.inset(
            leading: Icon(
              LucideIcons.rotateCcw,
              size: 16,
              color: theme.colorScheme.primary,
            ),
            onPressed: widget.onDelete,
            child: Text(
              '恢复',
              style: TextStyle(color: theme.colorScheme.primary),
            ),
          )
        else ...[
          ShadContextMenuItem.inset(
            leading: const Icon(LucideIcons.folderOpen, size: 16),
            trailing: const Icon(LucideIcons.chevronRight),
            onPressed: widget.onOpen,
            child: const Text('打开'),
          ),
          ShadContextMenuItem.inset(
            leading: const Icon(LucideIcons.pencil, size: 16),
            onPressed: _beginRename,
            child: const Text('重命名'),
          ),
          ShadContextMenuItem.inset(
            leading: const Icon(LucideIcons.copy, size: 16),
            trailing: const Icon(LucideIcons.chevronRight),
            onPressed: widget.onCopy,
            child: const Text('复制'),
          ),
          ShadContextMenuItem.inset(
            leading: const Icon(LucideIcons.scissors, size: 16),
            trailing: const Icon(LucideIcons.chevronRight),
            onPressed: widget.onCut,
            child: const Text('剪切'),
          ),
          const Divider(height: 8),
          ShadContextMenuItem.inset(
            leading: const Icon(LucideIcons.download, size: 16),
            trailing: const Icon(LucideIcons.chevronRight),
            onPressed: widget.onDownload,
            child: const Text('下载'),
          ),
          ShadContextMenuItem.inset(
            leading: const Icon(LucideIcons.share2, size: 16),
            trailing: const Icon(LucideIcons.chevronRight),
            onPressed: widget.onShare,
            child: const Text('分享'),
          ),
          ShadContextMenuItem.inset(
            leading: const Icon(LucideIcons.zap, size: 16),
            onPressed: widget.onCopyFastTransfer,
            child: const Text('复制秒传'),
          ),
          const Divider(height: 8),
          ShadContextMenuItem.inset(
            leading: Icon(
              LucideIcons.trash2,
              size: 16,
              color: theme.colorScheme.destructive,
            ),
            onPressed: widget.onDelete,
            child: Text(
              '删除',
              style: TextStyle(color: theme.colorScheme.destructive),
            ),
          ),
        ],
      ],
      child: Semantics(
        button: !_isRenaming,
        selected: widget.isSelected,
        label:
            '${widget.file.isDirectory ? '文件夹' : '文件'} ${widget.file.name}${widget.file.isDirectory ? '' : '，${widget.file.formattedSize}'}',
        hint: _isRenaming ? '正在重命名' : '点按选择，双击打开',
        child: GestureDetector(
          onTap: _isRenaming ? null : widget.onSelect,
          onDoubleTap: _isRenaming ? null : widget.onOpen,
          child: Container(
            height: compact ? 74 : 62,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? cs.primary.withValues(alpha: 0.14)
                  : cs.card,
              border: Border(bottom: BorderSide(color: cs.border, width: 0.5)),
            ),
            child: compact
                ? _buildCompactContent(theme)
                : Row(
                    children: [
                      if (widget.isSelected)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Icon(
                            LucideIcons.checkCircle,
                            size: 18,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      SizedBox(
                        width: 32,
                        height: 32,
                        child: FileIcon(file: widget.file),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _isRenaming
                            ? Row(
                                children: [
                                  Expanded(
                                    child: ShadInput(
                                      controller: _renameController,
                                      focusNode: _renameFocusNode,
                                      autofocus: true,
                                      enabled: !_isSubmittingRename,
                                      onSubmitted: (_) => _confirmRename(),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  ShadButton.ghost(
                                    size: ShadButtonSize.sm,
                                    onPressed: _isSubmittingRename
                                        ? null
                                        : _confirmRename,
                                    child: const Icon(
                                      Icons.check_rounded,
                                      size: 17,
                                    ),
                                  ),
                                  ShadButton.ghost(
                                    size: ShadButtonSize.sm,
                                    onPressed: _isSubmittingRename
                                        ? null
                                        : _cancelRename,
                                    child: const Icon(
                                      Icons.close_rounded,
                                      size: 17,
                                    ),
                                  ),
                                ],
                              )
                            : Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.file.name,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      color: theme.colorScheme.foreground,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (widget.file.directoryContentSummary
                                      case final String summary)
                                    Text(
                                      summary,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color:
                                            theme.colorScheme.mutedForeground,
                                      ),
                                    ),
                                ],
                              ),
                      ),
                      SizedBox(
                        width: 80,
                        child: Text(
                          widget.file.formattedSize,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.mutedForeground,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 120,
                        child: Text(
                          widget.file.modifiedAt,
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
      ),
    );
  }

  Widget _buildCompactContent(ShadThemeData theme) {
    final file = widget.file;
    final summary = file.directoryContentSummary;
    final metadata = [
      if (summary case final String value) value,
      file.formattedSize,
      if (file.modifiedAt.isNotEmpty) file.modifiedAt,
    ].join(' · ');
    return Row(
      children: [
        if (widget.isSelected)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Icon(
              LucideIcons.checkCircle,
              size: 18,
              color: theme.colorScheme.primary,
            ),
          ),
        SizedBox(width: 38, height: 38, child: FileIcon(file: file)),
        const SizedBox(width: 12),
        Expanded(
          child: _isRenaming
              ? Row(
                  children: [
                    Expanded(
                      child: ShadInput(
                        controller: _renameController,
                        focusNode: _renameFocusNode,
                        autofocus: true,
                        enabled: !_isSubmittingRename,
                        onSubmitted: (_) => _confirmRename(),
                      ),
                    ),
                    ShadButton.ghost(
                      size: ShadButtonSize.sm,
                      onPressed: _isSubmittingRename ? null : _confirmRename,
                      child: const Icon(Icons.check_rounded, size: 17),
                    ),
                    ShadButton.ghost(
                      size: ShadButtonSize.sm,
                      onPressed: _isSubmittingRename ? null : _cancelRename,
                      child: const Icon(Icons.close_rounded, size: 17),
                    ),
                  ],
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.foreground,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      metadata,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.mutedForeground,
                      ),
                    ),
                  ],
                ),
        ),
        if (!_isRenaming && file.isDirectory)
          Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: theme.colorScheme.mutedForeground,
          ),
      ],
    );
  }
}
