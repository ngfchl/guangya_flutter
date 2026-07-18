import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:window_manager/window_manager.dart';

import '../app/app_theme.dart';
import '../models/cloud_file.dart';
import '../models/media_library.dart';
import '../providers/auth_provider.dart';
import '../providers/file_provider.dart';
import '../providers/media_library_provider.dart';
import '../widgets/breadcrumb_bar.dart';
import '../widgets/file_list_tile.dart';
import '../widgets/side_panel.dart';
import '../widgets/sort_menu.dart';
import 'media_library_page.dart';
import 'search_results_page.dart';
import 'settings_page.dart';
import 'workspace_tools_page.dart';

enum WorkspaceMode { cloud, media }

enum _PaneLayoutMode { single, dual }

enum _PaneIdentity { primary, secondary }

class _DraggedCloudFiles {
  final List<CloudFile> files;
  final _PaneIdentity source;

  const _DraggedCloudFiles(this.files, this.source);
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

  const _TopBar({
    required this.mode,
    required this.onModeChanged,
    required this.searchController,
    required this.searchFocusNode,
    required this.searchOpen,
    required this.onSearch,
    required this.onToggleSearch,
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
              onTap: () => onTool(WorkspaceTool.tmdb),
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

  const _SidebarBrand({
    required this.icon,
    required this.title,
    required this.subtitle,
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
            color: cs.primary,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: cs.primary.withValues(alpha: 0.24),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Icon(icon, color: Colors.white, size: 26),
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
  _PaneLayoutMode _paneMode = _PaneLayoutMode.dual;

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
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  const Expanded(child: _SecondaryFilePane()),
                                ],
                              )
                            : _PrimaryFilePane(title: '文件列表', state: state)
                      : _PrimaryFilePane(
                          title: state.section.label,
                          state: state,
                        ),
                ),
                _CloudStatusBar(state: state),
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
  final bool sidePanelOpen;
  final VoidCallback onToggleSidePanel;

  const _CloudToolbar({
    required this.state,
    required this.paneMode,
    required this.onPaneModeChanged,
    required this.sidePanelOpen,
    required this.onToggleSidePanel,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(fileProvider.notifier);
    return Row(
      children: [
        Expanded(
          child: BreadcrumbBar(
            path: state.folderPath,
            onNavigate: notifier.navigateToPathIndex,
          ),
        ),
        SortMenu(
          currentSort: state.serverSort,
          currentDirection: state.serverSortDirection,
          onSortChanged: notifier.setSort,
        ),
        const SizedBox(width: 8),
        _ToolbarSegment(value: paneMode, onChanged: onPaneModeChanged),
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
    return OS26Glass(
      radius: 10,
      opacity: 0.36,
      padding: const EdgeInsets.all(2),
      child: Row(
        children: [
          _ToolbarSegmentButton(
            icon: Icons.view_agenda_rounded,
            selected: value == _PaneLayoutMode.single,
            tooltip: '单面板',
            onTap: () => onChanged(_PaneLayoutMode.single),
          ),
          _ToolbarSegmentButton(
            icon: Icons.view_column_rounded,
            selected: value == _PaneLayoutMode.dual,
            tooltip: '双面板',
            onTap: () => onChanged(_PaneLayoutMode.dual),
          ),
        ],
      ),
    );
  }
}

class _ToolbarSegmentButton extends StatelessWidget {
  final IconData icon;
  final bool selected;
  final String tooltip;
  final VoidCallback onTap;

  const _ToolbarSegmentButton({
    required this.icon,
    required this.selected,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ShadTooltip(
      builder: (_) => Text(tooltip),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          width: 32,
          height: 28,
          decoration: BoxDecoration(
            color: selected
                ? Colors.white.withValues(alpha: 0.68)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 17,
            color: selected ? cs.primary : cs.mutedForeground,
          ),
        ),
      ),
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

  const _PrimaryFilePane({required this.title, required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
      onPreviousPage: state.currentPage == 0 ? null : notifier.prevPage,
      onNextPage: state.currentPage >= state.totalPages - 1
          ? null
          : notifier.nextPage,
      onPageSizeChanged: notifier.setPageSize,
      child: RefreshIndicator(
        onRefresh: () => notifier.loadFiles(),
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
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
                  : () => notifier.downloadFile(file),
              onRename: () {},
              onCopy: () => notifier.copyToClipboard([file]),
              onCut: () => notifier.cutToClipboard([file]),
              onDownload: () => notifier.downloadFile(file),
              onShare: () {},
              onDelete: () => notifier.deleteFiles([file]),
            );
            return Draggable<_DraggedCloudFiles>(
              data: _DraggedCloudFiles([file], _PaneIdentity.primary),
              feedback: _DragFeedback(label: file.name),
              childWhenDragging: Opacity(opacity: 0.35, child: tile),
              child: tile,
            );
          },
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

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load({String? parentID}) async {
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
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
      child: RefreshIndicator(
        onRefresh: () => _load(parentID: _currentParentID),
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
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
                  ref.read(fileProvider.notifier).downloadFile(file);
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
                  ref.read(fileProvider.notifier).downloadFile(file);
                }
              },
              onCopy: () =>
                  ref.read(fileProvider.notifier).copyToClipboard([file]),
              onCut: () =>
                  ref.read(fileProvider.notifier).cutToClipboard([file]),
              onDownload: () =>
                  ref.read(fileProvider.notifier).downloadFile(file),
              onDelete: () =>
                  ref.read(fileProvider.notifier).deleteFiles([file]),
            );
            return Draggable<_DraggedCloudFiles>(
              data: _DraggedCloudFiles([file], _PaneIdentity.secondary),
              feedback: _DragFeedback(label: file.name),
              childWhenDragging: Opacity(opacity: 0.35, child: row),
              child: row,
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
  final VoidCallback? onPreviousPage;
  final VoidCallback? onNextPage;
  final ValueChanged<int>? onPageSizeChanged;

  const _PanePagination({
    required this.currentPage,
    required this.pageSize,
    required this.totalPages,
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
  final int itemCount;
  final bool isLoading;
  final String? errorMessage;
  final String emptyLabel;
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
  final VoidCallback? onPreviousPage;
  final VoidCallback? onNextPage;
  final ValueChanged<int>? onPageSizeChanged;

  const _FilePaneFrame({
    required this.title,
    required this.itemCount,
    required this.isLoading,
    required this.errorMessage,
    required this.emptyLabel,
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
                  : itemCount == 0
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
      child: OS26Glass(
        radius: 12,
        opacity: 0.52,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ShadProgress(),
            const SizedBox(height: 10),
            Text(
              '加载中',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: cs.mutedForeground,
              ),
            ),
          ],
        ),
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

class _CloudStatusBar extends StatelessWidget {
  final FileState state;

  const _CloudStatusBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      height: 40,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.insert_drive_file_rounded,
            size: 15,
            color: cs.mutedForeground,
          ),
          const SizedBox(width: 6),
          Text(
            '本页文件 ${state.files.where((file) => !file.isDirectory).length}',
            style: TextStyle(fontSize: 12, color: cs.mutedForeground),
          ),
          const SizedBox(width: 14),
          Icon(Icons.folder_rounded, size: 15, color: cs.mutedForeground),
          const SizedBox(width: 6),
          Text(
            '本页文件夹 ${state.files.where((file) => file.isDirectory).length}',
            style: TextStyle(fontSize: 12, color: cs.mutedForeground),
          ),
          const Spacer(),
          if (state.errorMessage != null)
            Text(
              state.errorMessage!,
              style: TextStyle(fontSize: 12, color: cs.destructive),
              overflow: TextOverflow.ellipsis,
            )
          else if (state.statusMessage != null)
            Text(
              state.statusMessage!,
              style: TextStyle(fontSize: 12, color: cs.primary),
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}
