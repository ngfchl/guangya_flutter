part of '../workspace_page.dart';

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
  final bool collapsed;
  final VoidCallback? onToggleCollapsed;

  const _SidebarBrand({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.imageAsset,
    this.onSwitchMode,
    this.onSettings,
    this.collapsed = false,
    this.onToggleCollapsed,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = ShadTheme.of(context).colorScheme;
    final hasAppUpgrade =
        ref.watch(appUpgradeStatusProvider).value?.hasNewVersion == true;
    final logo = Container(
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
    );
    if (collapsed) {
      return Column(
        children: [
          Semantics(
            button: onSwitchMode != null,
            label: onSwitchMode == null ? title : '$title，点击切换工作区',
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onSwitchMode,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: logo,
                ),
              ),
            ),
          ),
          if (onToggleCollapsed != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _TopBarIconButton(
                tooltip: '展开侧边栏',
                icon: Icons.chevron_right_rounded,
                onTap: onToggleCollapsed,
              ),
            ),
        ],
      );
    }
    final brand = Row(
      children: [
        logo,
        const SizedBox(width: 12),
        Expanded(
          // FittedBox(scaleDown) 让标题在缩放后自适应填满，不溢出不错位——
          // 全局 Transform.scale 缩小时标题会按放大布局空间布局再缩回，
          // 文字与 logo 错位；FittedBox 让标题区整体缩放保持对齐。
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
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
        if (onToggleCollapsed != null)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: _TopBarIconButton(
              tooltip: '收起侧边栏',
              icon: Icons.chevron_left_rounded,
              onTap: onToggleCollapsed,
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
  final bool collapsed;
  final VoidCallback onTap;

  const _SidebarTile({
    required this.icon,
    required this.label,
    this.subtitle,
    this.count,
    required this.selected,
    this.collapsed = false,
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
    if (collapsed) {
      return Semantics(
        button: true,
        selected: selected,
        label: semanticsLabel,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Material(
            color: Colors.transparent,
            child: RemoteFocusableButton(
              onTap: onTap,
              child: InkWell(
                borderRadius: BorderRadius.circular(7),
                overlayColor: WidgetStatePropertyAll(
                  cs.foreground.withValues(alpha: 0.05),
                ),
                onTap: onTap,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected
                        ? cs.primary.withValues(alpha: 0.12)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Icon(
                    icon,
                    size: 20,
                    color: selected ? cs.primary : cs.mutedForeground,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Semantics(
      button: true,
      selected: selected,
      label: semanticsLabel,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Material(
          color: Colors.transparent,
          child: RemoteFocusableButton(
            onTap: onTap,
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
      ),
    );
  }
}
