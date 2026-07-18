import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import '../models/cloud_file.dart';

class BreadcrumbBar extends StatelessWidget {
  final List<CloudFile> path;
  final ValueChanged<int> onNavigate;

  const BreadcrumbBar({
    super.key,
    required this.path,
    required this.onNavigate,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;

    final items = <Widget>[
      // Home button
      GestureDetector(
        onTap: () => onNavigate(-1),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: path.isEmpty ? cs.primary.withAlpha(15) : null,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '云盘',
              style: TextStyle(
                fontSize: 13,
                fontWeight: path.isEmpty ? FontWeight.w600 : FontWeight.normal,
                color: path.isEmpty ? cs.primary : cs.mutedForeground,
              ),
            ),
          ),
        ),
      ),
    ];

    for (int i = 0; i < path.length; i++) {
      final isLast = i == path.length - 1;
      items.add(
        Icon(
          Icons.chevron_right_rounded,
          size: 16,
          color: cs.mutedForeground.withAlpha(100),
        ),
      );
      items.add(
        GestureDetector(
          onTap: isLast ? null : () => onNavigate(i),
          child: MouseRegion(
            cursor: isLast
                ? SystemMouseCursors.basic
                : SystemMouseCursors.click,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isLast ? cs.primary.withAlpha(15) : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                path[i].name,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isLast ? FontWeight.w600 : FontWeight.normal,
                  color: isLast ? cs.primary : cs.mutedForeground,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.start,
          children: items,
        ),
      ),
    );
  }
}
