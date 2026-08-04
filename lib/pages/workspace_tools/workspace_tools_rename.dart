part of '../workspace_tools_page.dart';

class _RenameRuleIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool enabled;
  final bool destructive;
  final VoidCallback onPressed;

  const _RenameRuleIconButton({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onPressed,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ShadTooltip(
      builder: (_) => Text(tooltip),
      child: ShadButton.ghost(
        size: ShadButtonSize.sm,
        onPressed: enabled ? onPressed : null,
        child: Icon(icon, size: 16, color: destructive ? cs.destructive : null),
      ),
    );
  }
}
