import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../models/cloud_file.dart';
import '../providers/auth_provider.dart';
import '../providers/file_provider.dart';
import 'media_library_page.dart';

enum WorkspaceTool { scan, rename, fastTransfer, tmdb }

extension WorkspaceToolDetails on WorkspaceTool {
  String get title {
    switch (this) {
      case WorkspaceTool.scan:
        return '文件扫描与清理';
      case WorkspaceTool.rename:
        return '批量重命名';
      case WorkspaceTool.fastTransfer:
        return '秒传工具';
      case WorkspaceTool.tmdb:
        return 'TMDB 整理';
    }
  }

  IconData get icon {
    switch (this) {
      case WorkspaceTool.scan:
        return Icons.manage_search_rounded;
      case WorkspaceTool.rename:
        return Icons.text_fields_rounded;
      case WorkspaceTool.fastTransfer:
        return Icons.bolt_rounded;
      case WorkspaceTool.tmdb:
        return Icons.auto_fix_high_rounded;
    }
  }
}

class WorkspaceToolsPage extends StatelessWidget {
  final WorkspaceTool tool;
  final VoidCallback onClose;

  const WorkspaceToolsPage({
    super.key,
    required this.tool,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final body = switch (tool) {
      WorkspaceTool.scan => const _FileScanTool(),
      WorkspaceTool.rename => const _BatchRenameTool(),
      WorkspaceTool.fastTransfer => const _FastTransferTool(),
      WorkspaceTool.tmdb => const MediaLibraryPage(showLibrarySidebar: true),
    };
    return Column(
      children: [
        _ToolHeader(tool: tool, onClose: onClose),
        Expanded(child: body),
      ],
    );
  }
}

class _ToolHeader extends StatelessWidget {
  final WorkspaceTool tool;
  final VoidCallback onClose;

  const _ToolHeader({required this.tool, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: cs.border)),
      ),
      child: Row(
        children: [
          ShadButton.ghost(
            onPressed: onClose,
            leading: const Icon(Icons.arrow_back_rounded, size: 16),
            child: const Text('返回'),
          ),
          const SizedBox(width: 12),
          Icon(tool.icon, size: 20, color: cs.primary),
          const SizedBox(width: 8),
          Text(
            tool.title,
            style: TextStyle(
              color: cs.foreground,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _FileScanTool extends ConsumerStatefulWidget {
  const _FileScanTool();

  @override
  ConsumerState<_FileScanTool> createState() => _FileScanToolState();
}

class _FileScanToolState extends ConsumerState<_FileScanTool> {
  bool _scanning = false;
  String? _error;
  List<CloudFile> _emptyFolders = [];
  List<List<CloudFile>> _duplicates = [];

  Future<void> _scan() async {
    final state = ref.read(fileProvider);
    final api = ref.read(authProvider.notifier).api;
    setState(() {
      _scanning = true;
      _error = null;
      _emptyFolders = [];
      _duplicates = [];
    });
    try {
      final empty = <CloudFile>[];
      for (final folder in state.files.where((file) => file.isDirectory)) {
        final response = await api.fsFiles(parentID: folder.id, pageSize: 1);
        if (_extractFileCount(response) == 0) empty.add(folder);
      }
      final groups = <String, List<CloudFile>>{};
      for (final file in state.files.where((file) => !file.isDirectory)) {
        final key = file.gcid;
        if (key != null && key.isNotEmpty) {
          groups.putIfAbsent(key, () => []).add(file);
        }
      }
      if (mounted) {
        setState(() {
          _emptyFolders = empty;
          _duplicates = groups.values
              .where((group) => group.length > 1)
              .toList();
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  int _extractFileCount(Map<String, dynamic> value) {
    List? find(dynamic node) {
      if (node is Map) {
        for (final key in const ['list', 'files', 'fileList', 'items']) {
          if (node[key] is List) return node[key] as List;
        }
        for (final child in node.values) {
          final result = find(child);
          if (result != null) return result;
        }
      }
      return null;
    }

    return find(value)?.length ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        _ToolSection(
          title: '当前目录扫描',
          description: '检查空文件夹和具有相同 GCID 的重复文件。',
          trailing: ShadButton(
            onPressed: _scanning ? null : _scan,
            leading: Icon(
              _scanning
                  ? Icons.hourglass_top_rounded
                  : Icons.play_arrow_rounded,
              size: 16,
            ),
            child: Text(_scanning ? '扫描中' : '开始扫描'),
          ),
          child: _scanning
              ? const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: ShadProgress(),
                )
              : _error != null
              ? Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!, style: TextStyle(color: cs.destructive)),
                )
              : const SizedBox.shrink(),
        ),
        const SizedBox(height: 14),
        _ToolSection(
          title: '空文件夹',
          description: '扫描到 ${_emptyFolders.length} 个。',
          child: _CleanupList(files: _emptyFolders, emptyText: '开始扫描后显示空文件夹。'),
        ),
        const SizedBox(height: 14),
        _ToolSection(
          title: '重复文件',
          description: '扫描到 ${_duplicates.length} 组。',
          child: _duplicates.isEmpty
              ? Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    '开始扫描后显示重复项。',
                    style: TextStyle(color: cs.mutedForeground),
                  ),
                )
              : Column(
                  children: [
                    for (final group in _duplicates)
                      _DuplicateGroup(files: group),
                  ],
                ),
        ),
      ],
    );
  }
}

class _CleanupList extends ConsumerWidget {
  final List<CloudFile> files;
  final String emptyText;

  const _CleanupList({required this.files, required this.emptyText});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = ShadTheme.of(context).colorScheme;
    if (files.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(emptyText, style: TextStyle(color: cs.mutedForeground)),
      );
    }
    return Column(
      children: [
        for (final file in files)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.folder_rounded, color: cs.primary),
            title: Text(file.name),
            trailing: ShadButton.destructive(
              size: ShadButtonSize.sm,
              onPressed: () =>
                  ref.read(fileProvider.notifier).deleteFiles([file]),
              child: const Text('删除'),
            ),
          ),
      ],
    );
  }
}

