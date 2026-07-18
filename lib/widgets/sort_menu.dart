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
    return SizedBox(
      width: 124,
      child: ShadSelect<FileSort>(
        initialValue: currentSort,
        selectedOptionBuilder: (context, value) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sort_rounded, size: 15, color: cs.mutedForeground),
            const SizedBox(width: 5),
            Text(
              value.title,
              style: TextStyle(fontSize: 12, color: cs.foreground),
            ),
          ],
        ),
        options: [
          for (final sort in FileSort.values)
            ShadOption(
              value: sort,
              child: Row(
                children: [
                  Expanded(child: Text(sort.title)),
                  if (currentSort == sort)
                    Icon(
                      currentDirection == SortDirection.ascending
                          ? Icons.arrow_upward_rounded
                          : Icons.arrow_downward_rounded,
                      size: 14,
                      color: cs.primary,
                    ),
                ],
              ),
            ),
        ],
        onChanged: (value) {
          if (value != null) onSortChanged(value);
        },
      ),
    );
  }
}
