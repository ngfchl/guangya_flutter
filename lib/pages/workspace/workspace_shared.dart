part of '../workspace_page.dart';

class _SelectAllFilesIntent extends Intent {
  const _SelectAllFilesIntent();
}

class _DeleteSelectedIntent extends Intent {
  const _DeleteSelectedIntent();
}

const _desktopDeleteShortcuts = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.delete): _DeleteSelectedIntent(),
  SingleActivator(LogicalKeyboardKey.backspace, meta: true):
      _DeleteSelectedIntent(),
};

void _selectDesktopFile(FileNotifier notifier, CloudFile file) {
  notifier.selectWithModifiers(
    file.id,
    command:
        _hasPressedKey(LogicalKeyboardKey.metaLeft) ||
        _hasPressedKey(LogicalKeyboardKey.metaRight) ||
        _hasPressedKey(LogicalKeyboardKey.controlLeft) ||
        _hasPressedKey(LogicalKeyboardKey.controlRight),
    shift:
        _hasPressedKey(LogicalKeyboardKey.shiftLeft) ||
        _hasPressedKey(LogicalKeyboardKey.shiftRight),
  );
}

class _FolderMoveTarget extends StatefulWidget {
  final CloudFile file;
  final Future<void> Function(List<CloudFile> files, String? parentID) onMove;
  final VoidCallback? onOpen;
  final Widget child;
  final bool enabled;

  const _FolderMoveTarget({
    required this.file,
    required this.onMove,
    this.onOpen,
    required this.child,
    this.enabled = true,
  });

  @override
  State<_FolderMoveTarget> createState() => _FolderMoveTargetState();
}

class _FolderMoveTargetState extends State<_FolderMoveTarget> {
  Timer? _openTimer;

  @override
  void dispose() {
    _openTimer?.cancel();
    super.dispose();
  }

  void _scheduleOpen() {
    if (_openTimer?.isActive == true || widget.onOpen == null) return;
    _openTimer = Timer(const Duration(milliseconds: 700), () {
      _openTimer = null;
      if (mounted) widget.onOpen?.call();
    });
  }

  void _cancelOpen() {
    _openTimer?.cancel();
    _openTimer = null;
  }

  bool _canMove(_DraggedCloudFiles data) {
    final targetPath = widget.file.cloudPath
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    return !data.files.any((source) {
      if (source.id == widget.file.id ||
          _sameCloudParentID(source.parentID, widget.file.id)) {
        return true;
      }
      if (!source.isDirectory) return false;
      final sourcePath = source.cloudPath
          .replaceAll('\\', '/')
          .replaceAll(RegExp(r'/+$'), '');
      return sourcePath.isNotEmpty && targetPath.startsWith('$sourcePath/');
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || _isMobilePlatform || !widget.file.isDirectory) {
      return widget.child;
    }
    return DragTarget<_DraggedCloudFiles>(
      onWillAcceptWithDetails: (details) => _canMove(details.data),
      onMove: (_) {
        _scheduleOpen();
      },
      onLeave: (_) => _cancelOpen(),
      onAcceptWithDetails: (details) async {
        _cancelOpen();
        await widget.onMove(details.data.files, widget.file.id);
      },
      builder: (context, candidates, _) => DecoratedBox(
        decoration: BoxDecoration(
          border: candidates.isEmpty
              ? null
              : Border.all(
                  color: ShadTheme.of(context).colorScheme.primary,
                  width: 2,
                ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: widget.child,
      ),
    );
  }
}

void _openCloudFile(BuildContext context, WidgetRef ref, CloudFile file) {
  if (canPreviewCloudFile(file)) {
    _previewCloudFile(context, ref, file);
    return;
  }
  if (file.isPlayableVideo) {
    unawaited(showMediaPlayerDialog(context, file));
    return;
  }
  if (file.isIso) {
    ShadToaster.maybeOf(context)?.show(
      const ShadToast.destructive(
        title: Text('不支持播放 ISO 文件'),
        description: Text('可通过右键菜单下载该文件。'),
        showCloseIconOnlyWhenHovered: false,
      ),
    );
    return;
  }
  ref.read(fileProvider.notifier).downloadFile(file);
}

void _previewCloudFile(BuildContext context, WidgetRef ref, CloudFile file) {
  if (!canPreviewCloudFile(file)) return;
  final notifier = ref.read(fileProvider.notifier);
  unawaited(
    showCloudFilePreview(
      context: context,
      file: file,
      resolveUrl: () => notifier.previewURL(file),
      onDownload: () => notifier.downloadFile(file),
    ),
  );
}

Future<bool> _copyOrMoveFilesToDestination(
  BuildContext context,
  WidgetRef ref,
  List<CloudFile> files, {
  required bool move,
}) async {
  if (files.isEmpty) return false;
  final notifier = ref.read(fileProvider.notifier);
  final completed = await showShadDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CloudFolderDestinationPicker(
      move: move,
      files: files,
      onExecute: (parentID) => move
          ? notifier.moveFilesTo(files, parentID: parentID)
          : notifier.copyFilesTo(files, parentID: parentID),
    ),
  );
  return completed == true;
}

class _ClipboardPasteButton extends ConsumerWidget {
  final String? parentID;
  final Future<void> Function()? onCompleted;

  const _ClipboardPasteButton({required this.parentID, this.onCompleted});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(fileProvider);
    final count = state.clipboard?.length ?? 0;
    if (count == 0) return const SizedBox.shrink();
    return ShadButton.outline(
      size: ShadButtonSize.sm,
      onPressed: () async {
        await ref.read(fileProvider.notifier).pasteFromClipboardTo(parentID);
        await onCompleted?.call();
      },
      leading: Icon(
        state.clipboardIsMove
            ? Icons.content_paste_go_rounded
            : Icons.content_paste_rounded,
        size: 15,
      ),
      child: Text('粘贴 $count'),
    );
  }
}

Future<void> _confirmDeleteCloudFiles(
  BuildContext context,
  List<CloudFile> files,
  Future<void> Function() onConfirm, {
  bool shareRecords = false,
}) async {
  if (files.isEmpty) return;
  final confirmed = await showDeleteFilesConfirmDialog(
    context,
    files,
    title: shareRecords ? '删除 ${files.length} 条分享？' : null,
    description: shareRecords
        ? (files.length == 1 ? files.first.name : '将删除所选分享记录。')
        : null,
    warning: shareRecords ? '删除后原分享链接将立即失效。' : '此操作会将项目移入回收站。',
  );
  if (confirmed) await onConfirm();
}

class _SelectionActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  const _SelectionActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final color = destructive ? cs.destructive : cs.foreground;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: destructive
                ? cs.destructive.withValues(alpha: 0.08)
                : cs.secondary,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: destructive
                  ? cs.destructive.withValues(alpha: 0.35)
                  : cs.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UploadProgressPopover extends StatelessWidget {
  final UploadProgress? progress;

  const _UploadProgressPopover({required this.progress});

  @override
  Widget build(BuildContext context) {
    final value = progress;
    final cs = ShadTheme.of(context).colorScheme;
    if (value == null) {
      return SizedBox(
        width: 260,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Icon(
                Icons.cloud_done_rounded,
                size: 17,
                color: cs.mutedForeground,
              ),
              const SizedBox(width: 8),
              Text(
                '暂无上传任务',
                style: TextStyle(fontSize: 13, color: cs.mutedForeground),
              ),
            ],
          ),
        ),
      );
    }
    final percentage = (value.fraction * 100).round();
    return Semantics(
      label: '上传进度',
      value: '已完成 ${value.processedFiles} / ${value.totalFiles}，$percentage%',
      child: SizedBox(
        width: 292,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AppLoadingIndicator(
                  value: value.fraction,
                  size: AppLoadingSize.compact,
                  color: cs.primary,
                  semanticsLabel: '上传进度',
                  semanticsValue: '$percentage%',
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '正在上传',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: cs.foreground,
                    ),
                  ),
                ),
                Text(
                  '$percentage%',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: cs.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 9),
            Text(
              value.currentFileName.isEmpty
                  ? '正在整理上传结果'
                  : value.currentFileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: cs.foreground),
            ),
            const SizedBox(height: 4),
            Text(
              '已完成 ${value.completedFiles} / ${value.totalFiles} · ${_formatUploadBytes(value.transferredBytes)} / ${_formatUploadBytes(value.totalBytes)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                height: 1.05,
                color: cs.mutedForeground,
              ),
            ),
            if (value.failedFiles > 0) ...[
              const SizedBox(height: 4),
              Text(
                '${value.failedFiles} 个文件上传失败，队列会继续处理其余文件。',
                style: TextStyle(fontSize: 11, color: cs.destructive),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatUploadBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit += 1;
    }
    final precision = unit == 0 ? 0 : (value >= 100 ? 0 : 1);
    return '${value.toStringAsFixed(precision)} ${units[unit]}';
  }
}

class _PrimaryFilePane extends ConsumerWidget {
  final String title;
  final FileState state;
  final _FileViewMode viewMode;
  final bool enableCloudDrag;
  final ValueChanged<_FileViewMode> onViewModeChanged;

