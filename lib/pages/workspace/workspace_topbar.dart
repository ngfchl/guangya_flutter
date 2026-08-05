part of '../workspace_page.dart';

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
  final VoidCallback? onToggleFilter;
  final bool filterActive;

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
    this.onToggleFilter,
    this.filterActive = false,
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
                        style: TextStyle(color: cs.foreground, fontSize: 13),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          isDense: true,
                          hintText: mode == WorkspaceMode.cloud
                              ? '搜索文件'
                              : '搜索影视资源',
                          hintStyle: TextStyle(
                            color: cs.mutedForeground,
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
      height: 46,
      child: const DragToMoveArea(child: SizedBox.expand()),
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
      height: compact ? 42 : 38,
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
              key: const ValueKey('media-top-search-field'),
              controller: searchController,
              focusNode: searchFocusNode,
              autofocus: true,
              enabled: true,
              readOnly: false,
              style: TextStyle(color: cs.foreground, fontSize: 13),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                hintText: '搜索影视资源',
                hintStyle: TextStyle(color: cs.mutedForeground, fontSize: 13),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: onSearch,
            ),
          ),
          _TopBarIconButton(
            tooltip: '搜索',
            icon: Icons.search_rounded,
            onTap: () => onSearch(searchController.text),
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
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 5, 10, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
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
            Expanded(
              child: searchOpen
                  ? searchField
                  : Align(
                      alignment: Alignment.centerLeft,
                      child: identity,
                    ),
            ),
            if (!searchOpen) ...[
              const SizedBox(width: 4),
              if (mediaHomeSelected ||
                  mediaFilter == MediaLibraryBrowseFilter.movies ||
                  mediaFilter == MediaLibraryBrowseFilter.series ||
                  mediaFilter == MediaLibraryBrowseFilter.unmatched) ...[
                _GlobalScanTopAction(compact: true),
                const SizedBox(width: 4),
              ],
              if (!mediaHomeSelected) ...[
                _MediaSortTopAction(
                  selected: mediaState.sort,
                  direction: mediaState.sortDirection,
                  onSelected: onMediaSortChanged,
                  onDirectionSelected: onMediaSortDirectionChanged,
                ),
                const SizedBox(width: 4),
              ],
              if (onToggleFilter != null) ...[
                _TopBarIconButton(
                  tooltip: '筛选影视库',
                  icon: Icons.filter_alt_rounded,
                  color: filterActive ? cs.primary : null,
                  onTap: onToggleFilter,
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
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 640;
        final compactActions = constraints.maxWidth < 1360;
        return SizedBox(
          height: 46,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  flex: narrow ? 2 : 3,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: identity,
                  ),
                ),
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
                if (mediaHomeSelected ||
                    mediaFilter == MediaLibraryBrowseFilter.movies ||
                    mediaFilter == MediaLibraryBrowseFilter.series ||
                    mediaFilter == MediaLibraryBrowseFilter.unmatched) ...[
                  _GlobalScanTopAction(compact: false),
                  const SizedBox(width: 4),
                ],
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
                  width: searchOpen
                      ? (narrow ? 220 : 360)
                      : (onToggleFilter != null ? 84 : 40),
                  height: 38,
                  child: searchOpen
                      ? searchField
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (onToggleFilter != null) ...[
                              _TopBarIconButton(
                                tooltip: '筛选影视库',
                                icon: Icons.filter_alt_rounded,
                                color: filterActive ? cs.primary : null,
                                onTap: onToggleFilter,
                              ),
                              const SizedBox(width: 4),
                            ],
                            _TopBarIconButton(
                              tooltip: '搜索影视资源',
                              icon: Icons.search_rounded,
                              onTap: onToggleSearch,
                            ),
                          ],
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
