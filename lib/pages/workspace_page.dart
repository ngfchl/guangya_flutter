import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide showShadDialog, showShadSheet;
import 'package:window_manager/window_manager.dart';

import '../app/app_theme.dart';
import '../core/storage/storage_manager.dart';
import '../core/utils/guangya_share_link.dart';
import '../models/cloud_file.dart';
import '../models/media_library.dart';
import '../models/media_navigation.dart';
import '../providers/auth_provider.dart';
import '../providers/file_provider.dart';
import '../providers/media_library_provider.dart';
import '../widgets/app_dialog.dart';
import '../widgets/breadcrumb_bar.dart';
import '../widgets/app_loading_indicator.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/file_list_tile.dart';
import '../widgets/file_detail_dialog.dart';
import '../widgets/media_player_dialog.dart';
import '../widgets/file_icon.dart';
import '../widgets/share_link_dialog.dart';
import '../widgets/share_list_tile.dart';
import '../widgets/share_qr_scanner_dialog.dart';
import '../widgets/share_restore_dialog.dart';
import '../widgets/side_panel.dart';
import '../widgets/window_controls.dart';
import '../widgets/sort_menu.dart';
import 'media_library_page.dart';
import 'app_upgrade_page.dart';
import 'search_results_page.dart';
import 'settings_page.dart';
import 'workspace_tools_page.dart';

enum WorkspaceMode { cloud, media }

enum _PaneLayoutMode { single, dual }

enum _FileViewMode { list, columns, grid }

enum _PaneIdentity { primary, secondary }

bool get _isMobilePlatform => switch (defaultTargetPlatform) {
  TargetPlatform.android || TargetPlatform.iOS => true,
  _ => false,
};

bool get _isDesktopWindow =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

double get _sidebarWindowControlInset => Platform.isMacOS ? 46 : 24;

class _DraggedCloudFiles {
  final List<CloudFile> files;
  final _PaneIdentity source;

  const _DraggedCloudFiles(this.files, this.source);
}

class _CloudFileDraggable extends StatelessWidget {
  final _DraggedCloudFiles data;
  final Widget feedback;
  final Widget childWhenDragging;
  final Widget child;
  final bool enabled;

  const _CloudFileDraggable({
    required this.data,
    required this.feedback,
    required this.childWhenDragging,
    required this.child,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled || _isMobilePlatform) return child;
    return Draggable<_DraggedCloudFiles>(
      data: data,
      feedback: feedback,
      childWhenDragging: childWhenDragging,
      child: child,
    );
  }
}

bool _hasPressedKey(LogicalKeyboardKey key) =>
    HardwareKeyboard.instance.logicalKeysPressed.contains(key);

bool _sameCloudParentID(String? left, String? right) {
  final normalizedLeft = left?.trim();
  final normalizedRight = right?.trim();
  final effectiveLeft = normalizedLeft == null || normalizedLeft.isEmpty
      ? null
      : normalizedLeft;
  final effectiveRight = normalizedRight == null || normalizedRight.isEmpty
      ? null
      : normalizedRight;
  return effectiveLeft == effectiveRight;
}

const _desktopSelectAllShortcuts = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.keyA, meta: true): _SelectAllFilesIntent(),
  SingleActivator(LogicalKeyboardKey.keyA, control: true):
      _SelectAllFilesIntent(),
};

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

class _CloudFolderDestination {
  final String? parentID;

  const _CloudFolderDestination(this.parentID);
}

Future<bool> _copyOrMoveFilesToDestination(
  BuildContext context,
  WidgetRef ref,
  List<CloudFile> files, {
  required bool move,
}) async {
  if (files.isEmpty) return false;
  final destination = await showShadDialog<_CloudFolderDestination>(
    context: context,
    builder: (_) => _CloudFolderDestinationPicker(move: move),
  );
  if (destination == null || !context.mounted) return false;
  if (move &&
      files.every(
        (file) => _sameCloudParentID(file.parentID, destination.parentID),
      )) {
    ShadToaster.maybeOf(context)?.show(
      const ShadToast(
        title: Text('移动'),
        description: Text('不能移动至相同目录'),
        showCloseIconOnlyWhenHovered: false,
      ),
    );
    return false;
  }
  final notifier = ref.read(fileProvider.notifier);
  if (move) {
    await notifier.moveFilesTo(files, parentID: destination.parentID);
  } else {
    await notifier.copyFilesTo(files, parentID: destination.parentID);
  }
  return true;
}

class _CloudFolderDestinationPicker extends ConsumerStatefulWidget {
  final bool move;

  const _CloudFolderDestinationPicker({required this.move});

  @override
  ConsumerState<_CloudFolderDestinationPicker> createState() =>
      _CloudFolderDestinationPickerState();
}

