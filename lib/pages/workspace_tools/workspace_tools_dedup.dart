part of '../workspace_tools_page.dart';

enum _DuplicateQuickSelectKind {
  keepShortestPath,
  keepLongestPath,
  keepNewestFile,
  clear,
}

class _DuplicateQuickSelect {
  final _DuplicateQuickSelectKind kind;

  const _DuplicateQuickSelect(this.kind);
}

class _DuplicateGroup extends ConsumerStatefulWidget {
  final List<CloudFile> files;
  final ValueChanged<Set<String>>? onSelectionChanged;
  final Set<String> bulkDeletedIDs;
  final Set<String> bulkFailedIDs;
  final Set<String> bulkCurrentDeleteIDs;
  final bool bulkDeleting;
  final Set<String> initialSelectedIDs;
  final ValueChanged<Set<String>>? onDeleted;

  const _DuplicateGroup({
    super.key,
    required this.files,
    this.onSelectionChanged,
    this.onDeleted,
    this.bulkDeletedIDs = const {},
    this.bulkFailedIDs = const {},
    this.bulkCurrentDeleteIDs = const {},
    this.bulkDeleting = false,
    this.initialSelectedIDs = const {},
  });

  @override
  ConsumerState<_DuplicateGroup> createState() => _DuplicateGroupState();
}

class _DuplicateGroupState extends ConsumerState<_DuplicateGroup> {
  late Set<String> _selectedIDs;
  bool _deleting = false;
  int _deleteTotal = 0;
  int _deleteCurrent = 0;
  String? _currentDeleteID;
  final _deletedIDs = <String>{};
  final _failedIDs = <String>{};

  @override
  void initState() {
    super.initState();
    _selectedIDs = Set<String>.of(widget.initialSelectedIDs);
  }

