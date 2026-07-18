import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:window_manager/window_manager.dart';

import '../app/app_theme.dart';
import '../core/storage/storage_manager.dart';
import '../models/cloud_file.dart';
import '../models/media_library.dart';
import '../providers/auth_provider.dart';
import '../providers/file_provider.dart';
import '../providers/media_library_provider.dart';
import '../widgets/breadcrumb_bar.dart';
import '../widgets/file_list_tile.dart';
import '../widgets/media_player_dialog.dart';
import '../widgets/file_icon.dart';
import '../widgets/side_panel.dart';
import '../widgets/sort_menu.dart';
import 'media_library_page.dart';
import 'search_results_page.dart';
import 'settings_page.dart';
import 'workspace_tools_page.dart';

enum WorkspaceMode { cloud, media }

enum _PaneLayoutMode { single, dual }

enum _FileViewMode { list, columns, grid }

enum _PaneIdentity { primary, secondary }

class _DraggedCloudFiles {
  final List<CloudFile> files;
  final _PaneIdentity source;

  const _DraggedCloudFiles(this.files, this.source);
}

void _openCloudFile(BuildContext context, WidgetRef ref, CloudFile file) {
  if (file.isVideo) {
    showShadDialog<void>(
      context: context,
      builder: (_) => MediaPlayerDialog(file: file),
    );
    return;
  }
  ref.read(fileProvider.notifier).downloadFile(file);
}

class WorkspacePage extends ConsumerStatefulWidget {
  const WorkspacePage({super.key});