class _CloudFolderDestinationPickerState
    extends ConsumerState<_CloudFolderDestinationPicker> {
  final _path = <CloudFile>[];
  final _filterController = TextEditingController();
  var _folders = <CloudFile>[];
  CloudFile? _selectedFolder;
  var _loading = false;
  String? _error;
  String _filterQuery = '';

  List<CloudFile> get _filteredFolders {
    if (_filterQuery.isEmpty) return _folders;
    final q = _filterQuery.toLowerCase();
    return _folders.where((f) => f.name.toLowerCase().contains(q)).toList();
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  void _clearFilter() {
    _filterController.clear();
    _filterQuery = '';
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await ref
          .read(authProvider.notifier)
          .api
          .fsFiles(
            parentID: _path.isEmpty ? null : _path.last.id,
            pageSize: 1000,
          );
      if (mounted) {
        setState(() {
          _folders =
              _cloudFilesFromResponse(
                response,
              ).where((file) => file.isDirectory).toList()..sort(
                (left, right) =>
                    left.name.toLowerCase().compareTo(right.name.toLowerCase()),
              );
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _enterFolder(CloudFile folder) {
    setState(() {
      _path.add(folder);
      _selectedFolder = null;
      _clearFilter();
    });
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final currentName = _path.isEmpty ? '云盘根目录' : _path.last.name;
    final destinationName = _selectedFolder?.name ?? currentName;
    return ShadDialog(
      title: Text(widget.move ? '移动到' : '复制到'),
      description: Text('目标文件夹：$destinationName'),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ShadButton(
          onPressed: () => Navigator.of(context).pop(
            _CloudFolderDestination(
              _selectedFolder?.id ?? (_path.isEmpty ? null : _path.last.id),
            ),
          ),
          child: const Text('选择'),
        ),
      ],
      child: SizedBox(
        width: 440,
        height: 340,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                ShadButton.ghost(
                  size: ShadButtonSize.sm,
                  onPressed: _path.isEmpty
                      ? null
                      : () {
                          setState(() {
                            _path.clear();
                            _selectedFolder = null;
                            _clearFilter();
                          });
                          unawaited(_load());
                        },
                  child: const Text('根目录'),
                ),
                for (var index = 0; index < _path.length; index++)
                  ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    onPressed: () {
                      setState(() {
                        _path.removeRange(index + 1, _path.length);
                        _selectedFolder = null;
                        _clearFilter();
                      });
                      unawaited(_load());
                    },
                    child: Text(_path[index].name),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (!_loading && _error == null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ShadInput(
                  placeholder: const Text('筛选文件夹…'),
                  controller: _filterController,
                  onChanged: (value) => setState(() => _filterQuery = value),
                  leading: const Icon(Icons.search, size: 16),
                ),
              ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: AppLoadingIndicator(
                        size: AppLoadingSize.page,
                        label: '正在读取文件夹',
                      ),
                    )
                  : _error != null
                  ? Center(
                      child: Text(
                        _error!,
                        style: TextStyle(color: cs.destructive),
                      ),
                    )
                  : _filteredFolders.isEmpty
                  ? Center(
                      child: Text(
                        _folders.isEmpty ? '当前目录没有文件夹' : '没有匹配的文件夹',
                        style: TextStyle(color: cs.mutedForeground),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _filteredFolders.length,
                      itemBuilder: (context, index) {
                        final folder = _filteredFolders[index];
                        final selected = _selectedFolder?.id == folder.id;
                        return InkWell(
                          onTap: () => setState(() => _selectedFolder = folder),
                          onDoubleTap: () => _enterFolder(folder),
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            height: 38,
                            padding: const EdgeInsets.only(left: 10, right: 4),
                            decoration: BoxDecoration(
                              color: selected
                                  ? cs.primary.withValues(alpha: 0.14)
                                  : null,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.folder_rounded,
                                  size: 18,
                                  color: selected ? cs.primary : cs.foreground,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    folder.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                ShadTooltip(
                                  builder: (_) => const Text('进入目录'),
                                  child: ShadButton.ghost(
                                    size: ShadButtonSize.sm,
                                    onPressed: () => _enterFolder(folder),
                                    child: const Icon(
                                      Icons.chevron_right_rounded,
                                      size: 18,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
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

class WorkspacePage extends ConsumerStatefulWidget {
  const WorkspacePage({super.key});

  @override
  ConsumerState<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends ConsumerState<WorkspacePage> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  bool _readingClipboard = false;
  bool _shareDialogOpen = false;
  WorkspaceMode _mode = WorkspaceMode.cloud;
  bool _isSidePanelOpen = false;
  bool _searchOpen = false;
  String? _fileSearchQuery;
  String? _fileSearchReturnQuery;
  List<CloudFile>? _fileSearchResultsCache;
  String? _mediaSearchQuery;
  MediaLibraryBrowseFilter _mediaBrowseFilter = MediaLibraryBrowseFilter.all;
  MediaLibraryBrowseFilter _mediaLibrarySection = MediaLibraryBrowseFilter.all;
  bool _mediaHomeSelected = true;
  WorkspaceTool? _cloudActiveTool;
  WorkspaceTool? _mediaActiveTool;

  @override
  void initState() {
    super.initState();
    if (StorageManager.get<String>(StorageKeys.workspaceMode) == 'media') {
      _mode = WorkspaceMode.media;
    }
  }

  Future<void> _pasteShareLink() async {
    if (!mounted || _readingClipboard || _shareDialogOpen) return;
    setState(() => _readingClipboard = true);
    String? text;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      text = data?.text?.trim();
    } catch (_) {
      if (mounted) {
        ShadToaster.maybeOf(
          context,
        )?.show(const ShadToast(description: Text('无法读取剪贴板')));
      }
      return;
    } finally {
      if (mounted) {
        setState(() => _readingClipboard = false);
      } else {
        _readingClipboard = false;
      }
    }
    if (!mounted) return;
    if (text == null || text.isEmpty) {
      ShadToaster.maybeOf(
        context,
      )?.show(const ShadToast(description: Text('剪贴板为空')));
      return;
    }
    final share = GuangyaShareLink.tryParse(text);
    if (share == null) {
      ShadToaster.maybeOf(
        context,
      )?.show(const ShadToast(description: Text('未识别到分享链接')));
      return;
    }
    _shareDialogOpen = true;
    try {
      await showShareRestoreDialog(context, share);
    } finally {
      _shareDialogOpen = false;
    }
  }

  Future<void> _scanShareQRCode() async {
    if (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS) {
      ShadToaster.maybeOf(context)?.show(
        const ShadToast(title: Text('扫一扫'), description: Text('当前平台暂不支持相机扫码')),
      );
      return;
    }
    final share = await showShareQRScannerDialog(context);
    if (!mounted || share == null) return;
    await showShareRestoreDialog(context, share);
  }

  void _openTool(WorkspaceTool tool) {
    if (_mode == WorkspaceMode.media) {
      ref.read(activeMediaDetailHeaderProvider.notifier).state = null;
    }
    setState(() {
      if (_mode == WorkspaceMode.cloud) {
        _cloudActiveTool = tool;
      } else {
        _mediaActiveTool = tool;
      }
    });
  }

  void _closeActiveTool() {
    if (_mode == WorkspaceMode.media) {
      ref.read(activeMediaDetailHeaderProvider.notifier).state = null;
    }
    setState(() {
      if (_mode == WorkspaceMode.cloud) {
        _cloudActiveTool = null;
      } else {
        _mediaActiveTool = null;
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fp = ref.watch(fileProvider);
    final media = ref.watch(mediaLibraryProvider);
    final mediaDetail = ref.watch(activeMediaDetailHeaderProvider);
    ref.listen<FileState>(fileProvider, (previous, next) {
      final message = next.errorMessage ?? next.statusMessage;
      final previousMessage = previous?.errorMessage ?? previous?.statusMessage;
      final isProgressMessage =
          next.errorMessage == null && message?.startsWith('正在') == true;
      if (message == null ||
          message.isEmpty ||
          message == previousMessage ||
          isProgressMessage) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ShadToaster.maybeOf(context)?.show(
          next.errorMessage == null
              ? ShadToast(
                  title: const Text('云盘'),
                  description: Text(message),
                  showCloseIconOnlyWhenHovered: false,
                )
              : ShadToast.destructive(
                  title: const Text('云盘操作失败'),
                  description: Text(message),
                  showCloseIconOnlyWhenHovered: false,
                ),
        );
      });
    });

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: OS26Surface(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 720;
              final topBar = _TopBar(
                mode: _mode,
                compact: compact,
                searchController: _searchController,
                searchFocusNode: _searchFocusNode,
                searchOpen: _searchOpen,
                onSearch: _submitSearch,
                onToggleSearch: _toggleSearch,
                onScanShare: _scanShareQRCode,
                onPasteShare: _readingClipboard ? null : _pasteShareLink,
                onOpenMenu: () => _showMobileMenu(context),
                mediaState: media,
                mediaFilter: _mediaBrowseFilter,
                mediaLibrarySection: _mediaLibrarySection,
                mediaHomeSelected: _mediaHomeSelected,
                onMediaLibrarySectionChanged: _changeMediaLibrarySection,
                onMediaSortChanged: (sort) => unawaited(
                  ref.read(mediaLibraryProvider.notifier).setSort(sort),
                ),
                onMediaSortDirectionChanged: (direction) => unawaited(
                  ref
                      .read(mediaLibraryProvider.notifier)
                      .setSortDirection(direction),
                ),
                hideMediaIdentity:
                    _mode == WorkspaceMode.media && _mediaActiveTool != null,
                uploadProgress: fp.uploadProgress,
                mediaDetail: mediaDetail,
                onCloseMediaDetail: () =>
                    ref.read(activeMediaDetailHeaderProvider.notifier).state =
                        null,
              );
              final rawContent = IndexedStack(
                index: _mode == WorkspaceMode.cloud ? 0 : 1,
                children: [_buildCloudContent(fp), _buildMediaContent()],
              );
              final content = _mode == WorkspaceMode.media
                  ? OS26Glass(
                      radius: 18,
                      opacity: 0.42,
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          if (_mediaActiveTool == null) ...[
                            topBar,
                            const ShadSeparator.horizontal(),
                          ],
                          Expanded(child: rawContent),
                        ],
                      ),
                    )
                  : rawContent;
              if (compact) {
                return _MobileDrawerSwipeArea(
                  onOpen: () => _showMobileMenu(context),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                    child: Column(
                      children: [
                        if (_mode == WorkspaceMode.cloud) ...[
                          topBar,
                          const SizedBox(height: 8),
                        ],
                        Expanded(child: content),
                      ],
                    ),
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    _mode == WorkspaceMode.cloud
                        ? _CloudSidebar(
                            state: fp,
                            onSection: (section) => ref
                                .read(fileProvider.notifier)
                                .setSection(section),
                            onSettings: () => _showSettings(context),
                            onModeChanged: _changeMode,
                            onSignOut: () =>
                                ref.read(authProvider.notifier).signOut(),
                            onTool: _openTool,
                            activeTool: _cloudActiveTool,
                          )
                        : _MediaSidebar(
                            onModeChanged: _changeMode,
                            onSettings: () => _showSettings(context),
                            onScanTasks: () => _showScanTaskManagement(context),
                            onManage: () =>
                                _showMediaLibraryManagement(context),
                            onTool: _openTool,
                            activeTool: _mediaActiveTool,
                            selectedFilter: _mediaBrowseFilter,
                            onFilter: _changeMediaBrowseFilter,
                            homeSelected: _mediaHomeSelected,
                            onHome: _showMediaHome,
                            onSelectLibrary: _selectMediaLibrary,
                          ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        children: [
                          if (_mode == WorkspaceMode.cloud) ...[
                            topBar,
                            const SizedBox(height: 10),
                          ],
                          Expanded(child: content),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _changeMode(WorkspaceMode mode) {
    if (_mode == mode) return;
    if (mode != WorkspaceMode.media) {
      ref.read(activeMediaDetailHeaderProvider.notifier).state = null;
    }
    setState(() {
      _mode = mode;
      _searchOpen = false;
      _searchController.clear();
    });
    unawaited(StorageManager.set(StorageKeys.workspaceMode, mode.name));
    if (mode == WorkspaceMode.media) {
      ref.read(mediaLibraryProvider.notifier).api = ref
          .read(authProvider.notifier)
          .api;
      ref.read(mediaLibraryProvider.notifier).load();
    }
  }

  void _changeMediaBrowseFilter(MediaLibraryBrowseFilter filter) {
    ref.read(activeMediaDetailHeaderProvider.notifier).state = null;
    setState(() {
      _mediaBrowseFilter = filter;
      _mediaLibrarySection = MediaLibraryBrowseFilter.all;
      _mediaHomeSelected = false;
      _mediaActiveTool = null;
    });
  }

  void _showMediaHome() {
    ref.read(activeMediaDetailHeaderProvider.notifier).state = null;
    setState(() {
      _mediaBrowseFilter = MediaLibraryBrowseFilter.all;
      _mediaLibrarySection = MediaLibraryBrowseFilter.all;
      _mediaHomeSelected = true;
      _mediaActiveTool = null;
    });
  }

  void _showMediaLibraryManagement(BuildContext context) {
    ref.read(activeMediaDetailHeaderProvider.notifier).state = null;
    setState(() => _mediaActiveTool = null);
    MediaLibraryPage.showManagementDialog(context, ref);
  }

  void _showScanTaskManagement(BuildContext context) {
    ref.read(activeMediaDetailHeaderProvider.notifier).state = null;
    setState(() => _mediaActiveTool = null);
    MediaLibraryPage.showScanTaskDialog(context, ref);
  }

  void _selectMediaLibrary(String id) {
    ref.read(activeMediaDetailHeaderProvider.notifier).state = null;
    setState(() {
      _mediaBrowseFilter = MediaLibraryBrowseFilter.all;
      _mediaLibrarySection = MediaLibraryBrowseFilter.all;
      _mediaHomeSelected = false;
      _mediaActiveTool = null;
    });
    unawaited(ref.read(mediaLibraryProvider.notifier).selectLibrary(id));
  }

  void _changeMediaLibrarySection(MediaLibraryBrowseFilter filter) {
    ref.read(activeMediaDetailHeaderProvider.notifier).state = null;
    setState(() => _mediaLibrarySection = filter);
  }

  void _submitSearch(String value) {
    final query = value.trim();
    if (query.isEmpty) return;
    if (_mode == WorkspaceMode.media) {
      ref.read(activeMediaDetailHeaderProvider.notifier).state = null;
      setState(() => _mediaSearchQuery = query);
    } else {
      setState(() {
        _fileSearchQuery = query;
        _fileSearchReturnQuery = null;
        _fileSearchResultsCache = null;
      });
    }
  }

  void _toggleSearch() {
    setState(() => _searchOpen = !_searchOpen);
    if (!_searchOpen) {
      _searchController.clear();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _searchFocusNode.requestFocus(),
    );
  }

  void _showMobileMenu(BuildContext context) {
    final width = (MediaQuery.sizeOf(context).width * 0.72)
        .clamp(236.0, 280.0)
        .toDouble();
    showShadSheet(
      context: context,
      side: ShadSheetSide.left,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          final cs = ShadTheme.of(sheetContext).colorScheme;
          return ShadSheet(
            constraints: BoxConstraints.tightFor(width: width),
            padding: EdgeInsets.zero,
            scrollable: false,
            backgroundColor: cs.background,
            border: const Border(),
            shadows: const [],
            closeIcon: const SizedBox.shrink(),
            child: Material(
              color: cs.background,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                    child: _SidebarBrand(
                      icon: _mode == WorkspaceMode.cloud
                          ? Icons.cloud_sync_rounded
                          : Icons.play_circle_fill_rounded,
                      title: _mode == WorkspaceMode.cloud ? '光鸭云盘' : '光鸭影视',
                      subtitle: _mode == WorkspaceMode.cloud
                          ? 'Cloud Workspace'
                          : 'Media Center',
                      imageAsset: _mode == WorkspaceMode.cloud
                          ? 'assets/branding/guangya_icon.png'
                          : null,
                      onSwitchMode: () {
                        _changeMode(
                          _mode == WorkspaceMode.cloud
                              ? WorkspaceMode.media
                              : WorkspaceMode.cloud,
                        );
                        setSheetState(() {});
                      },
                      onSettings: () {
                        Navigator.of(sheetContext).pop();
                        _showSettings(context);
                      },
                    ),
                  ),
                  const ShadSeparator.horizontal(),
                  Expanded(
                    child: _mode == WorkspaceMode.cloud
                        ? _CloudSidebar(
                            state: ref.read(fileProvider),
                            width: width,
                            showBrand: false,
                            onModeChanged: _changeMode,
                            onSection: (section) {
                              Navigator.of(sheetContext).pop();
                              ref
                                  .read(fileProvider.notifier)
                                  .setSection(section);
                            },
                            onSettings: () {
                              Navigator.of(sheetContext).pop();
                              _showSettings(context);
                            },
                            onSignOut: () {
                              Navigator.of(sheetContext).pop();
                              ref.read(authProvider.notifier).signOut();
                            },
                            onTool: (tool) {
                              Navigator.of(sheetContext).pop();
                              _openTool(tool);
                            },
                          )
                        : _MediaSidebar(
                            width: width,
                            showBrand: false,
                            onModeChanged: _changeMode,
                            onSettings: () => _showSettings(context),
                            onScanTasks: () {
                              Navigator.of(sheetContext).pop();
                              _showScanTaskManagement(context);
                            },
                            onManage: () {
                              Navigator.of(sheetContext).pop();
                              _showMediaLibraryManagement(context);
                            },
                            onTool: (tool) {
                              Navigator.of(sheetContext).pop();
                              _openTool(tool);
                            },
                            activeTool: _mediaActiveTool,
                            selectedFilter: _mediaBrowseFilter,
                            onFilter: _changeMediaBrowseFilter,
                            homeSelected: _mediaHomeSelected,
                            onHome: _showMediaHome,
                            onSelectLibrary: (libraryID) {
                              Navigator.of(sheetContext).pop();
                              _selectMediaLibrary(libraryID);
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showSettings(BuildContext context) {
    showShadDialog<void>(
      context: context,
      builder: (_) => const SettingsDialog(),
    );
  }

  Widget _buildCloudContent(FileState state) {
    if (_cloudActiveTool != null) {
      return OS26Glass(
        radius: 18,
        opacity: 0.42,
        padding: EdgeInsets.zero,
        child: WorkspaceToolsPage(
          key: const PageStorageKey('cloud-tools'),
          tool: _cloudActiveTool!,
          onClose: _closeActiveTool,
        ),
      );
    }
    if (_fileSearchQuery != null) {
      return OS26Glass(
        radius: 18,
        opacity: 0.42,
        padding: EdgeInsets.zero,
        child: FileSearchResultsPage(
          key: const PageStorageKey('file-search-results'),
          query: _fileSearchQuery!,
          onClose: () => setState(() {
            _fileSearchQuery = null;
            _fileSearchReturnQuery = null;
            _fileSearchResultsCache = null;
            _searchController.clear();
          }),
          onBatchRename: (files) {
            ref.read(fileProvider.notifier).copyToClipboard(files);
            setState(() {
              _fileSearchQuery = null;
              _cloudActiveTool = WorkspaceTool.rename;
            });
          },
          onOpenLocation: (file) async {
            await ref.read(fileProvider.notifier).navigateToSearchResult(file);
            if (!mounted) return;
            setState(() {
              _fileSearchReturnQuery = _fileSearchQuery;
              _fileSearchQuery = null;
              _searchController.clear();
            });
          },
          cachedResults: _fileSearchResultsCache,
          onResultsLoaded: (results) {
            if (!mounted || _fileSearchQuery == null) return;
            setState(
              () => _fileSearchResultsCache = List<CloudFile>.unmodifiable(
                results,
              ),
            );
          },
        ),
      );
    }
    return _CloudWorkspace(
      state: state,
      sidePanelOpen: _isSidePanelOpen,
      onToggleSidePanel: () =>
          setState(() => _isSidePanelOpen = !_isSidePanelOpen),
      onReturnToSearch: _fileSearchReturnQuery == null
          ? null
          : () => setState(() {
              _fileSearchQuery = _fileSearchReturnQuery;
              _fileSearchReturnQuery = null;
              _searchController.text = _fileSearchQuery!;
            }),
    );
  }

  Widget _buildMediaContent() {
    if (_mediaActiveTool != null) {
      return WorkspaceToolsPage(
        key: const PageStorageKey('media-tools'),
        tool: _mediaActiveTool!,
        onClose: _closeActiveTool,
      );
    }
    if (_mediaSearchQuery != null) {
      return MediaSearchResultsPage(
        key: const PageStorageKey('media-search-results'),
        query: _mediaSearchQuery!,
        onClose: () {
          ref.read(activeMediaDetailHeaderProvider.notifier).state = null;
          setState(() {
            _mediaSearchQuery = null;
            _searchController.clear();
          });
        },
      );
    }
    return MediaLibraryPage(
      showLibrarySidebar: false,
      showBrowseHeader: false,
      showHomePanel: _mediaHomeSelected,
      browseFilter: _mediaBrowseFilter,
      librarySection: _mediaLibrarySection,
      onOpenLibrary: _selectMediaLibrary,
    );
  }
}

class _TopBar extends StatelessWidget {
  final WorkspaceMode mode;
  final bool compact;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final bool searchOpen;
  final ValueChanged<String> onSearch;
  final VoidCallback onToggleSearch;
  final VoidCallback onScanShare;
  final VoidCallback? onPasteShare;
  final VoidCallback onOpenMenu;
  final MediaLibraryState mediaState;
  final MediaLibraryBrowseFilter mediaFilter;
  final MediaLibraryBrowseFilter mediaLibrarySection;
  final bool mediaHomeSelected;
  final ValueChanged<MediaLibraryBrowseFilter> onMediaLibrarySectionChanged;
  final ValueChanged<MediaLibrarySort> onMediaSortChanged;
  final ValueChanged<MediaSortDirection> onMediaSortDirectionChanged;
  final bool hideMediaIdentity;
  final UploadProgress? uploadProgress;
  final MediaDetailHeader? mediaDetail;
  final VoidCallback onCloseMediaDetail;

  const _TopBar({
    required this.mode,
    required this.compact,
    required this.searchController,
    required this.searchFocusNode,
    required this.searchOpen,
    required this.onSearch,
    required this.onToggleSearch,
    required this.onScanShare,
    required this.onPasteShare,
    required this.onOpenMenu,
    required this.mediaState,
    required this.mediaFilter,
    required this.mediaLibrarySection,
    required this.mediaHomeSelected,
    required this.onMediaLibrarySectionChanged,
    required this.onMediaSortChanged,
    required this.onMediaSortDirectionChanged,
    required this.hideMediaIdentity,
    required this.uploadProgress,
    required this.mediaDetail,
    required this.onCloseMediaDetail,
  });

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    if (mode == WorkspaceMode.media && hideMediaIdentity) {
      return const SizedBox.shrink();
    }
    if (mode == WorkspaceMode.media && !hideMediaIdentity) {
      return _buildMediaTopBar(context, cs);
    }
    if (compact) {
      return SizedBox(
        height: 46,
        child: searchOpen
            ? OS26Glass(
                radius: 12,
                opacity: 0.58,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    Icon(
                      Icons.search_rounded,
                      size: 18,
                      color: cs.mutedForeground,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: searchController,
                        focusNode: searchFocusNode,
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          isDense: true,
                          hintText: mode == WorkspaceMode.cloud
                              ? '搜索文件'
                              : '搜索影视资源',
                          hintStyle: TextStyle(
                            color: cs.mutedForeground.withValues(alpha: 0.7),
                            fontSize: 13,
                          ),
                        ),
                        textInputAction: TextInputAction.search,
                        onSubmitted: onSearch,
                      ),
                    ),
                    _TopBarIconButton(
                      tooltip: '关闭搜索',
                      icon: Icons.close_rounded,
                      onTap: onToggleSearch,
                    ),
                  ],
                ),
              )
            : Row(
                children: [
                  OS26Glass(
                    radius: 12,
                    opacity: 0.42,
                    padding: const EdgeInsets.all(3),
                    child: _TopBarIconButton(
                      tooltip: '打开菜单',
                      icon: Icons.menu_rounded,
                      onTap: onOpenMenu,
                    ),
                  ),
                  const Spacer(),
                  if (mode == WorkspaceMode.cloud) ...[
                    _TopBarIconButton(
                      tooltip: '粘贴分享链接',
                      icon: Icons.content_paste_rounded,
                      onTap: onPasteShare,
                    ),
                    const SizedBox(width: 6),
                    _TopBarIconButton(
                      tooltip: '扫描分享二维码',
                      icon: Icons.qr_code_scanner_rounded,
                      onTap: onScanShare,
                    ),
                    const SizedBox(width: 6),
                  ],
                  _TopBarIconButton(
                    tooltip: mode == WorkspaceMode.cloud ? '搜索文件' : '搜索影视资源',
                    icon: Icons.search_rounded,
                    onTap: onToggleSearch,
                  ),
                ],
              ),
      );
    }
    return SizedBox(
      height: 42,
      child: Row(
        children: [
          const SizedBox(width: 78),
          const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          if (mode == WorkspaceMode.cloud) ...[
            _TopBarIconButton(
              tooltip: '粘贴分享链接',
              icon: Icons.content_paste_rounded,
              onTap: onPasteShare,
            ),
            const SizedBox(width: 8),
            _TopBarIconButton(
              tooltip: '扫描分享二维码',
              icon: Icons.qr_code_scanner_rounded,
              onTap: onScanShare,
            ),
            const SizedBox(width: 8),
            _UploadListTopButton(progress: uploadProgress),
            const SizedBox(width: 8),
          ],
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: searchOpen ? 280 : 42,
            height: 42,
            child: searchOpen
                ? OS26Glass(
                    radius: 21,
                    opacity: 0.52,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.search_rounded,
                          size: 18,
                          color: cs.foreground,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: searchController,
                            focusNode: searchFocusNode,
                            decoration: InputDecoration(
                              border: InputBorder.none,
                              isDense: true,
                              hintText: mode == WorkspaceMode.cloud
                                  ? '搜索文件'
                                  : '搜索影视资源',
                              hintStyle: TextStyle(
                                color: cs.foreground.withValues(alpha: 0.4),
                                fontSize: 13,
                              ),
                            ),
                            textInputAction: TextInputAction.search,
                            onSubmitted: onSearch,
                          ),
                        ),
                        InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: onToggleSearch,
                          child: Icon(
                            Icons.close_rounded,
                            size: 18,
                            color: cs.mutedForeground,
                          ),
                        ),
                      ],
                    ),
                  )
                : _TopBarIconButton(
                    tooltip: mode == WorkspaceMode.cloud ? '搜索文件' : '搜索影视资源',
                    icon: Icons.search_rounded,
                    onTap: onToggleSearch,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildMediaTopBar(BuildContext context, ShadColorScheme cs) {
    final detail = mediaDetail;
    if (detail != null) {
      return _MediaDetailTopBar(
        compact: compact,
        detail: detail,
        onBack: onCloseMediaDetail,
      );
    }
    final showLibraryScan =
        !mediaHomeSelected && mediaFilter == MediaLibraryBrowseFilter.all;
    final showLibrarySections =
        showLibraryScan && !searchOpen && mediaState.statistics.total > 0;
    final identity = compact && showLibrarySections
        ? _MediaLibrarySectionPopover(
            state: mediaState,
            compact: compact,
            filter: mediaFilter,
            homeSelected: mediaHomeSelected,
            statistics: mediaState.statistics,
            selected: mediaLibrarySection,
            onSelected: onMediaLibrarySectionChanged,
          )
        : _MediaLibraryTopIdentity(
            state: mediaState,
            compact: compact,
            filter: mediaFilter,
            homeSelected: mediaHomeSelected,
          );
    final searchField = Container(
      height: compact ? 42 : 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: cs.background.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.border),
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 18, color: cs.mutedForeground),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: searchController,
              focusNode: searchFocusNode,
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                hintText: '搜索影视资源',
                hintStyle: TextStyle(
                  color: cs.mutedForeground.withValues(alpha: 0.7),
                  fontSize: 13,
                ),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: onSearch,
            ),
          ),
          _TopBarIconButton(
            tooltip: '关闭搜索',
            icon: Icons.close_rounded,
            onTap: onToggleSearch,
          ),
        ],
      ),
    );
    if (compact) {
      return SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 5, 10, 0),
          child: Row(
            children: [
              _TopBarIconButton(
                tooltip: '打开菜单',
                icon: Icons.menu_rounded,
                onTap: onOpenMenu,
              ),
              const SizedBox(width: 6),
              if (showLibraryScan) ...[
                _MediaLibraryScanTopAction(compact: true, state: mediaState),
                const SizedBox(width: 4),
              ],
              Expanded(child: searchOpen ? searchField : identity),
              if (!searchOpen) ...[
                const SizedBox(width: 4),
                if (!mediaHomeSelected) ...[
                  _MediaSortTopAction(
                    selected: mediaState.sort,
                    direction: mediaState.sortDirection,
                    onSelected: onMediaSortChanged,
                    onDirectionSelected: onMediaSortDirectionChanged,
                  ),
                  const SizedBox(width: 4),
                ],
                _TopBarIconButton(
                  tooltip: '搜索影视资源',
                  icon: Icons.search_rounded,
                  onTap: onToggleSearch,
                ),
              ],
            ],
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 640;
        final compactActions = constraints.maxWidth < 1360;
        return SizedBox(
          height: 52,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(flex: narrow ? 2 : 3, child: identity),
                if (showLibrarySections) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    flex: narrow ? 3 : 4,
                    child: _MediaLibrarySectionSelector(
                      statistics: mediaState.statistics,
                      selected: mediaLibrarySection,
                      onSelected: onMediaLibrarySectionChanged,
                    ),
                  ),
                ],
                if (showLibraryScan) ...[
                  const SizedBox(width: 8),
                  _MediaLibraryScanTopAction(
                    compact: compactActions,
                    state: mediaState,
                  ),
                ],
                const SizedBox(width: 8),
                if (!mediaHomeSelected) ...[
                  _MediaSortTopAction(
                    selected: mediaState.sort,
                    direction: mediaState.sortDirection,
                    onSelected: onMediaSortChanged,
                    onDirectionSelected: onMediaSortDirectionChanged,
                  ),
                  const SizedBox(width: 4),
                ],
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: searchOpen ? (narrow ? 220 : 360) : 40,
                  height: 38,
                  child: searchOpen
                      ? searchField
                      : _TopBarIconButton(
                          tooltip: '搜索影视资源',
                          icon: Icons.search_rounded,
                          onTap: onToggleSearch,
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MediaDetailTopBar extends StatelessWidget {
  final bool compact;
  final MediaDetailHeader detail;
  final VoidCallback onBack;

  const _MediaDetailTopBar({
    required this.compact,
    required this.detail,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final type = detail.mediaKind == TMDBMediaKind.tv ? '剧集' : '电影';
    return SizedBox(
      height: compact ? 48 : 52,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          compact ? 10 : 14,
          compact ? 5 : 16,
          compact ? 10 : 14,
          compact ? 3 : 0,
        ),
        child: Center(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ShadTooltip(
                builder: (_) => const Text('返回影视库'),
                child: _TopBarIconButton(
                  tooltip: '返回影视库',
                  icon: Icons.arrow_back_rounded,
                  onTap: onBack,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                detail.mediaKind == TMDBMediaKind.tv
                    ? Icons.tv_rounded
                    : Icons.movie_rounded,
                size: compact ? 19 : 20,
                color: cs.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  detail.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: compact ? 15 : 16,
                    fontWeight: FontWeight.w700,
                    color: cs.foreground,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ShadBadge(child: Text(type)),
              if (detail.year.isNotEmpty) ...[
                const SizedBox(width: 6),
                ShadBadge.outline(child: Text(detail.year)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _mediaLibraryStatisticsLabel(MediaLibraryStatistics statistics) {
  final parts = <String>[
    if (statistics.movies > 0) '${statistics.movies} 部电影',
    if (statistics.series > 0) '${statistics.series} 部剧集',
    if (statistics.unmatched > 0) '${statistics.unmatched} 个未识别资源',
    if (statistics.total > 0) '${statistics.total} 个影视条目',
  ];
  return parts.isEmpty ? '暂无影视条目' : parts.join(' · ');
}

class _MediaLibraryTopIdentity extends StatelessWidget {
  final MediaLibraryState state;
  final bool compact;
  final MediaLibraryBrowseFilter filter;
  final bool homeSelected;
  final VoidCallback? onTap;
  final String? tapHint;

  const _MediaLibraryTopIdentity({
    required this.state,
    required this.compact,
    required this.filter,
    required this.homeSelected,
    this.onTap,
    this.tapHint,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final library = state.selectedLibrary;
    final statistics = homeSelected || filter != MediaLibraryBrowseFilter.all
        ? state.globalStatistics
        : state.statistics;
    final title = homeSelected
        ? '首页'
        : switch (filter) {
            MediaLibraryBrowseFilter.movies => '电影',
            MediaLibraryBrowseFilter.series => '电视剧',
            MediaLibraryBrowseFilter.unmatched => '未识别',
            MediaLibraryBrowseFilter.collections => '合集',
            MediaLibraryBrowseFilter.all => library?.name ?? '未选择媒体库',
          };
    final subtitle = homeSelected
        ? _mediaLibraryStatisticsLabel(statistics)
        : switch (filter) {
            MediaLibraryBrowseFilter.movies => '${statistics.movies} 部电影',
            MediaLibraryBrowseFilter.series => '${statistics.series} 部剧集',
            MediaLibraryBrowseFilter.unmatched =>
              '${statistics.unmatched} 个未识别资源',
            MediaLibraryBrowseFilter.collections => '自动整理的媒体合集',
            MediaLibraryBrowseFilter.all => _mediaLibraryStatisticsLabel(
              statistics,
            ),
          };
    return Semantics(
      button: onTap != null,
      label: tapHint == null ? '$title，$subtitle' : '$title，$tapHint',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            child: Row(
              children: [
                Icon(
                  Icons.video_library_rounded,
                  size: compact ? 20 : 19,
                  color: cs.primary,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: compact ? 15 : 14,
                          height: 1.05,
                          fontWeight: FontWeight.w700,
                          color: cs.foreground,
                        ),
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onTap != null)
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: cs.mutedForeground,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaLibrarySectionPopover extends StatefulWidget {
  final MediaLibraryState state;
  final bool compact;
  final MediaLibraryBrowseFilter filter;
  final bool homeSelected;
  final MediaLibraryStatistics statistics;
  final MediaLibraryBrowseFilter selected;
  final ValueChanged<MediaLibraryBrowseFilter> onSelected;

  const _MediaLibrarySectionPopover({
    required this.state,
    required this.compact,
    required this.filter,
    required this.homeSelected,
    required this.statistics,
    required this.selected,
    required this.onSelected,
  });

  @override
  State<_MediaLibrarySectionPopover> createState() =>
      _MediaLibrarySectionPopoverState();
}

class _MediaLibrarySectionPopoverState
    extends State<_MediaLibrarySectionPopover> {
  final _controller = ShadPopoverController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = _MediaLibraryTopIdentity(
      state: widget.state,
      compact: widget.compact,
      filter: widget.filter,
      homeSelected: widget.homeSelected,
      onTap: _controller.toggle,
      tapHint: '点击选择资源分类',
    );
    final cs = ShadTheme.of(context).colorScheme;
    return ShadPopover(
      controller: _controller,
      popover: (_) => SizedBox(
        width: (MediaQuery.sizeOf(context).width - 24)
            .clamp(300.0, 520.0)
            .toDouble(),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 3, 8, 7),
                child: Text(
                  '资源分类',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: cs.mutedForeground,
                  ),
                ),
              ),
              _MediaLibrarySectionSelector(
                statistics: widget.statistics,
                selected: widget.selected,
                onSelected: (filter) {
                  _controller.hide();
                  widget.onSelected(filter);
                },
              ),
            ],
          ),
        ),
      ),
      child: child,
    );
  }
}

class _MediaLibrarySectionSelector extends StatelessWidget {
  final MediaLibraryStatistics statistics;
  final MediaLibraryBrowseFilter selected;
  final ValueChanged<MediaLibraryBrowseFilter> onSelected;

  const _MediaLibrarySectionSelector({
    required this.statistics,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final sections = [
      (
        filter: MediaLibraryBrowseFilter.all,
        icon: Icons.video_library_rounded,
        label: '全部',
        count: statistics.total,
      ),
      (
        filter: MediaLibraryBrowseFilter.movies,
        icon: Icons.movie_rounded,
        label: '电影',
        count: statistics.movies,
      ),
      (
        filter: MediaLibraryBrowseFilter.series,
        icon: Icons.live_tv_rounded,
        label: '剧集',
        count: statistics.series,
      ),
      (
        filter: MediaLibraryBrowseFilter.unmatched,
        icon: Icons.help_outline_rounded,
        label: '未识别',
        count: statistics.unmatched,
      ),
    ].where((section) => section.count > 0).toList(growable: false);
    if (sections.isEmpty) return const SizedBox.shrink();

    return ClipRect(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Container(
          height: 36,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: cs.muted.withValues(alpha: 0.42),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: cs.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < sections.length; index++) ...[
                if (index > 0) const SizedBox(width: 2),
                selected == sections[index].filter
                    ? ShadButton(
                        size: ShadButtonSize.sm,
                        onPressed: () => onSelected(sections[index].filter),
                        leading: Icon(sections[index].icon, size: 15),
                        child: Text(
                          '${sections[index].label} ${sections[index].count}',
                        ),
                      )
                    : ShadButton.ghost(
                        size: ShadButtonSize.sm,
                        onPressed: () => onSelected(sections[index].filter),
                        leading: Icon(sections[index].icon, size: 15),
                        child: Text(
                          '${sections[index].label} ${sections[index].count}',
                        ),
                      ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBarIconButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;
  final Color? color;

  const _TopBarIconButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ShadTooltip(
      builder: (_) => Text(tooltip),
      child: ShadButton.ghost(
        width: 38,
        height: 38,
        padding: EdgeInsets.zero,
        onPressed: onTap,
        child: Icon(icon, size: 18, color: color ?? cs.mutedForeground),
      ),
    );
  }
}

class _MediaSortTopAction extends StatefulWidget {
  final MediaLibrarySort selected;
  final MediaSortDirection direction;
  final ValueChanged<MediaLibrarySort> onSelected;
  final ValueChanged<MediaSortDirection> onDirectionSelected;

  const _MediaSortTopAction({
    required this.selected,
    required this.direction,
    required this.onSelected,
    required this.onDirectionSelected,
  });

  @override
  State<_MediaSortTopAction> createState() => _MediaSortTopActionState();
}

class _MediaSortTopActionState extends State<_MediaSortTopAction> {
  final _controller = ShadPopoverController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ShadPopover(
      controller: _controller,
      popover: (_) => SizedBox(
        width: 148,
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final value in MediaLibrarySort.values)
                SizedBox(
                  width: double.infinity,
                  child: ShadButton.ghost(
                    onPressed: () {
                      _controller.hide();
                      widget.onSelected(value);
                    },
                    leading: Icon(
                      value == widget.selected
                          ? Icons.check_rounded
                          : Icons.sort_rounded,
                      size: 16,
                      color: value == widget.selected
                          ? cs.primary
                          : cs.mutedForeground,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(value.title),
                    ),
                  ),
                ),
              const Divider(height: 12),
              for (final direction in MediaSortDirection.values)
                SizedBox(
                  width: double.infinity,
                  child: ShadButton.ghost(
                    onPressed: () {
                      _controller.hide();
                      widget.onDirectionSelected(direction);
                    },
                    leading: Icon(
                      direction == MediaSortDirection.ascending
                          ? Icons.arrow_upward_rounded
                          : Icons.arrow_downward_rounded,
                      size: 16,
                      color: direction == widget.direction
                          ? cs.primary
                          : cs.mutedForeground,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(direction.title),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      child: _TopBarIconButton(
        tooltip: '排序：${widget.selected.title} · ${widget.direction.title}',
        icon: Icons.swap_vert_rounded,
        onTap: _controller.toggle,
      ),
    );
  }
}

class _MediaLibraryScanTopAction extends ConsumerStatefulWidget {
  final bool compact;
  final MediaLibraryState state;

  const _MediaLibraryScanTopAction({
    required this.compact,
    required this.state,
  });

  @override
  ConsumerState<_MediaLibraryScanTopAction> createState() =>
      _MediaLibraryScanTopActionState();
}

class _MediaLibraryScanTopActionState
    extends ConsumerState<_MediaLibraryScanTopAction> {
  final _controller = ShadPopoverController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.state.isScanning) {
      if (widget.compact) {
        return ShadTooltip(
          builder: (_) => const Text('停止扫描'),
          child: ShadButton.destructive(
            width: 38,
            height: 36,
            padding: EdgeInsets.zero,
            onPressed: () =>
                ref.read(mediaLibraryProvider.notifier).cancelScan(),
            child: const Icon(Icons.stop_rounded, size: 18),
          ),
        );
      }
      return ShadButton.destructive(
        width: 124,
        size: ShadButtonSize.sm,
        onPressed: () => ref.read(mediaLibraryProvider.notifier).cancelScan(),
        leading: const Icon(Icons.stop_rounded, size: 16),
        child: const Text('停止扫描'),
      );
    }
    return MediaScanMenu(
      compact: widget.compact,
      iconOnly: widget.compact,
      disabled: widget.state.selectedLibrary == null,
      controller: _controller,
      onScanUnrecognized: () => ref
          .read(mediaLibraryProvider.notifier)
          .rescanSelectedLibrary(mode: MediaLibraryScanMode.unrecognizedOnly),
      onForceAll: () => ref
          .read(mediaLibraryProvider.notifier)
          .rescanSelectedLibrary(mode: MediaLibraryScanMode.forceAll),
    );
  }
}

class _UploadListTopButton extends StatefulWidget {
  final UploadProgress? progress;

  const _UploadListTopButton({required this.progress});

  @override
  State<_UploadListTopButton> createState() => _UploadListTopButtonState();
}

class _UploadListTopButtonState extends State<_UploadListTopButton> {
  final _controller = ShadPopoverController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ShadPopover(
    controller: _controller,
    popover: (_) => _UploadProgressPopover(progress: widget.progress),
    child: _TopBarIconButton(
      tooltip: '上传列表',
      icon: Icons.upload_file_rounded,
      onTap: _controller.toggle,
    ),
  );
}

class _MobileDrawerSwipeArea extends StatefulWidget {
  final Widget child;
  final VoidCallback onOpen;

  const _MobileDrawerSwipeArea({required this.child, required this.onOpen});

  @override
  State<_MobileDrawerSwipeArea> createState() => _MobileDrawerSwipeAreaState();
}

class _MobileDrawerSwipeAreaState extends State<_MobileDrawerSwipeArea> {
  var _distance = 0.0;
  var _opening = false;

  void _onDragUpdate(DragUpdateDetails details) {
    if (_opening) return;
    final delta = details.primaryDelta ?? 0;
    if (delta <= 0) {
      _distance = 0;
      return;
    }
    _distance += delta;
    if (_distance >= 28) {
      _opening = true;
      _distance = 0;
      widget.onOpen();
      Future<void>.delayed(const Duration(milliseconds: 300), () {
        if (mounted) _opening = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      widget.child,
      Positioned(
        left: 0,
        top: 0,
        bottom: 0,
        width: 28,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: _onDragUpdate,
          onHorizontalDragEnd: (_) => _distance = 0,
          onHorizontalDragCancel: () => _distance = 0,
        ),
      ),
    ],
  );
}

// ignore: unused_element
class _MobileWorkspaceMenu extends StatelessWidget {
  final WorkspaceMode mode;
  final String userName;
  final String memberLevel;
  final String capacityText;
  final ValueChanged<WorkspaceSection> onSection;
  final ValueChanged<WorkspaceTool> onTool;
  final VoidCallback onManageLibrary;
  final VoidCallback onSettings;
  final VoidCallback onSearch;
  final VoidCallback onSignOut;

  const _MobileWorkspaceMenu({
    required this.mode,
    required this.userName,
    required this.memberLevel,
    required this.capacityText,
    required this.onSection,
    required this.onTool,
    required this.onManageLibrary,
    required this.onSettings,
    required this.onSearch,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final isCloud = mode == WorkspaceMode.cloud;
    final width = (MediaQuery.sizeOf(context).width * 0.86)
        .clamp(280.0, 340.0)
        .toDouble();
    return ShadSheet(
      constraints: BoxConstraints.tightFor(width: width),
      title: const Text('小黄鸭'),
      description: Text('$userName · $memberLevel'),
      scrollable: false,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.muted,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: cs.border),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 21,
                  backgroundColor: cs.primary,
                  child: Text(
                    userName.isEmpty
                        ? '小'
                        : userName.substring(0, 1).toUpperCase(),
                    style: TextStyle(
                      color: cs.primaryForeground,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        userName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: cs.foreground,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        capacityText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _MobileMenuGroup(
            title: '常用入口',
            children: [
              _MobileMenuRow(
                icon: Icons.search_rounded,
                label: '全局搜索',
                onTap: onSearch,
              ),
              _MobileMenuRow(
                icon: Icons.folder_rounded,
                label: '文件管理',
                onTap: () => onSection(WorkspaceSection.files),
              ),
              _MobileMenuRow(
                icon: Icons.movie_rounded,
                label: '光鸭影视',
                onTap: () => onSection(WorkspaceSection.mediaLibrary),
              ),
            ],
          ),
          if (isCloud)
            _MobileMenuGroup(
              title: '文件内容',
              children: [
                for (final section in [
                  WorkspaceSection.recentViewed,
                  WorkspaceSection.photos,
                  WorkspaceSection.videos,
                  WorkspaceSection.audio,
                  WorkspaceSection.documents,
                  WorkspaceSection.shares,
                  WorkspaceSection.recycle,
                ])
                  _MobileMenuRow(
                    icon: _mobileSectionIcon(section),
                    label: section.label,
                    onTap: () => onSection(section),
                  ),
              ],
            ),
          _MobileMenuGroup(
            title: isCloud ? '文件工具' : '影视工具',
            children: [
              _MobileMenuRow(
                icon: isCloud
                    ? Icons.manage_search_rounded
                    : Icons.movie_filter_rounded,
                label: isCloud ? '文件扫描与清理' : '媒体库管理',
                onTap: isCloud
                    ? () => onTool(WorkspaceTool.scan)
                    : onManageLibrary,
              ),
              if (isCloud) ...[
                _MobileMenuRow(
                  icon: Icons.text_fields_rounded,
                  label: '批量重命名',
                  onTap: () => onTool(WorkspaceTool.rename),
                ),
                _MobileMenuRow(
                  icon: Icons.bolt_rounded,
                  label: '秒传工具',
                  onTap: () => onTool(WorkspaceTool.fastTransfer),
                ),
              ],
            ],
          ),
          _MobileMenuGroup(
            title: '系统维护',
            children: [
              _MobileMenuRow(
                icon: Icons.settings_rounded,
                label: '设置中心',
                onTap: onSettings,
              ),
            ],
          ),
          const ShadSeparator.horizontal(),
          _MobileMenuRow(
            icon: Icons.logout_rounded,
            label: '退出登录',
            destructive: true,
            onTap: onSignOut,
          ),
        ],
      ),
    );
  }

  IconData _mobileSectionIcon(WorkspaceSection section) => switch (section) {
    WorkspaceSection.files => Icons.folder_rounded,
    WorkspaceSection.recentViewed => Icons.access_time_rounded,
    WorkspaceSection.recentRestored => Icons.history_rounded,
    WorkspaceSection.photos => Icons.image_rounded,
    WorkspaceSection.videos => Icons.smart_display_rounded,
    WorkspaceSection.audio => Icons.music_note_rounded,
    WorkspaceSection.documents => Icons.description_rounded,
    WorkspaceSection.cloud => Icons.cloud_download_rounded,
    WorkspaceSection.shares => Icons.ios_share_rounded,
    WorkspaceSection.recycle => Icons.delete_outline_rounded,
    WorkspaceSection.mediaLibrary => Icons.movie_filter_rounded,
  };
}

class _MobileMenuGroup extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _MobileMenuGroup({required this.title, required this.children});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: ShadTheme.of(context).colorScheme.mutedForeground,
            ),
          ),
        ),
        ...children,
      ],
    ),
  );
}

class _MobileMenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  const _MobileMenuRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final color = destructive ? cs.destructive : cs.foreground;
    return ShadButton.ghost(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      mainAxisAlignment: MainAxisAlignment.start,
      foregroundColor: color,
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      leading: Icon(
        icon,
        size: 20,
        color: destructive ? cs.destructive : cs.mutedForeground,
      ),
      onPressed: onTap,
      child: Text(label),
    );
  }
}

class _CloudSidebar extends StatelessWidget {
  final FileState state;
  final double width;
  final bool showBrand;
  final ValueChanged<WorkspaceMode> onModeChanged;
  final ValueChanged<WorkspaceSection> onSection;
  final VoidCallback onSettings;
  final VoidCallback onSignOut;
  final ValueChanged<WorkspaceTool> onTool;
  final WorkspaceTool? activeTool;

  const _CloudSidebar({
    required this.state,
    this.width = 250,
    this.showBrand = true,
    required this.onModeChanged,
    required this.onSection,
    required this.onSettings,
    required this.onSignOut,
    required this.onTool,
    this.activeTool,
  });

  @override
  Widget build(BuildContext context) {
    final sections = WorkspaceSection.values
        .where((section) => section != WorkspaceSection.mediaLibrary)
        .toList();
    return SizedBox(
      width: width,
      child: OS26Glass(
        radius: showBrand ? 24 : 0,
        opacity: showBrand ? 0.56 : 0,
        border: showBrand ? null : const Border(),
        applyBlur: showBrand,
        padding: EdgeInsets.fromLTRB(14, showBrand ? 14 : 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showBrand) ...[
              if (!Platform.isMacOS)
                const Padding(
                  padding: EdgeInsets.only(left: 2, bottom: 8),
                  child: WindowControls(),
                ),
              if (_isDesktopWindow)
                SizedBox(height: _sidebarWindowControlInset),
              _SidebarBrand(
                icon: Icons.cloud_sync_rounded,
                title: '光鸭云盘',
                subtitle: 'Cloud Workspace',
                imageAsset: 'assets/branding/guangya_icon.png',
                onSwitchMode: () => onModeChanged(WorkspaceMode.media),
                onSettings: onSettings,
              ),
              const SizedBox(height: 14),
            ],
            Expanded(
              child: ListView(
                children: [
                  for (final section in sections)
                    _SidebarTile(
                      icon: _sectionIcon(section),
                      label: section.label,
                      selected: state.section == section,
                      onTap: () => onSection(section),
                    ),
                  const Divider(height: 24),
                  _SidebarTile(
                    icon: Icons.manage_search_rounded,
                    label: '文件扫描与清理',
                    selected: activeTool == WorkspaceTool.scan,
                    onTap: () => onTool(WorkspaceTool.scan),
                  ),
                  _SidebarTile(
                    icon: Icons.text_fields_rounded,
                    label: '批量重命名',
                    selected: activeTool == WorkspaceTool.rename,
                    onTap: () => onTool(WorkspaceTool.rename),
                  ),
                  _SidebarTile(
                    icon: Icons.bolt_rounded,
                    label: '秒传工具',
                    selected: activeTool == WorkspaceTool.fastTransfer,
                    onTap: () => onTool(WorkspaceTool.fastTransfer),
                  ),
                ],
              ),
            ),
            _SidebarTile(
              icon: Icons.logout_rounded,
              label: '退出登录',
              selected: false,
              onTap: onSignOut,
            ),
          ],
        ),
      ),
    );
  }

  IconData _sectionIcon(WorkspaceSection s) {
    switch (s) {
      case WorkspaceSection.files:
        return Icons.folder_rounded;
      case WorkspaceSection.recentViewed:
        return Icons.access_time_rounded;
      case WorkspaceSection.recentRestored:
        return Icons.history_rounded;
      case WorkspaceSection.photos:
        return Icons.image_rounded;
      case WorkspaceSection.videos:
        return Icons.smart_display_rounded;
      case WorkspaceSection.audio:
        return Icons.music_note_rounded;
      case WorkspaceSection.documents:
        return Icons.description_rounded;
      case WorkspaceSection.cloud:
        return Icons.cloud_download_rounded;
      case WorkspaceSection.shares:
        return Icons.ios_share_rounded;
      case WorkspaceSection.recycle:
        return Icons.delete_outline_rounded;
      case WorkspaceSection.mediaLibrary:
        return Icons.movie_filter_rounded;
    }
  }
}

class _MediaSidebar extends ConsumerWidget {
  final double width;
  final bool showBrand;
  final ValueChanged<WorkspaceMode> onModeChanged;
  final VoidCallback onSettings;
  final VoidCallback onScanTasks;
  final VoidCallback onManage;
  final ValueChanged<WorkspaceTool> onTool;
  final WorkspaceTool? activeTool;
  final MediaLibraryBrowseFilter selectedFilter;
  final ValueChanged<MediaLibraryBrowseFilter> onFilter;
  final bool homeSelected;
  final VoidCallback onHome;
  final ValueChanged<String> onSelectLibrary;

  const _MediaSidebar({
    this.width = 250,
    this.showBrand = true,
    required this.onModeChanged,
    required this.onSettings,
    required this.onScanTasks,
    required this.onManage,
    required this.onTool,
    required this.activeTool,
    required this.selectedFilter,
    required this.onFilter,
    required this.homeSelected,
    required this.onHome,
    required this.onSelectLibrary,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(mediaLibraryProvider);
    return SizedBox(
      width: width,
      child: OS26Glass(
        radius: showBrand ? 24 : 0,
        opacity: showBrand ? 0.56 : 0,
        border: showBrand ? null : const Border(),
        applyBlur: showBrand,
        padding: EdgeInsets.fromLTRB(12, showBrand ? 14 : 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showBrand) ...[
              if (!Platform.isMacOS)
                const Padding(
                  padding: EdgeInsets.only(left: 2, bottom: 8),
                  child: WindowControls(),
                ),
              if (_isDesktopWindow)
                SizedBox(height: _sidebarWindowControlInset),
              _SidebarBrand(
                icon: Icons.play_circle_fill_rounded,
                title: '光鸭影视',
                subtitle: 'Media Center',
                onSwitchMode: () => onModeChanged(WorkspaceMode.cloud),
                onSettings: onSettings,
              ),
              const SizedBox(height: 16),
            ],
            const _SidebarSectionLabel('浏览'),
            _SidebarTile(
              icon: Icons.home_rounded,
              label: '首页',
              selected: homeSelected,
              onTap: onHome,
            ),
            _SidebarTile(
              icon: Icons.movie_creation_rounded,
              label: '电影',
              count: state.globalStatistics.movies,
              selected: selectedFilter == MediaLibraryBrowseFilter.movies,
              onTap: () => onFilter(MediaLibraryBrowseFilter.movies),
            ),
            _SidebarTile(
              icon: Icons.live_tv_rounded,
              label: '电视剧',
              count: state.globalStatistics.series,
              selected: selectedFilter == MediaLibraryBrowseFilter.series,
              onTap: () => onFilter(MediaLibraryBrowseFilter.series),
            ),
            _SidebarTile(
              icon: Icons.help_outline_rounded,
              label: '未识别',
              count: state.globalStatistics.unmatched,
              selected: selectedFilter == MediaLibraryBrowseFilter.unmatched,
              onTap: () => onFilter(MediaLibraryBrowseFilter.unmatched),
            ),
            const SizedBox(height: 8),
            const _SidebarSectionLabel('媒体库'),
            Expanded(
              child: ListView(
                children: [
                  for (final library in state.libraries)
                    Builder(
                      builder: (context) {
                        final statistics =
                            state.libraryStatistics[library.id] ??
                            const MediaLibraryStatistics();
                        return _SidebarTile(
                          icon: library.kind == MediaLibraryKind.series
                              ? Icons.live_tv_rounded
                              : Icons.smart_display_rounded,
                          label: library.name,
                          subtitle: _mediaLibraryStatisticsLabel(statistics),
                          selected:
                              !homeSelected &&
                              selectedFilter == MediaLibraryBrowseFilter.all &&
                              state.selectedLibrary?.id == library.id,
                          onTap: () => onSelectLibrary(library.id),
                        );
                      },
                    ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 8, bottom: 10),
              child: ShadSeparator.horizontal(),
            ),
            const _SidebarSectionLabel('管理'),
            _SidebarTile(
              icon: Icons.assignment_rounded,
              label: '刮削管理',
              count: state.activeScanCount,
              selected: false,
              onTap: onScanTasks,
            ),
            _SidebarTile(
              icon: Icons.drive_file_move_rounded,
              label: '文件整理',
              selected: activeTool == WorkspaceTool.organize,
              onTap: () => onTool(WorkspaceTool.organize),
            ),
            _SidebarTile(
              icon: Icons.category_rounded,
              label: '分类管理',
              selected: activeTool == WorkspaceTool.categories,
              onTap: () => onTool(WorkspaceTool.categories),
            ),
            _SidebarTile(
              icon: Icons.video_library_rounded,
              label: '媒体库管理',
              selected: false,
              onTap: onManage,
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarSectionLabel extends StatelessWidget {
  final String label;

  const _SidebarSectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 7),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: cs.mutedForeground,
        ),
      ),
    );
  }
}

class _SidebarBrand extends ConsumerWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? imageAsset;
  final VoidCallback? onSwitchMode;
  final VoidCallback? onSettings;

  const _SidebarBrand({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.imageAsset,
    this.onSwitchMode,
    this.onSettings,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = ShadTheme.of(context).colorScheme;
    final hasAppUpgrade =
        ref.watch(appUpgradeStatusProvider).value?.hasNewVersion == true;
    final brand = Row(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: cs.primary.withValues(alpha: 0.24),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: imageAsset == null
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    color: cs.primary,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: Colors.white, size: 26),
                )
              : ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.asset(
                    imageAsset!,
                    filterQuality: FilterQuality.high,
                  ),
                ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: cs.foreground,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                  color: cs.mutedForeground,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    return Row(
      children: [
        Expanded(
          child: Semantics(
            button: onSwitchMode != null,
            label: onSwitchMode == null ? title : '$title，点击切换工作区',
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onSwitchMode,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: brand,
                ),
              ),
            ),
          ),
        ),
        if (onSettings != null) ...[
          if (hasAppUpgrade)
            _TopBarIconButton(
              tooltip: '发现新版本',
              icon: Icons.upgrade_rounded,
              color: cs.primary,
              onTap: () => showAppUpgradeDialog(context),
            ),
          _TopBarIconButton(
            tooltip: '设置',
            icon: Icons.settings_rounded,
            onTap: onSettings!,
          ),
        ],
      ],
    );
  }
}

class _SidebarTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  const _SidebarTile({
    required this.icon,
    required this.label,
    this.subtitle,
    this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final visibleCount = count != null && count! > 0;
    final semanticsLabel = [
      label,
      ?subtitle,
      if (visibleCount) '$count',
    ].join('，');
    return Semantics(
      button: true,
      selected: selected,
      label: semanticsLabel,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(7),
            overlayColor: WidgetStatePropertyAll(
              cs.foreground.withValues(alpha: 0.05),
            ),
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: subtitle == null ? 40 : 52,
              padding: const EdgeInsets.symmetric(horizontal: 9),
              decoration: BoxDecoration(
                color: selected
                    ? cs.primary.withValues(alpha: 0.12)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Row(
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: selected
                          ? cs.primary.withValues(alpha: 0.16)
                          : cs.muted.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(
                      icon,
                      size: 16,
                      color: selected ? cs.primary : cs.mutedForeground,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w600,
                            color: cs.foreground,
                          ),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: cs.mutedForeground,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (visibleCount)
                    Container(
                      constraints: const BoxConstraints(minWidth: 20),
                      height: 20,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected
                            ? cs.primary.withValues(alpha: 0.16)
                            : cs.muted,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$count',
                        style: TextStyle(
                          fontSize: 10,
                          height: 1,
                          fontWeight: FontWeight.w700,
                          color: selected ? cs.primary : cs.mutedForeground,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CloudWorkspace extends ConsumerStatefulWidget {
  final FileState state;
  final bool sidePanelOpen;
  final VoidCallback onToggleSidePanel;
  final VoidCallback? onReturnToSearch;

  const _CloudWorkspace({
    required this.state,
    required this.sidePanelOpen,
    required this.onToggleSidePanel,
    this.onReturnToSearch,
  });

  @override
  ConsumerState<_CloudWorkspace> createState() => _CloudWorkspaceState();
}

class _CloudWorkspaceState extends ConsumerState<_CloudWorkspace> {
  _PaneLayoutMode _paneMode = _PaneLayoutMode.single;
  _FileViewMode _primaryViewMode = _FileViewMode.list;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        final paneMode = compact ? _PaneLayoutMode.single : _paneMode;
        final enableCloudDrag =
            !compact &&
            !_isMobilePlatform &&
            state.section == WorkspaceSection.files &&
            (_primaryViewMode == _FileViewMode.columns ||
                paneMode == _PaneLayoutMode.dual);
        final workspace = OS26Glass(
          radius: compact ? 8 : 18,
          opacity: 0.42,
          padding: EdgeInsets.all(compact ? 8 : 14),
          child: Column(
            children: [
              _CloudToolbar(
                state: state,
                compact: compact,
                paneMode: paneMode,
                onPaneModeChanged: (mode) => setState(() => _paneMode = mode),
                viewMode: _primaryViewMode,
                onViewModeChanged: (mode) =>
                    setState(() => _primaryViewMode = mode),
                sidePanelOpen: widget.sidePanelOpen,
                onToggleSidePanel: compact
                    ? () => _showMobileDetails(context)
                    : widget.onToggleSidePanel,
                onReturnToSearch: widget.onReturnToSearch,
              ),
              SizedBox(height: compact ? 8 : 12),
              Expanded(
                child: state.section == WorkspaceSection.files
                    ? paneMode == _PaneLayoutMode.dual
                          ? Row(
                              children: [
                                Expanded(
                                  child: _PrimaryFilePane(
                                    title: '左侧面板',
                                    state: state,
                                    viewMode: _primaryViewMode,
                                    enableCloudDrag: enableCloudDrag,
                                    onViewModeChanged: (mode) =>
                                        setState(() => _primaryViewMode = mode),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                const Expanded(child: _SecondaryFilePane()),
                              ],
                            )
                          : _PrimaryFilePane(
                              title: compact ? '文件' : '文件列表',
                              state: state,
                              viewMode: _primaryViewMode,
                              enableCloudDrag: enableCloudDrag,
                              onViewModeChanged: (mode) =>
                                  setState(() => _primaryViewMode = mode),
                            )
                    : _PrimaryFilePane(
                        title: state.section.label,
                        state: state,
                        viewMode: _primaryViewMode,
                        enableCloudDrag: enableCloudDrag,
                        onViewModeChanged: (mode) =>
                            setState(() => _primaryViewMode = mode),
                      ),
              ),
            ],
          ),
        );
        if (compact) return workspace;
        return Row(
          children: [
            Expanded(child: workspace),
            if (widget.sidePanelOpen) ...[
              const SizedBox(width: 12),
              SizedBox(
                width: 280,
                child: OS26Glass(
                  radius: 18,
                  opacity: 0.48,
                  padding: EdgeInsets.zero,
                  child: const SidePanel(),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  void _showMobileDetails(BuildContext context) {
    showShadSheet(
      context: context,
      side: ShadSheetSide.bottom,
      builder: (_) => const ShadSheet(
        constraints: BoxConstraints(maxHeight: 620),
        title: Text('详情'),
        child: SizedBox(height: 460, child: SidePanel()),
      ),
    );
  }
}

class _CloudToolbar extends ConsumerWidget {
  final FileState state;
  final bool compact;
  final _PaneLayoutMode paneMode;
  final ValueChanged<_PaneLayoutMode> onPaneModeChanged;
  final _FileViewMode viewMode;
  final ValueChanged<_FileViewMode> onViewModeChanged;
  final bool sidePanelOpen;
  final VoidCallback onToggleSidePanel;
  final VoidCallback? onReturnToSearch;

  const _CloudToolbar({
    required this.state,
    required this.compact,
    required this.paneMode,
    required this.onPaneModeChanged,
    required this.viewMode,
    required this.onViewModeChanged,
    required this.sidePanelOpen,
    required this.onToggleSidePanel,
    this.onReturnToSearch,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(fileProvider.notifier);
    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onReturnToSearch != null) ...[
          _ToolbarButton(
            icon: Icons.arrow_back_rounded,
            label: '返回搜索结果',
            compact: compact,
            onTap: onReturnToSearch,
          ),
          const SizedBox(width: 8),
        ],
        SortMenu(
          currentSort: state.serverSort,
          currentDirection: state.serverSortDirection,
          onSortChanged: notifier.setSort,
          onDirectionToggle: notifier.toggleSortDirection,
        ),
        const SizedBox(width: 8),
        _ToolbarControlGroup(
          children: [
            if (!compact) ...[
              _ToolbarSegment(value: paneMode, onChanged: onPaneModeChanged),
              const _ToolbarGroupDivider(),
            ],
            _FileViewButtons(
              value: viewMode,
              compact: compact,
              onChanged: onViewModeChanged,
            ),
          ],
        ),
        const SizedBox(width: 8),
        ShadPopover(
          visible: state.uploadProgress?.isActive == true,
          closeOnTapOutside: false,
          popover: (_) =>
              _UploadProgressPopover(progress: state.uploadProgress),
          child: _ToolbarButton(
            icon: Icons.upload_rounded,
            label: '上传',
            primary: true,
            compact: compact,
            onTap: state.uploadProgress?.isActive == true
                ? null
                : () => _pickAndUpload(ref),
          ),
        ),
        const SizedBox(width: 8),
        _ToolbarControlGroup(
          children: [
            _ToolbarButton(
              icon: Icons.create_new_folder_rounded,
              label: '新建文件夹',
              compact: compact,
              onTap: () => _showCreateFolderDialog(context, ref),
              grouped: true,
            ),
            _ToolbarButton(
              icon: Icons.refresh_rounded,
              label: '刷新',
              compact: compact,
              onTap: () => notifier.loadFiles(forceRefresh: true),
              grouped: true,
            ),
            _ToolbarButton(
              icon: Icons.more_horiz_rounded,
              label: sidePanelOpen ? '隐藏详情' : '显示详情',
              compact: compact,
              onTap: onToggleSidePanel,
              grouped: true,
              selected: sidePanelOpen,
            ),
          ],
        ),
      ],
    );
    if (compact) {
      return SizedBox(
        height: 40,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: controls,
        ),
      );
    }
    return Row(children: [const Spacer(), controls]);
  }

  Future<void> _pickAndUpload(WidgetRef ref) async {
    final result = await FilePicker.pickFiles();
    if (result == null) return;
    final files = result.paths.whereType<String>().map(File.new).toList();
    await ref.read(fileProvider.notifier).uploadLocalFiles(files);
  }

  void _showCreateFolderDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    showShadDialog(
      context: context,
      builder: (ctx) => ShadDialog(
        title: const Text('新建文件夹'),
        actions: [
          ShadButton.outline(
            child: const Text('取消'),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
          ShadButton(
            child: const Text('创建'),
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                ref.read(fileProvider.notifier).createFolder(name);
                Navigator.of(ctx).pop();
              }
            },
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: ShadInput(
            controller: controller,
            placeholder: const Text('文件夹名称'),
            autofocus: true,
          ),
        ),
      ),
    );
  }
}

class _ToolbarSegment extends StatelessWidget {
  final _PaneLayoutMode value;
  final ValueChanged<_PaneLayoutMode> onChanged;

  const _ToolbarSegment({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final isDual = value == _PaneLayoutMode.dual;
    return _ToolbarButton(
      icon: isDual ? Icons.view_agenda_rounded : Icons.crop_square_rounded,
      label: isDual ? '切换单面板' : '切换双面板',
      grouped: true,
      selected: isDual,
      onTap: () =>
          onChanged(isDual ? _PaneLayoutMode.single : _PaneLayoutMode.dual),
    );
  }
}

class _FileViewButtons extends StatelessWidget {
  final _FileViewMode value;
  final bool compact;
  final ValueChanged<_FileViewMode> onChanged;

  const _FileViewButtons({
    required this.value,
    required this.compact,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ToolbarButton(
          icon: Icons.view_list_rounded,
          label: '列表显示',
          grouped: true,
          compact: compact,
          selected: value == _FileViewMode.list,
          onTap: () => onChanged(_FileViewMode.list),
        ),
        _ToolbarButton(
          icon: Icons.view_column_rounded,
          label: 'Finder 分栏显示',
          grouped: true,
          compact: compact,
          selected: value == _FileViewMode.columns,
          onTap: () => onChanged(_FileViewMode.columns),
        ),
        _ToolbarButton(
          icon: Icons.grid_view_rounded,
          label: '网格显示',
          grouped: true,
          compact: compact,
          selected: value == _FileViewMode.grid,
          onTap: () => onChanged(_FileViewMode.grid),
        ),
      ],
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final bool grouped;
  final bool selected;
  final bool compact;

  const _ToolbarButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.grouped = false,
    this.selected = false,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final disabled = onTap == null;
    return ShadTooltip(
      builder: (_) => Text(label),
      child: Padding(
        padding: EdgeInsets.only(left: grouped ? 0 : 6),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            constraints: BoxConstraints(
              minWidth: compact ? 40 : (primary ? 72 : 36),
            ),
            height: compact ? 40 : 32,
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 0 : (primary ? 10 : 0),
            ),
            decoration: BoxDecoration(
              color: primary
                  ? cs.primary.withValues(alpha: disabled ? 0.55 : 1)
                  : selected
                  ? cs.primary.withValues(alpha: 0.14)
                  : grouped
                  ? Colors.transparent
                  : cs.secondary,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: primary
                    ? cs.primary
                    : selected
                    ? cs.primary.withValues(alpha: 0.45)
                    : grouped
                    ? Colors.transparent
                    : cs.border,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: primary
                      ? cs.primaryForeground
                      : selected
                      ? cs.primary
                      : cs.mutedForeground,
                ),
                if (primary && !compact) ...[
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: cs.primaryForeground,
                    ),
                  ),
                ],
              ],
            ),
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

class _ToolbarControlGroup extends StatelessWidget {
  final List<Widget> children;

  const _ToolbarControlGroup({required this.children});

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: cs.secondary,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _ToolbarGroupDivider extends StatelessWidget {
  const _ToolbarGroupDivider();

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      width: 1,
      height: 20,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      color: cs.border,
    );
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
          : (files, parentID) =>
                notifier.moveFilesTo(files, parentID: parentID),
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

            // Share section uses dedicated ShareListTile
            if (isShareSection) {
              final tile = ShareListTile(
                share: file,
                isSelected: selected,
                onSelect: () => _selectDesktopFile(notifier, file),
                onDelete: () => unawaited(
                  _confirmDeleteCloudFiles(
                    context,
                    [file],
                    () => notifier.deleteFiles([file]),
                    shareRecords: true,
                  ),
                ),
              );
              return tile;
            }

            final tile = FileListTile(
              file: file,
              isSelected: selected,
              onSelect: () => _selectDesktopFile(notifier, file),
              onOpen: file.isDirectory
                  ? () => notifier.navigateToFolder(file)
                  : () => _openCloudFile(context, ref, file),
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
                  : () => notifier.copyToClipboard([file]),
              onCut: _isMobilePlatform
                  ? null
                  : () => notifier.cutToClipboard([file]),
              onCopyTo: () => unawaited(
                _copyOrMoveFilesToDestination(context, ref, [
                  file,
                ], move: false),
              ),
              onMoveTo: () => unawaited(
                _copyOrMoveFilesToDestination(context, ref, [file], move: true),
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
                  ? notifier.restoreFiles([file])
                  : unawaited(
                      _confirmDeleteCloudFiles(context, [
                        file,
                      ], () => notifier.deleteFiles([file])),
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
                onMove: (sources, parentID) =>
                    notifier.moveFilesTo(sources, parentID: parentID),
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
                onMove: (sources, parentID) =>
                    notifier.moveFilesTo(sources, parentID: parentID),
                onOpen: () => notifier.navigateToFolder(file),
                child: _FastTransferContextMenu(
                  file: file,
                  onCopyFastTransfer: () => notifier.copyFastTransferJSON(file),
                  onCopy: _isMobilePlatform
                      ? null
                      : () => notifier.copyToClipboard([file]),
                  onCut: _isMobilePlatform
                      ? null
                      : () => notifier.cutToClipboard([file]),
                  onCopyTo: () => unawaited(
                    _copyOrMoveFilesToDestination(context, ref, [
                      file,
                    ], move: false),
                  ),
                  onMoveTo: () => unawaited(
                    _copyOrMoveFilesToDestination(context, ref, [
                      file,
                    ], move: true),
                  ),
                  child: _FileGridCard(
                    file: file,
                    isSelected: selected,
                    onSelect: () => _selectDesktopFile(notifier, file),
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

class _PaneViewToggle extends StatelessWidget {
  final _FileViewMode value;
  final ValueChanged<_FileViewMode> onChanged;

  const _PaneViewToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final mode = switch (value) {
      _FileViewMode.list => _FileViewMode.columns,
      _FileViewMode.columns => _FileViewMode.grid,
      _FileViewMode.grid => _FileViewMode.list,
    };
    return _PaneIconButton(
      icon: switch (value) {
        _FileViewMode.list => Icons.view_list_rounded,
        _FileViewMode.columns => Icons.view_column_rounded,
        _FileViewMode.grid => Icons.grid_view_rounded,
      },
      tooltip: '切换显示模式',
      onTap: () => onChanged(mode),
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
  bool _additive = false;

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
    final pane = context.findRenderObject() as RenderBox?;
    if (pane == null) return;
    final selection = Rect.fromPoints(start, event.localPosition);
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
    widget.onMarqueeSelectionChanged!(
      _additive ? {..._selectionBefore, ...hitIDs} : hitIDs,
    );
  }

  void _pointerEnd(PointerEvent event) {
    if (_start == null) return;
    setState(() {
      _start = null;
      _current = null;
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.viewMode == _FileViewMode.list
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

  @override
  void initState() {
    super.initState();
    _restorePath(widget.initialPath, initialFiles: widget.initialFiles);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
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
      final result = await ref
          .read(authProvider.notifier)
          .api
          .fsFiles(parentID: _columns[index].parentID, page: 0, pageSize: 200);
      _replaceColumn(
        index,
        _columns[index].copyWith(
          files: _cloudFilesFromResponse(result),
          isLoading: false,
          clearError: true,
        ),
        requestGeneration,
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
                        onActivate: () => _collapseToColumn(index),
                        onSelect: (file) => _selectColumnFile(index, file),
                        onSelectAll: () => _selectAllColumn(index),
                        onDeleteSelected: (files) =>
                            _deleteColumnFiles(index, files),
                        onRename: _renameColumnFile,
                        onCopy: (file) => ref
                            .read(fileProvider.notifier)
                            .copyToClipboard([file]),
                        onCut: (file) => ref
                            .read(fileProvider.notifier)
                            .cutToClipboard([file]),
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
  final VoidCallback onActivate;
  final ValueChanged<CloudFile> onSelect;
  final VoidCallback onSelectAll;
  final ValueChanged<List<CloudFile>> onDeleteSelected;
  final Future<void> Function(CloudFile file) onRename;
  final ValueChanged<CloudFile> onCopy;
  final ValueChanged<CloudFile> onCut;
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
                                final selected = column.selectedIDs.contains(
                                  file.id,
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
                                  onCopy: () => widget.onCopy(file),
                                  onCut: () => widget.onCut(file),
                                  onDownload: file.isDirectory
                                      ? null
                                      : () => widget.onDownload(file),
                                  onShare: () => widget.onShare(file),
                                  onCopyFastTransfer: () =>
                                      widget.onCopyFastTransfer(file),
                                  onDelete: () =>
                                      widget.onDeleteSelected([file]),
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

class _FileGridCard extends StatelessWidget {
  final CloudFile file;
  final bool isSelected;
  final VoidCallback onSelect;
  final VoidCallback onOpen;

  const _FileGridCard({
    required this.file,
    required this.onSelect,
    required this.onOpen,
    this.isSelected = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Semantics(
      button: true,
      label:
          '${file.name}，${file.isDirectory ? '文件夹' : file.typeName}，${file.formattedSize}',
      child: GestureDetector(
        onTap: onSelect,
        onDoubleTap: onOpen,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: isSelected ? cs.primary.withValues(alpha: 0.12) : cs.card,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected
                  ? cs.primary.withValues(alpha: 0.65)
                  : cs.border.withValues(alpha: 0.58),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 38, height: 38, child: FileIcon(file: file)),
              const Spacer(),
              Text(
                file.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: cs.foreground,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                file.directoryContentSummary ?? file.formattedSize,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: cs.mutedForeground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FastTransferContextMenu extends StatelessWidget {
  final CloudFile file;
  final VoidCallback onCopyFastTransfer;
  final VoidCallback? onCopy;
  final VoidCallback? onCut;
  final VoidCallback? onCopyTo;
  final VoidCallback? onMoveTo;
  final Widget child;

  const _FastTransferContextMenu({
    required this.file,
    required this.onCopyFastTransfer,
    this.onCopy,
    this.onCut,
    this.onCopyTo,
    this.onMoveTo,
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
  var _pageSize = 50;
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
            final row = FileListTile(
              file: file,
              isSelected: selected,
              onSelect: () => _selectWithModifiers(file),
              onOpen: () => _open(file),
              onCopy: () =>
                  ref.read(fileProvider.notifier).copyToClipboard([file]),
              onCut: () =>
                  ref.read(fileProvider.notifier).cutToClipboard([file]),
              onCopyTo: () => unawaited(() async {
                final completed = await _copyOrMoveFilesToDestination(
                  context,
                  ref,
                  [file],
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
                  [file],
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
                _confirmDeleteCloudFiles(context, [file], () async {
                  await ref.read(fileProvider.notifier).deleteFiles([file]);
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
                  ref.read(fileProvider.notifier).copyToClipboard([file]),
              onCut: () =>
                  ref.read(fileProvider.notifier).cutToClipboard([file]),
              onCopyTo: () => unawaited(() async {
                final completed = await _copyOrMoveFilesToDestination(
                  context,
                  ref,
                  [file],
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
                  [file],
                  move: true,
                );
                if (completed && mounted) {
                  await _load(parentID: _currentParentID);
                }
              }()),
              child: _FileGridCard(
                file: file,
                isSelected: selected,
                onSelect: () => _selectWithModifiers(file),
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

class _PanePagination extends StatelessWidget {
  static const _pageSizes = [
    10,
    20,
    50,
    100,
    200,
    500,
    1000,
    2000,
    5000,
    10000,
  ];

  final int currentPage;
  final int pageSize;
  final int totalPages;
  final int fileCount;
  final int folderCount;
  final VoidCallback? onPreviousPage;
  final VoidCallback? onNextPage;
  final ValueChanged<int>? onPageSizeChanged;

  const _PanePagination({
    required this.currentPage,
    required this.pageSize,
    required this.totalPages,
    required this.fileCount,
    required this.folderCount,
    this.onPreviousPage,
    this.onNextPage,
    this.onPageSizeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: cs.border.withValues(alpha: 0.62)),
        ),
      ),
      child: Row(
        children: [
          Text(
            '文件 $fileCount，文件夹 $folderCount',
            style: TextStyle(fontSize: 11, color: cs.mutedForeground),
          ),
          const SizedBox(width: 14),
          Text(
            '第 ${currentPage + 1} / ${totalPages.clamp(1, 1 << 31)} 页',
            style: TextStyle(fontSize: 11, color: cs.mutedForeground),
          ),
          const Spacer(),
          ShadSelect<int>(
            initialValue: pageSize,
            enabled: onPageSizeChanged != null,
            minWidth: 80,
            selectedOptionBuilder: (context, value) => Text('$value / 页'),
            options: [
              for (final size in _pageSizes)
                ShadOption(value: size, child: Text('$size / 页')),
            ],
            onChanged: (value) {
              if (value != null) onPageSizeChanged?.call(value);
            },
          ),
          const SizedBox(width: 6),
          _PaneIconButton(
            icon: Icons.chevron_left_rounded,
            tooltip: '上一页',
            onTap: onPreviousPage,
          ),
          const SizedBox(width: 3),
          _PaneIconButton(
            icon: Icons.chevron_right_rounded,
            tooltip: '下一页',
            onTap: onNextPage,
          ),
        ],
      ),
    );
  }
}

class _PaneIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  const _PaneIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ShadTooltip(
      builder: (_) => Text(tooltip),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 26,
          height: 26,
          child: Icon(
            icon,
            size: 16,
            color: onTap == null
                ? cs.mutedForeground.withValues(alpha: 0.45)
                : cs.foreground,
          ),
        ),
      ),
    );
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

class _PaneDropSurface extends StatefulWidget {
  final String? parentID;
  final Future<void> Function(List<CloudFile> files, String? parentID)?
  onMoveCloudFiles;
  final Future<void> Function(List<File> files, String? parentID)?
  onUploadLocalFiles;
  final Widget child;

  const _PaneDropSurface({
    required this.parentID,
    required this.onMoveCloudFiles,
    required this.onUploadLocalFiles,
    required this.child,
  });

  @override
  State<_PaneDropSurface> createState() => _PaneDropSurfaceState();
}

class _PaneDropSurfaceState extends State<_PaneDropSurface> {
  var _active = false;

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return DropTarget(
      onDragEntered: (_) => setState(() => _active = true),
      onDragExited: (_) => setState(() => _active = false),
      onDragDone: (details) async {
        setState(() => _active = false);
        final files = details.files
            .map((file) => file.path)
            .where((path) => path.isNotEmpty)
            .map(File.new)
            .where((file) => file.existsSync())
            .toList();
        if (files.isNotEmpty) {
          await widget.onUploadLocalFiles?.call(files, widget.parentID);
        }
      },
      child: DragTarget<_DraggedCloudFiles>(
        onWillAcceptWithDetails: (_) => widget.onMoveCloudFiles != null,
        onAcceptWithDetails: (details) async {
          setState(() => _active = false);
          await widget.onMoveCloudFiles?.call(
            details.data.files,
            widget.parentID,
          );
        },
        onMove: (_) {
          if (!_active) setState(() => _active = true);
        },
        onLeave: (_) => setState(() => _active = false),
        builder: (context, candidates, rejected) {
          final active = _active || candidates.isNotEmpty;
          return Stack(
            children: [
              widget.child,
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: active ? 1 : 0,
                    duration: const Duration(milliseconds: 120),
                    child: Container(
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: cs.primary, width: 1.5),
                      ),
                      child: Center(
                        child: OS26Glass(
                          radius: 12,
                          opacity: 0.7,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 12,
                          ),
                          child: Text(
                            '松开以上传或移动到此面板',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: cs.primary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DragFeedback extends StatelessWidget {
  final String label;

  const _DragFeedback({required this.label});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: OS26Glass(
        radius: 10,
        opacity: 0.78,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insert_drive_file_rounded, size: 16),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
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
