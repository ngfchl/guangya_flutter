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
import '../core/storage/file_metadata_cache.dart';
import '../core/utils/folder_stats_loader.dart';
import '../core/utils/guangya_share_link.dart';
import '../models/cloud_file.dart';
import '../models/media_library.dart';
import '../models/media_navigation.dart';
import '../providers/auth_provider.dart';
import '../providers/file_provider.dart';
import '../providers/media_library_provider.dart';
import '../providers/watch_history_provider.dart';
import '../widgets/app_dialog.dart';
import '../widgets/breadcrumb_bar.dart';
import '../widgets/app_loading_indicator.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/file_list_tile.dart';
import '../widgets/file_detail_dialog.dart';
import '../widgets/media_player_dialog.dart';
import '../widgets/file_icon.dart';
import '../widgets/file_preview_dialog.dart';
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

part 'workspace/workspace_cloud.dart';
part 'workspace/workspace_media.dart';
part 'workspace/workspace_sidebar.dart';
part 'workspace/workspace_topbar.dart';
part 'workspace/workspace_toolbar.dart';
part 'workspace/workspace_mobile.dart';
part 'workspace/workspace_file_view.dart';
part 'workspace/workspace_drag_drop.dart';
part 'workspace/workspace_scan.dart';
part 'workspace/workspace_shared.dart';


enum WorkspaceMode { cloud, media }

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
  bool _confirmingExit = false;
  MediaLibraryFilter _mediaLibraryFilter = const MediaLibraryFilter();
  bool _mediaFilterPanelExpanded = false;

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

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: OS26Surface(
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 720;
                final showMediaListFilters =
                    _mode == WorkspaceMode.media &&
                    _mediaActiveTool == null &&
                    _mediaSearchQuery == null &&
                    mediaDetail == null &&
                    !_mediaHomeSelected;
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
                  onToggleFilter: showMediaListFilters
                      ? () => setState(() {
                            _mediaFilterPanelExpanded = !_mediaFilterPanelExpanded;
                            if (!_mediaFilterPanelExpanded) {
                              _mediaLibraryFilter = const MediaLibraryFilter();
                            }
                          })
                      : null,
                  filterActive: _mediaLibraryFilter.isActive || _mediaFilterPanelExpanded,
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
                              if (showMediaListFilters && _mediaFilterPanelExpanded)
                                _buildMediaFilterPanel(context, ref),
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
                          Expanded(child: content),
                        ],
                      ),
                    ),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
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
                              onScanTasks: () =>
                                  _showScanTaskManagement(context),
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
                            SizedBox(height: _desktopSidebarTopGap),
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

  /// 判断当前是否处于"首页"状态（无工具、无搜索、无媒体详情）
  bool get _isAtHome =>
      _cloudActiveTool == null &&
      _mediaActiveTool == null &&
      _fileSearchQuery == null &&
      _mediaSearchQuery == null &&
      ref.read(activeMediaDetailHeaderProvider) == null;

  /// 返回键拦截：不在首页则先回首页，已在首页则弹窗确认退出
  Future<bool> _onWillPop() async {
    if (!_isAtHome) {
      _goHome();
      return false;
    }
    // 已在首页，二次确认退出
    if (_confirmingExit) return true;
    _confirmingExit = true;
    final confirmed = await showShadDialog<bool>(
      context: context,
      builder: (_) => ShadDialog(
        title: const Text('退出应用'),
        description: const Text('确定要退出小黄鸭吗？'),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          ShadButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    _confirmingExit = false;
    return confirmed == true;
  }

  /// 回到首页状态：关闭工具、搜索、媒体详情
  void _goHome() {
    ref.read(activeMediaDetailHeaderProvider.notifier).state = null;
    setState(() {
      _cloudActiveTool = null;
      _mediaActiveTool = null;
      _mediaFilterPanelExpanded = false;
      _fileSearchQuery = null;
      _fileSearchReturnQuery = null;
      _fileSearchResultsCache = null;
      _mediaSearchQuery = null;
      _searchOpen = false;
      _searchController.clear();
      _mediaHomeSelected = true;
      _mediaBrowseFilter = MediaLibraryBrowseFilter.all;
      _mediaLibrarySection = MediaLibraryBrowseFilter.all;
    });
  }

  void _changeMediaBrowseFilter(MediaLibraryBrowseFilter filter) {
    ref.read(activeMediaDetailHeaderProvider.notifier).state = null;
    setState(() {
      _mediaBrowseFilter = filter;
      _mediaLibrarySection = MediaLibraryBrowseFilter.all;
      _mediaHomeSelected = false;
      _mediaActiveTool = null;
      _mediaFilterPanelExpanded = false;
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
      setState(() {
        _mediaSearchQuery = query;
        _mediaFilterPanelExpanded = false;
      });
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
      onBatchRename: (files) {
        final notifier = ref.read(fileProvider.notifier);
        notifier.copyToClipboard(files);
        notifier.clearSelection();
        setState(() => _cloudActiveTool = WorkspaceTool.rename);
      },
      onReturnToSearch: _fileSearchReturnQuery == null
          ? null
          : () => setState(() {
              _fileSearchQuery = _fileSearchReturnQuery;
              _fileSearchReturnQuery = null;
              _searchController.text = _fileSearchQuery!;
            }),
      onPasteShare: _pasteShareLink,
      onScanShare: _scanShareQRCode,
      searchController: _searchController,
      searchFocusNode: _searchFocusNode,
      searchOpen: _searchOpen,
      onSearch: _submitSearch,
      onToggleSearch: () => setState(() {
        _searchOpen = !_searchOpen;
        if (!_searchOpen) {
          _searchController.clear();
          if (_fileSearchQuery != null && _fileSearchQuery!.isNotEmpty) {
            _fileSearchQuery = '';
            _fileSearchReturnQuery = null;
            ref.read(fileProvider.notifier).loadFiles(forceRefresh: true);
          }
        } else {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _searchFocusNode.requestFocus();
          });
        }
      }),
    );
  }

  Widget _buildMediaFilterPanel(BuildContext context, WidgetRef ref) {
    final media = ref.read(mediaLibraryProvider);
    final hasWatchHistory = ref.read(watchHistoryProvider).isNotEmpty;
    return MediaLibraryFilterPanel(
      filter: _mediaLibraryFilter,
      availableGenres: media.filterOptions.genres,
      availableCountries: media.filterOptions.countries,
      availableWatchedKeys: hasWatchHistory ? const {'watched', 'unwatched'} : const {},
      onFilter: (next) => setState(() => _mediaLibraryFilter = next),
      onCollapse: () => setState(() => _mediaFilterPanelExpanded = false),
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
      libraryFilter: _mediaLibraryFilter,
      onLibraryFilterChanged: (next) => setState(() => _mediaLibraryFilter = next),
    );
  }
}
