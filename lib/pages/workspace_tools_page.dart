import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../core/storage/storage_manager.dart';
import '../models/cloud_file.dart';
import '../models/batch_rename.dart';
import '../models/fast_transfer.dart';
import '../models/media_library.dart';
import '../providers/auth_provider.dart';
import '../providers/file_provider.dart';
import 'media_library_page.dart';

enum WorkspaceTool { scan, rename, fastTransfer, tmdb, categories }

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
      case WorkspaceTool.categories:
        return '分类管理';
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
      case WorkspaceTool.categories:
        return Icons.grid_view_rounded;
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
      WorkspaceTool.categories => const _CategoryManagementTool(),
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
  late List<BatchRenameRule> _rules;

  @override
  void initState() {
    super.initState();
    _rules = [
      BatchRenameRule(id: 'replace', kind: BatchRenameRuleKind.replace),
    ];
  }

  @override
  void dispose() {
    _find.dispose();
    _replace.dispose();
    super.dispose();
  }

  String _newName(CloudFile file) {
    final rule = _rules.first.copyWith(
      pattern: _find.text,
      replacement: _replace.text,
    );
    return buildRenamePreviews(
      [file],
      [rule],
      preserveExtension: _preserveExtension,
    ).first.newName;
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
    final previews = buildRenamePreviews(files, [
      _rules.first.copyWith(pattern: _find.text, replacement: _replace.text),
    ], preserveExtension: _preserveExtension);
    final changed = previews.where((item) => item.applicable).toList();
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
                    onPressed: _running
                        ? null
                        : () =>
                              _apply(changed.map((item) => item.file).toList()),
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
                  final preview = previews[index];
                  final next = preview.newName;
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
                      preview.error ?? next,
                      style: TextStyle(
                        color: preview.error != null
                            ? cs.destructive
                            : next == file.name
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
  bool _createDirectories = true;
  bool _skipExisting = true;
  String _result = '';

  @override
  void initState() {
    super.initState();
    final raw = StorageManager.get<dynamic>(StorageKeys.fastTransferSession);
    if (raw is Map && raw['entries'] is List) {
      final entries = (raw['entries'] as List)
          .whereType<Map>()
          .map(
            (value) =>
                FastTransferEntry.fromJson(Map<String, dynamic>.from(value)),
          )
          .where((entry) => entry.path.isNotEmpty)
          .toList();
      if (entries.isNotEmpty) {
        _json.text = jsonEncode({
          'files': entries.map((entry) => entry.toJson()).toList(),
        });
      }
      _result = raw['result']?.toString() ?? '';
    }
  }

  @override
  void dispose() {
    _json.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    late final List<FastTransferEntry> entries;
    try {
      entries = parseFastTransferJSON(_json.text);
    } catch (error) {
      setState(() => _result = error.toString());
      return;
    }
    setState(() {
      _running = true;
      _result = '';
    });
    await StorageManager.set(StorageKeys.fastTransferSession, {
      'entries': entries.map((entry) => entry.toJson()).toList(),
      'result': '待执行 ${entries.length} 项',
    });
    var completed = 0;
    var failed = 0;
    var nextIndex = 0;
    final api = ref.read(authProvider.notifier).api;
    final parentID = ref.read(fileProvider).folderPath.lastOrNull?.id;
    final directoryCache = <String, String?>{};
    final concurrency =
        (int.tryParse(
                  StorageManager.get<String>(
                        StorageKeys.fastTransferConcurrency,
                      ) ??
                      '3',
                ) ??
                3)
            .clamp(1, 20);
    try {
      Future<void> worker() async {
        while (nextIndex < entries.length) {
          final entry = entries[nextIndex++];
          try {
            final targetID = await _resolveTargetDirectory(
              entry,
              parentID,
              api,
              directoryCache,
            );
            if (_skipExisting &&
                await _hasExistingFile(api, targetID, entry.name)) {
              completed += 1;
              continue;
            }
            if (entry.md5 != null) {
              await api.flashTransferToken(
                name: entry.name,
                fileSize: entry.size,
                parentID: targetID,
                md5: entry.md5!,
              );
            } else {
              await api.flashTransferGCIDToken(
                name: entry.name,
                fileSize: entry.size,
                parentID: targetID,
                gcid: entry.gcid!,
              );
            }
            completed += 1;
          } catch (_) {
            failed += 1;
          }
          if (mounted) {
            setState(
              () => _result = '已处理 ${completed + failed}/${entries.length} 项',
            );
          }
        }
      }

      await Future.wait(List.generate(concurrency, (_) => worker()));
      await ref.read(fileProvider.notifier).loadFiles();
      if (mounted) {
        setState(() => _result = '秒传完成：成功 $completed，失败 $failed');
      }
      await StorageManager.set(StorageKeys.fastTransferSession, {
        'entries': entries.map((entry) => entry.toJson()).toList(),
        'result': '秒传完成：成功 $completed，失败 $failed',
      });
    } catch (error) {
      if (mounted) {
        setState(() => _result = '已提交 $completed / ${entries.length} 个：$error');
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<String?> _resolveTargetDirectory(
    FastTransferEntry entry,
    String? rootID,
    dynamic api,
    Map<String, String?> cache,
  ) async {
    var currentID = rootID;
    for (final name
        in entry.directoryPath.split('/').where((part) => part.isNotEmpty)) {
      if (name == '..') throw const FormatException('目录不能包含 ..');
      final key = '${currentID ?? 'root'}/$name';
      if (cache.containsKey(key)) {
        currentID = cache[key];
        continue;
      }
      final children = _extractFiles(
        await api.fsFiles(parentID: currentID, pageSize: 1000),
      );
      final existing = children.where((file) => file.name == name).firstOrNull;
      if (existing != null) {
        if (!existing.isDirectory) {
          throw FormatException('$name 已被同名文件占用');
        }
        currentID = existing.id;
      } else {
        if (!_createDirectories) {
          throw FormatException('${entry.path} 包含目录，请开启自动创建目录');
        }
        final parentBeforeCreate = currentID;
        final response = await api.fsCreateDir(
          name,
          parentID: parentBeforeCreate,
        );
        currentID = _findString(response, const [
          'fileId',
          'file_id',
          'id',
          'resId',
        ]);
        if (currentID == null) {
          final refreshed = _extractFiles(
            await api.fsFiles(parentID: parentBeforeCreate, pageSize: 1000),
          );
          currentID = refreshed
              .where((file) => file.name == name && file.isDirectory)
              .firstOrNull
              ?.id;
        }
        if (currentID == null) throw FormatException('无法创建目录 $name');
      }
      cache[key] = currentID;
    }
    return currentID;
  }

  Future<bool> _hasExistingFile(
    dynamic api,
    String? parentID,
    String name,
  ) async => _extractFiles(
    await api.fsFiles(parentID: parentID, pageSize: 1000),
  ).any((file) => !file.isDirectory && file.name == name);

  List<CloudFile> _extractFiles(Map<String, dynamic> json) {
    final files = <CloudFile>[];
    void visit(dynamic value) {
      if (value is Map) {
        try {
          files.add(CloudFile.fromJson(Map<String, dynamic>.from(value)));
        } catch (_) {}
        for (final child in value.values) {
          visit(child);
        }
      } else if (value is List) {
        for (final child in value) {
          visit(child);
        }
      }
    }

    visit(json);
    final unique = <String, CloudFile>{for (final file in files) file.id: file};
    return unique.values.toList();
  }

  String? _findString(Map<String, dynamic> value, List<String> keys) {
    for (final key in keys) {
      final found = value[key];
      if (found != null && found.toString().isNotEmpty) return found.toString();
    }
    for (final child in value.values) {
      if (child is Map) {
        final found = _findString(Map<String, dynamic>.from(child), keys);
        if (found != null) return found;
      }
    }
    return null;
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
              child: Column(
                children: [
                  Row(
                    children: [
                      ShadCheckbox(
                        value: _createDirectories,
                        label: const Text('自动创建目录'),
                        onChanged: (value) =>
                            setState(() => _createDirectories = value),
                      ),
                      const SizedBox(width: 16),
                      ShadCheckbox(
                        value: _skipExisting,
                        label: const Text('跳过同名文件'),
                        onChanged: (value) =>
                            setState(() => _skipExisting = value),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 220,
                    child: ShadInput(
                      controller: _json,
                      maxLines: null,
                      expands: true,
                      placeholder: const Text(
                        '{"files":[{"path":"Movies/example.mkv","size":123,"gcid":"..."}]}',
                      ),
                    ),
                  ),
                ],
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

class _CategoryManagementTool extends StatefulWidget {
  const _CategoryManagementTool();

  @override
  State<_CategoryManagementTool> createState() =>
      _CategoryManagementToolState();
}

class _CategoryManagementToolState extends State<_CategoryManagementTool> {
  List<MediaCategoryRule> _rules = [];

  @override
  void initState() {
    super.initState();
    final raw = StorageManager.get<dynamic>(StorageKeys.mediaCategoryRules);
    _rules = raw is List
        ? raw
              .whereType<Map>()
              .map(
                (value) => MediaCategoryRule.fromJson(
                  Map<String, dynamic>.from(value),
                ),
              )
              .toList()
        : MediaCategoryRule.presets();
    if (raw is! List) _save();
  }

  Future<void> _save() => StorageManager.set(
    StorageKeys.mediaCategoryRules,
    _rules.map((rule) => rule.toJson()).toList(),
  );

  Future<void> _restorePresets() async {
    setState(() => _rules = MediaCategoryRule.presets());
    await _save();
  }

  Future<void> _editRule([MediaCategoryRule? rule]) async {
    final result = await showShadDialog<MediaCategoryRule>(
      context: context,
      builder: (context) => _CategoryRuleDialog(initialRule: rule),
    );
    if (result == null || !mounted) return;
    setState(() {
      final index = _rules.indexWhere((item) => item.id == result.id);
      if (index == -1) {
        _rules.add(result);
      } else {
        _rules[index] = result;
      }
    });
    await _save();
  }

  Future<void> _deleteRule(MediaCategoryRule rule) async {
    setState(() => _rules.removeWhere((item) => item.id == rule.id));
    await _save();
  }

  Future<void> _move(MediaCategoryRule rule, int offset) async {
    final index = _rules.indexWhere((item) => item.id == rule.id);
    final target = index + offset;
    if (index < 0 || target < 0 || target >= _rules.length) return;
    setState(() {
      final moved = _rules.removeAt(index);
      _rules.insert(target, moved);
    });
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        _ToolSection(
          title: '影视分类规则',
          description: '按 TMDB 原始语言匹配分类；默认分类会接收未匹配到其它规则的资源。',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ShadButton.outline(
                onPressed: _restorePresets,
                leading: const Icon(Icons.restart_alt_rounded, size: 16),
                child: const Text('恢复预设'),
              ),
              const SizedBox(width: 8),
              ShadButton(
                onPressed: () => _editRule(),
                leading: const Icon(Icons.add_rounded, size: 16),
                child: const Text('新增分类'),
              ),
            ],
          ),
          child: const SizedBox.shrink(),
        ),
        const SizedBox(height: 16),
        _ruleGroup(
          title: '电影分类',
          icon: Icons.movie_rounded,
          kind: TMDBMediaKind.movie,
          color: cs.primary,
        ),
        const SizedBox(height: 16),
        _ruleGroup(
          title: '剧集分类',
          icon: Icons.tv_rounded,
          kind: TMDBMediaKind.tv,
          color: cs.foreground,
        ),
      ],
    );
  }

  Widget _ruleGroup({
    required String title,
    required IconData icon,
    required TMDBMediaKind kind,
    required Color color,
  }) {
    final rules = _rules.where((rule) => rule.mediaKind == kind).toList();
    return _ToolSection(
      title: title,
      description: rules.isEmpty ? '尚未配置分类规则。' : '${rules.length} 条分类规则',
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: rules.isEmpty
            ? const SizedBox.shrink()
            : Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: ShadTheme.of(context).colorScheme.border,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    for (final rule in rules)
                      _CategoryRuleRow(
                        rule: rule,
                        icon: icon,
                        color: color,
                        canMoveUp: _rules.indexOf(rule) > 0,
                        canMoveDown: _rules.indexOf(rule) < _rules.length - 1,
                        onMoveUp: () => _move(rule, -1),
                        onMoveDown: () => _move(rule, 1),
                        onEdit: () => _editRule(rule),
                        onDelete: () => _deleteRule(rule),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _CategoryRuleRow extends StatelessWidget {
  final MediaCategoryRule rule;
  final IconData icon;
  final Color color;
  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _CategoryRuleRow({
    required this.rule,
    required this.icon,
    required this.color,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: cs.border.withValues(alpha: 0.7)),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 19),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  rule.name,
                  style: TextStyle(
                    color: cs.foreground,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  rule.isFallback
                      ? '未设置原始语言的默认分类'
                      : '语言 ${rule.languages.join(', ')}',
                  style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                ),
              ],
            ),
          ),
          if (rule.isFallback) const ShadBadge(child: Text('默认')),
          const SizedBox(width: 6),
          _CategoryIconButton(
            tooltip: '上移',
            icon: Icons.arrow_upward_rounded,
            onPressed: canMoveUp ? onMoveUp : null,
          ),
          _CategoryIconButton(
            tooltip: '下移',
            icon: Icons.arrow_downward_rounded,
            onPressed: canMoveDown ? onMoveDown : null,
          ),
          _CategoryIconButton(
            tooltip: '编辑',
            icon: Icons.edit_outlined,
            onPressed: onEdit,
          ),
          _CategoryIconButton(
            tooltip: '删除',
            icon: Icons.delete_outline_rounded,
            onPressed: onDelete,
            destructive: true,
          ),
        ],
      ),
    );
  }
}

class _CategoryIconButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool destructive;

  const _CategoryIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ShadTooltip(
      builder: (_) => Text(tooltip),
      child: ShadButton.ghost(
        size: ShadButtonSize.sm,
        onPressed: onPressed,
        child: Icon(
          icon,
          size: 16,
          color: destructive ? cs.destructive : cs.mutedForeground,
        ),
      ),
    );
  }
}

