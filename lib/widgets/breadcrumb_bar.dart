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
      _BreadcrumbItem(
        label: '云盘根目录',
        text: '云盘',
        selected: path.isEmpty,
        enabled: true,
        onTap: () => onNavigate(-1),
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
        _BreadcrumbItem(
          label: path[i].name,
          text: path[i].name,
          selected: isLast,
          enabled: !isLast,
          onTap: () => onNavigate(i),
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

class _BreadcrumbItem extends StatelessWidget {
  final String label;
  final String text;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _BreadcrumbItem({
    required this.label,
    required this.text,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Semantics(
      button: enabled,
      selected: selected,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: selected ? cs.primary.withAlpha(15) : null,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                color: selected ? cs.primary : cs.mutedForeground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
