import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import '../providers/file_provider.dart';

class SortMenu extends StatelessWidget {
  final FileSort currentSort;
  final SortDirection currentDirection;
  final ValueChanged<FileSort> onSortChanged;
  final VoidCallback onDirectionToggle;

  const SortMenu({
    super.key,
    required this.currentSort,
    required this.currentDirection,
    required this.onSortChanged,
    required this.onDirectionToggle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: cs.secondary,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 126,
            child: ShadSelect<FileSort>(
              key: ValueKey('$currentSort:$currentDirection'),
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
          ),
          Container(width: 1, height: 20, color: cs.border),
          ShadTooltip(
            builder: (_) =>
                Text(currentDirection == SortDirection.ascending ? '升序' : '降序'),
            child: InkWell(
              onTap: onDirectionToggle,
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 34,
                child: Icon(
                  currentDirection == SortDirection.ascending
                      ? Icons.arrow_upward_rounded
                      : Icons.arrow_downward_rounded,
                  size: 16,
                  color: cs.mutedForeground,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
