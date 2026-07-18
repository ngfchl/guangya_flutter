import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  String confirmText = '确认',
  String cancelText = '取消',
}) async {
  final result = await showShadDialog<bool>(
    context: context,
    builder: (context) => ShadDialog(
      title: Text(title),
      description: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(content),
      ),
      actions: [
        ShadButton.outline(
          child: Text(cancelText),
          onPressed: () => Navigator.of(context).pop(false),
        ),
        ShadButton(
          child: Text(confirmText),
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    ),
  );
  return result ?? false;
}