  const _PrimaryFilePane({
    required this.title,
    required this.state,
    required this.viewMode,
    required this.enableCloudDrag,
    required this.onViewModeChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isShareSection = state.section == WorkspaceSection.shares;
    if (viewMode == _FileViewMode.columns && !isShareSection) {
      return _ColumnFileBrowser(
        title: title,
        initialPath: state.folderPath,
        initialFiles: state.files,
        onViewModeChanged: onViewModeChanged,
        allowDelete: state.section != WorkspaceSection.recycle,
        enableCloudDrag: enableCloudDrag,
      );
    }
    final notifier = ref.read(fileProvider.notifier);
    final files = _filterCurrentFolderFiles(
      state.files,
      state.currentListSearchQuery,
    );
    return _FilePaneFrame(
      title: title,
      itemCount: files.length,
      isLoading: state.isLoading,
      errorMessage: state.errorMessage,
      emptyLabel: isShareSection
          ? '暂无分享'
          : state.currentListSearchQuery.isEmpty
          ? '没有文件'
          : '当前文件夹没有匹配项',
      breadcrumbPath: state.folderPath,
      onBreadcrumbNavigate: (index) =>
          ref.read(fileProvider.notifier).navigateToPathIndex(index),
      header: _FilePaneHeader(
        trailing: isShareSection
            ? const SizedBox.shrink()
            : _ClipboardPasteButton(
                parentID: state.folderPath.isEmpty
                    ? null
                    : state.folderPath.last.id,
              ),
      ),
      dropParentID: state.folderPath.isEmpty ? null : state.folderPath.last.id,
      onMoveCloudFiles: isShareSection
          ? null
          : (files, parentID) async {
              await notifier.moveFilesTo(files, parentID: parentID);
            },
      onUploadLocalFiles: isShareSection
          ? null
          : (files, parentID) =>
                notifier.uploadLocalFiles(files, parentID: parentID),
      currentPage: state.currentPage,
      pageSize: state.pageSize,
      totalPages: state.totalPages,
      fileCount: files.where((file) => !file.isDirectory).length,
      folderCount: files.where((file) => file.isDirectory).length,
      onPreviousPage: state.currentPage == 0 ? null : notifier.prevPage,
      onNextPage: state.currentPage >= state.totalPages - 1
          ? null
          : notifier.nextPage,
      onPageSizeChanged: notifier.setPageSize,
      // The global toolbar already owns the view switch. Keep the pane header
      // focused on the current folder by using its trailing slot for search.
      trailing: SizedBox(
        width: MediaQuery.sizeOf(context).width < 720 ? 148 : 236,
        child: _CurrentFolderFileSearch(value: state.currentListSearchQuery),
      ),
      child: RefreshIndicator(
        onRefresh: () => notifier.loadFiles(forceRefresh: true),
        child: _FilePaneCollection(
          viewMode: viewMode,
          itemCount: files.length,
          itemIDs: files.map((file) => file.id).toList(growable: false),
          selectedIDs: state.selectedIDs,
          onMarqueeSelectionChanged: notifier.setSelection,
          onSelectAll: notifier.selectAll,
          onDeleteSelected: state.section == WorkspaceSection.recycle
              ? null
              : () {
                  final selected = files
                      .where((file) => state.selectedIDs.contains(file.id))
                      .toList();
                  unawaited(
                    _confirmDeleteCloudFiles(
                      context,
                      selected,
                      () => notifier.deleteFiles(selected),
                      shareRecords: isShareSection,
                    ),
                  );
                },
          itemBuilder: (context, index) {
            final file = files[index];
            final selected = state.selectedIDs.contains(file.id);
            final actionFiles = resolveCloudFileActionSelection(
              files: state.files,
              selectedIDs: state.selectedIDs,
              target: file,
            );
            void selectOrOpen() {
              if (!_isMobilePlatform) {
                _selectDesktopFile(notifier, file);
              } else if (state.selectedIDs.isNotEmpty) {
                notifier.toggleSelection(file.id);
              } else if (file.isDirectory) {
                notifier.navigateToFolder(file);
              } else {
                _openCloudFile(context, ref, file);
              }
            }

            void enterMobileSelection() {
              if (!_isMobilePlatform) return;
              notifier.setSelection({...state.selectedIDs, file.id});
            }

            // Share section uses dedicated ShareListTile
            if (isShareSection) {
              final tile = ShareListTile(
                share: file,
                isSelected: selected,
                onSelect: () => _selectDesktopFile(notifier, file),
                onDelete: () => unawaited(
                  _confirmDeleteCloudFiles(
                    context,
                    actionFiles,
                    () => notifier.deleteFiles(actionFiles),
                    shareRecords: true,
                  ),
                ),
              );
              return tile;
            }

            final tile = FileListTile(
              file: file,
              isSelected: selected,
              onVisible: file.isDirectory
                  ? () => notifier.requestFolderStats(file.id)
                  : null,
              onSelect: selectOrOpen,
              onLongPress: enterMobileSelection,
              onOpen: file.isDirectory
                  ? () => notifier.navigateToFolder(file)
                  : () => _openCloudFile(context, ref, file),
              onPreview: canPreviewCloudFile(file)
                  ? () => _previewCloudFile(context, ref, file)
                  : null,
              onRenameConfirm: (name) async {
                final renamed = await notifier.renameFile(file, name);
                if (renamed) {
                  await ref
                      .read(mediaLibraryProvider.notifier)
                      .synchronizeRenamedFiles([file.copyWith(name: name)]);
                }
              },
              onCopy: _isMobilePlatform
                  ? null
                  : () => notifier.copyToClipboard(actionFiles),
              onCut: _isMobilePlatform
                  ? null
                  : () => notifier.cutToClipboard(actionFiles),
              onCopyTo: () => unawaited(
                _copyOrMoveFilesToDestination(
                  context,
                  ref,
                  actionFiles,
                  move: false,
                ),
              ),
              onMoveTo: () => unawaited(
                _copyOrMoveFilesToDestination(
                  context,
                  ref,
                  actionFiles,
                  move: true,
                ),
              ),
              onDownload: () => notifier.downloadFile(file),
              onShare: () => unawaited(
                showShareLinkDialog(
                  context,
                  title: file.name,
                  createLink: () => notifier.createShare(file),
                ),
              ),
              onCopyFastTransfer: () => notifier.copyFastTransferJSON(file),
              onDetail: () => showFileDetailDialog(context, file),
              isRecycleItem: state.section == WorkspaceSection.recycle,
              onDelete: () => state.section == WorkspaceSection.recycle
                  ? notifier.restoreFiles(actionFiles)
                  : unawaited(
                      _confirmDeleteCloudFiles(
                        context,
                        actionFiles,
                        () => notifier.deleteFiles(actionFiles),
                      ),
                    ),
            );
            final item = _CloudFileDraggable(
              enabled: enableCloudDrag,
              data: _DraggedCloudFiles(
                selected
                    ? files
                          .where((item) => state.selectedIDs.contains(item.id))
                          .toList()
                    : [file],
                _PaneIdentity.primary,
              ),
              feedback: _DragFeedback(label: file.name),
              childWhenDragging: Opacity(opacity: 0.35, child: tile),
              child: _FolderMoveTarget(
                enabled: enableCloudDrag,
                file: file,
                onMove: (sources, parentID) async {
                  await notifier.moveFilesTo(sources, parentID: parentID);
                },
                onOpen: () => notifier.navigateToFolder(file),
                child: tile,
              ),
            );
            if (viewMode == _FileViewMode.list) return item;
            return _CloudFileDraggable(
              enabled: enableCloudDrag,
              data: _DraggedCloudFiles(
                selected
                    ? files
                          .where((item) => state.selectedIDs.contains(item.id))
                          .toList()
                    : [file],
                _PaneIdentity.primary,
              ),
              feedback: _DragFeedback(label: file.name),
              childWhenDragging: Opacity(
                opacity: 0.35,
                child: _FileGridCard(
                  file: file,
                  isSelected: selected,
                  onSelect: () => _selectDesktopFile(notifier, file),
                  onOpen: file.isDirectory
                      ? () => notifier.navigateToFolder(file)
                      : () => _openCloudFile(context, ref, file),
                ),
              ),
              child: _FolderMoveTarget(
                enabled: enableCloudDrag,
                file: file,
                onMove: (sources, parentID) async {
                  await notifier.moveFilesTo(sources, parentID: parentID);
                },
                onOpen: () => notifier.navigateToFolder(file),
                child: _FastTransferContextMenu(
                  file: file,
                  onCopyFastTransfer: () => notifier.copyFastTransferJSON(file),
                  onCopy: _isMobilePlatform
                      ? null
                      : () => notifier.copyToClipboard(actionFiles),
                  onCut: _isMobilePlatform
                      ? null
                      : () => notifier.cutToClipboard(actionFiles),
                  onCopyTo: () => unawaited(
                    _copyOrMoveFilesToDestination(
                      context,
                      ref,
                      actionFiles,
                      move: false,
                    ),
                  ),
                  onMoveTo: () => unawaited(
                    _copyOrMoveFilesToDestination(
                      context,
                      ref,
                      actionFiles,
                      move: true,
                    ),
                  ),
                  onDelete: () => unawaited(
                    _confirmDeleteCloudFiles(
                      context,
                      actionFiles,
                      () => notifier.deleteFiles(actionFiles),
                    ),
                  ),
                  child: _FileGridCard(
                    file: file,
                    isSelected: selected,
                    onSelect: selectOrOpen,
                    onLongPress: enterMobileSelection,
                    onOpen: file.isDirectory
                        ? () => notifier.navigateToFolder(file)
                        : () => _openCloudFile(context, ref, file),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

List<CloudFile> _filterCurrentFolderFiles(List<CloudFile> files, String query) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return files;
  return files
      .where(
        (file) =>
            file.name.toLowerCase().contains(normalized) ||
            file.cloudPath.toLowerCase().contains(normalized),
      )
      .toList();
}

class _CurrentFolderFileSearch extends ConsumerStatefulWidget {
  final String value;

  const _CurrentFolderFileSearch({required this.value});

  @override
  ConsumerState<_CurrentFolderFileSearch> createState() =>
      _CurrentFolderFileSearchState();
}

class _CurrentFolderFileSearchState
    extends ConsumerState<_CurrentFolderFileSearch> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
    _focusNode = FocusNode(debugLabel: 'current-folder-file-search');
  }

  @override
  void didUpdateWidget(covariant _CurrentFolderFileSearch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value &&
        _controller.text != widget.value &&
        !_focusNode.hasFocus) {
      _controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Semantics(
      textField: true,
      label: '搜索当前文件夹',
      child: ShadInput(
        controller: _controller,
        focusNode: _focusNode,
        placeholder: const Text('搜索当前文件夹'),
        leading: Icon(
          Icons.search_rounded,
          size: 16,
          color: cs.mutedForeground,
        ),
        trailing: widget.value.isEmpty
            ? null
            : ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed: () {
                  _controller.clear();
                  ref.read(fileProvider.notifier).setCurrentListSearchQuery('');
                },
                child: const Icon(Icons.close_rounded, size: 16),
              ),
        onChanged: ref.read(fileProvider.notifier).setCurrentListSearchQuery,
      ),
    );
  }
}

class _FilePaneCollection extends StatefulWidget {
  final _FileViewMode viewMode;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final List<String>? itemIDs;
  final Set<String>? selectedIDs;
  final ValueChanged<Set<String>>? onMarqueeSelectionChanged;
  final VoidCallback? onSelectAll;
  final VoidCallback? onDeleteSelected;

  const _FilePaneCollection({
    required this.viewMode,
    required this.itemCount,
    required this.itemBuilder,
    this.itemIDs,
    this.selectedIDs,
    this.onMarqueeSelectionChanged,
    this.onSelectAll,
    this.onDeleteSelected,
  });

  @override
  State<_FilePaneCollection> createState() => _FilePaneCollectionState();
}

/// The desktop marquee used by Finder: dragging in a file pane selects every
/// visible item intersected by the rectangle. Command/Ctrl preserves selection.
class _FilePaneCollectionState extends State<_FilePaneCollection> {
  final _itemKeys = <int, GlobalKey>{};
  final _focusNode = FocusNode(debugLabel: 'file-pane');
  Offset? _start;
  Offset? _current;
  Set<String> _selectionBefore = const {};
  final Set<String> _marqueeHitIDs = {};
  bool _additive = false;
  bool _selectionStarted = false;
  bool _scrollSelectionUpdateScheduled = false;

  bool get _canMarquee =>
      widget.itemIDs != null &&
      widget.selectedIDs != null &&
      widget.onMarqueeSelectionChanged != null;

  GlobalKey _itemKey(int index) => _itemKeys.putIfAbsent(
    index,
    () => GlobalKey(debugLabel: 'file-item-$index'),
  );

  void _pointerDown(PointerDownEvent event) {
    if (!_canMarquee || event.kind != PointerDeviceKind.mouse) return;
    _start = event.localPosition;
    _current = event.localPosition;
    _selectionBefore = Set<String>.from(widget.selectedIDs!);
    _marqueeHitIDs.clear();
    _selectionStarted = false;
    _additive =
        _hasPressedKey(LogicalKeyboardKey.metaLeft) ||
        _hasPressedKey(LogicalKeyboardKey.metaRight) ||
        _hasPressedKey(LogicalKeyboardKey.controlLeft) ||
        _hasPressedKey(LogicalKeyboardKey.controlRight);
  }

  void _pointerMove(PointerMoveEvent event) {
    final start = _start;
    if (start == null ||
        !_canMarquee ||
        (event.localPosition - start).distance < 4) {
      return;
    }
    setState(() => _current = event.localPosition);
    _collectMarqueeHits(event.localPosition);
  }

  void _collectMarqueeHits(Offset currentPosition) {
    final start = _start;
    if (start == null || !_canMarquee) return;
    final pane = context.findRenderObject() as RenderBox?;
    if (pane == null) return;
    final selection = Rect.fromPoints(start, currentPosition);
    final hitIDs = <String>{};
    for (var index = 0; index < widget.itemCount; index++) {
      final itemBox =
          _itemKeys[index]?.currentContext?.findRenderObject() as RenderBox?;
      if (itemBox == null) continue;
      final origin = pane.globalToLocal(itemBox.localToGlobal(Offset.zero));
      if (selection.overlaps(origin & itemBox.size)) {
        hitIDs.add(widget.itemIDs![index]);
      }
    }
    if (_selectionStarted) {
      _marqueeHitIDs.addAll(widget.selectedIDs!);
    }
    _selectionStarted = true;
    _marqueeHitIDs.addAll(hitIDs);
    _emitMarqueeSelection();
  }

  void _emitMarqueeSelection() {
    widget.onMarqueeSelectionChanged!(
      _additive
          ? {..._selectionBefore, ..._marqueeHitIDs}
          : Set<String>.from(_marqueeHitIDs),
    );
  }

  void _pointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        _start == null ||
        !_selectionStarted ||
        !_canMarquee) {
      return;
    }
    _marqueeHitIDs.addAll(widget.selectedIDs!);
    _scheduleSelectionUpdateAfterScroll();
  }

  void _scheduleSelectionUpdateAfterScroll() {
    if (_scrollSelectionUpdateScheduled ||
        _start == null ||
        !_selectionStarted) {
      return;
    }
    _scrollSelectionUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollSelectionUpdateScheduled = false;
      if (!mounted || _start == null || !_selectionStarted || !_canMarquee) {
        return;
      }
      _marqueeHitIDs.addAll(widget.selectedIDs!);
      final current = _current;
      if (current != null) _collectMarqueeHits(current);
    });
  }

  void _pointerEnd(PointerEvent event) {
    if (_start == null) return;
    setState(() {
      _start = null;
      _current = null;
      _marqueeHitIDs.clear();
      _selectionStarted = false;
      _scrollSelectionUpdateScheduled = false;
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final collection = widget.viewMode == _FileViewMode.list
        ? ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            itemCount: widget.itemCount,
            itemBuilder: (context, index) => KeyedSubtree(
              key: _itemKey(index),
              child: widget.itemBuilder(context, index),
            ),
          )
        : LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final columns = width < 400
                  ? (width / 120).floor().clamp(2, 4)
                  : (width / 160).floor().clamp(3, 8);
              return GridView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(10),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1.35,
                ),
                itemCount: widget.itemCount,
                itemBuilder: (context, index) => KeyedSubtree(
                  key: _itemKey(index),
                  child: widget.itemBuilder(context, index),
                ),
              );
            },
          );
    final content = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollUpdateNotification) {
          _scheduleSelectionUpdateAfterScroll();
        }
        return false;
      },
      child: collection,
    );
    final start = _start;
    final current = _current;
    final showMarquee =
        start != null && current != null && (current - start).distance >= 4;
    return FocusableActionDetector(
      focusNode: _focusNode,
      actions: {
        _SelectAllFilesIntent: CallbackAction<_SelectAllFilesIntent>(
          onInvoke: (_) {
            widget.onSelectAll?.call();
            return null;
          },
        ),
        _DeleteSelectedIntent: CallbackAction<_DeleteSelectedIntent>(
          onInvoke: (_) {
            widget.onDeleteSelected?.call();
            return null;
          },
        ),
      },
      shortcuts: {..._desktopSelectAllShortcuts, ..._desktopDeleteShortcuts},
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) {
          _focusNode.requestFocus();
          _pointerDown(event);
        },
        onPointerMove: _pointerMove,
        onPointerSignal: _pointerSignal,
        onPointerUp: _pointerEnd,
        onPointerCancel: _pointerEnd,
        child: Stack(
          fit: StackFit.expand,
          children: [
            content,
            if (showMarquee)
              IgnorePointer(
                child: CustomPaint(
                  painter: _MarqueeSelectionPainter(
                    Rect.fromPoints(start, current),
                    ShadTheme.of(context).colorScheme.primary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MarqueeSelectionPainter extends CustomPainter {
  final Rect rect;
  final Color color;

  const _MarqueeSelectionPainter(this.rect, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(rect, Paint()..color = color.withValues(alpha: 0.12));
    canvas.drawRect(
      rect,
      Paint()
        ..color = color.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _MarqueeSelectionPainter oldDelegate) =>
      oldDelegate.rect != rect || oldDelegate.color != color;
}

class _ColumnListing {
  final String? parentID;
  final String title;
  final List<CloudFile> files;
  final bool isLoading;
  final String? errorMessage;
  final Set<String> selectedIDs;
  final String? selectionAnchorID;

  const _ColumnListing({
    required this.parentID,
    required this.title,
    this.files = const [],
    this.isLoading = false,
    this.errorMessage,
    this.selectedIDs = const {},
    this.selectionAnchorID,
  });

  _ColumnListing copyWith({
    List<CloudFile>? files,
    bool? isLoading,
    String? errorMessage,
    bool clearError = false,
    Set<String>? selectedIDs,
    String? selectionAnchorID,
    bool clearSelection = false,
  }) {
    return _ColumnListing(
      parentID: parentID,
      title: title,
      files: files ?? this.files,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      selectedIDs: clearSelection
          ? const {}
          : (selectedIDs ?? this.selectedIDs),
      selectionAnchorID: clearSelection
          ? null
          : (selectionAnchorID ?? this.selectionAnchorID),
    );
  }
}

class _ColumnFileBrowser extends ConsumerStatefulWidget {
  final String title;
  final List<CloudFile> initialPath;
  final List<CloudFile> initialFiles;
  final ValueChanged<_FileViewMode> onViewModeChanged;
  final _PaneIdentity source;
  final Future<void> Function(List<CloudFile> files, String? parentID)?
  onMoveCloudFiles;
  final Future<void> Function(List<File> files, String? parentID)?
  onUploadLocalFiles;
  final bool allowDelete;
  final bool enableCloudDrag;
  final ValueChanged<List<CloudFile>>? onPathChanged;

  const _ColumnFileBrowser({
    required this.title,
    required this.initialPath,
    required this.initialFiles,
    required this.onViewModeChanged,
    this.source = _PaneIdentity.primary,
    this.onMoveCloudFiles,
    this.onUploadLocalFiles,
    this.allowDelete = true,
    this.enableCloudDrag = true,
    this.onPathChanged,
  });

  @override
  ConsumerState<_ColumnFileBrowser> createState() => _ColumnFileBrowserState();
}

class _ColumnFileBrowserState extends ConsumerState<_ColumnFileBrowser> {
  List<_ColumnListing> _columns = const [];
  List<CloudFile> _path = const [];
  var _generation = 0;
  final _scrollController = ScrollController();

  /// One tracker per column index, so folder statistics are fetched only for
  /// the rows that scroll into view.
  final _statsTrackers = <int, VisibleFolderStatsTracker>{};

  @override
  void initState() {
    super.initState();
    _restorePath(widget.initialPath, initialFiles: widget.initialFiles);
  }

  @override
  void dispose() {
    for (final tracker in _statsTrackers.values) {
      tracker.dispose();
    }
    _statsTrackers.clear();
    _scrollController.dispose();
    super.dispose();
  }

  /// Returns the tracker for [index], creating it on first use. Trackers read
  /// live state through closures so they stay correct as columns are replaced.
  VisibleFolderStatsTracker _statsTrackerFor(int index) {
    return _statsTrackers.putIfAbsent(index, () {
      final generation = _generation;
      return VisibleFolderStatsTracker(
        api: () => ref.read(authProvider.notifier).api,
        currentFiles: () =>
            index < _columns.length ? _columns[index].files : const [],
        parentID: () =>
            index < _columns.length ? _columns[index].parentID : null,
        isCancelled: () =>
            !mounted || generation != _generation || index >= _columns.length,
        onUpdated: (enriched) {
          if (index >= _columns.length) return;
          _replaceColumn(
            index,
            _columns[index].copyWith(files: enriched),
            _generation,
          );
        },
      );
    });
  }

  /// Drops trackers for columns that no longer exist, and for every column
  /// when the navigation generation changes.
  void _pruneStatsTrackers({bool all = false}) {
    if (all) {
      for (final tracker in _statsTrackers.values) {
        tracker.dispose();
      }
      _statsTrackers.clear();
      return;
    }
    final stale = _statsTrackers.keys
        .where((index) => index >= _columns.length)
        .toList();
    for (final index in stale) {
      _statsTrackers.remove(index)?.dispose();
    }
  }

  @override
  void didUpdateWidget(covariant _ColumnFileBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_samePath(_path, widget.initialPath)) {
      _restorePath(widget.initialPath, initialFiles: widget.initialFiles);
    } else if (!_sameFiles(oldWidget.initialFiles, widget.initialFiles)) {
      _applyInitialFiles(widget.initialFiles);
    }
  }

  bool _samePath(List<CloudFile> a, List<CloudFile> b) {
    return a.length == b.length &&
        Iterable.generate(
          a.length,
        ).every((index) => a[index].id == b[index].id);
  }

  bool _sameFiles(List<CloudFile> a, List<CloudFile> b) {
    return a.length == b.length &&
        Iterable.generate(a.length).every((index) {
          final left = a[index];
          final right = b[index];
          return left.id == right.id &&
              left.name == right.name &&
              left.isDirectory == right.isDirectory &&
              left.size == right.size &&
              left.modifiedAt == right.modifiedAt;
        });
  }

  void _applyInitialFiles(List<CloudFile> files) {
    if (_columns.isEmpty) return;
    final targetIndex = _path.isEmpty ? 0 : _path.length;
    if (targetIndex >= _columns.length) return;
    ++_generation;
    setState(() {
      final columns = _columns.toList();
      columns[targetIndex] = columns[targetIndex].copyWith(
        files: files,
        isLoading: false,
        clearError: true,
      );
      _columns = columns;
    });
  }

  Future<void> _restorePath(
    List<CloudFile> path, {
    List<CloudFile>? initialFiles,
  }) async {
    final generation = ++_generation;
    final restoredPath = List<CloudFile>.unmodifiable(path);
    // Every column is rebuilt from scratch here.
    _pruneStatsTrackers(all: true);
    setState(() {
      _path = restoredPath;
      _columns = [
        const _ColumnListing(parentID: null, title: '全部文件', isLoading: true),
      ];
    });
    _scrollToStart();
    await _loadColumn(0, generation: generation);
    for (var index = 0; index < restoredPath.length; index++) {
      if (!mounted || generation != _generation) return;
      final folder = restoredPath[index];
      setState(() {
        final columns = _columns.toList();
        columns[index] = columns[index].copyWith(
          selectedIDs: {folder.id},
          selectionAnchorID: folder.id,
        );
        columns.add(
          _ColumnListing(
            parentID: folder.id,
            title: folder.name,
            isLoading: true,
          ),
        );
        _columns = columns;
      });
      if (index == restoredPath.length - 1 && initialFiles != null) {
        _replaceColumn(
          index + 1,
          _columns[index + 1].copyWith(
            files: initialFiles,
            isLoading: false,
            clearError: true,
          ),
          generation,
        );
      } else {
        await _loadColumn(index + 1, generation: generation);
      }
    }
  }

  Future<void> _loadColumn(int index, {int? generation}) async {
    final requestGeneration = generation ?? _generation;
    if (index >= _columns.length) return;
    _replaceColumn(
      index,
      _columns[index].copyWith(isLoading: true, clearError: true),
      requestGeneration,
    );
    try {
      final api = ref.read(authProvider.notifier).api;
      final result = await api.fsFiles(
        parentID: _columns[index].parentID,
        page: 0,
        pageSize: 200,
      );
      // The list endpoint omits per-folder child counts; apply whatever is
      // already memoised so cached columns render complete immediately.
      final files = FolderStatsLoader.instance.applyCached(
        _cloudFilesFromResponse(result),
      );
      _replaceColumn(
        index,
        _columns[index].copyWith(
          files: files,
          isLoading: false,
          clearError: true,
        ),
        requestGeneration,
      );
      // Pull anything already in the persistent cache — one local query for the
      // whole column, no network. Rows still missing statistics are fetched
      // lazily as they scroll into view (see _statsTrackerFor).
      unawaited(
        FolderStatsLoader.instance.hydrate(
          files,
          api: api,
          parentID: _columns[index].parentID,
          visibleIDs: const {},
          isCancelled: () =>
              !mounted ||
              requestGeneration != _generation ||
              index >= _columns.length,
          onUpdated: (enriched) {
            if (index >= _columns.length) return;
            _replaceColumn(
              index,
              _columns[index].copyWith(files: enriched),
              requestGeneration,
            );
          },
        ),
      );
    } catch (error) {
      _replaceColumn(
        index,
        _columns[index].copyWith(
          isLoading: false,
          errorMessage: error.toString(),
        ),
        requestGeneration,
      );
    }
  }

  void _replaceColumn(int index, _ColumnListing column, int generation) {
    if (!mounted || generation != _generation || index >= _columns.length) {
      return;
    }
    setState(() {
      final columns = _columns.toList();
      columns[index] = column;
      _columns = columns;
    });
  }

  void _openFolder(int index, CloudFile folder) {
    final path = [..._path.take(index), folder];
    final generation = ++_generation;
    // Columns beyond this one are replaced, so their trackers would otherwise
    // keep pointing at the previous directory.
    for (final key
        in _statsTrackers.keys.where((key) => key > index).toList()) {
      _statsTrackers.remove(key)?.dispose();
    }
    setState(() {
      _path = List<CloudFile>.unmodifiable(path);
      final columns = _columns.take(index + 1).toList();
      columns[index] = columns[index].copyWith(
        selectedIDs: {folder.id},
        selectionAnchorID: folder.id,
      );
      columns.add(
        _ColumnListing(
          parentID: folder.id,
          title: folder.name,
          isLoading: true,
        ),
      );
      _columns = columns;
    });
    unawaited(_loadColumn(index + 1, generation: generation));
    _scrollToLatestColumn();
    _notifyPathChanged(path);
  }

  void _collapseToColumn(int index) {
    if (index < 0 || index >= _columns.length || index == _columns.length - 1) {
      return;
    }
    final path = _path.take(index).toList(growable: false);
    ++_generation;
    setState(() {
      _path = List<CloudFile>.unmodifiable(path);
      _columns = _columns.take(index + 1).toList(growable: false);
    });
    _pruneStatsTrackers();
    _notifyPathChanged(path);
    _scrollToColumn(index);
  }

  void _selectColumnFile(int columnIndex, CloudFile file) {
    if (columnIndex >= _columns.length) return;
    final column = _columns[columnIndex];
    final index = column.files.indexWhere((item) => item.id == file.id);
    if (index < 0) return;
    final command =
        _hasPressedKey(LogicalKeyboardKey.metaLeft) ||
        _hasPressedKey(LogicalKeyboardKey.metaRight) ||
        _hasPressedKey(LogicalKeyboardKey.controlLeft) ||
        _hasPressedKey(LogicalKeyboardKey.controlRight);
    final shift =
        _hasPressedKey(LogicalKeyboardKey.shiftLeft) ||
        _hasPressedKey(LogicalKeyboardKey.shiftRight);
    final selected = Set<String>.from(column.selectedIDs);
    if (shift && column.selectionAnchorID != null) {
      final anchor = column.files.indexWhere(
        (item) => item.id == column.selectionAnchorID,
      );
      if (anchor >= 0) {
        if (!command) selected.clear();
        selected.addAll(
          column.files
              .sublist(
                anchor < index ? anchor : index,
                anchor > index ? anchor + 1 : index + 1,
              )
              .map((item) => item.id),
        );
      }
    } else if (command) {
      selected.contains(file.id)
          ? selected.remove(file.id)
          : selected.add(file.id);
    } else {
      selected
        ..clear()
        ..add(file.id);
    }
    setState(() {
      final columns = _columns.toList();
      columns[columnIndex] = column.copyWith(
        selectedIDs: selected,
        selectionAnchorID: file.id,
      );
      _columns = columns;
    });
    // A plain folder click in Finder column view reveals its children.
    if (file.isDirectory && !command && !shift) _openFolder(columnIndex, file);
  }

  void _scrollToStart() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  void _scrollToLatestColumn() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _scrollToColumn(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final target = (index * 244.0).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _navigateBreadcrumb(int index) {
    final path = index < 0
        ? const <CloudFile>[]
        : _path.take(index + 1).toList();
    unawaited(_restorePath(path));
    _notifyPathChanged(path);
  }

  void _notifyPathChanged(List<CloudFile> path) {
    final onPathChanged = widget.onPathChanged;
    if (onPathChanged != null) {
      onPathChanged(path);
      return;
    }
    unawaited(ref.read(fileProvider.notifier).navigateToFolderPath(path));
  }

  Future<void> _moveFiles(
    List<CloudFile> files,
    String? parentID,
    int index,
  ) async {
    final refreshIndexes = <int>{index};
    for (var columnIndex = 0; columnIndex < _columns.length; columnIndex++) {
      final ids = _columns[columnIndex].files.map((file) => file.id).toSet();
      if (files.any((file) => ids.contains(file.id))) {
        refreshIndexes.add(columnIndex);
      }
      if (_columns[columnIndex].parentID == parentID) {
        refreshIndexes.add(columnIndex);
      }
    }
    final onMoveCloudFiles = widget.onMoveCloudFiles;
    if (onMoveCloudFiles != null) {
      await onMoveCloudFiles(files, parentID);
    } else {
      await ref
          .read(fileProvider.notifier)
          .moveFilesTo(files, parentID: parentID);
    }
    if (mounted) {
      await Future.wait(refreshIndexes.map(_loadColumn));
    }
  }

  Future<void> _renameColumnFile(CloudFile file) async {
    final controller = TextEditingController(text: file.name);
    final newName = await showShadDialog<String>(
      context: context,
      builder: (dialogContext) => ShadDialog(
        title: const Text('重命名'),
        description: Text(file.name),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          ShadButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('确认'),
          ),
        ],
        child: ShadInput(controller: controller, autofocus: true),
      ),
    );
    controller.dispose();
    if (newName == null || newName.isEmpty || newName == file.name) return;
    await ref.read(authProvider.notifier).api.fsRename(file.id, newName);
    await ref.read(mediaLibraryProvider.notifier).synchronizeRenamedFiles([
      file.copyWith(name: newName),
    ]);
    final affected = <int>{};
    for (var index = 0; index < _columns.length; index++) {
      if (_columns[index].files.any((item) => item.id == file.id)) {
        affected.add(index);
      }
    }
    if (mounted) await Future.wait(affected.map(_loadColumn));
  }

  Future<void> _uploadFiles(
    List<File> files,
    String? parentID,
    int index,
  ) async {
    final onUploadLocalFiles = widget.onUploadLocalFiles;
    if (onUploadLocalFiles != null) {
      await onUploadLocalFiles(files, parentID);
    } else {
      await ref
          .read(fileProvider.notifier)
          .uploadLocalFiles(files, parentID: parentID);
    }
    if (mounted) await _loadColumn(index);
  }

  void _selectAllColumn(int index) {
    if (index >= _columns.length) return;
    setState(() {
      final columns = _columns.toList();
      final column = columns[index];
      columns[index] = column.copyWith(
        selectedIDs: column.files.map((file) => file.id).toSet(),
      );
      _columns = columns;
    });
  }

  void _deleteColumnFiles(int index, List<CloudFile> files) {
    if (!widget.allowDelete || files.isEmpty) return;
    unawaited(
      _confirmDeleteCloudFiles(context, files, () async {
        await ref.read(fileProvider.notifier).deleteFiles(files);
        if (mounted) await _loadColumn(index);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final itemCount = _columns.isEmpty ? 0 : _columns.last.files.length;
    return _FilePaneFrame(
      title: widget.title,
      itemCount: itemCount,
      isLoading: _columns.isEmpty,
      errorMessage: null,
      emptyLabel: '没有文件',
      showChildWhenEmpty: true,
      breadcrumbPath: _path,
      onBreadcrumbNavigate: _navigateBreadcrumb,
      header: const _ColumnPaneHeader(),
      currentPage: 0,
      pageSize: 200,
      totalPages: 1,
      fileCount: _columns.isEmpty
          ? 0
          : _columns.last.files.where((file) => !file.isDirectory).length,
      folderCount: _columns.isEmpty
          ? 0
          : _columns.last.files.where((file) => file.isDirectory).length,
      trailing: _PaneViewToggle(
        value: _FileViewMode.columns,
        onChanged: widget.onViewModeChanged,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Scrollbar(
          controller: _scrollController,
          thumbVisibility: true,
          trackVisibility: true,
          interactive: true,
          scrollbarOrientation: ScrollbarOrientation.bottom,
          child: SingleChildScrollView(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: SizedBox(
                height: constraints.maxHeight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var index = 0; index < _columns.length; index++)
                      _FinderColumn(
                        key: ValueKey('${_columns[index].parentID}-$index'),
                        column: _columns[index],
                        source: widget.source,
                        enableCloudDrag: widget.enableCloudDrag,
                        onItemVisible: _statsTrackerFor(index).onItemBuilt,
                        onActivate: () => _collapseToColumn(index),
                        onSelect: (file) => _selectColumnFile(index, file),
                        onSelectAll: () => _selectAllColumn(index),
                        onDeleteSelected: (files) =>
                            _deleteColumnFiles(index, files),
                        onRename: _renameColumnFile,
                        onCopy: (files) => ref
                            .read(fileProvider.notifier)
                            .copyToClipboard(files),
                        onCut: (files) => ref
                            .read(fileProvider.notifier)
                            .cutToClipboard(files),
                        onDownload: (file) =>
                            ref.read(fileProvider.notifier).downloadFile(file),
                        onShare: (file) => unawaited(
                          showShareLinkDialog(
                            context,
                            title: file.name,
                            createLink: () => ref
                                .read(fileProvider.notifier)
                                .createShare(file),
                          ),
                        ),
                        onOpenFolder: (folder) => _openFolder(index, folder),
                        onOpenFile: (file) =>
                            _openCloudFile(context, ref, file),
                        onMoveCloudFiles: (files, parentID) =>
                            _moveFiles(files, parentID, index),
                        onUploadLocalFiles: (files, parentID) =>
                            _uploadFiles(files, parentID, index),
                        onCopyFastTransfer: (file) => ref
                            .read(fileProvider.notifier)
                            .copyFastTransferJSON(file),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ColumnPaneHeader extends StatelessWidget {
  const _ColumnPaneHeader();

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Text(
        'Finder 分栏浏览',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: cs.mutedForeground,
        ),
      ),
    );
  }
}

class _FinderColumn extends StatefulWidget {
  final _ColumnListing column;
  final _PaneIdentity source;
  final bool enableCloudDrag;

  /// Reports rows as the list builds them, so folder statistics are only
  /// fetched for what the user can actually see.
  final void Function(CloudFile file)? onItemVisible;
  final VoidCallback onActivate;
  final ValueChanged<CloudFile> onSelect;
  final VoidCallback onSelectAll;
  final ValueChanged<List<CloudFile>> onDeleteSelected;
  final Future<void> Function(CloudFile file) onRename;
  final ValueChanged<List<CloudFile>> onCopy;
  final ValueChanged<List<CloudFile>> onCut;
  final ValueChanged<CloudFile> onDownload;
  final ValueChanged<CloudFile> onShare;
  final ValueChanged<CloudFile> onOpenFolder;
  final ValueChanged<CloudFile> onOpenFile;
  final ValueChanged<CloudFile> onCopyFastTransfer;
  final Future<void> Function(List<CloudFile> files, String? parentID)
  onMoveCloudFiles;
  final Future<void> Function(List<File> files, String? parentID)
  onUploadLocalFiles;

  const _FinderColumn({
    super.key,
    required this.column,
    required this.source,
    required this.enableCloudDrag,
    this.onItemVisible,
    required this.onActivate,
    required this.onSelect,
    required this.onSelectAll,
    required this.onDeleteSelected,
    required this.onRename,
    required this.onCopy,
    required this.onCut,
    required this.onDownload,
    required this.onShare,
    required this.onOpenFolder,
    required this.onOpenFile,
    required this.onCopyFastTransfer,
    required this.onMoveCloudFiles,
    required this.onUploadLocalFiles,
  });

  @override
  State<_FinderColumn> createState() => _FinderColumnState();
}

class _FinderColumnState extends State<_FinderColumn> {
  var _dragActive = false;
  final _focusNode = FocusNode(debugLabel: 'finder-column');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final column = widget.column;
    return FocusableActionDetector(
      focusNode: _focusNode,
      shortcuts: {..._desktopSelectAllShortcuts, ..._desktopDeleteShortcuts},
      actions: {
        _SelectAllFilesIntent: CallbackAction<_SelectAllFilesIntent>(
          onInvoke: (_) {
            widget.onSelectAll();
            return null;
          },
        ),
        _DeleteSelectedIntent: CallbackAction<_DeleteSelectedIntent>(
          onInvoke: (_) {
            final selected = widget.column.files
                .where((file) => widget.column.selectedIDs.contains(file.id))
                .toList();
            widget.onDeleteSelected(selected);
            return null;
          },
        ),
      },
      child: Listener(
        onPointerDown: (event) {
          _focusNode.requestFocus();
          final hasModifier =
              _hasPressedKey(LogicalKeyboardKey.metaLeft) ||
              _hasPressedKey(LogicalKeyboardKey.metaRight) ||
              _hasPressedKey(LogicalKeyboardKey.controlLeft) ||
              _hasPressedKey(LogicalKeyboardKey.controlRight) ||
              _hasPressedKey(LogicalKeyboardKey.shiftLeft) ||
              _hasPressedKey(LogicalKeyboardKey.shiftRight);
          if (event.buttons == kPrimaryButton && !hasModifier) {
            widget.onActivate();
          }
        },
        child: SizedBox(
          width: 244,
          child: DropTarget(
            onDragEntered: (_) => setState(() => _dragActive = true),
            onDragExited: (_) => setState(() => _dragActive = false),
            onDragDone: (details) async {
              setState(() => _dragActive = false);
              final files = details.files
                  .map((file) => file.path)
                  .where((path) => path.isNotEmpty)
                  .map(File.new)
                  .where((file) => file.existsSync())
                  .toList();
              if (files.isNotEmpty) {
                await widget.onUploadLocalFiles(files, column.parentID);
              }
            },
            child: DragTarget<_DraggedCloudFiles>(
              onWillAcceptWithDetails: (details) =>
                  widget.enableCloudDrag &&
                  !details.data.files.every(
                    (file) =>
                        _sameCloudParentID(file.parentID, column.parentID),
                  ),
              onAcceptWithDetails: (details) async {
                setState(() => _dragActive = false);
                await widget.onMoveCloudFiles(
                  details.data.files,
                  column.parentID,
                );
              },
              onLeave: (_) => setState(() => _dragActive = false),
              builder: (context, candidates, rejected) => AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                decoration: BoxDecoration(
                  color: _dragActive || candidates.isNotEmpty
                      ? cs.primary.withValues(alpha: 0.10)
                      : cs.secondary,
                  border: Border(
                    right: BorderSide(color: cs.border.withValues(alpha: 0.70)),
                    left: BorderSide(
                      color: _dragActive || candidates.isNotEmpty
                          ? cs.primary
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Column(
                  children: [
                    Container(
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              column.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                color: cs.foreground,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${column.files.where((file) => file.isDirectory).length} 夹 · '
                            '${column.files.where((file) => !file.isDirectory).length} 件',
                            style: TextStyle(
                              fontSize: 10,
                              color: cs.mutedForeground,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Divider(
                      height: 1,
                      color: cs.border.withValues(alpha: 0.60),
                    ),
                    Expanded(
                      child: column.isLoading
                          ? const _ShadLoading()
                          : column.errorMessage != null
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Text(
                                  column.errorMessage!,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: cs.destructive,
                                  ),
                                ),
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              itemCount: column.files.length,
                              itemBuilder: (context, index) {
                                final file = column.files[index];
                                // ListView.builder only builds rows near the
                                // viewport, making this an accurate signal for
                                // lazily loading folder statistics.
                                widget.onItemVisible?.call(file);
                                final selected = column.selectedIDs.contains(
                                  file.id,
                                );
                                final actionFiles =
                                    resolveCloudFileActionSelection(
                                      files: column.files,
                                      selectedIDs: column.selectedIDs,
                                      target: file,
                                    );
                                final row = _FinderColumnContextMenu(
                                  file: file,
                                  onOpen: () {
                                    if (file.isDirectory) {
                                      widget.onOpenFolder(file);
                                    } else {
                                      widget.onOpenFile(file);
                                    }
                                  },
                                  onRename: () => widget.onRename(file),
                                  onCopy: () => widget.onCopy(actionFiles),
                                  onCut: () => widget.onCut(actionFiles),
                                  onDownload: file.isDirectory
                                      ? null
                                      : () => widget.onDownload(file),
                                  onShare: () => widget.onShare(file),
                                  onCopyFastTransfer: () =>
                                      widget.onCopyFastTransfer(file),
                                  onDelete: () =>
                                      widget.onDeleteSelected(actionFiles),
                                  child: _FinderColumnItem(
                                    file: file,
                                    selected: selected,
                                    onTap: () => widget.onSelect(file),
                                    onOpen: () {
                                      if (file.isDirectory) {
                                        widget.onOpenFolder(file);
                                      } else {
                                        widget.onOpenFile(file);
                                      }
                                    },
                                  ),
                                );
                                return _CloudFileDraggable(
                                  enabled: widget.enableCloudDrag,
                                  data: _DraggedCloudFiles(
                                    selected
                                        ? column.files
                                              .where(
                                                (item) => column.selectedIDs
                                                    .contains(item.id),
                                              )
                                              .toList()
                                        : [file],
                                    widget.source,
                                  ),
                                  feedback: _DragFeedback(label: file.name),
                                  childWhenDragging: Opacity(
                                    opacity: 0.35,
                                    child: row,
                                  ),
                                  child: _FolderMoveTarget(
                                    enabled: widget.enableCloudDrag,
                                    file: file,
                                    onMove: widget.onMoveCloudFiles,
                                    onOpen: () => widget.onOpenFolder(file),
                                    child: row,
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FinderColumnContextMenu extends StatelessWidget {
  final CloudFile file;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onCopy;
  final VoidCallback onCut;
  final VoidCallback? onDownload;
  final VoidCallback onShare;
  final VoidCallback onCopyFastTransfer;
  final VoidCallback onDelete;
  final Widget child;

  const _FinderColumnContextMenu({
    required this.file,
    required this.onOpen,
    required this.onRename,
    required this.onCopy,
    required this.onCut,
    required this.onDownload,
    required this.onShare,
    required this.onCopyFastTransfer,
    required this.onDelete,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ShadContextMenuRegion(
      tapEnabled: false,
      constraints: const BoxConstraints(minWidth: 190),
      items: [
        ShadContextMenuItem.inset(
          leading: Icon(
            file.isDirectory ? LucideIcons.folderOpen : LucideIcons.eye,
            size: 16,
          ),
          onPressed: onOpen,
          child: Text(file.isDirectory ? '打开文件夹' : '打开'),
        ),
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.pencil, size: 16),
          onPressed: onRename,
          child: const Text('重命名'),
        ),
        const Divider(height: 8),
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.copy, size: 16),
          onPressed: onCopy,
          child: const Text('复制'),
        ),
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.scissors, size: 16),
          onPressed: onCut,
          child: const Text('剪切'),
        ),
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.download, size: 16),
          onPressed: onDownload,
          child: const Text('下载'),
        ),
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.share2, size: 16),
          onPressed: onShare,
          child: const Text('分享'),
        ),
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.zap, size: 16),
          onPressed: onCopyFastTransfer,
          child: Text(file.isDirectory ? '复制目录秒传' : '复制秒传'),
        ),
        const Divider(height: 8),
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.info, size: 16),
          onPressed: () => showFileDetailDialog(context, file),
          child: const Text('详情'),
        ),
        const Divider(height: 8),
        ShadContextMenuItem.inset(
          leading: Icon(LucideIcons.trash2, size: 16, color: cs.destructive),
          onPressed: onDelete,
          child: Text('删除', style: TextStyle(color: cs.destructive)),
        ),
      ],
      child: child,
    );
  }
}

class _FinderColumnItem extends StatelessWidget {
  final CloudFile file;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onOpen;

  const _FinderColumnItem({
    required this.file,
    required this.selected,
    required this.onTap,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      onDoubleTap: onOpen,
      child: Container(
        height: 34,
        margin: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 7),
        decoration: BoxDecoration(
          color: selected ? cs.primary.withValues(alpha: 0.16) : null,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            SizedBox(width: 20, height: 20, child: FileIcon(file: file)),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                file.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: cs.foreground),
              ),
            ),
            if (file.isDirectory)
              Icon(
                Icons.chevron_right_rounded,
                size: 17,
                color: cs.mutedForeground,
              ),
          ],
        ),
      ),
    );
  }
}

List<CloudFile> _cloudFilesFromResponse(Map<String, dynamic> json) {
  final result = <CloudFile>[];
  final seen = <String>{};
  void visit(dynamic value) {
    if (value is Map) {
      try {
        final file = CloudFile.fromJson(Map<String, dynamic>.from(value));
        if (seen.add(file.id)) result.add(file);
      } catch (_) {
        // Response envelopes and non-file map nodes are expected here.
      }
      for (final child in value.values) {
        visit(child);
      }
    } else if (value is List) {
      for (final child in value) {
        visit(child);
      }
    }
  }

  visit(json);
  return result;
}

class _FastTransferContextMenu extends StatelessWidget {
  final CloudFile file;
  final VoidCallback onCopyFastTransfer;
  final VoidCallback? onCopy;
  final VoidCallback? onCut;
  final VoidCallback? onCopyTo;
  final VoidCallback? onMoveTo;
  final VoidCallback? onDelete;
  final Widget child;

  const _FastTransferContextMenu({
    required this.file,
    required this.onCopyFastTransfer,
    this.onCopy,
    this.onCut,
    this.onCopyTo,
    this.onMoveTo,
    this.onDelete,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return ShadContextMenuRegion(
      tapEnabled: false,
      items: [
        if (onCopy != null)
          ShadContextMenuItem.inset(
            leading: const Icon(LucideIcons.copy, size: 16),
            onPressed: onCopy,
            child: const Text('复制'),
          ),
        if (onCut != null)
          ShadContextMenuItem.inset(
            leading: const Icon(LucideIcons.scissors, size: 16),
            onPressed: onCut,
            child: const Text('剪切'),
          ),
        if (onCopyTo != null)
          ShadContextMenuItem.inset(
            leading: const Icon(LucideIcons.copyPlus, size: 16),
            onPressed: onCopyTo,
            child: const Text('复制到…'),
          ),
        if (onMoveTo != null)
          ShadContextMenuItem.inset(
            leading: const Icon(LucideIcons.folderInput, size: 16),
            onPressed: onMoveTo,
            child: const Text('移动到…'),
          ),
        const Divider(height: 8),
        ShadContextMenuItem.inset(
          leading: const Icon(Icons.bolt_rounded, size: 16),
          onPressed: onCopyFastTransfer,
          child: Text(file.isDirectory ? '复制目录秒传' : '复制秒传'),
        ),
        const Divider(height: 8),
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.info, size: 16),
          onPressed: () => showFileDetailDialog(context, file),
          child: const Text('详情'),
        ),
        if (onDelete != null) ...[
          const Divider(height: 8),
          ShadContextMenuItem.inset(
            leading: Icon(
              LucideIcons.trash2,
              size: 16,
              color: ShadTheme.of(context).colorScheme.destructive,
            ),
            onPressed: onDelete,
            child: Text(
              '删除',
              style: TextStyle(
                color: ShadTheme.of(context).colorScheme.destructive,
              ),
            ),
          ),
        ],
      ],
      child: child,
    );
  }
}

class _SecondaryFilePane extends ConsumerStatefulWidget {
  const _SecondaryFilePane();

  @override
  ConsumerState<_SecondaryFilePane> createState() => _SecondaryFilePaneState();
}

class _SecondaryFilePaneState extends ConsumerState<_SecondaryFilePane> {
  final _path = <CloudFile>[];
  var _files = <CloudFile>[];
  var _loading = false;
  String? _error;
  var _page = 0;
  var _pageSize = configuredDefaultFilePageSize();
  var _totalPages = 1;
  var _viewMode = _FileViewMode.list;
  var _detailGeneration = 0;
  final _selectedIDs = <String>{};
  String? _selectionAnchorID;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load({String? parentID}) async {
    final generation = ++_detailGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(authProvider.notifier).api;
      final result = await api.fsFiles(
        parentID: parentID,
        page: _page,
        pageSize: _pageSize,
      );
      final files = _extractFiles(result);
      setState(() {
        _files = files;
        _totalPages = _extractTotalPages(result, files.length);
      });
      unawaited(_enrichFolderSizes(files, generation));
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _enrichFolderSizes(List<CloudFile> files, int generation) async {
    final cache = _readFolderSizeCache();
    final now = DateTime.now().millisecondsSinceEpoch;
    final ttl = Duration(
      minutes:
          (int.tryParse(
                    StorageManager.get<String>(
                          StorageKeys.fileCacheTTLMinutes,
                        ) ??
                        '3',
                  ) ??
                  3)
              .clamp(1, 60),
    ).inMilliseconds;
    final queue = <CloudFile>[];
    final cached = <String, int>{};
    for (final file in files.where((file) => file.isDirectory)) {
      final entry = cache[file.id];
      final cachedAt = int.tryParse(entry?['cachedAt']?.toString() ?? '');
      final size = int.tryParse(entry?['size']?.toString() ?? '');
      if (cachedAt != null &&
          size != null &&
          size > 0 &&
          now - cachedAt <= ttl) {
        cached[file.id] = size;
      } else {
        queue.add(file);
      }
    }

    void apply(Map<String, int> sizes) {
      if (!mounted || generation != _detailGeneration || sizes.isEmpty) return;
      setState(() {
        _files = _files
            .map(
              (file) => sizes.containsKey(file.id)
                  ? file.copyWith(size: sizes[file.id])
                  : file,
            )
            .toList();
      });
    }

    apply(cached);
    if (queue.isEmpty) return;
    final api = ref.read(authProvider.notifier).api;
    final resolved = <String, int>{};
    await Future.wait(
      List.generate(6, (_) async {
        while (queue.isNotEmpty) {
          final folder = queue.removeLast();
          try {
            final detail = await api.fsDetail(folder.id);
            final size = _findIntDeep(detail, const [
              'size',
              'fileSize',
              'resSize',
              'totalSize',
              'dirSize',
              'folderSize',
            ]);
            if (size == null) continue;
            cache[folder.id] = {'size': size, 'cachedAt': now};
            resolved[folder.id] = size;
            apply({folder.id: size});
          } catch (_) {
            // Continue enriching the visible folders after an individual failure.
          }
        }
      }),
    );
    if (resolved.isNotEmpty) {
      await StorageManager.set(StorageKeys.fileMetadataCache, cache);
    }
  }

  Map<String, Map<String, dynamic>> _readFolderSizeCache() {
    final raw = StorageManager.get<dynamic>(StorageKeys.fileMetadataCache);
    if (raw is! Map) return <String, Map<String, dynamic>>{};
    return raw.map(
      (key, value) => MapEntry(
        key.toString(),
        value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{},
      ),
    );
  }

  int? _findIntDeep(Map<String, dynamic> value, List<String> keys) {
    for (final entry in value.entries) {
      if (keys.contains(entry.key)) {
        final parsed = int.tryParse(entry.value?.toString() ?? '');
        if (parsed != null) return parsed;
      }
      if (entry.value is Map) {
        final found = _findIntDeep(
          Map<String, dynamic>.from(entry.value),
          keys,
        );
        if (found != null) return found;
      } else if (entry.value is List) {
        for (final child in entry.value as List) {
          if (child is Map) {
            final found = _findIntDeep(Map<String, dynamic>.from(child), keys);
            if (found != null) return found;
          }
        }
      }
    }
    return null;
  }

  String? get _currentParentID => _path.isEmpty ? null : _path.last.id;

  void _selectWithModifiers(CloudFile file) {
    final index = _files.indexWhere((item) => item.id == file.id);
    if (index < 0) return;
    final command =
        _hasPressedKey(LogicalKeyboardKey.metaLeft) ||
        _hasPressedKey(LogicalKeyboardKey.metaRight) ||
        _hasPressedKey(LogicalKeyboardKey.controlLeft) ||
        _hasPressedKey(LogicalKeyboardKey.controlRight);
    final shift =
        _hasPressedKey(LogicalKeyboardKey.shiftLeft) ||
        _hasPressedKey(LogicalKeyboardKey.shiftRight);
    final selected = Set<String>.from(_selectedIDs);
    if (shift && _selectionAnchorID != null) {
      final anchor = _files.indexWhere((item) => item.id == _selectionAnchorID);
      if (anchor >= 0) {
        final range = _files
            .sublist(
              anchor < index ? anchor : index,
              anchor > index ? anchor + 1 : index + 1,
            )
            .map((item) => item.id);
        if (!command) selected.clear();
        selected.addAll(range);
      }
    } else if (command) {
      selected.contains(file.id)
          ? selected.remove(file.id)
          : selected.add(file.id);
      _selectionAnchorID = file.id;
    } else {
      selected
        ..clear()
        ..add(file.id);
      _selectionAnchorID = file.id;
    }
    setState(() {
      _selectedIDs
        ..clear()
        ..addAll(selected);
    });
  }

  void _selectOrOpen(CloudFile file) {
    if (!_isMobilePlatform) {
      _selectWithModifiers(file);
    } else if (_selectedIDs.isNotEmpty) {
      setState(() {
        _selectedIDs.contains(file.id)
            ? _selectedIDs.remove(file.id)
            : _selectedIDs.add(file.id);
      });
    } else {
      _open(file);
    }
  }

  void _enterMobileSelection(CloudFile file) {
    if (!_isMobilePlatform) return;
    setState(() => _selectedIDs.add(file.id));
  }

  void _open(CloudFile file) {
    if (file.isDirectory) {
      setState(() {
        _path.add(file);
        _page = 0;
        _selectedIDs.clear();
        _selectionAnchorID = null;
      });
      unawaited(_load(parentID: file.id));
    } else {
      _openCloudFile(context, ref, file);
    }
  }

  Future<void> _moveCloudFiles(List<CloudFile> files, String? parentID) async {
    if (files.isEmpty) return;
    final movable = files
        .where((file) => !_sameCloudParentID(file.parentID, parentID))
        .toList(growable: false);
    if (movable.isEmpty) {
      ShadToaster.maybeOf(context)?.show(
        const ShadToast(
          title: Text('移动'),
          description: Text('不能移动至相同目录'),
          showCloseIconOnlyWhenHovered: false,
        ),
      );
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(authProvider.notifier).api;
      await api.fsMove(
        movable.map((file) => file.id).toList(),
        parentID: parentID,
      );
      await _load(parentID: _currentParentID);
      await ref.read(fileProvider.notifier).loadFiles();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _uploadLocalFiles(List<File> files, String? parentID) async {
    if (files.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref
          .read(fileProvider.notifier)
          .uploadLocalFiles(files, parentID: parentID);
      await _load(parentID: _currentParentID);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_viewMode == _FileViewMode.columns) {
      return _ColumnFileBrowser(
        title: _path.isEmpty ? '右侧面板' : _path.last.name,
        initialPath: _path,
        initialFiles: _files,
        source: _PaneIdentity.secondary,
        onViewModeChanged: (mode) {
          setState(() => _viewMode = mode);
          if (mode != _FileViewMode.columns) {
            unawaited(_load(parentID: _currentParentID));
          }
        },
        onMoveCloudFiles: _moveCloudFiles,
        onUploadLocalFiles: _uploadLocalFiles,
        onPathChanged: (path) {
          setState(() {
            _path
              ..clear()
              ..addAll(path);
            _page = 0;
          });
        },
      );
    }
    return _FilePaneFrame(
      title: _path.isEmpty ? '右侧面板' : _path.last.name,
      itemCount: _files.length,
      isLoading: _loading,
      errorMessage: _error,
      emptyLabel: '没有文件',
      breadcrumbPath: _path,
      onBreadcrumbNavigate: _navigateBreadcrumb,
      dropParentID: _currentParentID,
      onMoveCloudFiles: _moveCloudFiles,
      onUploadLocalFiles: _uploadLocalFiles,
      header: Row(
        children: [
          if (_path.isNotEmpty)
            _ToolbarButton(
              icon: Icons.arrow_back_rounded,
              label: '返回',
              onTap: () {
                setState(() {
                  _path.removeLast();
                  _page = 0;
                });
                _load(parentID: _path.isEmpty ? null : _path.last.id);
              },
            ),
          Expanded(
            child: _FilePaneHeader(
              trailing: _ClipboardPasteButton(
                parentID: _currentParentID,
                onCompleted: () => _load(parentID: _currentParentID),
              ),
            ),
          ),
        ],
      ),
      currentPage: _page,
      pageSize: _pageSize,
      totalPages: _totalPages,
      fileCount: _files.where((file) => !file.isDirectory).length,
      folderCount: _files.where((file) => file.isDirectory).length,
      onPreviousPage: _page == 0
          ? null
          : () {
              setState(() => _page -= 1);
              _load(parentID: _currentParentID);
            },
      onNextPage: _page >= _totalPages - 1
          ? null
          : () {
              setState(() => _page += 1);
              _load(parentID: _currentParentID);
            },
      onPageSizeChanged: (size) {
        setState(() {
          _pageSize = size;
          _page = 0;
        });
        _load(parentID: _currentParentID);
      },
      trailing: _PaneViewToggle(
        value: _viewMode,
        onChanged: (mode) => setState(() => _viewMode = mode),
      ),
      child: RefreshIndicator(
        onRefresh: () => _load(parentID: _currentParentID),
        child: _FilePaneCollection(
          viewMode: _viewMode,
          itemCount: _files.length,
          itemIDs: _files.map((file) => file.id).toList(growable: false),
          selectedIDs: _selectedIDs,
          onMarqueeSelectionChanged: (ids) => setState(() {
            _selectedIDs
              ..clear()
              ..addAll(ids);
          }),
          onSelectAll: () => setState(() {
            _selectedIDs
              ..clear()
              ..addAll(_files.map((file) => file.id));
          }),
          onDeleteSelected: () {
            final selected = _files
                .where((file) => _selectedIDs.contains(file.id))
                .toList();
            unawaited(
              _confirmDeleteCloudFiles(context, selected, () async {
                await ref.read(fileProvider.notifier).deleteFiles(selected);
                if (mounted) await _load(parentID: _currentParentID);
              }),
            );
          },
          itemBuilder: (context, index) {
            final file = _files[index];
            final selected = _selectedIDs.contains(file.id);
            final actionFiles = resolveCloudFileActionSelection(
              files: _files,
              selectedIDs: _selectedIDs,
              target: file,
            );
            final row = FileListTile(
              file: file,
              isSelected: selected,
              onVisible: file.isDirectory
                  ? () => ref
                        .read(fileProvider.notifier)
                        .requestFolderStats(file.id)
                  : null,
              onSelect: () => _selectOrOpen(file),
              onLongPress: () => _enterMobileSelection(file),
              onOpen: () => _open(file),
              onPreview: canPreviewCloudFile(file)
                  ? () => _previewCloudFile(context, ref, file)
                  : null,
              onCopy: () =>
                  ref.read(fileProvider.notifier).copyToClipboard(actionFiles),
              onCut: () =>
                  ref.read(fileProvider.notifier).cutToClipboard(actionFiles),
              onCopyTo: () => unawaited(() async {
                final completed = await _copyOrMoveFilesToDestination(
                  context,
                  ref,
                  actionFiles,
                  move: false,
                );
                if (completed && mounted) {
                  await _load(parentID: _currentParentID);
                }
              }()),
              onMoveTo: () => unawaited(() async {
                final completed = await _copyOrMoveFilesToDestination(
                  context,
                  ref,
                  actionFiles,
                  move: true,
                );
                if (completed && mounted) {
                  await _load(parentID: _currentParentID);
                }
              }()),
              onRenameConfirm: (name) async {
                final renamed = await ref
                    .read(fileProvider.notifier)
                    .renameFile(file, name);
                if (renamed) {
                  await ref
                      .read(mediaLibraryProvider.notifier)
                      .synchronizeRenamedFiles([file.copyWith(name: name)]);
                }
                if (!mounted) return;
                setState(() {
                  _files = _files
                      .map(
                        (item) => item.id == file.id
                            ? item.copyWith(name: name)
                            : item,
                      )
                      .toList();
                });
              },
              onDownload: () =>
                  ref.read(fileProvider.notifier).downloadFile(file),
              onShare: () => unawaited(
                showShareLinkDialog(
                  context,
                  title: file.name,
                  createLink: () =>
                      ref.read(fileProvider.notifier).createShare(file),
                ),
              ),
              onCopyFastTransfer: () =>
                  ref.read(fileProvider.notifier).copyFastTransferJSON(file),
              onDelete: () => unawaited(
                _confirmDeleteCloudFiles(context, actionFiles, () async {
                  await ref
                      .read(fileProvider.notifier)
                      .deleteFiles(actionFiles);
                  if (mounted) await _load(parentID: _currentParentID);
                }),
              ),
            );
            if (_viewMode == _FileViewMode.list) {
              return _CloudFileDraggable(
                data: _DraggedCloudFiles(
                  selected
                      ? _files
                            .where((item) => _selectedIDs.contains(item.id))
                            .toList()
                      : [file],
                  _PaneIdentity.secondary,
                ),
                feedback: _DragFeedback(label: file.name),
                childWhenDragging: Opacity(opacity: 0.35, child: row),
                child: _FolderMoveTarget(
                  file: file,
                  onMove: _moveCloudFiles,
                  onOpen: () => _open(file),
                  child: row,
                ),
              );
            }

            final card = _FastTransferContextMenu(
              file: file,
              onCopyFastTransfer: () =>
                  ref.read(fileProvider.notifier).copyFastTransferJSON(file),
              onCopy: () =>
                  ref.read(fileProvider.notifier).copyToClipboard(actionFiles),
              onCut: () =>
                  ref.read(fileProvider.notifier).cutToClipboard(actionFiles),
              onCopyTo: () => unawaited(() async {
                final completed = await _copyOrMoveFilesToDestination(
                  context,
                  ref,
                  actionFiles,
                  move: false,
                );
                if (completed && mounted) {
                  await _load(parentID: _currentParentID);
                }
              }()),
              onMoveTo: () => unawaited(() async {
                final completed = await _copyOrMoveFilesToDestination(
                  context,
                  ref,
                  actionFiles,
                  move: true,
                );
                if (completed && mounted) {
                  await _load(parentID: _currentParentID);
                }
              }()),
              onDelete: () => unawaited(
                _confirmDeleteCloudFiles(context, actionFiles, () async {
                  await ref
                      .read(fileProvider.notifier)
                      .deleteFiles(actionFiles);
                  if (mounted) await _load(parentID: _currentParentID);
                }),
              ),
              child: _FileGridCard(
                file: file,
                isSelected: selected,
                onSelect: () => _selectOrOpen(file),
                onLongPress: () => _enterMobileSelection(file),
                onOpen: () => _open(file),
              ),
            );
            return _CloudFileDraggable(
              data: _DraggedCloudFiles(
                selected
                    ? _files
                          .where((item) => _selectedIDs.contains(item.id))
                          .toList()
                    : [file],
                _PaneIdentity.secondary,
              ),
              feedback: _DragFeedback(label: file.name),
              childWhenDragging: Opacity(opacity: 0.35, child: card),
              child: _FolderMoveTarget(
                file: file,
                onMove: _moveCloudFiles,
                onOpen: () => _open(file),
                child: card,
              ),
            );
          },
        ),
      ),
    );
  }

  List<CloudFile> _extractFiles(Map<String, dynamic> json) {
    final result = <CloudFile>[];
    final seen = <String>{};
    void visit(dynamic value) {
      if (value is Map) {
        try {
          final file = CloudFile.fromJson(Map<String, dynamic>.from(value));
          if (seen.add(file.id)) result.add(file);
        } catch (_) {}
        for (final child in value.values) {
          visit(child);
        }
      } else if (value is List) {
        for (final child in value) {
          visit(child);
        }
      }
    }

    visit(json);
    return result;
  }

  void _navigateBreadcrumb(int index) {
    if (index < 0) {
      setState(() {
        _path.clear();
        _page = 0;
      });
      _load();
      return;
    }
    if (!_path.asMap().containsKey(index)) return;
    setState(() {
      _path.removeRange(index + 1, _path.length);
      _page = 0;
    });
    _load(parentID: _path.isEmpty ? null : _path.last.id);
  }

  int _extractTotalPages(Map<String, dynamic> json, int itemCount) {
    int? find(Map<String, dynamic> value) {
      for (final key in const [
        'totalPages',
        'pages',
        'pageCount',
        'total',
        'totalCount',
        'count',
      ]) {
        final raw = value[key];
        final parsed = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
        if (parsed != null && parsed >= 0) return parsed;
      }
      for (final child in value.values) {
        if (child is Map) {
          final result = find(Map<String, dynamic>.from(child));
          if (result != null) return result;
        }
      }
      return null;
    }

    final result = find(json);
    if (result == null) return itemCount < _pageSize ? 1 : _page + 2;
    if (result <= 0) return 1;
    final hasExplicitPageCount =
        json.containsKey('totalPages') ||
        json.containsKey('pages') ||
        json.containsKey('pageCount');
    return hasExplicitPageCount
        ? result
        : (result / _pageSize).ceil().clamp(1, 1 << 31).toInt();
  }
}

class _FilePaneFrame extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final int itemCount;
  final bool isLoading;
  final String? errorMessage;
  final String emptyLabel;
  final bool showChildWhenEmpty;
  final String? dropParentID;
  final List<CloudFile> breadcrumbPath;
  final ValueChanged<int>? onBreadcrumbNavigate;
  final Future<void> Function(List<CloudFile> files, String? parentID)?
  onMoveCloudFiles;
  final Future<void> Function(List<File> files, String? parentID)?
  onUploadLocalFiles;
  final Widget header;
  final Widget child;
  final int currentPage;
  final int pageSize;
  final int totalPages;
  final int fileCount;
  final int folderCount;
  final VoidCallback? onPreviousPage;
  final VoidCallback? onNextPage;
  final ValueChanged<int>? onPageSizeChanged;

  const _FilePaneFrame({
    required this.title,
    this.trailing,
    required this.itemCount,
    required this.isLoading,
    required this.errorMessage,
    required this.emptyLabel,
    this.showChildWhenEmpty = false,
    this.dropParentID,
    this.breadcrumbPath = const [],
    this.onBreadcrumbNavigate,
    this.onMoveCloudFiles,
    this.onUploadLocalFiles,
    required this.header,
    required this.child,
    this.currentPage = 0,
    this.pageSize = 50,
    this.totalPages = 1,
    this.fileCount = 0,
    this.folderCount = 0,
    this.onPreviousPage,
    this.onNextPage,
    this.onPageSizeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return _PaneDropSurface(
      parentID: dropParentID,
      onMoveCloudFiles: onMoveCloudFiles,
      onUploadLocalFiles: onUploadLocalFiles,
      child: Container(
        decoration: BoxDecoration(
          color: cs.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.border),
        ),
        child: Column(
          children: [
            Container(
              // ShadInput uses a 48px touch target. Keep it inline while
              // reserving enough height for typed text and its decoration.
              height: 56,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compactHeader = constraints.maxWidth < 520;
                  return Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: cs.foreground,
                                ),
                              ),
                            ),
                            if (!compactHeader) ...[
                              const SizedBox(width: 8),
                              Text(
                                '$folderCount 个文件夹 · $fileCount 个文件',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.mutedForeground,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (trailing case final Widget trailing) trailing,
                    ],
                  );
                },
              ),
            ),
            Divider(height: 1, color: cs.border.withValues(alpha: 0.62)),
            SizedBox(
              height: 36,
              child: BreadcrumbBar(
                path: breadcrumbPath,
                onNavigate: onBreadcrumbNavigate ?? (_) {},
              ),
            ),
            Divider(height: 1, color: cs.border.withValues(alpha: 0.62)),
            SizedBox(height: 34, child: header),
            Divider(height: 1, color: cs.border.withValues(alpha: 0.62)),
            Expanded(
              child: isLoading
                  ? const _ShadLoading()
                  : errorMessage != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          errorMessage!,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: cs.destructive),
                        ),
                      ),
                    )
                  : itemCount == 0 && !showChildWhenEmpty
                  ? Center(
                      child: Text(
                        emptyLabel,
                        style: TextStyle(color: cs.mutedForeground),
                      ),
                    )
                  : child,
            ),
            _PanePagination(
              currentPage: currentPage,
              pageSize: pageSize,
              totalPages: totalPages,
              fileCount: fileCount,
              folderCount: folderCount,
              onPreviousPage: onPreviousPage,
              onNextPage: onNextPage,
              onPageSizeChanged: onPageSizeChanged,
            ),
          ],
        ),
      ),
    );
  }
}

class _ShadLoading extends StatelessWidget {
  const _ShadLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: AppLoadingIndicator(
        size: AppLoadingSize.page,
        label: '正在加载文件夹内容',
        description: '正在同步文件、大小和修改时间',
      ),
    );
  }
}

class _FilePaneHeader extends StatelessWidget {
  final Widget? trailing;

  const _FilePaneHeader({this.trailing});

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final style = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w800,
      color: cs.mutedForeground,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          const SizedBox(width: 44),
          Expanded(child: Text('名称', style: style)),
          SizedBox(
            width: 88,
            child: Text('大小', textAlign: TextAlign.right, style: style),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 116,
            child: Text('修改时间', textAlign: TextAlign.right, style: style),
          ),
          if (trailing case final Widget trailing) ...[
            const SizedBox(width: 8),
            trailing,
          ],
        ],
      ),
    );
  }
}
