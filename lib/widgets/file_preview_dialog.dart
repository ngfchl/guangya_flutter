import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide showShadDialog, showShadSheet;
import 'package:universal_file_viewer/universal_file_viewer.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/cloud_file.dart';
import 'app_dialog.dart';
import 'file_icon.dart';

Future<void> showFilePreviewDialog({
  required BuildContext context,
  required CloudFile file,
  required Future<Uri> Function() resolveUrl,
  VoidCallback? onDownload,
}) {
  return showShadDialog<void>(
    context: context,
    builder: (_) => _FilePreviewDialog(
      file: file,
      resolveUrl: resolveUrl,
      onDownload: onDownload,
    ),
  );
}

bool canPreviewCloudFile(CloudFile file) {
  if (file.isDirectory) return false;
  final type = detectFileType(file.name);
  if (type != null && type != FileType.video) return true;
  return file.isImage || file.isDocument;
}

class _FilePreviewDialog extends StatefulWidget {
  final CloudFile file;
  final Future<Uri> Function() resolveUrl;
  final VoidCallback? onDownload;

  const _FilePreviewDialog({
    required this.file,
    required this.resolveUrl,
    this.onDownload,
  });

  @override
  State<_FilePreviewDialog> createState() => _FilePreviewDialogState();
}

class _FilePreviewDialogState extends State<_FilePreviewDialog> {
  late final Future<Uri> _url = widget.resolveUrl();

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final screen = MediaQuery.sizeOf(context);
    final compact = screen.width < 720;
    final maxWidth = math.min(screen.width - 24, compact ? 560.0 : 980.0);
    final maxHeight = math.max(320.0, screen.height - 32);

    return ShadDialog(
      constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
      padding: EdgeInsets.all(compact ? 12 : 16),
      scrollable: false,
      title: Row(
        children: [
          FileIcon(file: widget.file, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      description: Text(
        '${widget.file.typeName} · ${widget.file.formattedSize}',
        style: TextStyle(fontSize: 12, color: cs.mutedForeground),
      ),
      actions: [
        FutureBuilder<Uri>(
          future: _url,
          builder: (context, snapshot) => ShadButton.outline(
            onPressed: snapshot.hasData
                ? () => launchUrl(
                    snapshot.data!,
                    mode: LaunchMode.externalApplication,
                  )
                : null,
            leading: const Icon(Icons.open_in_new_rounded, size: 16),
            child: const Text('系统打开'),
          ),
        ),
        if (widget.onDownload != null)
          ShadButton.outline(
            onPressed: widget.onDownload,
            leading: const Icon(Icons.download_rounded, size: 16),
            child: const Text('下载'),
          ),
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
      child: SizedBox(
        width: maxWidth,
        height: math.min(maxHeight - 132, compact ? 520.0 : 680.0),
        child: FutureBuilder<Uri>(
          future: _url,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const _PreviewLoading();
            }
            if (snapshot.hasError || !snapshot.hasData) {
              return _PreviewMessage(
                title: '预览链接获取失败',
                description: snapshot.error?.toString() ?? '响应缺少可用链接',
              );
            }
            return ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: UniversalFileViewer.remote(
                fileUrl: snapshot.data!.toString(),
                padding: const EdgeInsets.all(14),
                backgroundColor: cs.background,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PreviewLoading extends StatelessWidget {
  const _PreviewLoading();

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: cs.primary,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '正在获取预览链接…',
            style: TextStyle(fontSize: 12, color: cs.mutedForeground),
          ),
        ],
      ),
    );
  }
}

class _PreviewMessage extends StatelessWidget {
  final String title;
  final String description;

  const _PreviewMessage({required this.title, required this.description});

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 34,
              color: cs.mutedForeground,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: cs.foreground,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              description,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: cs.mutedForeground),
            ),
          ],
        ),
      ),
    );
  }
}
