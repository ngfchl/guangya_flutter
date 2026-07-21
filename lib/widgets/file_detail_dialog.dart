import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../api/guangya_api.dart';
import '../core/logging/app_logger.dart';
import '../core/storage/storage_manager.dart';
import '../models/cloud_file.dart';
import 'app_loading_indicator.dart';

/// Show file/folder detail dialog. Calls the real API to fetch full detail.
Future<void> showFileDetailDialog(BuildContext context, CloudFile file) async {
  return showShadDialog(
    context: context,
    builder: (_) => _FileDetailDialog(file: file),
  );
}

class _FileDetailDialog extends StatefulWidget {
  final CloudFile file;

  const _FileDetailDialog({required this.file});

  @override
  State<_FileDetailDialog> createState() => _FileDetailDialogState();
}

class _FileDetailDialogState extends State<_FileDetailDialog> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _rawDetail;
  CloudFile? _detailFile;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    try {
      final host = StorageManager.networkProxyHost;
      final port = StorageManager.networkProxyPort;
      final api = GuangyaAPI();
      final result = await api.fsDetail(widget.file.id);
      // Try to extract a CloudFile from the detail response
      CloudFile? detailFile;
      try {
        final files = _extractFiles(result);
        detailFile = files.cast<CloudFile?>().firstWhere(
              (f) => f?.id == widget.file.id,
              orElse: () => null,
            );
      } catch (_) {}
      if (mounted) {
        setState(() {
          _rawDetail = result;
          _detailFile = detailFile;
          _loading = false;
        });
      }
    } catch (e) {
      AppLogger.error('获取文件详情失败', e.toString());
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final file = _detailFile ?? widget.file;
    return ShadDialog(
      title: Row(
        children: [
          Icon(
            file.isDirectory ? Icons.folder_rounded : Icons.insert_drive_file_rounded,
            size: 20,
            color: file.isDirectory ? Colors.amber : cs.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              file.name,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ],
      ),
      description: Text(
        file.isDirectory ? '文件夹详情' : '文件详情',
        style: TextStyle(fontSize: 12, color: cs.mutedForeground),
      ),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
      child: SizedBox(
        width: 420,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: AppLoadingIndicator(size: AppLoadingSize.inline)),
              )
            : _error != null
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.error_outline_rounded, size: 18, color: cs.destructive),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '加载失败',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: cs.destructive,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _error!,
                          style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                        ),
                      ],
                    ),
                  )
                : _buildDetailBody(file, cs),
      ),
    );
  }

  Widget _buildDetailBody(CloudFile file, cs) {
    final rows = <_DetailRow>[];

    // Basic info
    rows.add(_DetailRow('类型', file.isDirectory ? '文件夹' : file.typeName));
    if (!file.isDirectory) {
      rows.add(_DetailRow('大小', file.formattedSize));
    }
    if (file.modifiedAt.isNotEmpty) {
      rows.add(_DetailRow('修改时间', file.modifiedAt));
    }
    if (file.cloudPath.isNotEmpty) {
      rows.add(_DetailRow('路径', file.cloudPath, maxLines: 3));
    }
    if (file.gcid?.isNotEmpty == true) {
      rows.add(_DetailRow('GCID', file.gcid!, monospace: true, maxLines: 2));
    }
    if (file.isDirectory) {
      if (file.subDirectoryCount != null) {
        rows.add(_DetailRow('子文件夹', '${file.subDirectoryCount}'));
      }
      if (file.subFileCount != null) {
        rows.add(_DetailRow('子文件', '${file.subFileCount}'));
      }
    }
    rows.add(_DetailRow('文件 ID', file.id, monospace: true, maxLines: 2));
    if (file.fileType > 0) {
      rows.add(_DetailRow('文件类型码', '${file.fileType}'));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Basic info card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  _buildDetailRow(rows[i], cs),
                  if (i < rows.length - 1)
                    Divider(height: 1, color: cs.border.withValues(alpha: 0.5)),
                ],
              ],
            ),
          ),
        ),
        // Raw JSON toggle
        if (_rawDetail != null && _rawDetail!.isNotEmpty) ...[
          const SizedBox(height: 12),
          _RawJsonSection(rawJson: _rawDetail!),
        ],
      ],
    );
  }

  Widget _buildDetailRow(_DetailRow row, cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              row.label,
              style: TextStyle(
                fontSize: 12,
                color: cs.mutedForeground,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              row.value,
              maxLines: row.maxLines,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontFamily: row.monospace ? 'monospace' : null,
                color: cs.foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Minimal file extractor (mirrors the provider's logic).
  static List<CloudFile> _extractFiles(Map<String, dynamic> json) {
    final result = <CloudFile>[];
    final seen = <String>{};

    void visit(dynamic value) {
      if (value is Map) {
        final map = Map<String, dynamic>.from(value);
        try {
          final file = CloudFile.fromJson(map);
          if (seen.add(file.id)) result.add(file);
        } catch (_) {}
        for (final v in map.values) {
          visit(v);
        }
      } else if (value is List) {
        for (final v in value) {
          visit(v);
        }
      }
    }

    // Check common list keys first
    for (final key in ['list', 'files', 'fileList', 'items', 'records', 'resList']) {
      final v = json[key];
      if (v is List) {
        visit(v);
        if (result.isNotEmpty) return result;
      }
    }
    visit(json);
    return result;
  }
}

class _DetailRow {
  final String label;
  final String value;
  final bool monospace;
  final int maxLines;

  const _DetailRow(
    this.label,
    this.value, {
    this.monospace = false,
    this.maxLines = 1,
  });
}

class _RawJsonSection extends StatefulWidget {
  final Map<String, dynamic> rawJson;

  const _RawJsonSection({required this.rawJson});

  @override
  State<_RawJsonSection> createState() => _RawJsonSectionState();
}

class _RawJsonSectionState extends State<_RawJsonSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                children: [
                  Icon(
                    _expanded ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_right_rounded,
                    size: 18,
                    color: cs.mutedForeground,
                  ),
                  Text(
                    '原始数据 (JSON)',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: cs.foreground,
                    ),
                  ),
                ],
              ),
            ),
            if (_expanded) ...[
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: cs.muted.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _prettyJson(widget.rawJson),
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        height: 1.5,
                        color: cs.foreground,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _prettyJson(Map<String, dynamic> json) {
    try {
      // Manual pretty print to avoid dart:convert import
      final buffer = StringBuffer('{\n');
      final entries = json.entries.toList();
      for (var i = 0; i < entries.length; i++) {
        final e = entries[i];
        buffer.write('  "${e.key}": ${_toPrettyValue(e.value)}');
        if (i < entries.length - 1) buffer.write(',');
        buffer.write('\n');
      }
      buffer.write('}');
      return buffer.toString();
    } catch (_) {
      return json.toString();
    }
  }

  static String _toPrettyValue(dynamic value) {
    if (value == null) return 'null';
    if (value is String) return '"$value"';
    if (value is num) return '$value';
    if (value is bool) return '$value';
    if (value is Map) {
      final entries = value.entries.toList();
      if (entries.isEmpty) return '{}';
      final parts = entries.map((e) => '  "${e.key}": ${_toPrettyValue(e.value)}').join(',\n  ');
      return '{\n  $parts\n}';
    }
    if (value is List) {
      if (value.isEmpty) return '[]';
      final parts = value.map(_toPrettyValue).join(', ');
      return '[$parts]';
    }
    return '"$value"';
  }
}
