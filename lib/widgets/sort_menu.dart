import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import '../providers/file_provider.dart';

class SortMenu extends StatelessWidget {
  final FileSort currentSort;
  final SortDirection currentDirection;
  final ValueChanged<FileSort> onSortChanged;

  const SortMenu({
    super.key,
    required this.currentSort,
    required this.currentDirection,
    required this.onSortChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;

    return ShadButton.ghost(
      onPressed: () => _showSortMenu(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.sort_rounded, size: 16, color: cs.mutedForeground),
          const SizedBox(width: 4),
          Text('排序', style: TextStyle(fontSize: 13, color: cs.mutedForeground)),
        ],
      ),
    );
  }

  void _showSortMenu(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;

    showModalBottomSheet(
      context: context,
      builder: (ctx) => Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Text('排序方式',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.foreground)),
                  const Spacer(),
                  Text('当前: ${currentSort.title}',
                      style: TextStyle(fontSize: 12, color: cs.mutedForeground)),
                ],
              ),
            ),
            const ShadSeparator.horizontal(),
            for (final sort in FileSort.values)
              ListTile(
                dense: true,
                leading: currentSort == sort
                    ? Icon(Icons.check_rounded, size: 16, color: cs.primary)
                    : const SizedBox(width: 16),
                title: Text(
                  sort.title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: currentSort == sort ? FontWeight.w600 : FontWeight.normal,
                    color: currentSort == sort ? cs.primary : cs.foreground,
                  ),
                ),
                trailing: currentSort == sort
                    ? Icon(
                        currentDirection == SortDirection.ascending
                            ? Icons.arrow_upward_rounded
                            : Icons.arrow_downward_rounded,
                        size: 14,
                        color: cs.primary,
                      )
                    : null,
                onTap: () {
                  Navigator.of(ctx).pop();
                  onSortChanged(sort);
                },
              ),
          ],
        ),
      ),
    );
  }
}
