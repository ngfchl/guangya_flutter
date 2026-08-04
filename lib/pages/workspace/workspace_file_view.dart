part of '../workspace_page.dart';

enum _PaneLayoutMode { single, dual }

enum _FileViewMode { list, columns, grid }

enum _PaneIdentity { primary, secondary }

bool get _isMobilePlatform => switch (defaultTargetPlatform) {
  TargetPlatform.android || TargetPlatform.iOS => true,
  _ => false,
};

bool get _isDesktopWindow =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

double get _desktopSidebarTopGap => Platform.isMacOS ? 20 : 32;

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

class _FileGridCard extends StatelessWidget {
  final CloudFile file;
  final bool isSelected;
  final VoidCallback onSelect;
  final VoidCallback? onLongPress;
  final VoidCallback onOpen;

  const _FileGridCard({
    required this.file,
    required this.onSelect,
    this.onLongPress,
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
        onLongPress: onLongPress,
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

class _PanePagination extends StatelessWidget {
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
              for (final size in supportedFilePageSizes)
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
