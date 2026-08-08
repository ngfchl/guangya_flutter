part of '../workspace_page.dart';

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

@visibleForTesting
List<CloudFile> resolveCloudFileActionSelection({
  required List<CloudFile> files,
  required Set<String> selectedIDs,
  required CloudFile target,
}) {
  if (!selectedIDs.contains(target.id)) return [target];
  final selected = files
      .where((file) => selectedIDs.contains(file.id))
      .toList(growable: false);
  return selected.isEmpty ? [target] : selected;
}

const _desktopSelectAllShortcuts = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.keyA, meta: true): _SelectAllFilesIntent(),
  SingleActivator(LogicalKeyboardKey.keyA, control: true):
      _SelectAllFilesIntent(),
};

class _CloudFolderDestinationPicker extends ConsumerStatefulWidget {
  final bool move;
  final List<CloudFile> files;
  final Future<bool> Function(String? parentID) onExecute;

  const _CloudFolderDestinationPicker({
    required this.move,
    required this.files,
    required this.onExecute,
  });

  @override
  ConsumerState<_CloudFolderDestinationPicker> createState() =>
      _CloudFolderDestinationPickerState();
}

class _CloudFolderDestinationPickerState
    extends ConsumerState<_CloudFolderDestinationPicker> {
  final _path = <CloudFile>[];
  final _filterController = TextEditingController();
  var _folders = <CloudFile>[];
  var _cachedFolders = <CloudFile>[];
  CloudFile? _selectedFolder;
  var _loading = false;
  var _loadingSearchCache = false;
  var _executing = false;
  Timer? _searchDebounce;
  var _searchGeneration = 0;
  String? _error;
  String _filterQuery = '';

  List<CloudFile> get _filteredFolders {
    if (_filterQuery.isEmpty) return _folders;
    return _cachedFolders;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _filterController.dispose();
    super.dispose();
  }

  void _clearFilter() {
    _searchDebounce?.cancel();
    _searchGeneration++;
    _filterController.clear();
    _filterQuery = '';
    _cachedFolders = [];
  }

  void _scheduleFolderSearch(String query) {
    _searchDebounce?.cancel();
    final generation = ++_searchGeneration;
    if (query.isEmpty) {
      setState(() => _cachedFolders = []);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 220), () {
      if (generation == _searchGeneration) {
        unawaited(_searchCachedFolders(query, generation: generation));
      }
    });
  }

  Future<void> _searchCachedFolders(
    String query, {
    int? generation,
  }) async {
    final requestGeneration = generation ?? ++_searchGeneration;
    if (mounted) setState(() => _loadingSearchCache = true);
    try {
      final matches = await FileMetadataCache.searchCachedDirectories(query);
      if (!mounted ||
          requestGeneration != _searchGeneration ||
          query != _filterQuery) {
        return;
      }
      setState(() {
        _cachedFolders = matches;
        _error = null;
      });
    } catch (error) {
      if (mounted && requestGeneration == _searchGeneration) {
        setState(() => _error = '搜索本地文件夹索引失败：$error');
      }
    } finally {
      if (mounted && requestGeneration == _searchGeneration) {
        setState(() => _loadingSearchCache = false);
      }
    }
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
    if (_executing) return;
    setState(() {
      _path.add(folder);
      _selectedFolder = null;
      _clearFilter();
    });
    unawaited(_load());
  }

  Future<void> _execute() async {
    if (_executing || _loading) return;
    final destinationID =
        _selectedFolder?.id ?? (_path.isEmpty ? null : _path.last.id);
    if (widget.move &&
        widget.files.every(
          (file) => _sameCloudParentID(file.parentID, destinationID),
        )) {
      setState(() => _error = '不能移动至相同目录');
      return;
    }
    setState(() {
      _executing = true;
      _error = null;
    });
    try {
      final succeeded = await widget.onExecute(destinationID);
      if (!mounted) return;
      if (succeeded) {
        Navigator.of(context).pop(true);
      } else {
        setState(() {
          _executing = false;
          _error =
              ref.read(fileProvider).errorMessage ??
              (widget.move ? '移动失败，请重试' : '复制失败，请重试');
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _executing = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final viewport = MediaQuery.sizeOf(context);
    final useDesktopSize = _isDesktopWindow && viewport.width >= 700;
    final contentWidth = useDesktopSize
        ? (viewport.width * 0.62).clamp(600.0, 760.0)
        : (viewport.width - 80).clamp(240.0, 440.0);
    final contentHeight = useDesktopSize
        ? (viewport.height * 0.62).clamp(420.0, 620.0)
        : (viewport.height * 0.55).clamp(280.0, 480.0);
    final currentName = _path.isEmpty ? '云盘根目录' : _path.last.name;
    final destinationName = _selectedFolder == null
        ? currentName
        : _filterQuery.isNotEmpty && _selectedFolder!.cloudPath.isNotEmpty
        ? _selectedFolder!.cloudPath
        : _selectedFolder!.name;
    return PopScope(
      canPop: !_executing,
      child: ShadDialog(
        closeIcon: const SizedBox.shrink(),
        constraints: BoxConstraints(maxWidth: contentWidth + 48),
        title: Text(widget.move ? '移动到' : '复制到'),
        description: Text('目标文件夹：$destinationName'),
        actions: [
          ShadButton.outline(
            onPressed: _executing
                ? null
                : () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          ShadButton(
            onPressed: _loading || _executing ? null : _execute,
            child: _executing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('选择'),
          ),
        ],
        child: IgnorePointer(
          ignoring: _executing,
          child: SizedBox(
            width: contentWidth,
            height: contentHeight,
            child: Material(
              type: MaterialType.transparency,
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
                        placeholder: const Text('搜索全部文件夹…'),
                        controller: _filterController,
                        onChanged: (value) {
                          final query = value.trim();
                          setState(() {
                            _filterQuery = query;
                            _selectedFolder = null;
                          });
                          _scheduleFolderSearch(query);
                        },
                        leading: const Icon(Icons.search, size: 16),
                      ),
                    ),
                  Expanded(
                    child:
                        _loading ||
                            (_filterQuery.isNotEmpty && _loadingSearchCache)
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
                              _filterQuery.isNotEmpty
                                  ? '没有匹配的文件夹'
                                  : '当前目录没有文件夹',
                              style: TextStyle(color: cs.mutedForeground),
                            ),
                          )
                        : ListView.builder(
                            itemCount: _filteredFolders.length,
                            itemBuilder: (context, index) {
                              final folder = _filteredFolders[index];
                              final selected = _selectedFolder?.id == folder.id;
                              return InkWell(
                                onTap: () =>
                                    setState(() => _selectedFolder = folder),
                                onDoubleTap: _filterQuery.isEmpty
                                    ? () => _enterFolder(folder)
                                    : null,
                                borderRadius: BorderRadius.circular(6),
                                child: Container(
                                  height: 38,
                                  padding: const EdgeInsets.only(
                                    left: 10,
                                    right: 4,
                                  ),
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
                                        color: selected
                                            ? cs.primary
                                            : cs.foreground,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          folder.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (_filterQuery.isEmpty)
                                        ShadTooltip(
                                          builder: (_) => const Text('进入目录'),
                                          child: ShadButton.ghost(
                                            size: ShadButtonSize.sm,
                                            onPressed: () =>
                                                _enterFolder(folder),
                                            child: const Icon(
                                              Icons.chevron_right_rounded,
                                              size: 18,
                                            ),
                                          ),
                                        )
                                      else
                                        Expanded(
                                          child: Text(
                                            folder.cloudPath,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.right,
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: cs.mutedForeground,
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
          ),
        ),
      ),
    );
  }
}

class _CloudSidebar extends StatelessWidget {
  final FileState state;
  final double width;
  final bool showBrand;
  final bool collapsed;
  final VoidCallback? onToggleCollapsed;
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
    this.collapsed = false,
    this.onToggleCollapsed,
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
    final effectiveWidth = collapsed ? 64.0 : width;
    return SizedBox(
      width: effectiveWidth,
      child: Column(
        children: [
          if (showBrand && _isDesktopWindow)
            SizedBox(
              height: _desktopSidebarTopGap,
              child: !Platform.isMacOS
                  ? const Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: EdgeInsets.only(left: 2),
                        child: WindowControls(),
                      ),
                    )
                  : null,
            ),
          Expanded(
            child: OS26Glass(
              radius: showBrand ? 24 : 0,
              opacity: showBrand ? 0.56 : 0,
              border: showBrand ? null : const Border(),
              applyBlur: showBrand,
              padding: collapsed
                  ? const EdgeInsets.fromLTRB(6, 10, 6, 10)
                  : EdgeInsets.fromLTRB(14, showBrand ? 14 : 12, 14, 12),
              child: ListView(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                children: [
                  if (showBrand) ...[
                    _SidebarBrand(
                      icon: Icons.cloud_sync_rounded,
                      title: '光鸭云盘',
                      subtitle: 'Cloud Workspace',
                      imageAsset: 'assets/branding/guangya_icon.png',
                      onSwitchMode: () => onModeChanged(WorkspaceMode.media),
                      onSettings: onSettings,
                      collapsed: collapsed,
                      onToggleCollapsed: onToggleCollapsed,
                    ),
                    const SizedBox(height: 14),
                  ],
                  for (final section in sections)
                    _SidebarTile(
                      icon: _sectionIcon(section),
                      label: section.label,
                      selected: state.section == section,
                      onTap: () => onSection(section),
                      collapsed: collapsed,
                    ),
                  const Divider(height: 24),
                  _SidebarTile(
                    icon: Icons.folder_off_rounded,
                    label: '空文件夹',
                    selected: activeTool == WorkspaceTool.emptyFolderScan,
                    onTap: () => onTool(WorkspaceTool.emptyFolderScan),
                    collapsed: collapsed,
                  ),
                  _SidebarTile(
                    icon: Icons.content_copy_rounded,
                    label: '重复文件',
                    selected:
                        activeTool == WorkspaceTool.duplicateFileScan,
                    onTap: () => onTool(WorkspaceTool.duplicateFileScan),
                    collapsed: collapsed,
                  ),
                  _SidebarTile(
                    icon: Icons.folder_special_rounded,
                    label: '目录整理',
                    selected:
                        activeTool == WorkspaceTool.similarFolderScan,
                    onTap: () => onTool(WorkspaceTool.similarFolderScan),
                    collapsed: collapsed,
                  ),
                  _SidebarTile(
                    icon: Icons.text_fields_rounded,
                    label: '批量命名',
                    selected: activeTool == WorkspaceTool.rename,
                    onTap: () => onTool(WorkspaceTool.rename),
                    collapsed: collapsed,
                  ),
                  _SidebarTile(
                    icon: Icons.bolt_rounded,
                    label: '秒传工具',
                    selected: activeTool == WorkspaceTool.fastTransfer,
                    onTap: () => onTool(WorkspaceTool.fastTransfer),
                    collapsed: collapsed,
                  ),
                  _SidebarTile(
                    icon: Icons.logout_rounded,
                    label: '退出登录',
                    selected: false,
                    onTap: onSignOut,
                    collapsed: collapsed,
                  ),
                ],
              ),
            ),
          ),
        ],
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

class _CloudWorkspace extends ConsumerStatefulWidget {
  final FileState state;
  final bool sidePanelOpen;
  final VoidCallback onToggleSidePanel;
  final ValueChanged<List<CloudFile>> onBatchRename;
  final VoidCallback? onReturnToSearch;
  final VoidCallback? onPasteShare;
  final VoidCallback? onScanShare;
  final TextEditingController? searchController;
  final FocusNode? searchFocusNode;
  final bool searchOpen;
  final ValueChanged<String>? onSearch;
  final VoidCallback? onToggleSearch;

  const _CloudWorkspace({
    required this.state,
    required this.sidePanelOpen,
    required this.onToggleSidePanel,
    required this.onBatchRename,
    this.onReturnToSearch,
    this.onPasteShare,
    this.onScanShare,
    this.searchController,
    this.searchFocusNode,
    this.searchOpen = false,
    this.onSearch,
    this.onToggleSearch,
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
                onBatchRename: widget.onBatchRename,
                onReturnToSearch: widget.onReturnToSearch,
                onPasteShare: widget.onPasteShare,
                onScanShare: widget.onScanShare,
                searchController: widget.searchController,
                searchFocusNode: widget.searchFocusNode,
                searchOpen: widget.searchOpen,
                onSearch: widget.onSearch,
                onToggleSearch: widget.onToggleSearch,
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

/// 云盘工具栏里的搜索框：收起态显示搜索按钮，展开态显示输入框+关闭按钮。
/// 从 `_TopBar` 移下来，让标题栏只保留拖拽区，搜索能力落到主体工具栏。
class _CloudToolbarSearchField extends StatelessWidget {
  final bool compact;
  final TextEditingController? searchController;
  final FocusNode? searchFocusNode;
  final bool searchOpen;
  final ValueChanged<String>? onSearch;
  final VoidCallback? onToggleSearch;

  const _CloudToolbarSearchField({
    required this.compact,
    this.searchController,
    this.searchFocusNode,
    this.searchOpen = false,
    this.onSearch,
    this.onToggleSearch,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: searchOpen ? (compact ? 180 : 280) : 38,
      height: 38,
      child: searchOpen
          ? OS26Glass(
              radius: 19,
              opacity: 0.52,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ClipRect(
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
                        style: TextStyle(
                          color: cs.foreground,
                          fontSize: 13,
                        ),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          isDense: true,
                          hintText: '搜索文件',
                          hintStyle: TextStyle(
                            color: cs.mutedForeground,
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
              ),
            )
          : _ToolbarButton(
              icon: Icons.search_rounded,
              label: '搜索文件',
              compact: compact,
              onTap: onToggleSearch,
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
  final ValueChanged<List<CloudFile>> onBatchRename;
  final VoidCallback? onReturnToSearch;
  final VoidCallback? onPasteShare;
  final VoidCallback? onScanShare;
  final TextEditingController? searchController;
  final FocusNode? searchFocusNode;
  final bool searchOpen;
  final ValueChanged<String>? onSearch;
  final VoidCallback? onToggleSearch;

  const _CloudToolbar({
    required this.state,
    required this.compact,
    required this.paneMode,
    required this.onPaneModeChanged,
    required this.viewMode,
    required this.onViewModeChanged,
    required this.sidePanelOpen,
    required this.onToggleSidePanel,
    required this.onBatchRename,
    this.onReturnToSearch,
    this.onPasteShare,
    this.onScanShare,
    this.searchController,
    this.searchFocusNode,
    this.searchOpen = false,
    this.onSearch,
    this.onToggleSearch,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(fileProvider.notifier);
    final selectedFiles = state.files
        .where((file) => state.selectedIDs.contains(file.id))
        .toList(growable: false);
    if (selectedFiles.isNotEmpty && state.section == WorkspaceSection.files) {
      return _CloudSelectionToolbar(
        compact: compact,
        selectedCount: selectedFiles.length,
        onExit: notifier.clearSelection,
        onSelectAll: notifier.selectAll,
        onCopyTo: () => unawaited(
          _copyOrMoveFilesToDestination(
            context,
            ref,
            selectedFiles,
            move: false,
          ),
        ),
        onMoveTo: () => unawaited(
          _copyOrMoveFilesToDestination(
            context,
            ref,
            selectedFiles,
            move: true,
          ),
        ),
        onDelete: () => unawaited(
          _confirmDeleteCloudFiles(
            context,
            selectedFiles,
            () => notifier.deleteFiles(selectedFiles),
          ),
        ),
        onRename: () => onBatchRename(selectedFiles),
      );
    }
    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onToggleSearch != null) ...[
          _CloudToolbarSearchField(
            compact: compact,
            searchController: searchController,
            searchFocusNode: searchFocusNode,
            searchOpen: searchOpen,
            onSearch: onSearch,
            onToggleSearch: onToggleSearch,
          ),
          const SizedBox(width: 8),
        ],
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
        if (onPasteShare != null || onScanShare != null) ...[
          const SizedBox(width: 8),
          _ToolbarControlGroup(
            children: [
              if (onPasteShare != null)
                _ToolbarButton(
                  icon: Icons.content_paste_rounded,
                  label: '粘贴分享链接',
                  compact: compact,
                  onTap: onPasteShare,
                  grouped: true,
                ),
              if (onScanShare != null)
                _ToolbarButton(
                  icon: Icons.qr_code_scanner_rounded,
                  label: '扫码分享',
                  compact: compact,
                  onTap: onScanShare,
                  grouped: true,
                ),
            ],
          ),
        ],
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
        closeIcon: const SizedBox.shrink(),
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

class _CloudSelectionToolbar extends StatelessWidget {
  final bool compact;
  final int selectedCount;
  final VoidCallback onExit;
  final VoidCallback onSelectAll;
  final VoidCallback onCopyTo;
  final VoidCallback onMoveTo;
  final VoidCallback onDelete;
  final VoidCallback onRename;

  const _CloudSelectionToolbar({
    required this.compact,
    required this.selectedCount,
    required this.onExit,
    required this.onSelectAll,
    required this.onCopyTo,
    required this.onMoveTo,
    required this.onDelete,
    required this.onRename,
  });

  @override
  Widget build(BuildContext context) {
    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (compact) ...[
          _SelectionActionButton(
            icon: Icons.close_rounded,
            label: '退出',
            onTap: onExit,
          ),
          _SelectionActionButton(
            icon: Icons.select_all_rounded,
            label: '全选',
            onTap: onSelectAll,
          ),
        ] else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text('已选择 $selectedCount 项'),
          ),
          _SelectionActionButton(
            icon: Icons.select_all_rounded,
            label: '全选',
            onTap: onSelectAll,
          ),
          _SelectionActionButton(
            icon: Icons.close_rounded,
            label: '退出选择',
            onTap: onExit,
          ),
        ],
        _SelectionActionButton(
          icon: Icons.copy_all_rounded,
          label: '复制到',
          onTap: onCopyTo,
        ),
        _SelectionActionButton(
          icon: Icons.drive_file_move_rounded,
          label: '移动到',
          onTap: onMoveTo,
        ),
        _SelectionActionButton(
          icon: Icons.delete_outline_rounded,
          label: '删除',
          destructive: true,
          onTap: onDelete,
        ),
        _SelectionActionButton(
          icon: Icons.text_fields_rounded,
          label: '重命名',
          onTap: onRename,
        ),
      ],
    );
    return SizedBox(
      height: 40,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: controls,
      ),
    );
  }
}
