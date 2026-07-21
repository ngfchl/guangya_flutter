import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide showShadDialog, showShadSheet;

import '../models/cloud_file.dart';
import 'app_dialog.dart';

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

Future<bool> showDeleteFilesConfirmDialog(
  BuildContext context,
  List<CloudFile> files, {
  String confirmText = '删除',
  String? title,
  String? description,
  String warning = '项目会被移入回收站。',
}) async {
  if (files.isEmpty) return false;
  final result = await showShadDialog<bool>(
    context: context,
    builder: (dialogContext) => ShadDialog(
      title: Text(title ?? '删除 ${files.length} 项？'),
      description: Text(
        description ??
            (files.length == 1
                ? files.first.name
                : '将删除所选的 ${files.length} 个文件或文件夹。'),
      ),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        ShadButton.destructive(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          leading: const Icon(LucideIcons.trash2, size: 16),
          child: Text(confirmText),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(warning),
      ),
    ),
  );
  return result ?? false;
}
