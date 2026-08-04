part of '../workspace_page.dart';

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
      height: compact ? 48 : 46,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          compact ? 10 : 14,
          compact ? 15 : 14,
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
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                Icons.video_library_rounded,
                size: compact ? 20 : 19,
                color: cs.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  // mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: compact ? 15 : 14,
                        height: 1.15,
                        fontWeight: FontWeight.w700,
                        color: cs.foreground,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.15,
                        color: cs.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 6),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: cs.mutedForeground,
                ),
              ],
            ],
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
            onPressed: () => ref
                .read(mediaLibraryProvider.notifier)
                .cancelScan(
                  libraryID:
                      widget.state.selectedLibrary?.id ?? globalMediaLibraryID,
                ),
            child: const Icon(Icons.stop_rounded, size: 18),
          ),
        );
      }
      return ShadButton.destructive(
        width: 38,
        height: 36,
        padding: EdgeInsets.zero,
        onPressed: () => ref
            .read(mediaLibraryProvider.notifier)
            .cancelScan(
              libraryID:
                  widget.state.selectedLibrary?.id ?? globalMediaLibraryID,
            ),
        child: const Icon(Icons.stop_rounded, size: 18),
      );
    }
    return MediaScanMenu(
      compact: widget.compact,
      iconOnly: true,
      disabled: widget.state.selectedLibrary == null,
      controller: _controller,
      onScanUnrecognized: widget.state.selectedLibrary == null
          ? () => ref
                .read(mediaLibraryProvider.notifier)
                .scanGlobalLibrary(mode: MediaLibraryScanMode.unrecognizedOnly)
          : () => ref
                .read(mediaLibraryProvider.notifier)
                .rescanSelectedLibrary(
                  mode: MediaLibraryScanMode.unrecognizedOnly,
                ),
      onScanUnindexed: widget.state.selectedLibrary == null
          ? () => ref
                .read(mediaLibraryProvider.notifier)
                .scanGlobalLibrary(mode: MediaLibraryScanMode.unindexedOnly)
          : () => ref
                .read(mediaLibraryProvider.notifier)
                .rescanSelectedLibrary(
                  mode: MediaLibraryScanMode.unindexedOnly,
                ),
      onForceAll: widget.state.selectedLibrary == null
          ? () => ref
                .read(mediaLibraryProvider.notifier)
                .scanGlobalLibrary(mode: MediaLibraryScanMode.forceAll)
          : () => ref
                .read(mediaLibraryProvider.notifier)
                .rescanSelectedLibrary(mode: MediaLibraryScanMode.forceAll),
    );
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
              padding: EdgeInsets.fromLTRB(12, showBrand ? 14 : 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showBrand) ...[
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
                    selected:
                        selectedFilter == MediaLibraryBrowseFilter.unmatched,
                    onTap: () => onFilter(MediaLibraryBrowseFilter.unmatched),
                  ),
                  const SizedBox(height: 8),
                  if (_shouldShowLibrarySection(state)) ...[
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
                                  subtitle: _mediaLibraryStatisticsLabel(
                                    statistics,
                                  ),
                                  selected:
                                      !homeSelected &&
                                      selectedFilter ==
                                          MediaLibraryBrowseFilter.all &&
                                      state.selectedLibrary?.id == library.id,
                                  onTap: () => onSelectLibrary(library.id),
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                  ],
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
          ),
        ],
      ),
    );
  }
}

bool _shouldShowLibrarySection(MediaLibraryState state) {
  if (state.libraries.isEmpty) return false;
  if (state.libraries.length == 1 &&
      state.libraries.first.id == globalMediaLibraryID) {
    return false;
  }
  return true;
}