class _DuplicateGroup extends ConsumerWidget {
  final List<CloudFile> files;

  const _DuplicateGroup({required this.files});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.muted,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          for (final file in files.skip(1))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(file.name),
              subtitle: Text(
                file.cloudPath,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: ShadButton.destructive(
                size: ShadButtonSize.sm,
                onPressed: () =>
                    ref.read(fileProvider.notifier).deleteFiles([file]),
                child: const Text('删除副本'),
              ),
            ),
        ],
      ),
    );
  }
}

class _BatchRenameTool extends ConsumerStatefulWidget {
  const _BatchRenameTool();

  @override
  ConsumerState<_BatchRenameTool> createState() => _BatchRenameToolState();
}

class _BatchRenameToolState extends ConsumerState<_BatchRenameTool> {
  final _find = TextEditingController();
  final _replace = TextEditingController();
  bool _preserveExtension = true;
  bool _running = false;

  @override
  void dispose() {
    _find.dispose();
    _replace.dispose();
    super.dispose();
  }

  String _newName(CloudFile file) {
    final old = file.name;
    if (!_preserveExtension || file.isDirectory) {
      return old.replaceAll(_find.text, _replace.text);
    }
    final split = old.lastIndexOf('.');
    if (split <= 0) return old.replaceAll(_find.text, _replace.text);
    return '${old.substring(0, split).replaceAll(_find.text, _replace.text)}${old.substring(split)}';
  }

