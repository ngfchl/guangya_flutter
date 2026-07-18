import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../models/cloud_file.dart';
import '../models/media_library.dart';
import '../providers/auth_provider.dart';
import '../providers/file_provider.dart';
import '../providers/media_library_provider.dart';
import '../widgets/file_list_tile.dart';
import '../widgets/media_player_dialog.dart';

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
                        onPressed: () => notifier.deleteFiles(selected),
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
                child: ListView.builder(
                  itemCount: files.length,
                  itemBuilder: (context, index) {
                    final file = files[index];
                    return FileListTile(
                      file: file,
                      isSelected: _selectedIDs.contains(file.id),
                      onSelect: () => setState(() {
                        _selectedIDs.contains(file.id)
                            ? _selectedIDs.remove(file.id)
                            : _selectedIDs.add(file.id);
                      }),
                      onOpen: () => notifier.downloadFile(file),
                      onCopy: () => notifier.copyToClipboard([file]),
                      onCut: () => notifier.cutToClipboard([file]),
                      onCopyFastTransfer: () =>
                          notifier.copyFastTransferJSON(file),
                      onDownload: () => notifier.downloadFile(file),
                      onDelete: () => notifier.deleteFiles([file]),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class MediaSearchResultsPage extends ConsumerWidget {
  final String query;
  final VoidCallback onClose;

  const MediaSearchResultsPage({
    super.key,
    required this.query,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = ShadTheme.of(context).colorScheme;
    return _SearchPageFrame(
      title: '影视资源搜索',
      query: query,
      onClose: onClose,
      child: FutureBuilder<List<MediaLibraryItem>>(
        future: ref.read(mediaLibraryProvider.notifier).searchAllItems(query),
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
          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 260,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 2.25,
            ),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              return ShadContextMenuRegion(
                items: [
                  ShadContextMenuItem.inset(
                    leading: const Icon(LucideIcons.play, size: 16),
                    onPressed: () => showMediaPlayerDialog(context, item.file),
                    child: const Text('播放'),
                  ),
                  ShadContextMenuItem.inset(
                    leading: const Icon(LucideIcons.monitorPlay, size: 16),
                    onPressed: () => showShadDialog<void>(
                      context: context,
                      builder: (_) => ExternalPlayerDialog(file: item.file),
                    ),
                    child: const Text('外部播放器'),
                  ),
                  ShadContextMenuItem.inset(
                    leading: const Icon(LucideIcons.download, size: 16),
                    onPressed: () =>
                        ref.read(fileProvider.notifier).downloadFile(item.file),
                    child: const Text('下载'),
                  ),
                  ShadContextMenuItem.inset(
                    leading: const Icon(LucideIcons.refreshCw, size: 16),
                    onPressed: () => ref
                        .read(mediaLibraryProvider.notifier)
                        .scanSelectedLibrary(),
                    child: const Text('重新扫描媒体库'),
                  ),
                ],
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => showShadDialog<void>(
                      context: context,
                      builder: (_) => ShadDialog(
                        title: Text(item.title),
                        description: const Text('影视资源信息'),
                        child: SelectableText(
                          'TMDB: ${item.tmdbID ?? '未匹配'}\n文件: ${item.file.name}\n路径: ${item.file.cloudPath}\n${item.overview}',
                        ),
                      ),
                    ),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.card,
                        border: Border.all(color: cs.border),
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
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
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
                                  item.year.isEmpty ? '年份未知' : item.year,
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
