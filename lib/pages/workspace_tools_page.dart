import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide showShadDialog, showShadSheet;

import '../core/storage/storage_manager.dart';
import '../models/cloud_file.dart';
import '../models/batch_rename.dart';
import '../models/fast_transfer.dart';
import '../models/media_library.dart';
import '../providers/auth_provider.dart';
import '../providers/file_provider.dart';
import '../providers/media_library_provider.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_loading_indicator.dart';
import 'media_library_page.dart';

enum WorkspaceTool { scan, rename, fastTransfer, tmdb, organize, categories }

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
        return '媒体库管理';
      case WorkspaceTool.organize:
        return '文件整理';
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
      case WorkspaceTool.organize:
        return Icons.drive_file_move_rounded;
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
      WorkspaceTool.tmdb => const MediaLibraryPage(
        showLibrarySidebar: true,
        showManagementToolbar: true,
      ),
      WorkspaceTool.organize => const _MediaOrganizerTool(),
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

class _ToolHeader extends ConsumerWidget {
  final WorkspaceTool tool;
  final VoidCallback onClose;

  const _ToolHeader({required this.tool, required this.onClose});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = ShadTheme.of(context).colorScheme;
    final mediaState = tool == WorkspaceTool.tmdb
        ? ref.watch(mediaLibraryProvider)
        : null;
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: cs.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 420;
          return Row(
            children: [
              ShadTooltip(
                builder: (_) => const Text('返回'),
                child: ShadButton.ghost(
                  size: compact ? ShadButtonSize.sm : ShadButtonSize.regular,
                  onPressed: onClose,
                  leading: const Icon(Icons.arrow_back_rounded, size: 16),
                  child: compact ? const SizedBox.shrink() : const Text('返回'),
                ),
              ),
              const SizedBox(width: 10),
              Icon(tool.icon, size: 20, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tool.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.foreground,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (mediaState != null) ...[
                const SizedBox(width: 8),
                _ToolMediaLibrarySwitcher(
                  libraries: mediaState.libraries,
                  selectedLibraryID: mediaState.selectedLibraryID,
                  compact: compact,
                  onSelected: (libraryID) => ref
                      .read(mediaLibraryProvider.notifier)
                      .selectLibrary(libraryID),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _ToolMediaLibrarySwitcher extends StatefulWidget {
  final List<MediaLibraryDefinition> libraries;
  final String? selectedLibraryID;
  final ValueChanged<String> onSelected;
  final bool compact;

  const _ToolMediaLibrarySwitcher({
    required this.libraries,
    required this.selectedLibraryID,
    required this.onSelected,
    required this.compact,
  });

  @override
  State<_ToolMediaLibrarySwitcher> createState() =>
      _ToolMediaLibrarySwitcherState();
}

class _ToolMediaLibrarySwitcherState extends State<_ToolMediaLibrarySwitcher> {
  final _controller = ShadPopoverController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final selected = widget.libraries
        .where((library) => library.id == widget.selectedLibraryID)
        .firstOrNull;
    return ShadPopover(
      controller: _controller,
      popover: (_) => SizedBox(
        width: 240,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(6),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
                child: Text(
                  '切换媒体库',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: cs.mutedForeground,
                  ),
                ),
              ),
              for (final library in widget.libraries)
                ShadButton.ghost(
                  width: double.infinity,
                  mainAxisAlignment: MainAxisAlignment.start,
                  leading: Icon(
                    library.kind == MediaLibraryKind.series
                        ? Icons.live_tv_rounded
                        : Icons.movie_rounded,
                    size: 16,
                  ),
                  trailing: library.id == widget.selectedLibraryID
                      ? Icon(Icons.check_rounded, size: 16, color: cs.primary)
                      : null,
                  onPressed: () {
                    _controller.hide();
                    widget.onSelected(library.id);
                  },
                  child: Text(
                    library.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.compact ? 92 : 190),
            child: ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: widget.libraries.isEmpty ? null : _controller.toggle,
              leading: Icon(
                Icons.video_library_rounded,
                size: 16,
                color: cs.primary,
              ),
              child: Text(
                selected?.name ?? '未选择媒体库',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: 2),
          ShadTooltip(
            builder: (_) => const Text('切换媒体库'),
            child: ShadButton.outline(
              size: ShadButtonSize.sm,
              onPressed: widget.libraries.isEmpty ? null : _controller.toggle,
              child: const Icon(Icons.swap_horiz_rounded, size: 17),
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
  bool _cancelRequested = false;
  int _foldersScanned = 0;
  int _filesScanned = 0;
  String? _error;
  List<CloudFile> _emptyFolders = [];
  List<List<CloudFile>> _duplicates = [];
  List<List<CloudFile>> _similarFolders = [];

  Future<void> _scan() async {
    final state = ref.read(fileProvider);
    final api = ref.read(authProvider.notifier).api;
    setState(() {
      _scanning = true;
      _cancelRequested = false;
      _foldersScanned = 0;
      _filesScanned = 0;
      _error = null;
      _emptyFolders = [];
      _duplicates = [];
      _similarFolders = [];
    });
    try {
      final empty = <CloudFile>[];
      final groups = <String, List<CloudFile>>{};
      final queue = <CloudFile>[
        ...state.files.where((file) => file.isDirectory),
      ];
      final files = <CloudFile>[
        ...state.files.where((file) => !file.isDirectory),
      ];
      final folders = <CloudFile>[
        ...state.files.where((file) => file.isDirectory),
      ];
      while (queue.isNotEmpty) {
        if (_cancelRequested) break;
        final folder = queue.removeLast();
        final response = await api.fsFiles(parentID: folder.id, pageSize: 1000);
        final children = _extractFiles(response);
        _foldersScanned += 1;
        _filesScanned += children.where((child) => !child.isDirectory).length;
        if (children.isEmpty) empty.add(folder);
        for (final child in children) {
          if (child.isDirectory) {
            queue.add(child);
            folders.add(child);
          } else {
            files.add(child);
          }
        }
        if (mounted) {
          setState(() {
            _emptyFolders = List.of(empty);
            _similarFolders = _groupSimilarFolders(folders);
          });
        }
      }
      for (final file in files) {
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
          _similarFolders = _groupSimilarFolders(folders);
          if (_cancelRequested) _error = '扫描已取消，已保留当前结果';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _cancelScan() {
    if (!_scanning) return;
    setState(() => _cancelRequested = true);
  }

  List<List<CloudFile>> _groupSimilarFolders(List<CloudFile> folders) {
    final groups = <String, List<CloudFile>>{};
    for (final folder in folders) {
      final key = _normalizedFolderName(folder.name);
      if (key.isNotEmpty) groups.putIfAbsent(key, () => []).add(folder);
    }
    return groups.values.where((group) => group.length > 1).toList();
  }

  String _normalizedFolderName(String value) {
    var normalized = value.toLowerCase().trim();
    normalized = normalized.replaceAll(
      RegExp(
        r'(?:[\s._-]*(?:copy|duplicate|backup|副本|复制|拷贝|备份))(?:[\s._-]*\d+)?$',
        caseSensitive: false,
      ),
      '',
    );
    normalized = normalized.replaceAll(
      RegExp(r'(?:[（(\[]\s*\d{1,3}\s*[）)\]])$'),
      '',
    );
    return normalized.replaceAll(RegExp(r'[\s._()\[\]{}-]+'), '');
  }

  List<CloudFile> _extractFiles(Map<String, dynamic> value) {
    final files = <CloudFile>[];
    void visit(dynamic node) {
      if (node is Map) {
        try {
          files.add(CloudFile.fromJson(Map<String, dynamic>.from(node)));
        } catch (_) {}
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
    return {for (final file in files) file.id: file}.values.toList();
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        _ToolSection(
          title: '当前目录扫描',
          description: _scanning
              ? '已扫描 $_foldersScanned 个文件夹、$_filesScanned 个文件。'
              : '检查空文件夹、相同 GCID 的重复文件和相似名称目录。',
          trailing: ShadButton(
            onPressed: _scanning ? _cancelScan : _scan,
            leading: Icon(
              _scanning ? Icons.stop_circle_outlined : Icons.play_arrow_rounded,
              size: 16,
            ),
            child: Text(_scanning ? '取消扫描' : '开始扫描'),
          ),
          child: _scanning
              ? Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Semantics(
                    label: '文件扫描进度：$_foldersScanned 个文件夹，$_filesScanned 个文件',
                    child: const Align(
                      alignment: Alignment.centerLeft,
                      child: AppLoadingIndicator(
                        size: AppLoadingSize.compact,
                        semanticsLabel: '正在扫描当前目录',
                      ),
                    ),
                  ),
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
        const SizedBox(height: 14),
        _ToolSection(
          title: '相似文件夹',
          description: '扫描到 ${_similarFolders.length} 组，忽略空格、标点和副本后缀。',
          child: _similarFolders.isEmpty
              ? Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    '开始扫描后显示相似名称的文件夹。',
                    style: TextStyle(color: cs.mutedForeground),
                  ),
                )
              : Column(
                  children: [
                    for (final group in _similarFolders)
                      _SimilarFolderGroup(folders: group),
                  ],
                ),
        ),
      ],
    );
  }
}

class _SimilarFolderGroup extends ConsumerStatefulWidget {
  final List<CloudFile> folders;

  const _SimilarFolderGroup({required this.folders});

  @override
  ConsumerState<_SimilarFolderGroup> createState() =>
      _SimilarFolderGroupState();
}

class _SimilarFolderGroupState extends ConsumerState<_SimilarFolderGroup> {
  late Set<String> _selectedIDs;

  @override
  void initState() {
    super.initState();
    _selectedIDs = widget.folders.skip(1).map((folder) => folder.id).toSet();
  }

  Future<void> _confirmDelete() async {
    final targets = widget.folders
        .where((folder) => _selectedIDs.contains(folder.id))
        .toList();
    if (targets.isEmpty) return;
    final confirmed = await showShadDialog<bool>(
      context: context,
      builder: (dialogContext) => ShadDialog(
        title: Text('删除 ${targets.length} 个相似文件夹？'),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          ShadButton.destructive(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除已选项'),
          ),
        ],
        child: const Padding(
          padding: EdgeInsets.only(top: 10),
          child: Text('同组至少会保留一个文件夹。删除会移除其中的全部内容，请确认完整路径。'),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(fileProvider.notifier).deleteFiles(targets);
    if (mounted) setState(_selectedIDs.clear);
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.muted,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '相似名称组 · ${widget.folders.length} 个文件夹',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: cs.primary,
            ),
          ),
          for (final folder in widget.folders)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Row(
                children: [
                  ShadCheckbox(
                    value: _selectedIDs.contains(folder.id),
                    onChanged: (value) => setState(() {
                      if (value == true) {
                        if (_selectedIDs.length < widget.folders.length - 1) {
                          _selectedIDs.add(folder.id);
                        }
                      } else {
                        _selectedIDs.remove(folder.id);
                      }
                    }),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.folder_rounded, size: 17, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      folder.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    folder.formattedSize,
                    style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: ShadButton.destructive(
              size: ShadButtonSize.sm,
              onPressed: _selectedIDs.isEmpty ? null : _confirmDelete,
              child: Text('删除已选 ${_selectedIDs.length} 项'),
            ),
          ),
        ],
      ),
    );
  }
}

class _CleanupList extends ConsumerWidget {
  final List<CloudFile> files;
  final String emptyText;

  const _CleanupList({required this.files, required this.emptyText});

  Future<void> _confirmDeleteEmpty(
    BuildContext context,
    WidgetRef ref,
    CloudFile folder,
  ) async {
    final confirmed = await showShadDialog<bool>(
      context: context,
      builder: (dialogContext) => ShadDialog(
        title: Text('删除空文件夹「${folder.name}」？'),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          ShadButton.destructive(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('重新校验并删除'),
          ),
        ],
        child: const Padding(
          padding: EdgeInsets.only(top: 10),
          child: Text('删除前会重新检查目录是否为空；已发生变化的目录将被保留。'),
        ),
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      final response = await ref
          .read(authProvider.notifier)
          .api
          .fsFiles(parentID: folder.id, pageSize: 1);
      if (_hasCloudFile(response)) {
        if (!context.mounted) return;
        await showShadDialog<void>(
          context: context,
          builder: (dialogContext) => ShadDialog(
            title: const Text('已跳过删除'),
            actions: [
              ShadButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('知道了'),
              ),
            ],
            child: const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text('该文件夹在扫描后已有内容，未执行删除。'),
            ),
          ),
        );
        return;
      }
      await ref.read(fileProvider.notifier).deleteFiles([folder]);
    } catch (_) {
      if (!context.mounted) return;
      await showShadDialog<void>(
        context: context,
        builder: (dialogContext) => ShadDialog(
          title: const Text('无法校验文件夹'),
          actions: [
            ShadButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
          ],
          child: const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text('未能重新读取目录内容，因此没有执行删除。'),
          ),
        ),
      );
    }
  }

  bool _hasCloudFile(Map<String, dynamic> value) {
    var found = false;
    void visit(dynamic node) {
      if (found) return;
      if (node is Map) {
        try {
          CloudFile.fromJson(Map<String, dynamic>.from(node));
          found = true;
          return;
        } catch (_) {}
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
    return found;
  }

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
              onPressed: () => _confirmDeleteEmpty(context, ref, file),
              child: const Text('删除'),
            ),
          ),
      ],
    );
  }
}

class _DuplicateGroup extends ConsumerStatefulWidget {
  final List<CloudFile> files;

  const _DuplicateGroup({required this.files});

  @override
  ConsumerState<_DuplicateGroup> createState() => _DuplicateGroupState();
}

class _DuplicateGroupState extends ConsumerState<_DuplicateGroup> {
  late Set<String> _selectedIDs;

  @override
  void initState() {
    super.initState();
    _selectedIDs = widget.files.skip(1).map((file) => file.id).toSet();
  }

  Future<void> _confirmDelete() async {
    final targets = widget.files
        .where((file) => _selectedIDs.contains(file.id))
        .toList();
    if (targets.isEmpty) return;
    final confirmed = await showShadDialog<bool>(
      context: context,
      builder: (dialogContext) => ShadDialog(
        title: Text('删除 ${targets.length} 个重复文件？'),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          ShadButton.destructive(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除已选项'),
          ),
        ],
        child: const Padding(
          padding: EdgeInsets.only(top: 10),
          child: Text('同组至少会保留一项。删除后无法恢复，请确认选中的文件。'),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(fileProvider.notifier).deleteFiles(targets);
    if (mounted) setState(_selectedIDs.clear);
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final selectedCount = _selectedIDs.length;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.muted,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                '重复组 · ${widget.files.length} 项',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: cs.primary,
                ),
              ),
              const Spacer(),
              ShadButton.destructive(
                size: ShadButtonSize.sm,
                onPressed: selectedCount == 0 ? null : _confirmDelete,
                child: Text('删除已选 $selectedCount 项'),
              ),
            ],
          ),
          for (final file in widget.files)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Row(
                children: [
                  ShadCheckbox(
                    value: _selectedIDs.contains(file.id),
                    onChanged: (value) => setState(() {
                      if (value == true) {
                        if (_selectedIDs.length < widget.files.length - 1) {
                          _selectedIDs.add(file.id);
                        }
                      } else {
                        _selectedIDs.remove(file.id);
                      }
                    }),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          file.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          file.cloudPath,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.mutedForeground,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    _selectedIDs.contains(file.id) ? '将删除' : '保留',
                    style: TextStyle(
                      fontSize: 12,
                      color: _selectedIDs.contains(file.id)
                          ? cs.destructive
                          : cs.primary,
                    ),
                  ),
                ],
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
  final _filter = TextEditingController();
  final _previewHorizontalController = ScrollController();
  final _previewVerticalController = ScrollController();
  bool _preserveExtension = true;
  bool _running = false;
  int _completed = 0;
  int _total = 0;
  String _status = '';
  BatchRenameItemType _itemType = BatchRenameItemType.all;
  BatchRenameConflictStrategy _conflictStrategy =
      BatchRenameConflictStrategy.reject;
  final _selectedIDs = <String>{};
  late List<CloudFile> _candidates;
  late String? _sourceID;
  late String _sourceLabel;
  var _recursive = false;
  var _loadingCandidates = false;
  late List<BatchRenameRule> _rules;

  @override
  void initState() {
    super.initState();
    final state = ref.read(fileProvider);
    _sourceID = state.folderPath.isEmpty ? null : state.folderPath.last.id;
    _sourceLabel = state.folderPath.isEmpty
        ? '云盘根目录'
        : state.folderPath.map((folder) => folder.name).join(' / ');
    _candidates = (state.clipboard ?? state.files)
        .map(
          (file) => file.copyWith(
            cloudPath: _fullCloudPath(file.cloudPath, fallbackName: file.name),
          ),
        )
        .toList();
    _rules = [
      const BatchRenameRule(id: 'rule-0', kind: BatchRenameRuleKind.replace),
    ];
    _selectedIDs.addAll(_candidates.map((file) => file.id));
    Future.microtask(_enrichCandidatePaths);
  }

  @override
  void dispose() {
    _filter.dispose();
    _previewHorizontalController.dispose();
    _previewVerticalController.dispose();
    super.dispose();
  }

  void _updateRule(int index, BatchRenameRule rule) {
    setState(() => _rules[index] = rule);
  }

  void _moveRule(int index, int offset) {
    final destination = index + offset;
    if (destination < 0 || destination >= _rules.length) return;
    setState(() {
      final next = List<BatchRenameRule>.of(_rules);
      final rule = next[index];
      next[index] = next[destination];
      next[destination] = rule;
      _rules = next;
    });
  }

  String _fullCloudPath(String path, {required String fallbackName}) {
    final value = path.trim().isEmpty ? fallbackName : path.trim();
    if (value.startsWith('/')) return value;
    final source = _sourceLabel == '云盘根目录'
        ? ''
        : _sourceLabel.split(' / ').join('/');
    if (source.isEmpty) return '/$value';
    if (value == source || value.startsWith('$source/')) return '/$value';
    return '/$source/$value';
  }

  Future<void> _enrichCandidatePaths() async {
    final api = ref.read(authProvider.notifier).api;
    final detailCache = <String, Future<CloudFile?>>{};

    Future<CloudFile?> loadFolder(String id) =>
        detailCache.putIfAbsent(id, () async {
          try {
            final detail = await api.fsDetail(id);
            final values = _extractCandidates(detail);
            return values.cast<CloudFile?>().firstWhere(
              (file) => file?.id == id,
              orElse: () => null,
            );
          } catch (_) {
            return null;
          }
        });

    Future<String?> resolvePath(CloudFile file) async {
      final names = <String>[file.name];
      var parentID = file.parentID?.trim();
      final visited = <String>{file.id};
      while (parentID != null && parentID.isNotEmpty && visited.add(parentID)) {
        if (parentID == _sourceID && _sourceLabel != '云盘根目录') {
          names.insertAll(0, _sourceLabel.split(' / '));
          break;
        }
        final folder = await loadFolder(parentID);
        if (folder == null) return null;
        names.insert(0, folder.name);
        parentID = folder.parentID?.trim();
      }
      return '/${names.join('/')}';
    }

    final paths = await Future.wait(
      _candidates.map((file) async => (file, await resolvePath(file))),
    );
    if (!mounted) return;
    setState(() {
      final resolved = <String, String>{
        for (final entry in paths)
          if (entry.$2 != null) entry.$1.id: entry.$2!,
      };
      if (resolved.isEmpty) return;
      _candidates = _candidates
          .map(
            (file) => resolved.containsKey(file.id)
                ? file.copyWith(cloudPath: resolved[file.id])
                : file,
          )
          .toList();
    });
  }

  Future<void> _pickSource() async {
    final selection = await showShadDialog<_BatchRenameFolderSelection>(
      context: context,
      builder: (_) => _BatchRenameFolderPicker(initialID: _sourceID),
    );
    if (selection == null || !mounted) return;
    setState(() {
      _sourceID = selection.id;
      _sourceLabel = selection.label;
    });
    await _loadCandidates();
  }

  Future<void> _loadCandidates() async {
    if (_loadingCandidates) return;
    setState(() {
      _loadingCandidates = true;
      _status = '';
    });
    try {
      final api = ref.read(authProvider.notifier).api;
      final result = <CloudFile>[];
      final visitedFolders = <String>{};
      final queue = <_BatchRenameDirectoryNode>[
        _BatchRenameDirectoryNode(_sourceID, ''),
      ];
      while (queue.isNotEmpty) {
        final node = queue.removeLast();
        final response = await api.fsFiles(parentID: node.id, pageSize: 1000);
        final children = _extractCandidates(response);
        for (final child in children) {
          final path = node.path.isEmpty
              ? child.name
              : '${node.path}/${child.name}';
          final candidate = child.copyWith(
            cloudPath: _fullCloudPath(path, fallbackName: child.name),
          );
          result.add(candidate);
          if (_recursive &&
              candidate.isDirectory &&
              visitedFolders.add(candidate.id)) {
            queue.add(_BatchRenameDirectoryNode(candidate.id, path));
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _candidates = {
          for (final file in result) file.id: file,
        }.values.toList();
        _selectedIDs
          ..clear()
          ..addAll(_candidates.map((file) => file.id));
        _status = '已读取 ${_candidates.length} 项';
      });
    } catch (error) {
      if (mounted) setState(() => _status = error.toString());
    } finally {
      if (mounted) setState(() => _loadingCandidates = false);
    }
  }

  List<CloudFile> _extractCandidates(Map<String, dynamic> value) {
    final files = <CloudFile>[];
    void visit(dynamic node) {
      if (node is Map) {
        try {
          files.add(CloudFile.fromJson(Map<String, dynamic>.from(node)));
        } catch (_) {}
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
    return {for (final file in files) file.id: file}.values.toList();
  }

  Future<void> _confirmAndApply(List<BatchRenamePreview> previews) async {
    final changes = previews
        .where(
          (preview) =>
              preview.applicable && _selectedIDs.contains(preview.file.id),
        )
        .toList();
    if (changes.isEmpty || _running) return;
    final confirmed = await showShadDialog<bool>(
      context: context,
      builder: (dialogContext) => ShadDialog(
        title: Text('应用 ${changes.length} 项重命名？'),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          ShadButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('应用重命名'),
          ),
        ],
        child: const Padding(
          padding: EdgeInsets.only(top: 10),
          child: Text('名称修改会直接同步到云盘，请确认预览结果。'),
        ),
      ),
    );
    if (confirmed == true) await _apply(changes);
  }

  Future<void> _apply(List<BatchRenamePreview> changes) async {
    setState(() {
      _running = true;
      _completed = 0;
      _total = changes.length;
      _status = '';
    });
    final api = ref.read(authProvider.notifier).api;
    var succeeded = 0;
    var failed = 0;
    final renamedFiles = <CloudFile>[];
    try {
      for (final change in changes) {
        if (!mounted) return;
        setState(() => _status = change.file.name);
        try {
          await api.fsRename(change.file.id, change.newName);
          succeeded += 1;
          renamedFiles.add(change.file.copyWith(name: change.newName));
        } catch (_) {
          failed += 1;
        }
        if (mounted) setState(() => _completed += 1);
      }
      await ref.read(fileProvider.notifier).loadFiles();
      if (renamedFiles.isNotEmpty) {
        await ref
            .read(mediaLibraryProvider.notifier)
            .synchronizeRenamedFiles(renamedFiles);
      }
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _selectedIDs.clear();
          _status = failed == 0
              ? '已完成 $succeeded 项重命名'
              : '已完成 $succeeded 项，失败 $failed 项';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final files = _candidates;
    final allPreviews = buildRenamePreviews(
      files,
      _rules,
      preserveExtension: _preserveExtension,
      conflictStrategy: _conflictStrategy,
    );
    final filterText = _filter.text.trim().toLowerCase();
    final previews = allPreviews.where((preview) {
      final matchesType = switch (_itemType) {
        BatchRenameItemType.all => true,
        BatchRenameItemType.files => !preview.file.isDirectory,
        BatchRenameItemType.folders => preview.file.isDirectory,
      };
      return matchesType &&
          (filterText.isEmpty ||
              preview.file.name.toLowerCase().contains(filterText));
    }).toList();
    final applicable = previews.where((preview) => preview.applicable).toList();
    final selectedCount = applicable
        .where((preview) => _selectedIDs.contains(preview.file.id))
        .length;
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        _ToolSection(
          title: '数据源',
          description:
              '$_sourceLabel，已读取 ${files.length} 项；筛选后显示 ${previews.length} 项。',
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                SizedBox(
                  width: 132,
                  child: ShadSelect<BatchRenameItemType>(
                    key: ValueKey(_itemType),
                    initialValue: _itemType,
                    selectedOptionBuilder: (_, value) =>
                        Text(_itemTypeLabel(value)),
                    options: [
                      for (final value in BatchRenameItemType.values)
                        ShadOption(
                          value: value,
                          child: Text(_itemTypeLabel(value)),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _itemType = value);
                    },
                  ),
                ),
                SizedBox(
                  width: 152,
                  child: ShadSelect<BatchRenameConflictStrategy>(
                    key: ValueKey(_conflictStrategy),
                    initialValue: _conflictStrategy,
                    selectedOptionBuilder: (_, value) =>
                        Text(_conflictStrategyLabel(value)),
                    options: [
                      for (final value in BatchRenameConflictStrategy.values)
                        ShadOption(
                          value: value,
                          child: Text(_conflictStrategyLabel(value)),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _conflictStrategy = value);
                      }
                    },
                  ),
                ),
                SizedBox(
                  width: 220,
                  child: ShadInput(
                    controller: _filter,
                    placeholder: const Text('按原名称过滤'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                ShadCheckbox(
                  value: _preserveExtension,
                  label: const Text('保留扩展名'),
                  onChanged: (value) =>
                      setState(() => _preserveExtension = value),
                ),
                ShadCheckbox(
                  value: _recursive,
                  label: const Text('包含子文件夹'),
                  onChanged: _loadingCandidates
                      ? null
                      : (value) async {
                          setState(() => _recursive = value);
                          await _loadCandidates();
                        },
                ),
                ShadButton.outline(
                  onPressed: _loadingCandidates ? null : _pickSource,
                  leading: const Icon(Icons.folder_open_rounded, size: 16),
                  child: const Text('选择目录'),
                ),
                ShadButton.ghost(
                  onPressed: _loadingCandidates ? null : _loadCandidates,
                  leading: Icon(
                    _loadingCandidates
                        ? Icons.hourglass_top_rounded
                        : Icons.refresh_rounded,
                    size: 16,
                  ),
                  child: Text(_loadingCandidates ? '读取中' : '重新读取'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        _ToolSection(
          title: '规则链',
          description: '规则按从上到下的顺序应用。',
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = 0; index < _rules.length; index++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _BatchRenameRuleRow(
                      key: ValueKey(_rules[index].id),
                      rule: _rules[index],
                      isFirst: index == 0,
                      isLast: index == _rules.length - 1,
                      onChanged: (rule) => _updateRule(index, rule),
                      onMoveUp: () => _moveRule(index, -1),
                      onMoveDown: () => _moveRule(index, 1),
                      onRemove: () => setState(() {
                        _rules.removeAt(index);
                        if (_rules.isEmpty) {
                          _rules = const [
                            BatchRenameRule(
                              id: 'rule-0',
                              kind: BatchRenameRuleKind.replace,
                            ),
                          ];
                        }
                      }),
                    ),
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ShadButton.outline(
                      onPressed: () => setState(() {
                        _rules.add(
                          BatchRenameRule(
                            id: 'rule-${DateTime.now().microsecondsSinceEpoch}',
                            kind: BatchRenameRuleKind.replace,
                          ),
                        );
                      }),
                      leading: const Icon(Icons.add_rounded, size: 16),
                      child: const Text('添加规则'),
                    ),
                    ShadButton.ghost(
                      onPressed: () => setState(() {
                        _rules = const [
                          BatchRenameRule(
                            id: 'rule-0',
                            kind: BatchRenameRuleKind.replace,
                          ),
                        ];
                      }),
                      child: const Text('清空规则'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        _ToolSection(
          title: '预览',
          description: '可应用 ${applicable.length} 项，已选择 $selectedCount 项。',
          trailing: ShadButton(
            onPressed: _running || selectedCount == 0
                ? null
                : () => _confirmAndApply(previews),
            leading: Icon(
              _running ? Icons.hourglass_top_rounded : Icons.play_arrow_rounded,
              size: 16,
            ),
            child: Text(_running ? '正在应用 $_completed / $_total' : '应用重命名'),
          ),
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              children: [
                LayoutBuilder(
                  builder: (context, constraints) => Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ShadButton.outline(
                        onPressed: _running
                            ? null
                            : () => setState(() {
                                _selectedIDs
                                  ..clear()
                                  ..addAll(
                                    applicable.map((item) => item.file.id),
                                  );
                              }),
                        child: const Text('全选可应用项'),
                      ),
                      ShadButton.ghost(
                        onPressed: _running
                            ? null
                            : () => setState(_selectedIDs.clear),
                        child: const Text('全不选'),
                      ),
                      if (_status.isNotEmpty)
                        SizedBox(
                          width: constraints.maxWidth < 560
                              ? constraints.maxWidth
                              : 260,
                          child: Text(
                            _status,
                            textAlign: constraints.maxWidth < 560
                                ? TextAlign.left
                                : TextAlign.right,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: ShadTheme.of(
                                context,
                              ).colorScheme.mutedForeground,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  height: 360,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: ShadTheme.of(context).colorScheme.border,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: previews.isEmpty
                      ? Center(
                          child: Text(
                            '当前筛选条件下没有项目',
                            style: TextStyle(
                              color: ShadTheme.of(
                                context,
                              ).colorScheme.mutedForeground,
                            ),
                          ),
                        )
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            final tableWidth = constraints.maxWidth < 920
                                ? 920.0
                                : constraints.maxWidth;
                            return Scrollbar(
                              controller: _previewHorizontalController,
                              child: SingleChildScrollView(
                                controller: _previewHorizontalController,
                                scrollDirection: Axis.horizontal,
                                child: SizedBox(
                                  width: tableWidth,
                                  child: Column(
                                    children: [
                                      const _BatchRenamePreviewHeader(),
                                      const Divider(height: 1),
                                      Expanded(
                                        child: ListView.separated(
                                          controller:
                                              _previewVerticalController,
                                          primary: false,
                                          itemCount: previews.length,
                                          separatorBuilder: (_, _) =>
                                              const Divider(height: 1),
                                          itemBuilder: (context, index) {
                                            final preview = previews[index];
                                            final canSelect =
                                                preview.applicable;
                                            return _BatchRenamePreviewRow(
                                              preview: preview,
                                              selected: _selectedIDs.contains(
                                                preview.file.id,
                                              ),
                                              enabled: canSelect && !_running,
                                              onChanged: (selected) =>
                                                  setState(() {
                                                    if (selected == true &&
                                                        canSelect) {
                                                      _selectedIDs.add(
                                                        preview.file.id,
                                                      );
                                                    } else {
                                                      _selectedIDs.remove(
                                                        preview.file.id,
                                                      );
                                                    }
                                                  }),
                                            );
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

String _itemTypeLabel(BatchRenameItemType value) => switch (value) {
  BatchRenameItemType.all => '全部项目',
  BatchRenameItemType.files => '仅文件',
  BatchRenameItemType.folders => '仅文件夹',
};

String _conflictStrategyLabel(BatchRenameConflictStrategy value) =>
    switch (value) {
      BatchRenameConflictStrategy.reject => '同名：阻止执行',
      BatchRenameConflictStrategy.appendIndex => '同名：自动编号',
    };

String _ruleKindLabel(BatchRenameRuleKind value) => switch (value) {
  BatchRenameRuleKind.remove => '删除字符',
  BatchRenameRuleKind.replace => '查找替换',
  BatchRenameRuleKind.regex => '正则替换',
  BatchRenameRuleKind.prefix => '添加前缀',
  BatchRenameRuleKind.suffix => '添加后缀',
};

String _rulePatternPlaceholder(BatchRenameRuleKind value) => switch (value) {
  BatchRenameRuleKind.remove => '要删除的字符',
  BatchRenameRuleKind.replace => '查找内容',
  BatchRenameRuleKind.regex => '正则表达式，例如 \\s+',
  BatchRenameRuleKind.prefix => '前缀',
  BatchRenameRuleKind.suffix => '后缀',
};

class _BatchRenameDirectoryNode {
  final String? id;
  final String path;

  const _BatchRenameDirectoryNode(this.id, this.path);
}

class _BatchRenameFolderSelection {
  final String? id;
  final String label;

  const _BatchRenameFolderSelection(this.id, this.label);
}

class _BatchRenameFolderPicker extends ConsumerStatefulWidget {
  final String? initialID;

  const _BatchRenameFolderPicker({required this.initialID});

  @override
  ConsumerState<_BatchRenameFolderPicker> createState() =>
      _BatchRenameFolderPickerState();
}

class _BatchRenameFolderPickerState
    extends ConsumerState<_BatchRenameFolderPicker> {
  final _path = <CloudFile>[];
  var _folders = <CloudFile>[];
  var _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  String? get _parentID => _path.isEmpty ? null : _path.last.id;
  String get _label =>
      _path.isEmpty ? '云盘根目录' : _path.map((folder) => folder.name).join(' / ');

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await ref
          .read(authProvider.notifier)
          .api
          .fsFiles(parentID: _parentID, pageSize: 1000);
      if (!mounted) return;
      setState(() {
        _folders = _extractFolders(
          response,
        )..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<CloudFile> _extractFolders(Map<String, dynamic> value) {
    final folders = <CloudFile>[];
    void visit(dynamic node) {
      if (node is Map) {
        try {
          final file = CloudFile.fromJson(Map<String, dynamic>.from(node));
          if (file.isDirectory) folders.add(file);
        } catch (_) {}
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
    return {for (final folder in folders) folder.id: folder}.values.toList();
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ShadDialog(
      title: const Text('选择重命名目录'),
      description: Text('当前：$_label'),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ShadButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(_BatchRenameFolderSelection(_parentID, _label)),
          leading: const Icon(Icons.check_rounded, size: 16),
          child: const Text('使用此目录'),
        ),
      ],
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 560;
          return SizedBox(
            width: narrow ? constraints.maxWidth : 540,
            height: narrow ? 420 : 360,
            child: Column(
              children: [
                Row(
                  children: [
                    ShadButton.ghost(
                      size: ShadButtonSize.sm,
                      onPressed: _path.isEmpty
                          ? null
                          : () {
                              setState(() => _path.removeLast());
                              _load();
                            },
                      leading: const Icon(Icons.arrow_back_rounded, size: 16),
                      child: narrow
                          ? const SizedBox.shrink()
                          : const Text('返回上级'),
                    ),
                    const Spacer(),
                    ShadTooltip(
                      builder: (_) => const Text('刷新文件夹'),
                      child: ShadButton.ghost(
                        size: ShadButtonSize.sm,
                        onPressed: _loading ? null : _load,
                        child: const Icon(Icons.refresh_rounded, size: 16),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _loading
                      ? const Center(
                          child: AppLoadingIndicator(
                            size: AppLoadingSize.page,
                            label: '正在读取目录',
                          ),
                        )
                      : _error != null
                      ? Center(
                          child: Text(
                            _error!,
                            style: TextStyle(color: cs.destructive),
                          ),
                        )
                      : _folders.isEmpty
                      ? Center(
                          child: Text(
                            '没有子文件夹',
                            style: TextStyle(color: cs.mutedForeground),
                          ),
                        )
                      : ListView.separated(
                          itemCount: _folders.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final folder = _folders[index];
                            return ListTile(
                              leading: Icon(
                                Icons.folder_rounded,
                                color: cs.primary,
                              ),
                              title: Text(folder.name),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () {
                                setState(() => _path.add(folder));
                                _load();
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _BatchRenameRuleRow extends StatelessWidget {
  final BatchRenameRule rule;
  final bool isFirst;
  final bool isLast;
  final ValueChanged<BatchRenameRule> onChanged;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onRemove;

  const _BatchRenameRuleRow({
    super.key,
    required this.rule,
    required this.isFirst,
    required this.isLast,
    required this.onChanged,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final hasReplacement =
        rule.kind == BatchRenameRuleKind.replace ||
        rule.kind == BatchRenameRuleKind.regex;
    final supportsCase =
        hasReplacement || rule.kind == BatchRenameRuleKind.remove;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.muted.withValues(alpha: 0.46),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.border.withValues(alpha: 0.65)),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ShadCheckbox(
            value: rule.enabled,
            label: const Text('启用'),
            onChanged: (value) => onChanged(rule.copyWith(enabled: value)),
          ),
          SizedBox(
            width: 132,
            child: ShadSelect<BatchRenameRuleKind>(
              key: ValueKey('${rule.id}-${rule.kind}'),
              initialValue: rule.kind,
              selectedOptionBuilder: (_, value) => Text(_ruleKindLabel(value)),
              options: [
                for (final value in BatchRenameRuleKind.values)
                  ShadOption(value: value, child: Text(_ruleKindLabel(value))),
              ],
              onChanged: (value) {
                if (value != null) onChanged(rule.copyWith(kind: value));
              },
            ),
          ),
          SizedBox(
            width: 190,
            child: ShadInput(
              initialValue: rule.pattern,
              placeholder: Text(_rulePatternPlaceholder(rule.kind)),
              onChanged: (value) => onChanged(rule.copyWith(pattern: value)),
            ),
          ),
          if (hasReplacement) ...[
            const Icon(Icons.arrow_right_alt_rounded, size: 18),
            SizedBox(
              width: 160,
              child: ShadInput(
                initialValue: rule.replacement,
                placeholder: const Text('替换为'),
                onChanged: (value) =>
                    onChanged(rule.copyWith(replacement: value)),
              ),
            ),
          ],
          if (supportsCase)
            ShadCheckbox(
              value: rule.ignoreCase,
              label: const Text('忽略大小写'),
              onChanged: (value) => onChanged(rule.copyWith(ignoreCase: value)),
            ),
          _RenameRuleIconButton(
            icon: Icons.arrow_upward_rounded,
            tooltip: '上移规则',
            enabled: !isFirst,
            onPressed: onMoveUp,
          ),
          _RenameRuleIconButton(
            icon: Icons.arrow_downward_rounded,
            tooltip: '下移规则',
            enabled: !isLast,
            onPressed: onMoveDown,
          ),
          _RenameRuleIconButton(
            icon: Icons.delete_outline_rounded,
            tooltip: '删除规则',
            enabled: true,
            destructive: true,
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _RenameRuleIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool enabled;
  final bool destructive;
  final VoidCallback onPressed;

  const _RenameRuleIconButton({
    required this.icon,
    required this.tooltip,
    required this.enabled,
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
        onPressed: enabled ? onPressed : null,
        child: Icon(icon, size: 16, color: destructive ? cs.destructive : null),
      ),
    );
  }
}

class _BatchRenamePreviewHeader extends StatelessWidget {
  const _BatchRenamePreviewHeader();

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final style = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      color: cs.mutedForeground,
    );
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: cs.muted.withValues(alpha: 0.28),
      child: Row(
        children: [
          const SizedBox(width: 64),
          Expanded(flex: 3, child: Text('名称变更', style: style)),
          Expanded(flex: 4, child: Text('完整路径', style: style)),
          SizedBox(width: 270, child: Text('GCID', style: style)),
          SizedBox(
            width: 130,
            child: Text('状态', textAlign: TextAlign.right, style: style),
          ),
        ],
      ),
    );
  }
}

class _BatchRenamePreviewRow extends StatelessWidget {
  final BatchRenamePreview preview;
  final bool selected;
  final bool enabled;
  final ValueChanged<bool?> onChanged;

  const _BatchRenamePreviewRow({
    required this.preview,
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final changed = preview.changed;
    final rawPath = preview.file.cloudPath.trim();
    final path = rawPath.isEmpty
        ? preview.file.name
        : (rawPath.startsWith('/') ? rawPath : '/$rawPath');
    final gcid = preview.file.gcid?.trim();
    final gcidText = gcid?.isNotEmpty == true ? gcid! : '未获取';
    final status = preview.error ?? (changed ? '将修改' : '无变化');
    final statusColor = preview.error != null
        ? cs.destructive
        : changed
        ? cs.primary
        : cs.mutedForeground;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        children: [
          ShadCheckbox(value: selected, onChanged: enabled ? onChanged : null),
          const SizedBox(width: 10),
          Icon(
            preview.file.isDirectory
                ? Icons.folder_rounded
                : Icons.insert_drive_file_rounded,
            size: 18,
            color: preview.file.isDirectory ? cs.primary : cs.mutedForeground,
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '原  ${preview.file.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                ),
                const SizedBox(height: 4),
                Text(
                  '新  ${preview.newName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: statusColor,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            flex: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
              decoration: BoxDecoration(
                color: cs.muted.withValues(alpha: 0.48),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.folder_outlined,
                    size: 14,
                    color: cs.mutedForeground,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: SelectableText(
                      path,
                      maxLines: 1,
                      style: TextStyle(fontSize: 11, color: cs.mutedForeground),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 14),
          SizedBox(
            width: 270,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  'GCID',
                  style: TextStyle(fontSize: 10, color: cs.mutedForeground),
                ),
                const SizedBox(height: 3),
                SelectableText(
                  gcidText,
                  maxLines: 1,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: gcid?.isNotEmpty == true
                        ? cs.mutedForeground
                        : cs.destructive,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 118,
            child: Text(
              status,
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: statusColor,
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

enum _FastTransferTaskState { imported, skipped, failed, cancelled }

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

class _FastTransferTaskResult {
  final FastTransferEntry entry;
  final _FastTransferTaskState state;
  final String message;

  const _FastTransferTaskResult({
    required this.entry,
    required this.state,
    required this.message,
  });

  Map<String, dynamic> toJson() => {
    'entry': entry.toJson(),
    'state': state.name,
    'message': message,
  };

  factory _FastTransferTaskResult.fromJson(Map<String, dynamic> value) {
    final state = _FastTransferTaskState.values.firstWhere(
      (candidate) => candidate.name == value['state']?.toString(),
      orElse: () => _FastTransferTaskState.failed,
    );
    return _FastTransferTaskResult(
      entry: FastTransferEntry.fromJson(
        Map<String, dynamic>.from(value['entry'] as Map),
      ),
      state: state,
      message: value['message']?.toString() ?? '',
    );
  }
}

class _FastTransferToolState extends ConsumerState<_FastTransferTool> {
  final _json = TextEditingController();
  bool _running = false;
  bool _paused = false;
  bool _cancelRequested = false;
  bool _createDirectories = true;
  bool _skipExisting = true;
  bool _generating = false;
  int _generated = 0;
  int _generationTotal = 0;
  String _generationName = '';
  String _result = '';
  var _taskResults = <_FastTransferTaskResult>[];

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
      _taskResults =
          (raw['results'] as List?)
              ?.whereType<Map>()
              .map(
                (value) => _FastTransferTaskResult.fromJson(
                  Map<String, dynamic>.from(value),
                ),
              )
              .toList() ??
          [];
    }
  }

  @override
  void dispose() {
    _json.dispose();
    super.dispose();
  }

  Future<void> _submit({List<FastTransferEntry>? retryEntries}) async {
    late final List<FastTransferEntry> entries;
    if (retryEntries != null) {
      entries = retryEntries;
    } else {
      try {
        entries = parseFastTransferJSON(_json.text);
      } catch (error) {
        setState(() => _result = error.toString());
        return;
      }
    }
    setState(() {
      _running = true;
      _paused = false;
      _cancelRequested = false;
      _result = '';
      if (retryEntries == null) {
        _taskResults = [];
      } else {
        final retryPaths = retryEntries.map((entry) => entry.path).toSet();
        _taskResults.removeWhere(
          (result) => retryPaths.contains(result.entry.path),
        );
      }
    });
    await StorageManager.set(StorageKeys.fastTransferSession, {
      'entries': entries.map((entry) => entry.toJson()).toList(),
      'result': '待执行 ${entries.length} 项',
      'results': _taskResults.map((result) => result.toJson()).toList(),
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
        while (nextIndex < entries.length && !_cancelRequested) {
          while (_paused && !_cancelRequested) {
            await Future<void>.delayed(const Duration(milliseconds: 150));
          }
          if (_cancelRequested) return;
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
              _recordTaskResult(
                entry,
                _FastTransferTaskState.skipped,
                '目标目录已有同名文件',
              );
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
            _recordTaskResult(entry, _FastTransferTaskState.imported, '秒传成功');
          } catch (error) {
            failed += 1;
            _recordTaskResult(
              entry,
              _FastTransferTaskState.failed,
              error.toString(),
            );
          }
          if (mounted) {
            setState(
              () => _result = '已处理 ${completed + failed}/${entries.length} 项',
            );
          }
        }
      }

      await Future.wait(List.generate(concurrency, (_) => worker()));
      if (_cancelRequested) {
        final handled = _taskResults.map((result) => result.entry.path).toSet();
        for (final entry in entries.where(
          (entry) => !handled.contains(entry.path),
        )) {
          _recordTaskResult(entry, _FastTransferTaskState.cancelled, '任务已终止');
        }
      }
      await ref.read(fileProvider.notifier).loadFiles();
      if (mounted) {
        setState(
          () => _result = _cancelRequested
              ? '秒传已终止：成功 $completed，失败 $failed，待处理 ${entries.length - completed - failed}'
              : '秒传完成：成功 $completed，失败 $failed',
        );
      }
      await StorageManager.set(StorageKeys.fastTransferSession, {
        'entries': entries.map((entry) => entry.toJson()).toList(),
        'result': _cancelRequested
            ? '秒传已终止：成功 $completed，失败 $failed'
            : '秒传完成：成功 $completed，失败 $failed',
        'results': _taskResults.map((result) => result.toJson()).toList(),
      });
    } catch (error) {
      if (mounted) {
        setState(() => _result = '已提交 $completed / ${entries.length} 个：$error');
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _generateLocalJson() async {
    if (_generating || _running) return;
    final picked = await FilePicker.pickFiles(type: FileType.any);
    if (picked == null) return;
    final files = picked.paths
        .whereType<String>()
        .map(File.new)
        .where((file) => file.existsSync())
        .toList();
    if (files.isEmpty) return;
    setState(() {
      _generating = true;
      _generated = 0;
      _generationTotal = files.length;
      _generationName = '';
      _result = '';
    });
    final entries = <FastTransferEntry>[];
    var failures = 0;
    try {
      for (final file in files) {
        if (!mounted) return;
        setState(() => _generationName = file.path.split('/').last);
        try {
          final stat = await file.stat();
          final hashes = await _calculateLocalHashes(file, stat.size);
          entries.add(
            FastTransferEntry.create(
              path: file.path.split('/').last,
              size: stat.size,
              md5: hashes.$1,
              gcid: hashes.$2,
            ),
          );
        } catch (_) {
          failures += 1;
        }
        if (mounted) setState(() => _generated += 1);
      }
      if (!mounted) return;
      setState(() {
        _json.text = const JsonEncoder.withIndent(
          '  ',
        ).convert({'files': entries.map((entry) => entry.toJson()).toList()});
        _result = failures == 0
            ? '已生成 ${entries.length} 个本地文件的秒传 JSON'
            : '已生成 ${entries.length} 项，$failures 项无法读取';
      });
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<(String, String)> _calculateLocalHashes(File file, int size) async {
    final chunkSize = switch (size) {
      <= 0x8000000 => 262144,
      <= 0x10000000 => 524288,
      <= 0x20000000 => 1048576,
      _ => 2097152,
    };
    final fileHandle = await file.open(mode: FileMode.read);
    final md5Sink = _DigestSink();
    final md5Converter = md5.startChunkedConversion(md5Sink);
    final chunkHashes = <int>[];
    try {
      while (true) {
        final chunk = await fileHandle.read(chunkSize);
        if (chunk.isEmpty) break;
        md5Converter.add(chunk);
        chunkHashes.addAll(sha1.convert(chunk).bytes);
      }
    } finally {
      md5Converter.close();
      await fileHandle.close();
    }
    final md5Text = md5Sink.value?.toString();
    if (md5Text == null) throw StateError('无法计算 MD5');
    final gcid = sha1.convert(chunkHashes).toString().toUpperCase();
    return (md5Text, gcid);
  }

  void _recordTaskResult(
    FastTransferEntry entry,
    _FastTransferTaskState state,
    String message,
  ) {
    if (!mounted) return;
    setState(() {
      _taskResults.removeWhere((result) => result.entry.path == entry.path);
      _taskResults.add(
        _FastTransferTaskResult(entry: entry, state: state, message: message),
      );
      _result = '已处理 ${_taskResults.length} 项';
    });
  }

  Future<void> _retryFailed() async {
    final entries = _taskResults
        .where((result) => result.state == _FastTransferTaskState.failed)
        .map((result) => result.entry)
        .toList();
    if (entries.isNotEmpty) await _submit(retryEntries: entries);
  }

  IconData _taskIcon(_FastTransferTaskState state) => switch (state) {
    _FastTransferTaskState.imported => Icons.check_circle_outline_rounded,
    _FastTransferTaskState.skipped => Icons.skip_next_rounded,
    _FastTransferTaskState.failed => Icons.error_outline_rounded,
    _FastTransferTaskState.cancelled => Icons.cancel_outlined,
  };

  Color _taskColor(ShadColorScheme cs, _FastTransferTaskState state) =>
      switch (state) {
        _FastTransferTaskState.imported => cs.primary,
        _FastTransferTaskState.skipped => cs.mutedForeground,
        _FastTransferTaskState.failed => cs.destructive,
        _FastTransferTaskState.cancelled => cs.mutedForeground,
      };

  String _taskTitle(_FastTransferTaskState state) => switch (state) {
    _FastTransferTaskState.imported => '已秒传',
    _FastTransferTaskState.skipped => '已跳过',
    _FastTransferTaskState.failed => '失败',
    _FastTransferTaskState.cancelled => '已取消',
  };

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
            trailing: _running
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ShadButton.outline(
                        onPressed: () => setState(() => _paused = !_paused),
                        leading: Icon(
                          _paused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                          size: 16,
                        ),
                        child: Text(_paused ? '继续' : '暂停'),
                      ),
                      const SizedBox(width: 8),
                      ShadButton.destructive(
                        onPressed: () =>
                            setState(() => _cancelRequested = true),
                        leading: const Icon(Icons.stop_rounded, size: 16),
                        child: const Text('终止'),
                      ),
                    ],
                  )
                : ShadButton(
                    onPressed: _submit,
                    leading: const Icon(Icons.bolt_rounded, size: 16),
                    child: const Text('开始秒传'),
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
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ShadButton.outline(
                      onPressed: _generating || _running
                          ? null
                          : _generateLocalJson,
                      leading: Icon(
                        _generating
                            ? Icons.hourglass_top_rounded
                            : Icons.file_open_rounded,
                        size: 16,
                      ),
                      child: Text(_generating ? '正在生成 JSON' : '从本地文件生成 JSON'),
                    ),
                  ),
                  if (_generating) ...[
                    const SizedBox(height: 8),
                    Semantics(
                      label: '正在计算本地文件校验值：$_generated / $_generationTotal',
                      child: const Align(
                        alignment: Alignment.centerLeft,
                        child: AppLoadingIndicator(
                          size: AppLoadingSize.compact,
                          semanticsLabel: '正在计算本地文件校验值',
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$_generated / $_generationTotal ${_generationName.isEmpty ? '' : _generationName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                    ),
                  ],
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
          if (_running) ...[
            const SizedBox(height: 12),
            const Align(
              alignment: Alignment.centerLeft,
              child: AppLoadingIndicator(
                size: AppLoadingSize.compact,
                label: '正在执行秒传任务',
              ),
            ),
          ],
          if (_result.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_result, style: TextStyle(color: cs.mutedForeground)),
          ],
          if (_taskResults.isNotEmpty) ...[
            const SizedBox(height: 12),
            _ToolSection(
              title: '任务结果',
              description:
                  '成功 ${_taskResults.where((result) => result.state == _FastTransferTaskState.imported).length} 项，失败 ${_taskResults.where((result) => result.state == _FastTransferTaskState.failed).length} 项。',
              trailing: ShadButton.outline(
                onPressed:
                    _running ||
                        !_taskResults.any(
                          (result) =>
                              result.state == _FastTransferTaskState.failed,
                        )
                    ? null
                    : _retryFailed,
                leading: const Icon(Icons.refresh_rounded, size: 16),
                child: const Text('重试失败项'),
              ),
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: SizedBox(
                  height: 210,
                  child: ListView.separated(
                    itemCount: _taskResults.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final task = _taskResults[index];
                      final color = _taskColor(cs, task.state);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            Icon(_taskIcon(task.state), size: 17, color: color),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    task.entry.path,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  Text(
                                    task.message,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: cs.mutedForeground,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _taskTitle(task.state),
                              style: TextStyle(fontSize: 12, color: color),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
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

class _MediaOrganizerFilePicker extends ConsumerStatefulWidget {
  const _MediaOrganizerFilePicker();

  @override
  ConsumerState<_MediaOrganizerFilePicker> createState() =>
      _MediaOrganizerFilePickerState();
}

class _MediaOrganizerFilePickerState
    extends ConsumerState<_MediaOrganizerFilePicker> {
  final _path = <CloudFile>[];
  List<CloudFile> _files = const [];
  bool _loading = true;
  String? _error;

  String? get _parentID => _path.lastOrNull?.id;
  String get _pathLabel =>
      _path.isEmpty ? '云盘根目录' : _path.map((file) => file.name).join(' / ');

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await ref
          .read(authProvider.notifier)
          .api
          .fsFiles(parentID: _parentID, pageSize: 1000);
      final files =
          _extractCloudFiles(
              response,
            ).where((file) => file.isDirectory || file.isVideo).toList()
            ..sort((a, b) {
              if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
              return a.name.toLowerCase().compareTo(b.name.toLowerCase());
            });
      if (mounted) setState(() => _files = files);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<CloudFile> _extractCloudFiles(Map<String, dynamic> response) {
    final files = <String, CloudFile>{};
    void visit(dynamic node) {
      if (node is Map) {
        try {
          final file = CloudFile.fromJson(Map<String, dynamic>.from(node));
          if (file.id.isNotEmpty) files[file.id] = file;
        } catch (_) {}
        for (final child in node.values) {
          visit(child);
        }
      } else if (node is List) {
        for (final child in node) {
          visit(child);
        }
      }
    }

    visit(response);
    return files.values.toList(growable: false);
  }

  void _selectFile(CloudFile file) {
    final path = _pathLabel == '云盘根目录'
        ? '/${file.name}'
        : '/$_pathLabel/${file.name}';
    Navigator.of(
      context,
    ).pop(file.copyWith(parentID: _parentID, cloudPath: path));
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ShadDialog(
      title: const Text('选择整理起点'),
      description: Text('选择一个媒体文件，将整理它所在文件夹中的已识别视频。\n当前：$_pathLabel'),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
      child: Material(
        type: MaterialType.transparency,
        child: SizedBox(
          width: 620,
          height: 430,
          child: Column(
            children: [
              Row(
                children: [
                  ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    onPressed: _path.isEmpty
                        ? null
                        : () {
                            setState(() => _path.removeLast());
                            _load();
                          },
                    leading: const Icon(Icons.arrow_back_rounded, size: 16),
                    child: const Text('返回上级'),
                  ),
                  const Spacer(),
                  ShadTooltip(
                    builder: (_) => const Text('刷新'),
                    child: ShadButton.ghost(
                      size: ShadButtonSize.sm,
                      onPressed: _loading ? null : _load,
                      child: const Icon(Icons.refresh_rounded, size: 16),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: cs.border),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: _loading
                      ? const Center(
                          child: AppLoadingIndicator(
                            size: AppLoadingSize.page,
                            label: '正在读取目录',
                          ),
                        )
                      : _error != null
                      ? Center(
                          child: Text(
                            _error!,
                            style: TextStyle(color: cs.destructive),
                          ),
                        )
                      : _files.isEmpty
                      ? Center(
                          child: Text(
                            '当前目录没有文件夹或视频',
                            style: TextStyle(color: cs.mutedForeground),
                          ),
                        )
                      : ListView.separated(
                          itemCount: _files.length,
                          separatorBuilder: (_, _) =>
                              Divider(height: 1, color: cs.border),
                          itemBuilder: (context, index) {
                            final file = _files[index];
                            return ListTile(
                              leading: Icon(
                                file.isDirectory
                                    ? Icons.folder_rounded
                                    : Icons.movie_outlined,
                                color: file.isDirectory
                                    ? cs.primary
                                    : cs.mutedForeground,
                              ),
                              title: Text(
                                file.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: file.isDirectory
                                  ? null
                                  : Text(file.formattedSize),
                              trailing: Icon(
                                file.isDirectory
                                    ? Icons.chevron_right_rounded
                                    : Icons.check_circle_outline_rounded,
                                size: 18,
                              ),
                              onTap: file.isDirectory
                                  ? () {
                                      setState(() => _path.add(file));
                                      _load();
                                    }
                                  : () => _selectFile(file),
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MediaOrganizerEntry {
  final MediaLibraryItem item;
  final String? rootID;
  final List<String> folders;
  final String targetPath;

  const _MediaOrganizerEntry({
    required this.item,
    required this.rootID,
    required this.folders,
    required this.targetPath,
  });
}

class _MediaOrganizerTool extends ConsumerStatefulWidget {
  const _MediaOrganizerTool();

  @override
  ConsumerState<_MediaOrganizerTool> createState() =>
      _MediaOrganizerToolState();
}

class _MediaOrganizerToolState extends ConsumerState<_MediaOrganizerTool> {
  List<_MediaOrganizerEntry> _entries = const [];
  final _selectedKeys = <String>{};
  final _folderIDs = <String, String>{};
  final _tmdbDetailsCache = <String, Map<String, dynamic>>{};
  final _destinationFiles = <String, Map<String, String>>{};
  final _failures = <String, String>{};
  CloudFile? _anchorFile;
  String? _libraryName;
  int _folderVideoCount = 0;
  int _unmatchedCount = 0;
  bool _loading = false;
  bool _running = false;
  bool _stopRequested = false;
  int _runTotal = 0;
  int _completed = 0;
  int _failed = 0;
  String _status = '';

  String _key(MediaLibraryItem item) => '${item.libraryID}:${item.id}';

  List<MediaCategoryRule> _categoryRules() {
    final raw = StorageManager.get<dynamic>(StorageKeys.mediaCategoryRules);
    if (raw is! List) return MediaCategoryRule.presets();
    return raw
        .whereType<Map>()
        .map(
          (value) =>
              MediaCategoryRule.fromJson(Map<String, dynamic>.from(value)),
        )
        .toList(growable: false);
  }

  String _categoryFor(
    TMDBMediaKind kind,
    String language,
    List<MediaCategoryRule> rules,
  ) {
    final sameKind = rules.where((rule) => rule.mediaKind == kind).toList();
    final normalized = language.trim().toLowerCase();
    final explicit = sameKind
        .where((rule) => !rule.isFallback)
        .where((rule) => rule.languages.contains(normalized))
        .firstOrNull;
    return explicit?.name ??
        sameKind.where((rule) => rule.isFallback).firstOrNull?.name ??
        (kind == TMDBMediaKind.movie ? '其他电影' : '其他剧集');
  }

  Future<void> _prepare() async {
    if (_loading || _running) return;
    final state = ref.read(mediaLibraryProvider);
    final anchorFile = _anchorFile;
    if (anchorFile == null) {
      setState(() => _status = '请先选择一个媒体文件');
      return;
    }
    setState(() {
      _loading = true;
      _status = '正在读取已识别项目';
    });
    try {
      final folderResponse = await ref
          .read(authProvider.notifier)
          .api
          .fsFiles(parentID: anchorFile.parentID, pageSize: 1000);
      final folderFiles = _extractFiles(folderResponse)
          .where((file) => !file.isDirectory && file.isVideo)
          .toList(growable: false);
      final folderIDs = folderFiles.map((file) => file.id).toSet();
      final library = _libraryForFolder(anchorFile, folderIDs, state);
      if (library == null) {
        if (mounted) {
          setState(() {
            _entries = const [];
            _status = '当前文件夹的内容未关联到任何媒体库';
          });
        }
        return;
      }
      final items = <(String, String), MediaLibraryItem>{
        for (final item in state.allItems)
          if (item.libraryID == library.id &&
              folderIDs.contains(item.file.id) &&
              item.tmdbID != null &&
              (item.mediaKind == TMDBMediaKind.movie ||
                  item.mediaKind == TMDBMediaKind.tv))
            (item.libraryID, item.id): item,
      }.values.toList(growable: false);
      final api = ref.read(authProvider.notifier).api;
      final apiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
      final proxyHost =
          StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '';
      final proxyPort =
          StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '';
      final details = <String, Map<String, dynamic>>{
        for (final entry in _tmdbDetailsCache.entries) entry.key: entry.value,
      };
      final prototypes = <String, MediaLibraryItem>{
        for (final item in items)
          if (!details.containsKey('${item.mediaKind!.name}:${item.tmdbID}'))
            '${item.mediaKind!.name}:${item.tmdbID}': item,
      }.values.toList(growable: false);
      for (var start = 0; start < prototypes.length; start += 4) {
        final batch = prototypes.sublist(
          start,
          (start + 4).clamp(0, prototypes.length),
        );
        final values = await Future.wait(
          batch.map((item) async {
            if (apiKey.isEmpty) {
              return (item: item, detail: <String, dynamic>{});
            }
            try {
              final detail = await api.tmdbDetails(
                item.tmdbID!,
                mediaKind: item.mediaKind!.name,
                apiKey: apiKey,
                proxyHost: proxyHost,
                proxyPort: proxyPort,
              );
              return (item: item, detail: detail);
            } catch (_) {
              return (item: item, detail: <String, dynamic>{});
            }
          }),
        );
        for (final value in values) {
          final key = '${value.item.mediaKind!.name}:${value.item.tmdbID}';
          details[key] = value.detail;
          if (value.detail.isNotEmpty) _tmdbDetailsCache[key] = value.detail;
        }
      }
      final rules = _categoryRules();
      final entries = <_MediaOrganizerEntry>[];
      for (final item in items) {
        final detail = details['${item.mediaKind!.name}:${item.tmdbID}'];
        final language =
            (detail?['original_language'] ?? detail?['originalLanguage'] ?? '')
                .toString();
        final category = _categoryFor(item.mediaKind!, language, rules);
        final year = item.year.isEmpty ? '0000' : item.year;
        final workName = safeMediaCloudName(
          '${item.title} ($year) {tmdb-${item.tmdbID}}',
        );
        final parsed = ParsedMediaName.parse(
          item.file.name,
          directoryName: item.file.cloudPath
              .replaceAll(RegExp(r'\\+'), '/')
              .split('/')
              .where((part) => part.isNotEmpty)
              .toList()
              .reversed
              .skip(1)
              .firstOrNull,
          directoryPath: item.file.cloudPath,
        );
        final folders = <String>[
          item.mediaKind == TMDBMediaKind.movie ? '电影' : '剧集',
          safeMediaCloudName(category),
          year,
          workName,
          if (item.mediaKind == TMDBMediaKind.tv && parsed.season != null)
            'Season ${parsed.season!.toString().padLeft(2, '0')}',
        ];
        final currentPath = _parentPath(anchorFile.cloudPath);
        final targetPath = [
          if (currentPath.isNotEmpty) currentPath,
          ...folders,
        ].join('/');
        entries.add(
          _MediaOrganizerEntry(
            item: item,
            rootID: anchorFile.parentID,
            folders: folders,
            targetPath: targetPath,
          ),
        );
      }
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _anchorFile = anchorFile;
        _libraryName = library.name;
        _folderVideoCount = folderFiles.length;
        _unmatchedCount = folderFiles.length - items.length;
        _failures.clear();
        _selectedKeys.clear();
        _status = entries.isEmpty
            ? '所选文件夹没有可整理的已识别资源'
            : '已读取 ${folderFiles.length} 个视频，生成 ${entries.length} 条整理预览';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  MediaLibraryDefinition? _libraryForFolder(
    CloudFile file,
    Set<String> folderFileIDs,
    MediaLibraryState state,
  ) {
    final counts = <String, int>{};
    for (final item in state.allItems) {
      if (folderFileIDs.contains(item.file.id)) {
        counts.update(item.libraryID, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    if (counts.isNotEmpty) {
      final libraryID = counts.entries
          .reduce((a, b) => a.value >= b.value ? a : b)
          .key;
      final indexed = state.libraries
          .where((library) => library.id == libraryID)
          .firstOrNull;
      if (indexed != null) return indexed;
    }
    final path = file.cloudPath.replaceAll(RegExp(r'\\+'), '/');
    final matches = <MediaLibraryDefinition>[];
    for (final library in state.libraries) {
      if (library.sources.any((source) {
        final sourcePath = source.path
            .replaceAll(RegExp(r'\\+'), '/')
            .replaceFirst(RegExp(r'/$'), '');
        return source.rootID == file.parentID ||
            (sourcePath.isNotEmpty &&
                (path == sourcePath || path.startsWith('$sourcePath/')));
      })) {
        matches.add(library);
      }
    }
    matches.sort((a, b) => b.rootPath.length.compareTo(a.rootPath.length));
    return matches.firstOrNull;
  }

  String _parentPath(String path) {
    final normalized = path.replaceAll(RegExp(r'\\+'), '/');
    final index = normalized.lastIndexOf('/');
    if (index <= 0) return '';
    return normalized.substring(0, index);
  }

  Future<void> _chooseFile() async {
    final file = await showShadDialog<CloudFile>(
      context: context,
      builder: (_) => const _MediaOrganizerFilePicker(),
    );
    if (file == null || !mounted) return;
    setState(() {
      _anchorFile = file;
      _libraryName = null;
      _folderVideoCount = 0;
      _unmatchedCount = 0;
      _entries = const [];
      _failures.clear();
      _status = '正在读取 ${file.name} 所在文件夹';
    });
    await _prepare();
  }

  List<CloudFile> _extractFiles(Map<String, dynamic> value) {
    final files = <String, CloudFile>{};
    void visit(dynamic node) {
      if (node is Map) {
        try {
          final file = CloudFile.fromJson(Map<String, dynamic>.from(node));
          files[file.id] = file;
        } catch (_) {}
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
    return files.values.toList(growable: false);
  }

  String? _findID(dynamic node) {
    if (node is Map) {
      for (final key in const ['fileId', 'file_id', 'resId', 'id']) {
        final value = node[key];
        if (value != null && value.toString().trim().isNotEmpty) {
          return value.toString();
        }
      }
      for (final child in node.values) {
        final value = _findID(child);
        if (value != null) return value;
      }
    } else if (node is List) {
      for (final child in node) {
        final value = _findID(child);
        if (value != null) return value;
      }
    }
    return null;
  }

  Future<String> _ensureFolder(String? parentID, String name) async {
    final cacheKey = '${parentID ?? '@root'}/$name';
    final cached = _folderIDs[cacheKey];
    if (cached != null) return cached;
    final api = ref.read(authProvider.notifier).api;
    final response = await api.fsFiles(parentID: parentID, pageSize: 1000);
    final existing = _extractFiles(
      response,
    ).where((file) => file.isDirectory && file.name == name).firstOrNull;
    if (existing != null) {
      _folderIDs[cacheKey] = existing.id;
      return existing.id;
    }
    final created = await api.fsCreateDir(name, parentID: parentID);
    var id = _extractFiles(
      created,
    ).where((file) => file.isDirectory && file.name == name).firstOrNull?.id;
    if (id == null || id.isEmpty) {
      final refreshed = await api.fsFiles(parentID: parentID, pageSize: 1000);
      id = _extractFiles(
        refreshed,
      ).where((file) => file.isDirectory && file.name == name).firstOrNull?.id;
    }
    id ??= _findID(created);
    if (id == null || id.isEmpty) throw Exception('无法获取目录 ID：$name');
    _folderIDs[cacheKey] = id;
    return id;
  }

  Future<void> _confirmRun() async {
    final selected = _entries
        .where((entry) => _selectedKeys.contains(_key(entry.item)))
        .toList(growable: false);
    if (selected.isEmpty || _running) return;
    final confirmed = await showShadDialog<bool>(
      context: context,
      builder: (dialogContext) => ShadDialog(
        title: const Text('确认整理文件'),
        description: Text('将移动 ${selected.length} 个媒体文件，原文件路径会发生变化。'),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          ShadButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('开始整理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(selected);
  }

  Future<void> _run(List<_MediaOrganizerEntry> selected) async {
    setState(() {
      _running = true;
      _stopRequested = false;
      _runTotal = selected.length;
      _completed = 0;
      _failed = 0;
      _failures.clear();
      _status = '正在整理 ${selected.length} 个文件';
    });
    _destinationFiles.clear();
    final api = ref.read(authProvider.notifier).api;
    final movedFiles = <CloudFile>[];
    final movedKeys = <String>{};
    for (final entry in selected) {
      if (_stopRequested) break;
      try {
        String? parentID = entry.rootID;
        for (final folder in entry.folders) {
          parentID = await _ensureFolder(parentID, folder);
        }
        final destinationKey = parentID ?? '@root';
        var filesByName = _destinationFiles[destinationKey];
        if (filesByName == null) {
          final response = await api.fsFiles(
            parentID: parentID,
            pageSize: 1000,
          );
          filesByName = {
            for (final file in _extractFiles(response))
              if (!file.isDirectory) file.name.toLowerCase(): file.id,
          };
          _destinationFiles[destinationKey] = filesByName;
        }
        final existingID = filesByName[entry.item.file.name.toLowerCase()];
        if (existingID != null && existingID != entry.item.id) {
          throw Exception('目标目录已有同名文件');
        }
        if (entry.item.file.parentID != parentID) {
          await api.fsMove([entry.item.id], parentID: parentID);
        }
        filesByName[entry.item.file.name.toLowerCase()] = entry.item.id;
        final targetPath = '${entry.targetPath}/${entry.item.file.name}';
        movedFiles.add(
          entry.item.file.copyWith(parentID: parentID, cloudPath: targetPath),
        );
        movedKeys.add(_key(entry.item));
        if (mounted) setState(() => _completed += 1);
      } catch (error) {
        if (mounted) {
          setState(() {
            _failed += 1;
            _failures[_key(entry.item)] = error.toString().replaceFirst(
              'Exception: ',
              '',
            );
          });
        }
      }
    }
    if (movedFiles.isNotEmpty) {
      await ref
          .read(mediaLibraryProvider.notifier)
          .synchronizeRenamedFiles(movedFiles);
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _entries = _entries
          .where((entry) => !movedKeys.contains(_key(entry.item)))
          .toList(growable: false);
      _selectedKeys
        ..clear()
        ..addAll(_failures.keys);
      _status = _stopRequested
          ? '已停止：$_completed 个成功，$_failed 个失败'
          : _failed == 0
          ? '整理完成，共移动 $_completed 个文件'
          : '整理完成：$_completed 个成功，$_failed 个失败';
      _stopRequested = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final selectedCount = _selectedKeys.length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 620;
        return Padding(
          padding: EdgeInsets.all(compact ? 12 : 18),
          child: Column(
            children: [
              _ToolSection(
                title: '媒体文件整理',
                description: _status.isEmpty
                    ? '选择一个文件，预览并整理它所在文件夹中的已识别视频。'
                    : _status,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_anchorFile != null) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _OrganizerMetric(
                            icon: Icons.folder_outlined,
                            label: _parentPath(_anchorFile!.cloudPath),
                          ),
                          if (_libraryName != null)
                            _OrganizerMetric(
                              icon: Icons.video_library_outlined,
                              label: _libraryName!,
                            ),
                          _OrganizerMetric(
                            icon: Icons.movie_outlined,
                            label: '$_folderVideoCount 个视频',
                          ),
                          if (_unmatchedCount > 0)
                            _OrganizerMetric(
                              icon: Icons.help_outline_rounded,
                              label: '$_unmatchedCount 个未识别',
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ShadButton.outline(
                          onPressed: _loading || _running ? null : _chooseFile,
                          leading: const Icon(
                            Icons.file_open_rounded,
                            size: 16,
                          ),
                          child: Text(_anchorFile == null ? '选择文件' : '更换文件'),
                        ),
                        if (_anchorFile != null)
                          ShadButton.outline(
                            onPressed: _loading || _running ? null : _prepare,
                            leading: const Icon(
                              Icons.refresh_rounded,
                              size: 16,
                            ),
                            child: const Text('刷新预览'),
                          ),
                        if (_running)
                          ShadButton.outline(
                            onPressed: _stopRequested
                                ? null
                                : () => setState(() => _stopRequested = true),
                            leading: const Icon(Icons.stop_rounded, size: 16),
                            child: const Text('完成当前项后停止'),
                          )
                        else
                          ShadButton(
                            onPressed: selectedCount == 0 ? null : _confirmRun,
                            leading: const Icon(
                              Icons.drive_file_move_rounded,
                              size: 16,
                            ),
                            child: Text('整理 $selectedCount 项'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    onPressed: _running
                        ? null
                        : () => setState(() {
                            _selectedKeys
                              ..clear()
                              ..addAll(
                                _entries.map((entry) => _key(entry.item)),
                              );
                          }),
                    child: const Text('全选'),
                  ),
                  ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    onPressed: _running
                        ? null
                        : () => setState(_selectedKeys.clear),
                    child: const Text('全不选'),
                  ),
                  const Spacer(),
                  if (_running)
                    Text(
                      '${_completed + _failed} / $_runTotal',
                      style: TextStyle(color: cs.mutedForeground, fontSize: 12),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: cs.border),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: _loading
                      ? const Center(
                          child: AppLoadingIndicator(
                            size: AppLoadingSize.page,
                            label: '正在生成整理预览',
                          ),
                        )
                      : _entries.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _anchorFile == null
                                    ? Icons.file_open_outlined
                                    : Icons.check_circle_outline_rounded,
                                size: 34,
                                color: cs.mutedForeground,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                _anchorFile == null
                                    ? '选择一个媒体文件开始预览'
                                    : '当前文件夹没有待整理的已识别资源',
                                style: TextStyle(color: cs.mutedForeground),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          itemCount: _entries.length,
                          separatorBuilder: (_, _) =>
                              Divider(height: 1, color: cs.border),
                          itemBuilder: (context, index) {
                            final entry = _entries[index];
                            final key = _key(entry.item);
                            final failure = _failures[key];
                            return CheckboxListTile(
                              value: _selectedKeys.contains(key),
                              enabled: !_running,
                              onChanged: (value) => setState(() {
                                if (value == true) {
                                  _selectedKeys.add(key);
                                } else {
                                  _selectedKeys.remove(key);
                                }
                              }),
                              title: Text(
                                entry.item.file.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    entry.targetPath,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (failure != null)
                                    Text(
                                      failure,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(color: cs.destructive),
                                    ),
                                ],
                              ),
                              secondary: Icon(
                                entry.item.mediaKind == TMDBMediaKind.movie
                                    ? Icons.movie_rounded
                                    : Icons.tv_rounded,
                                color: cs.primary,
                              ),
                              controlAffinity: ListTileControlAffinity.leading,
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _OrganizerMetric extends StatelessWidget {
  final IconData icon;
  final String label;

  const _OrganizerMetric({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: cs.mutedForeground),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: cs.mutedForeground),
            ),
          ),
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