class _CategoryRuleDialog extends StatefulWidget {
  final MediaCategoryRule? initialRule;

  const _CategoryRuleDialog({this.initialRule});

  @override
  State<_CategoryRuleDialog> createState() => _CategoryRuleDialogState();
}

class _CategoryRuleDialogState extends State<_CategoryRuleDialog> {
  late final TextEditingController _name;
  late final TextEditingController _languages;
  late TMDBMediaKind _kind;
  late bool _isFallback;

  @override
  void initState() {
    super.initState();
    final rule = widget.initialRule;
    _name = TextEditingController(text: rule?.name ?? '');
    _languages = TextEditingController(text: rule?.languages.join(', ') ?? '');
    _kind = rule?.mediaKind ?? TMDBMediaKind.movie;
    _isFallback = rule?.isFallback ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _languages.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final languages = _languages.text
        .split(',')
        .map((value) => value.trim().toLowerCase())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList();
    Navigator.of(context).pop(
      MediaCategoryRule(
        id:
            widget.initialRule?.id ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: name,
        mediaKind: _kind,
        languages: languages,
        isFallback: _isFallback,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ShadDialog(
      title: Text(widget.initialRule == null ? '新增分类' : '编辑分类'),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ShadButton(onPressed: _save, child: const Text('保存')),
      ],
      child: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ShadInput(controller: _name, placeholder: const Text('分类名称')),
            const SizedBox(height: 10),
            ShadSelect<TMDBMediaKind>(
              initialValue: _kind,
              selectedOptionBuilder: (context, value) => Text(value.title),
              options: const [
                ShadOption(value: TMDBMediaKind.movie, child: Text('电影')),
                ShadOption(value: TMDBMediaKind.tv, child: Text('剧集')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _kind = value);
              },
            ),
            const SizedBox(height: 10),
            ShadInput(
              controller: _languages,
              enabled: !_isFallback,
              placeholder: const Text('原始语言代码，以英文逗号分隔，例如 zh, en'),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: ShadCheckbox(
                value: _isFallback,
                label: const Text('设为默认分类'),
                sublabel: const Text('在其它分类均未匹配时使用'),
                onChanged: (value) => setState(() => _isFallback = value),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
