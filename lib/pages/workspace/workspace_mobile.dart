part of '../workspace_page.dart';

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
