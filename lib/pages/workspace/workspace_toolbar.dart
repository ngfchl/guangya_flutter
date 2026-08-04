part of '../workspace_page.dart';

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
