import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../models/cloud_file.dart';
import '../models/media_library.dart';
import '../providers/auth_provider.dart';
import '../providers/file_provider.dart';
import '../providers/media_library_provider.dart';
import '../widgets/file_list_tile.dart';
import '../widgets/share_link_dialog.dart';
import '../widgets/media_player_dialog.dart';

class _SearchSelectAllIntent extends Intent {
  const _SearchSelectAllIntent();
}

const _searchSelectAllShortcuts = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.keyA, meta: true):
      _SearchSelectAllIntent(),
  SingleActivator(LogicalKeyboardKey.keyA, control: true):
      _SearchSelectAllIntent(),
};

class FileSearchResultsPage extends ConsumerStatefulWidget {
  final String query;
  final VoidCallback onClose;
  final ValueChanged<List<CloudFile>> onBatchRename;

  const FileSearchResultsPage({
    super.key,
    required this.query,
    required this.onClose,
    required this.onBatchRename,
  });

  @override
  ConsumerState<FileSearchResultsPage> createState() =>
      _FileSearchResultsPageState();
}

class _FileSearchResultsPageState extends ConsumerState<FileSearchResultsPage> {
  late Future<List<CloudFile>> _results = _search();
  final _selectedIDs = <String>{};
  String? _selectionAnchorID;
  final _resultsFocusNode = FocusNode(debugLabel: 'file-search-results');

  @override
  void dispose() {
    _resultsFocusNode.dispose();
    super.dispose();
  }

  bool get _commandPressed =>
      HardwareKeyboard.instance.logicalKeysPressed.contains(
        LogicalKeyboardKey.metaLeft,
      ) ||
      HardwareKeyboard.instance.logicalKeysPressed.contains(
        LogicalKeyboardKey.metaRight,
      ) ||
      HardwareKeyboard.instance.logicalKeysPressed.contains(
        LogicalKeyboardKey.controlLeft,
      ) ||
      HardwareKeyboard.instance.logicalKeysPressed.contains(
        LogicalKeyboardKey.controlRight,
      );

  bool get _shiftPressed =>
      HardwareKeyboard.instance.logicalKeysPressed.contains(
        LogicalKeyboardKey.shiftLeft,
      ) ||
      HardwareKeyboard.instance.logicalKeysPressed.contains(
        LogicalKeyboardKey.shiftRight,
      );

  void _selectFile(List<CloudFile> files, CloudFile file) {
    final index = files.indexWhere((item) => item.id == file.id);
    if (index < 0) return;
    final selected = Set<String>.from(_selectedIDs);
    if (_shiftPressed && _selectionAnchorID != null) {
      final anchor = files.indexWhere((item) => item.id == _selectionAnchorID);
      if (anchor >= 0) {
        if (!_commandPressed) selected.clear();
        selected.addAll(
          files
              .sublist(
                anchor < index ? anchor : index,
                anchor > index ? anchor + 1 : index + 1,
              )
              .map((item) => item.id),
        );
      }
    } else if (_commandPressed) {
      selected.contains(file.id)
          ? selected.remove(file.id)
          : selected.add(file.id);
      _selectionAnchorID = file.id;
    } else {
      selected
        ..clear()
        ..add(file.id);
      _selectionAnchorID = file.id;
    }
    setState(() {
      _selectedIDs
        ..clear()
        ..addAll(selected);
    });
  }

  void _selectAllFiles(List<CloudFile> files) {
    setState(() {
      _selectedIDs
        ..clear()
        ..addAll(files.map((file) => file.id));
    });
  }

  Future<void> _deleteFiles(List<CloudFile> files) async {
    if (files.isEmpty) return;
    final confirmed = await showShadDialog<bool>(
      context: context,
      builder: (dialogContext) => ShadDialog(
        title: Text('删除 ${files.length} 项？'),
        description: Text(
          files.length == 1 ? files.first.name : '将删除所选的 ${files.length} 个项目。',
        ),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          ShadButton.destructive(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
        child: const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('项目会被移入回收站。'),
        ),
      ),
    );
    if (confirmed != true) return;
    await ref.read(fileProvider.notifier).deleteFiles(files);
    if (!mounted) return;
    setState(() {
      _selectedIDs.removeAll(files.map((file) => file.id));
      _results = _search();
    });
  }