  @override
  void didUpdateWidget(covariant _DuplicateGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!setEquals(oldWidget.initialSelectedIDs, widget.initialSelectedIDs)) {
      _selectedIDs = Set<String>.of(widget.initialSelectedIDs);
    }
    final newlyDeleted = widget.bulkDeletedIDs.difference(
      oldWidget.bulkDeletedIDs,
    );
    if (newlyDeleted.isNotEmpty) {
      _selectedIDs.removeAll(newlyDeleted);
      _notifySelection();
    }
  }

  void _notifySelection() {
    final selected = Set<String>.of(_selectedIDs);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onSelectionChanged?.call(selected);
    });
  }

  void _openFile(CloudFile file) {
    if (canPreviewCloudFile(file)) {
      final notifier = ref.read(fileProvider.notifier);
      unawaited(
        showCloudFilePreview(
          context: context,
          file: file,
          resolveUrl: () => notifier.previewURL(file),
          onDownload: () => notifier.downloadFile(file),
        ),
      );
      return;
    }
    if (file.isPlayableVideo) {
      unawaited(showMediaPlayerDialog(context, file));
      return;
    }
    ref.read(fileProvider.notifier).downloadFile(file);
  }

  Future<void> _confirmDelete() async {
    final targets = widget.files
        .where((file) => _selectedIDs.contains(file.id))
        .toList();
    if (targets.isEmpty || _deleting || widget.bulkDeleting) return;
    final confirmed = await showShadDialog<bool>(
      context: context,
      builder: (dialogContext) => ShadDialog(
        closeIcon: const SizedBox.shrink(),
        title: Text('删除 ${targets.length} 个重复文件？'),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          ShadButton.destructive(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
        child: const Padding(
          padding: EdgeInsets.only(top: 10),
          child: Text('删除后无法恢复，请确认选中的文件。'),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _deleting = true;
      _deleteTotal = targets.length;
      _deleteCurrent = 0;
      _currentDeleteID = null;
      _deletedIDs.clear();
      _failedIDs.clear();
    });

    for (var i = 0; i < targets.length; i++) {
      if (!mounted) return;
      final file = targets[i];
      setState(() {
        _deleteCurrent = i + 1;
        _currentDeleteID = file.id;
      });
      try {
        final ok = await ref.read(fileProvider.notifier).deleteFiles([file]);
        if (ok && mounted) {
          setState(() => _deletedIDs.add(file.id));
        } else if (mounted) {
          setState(() => _failedIDs.add(file.id));
        }
      } catch (_) {
        if (mounted) {
          setState(() => _failedIDs.add(file.id));
        }
      }
    }

    if (_deletedIDs.isNotEmpty) {
      await FileMetadataCache.removeFilesFromAllFolders(_deletedIDs);
      await FileMetadataCache.removeLiveFileIDs(_deletedIDs);
    }

    if (mounted) {
      final deletedIDs = Set<String>.of(_deletedIDs);
      setState(() {
        _deleting = false;
        _currentDeleteID = null;
        _selectedIDs.removeAll(deletedIDs);
      });
      _notifySelection();
      widget.onDeleted?.call(deletedIDs);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final selectedCount = _selectedIDs.length;
    final gcid = widget.files.first.gcid?.trim() ?? '';
    final deleting = _deleting || widget.bulkDeleting;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.muted,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '重复组 · ${widget.files.length} 项',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: cs.primary,
                      ),
                    ),
                    if (gcid.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Tooltip(
                          message: gcid,
                          child: SelectionArea(
                            child: Text(
                              'GCID: $gcid',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: cs.mutedForeground,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (_deleting && _deleteTotal > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 80,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _deleteCurrent / _deleteTotal,
                        minHeight: 6,
                        backgroundColor: cs.border,
                      ),
                    ),
                  ),
                ),
              ShadButton.destructive(
                size: ShadButtonSize.sm,
                onPressed: selectedCount == 0 || deleting
                    ? null
                    : _confirmDelete,
                leading: _deleting
                    ? const AppLoadingIndicator(size: AppLoadingSize.inline)
                    : null,
                child: Text(
                  _deleting
                      ? '删除中 $_deleteCurrent/$_deleteTotal'
                      : '删除 $selectedCount',
                ),
              ),
            ],
          ),
          for (final file in widget.files)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Row(
                children: [
                  ShadCheckbox(
                    value: _selectedIDs.contains(file.id),
                    onChanged: deleting
                        ? null
                        : (value) => setState(() {
                            if (value == true) {
                              _selectedIDs.add(file.id);
                            } else {
                              _selectedIDs.remove(file.id);
                            }
                            _notifySelection();
                          }),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                file.name,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            if (file.size != null && file.size! > 0)
                              Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: Text(
                                  file.formattedSize,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: cs.mutedForeground,
                                  ),
                                ),
                              ),
                            if (_deletedIDs.contains(file.id) ||
                                widget.bulkDeletedIDs.contains(file.id))
                              Padding(
                                padding: const EdgeInsets.only(left: 6),
                                child: Icon(
                                  Icons.check_circle_rounded,
                                  size: 14,
                                  color: cs.primary,
                                ),
                              ),
                            if (_failedIDs.contains(file.id) ||
                                widget.bulkFailedIDs.contains(file.id))
                              Padding(
                                padding: const EdgeInsets.only(left: 6),
                                child: Icon(
                                  Icons.error_outline_rounded,
                                  size: 14,
                                  color: cs.destructive,
                                ),
                              ),
                          ],
                        ),
                        Text(
                          file.cloudPath,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: cs.mutedForeground,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_deletedIDs.contains(file.id) ||
                      widget.bulkDeletedIDs.contains(file.id))
                    Text(
                      '已删除',
                      style: TextStyle(fontSize: 11, color: cs.primary),
                    )
                  else if (_failedIDs.contains(file.id) ||
                      widget.bulkFailedIDs.contains(file.id))
                    Text(
                      '失败',
                      style: TextStyle(fontSize: 11, color: cs.destructive),
                    )
                  else if ((_deleting && _currentDeleteID == file.id) ||
                      (widget.bulkDeleting &&
                          widget.bulkCurrentDeleteIDs.contains(file.id)))
                    const AppLoadingIndicator(size: AppLoadingSize.inline)
                  else
                    Text(
                      _selectedIDs.contains(file.id) ? '将删除' : '保留',
                      style: TextStyle(
                        fontSize: 11,
                        color: _selectedIDs.contains(file.id)
                            ? cs.destructive
                            : cs.primary,
                      ),
                    ),
                  const SizedBox(width: 4),
                  Tooltip(
                    message: '打开',
                    child: ShadIconButton.ghost(
                      onPressed: deleting ? null : () => _openFile(file),
                      icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    ),
                  ),
                  Tooltip(
                    message: '详情',
                    child: ShadIconButton.ghost(
                      onPressed: deleting
                          ? null
                          : () => showFileDetailDialog(context, file),
                      icon: const Icon(Icons.info_outline_rounded, size: 16),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
