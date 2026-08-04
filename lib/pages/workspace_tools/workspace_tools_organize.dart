part of '../workspace_tools_page.dart';

class _OrganizerMetric extends StatelessWidget {
  final IconData icon;
  final String label;

  const _OrganizerMetric({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: cs.mutedForeground),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: cs.mutedForeground),
            ),
          ),
        ],
      ),
    );
  }
}