  @override
  void didUpdateWidget(covariant FileSearchResultsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) _results = _search();
  }

  Future<List<CloudFile>> _search() async {
    final api = ref.read(authProvider.notifier).api;
    final query = widget.query.trim();
    if (query.isEmpty) return const [];
    final results = <CloudFile>[];
    final ids = <String>{};
    var page = 0;
    while (page < 100) {
      final response = await api.searchFiles(query, page: page, pageSize: 100);
      final batch = _extractFiles(response);
      for (final file in batch) {
        if (ids.add(file.id)) {
          results.add(file);
        }
      }
      final total = _extractTotal(response);
      if (batch.isEmpty || results.length >= total || batch.length < 100) break;
      page += 1;
    }
    results.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return results;
  }

  int _extractTotal(Map<String, dynamic> json) {
    final data = json['data'];
    if (data is Map) return int.tryParse(data['total']?.toString() ?? '') ?? 0;
    return 0;
  }

  List<CloudFile> _extractFiles(Map<String, dynamic> json) {
    final values = <CloudFile>[];
    final ids = <String>{};
    void visit(dynamic value) {
      if (value is Map) {
        try {
          final file = CloudFile.fromJson(Map<String, dynamic>.from(value));
          if (ids.add(file.id)) values.add(file);
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
    return values;
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final notifier = ref.read(fileProvider.notifier);
    return _SearchPageFrame(
      title: '文件搜索',
      query: widget.query,
      onClose: widget.onClose,
      child: FutureBuilder<List<CloudFile>>(
        future: _results,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const _ShadSearchLoading();
          }
          if (snapshot.hasError) {
            return Center(
              child: Text(
                snapshot.error.toString(),
                style: TextStyle(color: cs.destructive),
              ),
            );
          }
          final files = snapshot.data ?? const <CloudFile>[];
          if (files.isEmpty) {
            return Center(
              child: Text(
                '没有匹配的文件',
                style: TextStyle(color: cs.mutedForeground),
              ),
            );
          }
          final selected = files
              .where((file) => _selectedIDs.contains(file.id))
              .toList();
          return Column(
            children: [
              if (selected.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: Row(
                    children: [
                      Text('已选择 ${selected.length} 项'),
                      const Spacer(),
                      ShadButton.ghost(
                        size: ShadButtonSize.sm,
                        onPressed: () => notifier.copyToClipboard(selected),
                        leading: const Icon(Icons.copy_rounded, size: 16),
                        child: const Text('复制'),
                      ),
                      ShadButton.ghost(
                        size: ShadButtonSize.sm,
                        onPressed: () => notifier.cutToClipboard(selected),
                        leading: const Icon(
                          Icons.content_cut_rounded,
                          size: 16,
                        ),
                        child: const Text('剪切'),
                      ),
                      ShadButton.ghost(
                        size: ShadButtonSize.sm,
                        onPressed: () => widget.onBatchRename(selected),
                        leading: const Icon(
                          Icons.drive_file_rename_outline_rounded,
                          size: 16,
                        ),
                        child: const Text('批量重命名'),
                      ),
                      ShadButton.ghost(
                        size: ShadButtonSize.sm,
                        onPressed: () => _deleteFiles(selected),
                        leading: const Icon(
                          Icons.delete_outline_rounded,
                          size: 16,
                        ),
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: FocusableActionDetector(
                  focusNode: _resultsFocusNode,
                  shortcuts: _searchSelectAllShortcuts,
                  actions: {
                    _SearchSelectAllIntent:
                        CallbackAction<_SearchSelectAllIntent>(
                          onInvoke: (_) {
                            _selectAllFiles(files);
                            return null;
                          },
                        ),
                  },
                  child: Listener(
                    onPointerDown: (_) => _resultsFocusNode.requestFocus(),
                    child: ListView.builder(
                      itemCount: files.length,
                      itemBuilder: (context, index) {
                        final file = files[index];
                        return FileListTile(
                          file: file,
                          isSelected: _selectedIDs.contains(file.id),
                          onSelect: () => _selectFile(files, file),
                          onOpen: () => notifier.downloadFile(file),
                          onRenameConfirm: (name) async {
                            final renamed = await notifier.renameFile(
                              file,
                              name,
                            );
                            if (renamed) {
                              await ref
                                  .read(mediaLibraryProvider.notifier)
                                  .synchronizeRenamedFiles([
                                    file.copyWith(name: name),
                                  ]);
                            }
                            if (mounted) setState(() => _results = _search());
                          },
                          onCopy: () => notifier.copyToClipboard([file]),
                          onCut: () => notifier.cutToClipboard([file]),
                          onCopyFastTransfer: () =>
                              notifier.copyFastTransferJSON(file),
                          onDownload: () => notifier.downloadFile(file),
                          onShare: () => unawaited(
                            showShareLinkDialog(
                              context,
                              createLink: () => notifier.createShare(file),
                            ),
                          ),
                          onDelete: () => _deleteFiles([file]),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class MediaSearchResultsPage extends ConsumerStatefulWidget {
  final String query;
  final VoidCallback onClose;

  const MediaSearchResultsPage({
    super.key,
    required this.query,
    required this.onClose,
  });

  @override
  ConsumerState<MediaSearchResultsPage> createState() =>
      _MediaSearchResultsPageState();
}

class _MediaSearchResultsPageState
    extends ConsumerState<MediaSearchResultsPage> {
  final _selectedIDs = <String>{};
  final _resultsFocusNode = FocusNode(debugLabel: 'media-search-results');
  bool _recognizing = false;

  @override
  void dispose() {
    _resultsFocusNode.dispose();
    super.dispose();
  }

  Future<void> _recognize(Iterable<MediaLibraryItem> items) async {
    setState(() => _recognizing = true);
    try {
      await ref.read(mediaLibraryProvider.notifier).recognizeItems(items);
    } finally {
      if (mounted) setState(() => _recognizing = false);
    }
  }

  void _selectAllItems(List<MediaLibraryItem> items) {
    setState(() {
      _selectedIDs
        ..clear()
        ..addAll(items.map((item) => item.id));
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return _SearchPageFrame(
      title: '影视资源搜索',
      query: widget.query,
      onClose: widget.onClose,
      child: FutureBuilder<List<MediaLibraryItem>>(
        future: ref
            .read(mediaLibraryProvider.notifier)
            .searchAllItems(widget.query),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const _ShadSearchLoading();
          }
          final items = snapshot.data ?? const <MediaLibraryItem>[];
          if (items.isEmpty) {
            return Center(
              child: Text(
                '没有匹配的影视资源',
                style: TextStyle(color: cs.mutedForeground),
              ),
            );
          }
          final selected = items
              .where((item) => _selectedIDs.contains(item.id))
              .toList();
          return Column(
            children: [
              if (selected.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Text('已选择 ${selected.length} 个资源'),
                      const Spacer(),
                      ShadButton(
                        size: ShadButtonSize.sm,
                        onPressed: _recognizing
                            ? null
                            : () => _recognize(selected),
                        leading: const Icon(
                          Icons.auto_fix_high_rounded,
                          size: 16,
                        ),
                        child: Text(_recognizing ? '正在识别' : '批量识别'),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: FocusableActionDetector(
                  focusNode: _resultsFocusNode,
                  shortcuts: _searchSelectAllShortcuts,
                  actions: {
                    _SearchSelectAllIntent:
                        CallbackAction<_SearchSelectAllIntent>(
                          onInvoke: (_) {
                            _selectAllItems(items);
                            return null;
                          },
                        ),
                  },
                  child: Listener(
                    onPointerDown: (_) => _resultsFocusNode.requestFocus(),
                    child: GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 260,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 2.25,
                          ),
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final isSelected = _selectedIDs.contains(item.id);
                        return ShadContextMenuRegion(
                          items: [
                            ShadContextMenuItem.inset(
                              leading: const Icon(
                                LucideIcons.wandSparkles,
                                size: 16,
                              ),
                              onPressed: _recognizing
                                  ? null
                                  : () => _recognize([item]),
                              child: const Text('手动识别'),
                            ),
                            ShadContextMenuItem.inset(
                              leading: const Icon(LucideIcons.play, size: 16),
                              onPressed: () =>
                                  showMediaPlayerDialog(context, item.file),
                              child: const Text('播放'),
                            ),
                            ShadContextMenuItem.inset(
                              leading: const Icon(
                                LucideIcons.monitorPlay,
                                size: 16,
                              ),
                              onPressed: () => showShadDialog<void>(
                                context: context,
                                builder: (_) =>
                                    ExternalPlayerDialog(file: item.file),
                              ),
                              child: const Text('外部播放器'),
                            ),
                            ShadContextMenuItem.inset(
                              leading: const Icon(
                                LucideIcons.download,
                                size: 16,
                              ),
                              onPressed: () => ref
                                  .read(fileProvider.notifier)
                                  .downloadFile(item.file),
                              child: const Text('下载'),
                            ),
                            ShadContextMenuItem.inset(
                              leading: const Icon(
                                LucideIcons.refreshCw,
                                size: 16,
                              ),
                              onPressed: () => ref
                                  .read(mediaLibraryProvider.notifier)
                                  .scanSelectedLibrary(),
                              child: const Text('重新扫描媒体库'),
                            ),
                          ],
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () => setState(() {
                                isSelected
                                    ? _selectedIDs.remove(item.id)
                                    : _selectedIDs.add(item.id);
                              }),
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: cs.card,
                                  border: Border.all(
                                    color: isSelected ? cs.primary : cs.border,
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 46,
                                      height: 64,
                                      decoration: BoxDecoration(
                                        color: cs.muted,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Icon(
                                        Icons.movie_rounded,
                                        color: cs.mutedForeground,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item.title,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: cs.foreground,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            item.year.isEmpty
                                                ? '年份未知'
                                                : item.year,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: cs.mutedForeground,
                                            ),
                                          ),
                                          Text(
                                            item.file.cloudPath,
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
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SearchPageFrame extends StatelessWidget {
  final String title;
  final String query;
  final VoidCallback onClose;
  final Widget child;

  const _SearchPageFrame({
    required this.title,
    required this.query,
    required this.onClose,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Column(
      children: [
        Container(
          height: 54,
          padding: const EdgeInsets.symmetric(horizontal: 12),
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
              const SizedBox(width: 10),
              Text(
                title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: cs.foreground,
                ),
              ),
              const SizedBox(width: 8),
              ShadBadge(child: Text(query)),
            ],
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _ShadSearchLoading extends StatelessWidget {
  const _ShadSearchLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(child: SizedBox(width: 220, child: ShadProgress()));
  }
}