  Future<void> _apply(List<CloudFile> files) async {
    final updates = files.where((file) => _newName(file) != file.name).toList();
    if (updates.isEmpty) return;
    setState(() => _running = true);
    try {
      final notifier = ref.read(fileProvider.notifier);
      for (final file in updates) {
        await notifier.renameFile(file, _newName(file));
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final files = ref.watch(fileProvider).files;
    final changed = files.where((file) => _newName(file) != file.name).toList();
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          _ToolSection(
            title: '重命名规则',
            description: '对当前目录的文件和文件夹生成预览，确认后逐项同步到云盘。',
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                children: [
                  Expanded(
                    child: ShadInput(
                      controller: _find,
                      placeholder: const Text('查找'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.arrow_right_alt_rounded),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ShadInput(
                      controller: _replace,
                      placeholder: const Text('替换为'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ShadCheckbox(
                    value: _preserveExtension,
                    label: const Text('保留扩展名'),
                    onChanged: (value) =>
                        setState(() => _preserveExtension = value),
                  ),
                  const SizedBox(width: 12),
                  ShadButton(
                    onPressed: _running ? null : () => _apply(files),
                    child: Text(_running ? '正在应用' : '应用 ${changed.length} 项'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: cs.card,
                border: Border.all(color: cs.border),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.separated(
                itemCount: files.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: cs.border),
                itemBuilder: (context, index) {
                  final file = files[index];
                  final next = _newName(file);
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      file.isDirectory
                          ? Icons.folder_rounded
                          : Icons.insert_drive_file_rounded,
                      color: file.isDirectory ? cs.primary : cs.mutedForeground,
                    ),
                    title: Text(file.name),
                    subtitle: Text(
                      next,
                      style: TextStyle(
                        color: next == file.name
                            ? cs.mutedForeground
                            : cs.primary,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FastTransferTool extends ConsumerStatefulWidget {
  const _FastTransferTool();

  @override
  ConsumerState<_FastTransferTool> createState() => _FastTransferToolState();
}

class _FastTransferToolState extends ConsumerState<_FastTransferTool> {
  final _json = TextEditingController();
  bool _running = false;
  String _result = '';

  @override
  void dispose() {
    _json.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final entries = _parseEntries(_json.text);
    if (entries.isEmpty) {
      setState(() => _result = '未找到包含 name、size、gcid 的秒传条目。');
      return;
    }
    setState(() {
      _running = true;
      _result = '';
    });
    var completed = 0;
    final api = ref.read(authProvider.notifier).api;
    final parentID = ref.read(fileProvider).folderPath.lastOrNull?.id;
    try {
      for (final entry in entries) {
        await api.flashTransferGCIDToken(
          name: entry.name,
          fileSize: entry.size,
          parentID: parentID,
          gcid: entry.gcid,
        );
        completed += 1;
      }
      await ref.read(fileProvider.notifier).loadFiles();
      if (mounted) {
        setState(() => _result = '已提交 $completed / ${entries.length} 个秒传任务。');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _result = '已提交 $completed / ${entries.length} 个：$error');
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  List<_TransferEntry> _parseEntries(String text) {
    try {
      final value = jsonDecode(text);
      final output = <_TransferEntry>[];
      void visit(dynamic node) {
        if (node is Map) {
          final name = node['name']?.toString() ?? node['fileName']?.toString();
          final gcid = node['gcid']?.toString() ?? node['gcId']?.toString();
          final rawSize = node['size'] ?? node['fileSize'];
          final size = rawSize is int
              ? rawSize
              : int.tryParse(rawSize?.toString() ?? '');
          if (name != null &&
              name.isNotEmpty &&
              gcid != null &&
              gcid.isNotEmpty &&
              size != null &&
              size >= 0) {
            output.add(_TransferEntry(name, gcid, size));
          }
          for (final child in node.values) {
            visit(child);
          }
        } else if (node is List) {
          for (final child in node) {
            visit(child);
          }
        }
      }

      visit(value);
      return output;
    } catch (_) {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ToolSection(
            title: '导入秒传 JSON',
            description: '支持递归解析包含 name、size、gcid（或 gcId）的 JSON。任务将写入当前目录。',
            trailing: ShadButton(
              onPressed: _running ? null : _submit,
              leading: Icon(
                _running ? Icons.hourglass_top_rounded : Icons.bolt_rounded,
                size: 16,
              ),
              child: Text(_running ? '提交中' : '开始秒传'),
            ),
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SizedBox(
                height: 260,
                child: ShadInput(
                  controller: _json,
                  maxLines: null,
                  expands: true,
                  placeholder: const Text(
                    '[{"name":"example.mkv","size":123,"gcid":"..."}]',
                  ),
                ),
              ),
            ),
          ),
          if (_running) ...[const SizedBox(height: 12), const ShadProgress()],
          if (_result.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_result, style: TextStyle(color: cs.mutedForeground)),
          ],
        ],
      ),
    );
  }
}

class _TransferEntry {
  final String name;
  final String gcid;
  final int size;

  const _TransferEntry(this.name, this.gcid, this.size);
}

class _ToolSection extends StatelessWidget {
  final String title;
  final String description;
  final Widget child;
  final Widget? trailing;

  const _ToolSection({
    required this.title,
    required this.description,
    required this.child,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.card,
        border: Border.all(color: cs.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: cs.foreground,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      description,
                      style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                    ),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
          child,
        ],
      ),
    );
  }
}