  @override
  ConsumerState<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends ConsumerState<WorkspacePage> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  WorkspaceMode _mode = WorkspaceMode.cloud;
  bool _isSidePanelOpen = false;
  bool _searchOpen = false;
  String? _fileSearchQuery;
  String? _mediaSearchQuery;
  WorkspaceTool? _activeTool;

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fp = ref.watch(fileProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: OS26Surface(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                _mode == WorkspaceMode.cloud
                    ? _CloudSidebar(
                        state: fp,
                        onSection: (section) =>
                            ref.read(fileProvider.notifier).setSection(section),
                        onSettings: () => _showSettings(context),
                        onSignOut: () =>
                            ref.read(authProvider.notifier).signOut(),
                        onTool: (tool) => setState(() => _activeTool = tool),
                      )
                    : _MediaSidebar(
                        onCreate: () =>
                            MediaLibraryPage.showCreateDialog(context, ref),
                        onTool: (tool) => setState(() => _activeTool = tool),
                      ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    children: [
                      _TopBar(
                        mode: _mode,
                        onModeChanged: (mode) {
                          setState(() => _mode = mode);
                          if (mode == WorkspaceMode.media) {
                            ref.read(mediaLibraryProvider.notifier).api = ref
                                .read(authProvider.notifier)
                                .api;
                            ref.read(mediaLibraryProvider.notifier).load();
                          }
                        },
                        searchController: _searchController,
                        searchFocusNode: _searchFocusNode,
                        searchOpen: _searchOpen,
                        onSearch: (value) {
                          final query = value.trim();
                          if (query.isEmpty) return;
                          if (_mode == WorkspaceMode.media) {
                            setState(() => _mediaSearchQuery = query);
                            ref
                                .read(mediaLibraryProvider.notifier)
                                .setSearchQuery(query);
                          } else {
                            setState(() => _fileSearchQuery = query);
                          }
                        },
                        onToggleSearch: () {
                          setState(() => _searchOpen = !_searchOpen);
                          if (!_searchOpen) {
                            _searchController.clear();
                          } else {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              _searchFocusNode.requestFocus();
                            });
                          }
                        },
                        onSettings: () => _showSettings(context),
                      ),
                      const SizedBox(height: 14),
                      Expanded(
                        child: _activeTool != null
                            ? OS26Glass(
                                radius: 18,
                                opacity: 0.42,
                                padding: EdgeInsets.zero,
                                child: WorkspaceToolsPage(
                                  tool: _activeTool!,
                                  onClose: () =>
                                      setState(() => _activeTool = null),
                                ),
                              )
                            : _fileSearchQuery != null
                            ? OS26Glass(
                                radius: 18,
                                opacity: 0.42,
                                padding: EdgeInsets.zero,
                                child: FileSearchResultsPage(
                                  query: _fileSearchQuery!,
                                  onClose: () => setState(() {
                                    _fileSearchQuery = null;
                                    _searchController.clear();
                                  }),
                                ),
                              )
                            : _mediaSearchQuery != null
                            ? OS26Glass(
                                radius: 18,
                                opacity: 0.42,
                                padding: EdgeInsets.zero,
                                child: MediaSearchResultsPage(
                                  query: _mediaSearchQuery!,
                                  onClose: () => setState(() {
                                    _mediaSearchQuery = null;
                                    _searchController.clear();
                                    ref
                                        .read(mediaLibraryProvider.notifier)
                                        .setSearchQuery('');
                                  }),
                                ),
                              )
                            : _mode == WorkspaceMode.cloud
                            ? _CloudWorkspace(
                                state: fp,
                                sidePanelOpen: _isSidePanelOpen,
                                onToggleSidePanel: () => setState(
                                  () => _isSidePanelOpen = !_isSidePanelOpen,
                                ),
                              )
                            : OS26Glass(
                                radius: 18,
                                opacity: 0.42,
                                padding: EdgeInsets.zero,
                                child: MediaLibraryPage(
                                  showLibrarySidebar: false,
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showSettings(BuildContext context) {
    showDialog(context: context, builder: (_) => const SettingsDialog());
  }
}

class _TopBar extends StatelessWidget {
  final WorkspaceMode mode;
  final ValueChanged<WorkspaceMode> onModeChanged;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final bool searchOpen;
  final ValueChanged<String> onSearch;
  final VoidCallback onToggleSearch;
  final VoidCallback onSettings;

  const _TopBar({
    required this.mode,
    required this.onModeChanged,
    required this.searchController,
    required this.searchFocusNode,
    required this.searchOpen,
    required this.onSearch,
    required this.onToggleSearch,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return SizedBox(
      height: 42,
      child: Row(
        children: [
          const SizedBox(width: 78),
          const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          OS26Glass(
            radius: 13,
            opacity: 0.42,
            padding: const EdgeInsets.all(3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SegmentButton(
                  icon: Icons.folder_rounded,
                  label: '光鸭云盘',
                  selected: mode == WorkspaceMode.cloud,
                  onTap: () => onModeChanged(WorkspaceMode.cloud),
                ),
                _SegmentButton(
                  icon: Icons.movie_rounded,
                  label: '光鸭影视',
                  selected: mode == WorkspaceMode.media,
                  onTap: () => onModeChanged(WorkspaceMode.media),
                ),
                ShadTooltip(
                  builder: (_) => const Text('设置'),
                  child: SizedBox(
                    width: 34,
                    height: 32,
                    child: GestureDetector(
                      onTap: onSettings,
                      child: Icon(
                        Icons.settings_rounded,
                        size: 17,
                        color: cs.mutedForeground,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: searchOpen ? 280 : 42,
            height: 42,
            child: OS26Glass(
              radius: 21,
              opacity: 0.52,
              padding: searchOpen
                  ? const EdgeInsets.symmetric(horizontal: 12)
                  : EdgeInsets.zero,
              child: searchOpen
                  ? Row(
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
                    )
                  : InkWell(
                      borderRadius: BorderRadius.circular(21),
                      onTap: onToggleSearch,
                      child: Icon(Icons.search_rounded, color: cs.foreground),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

void _showRenameDialog(BuildContext context, WidgetRef ref, CloudFile file) {
  final controller = TextEditingController(text: file.name);
  showShadDialog(
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
          onPressed: () {
            final name = controller.text.trim();
            if (name.isEmpty || name == file.name) return;
            ref.read(fileProvider.notifier).renameFile(file, name);
            Navigator.of(dialogContext).pop();
          },
          child: const Text('保存'),
        ),
      ],
      child: ShadInput(
        controller: controller,
        autofocus: true,
        placeholder: const Text('文件名称'),
      ),
    ),
  );
}

class _SegmentButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SegmentButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 126,
        height: 32,
        decoration: BoxDecoration(
          color: selected
              ? Colors.white.withValues(alpha: 0.74)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 15,
              color: selected ? cs.foreground : cs.mutedForeground,
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: selected ? cs.foreground : cs.mutedForeground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CloudSidebar extends StatelessWidget {
  final FileState state;
  final ValueChanged<WorkspaceSection> onSection;
  final VoidCallback onSettings;
  final VoidCallback onSignOut;
  final ValueChanged<WorkspaceTool> onTool;

  const _CloudSidebar({
    required this.state,
    required this.onSection,
    required this.onSettings,
    required this.onSignOut,
    required this.onTool,
  });

  @override
  Widget build(BuildContext context) {
    final sections = WorkspaceSection.values
        .where((section) => section != WorkspaceSection.mediaLibrary)
        .toList();
    return SizedBox(
      width: 250,
      child: OS26Glass(
        radius: 24,
        opacity: 0.56,
        padding: const EdgeInsets.fromLTRB(14, 18, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SidebarBrand(
              icon: Icons.cloud_sync_rounded,
              title: '光鸭云盘',
              subtitle: 'Cloud Workspace',
              imageAsset: 'assets/branding/guangya_icon.png',
            ),
            const SizedBox(height: 18),
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
                    selected: false,
                    onTap: () => onTool(WorkspaceTool.scan),
                  ),
                  _SidebarTile(
                    icon: Icons.text_fields_rounded,
                    label: '批量重命名',
                    selected: false,
                    onTap: () => onTool(WorkspaceTool.rename),
                  ),
                  _SidebarTile(
                    icon: Icons.bolt_rounded,
                    label: '秒传工具',
                    selected: false,
                    onTap: () => onTool(WorkspaceTool.fastTransfer),
                  ),
                ],
              ),
            ),
            _SidebarTile(
              icon: Icons.settings_rounded,
              label: '工作区设置',
              selected: false,
              onTap: onSettings,
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
  final VoidCallback onCreate;
  final ValueChanged<WorkspaceTool> onTool;

  const _MediaSidebar({required this.onCreate, required this.onTool});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(mediaLibraryProvider);
    final notifier = ref.read(mediaLibraryProvider.notifier);
    return SizedBox(
      width: 250,
      child: OS26Glass(
        radius: 24,
        opacity: 0.56,
        padding: const EdgeInsets.fromLTRB(14, 18, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SidebarBrand(
              icon: Icons.play_circle_fill_rounded,
              title: '光鸭影视',
              subtitle: 'Media Center',
            ),
            const SizedBox(height: 18),
            _SidebarTile(
              icon: Icons.home_rounded,
              label: '首页',
              selected: true,
              onTap: () => onTool(WorkspaceTool.tmdb),
            ),
            _SidebarTile(
              icon: Icons.movie_creation_rounded,
              label: '电影',
              count: state.statistics.movies,
              selected: false,
              onTap: () => onTool(WorkspaceTool.tmdb),
            ),
            _SidebarTile(
              icon: Icons.live_tv_rounded,
              label: '电视剧',
              count: state.statistics.series,
              selected: false,
              onTap: () {},
            ),
            _SidebarTile(
              icon: Icons.help_outline_rounded,
              label: '未识别',
              count: state.statistics.unmatched,
              selected: false,
              onTap: () {},
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 18, 8, 8),
              child: Text(
                '媒体库',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final library in state.libraries)
                    _SidebarTile(
                      icon: library.kind == MediaLibraryKind.series
                          ? Icons.live_tv_rounded
                          : Icons.smart_display_rounded,
                      label: library.name,
                      selected: state.selectedLibrary?.id == library.id,
                      onTap: () => notifier.selectLibrary(library.id),
                    ),
                ],
              ),
            ),
            _SidebarTile(
              icon: Icons.add_rounded,
              label: '新建媒体库',
              selected: false,
              onTap: onCreate,
            ),
            _SidebarTile(
              icon: Icons.auto_fix_high_rounded,
              label: 'TMDB 整理',
              selected: false,
              onTap: () => onTool(WorkspaceTool.tmdb),
            ),
            _SidebarTile(
              icon: Icons.category_rounded,
              label: '分类管理',
              selected: false,
              onTap: () => onTool(WorkspaceTool.categories),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarBrand extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? imageAsset;

  const _SidebarBrand({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.imageAsset,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Row(
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
                  letterSpacing: 1.6,
                  color: cs.mutedForeground,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SidebarTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  const _SidebarTile({
    required this.icon,
    required this.label,
    this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: selected
                ? const Color(0xFFFFB18A).withValues(alpha: 0.72)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: selected
                      ? Colors.white.withValues(alpha: 0.36)
                      : const Color(0xFFFFE4D2).withValues(alpha: 0.82),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 17, color: cs.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: selected ? cs.foreground : cs.mutedForeground,
                  ),
                ),
              ),
              if (count != null)
                Text(
                  count.toString(),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: cs.mutedForeground,
                  ),
                ),
            ],
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

  const _CloudWorkspace({
    required this.state,
    required this.sidePanelOpen,
    required this.onToggleSidePanel,
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
    return Row(
      children: [
        Expanded(
          child: OS26Glass(
            radius: 18,
            opacity: 0.42,
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                _CloudToolbar(
                  state: state,
                  paneMode: _paneMode,
                  onPaneModeChanged: (mode) => setState(() => _paneMode = mode),
                  viewMode: _primaryViewMode,
                  onViewModeChanged: (mode) =>
                      setState(() => _primaryViewMode = mode),
                  sidePanelOpen: widget.sidePanelOpen,
                  onToggleSidePanel: widget.onToggleSidePanel,
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: state.section == WorkspaceSection.files
                      ? _paneMode == _PaneLayoutMode.dual
                            ? Row(
                                children: [
                                  Expanded(
                                    child: _PrimaryFilePane(
                                      title: '左侧面板',
                                      state: state,
                                      viewMode: _primaryViewMode,
                                      onViewModeChanged: (mode) => setState(
                                        () => _primaryViewMode = mode,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  const Expanded(child: _SecondaryFilePane()),
                                ],
                              )
                            : _PrimaryFilePane(
                                title: '文件列表',
                                state: state,
                                viewMode: _primaryViewMode,
                                onViewModeChanged: (mode) =>
                                    setState(() => _primaryViewMode = mode),
                              )
                      : _PrimaryFilePane(
                          title: state.section.label,
                          state: state,
                          viewMode: _primaryViewMode,
                          onViewModeChanged: (mode) =>
                              setState(() => _primaryViewMode = mode),
                        ),
                ),
              ],
            ),
          ),
        ),
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
  }
}

class _CloudToolbar extends ConsumerWidget {
  final FileState state;
  final _PaneLayoutMode paneMode;
  final ValueChanged<_PaneLayoutMode> onPaneModeChanged;
  final _FileViewMode viewMode;
  final ValueChanged<_FileViewMode> onViewModeChanged;
  final bool sidePanelOpen;
  final VoidCallback onToggleSidePanel;

  const _CloudToolbar({
    required this.state,
    required this.paneMode,
    required this.onPaneModeChanged,
    required this.viewMode,
    required this.onViewModeChanged,
    required this.sidePanelOpen,
    required this.onToggleSidePanel,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(fileProvider.notifier);
    return Row(
      children: [
        const Spacer(),
        SortMenu(
          currentSort: state.serverSort,
          currentDirection: state.serverSortDirection,
          onSortChanged: notifier.setSort,
        ),
        const SizedBox(width: 8),
        _ToolbarSegment(value: paneMode, onChanged: onPaneModeChanged),
        const SizedBox(width: 8),
        _FileViewButtons(value: viewMode, onChanged: onViewModeChanged),
        const SizedBox(width: 8),
        _ToolbarButton(
          icon: Icons.upload_rounded,
          label: '上传',
          primary: true,
          onTap: () => _pickAndUpload(ref),
        ),
        const SizedBox(width: 6),
        _ToolbarButton(
          icon: Icons.create_new_folder_rounded,
          label: '新建文件夹',
          onTap: () => _showCreateFolderDialog(context, ref),
        ),
        _ToolbarButton(
          icon: Icons.refresh_rounded,
          label: '刷新',
          onTap: () => notifier.loadFiles(),
        ),
        _ToolbarButton(
          icon: Icons.more_horiz_rounded,
          label: sidePanelOpen ? '隐藏详情' : '显示详情',
          onTap: onToggleSidePanel,
        ),
      ],
    );
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
      icon: isDual ? Icons.view_agenda_rounded : Icons.view_column_rounded,
      label: isDual ? '切换单面板' : '切换双面板',
      onTap: () =>
          onChanged(isDual ? _PaneLayoutMode.single : _PaneLayoutMode.dual),
    );
  }
}

class _FileViewButtons extends StatelessWidget {
  final _FileViewMode value;
  final ValueChanged<_FileViewMode> onChanged;

  const _FileViewButtons({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ToolbarButton(
          icon: Icons.view_list_rounded,
          label: '列表显示',
          onTap: () => onChanged(_FileViewMode.list),
        ),
        _ToolbarButton(
          icon: Icons.view_column_rounded,
          label: 'Finder 分栏显示',
          onTap: () => onChanged(_FileViewMode.columns),
        ),
        _ToolbarButton(
          icon: Icons.grid_view_rounded,
          label: '网格显示',
          onTap: () => onChanged(_FileViewMode.grid),
        ),
      ],
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  const _ToolbarButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ShadTooltip(
      builder: (_) => Text(label),
      child: Padding(
        padding: const EdgeInsets.only(left: 6),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            constraints: BoxConstraints(minWidth: primary ? 72 : 38),
            height: 32,
            padding: EdgeInsets.symmetric(horizontal: primary ? 10 : 0),
            decoration: BoxDecoration(
              color: primary
                  ? cs.primary
                  : Colors.white.withValues(alpha: 0.46),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: primary
                    ? cs.primary
                    : Colors.white.withValues(alpha: 0.54),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: primary ? cs.primaryForeground : cs.mutedForeground,
                ),
                if (primary) ...[
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

class _PrimaryFilePane extends ConsumerWidget {
  final String title;
  final FileState state;
  final _FileViewMode viewMode;
  final ValueChanged<_FileViewMode> onViewModeChanged;

  const _PrimaryFilePane({
    required this.title,
    required this.state,
    required this.viewMode,
    required this.onViewModeChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (viewMode == _FileViewMode.columns) {
      return _ColumnFileBrowser(
        title: title,
        initialPath: state.folderPath,
        initialFiles: state.files,
        onViewModeChanged: onViewModeChanged,
      );
    }
    final notifier = ref.read(fileProvider.notifier);
    final files = state.files;
    return _FilePaneFrame(
      title: title,
      itemCount: files.length,
      isLoading: state.isLoading,
      errorMessage: state.errorMessage,
      emptyLabel: '没有文件',
      breadcrumbPath: state.folderPath,
      onBreadcrumbNavigate: (index) =>
          ref.read(fileProvider.notifier).navigateToPathIndex(index),
      header: const _FilePaneHeader(),
      dropParentID: state.folderPath.isEmpty ? null : state.folderPath.last.id,
      onMoveCloudFiles: (files, parentID) =>
          notifier.moveFilesTo(files, parentID: parentID),
      onUploadLocalFiles: (files, parentID) =>
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
      trailing: _PaneViewToggle(value: viewMode, onChanged: onViewModeChanged),
      child: RefreshIndicator(
        onRefresh: () => notifier.loadFiles(),
        child: _FilePaneCollection(
          viewMode: viewMode,
          itemCount: files.length,
          itemBuilder: (context, index) {
            final file = files[index];
            final selected = state.selectedIDs.contains(file.id);
            final tile = FileListTile(
              file: file,
              isSelected: selected,
              onSelect: () {
                if (file.isDirectory && !selected) {
                  notifier.navigateToFolder(file);
                } else {
                  notifier.toggleSelection(file.id);
                }
              },
              onOpen: file.isDirectory
                  ? () => notifier.navigateToFolder(file)
                  : () => _openCloudFile(context, ref, file),
              onRename: () => _showRenameDialog(context, ref, file),
              onCopy: () => notifier.copyToClipboard([file]),
              onCut: () => notifier.cutToClipboard([file]),
              onDownload: () => notifier.downloadFile(file),
              onShare: () => notifier.createShare(file),
              isRecycleItem: state.section == WorkspaceSection.recycle,
              onDelete: () => state.section == WorkspaceSection.recycle
                  ? notifier.restoreFiles([file])
                  : notifier.deleteFiles([file]),
            );
            final item = Draggable<_DraggedCloudFiles>(
              data: _DraggedCloudFiles([file], _PaneIdentity.primary),
              feedback: _DragFeedback(label: file.name),
              childWhenDragging: Opacity(opacity: 0.35, child: tile),
              child: tile,
            );
            if (viewMode == _FileViewMode.list) return item;
            return Draggable<_DraggedCloudFiles>(
              data: _DraggedCloudFiles([file], _PaneIdentity.primary),
              feedback: _DragFeedback(label: file.name),
              childWhenDragging: Opacity(
                opacity: 0.35,
                child: _FileGridCard(
                  file: file,
                  isSelected: selected,
                  onSelect: () {
                    if (file.isDirectory && !selected) {
                      notifier.navigateToFolder(file);
                    } else {
                      notifier.toggleSelection(file.id);
                    }
                  },
                  onOpen: file.isDirectory
                      ? () => notifier.navigateToFolder(file)
                      : () => _openCloudFile(context, ref, file),
                ),
              ),
              child: _FileGridCard(
                file: file,
                isSelected: selected,
                onSelect: () {
                  if (file.isDirectory && !selected) {
                    notifier.navigateToFolder(file);
                  } else {
                    notifier.toggleSelection(file.id);
                  }
                },
                onOpen: file.isDirectory
                    ? () => notifier.navigateToFolder(file)
                    : () => _openCloudFile(context, ref, file),
              ),
            );
          },
        ),
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

class _FilePaneCollection extends StatelessWidget {
  final _FileViewMode viewMode;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  const _FilePaneCollection({
    required this.viewMode,
    required this.itemCount,
    required this.itemBuilder,
  });

  @override
  Widget build(BuildContext context) {
    if (viewMode == _FileViewMode.list) {
      return ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: itemCount,
        itemBuilder: itemBuilder,
      );
    }
    assert(viewMode == _FileViewMode.grid);
    return GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 168,
        mainAxisExtent: 132,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: itemCount,
      itemBuilder: itemBuilder,
    );
  }
}

class _ColumnListing {
  final String? parentID;
  final String title;
  final List<CloudFile> files;
  final bool isLoading;
  final String? errorMessage;
  final String? selectedID;

  const _ColumnListing({
    required this.parentID,
    required this.title,
    this.files = const [],
    this.isLoading = false,
    this.errorMessage,
    this.selectedID,
  });

  _ColumnListing copyWith({
    List<CloudFile>? files,
    bool? isLoading,
    String? errorMessage,
    bool clearError = false,
    String? selectedID,
    bool clearSelection = false,
  }) {
    return _ColumnListing(
      parentID: parentID,
      title: title,
      files: files ?? this.files,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      selectedID: clearSelection ? null : (selectedID ?? this.selectedID),
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
  final ValueChanged<List<CloudFile>>? onPathChanged;

  const _ColumnFileBrowser({
    required this.title,
    required this.initialPath,
    required this.initialFiles,
    required this.onViewModeChanged,
    this.source = _PaneIdentity.primary,
    this.onMoveCloudFiles,
    this.onUploadLocalFiles,
    this.onPathChanged,
  });

  @override
  ConsumerState<_ColumnFileBrowser> createState() => _ColumnFileBrowserState();
}

class _ColumnFileBrowserState extends ConsumerState<_ColumnFileBrowser> {
  List<_ColumnListing> _columns = const [];
  List<CloudFile> _path = const [];
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    _restorePath(widget.initialPath, initialFiles: widget.initialFiles);
  }

  @override
  void didUpdateWidget(covariant _ColumnFileBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_samePath(_path, widget.initialPath)) {
      _restorePath(widget.initialPath, initialFiles: widget.initialFiles);
    }
  }

  bool _samePath(List<CloudFile> a, List<CloudFile> b) {
    return a.length == b.length &&
        Iterable.generate(
          a.length,
        ).every((index) => a[index].id == b[index].id);
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
    await _loadColumn(0, generation: generation);
    for (var index = 0; index < restoredPath.length; index++) {
      if (!mounted || generation != _generation) return;
      final folder = restoredPath[index];
      setState(() {
        final columns = _columns.toList();
        columns[index] = columns[index].copyWith(selectedID: folder.id);
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
      columns[index] = columns[index].copyWith(selectedID: folder.id);
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
    _notifyPathChanged(path);
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
    final onMoveCloudFiles = widget.onMoveCloudFiles;
    if (onMoveCloudFiles != null) {
      await onMoveCloudFiles(files, parentID);
    } else {
      await ref
          .read(fileProvider.notifier)
          .moveFilesTo(files, parentID: parentID);
    }
    if (mounted) await _loadColumn(index);
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
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            height: constraints.maxHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = 0; index < _columns.length; index++)
                  _FinderColumn(
                    key: ValueKey('${_columns[index].parentID}-$index'),
                    column: _columns[index],
                    source: widget.source,
                    onOpenFolder: (folder) => _openFolder(index, folder),
                    onOpenFile: (file) => _openCloudFile(context, ref, file),
                    onMoveCloudFiles: (files, parentID) =>
                        _moveFiles(files, parentID, index),
                    onUploadLocalFiles: (files, parentID) =>
                        _uploadFiles(files, parentID, index),
                  ),
              ],
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
  final ValueChanged<CloudFile> onOpenFolder;
  final ValueChanged<CloudFile> onOpenFile;
  final Future<void> Function(List<CloudFile> files, String? parentID)
  onMoveCloudFiles;
  final Future<void> Function(List<File> files, String? parentID)
  onUploadLocalFiles;

  const _FinderColumn({
    super.key,
    required this.column,
    required this.source,
    required this.onOpenFolder,
    required this.onOpenFile,
    required this.onMoveCloudFiles,
    required this.onUploadLocalFiles,
  });

  @override
  State<_FinderColumn> createState() => _FinderColumnState();
}

class _FinderColumnState extends State<_FinderColumn> {
  var _dragActive = false;

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final column = widget.column;
    return SizedBox(
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
          onWillAcceptWithDetails: (_) => true,
          onAcceptWithDetails: (details) async {
            setState(() => _dragActive = false);
            await widget.onMoveCloudFiles(details.data.files, column.parentID);
          },
          onLeave: (_) => setState(() => _dragActive = false),
          builder: (context, candidates, rejected) => AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              color: _dragActive || candidates.isNotEmpty
                  ? cs.primary.withValues(alpha: 0.10)
                  : Colors.white.withValues(alpha: 0.22),
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
                  alignment: Alignment.centerLeft,
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
                Divider(height: 1, color: cs.border.withValues(alpha: 0.60)),
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
                            final selected = column.selectedID == file.id;
                            final row = _FinderColumnItem(
                              file: file,
                              selected: selected,
                              onTap: () {
                                if (file.isDirectory) {
                                  widget.onOpenFolder(file);
                                }
                              },
                              onOpen: () {
                                if (file.isDirectory) {
                                  widget.onOpenFolder(file);
                                } else {
                                  widget.onOpenFile(file);
                                }
                              },
                            );
                            return Draggable<_DraggedCloudFiles>(
                              data: _DraggedCloudFiles([file], widget.source),
                              feedback: _DragFeedback(label: file.name),
                              childWhenDragging: Opacity(
                                opacity: 0.35,
                                child: row,
                              ),
                              child: row,
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
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
            color: isSelected
                ? cs.primary.withValues(alpha: 0.12)
                : Colors.white.withValues(alpha: 0.34),
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
                file.isDirectory && file.subFileCount != null
                    ? '${file.formattedSize} · ${file.subFileCount} 项'
                    : file.formattedSize,
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

  Future<void> _moveCloudFiles(List<CloudFile> files, String? parentID) async {
    if (files.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(authProvider.notifier).api;
      await api.fsMove(
        files.map((file) => file.id).toList(),
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
      final api = ref.read(authProvider.notifier).api;
      for (final file in files) {
        if (await file.exists()) {
          await api.fileUpload(file, parentID: parentID);
        }
      }
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
          const Expanded(child: _FilePaneHeader()),
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
          itemBuilder: (context, index) {
            final file = _files[index];
            final row = FileListTile(
              file: file,
              onSelect: () {
                if (file.isDirectory) {
                  setState(() {
                    _path.add(file);
                    _page = 0;
                  });
                  _load(parentID: file.id);
                } else {
                  _openCloudFile(context, ref, file);
                }
              },
              onOpen: () {
                if (file.isDirectory) {
                  setState(() {
                    _path.add(file);
                    _page = 0;
                  });
                  _load(parentID: file.id);
                } else {
                  _openCloudFile(context, ref, file);
                }
              },
              onCopy: () =>
                  ref.read(fileProvider.notifier).copyToClipboard([file]),
              onCut: () =>
                  ref.read(fileProvider.notifier).cutToClipboard([file]),
              onRename: () => _showRenameDialog(context, ref, file),
              onDownload: () =>
                  ref.read(fileProvider.notifier).downloadFile(file),
              onShare: () => ref.read(fileProvider.notifier).createShare(file),
              onDelete: () =>
                  ref.read(fileProvider.notifier).deleteFiles([file]),
            );
            if (_viewMode == _FileViewMode.list) {
              return Draggable<_DraggedCloudFiles>(
                data: _DraggedCloudFiles([file], _PaneIdentity.secondary),
                feedback: _DragFeedback(label: file.name),
                childWhenDragging: Opacity(opacity: 0.35, child: row),
                child: row,
              );
            }
            void open() {
              if (file.isDirectory) {
                setState(() {
                  _path.add(file);
                  _page = 0;
                });
                _load(parentID: file.id);
              } else {
                _openCloudFile(context, ref, file);
              }
            }

            final card = _FileGridCard(
              file: file,
              onSelect: open,
              onOpen: open,
            );
            return Draggable<_DraggedCloudFiles>(
              data: _DraggedCloudFiles([file], _PaneIdentity.secondary),
              feedback: _DragFeedback(label: file.name),
              childWhenDragging: Opacity(opacity: 0.35, child: card),
              child: card,
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
          Icon(
            Icons.insert_drive_file_rounded,
            size: 14,
            color: cs.mutedForeground,
          ),
          const SizedBox(width: 5),
          Text(
            '本页文件 $fileCount',
            style: TextStyle(fontSize: 11, color: cs.mutedForeground),
          ),
          const SizedBox(width: 12),
          Icon(Icons.folder_rounded, size: 14, color: cs.mutedForeground),
          const SizedBox(width: 5),
          Text(
            '本页文件夹 $folderCount',
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
          color: Colors.white.withValues(alpha: 0.42),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.62)),
        ),
        child: Column(
          children: [
            Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: cs.foreground,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$itemCount 项',
                    style: TextStyle(fontSize: 11, color: cs.mutedForeground),
                  ),
                  const Spacer(),
                  if (trailing case final Widget trailing) trailing,
                ],
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
    final cs = ShadTheme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: cs.mutedForeground,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '正在加载文件夹内容...',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: cs.foreground,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '正在同步文件、大小和修改时间',
            style: TextStyle(fontSize: 12, color: cs.mutedForeground),
          ),
        ],
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
  const _FilePaneHeader();

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
        ],
      ),
    );
  }
}
