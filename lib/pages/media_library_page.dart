import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../core/storage/storage_manager.dart';
import '../models/cloud_file.dart';
import '../models/media_library.dart';
import '../providers/auth_provider.dart';
import '../providers/file_provider.dart';
import '../providers/media_library_provider.dart';
import '../widgets/media_player_dialog.dart';

enum _MediaWallFilter { all, movies, series, collections, unmatched }

String _tmdbImageURL(String path, {required String size}) {
  final source = _tmdbDirectImageURL(path, size: size);
  final configured = StorageManager.get<String>(
    StorageKeys.tmdbImageProxy,
  )?.trim();
  if (configured != null && configured.isEmpty) return source;
  final proxy = Uri.tryParse(configured ?? 'https://wsrv.nl');
  if (proxy == null || !proxy.hasScheme || proxy.host.isEmpty) return source;
  return proxy
      .replace(
        path: proxy.path.isEmpty ? '/' : proxy.path,
        queryParameters: {'url': source, 'output': 'webp', 'q': '85'},
      )
      .toString();
}

String _tmdbDirectImageURL(String path, {required String size}) {
  return path.startsWith('http')
      ? path
      : 'https://image.tmdb.org/t/p/$size$path';
}

Widget _tmdbDirectFallback({
  required String path,
  required String size,
  required Widget fallback,
  BoxFit fit = BoxFit.cover,
  double? width,
  double? height,
}) {
  return CachedNetworkImage(
    imageUrl: _tmdbDirectImageURL(path, size: size),
    fit: fit,
    width: width,
    height: height,
    errorWidget: (_, _, _) => fallback,
  );
}

class MediaLibraryPage extends ConsumerStatefulWidget {
  final bool showLibrarySidebar;
  final String? searchTitle;

  const MediaLibraryPage({
    super.key,
    this.showLibrarySidebar = true,
    this.searchTitle,
  });

  static void showCreateDialog(BuildContext context, WidgetRef ref) {
    _MediaLibraryPageState._showCreateLibraryDialog(context, ref);
  }

  @override
  ConsumerState<MediaLibraryPage> createState() => _MediaLibraryPageState();
}

class _MediaLibraryPageState extends ConsumerState<MediaLibraryPage> {
  final String _tmdbApiKey =
      StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
  bool _tmdbSearching = false;
  String? _tmdbError;
  List<Map<String, dynamic>> _tmdbResults = [];
  bool _backupBusy = false;
  _MediaWork? _detailWork;
  _MediaWallFilter _wallFilter = _MediaWallFilter.all;
  String? _activeCollectionKey;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(mediaLibraryProvider.notifier).api = ref
          .read(authProvider.notifier)
          .api;
      ref.read(mediaLibraryProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(mediaLibraryProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
      child: Column(
        children: [
          _buildHeader(context, state),
          const SizedBox(height: 12),
          _buildToolbar(context, state),
          const SizedBox(height: 12),
          if (state.errorMessage != null || state.statusMessage != null)
            _buildMessageBar(context, state),
          Expanded(
            child: widget.showLibrarySidebar
                ? Row(
                    children: [
                      _buildLibraryList(context, state),
                      VerticalDivider(
                        width: 24,
                        color: ShadTheme.of(context).colorScheme.border,
                      ),
                      Expanded(child: _buildMainPanel(context, state)),
                    ],
                  )
                : _buildMainPanel(context, state),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, MediaLibraryState state) {
    final cs = ShadTheme.of(context).colorScheme;
    final stats = state.statistics;
    return Row(
      children: [
        Icon(Icons.movie_filter_rounded, size: 26, color: cs.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.searchTitle ?? '光鸭影视',
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  color: cs.foreground,
                ),
              ),
              Text(
                state.selectedLibrary?.name ?? '创建媒体库后扫描云盘影视文件',
                style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        _statPill(
          context,
          '全部',
          stats.total.toString(),
          selected: _wallFilter == _MediaWallFilter.all,
          onTap: () => _selectWallFilter(_MediaWallFilter.all),
        ),
        _statPill(
          context,
          '电影',
          stats.movies.toString(),
          selected: _wallFilter == _MediaWallFilter.movies,
          onTap: () => _selectWallFilter(_MediaWallFilter.movies),
        ),
        _statPill(
          context,
          '剧集',
          stats.series.toString(),
          selected: _wallFilter == _MediaWallFilter.series,
          onTap: () => _selectWallFilter(_MediaWallFilter.series),
        ),
        _statPill(
          context,
          '合集',
          stats.collections.toString(),
          selected: _wallFilter == _MediaWallFilter.collections,
          onTap: () => _selectWallFilter(_MediaWallFilter.collections),
        ),
        _statPill(
          context,
          '待匹配',
          stats.unmatched.toString(),
          selected: _wallFilter == _MediaWallFilter.unmatched,
          onTap: () => _selectWallFilter(_MediaWallFilter.unmatched),
        ),
      ],
    );
  }

  void _selectWallFilter(_MediaWallFilter filter) {
    setState(() {
      _wallFilter = filter;
      _activeCollectionKey = null;
      _detailWork = null;
    });
  }

  Widget _statPill(
    BuildContext context,
    String label,
    String value, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    final cs = ShadTheme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: selected ? cs.primary.withValues(alpha: 0.12) : cs.muted,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: selected ? cs.primary : cs.border),
            ),
            child: Text(
              '$label $value',
              style: TextStyle(
                fontSize: 12,
                color: selected ? cs.primary : cs.mutedForeground,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar(BuildContext context, MediaLibraryState state) {
    final cs = ShadTheme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: ShadInput(
            controller: _searchController,
            placeholder: const Text('搜索影视库或匹配 TMDB…'),
            leading: Icon(
              Icons.search_rounded,
              size: 16,
              color: cs.mutedForeground,
            ),
            onChanged: (value) =>
                ref.read(mediaLibraryProvider.notifier).setSearchQuery(value),
            onSubmitted: _searchTMDB,
          ),
        ),
        const SizedBox(width: 8),
        ShadButton.outline(
          onPressed: () => _showCreateLibraryDialog(context, ref),
          leading: const Icon(Icons.add_rounded, size: 16),
          child: const Text('媒体库'),
        ),
        const SizedBox(width: 8),
        ShadButton.outline(
          onPressed: _backupBusy || state.isScanning
              ? null
              : _exportScrapedData,
          leading: const Icon(Icons.save_alt_rounded, size: 16),
          child: const Text('导出数据'),
        ),
        const SizedBox(width: 8),
        ShadButton.outline(
          onPressed: _backupBusy || state.isScanning
              ? null
              : _importScrapedData,
          leading: const Icon(Icons.upload_file_rounded, size: 16),
          child: const Text('导入数据'),
        ),
        const SizedBox(width: 8),
        ShadButton.outline(
          onPressed: state.selectedLibrary == null || state.isScanning
              ? null
              : () => ref
                    .read(mediaLibraryProvider.notifier)
                    .scanSelectedLibrary(),
          leading: const Icon(Icons.refresh_rounded, size: 16),
          child: const Text('扫描'),
        ),
        if (state.isScanning) ...[
          const SizedBox(width: 8),
          ShadButton.destructive(
            onPressed: () =>
                ref.read(mediaLibraryProvider.notifier).cancelScan(),
            leading: const Icon(Icons.stop_rounded, size: 16),
            child: const Text('停止'),
          ),
        ],
        const SizedBox(width: 8),
        ShadButton(
          onPressed: _tmdbApiKey.isEmpty
              ? null
              : () => _searchTMDB(_searchController.text),
          leading: const Icon(Icons.travel_explore_rounded, size: 16),
          child: const Text('匹配'),
        ),
      ],
    );
  }

  Widget _buildMessageBar(BuildContext context, MediaLibraryState state) {
    final cs = ShadTheme.of(context).colorScheme;
    final isError = state.errorMessage != null;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isError ? cs.destructive.withValues(alpha: 0.08) : cs.muted,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isError ? cs.destructive : cs.border),
      ),
      child: Text(
        state.errorMessage ?? state.statusMessage ?? '',
        style: TextStyle(
          fontSize: 12,
          color: isError ? cs.destructive : cs.mutedForeground,
        ),
      ),
    );
  }

  Widget _buildLibraryList(BuildContext context, MediaLibraryState state) {
    final cs = ShadTheme.of(context).colorScheme;
    return SizedBox(
      width: 260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '媒体库',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: cs.mutedForeground,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: state.libraries.isEmpty
                ? _emptyLibraryHint(context)
                : ListView.builder(
                    itemCount: state.libraries.length,
                    itemBuilder: (context, index) {
                      final library = state.libraries[index];
                      final selected = library.id == state.selectedLibrary?.id;
                      return _LibraryRow(
                        library: library,
                        selected: selected,
                        onTap: () => ref
                            .read(mediaLibraryProvider.notifier)
                            .selectLibrary(library.id),
                        onEdit: () =>
                            _showEditLibraryDialog(context, ref, library),
                        onDelete: () => ref
                            .read(mediaLibraryProvider.notifier)
                            .deleteLibrary(library.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _emptyLibraryHint(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.video_library_outlined,
            size: 42,
            color: cs.mutedForeground,
          ),
          const SizedBox(height: 12),
          Text(
            '暂无媒体库',
            style: TextStyle(fontSize: 14, color: cs.mutedForeground),
          ),
          const SizedBox(height: 10),
          ShadButton.outline(
            onPressed: () => _showCreateLibraryDialog(context, ref),
            child: const Text('创建媒体库'),
          ),
        ],
      ),
    );
  }

  Widget _buildMainPanel(BuildContext context, MediaLibraryState state) {
    if (state.isLoading) {
      return const Center(child: ShadProgress());
    }
    if (_tmdbSearching || _tmdbResults.isNotEmpty || _tmdbError != null) {
      return _tmdbResultPanel(context);
    }
    final visibleItems = state.visibleItems;
    final collections = _MediaCollection.fromItems(visibleItems);
    final activeCollection = collections
        .where((collection) => collection.key == _activeCollectionKey)
        .firstOrNull;
    final filteredItems = switch (_wallFilter) {
      _MediaWallFilter.all => visibleItems,
      _MediaWallFilter.movies =>
        visibleItems
            .where((item) => item.mediaKind == TMDBMediaKind.movie)
            .toList(),
      _MediaWallFilter.series =>
        visibleItems
            .where((item) => item.mediaKind == TMDBMediaKind.tv)
            .toList(),
      _MediaWallFilter.collections => activeCollection?.resources ?? const [],
      _MediaWallFilter.unmatched =>
        visibleItems.where((item) => !item.isMatched).toList(),
    };
    final works = _MediaWork.fromItems(filteredItems);
    if (state.selectedLibrary == null) {
      return _mainEmpty(context, '还没有媒体库', '从云盘根目录或当前目录创建一个媒体库');
    }
    if (_detailWork != null) {
      final current = works
          .where((work) => work.key == _detailWork!.key)
          .firstOrNull;
      return _MediaDetailPanel(
        work: current ?? _detailWork!,
        onBack: () => setState(() => _detailWork = null),
        onDownload: (item) =>
            ref.read(fileProvider.notifier).downloadFile(item.file),
        onPlay: (item) => unawaited(
          showMediaPlayerDialog(
            context,
            item.file,
            episodeCandidates: (current ?? _detailWork!).resources
                .map((resource) => resource.file)
                .toList(),
          ),
        ),
        onExternalPlay: (item) => showShadDialog(
          context: context,
          builder: (_) => ExternalPlayerDialog(file: item.file),
        ),
        onManualMatch: () => _showManualTMDBMatch(current ?? _detailWork!),
        onRefreshAndRecognize: () => ref
            .read(mediaLibraryProvider.notifier)
            .refreshAndRecognizeItems((current ?? _detailWork!).resources),
      );
    }
    final showingCollectionOverview =
        _wallFilter == _MediaWallFilter.collections && activeCollection == null;
    final wallContent = showingCollectionOverview
        ? _collectionOverview(context, collections)
        : works.isEmpty
        ? _mainEmpty(
            context,
            state.isScanning
                ? '正在扫描媒体库'
                : (_wallFilter == _MediaWallFilter.all ? '没有扫描结果' : '当前筛选没有结果'),
            state.isScanning ? '发现并入库的资源会立即显示在这里' : '点击扫描读取该媒体库下的视频文件',
          )
        : LayoutBuilder(
            builder: (context, constraints) {
              final columns = (constraints.maxWidth / 154).floor().clamp(2, 7);
              return GridView.builder(
                padding: const EdgeInsets.only(bottom: 10),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: 18,
                  crossAxisSpacing: 14,
                  childAspectRatio: 0.52,
                ),
                itemCount: works.length,
                itemBuilder: (context, index) => _MediaPosterTile(
                  work: works[index],
                  onOpen: () => setState(() => _detailWork = works[index]),
                  onDownload: () => ref
                      .read(fileProvider.notifier)
                      .downloadFile(works[index].primary.file),
                  onRescan: state.isScanning
                      ? null
                      : () => ref
                            .read(mediaLibraryProvider.notifier)
                            .scanSelectedLibrary(),
                ),
              );
            },
          );
    final content = activeCollection == null
        ? wallContent
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed: () => setState(() => _activeCollectionKey = null),
                leading: const Icon(Icons.arrow_back_rounded, size: 16),
                child: Text('返回合集：${activeCollection.name}'),
              ),
              const SizedBox(height: 8),
              Expanded(child: wallContent),
            ],
          );
    if (!state.isScanning) {
      if (state.scanLogs.isEmpty) return content;
      return Column(
        children: [
          _recentScanLogs(context, state),
          const SizedBox(height: 10),
          Expanded(child: content),
        ],
      );
    }
    return Column(
      children: [
        _scanProgress(context, state),
        const SizedBox(height: 10),
        Expanded(child: content),
      ],
    );
  }

  Widget _collectionOverview(
    BuildContext context,
    List<_MediaCollection> collections,
  ) {
    if (collections.isEmpty) {
      return _mainEmpty(context, '没有自动合集', '已匹配合集信息的电影会显示在这里');
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 154).floor().clamp(2, 7);
        return GridView.builder(
          padding: const EdgeInsets.only(bottom: 10),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 18,
            crossAxisSpacing: 14,
            childAspectRatio: 0.52,
          ),
          itemCount: collections.length,
          itemBuilder: (context, index) => _MediaCollectionTile(
            collection: collections[index],
            onOpen: () => setState(() {
              _activeCollectionKey = collections[index].key;
              _detailWork = null;
            }),
          ),
        );
      },
    );
  }

  Widget _scanProgress(BuildContext context, MediaLibraryState state) {
    final cs = ShadTheme.of(context).colorScheme;
    return Semantics(
      label: '媒体扫描进度：${state.progress.phase}，已处理 ${state.progress.completed} 项',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: cs.muted,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(width: 120, child: ShadProgress()),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        state.progress.phase,
                        style: TextStyle(color: cs.foreground),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '已发现 ${state.progress.completed} 个视频文件，已入库资源会实时显示。',
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (state.scanLogs.isNotEmpty) ...[
              const SizedBox(height: 10),
              Divider(height: 1, color: cs.border),
              const SizedBox(height: 8),
              Text(
                '任务日志',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: cs.mutedForeground,
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 84,
                child: ListView.builder(
                  reverse: true,
                  itemCount: state.scanLogs.length,
                  itemBuilder: (context, index) {
                    final log = state.scanLogs.reversed.elementAt(index);
                    final time = TimeOfDay.fromDateTime(
                      log.createdAt,
                    ).format(context);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        '$time  ${log.message}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: log.isError
                              ? cs.destructive
                              : cs.mutedForeground,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _recentScanLogs(BuildContext context, MediaLibraryState state) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: cs.muted.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '最近扫描日志',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: cs.mutedForeground,
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 54,
            child: ListView.builder(
              reverse: true,
              itemCount: state.scanLogs.length,
              itemBuilder: (context, index) {
                final log = state.scanLogs.reversed.elementAt(index);
                final time = TimeOfDay.fromDateTime(
                  log.createdAt,
                ).format(context);
                return Text(
                  '$time  ${log.message}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: log.isError ? cs.destructive : cs.mutedForeground,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _mainEmpty(BuildContext context, String title, String subtitle) {
    final cs = ShadTheme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.movie_creation_outlined,
            size: 56,
            color: cs.mutedForeground,
          ),
          const SizedBox(height: 14),
          Text(title, style: TextStyle(fontSize: 16, color: cs.foreground)),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(fontSize: 12, color: cs.mutedForeground),
          ),
        ],
      ),
    );
  }

  Widget _tmdbResultPanel(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    if (_tmdbSearching) return const Center(child: ShadProgress());
    if (_tmdbError != null) {
      return _mainEmpty(context, 'TMDB 请求失败', _tmdbError!);
    }
    if (_tmdbResults.isEmpty) {
      return _mainEmpty(context, '没有 TMDB 结果', '换一个片名继续搜索');
    }
    return ListView.separated(
      itemCount: _tmdbResults.length,
      separatorBuilder: (context, index) =>
          Divider(color: cs.border, height: 1),
      itemBuilder: (context, index) =>
          _buildTMDBResultItem(context, _tmdbResults[index]),
    );
  }

  Widget _buildTMDBResultItem(BuildContext context, Map<String, dynamic> item) {
    final cs = ShadTheme.of(context).colorScheme;
    final title = item['title'] ?? item['name'] ?? '未知';
    final overview = item['overview']?.toString() ?? '';
    final releaseDate =
        item['release_date']?.toString() ??
        item['first_air_date']?.toString() ??
        '';
    final mediaType = item['media_type']?.toString() ?? 'movie';
    final posterPath = item['poster_path'] as String?;
    final year = releaseDate.length >= 4 ? releaseDate.substring(0, 4) : '';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: posterPath == null
                ? _posterPlaceholder(context, 74, 110)
                : CachedNetworkImage(
                    imageUrl: _tmdbImageURL(posterPath, size: 'w200'),
                    width: 74,
                    height: 110,
                    fit: BoxFit.cover,
                    errorWidget: (context, url, error) => _tmdbDirectFallback(
                      path: posterPath,
                      size: 'w200',
                      width: 74,
                      height: 110,
                      fallback: _posterPlaceholder(context, 74, 110),
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        year.isEmpty ? title.toString() : '$title ($year)',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: cs.foreground,
                        ),
                      ),
                    ),
                    ShadBadge(child: Text(mediaType == 'tv' ? '剧集' : '电影')),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  overview.isEmpty ? '暂无简介' : overview,
                  style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _posterPlaceholder(BuildContext context, double width, double height) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      width: width,
      height: height,
      color: cs.muted,
      child: Icon(Icons.movie_rounded, color: cs.mutedForeground),
    );
  }

  static void _showCreateLibraryDialog(BuildContext context, WidgetRef ref) {
    final fileState = ref.read(fileProvider);
    final currentPath = fileState.folderPath.isEmpty
        ? '云盘根目录'
        : fileState.folderPath.map((file) => file.name).join(' / ');
    showShadDialog(
      context: context,
      builder: (ctx) => _CreateMediaLibraryDialog(
        initialRootID: fileState.folderPath.isEmpty
            ? null
            : fileState.folderPath.last.id,
        initialPath: currentPath,
        initialName: fileState.folderPath.isEmpty
            ? '我的影视库'
            : fileState.folderPath.last.name,
      ),
    );
  }

  static void _showEditLibraryDialog(
    BuildContext context,
    WidgetRef ref,
    MediaLibraryDefinition library,
  ) {
    showShadDialog(
      context: context,
      builder: (_) => _CreateMediaLibraryDialog(
        initialRootID: library.rootID,
        initialPath: library.rootPath,
        initialName: library.name,
        editingLibrary: library,
      ),
    );
  }

  Future<void> _exportScrapedData() async {
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: '选择刮削数据导出目录',
    );
    if (directory == null || !mounted) return;
    setState(() => _backupBusy = true);
    try {
      await ref
          .read(mediaLibraryProvider.notifier)
          .exportScrapedData('$directory/media-library.sqlite3');
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _importScrapedData() async {
    final backup = await FilePicker.pickFile(
      dialogTitle: '导入影视缓存与刮削数据',
      type: FileType.custom,
      allowedExtensions: const ['sqlite3', 'sqlite', 'db'],
    );
    final path = backup?.path;
    if (path == null || !mounted) return;
    setState(() => _backupBusy = true);
    try {
      await ref.read(mediaLibraryProvider.notifier).importScrapedData(path);
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _searchTMDB(String query) async {
    final text = query.trim();
    if (text.isEmpty || _tmdbApiKey.isEmpty) return;

    setState(() {
      _tmdbSearching = true;
      _tmdbError = null;
      _tmdbResults = [];
    });

    try {
      final api = ref.read(authProvider.notifier).api;
      final result = await api.tmdbSearch(
        text,
        apiKey: _tmdbApiKey,
        proxyHost: StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '',
        proxyPort: StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '',
      );
      final results =
          (result['results'] as List?)
              ?.whereType<Map>()
              .where(
                (item) =>
                    item['media_type'] == 'movie' || item['media_type'] == 'tv',
              )
              .map((item) => Map<String, dynamic>.from(item))
              .toList() ??
          [];
      setState(() {
        _tmdbResults = results;
        _tmdbSearching = false;
      });
    } catch (e) {
      setState(() {
        _tmdbError = e.toString();
        _tmdbSearching = false;
      });
    }
  }

  Future<void> _showManualTMDBMatch(_MediaWork work) async {
    final candidate = await showShadDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ManualTMDBMatchDialog(initialQuery: work.primary.title),
    );
    if (candidate == null || !mounted) return;
    final notifier = ref.read(mediaLibraryProvider.notifier);
    final updated = <MediaLibraryItem>[];
    for (final resource in work.resources) {
      updated.add(await notifier.applyTMDBMatch(resource, candidate));
    }
    if (mounted) {
      setState(() {
        _detailWork = _MediaWork.fromItems(updated).first;
      });
    }
  }
}

class _CreateMediaLibraryDialog extends ConsumerStatefulWidget {
  final String? initialRootID;
  final String initialPath;
  final String initialName;
  final MediaLibraryDefinition? editingLibrary;

  const _CreateMediaLibraryDialog({
    required this.initialRootID,
    required this.initialPath,
    required this.initialName,
    this.editingLibrary,
  });

  @override
  ConsumerState<_CreateMediaLibraryDialog> createState() =>
      _CreateMediaLibraryDialogState();
}

class _CreateMediaLibraryDialogState
    extends ConsumerState<_CreateMediaLibraryDialog> {
  late final TextEditingController _nameController;
  final _minSizeController = TextEditingController(text: '50');
  MediaLibraryKind _kind = MediaLibraryKind.mixed;
  bool _recursive = true;
  bool _isBrowsing = false;
  bool _isLoadingFolders = false;
  String? _folderError;
  late List<MediaLibrarySource> _sources;
  final _browserPath = <CloudFile>[];
  var _folders = <CloudFile>[];

  bool get _isEditing => widget.editingLibrary != null;

  @override
  void initState() {
    super.initState();
    _sources =
        widget.editingLibrary?.sources ??
        [
          MediaLibrarySource(
            id: 'initial-source',
            rootID: widget.initialRootID,
            path: widget.initialPath,
          ),
        ];
    _nameController = TextEditingController(text: widget.initialName);
    if (_isEditing) {
      _kind = widget.editingLibrary!.kind;
      _recursive = widget.editingLibrary!.recursive;
      _minSizeController.text = widget.editingLibrary!.minimumSizeMB.toString();
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _minSizeController.dispose();
    super.dispose();
  }

  String get _browserLocation => _browserPath.isEmpty
      ? '云盘根目录'
      : _browserPath.map((folder) => folder.name).join(' / ');

  String? get _browserFolderID =>
      _browserPath.isEmpty ? null : _browserPath.last.id;

  Future<void> _startBrowsing() async {
    setState(() {
      _isBrowsing = true;
      _browserPath.clear();
      _folders = [];
    });
    await _loadFolders();
  }

  Future<void> _loadFolders() async {
    setState(() {
      _isLoadingFolders = true;
      _folderError = null;
    });
    try {
      final response = await ref
          .read(authProvider.notifier)
          .api
          .fsFiles(parentID: _browserFolderID, pageSize: 1000);
      if (mounted) {
        setState(() {
          _folders =
              _extractFiles(response).where((file) => file.isDirectory).toList()
                ..sort(
                  (a, b) =>
                      a.name.toLowerCase().compareTo(b.name.toLowerCase()),
                );
        });
      }
    } catch (error) {
      if (mounted) setState(() => _folderError = error.toString());
    } finally {
      if (mounted) setState(() => _isLoadingFolders = false);
    }
  }

  List<CloudFile> _extractFiles(Map<String, dynamic> value) {
    final files = <CloudFile>[];
    final ids = <String>{};
    void visit(dynamic node) {
      if (node is Map) {
        try {
          final file = CloudFile.fromJson(Map<String, dynamic>.from(node));
          if (ids.add(file.id)) files.add(file);
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
    return files;
  }

  void _useBrowserFolder() {
    final rootID = _browserFolderID;
    final rootPath = _browserLocation;
    setState(() {
      if (rootID == null) {
        _sources = [
          MediaLibrarySource(id: 'root-source', rootID: null, path: rootPath),
        ];
      } else if (!_sources.any((source) => source.rootID == rootID)) {
        _sources = [
          ..._sources.where((source) => source.rootID != null),
          MediaLibrarySource(
            id: 'source-${DateTime.now().microsecondsSinceEpoch}',
            rootID: rootID,
            path: rootPath,
          ),
        ];
      }
      if (_nameController.text.trim().isEmpty ||
          _nameController.text == widget.initialName) {
        _nameController.text = _browserPath.isEmpty
            ? '我的影视库'
            : _browserPath.last.name;
      }
      _isBrowsing = false;
    });
  }

  Future<void> _save(BuildContext context) async {
    final notifier = ref.read(mediaLibraryProvider.notifier);
    if (_isEditing) {
      await notifier.updateLibrary(
        widget.editingLibrary!.copyWith(
          name: _nameController.text,
          sources: _sources,
          kind: _kind,
          recursive: _recursive,
          minimumSizeMB: int.tryParse(_minSizeController.text.trim()) ?? 50,
          updatedAt: DateTime.now(),
        ),
      );
    } else {
      await notifier.createLibrary(
        name: _nameController.text,
        rootID: _sources.isEmpty ? null : _sources.first.rootID,
        rootPath: _sources.isEmpty ? '未配置目录' : _sources.first.path,
        sources: _sources,
        kind: _kind,
        recursive: _recursive,
        minimumSizeMB: int.tryParse(_minSizeController.text.trim()) ?? 50,
      );
    }
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ShadDialog(
      title: Text(_isBrowsing ? '选择云盘文件夹' : (_isEditing ? '管理媒体库' : '创建媒体库')),
      description: Text(
        _isBrowsing ? '进入目标目录后，选择该目录作为媒体库来源。' : '媒体库会从指定目录扫描视频文件。',
      ),
      actions: _isBrowsing
          ? [
              ShadButton.outline(
                onPressed: () => setState(() => _isBrowsing = false),
                child: const Text('返回设置'),
              ),
              ShadButton(
                onPressed: _useBrowserFolder,
                leading: const Icon(Icons.check_rounded, size: 16),
                child: const Text('使用此目录'),
              ),
            ]
          : [
              ShadButton.outline(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              ShadButton(
                onPressed: _sources.isEmpty ? null : () => _save(context),
                leading: const Icon(Icons.add_rounded, size: 16),
                child: Text(_isEditing ? '保存并扫描' : '创建媒体库'),
              ),
            ],
      child: _isBrowsing ? _folderBrowser(cs) : _form(cs),
    );
  }

  Widget _form(ShadColorScheme cs) {
    return SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.muted,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: cs.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.folder_rounded, color: cs.primary, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      '媒体来源 (${_sources.length})',
                      style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                    ),
                    const Spacer(),
                    ShadButton.outline(
                      size: ShadButtonSize.sm,
                      onPressed: _startBrowsing,
                      leading: const Icon(Icons.add_rounded, size: 15),
                      child: const Text('添加目录'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_sources.isEmpty)
                  Text(
                    '请至少添加一个云盘目录',
                    style: TextStyle(fontSize: 12, color: cs.destructive),
                  )
                else
                  for (final source in _sources)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Row(
                        children: [
                          Icon(
                            Icons.folder_outlined,
                            size: 16,
                            color: cs.mutedForeground,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              source.path,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: cs.foreground,
                              ),
                            ),
                          ),
                          ShadButton.ghost(
                            size: ShadButtonSize.sm,
                            onPressed: () => setState(
                              () => _sources.removeWhere(
                                (candidate) => candidate.id == source.id,
                              ),
                            ),
                            child: Icon(
                              Icons.remove_circle_outline_rounded,
                              size: 16,
                              color: cs.destructive,
                            ),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          ShadInput(
            controller: _nameController,
            placeholder: const Text('媒体库名称'),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ShadSelect<MediaLibraryKind>(
                  initialValue: _kind,
                  placeholder: const Text('媒体类型'),
                  selectedOptionBuilder: (context, value) => Text(value.title),
                  options: [
                    for (final value in MediaLibraryKind.values)
                      ShadOption(value: value, child: Text(value.title)),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _kind = value);
                  },
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 132,
                child: ShadInput(
                  controller: _minSizeController,
                  keyboardType: TextInputType.number,
                  placeholder: const Text('最小 MB'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: ShadCheckbox(
              value: _recursive,
              label: const Text('递归扫描所有子目录'),
              sublabel: const Text('关闭后仅扫描当前目录中的视频文件'),
              onChanged: (value) => setState(() => _recursive = value),
            ),
          ),
        ],
      ),
    );
  }

  Widget _folderBrowser(ShadColorScheme cs) {
    return SizedBox(
      width: 560,
      height: 390,
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: cs.muted,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              children: [
                ShadTooltip(
                  builder: (_) => const Text('返回上级目录'),
                  child: ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    onPressed: _browserPath.isEmpty
                        ? null
                        : () {
                            setState(() => _browserPath.removeLast());
                            _loadFolders();
                          },
                    child: const Icon(Icons.arrow_back_rounded, size: 16),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.folder_rounded, size: 16, color: cs.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _browserLocation,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: cs.foreground),
                  ),
                ),
                ShadTooltip(
                  builder: (_) => const Text('刷新目录'),
                  child: ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    onPressed: _isLoadingFolders ? null : _loadFolders,
                    child: const Icon(Icons.refresh_rounded, size: 16),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _isLoadingFolders
                ? const Center(
                    child: SizedBox(width: 220, child: ShadProgress()),
                  )
                : _folderError != null
                ? Center(
                    child: Text(
                      _folderError!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.destructive),
                    ),
                  )
                : _folders.isEmpty
                ? Center(
                    child: Text(
                      '此目录没有子文件夹',
                      style: TextStyle(color: cs.mutedForeground),
                    ),
                  )
                : ListView.separated(
                    itemCount: _folders.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: cs.border),
                    itemBuilder: (context, index) {
                      final folder = _folders[index];
                      return MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            setState(() => _browserPath.add(folder));
                            _loadFolders();
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 11,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.folder_rounded,
                                  size: 19,
                                  color: cs.primary,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    folder.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Icon(
                                  Icons.chevron_right_rounded,
                                  size: 18,
                                  color: cs.mutedForeground,
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
    );
  }
}

class _LibraryRow extends StatelessWidget {
  final MediaLibraryDefinition library;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _LibraryRow({
    required this.library,
    required this.selected,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: selected
            ? cs.primary.withValues(alpha: 0.08)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: selected ? cs.primary : cs.border),
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
            child: Row(
              children: [
                Icon(
                  Icons.video_library_rounded,
                  size: 20,
                  color: selected ? cs.primary : cs.mutedForeground,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        library.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: cs.foreground,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${library.kind.title} · ${library.rootPath}',
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
                ShadTooltip(
                  builder: (_) => const Text('管理媒体库'),
                  child: ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    onPressed: onEdit,
                    child: const Icon(Icons.edit_outlined, size: 15),
                  ),
                ),
                ShadTooltip(
                  builder: (_) => const Text('删除媒体库'),
                  child: ShadButton.destructive(
                    size: ShadButtonSize.sm,
                    onPressed: onDelete,
                    child: const Icon(Icons.delete_outline_rounded, size: 15),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaWork {
  final String key;
  final MediaLibraryItem primary;
  final List<MediaLibraryItem> resources;

  const _MediaWork({
    required this.key,
    required this.primary,
    required this.resources,
  });

  static List<_MediaWork> fromItems(Iterable<MediaLibraryItem> items) {
    final grouped = <String, List<MediaLibraryItem>>{};
    for (final item in items) {
      final title = item.title.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9\u4e00-\u9fff]'),
        '',
      );
      final kind = item.mediaKind?.name ?? 'unknown';
      final key = item.tmdbID == null
          ? '$kind:$title:${item.year}'
          : '$kind:tmdb:${item.tmdbID}';
      grouped.putIfAbsent(key, () => []).add(item);
    }
    return grouped.entries.map((entry) {
      final resources = entry.value
        ..sort(
          (a, b) =>
              a.file.name.toLowerCase().compareTo(b.file.name.toLowerCase()),
        );
      final primary = resources.reduce((best, candidate) {
        final bestScore =
            (best.hasChineseAudio ? 2 : 0) +
            (best.hasChineseSubtitle ? 1 : 0) +
            (best.posterPath?.isNotEmpty == true ? 1 : 0);
        final candidateScore =
            (candidate.hasChineseAudio ? 2 : 0) +
            (candidate.hasChineseSubtitle ? 1 : 0) +
            (candidate.posterPath?.isNotEmpty == true ? 1 : 0);
        return candidateScore > bestScore ? candidate : best;
      });
      return _MediaWork(key: entry.key, primary: primary, resources: resources);
    }).toList()..sort(
      (a, b) => a.primary.title.toLowerCase().compareTo(
        b.primary.title.toLowerCase(),
      ),
    );
  }
}

class _MediaCollection {
  final String key;
  final String name;
  final MediaLibraryItem primary;
  final List<MediaLibraryItem> resources;
  final int workCount;

  const _MediaCollection({
    required this.key,
    required this.name,
    required this.primary,
    required this.resources,
    required this.workCount,
  });

  static List<_MediaCollection> fromItems(Iterable<MediaLibraryItem> items) {
    final grouped = <String, List<MediaLibraryItem>>{};
    final names = <String, String>{};
    for (final item in items) {
      final name = item.collectionName?.trim();
      if (name == null || name.isEmpty) continue;
      final key = item.collectionID == null
          ? 'name:${name.toLowerCase()}'
          : 'tmdb:${item.collectionID}';
      grouped.putIfAbsent(key, () => []).add(item);
      names[key] = name;
    }
    return grouped.entries
        .map((entry) {
          final resources = entry.value;
          final works = _MediaWork.fromItems(resources);
          final primary = works.map((work) => work.primary).reduce((
            best,
            candidate,
          ) {
            final bestScore =
                (best.posterPath?.isNotEmpty == true ? 1 : 0) +
                (best.hasChineseAudio ? 1 : 0);
            final candidateScore =
                (candidate.posterPath?.isNotEmpty == true ? 1 : 0) +
                (candidate.hasChineseAudio ? 1 : 0);
            return candidateScore > bestScore ? candidate : best;
          });
          return _MediaCollection(
            key: entry.key,
            name: names[entry.key] ?? '未命名合集',
            primary: primary,
            resources: resources,
            workCount: works.length,
          );
        })
        .where((collection) => collection.workCount >= 2)
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }
}

class _MediaCollectionTile extends ConsumerWidget {
  final _MediaCollection collection;
  final VoidCallback onOpen;

  const _MediaCollectionTile({required this.collection, required this.onOpen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = ShadTheme.of(context).colorScheme;
    final item = collection.primary;
    final posterURL = item.posterPath?.isNotEmpty == true
        ? _tmdbImageURL(item.posterPath!, size: 'w342')
        : null;
    return Semantics(
      button: true,
      label: '${collection.name}，${collection.workCount} 部作品',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: cs.muted,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: cs.border),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: posterURL == null
                          ? Center(
                              child: Icon(
                                Icons.collections_bookmark_rounded,
                                color: cs.mutedForeground,
                                size: 34,
                              ),
                            )
                          : CachedNetworkImage(
                              imageUrl: posterURL,
                              fit: BoxFit.cover,
                              errorWidget: (_, _, _) => _tmdbDirectFallback(
                                path: item.posterPath!,
                                size: 'w342',
                                fallback: Center(
                                  child: Icon(
                                    Icons.collections_bookmark_rounded,
                                    color: cs.mutedForeground,
                                    size: 34,
                                  ),
                                ),
                              ),
                            ),
                    ),
                    Positioned(
                      right: 7,
                      bottom: 7,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.72),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${collection.workCount} 部',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                collection.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: cs.foreground,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '${collection.workCount} 部作品 · 自动合集',
                style: TextStyle(fontSize: 11, color: cs.mutedForeground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MediaPosterTile extends ConsumerWidget {
  final _MediaWork work;
  final VoidCallback onOpen;
  final VoidCallback onDownload;
  final VoidCallback? onRescan;

  const _MediaPosterTile({
    required this.work,
    required this.onOpen,
    required this.onDownload,
    this.onRescan,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = ShadTheme.of(context).colorScheme;
    final item = work.primary;
    final isSeries = item.mediaKind == TMDBMediaKind.tv;
    final posterURL = item.posterPath?.isNotEmpty == true
        ? _tmdbImageURL(item.posterPath!, size: 'w342')
        : null;
    return ShadContextMenuRegion(
      items: [
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.info, size: 16),
          onPressed: onOpen,
          child: const Text('查看详情'),
        ),
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.download, size: 16),
          onPressed: onDownload,
          child: const Text('打开资源'),
        ),
        const Divider(height: 8),
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.refreshCw, size: 16),
          onPressed: onRescan,
          child: const Text('重新扫描媒体库'),
        ),
      ],
      child: Semantics(
        button: true,
        label: '${item.title}，${work.resources.length} 个资源版本',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: cs.muted,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: cs.border),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: posterURL == null
                            ? _posterFallback(cs, isSeries)
                            : CachedNetworkImage(
                                imageUrl: posterURL,
                                fit: BoxFit.cover,
                                errorWidget: (_, _, _) => _tmdbDirectFallback(
                                  path: item.posterPath!,
                                  size: 'w342',
                                  fallback: _posterFallback(cs, isSeries),
                                ),
                              ),
                      ),
                      if (work.resources.length > 1)
                        Positioned(
                          right: 7,
                          bottom: 7,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.72),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              isSeries
                                  ? '${work.resources.length} 集'
                                  : '${work.resources.length} 版本',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: cs.foreground,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${item.year.isEmpty ? '未知年份' : item.year} · ${isSeries ? '剧集' : '电影'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: cs.mutedForeground),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _posterFallback(ShadColorScheme cs, bool isSeries) => Center(
    child: Icon(
      isSeries ? Icons.tv_rounded : Icons.movie_rounded,
      color: cs.mutedForeground,
      size: 34,
    ),
  );
}

class _MediaDetailPanel extends ConsumerStatefulWidget {
  final _MediaWork work;
  final VoidCallback onBack;
  final ValueChanged<MediaLibraryItem> onDownload;
  final ValueChanged<MediaLibraryItem> onPlay;
  final ValueChanged<MediaLibraryItem> onExternalPlay;
  final VoidCallback onManualMatch;
  final VoidCallback onRefreshAndRecognize;

  const _MediaDetailPanel({
    required this.work,
    required this.onBack,
    required this.onDownload,
    required this.onPlay,
    required this.onExternalPlay,
    required this.onManualMatch,
    required this.onRefreshAndRecognize,
  });

  @override
  ConsumerState<_MediaDetailPanel> createState() => _MediaDetailPanelState();
}

class _MediaDetailPanelState extends ConsumerState<_MediaDetailPanel> {
  late MediaLibraryItem _resource = widget.work.primary;
  Map<String, dynamic>? _tmdbDetails;
  int? _loadedTMDBID;
  bool _loadingTMDBDetails = false;
  final _updatePopover = ShadPopoverController();

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadTMDBDetails);
  }

  @override
  void didUpdateWidget(covariant _MediaDetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final updatedResource = widget.work.resources
        .where((item) => item.id == _resource.id)
        .firstOrNull;
    if (updatedResource != null) {
      _resource = updatedResource;
    } else {
      _resource = widget.work.primary;
    }
    if (widget.work.primary.tmdbID != _loadedTMDBID) {
      Future.microtask(_loadTMDBDetails);
    }
  }

  @override
  void dispose() {
    _updatePopover.dispose();
    super.dispose();
  }

  Widget _updateMediaMenu() {
    return ShadPopover(
      controller: _updatePopover,
      padding: const EdgeInsets.all(8),
      popover: (_) => SizedBox(
        width: 230,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ShadButton.outline(
              size: ShadButtonSize.sm,
              onPressed: () {
                _updatePopover.hide();
                widget.onRefreshAndRecognize();
              },
              leading: const Icon(Icons.sync_rounded, size: 16),
              child: const Text('同步并自动识别'),
            ),
            const SizedBox(height: 6),
            ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: () {
                _updatePopover.hide();
                widget.onManualMatch();
              },
              leading: const Icon(Icons.edit_note_rounded, size: 16),
              child: const Text('手动匹配 TMDB'),
            ),
          ],
        ),
      ),
      child: ShadButton.outline(
        onPressed: () => _updatePopover.toggle(),
        leading: const Icon(Icons.sync_rounded, size: 16),
        child: const Text('更新媒体信息'),
      ),
    );
  }

  Future<void> _loadTMDBDetails() async {
    final item = widget.work.primary;
    final tmdbID = item.tmdbID;
    final kind = item.mediaKind;
    final apiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    if (tmdbID == null ||
        kind == null ||
        apiKey.isEmpty ||
        _loadedTMDBID == tmdbID ||
        _loadingTMDBDetails) {
      return;
    }
    setState(() => _loadingTMDBDetails = true);
    try {
      final details = await ref
          .read(authProvider.notifier)
          .api
          .tmdbDetails(
            tmdbID,
            mediaKind: kind == TMDBMediaKind.tv ? 'tv' : 'movie',
            apiKey: apiKey,
            proxyHost:
                StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '',
            proxyPort:
                StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '',
          );
      if (mounted) {
        setState(() {
          _tmdbDetails = details;
          _loadedTMDBID = tmdbID;
        });
      }
    } catch (_) {
      // Artwork enrichments are optional and should not interrupt playback.
    } finally {
      if (mounted) setState(() => _loadingTMDBDetails = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final item = widget.work.primary;
    final isSeries = item.mediaKind == TMDBMediaKind.tv;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: widget.onBack,
              leading: const Icon(Icons.arrow_back_rounded, size: 16),
              child: const Text('返回海报墙'),
            ),
            _updateMediaMenu(),
            const SizedBox(width: 8),
            ShadButton(
              onPressed: () => widget.onPlay(_resource),
              leading: const Icon(Icons.play_arrow_rounded, size: 16),
              child: const Text('播放'),
            ),
            ShadButton.outline(
              onPressed: () => widget.onExternalPlay(_resource),
              leading: const Icon(Icons.launch_rounded, size: 16),
              child: const Text('外部播放器'),
            ),
            ShadButton.outline(
              onPressed: () => widget.onDownload(_resource),
              leading: const Icon(Icons.download_rounded, size: 16),
              child: const Text('下载'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 700;
              final information = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _detailInformation(context, item, isSeries),
                  if (item.isMatched) ...[
                    const SizedBox(height: 22),
                    _tmdbEnrichment(context),
                  ],
                ],
              );
              final resources = _resourceList(context, cs);
              return SingleChildScrollView(
                child: compact
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          information,
                          const SizedBox(height: 18),
                          resources,
                        ],
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 3, child: information),
                          const SizedBox(width: 28),
                          SizedBox(width: 310, child: resources),
                        ],
                      ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _detailInformation(
    BuildContext context,
    MediaLibraryItem item,
    bool isSeries,
  ) {
    final cs = ShadTheme.of(context).colorScheme;
    final posterURL = item.posterPath?.isNotEmpty == true
        ? _tmdbImageURL(item.posterPath!, size: 'w342')
        : null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 180,
          height: 270,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: posterURL == null
                ? _detailPosterFallback(cs, isSeries)
                : CachedNetworkImage(
                    imageUrl: posterURL,
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) => _tmdbDirectFallback(
                      path: item.posterPath!,
                      size: 'w342',
                      fallback: _detailPosterFallback(cs, isSeries),
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                item.title,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: cs.foreground,
                ),
              ),
              if (item.originalTitle.isNotEmpty &&
                  item.originalTitle != item.title) ...[
                const SizedBox(height: 3),
                SelectableText(
                  item.originalTitle,
                  style: TextStyle(fontSize: 13, color: cs.mutedForeground),
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ShadBadge(child: Text(isSeries ? '剧集' : '电影')),
                  if (item.year.isNotEmpty)
                    ShadBadge.outline(child: Text(item.year)),
                  if (item.hasChineseAudio)
                    const ShadBadge.outline(child: Text('中文音轨')),
                  if (item.hasChineseSubtitle)
                    const ShadBadge.outline(child: Text('中文字幕')),
                ],
              ),
              const SizedBox(height: 16),
              SelectableText(
                item.overview.isEmpty ? '暂无影视简介。' : item.overview,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.55,
                  color: cs.mutedForeground,
                ),
              ),
              const SizedBox(height: 16),
              _metadataRow(context, 'TMDB', item.tmdbID?.toString() ?? '未匹配'),
              _metadataRow(context, '资源数', '${widget.work.resources.length}'),
              _metadataRow(context, '当前文件', _resource.file.name),
              _metadataRow(context, '文件 ID', _resource.file.id),
              _metadataRow(
                context,
                'GCID',
                _resource.file.gcid?.isNotEmpty == true
                    ? _resource.file.gcid!
                    : '未获取',
              ),
              _metadataRow(context, '文件大小', _resource.file.formattedSize),
              _metadataRow(context, '云盘位置', _resource.file.cloudPath),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tmdbEnrichment(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    if (_loadingTMDBDetails && _tmdbDetails == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Row(children: [SizedBox(width: 100, child: ShadProgress())]),
      );
    }
    final details = _tmdbDetails;
    if (details == null) return const SizedBox.shrink();
    final images = details['images'] is Map
        ? Map<String, dynamic>.from(details['images'] as Map)
        : const <String, dynamic>{};
    final posters = _imagePaths(images['posters']);
    final backdrops = _imagePaths(images['backdrops']);
    final credits = details['credits'] is Map
        ? Map<String, dynamic>.from(details['credits'] as Map)
        : const <String, dynamic>{};
    final cast =
        (credits['cast'] as List?)
            ?.whereType<Map>()
            .map((value) => Map<String, dynamic>.from(value))
            .take(12)
            .toList() ??
        const <Map<String, dynamic>>[];
    if (posters.isEmpty && backdrops.isEmpty && cast.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (backdrops.isNotEmpty) ...[
          Text(
            '横幅与剧照',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: cs.foreground,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 155,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: backdrops.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) => ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: CachedNetworkImage(
                  imageUrl: _tmdbImageURL(backdrops[index], size: 'w780'),
                  width: 260,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => _tmdbDirectFallback(
                    path: backdrops[index],
                    size: 'w780',
                    width: 260,
                    fallback: const SizedBox(width: 260),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
        ],
        if (posters.isNotEmpty) ...[
          Text(
            '更多海报',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: cs.foreground,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 160,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: posters.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) => ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: CachedNetworkImage(
                  imageUrl: _tmdbImageURL(posters[index], size: 'w342'),
                  width: 106,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => _tmdbDirectFallback(
                    path: posters[index],
                    size: 'w342',
                    width: 106,
                    fallback: const SizedBox(width: 106),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
        ],
        if (cast.isNotEmpty) ...[
          Text(
            '演职员',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: cs.foreground,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 180,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: cast.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final person = cast[index];
                final profile = person['profile_path']?.toString();
                return SizedBox(
                  width: 96,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: profile == null || profile.isEmpty
                            ? Container(
                                width: 96,
                                height: 122,
                                color: cs.muted,
                                child: Icon(
                                  Icons.person_rounded,
                                  color: cs.mutedForeground,
                                ),
                              )
                            : CachedNetworkImage(
                                imageUrl: _tmdbImageURL(profile, size: 'w185'),
                                width: 96,
                                height: 122,
                                fit: BoxFit.cover,
                                errorWidget: (_, _, _) => _tmdbDirectFallback(
                                  path: profile,
                                  size: 'w185',
                                  width: 96,
                                  height: 122,
                                  fallback: Container(
                                    width: 96,
                                    height: 122,
                                    color: cs.muted,
                                  ),
                                ),
                              ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        person['name']?.toString() ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: cs.foreground,
                        ),
                      ),
                      Text(
                        person['character']?.toString() ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: cs.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  List<String> _imagePaths(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((image) => image['file_path']?.toString())
        .whereType<String>()
        .where((path) => path.isNotEmpty)
        .take(12)
        .toList();
  }

  Widget _detailPosterFallback(ShadColorScheme cs, bool isSeries) => Container(
    color: cs.muted,
    child: Center(
      child: Icon(
        isSeries ? Icons.tv_rounded : Icons.movie_rounded,
        color: cs.mutedForeground,
        size: 42,
      ),
    ),
  );

  Widget _metadataRow(BuildContext context, String label, String value) {
    final cs = ShadTheme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: SelectableText(
              label,
              style: TextStyle(fontSize: 12, color: cs.mutedForeground),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(fontSize: 12, color: cs.foreground),
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _resourceList(BuildContext context, ShadColorScheme cs) {
    final isSeries = widget.work.primary.mediaKind == TMDBMediaKind.tv;
    final episodesBySeason = <int, List<MediaLibraryItem>>{};
    if (isSeries) {
      for (final resource in widget.work.resources) {
        final parsed = ParsedMediaName.parse(resource.file.name);
        (episodesBySeason[parsed.season ?? 1] ??= []).add(resource);
      }
      for (final values in episodesBySeason.values) {
        values.sort((a, b) {
          final aEpisode = ParsedMediaName.parse(a.file.name).episode ?? 9999;
          final bEpisode = ParsedMediaName.parse(b.file.name).episode ?? 9999;
          return aEpisode == bEpisode
              ? a.file.name.compareTo(b.file.name)
              : aEpisode.compareTo(bEpisode);
        });
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isSeries
              ? '剧集 (${widget.work.resources.length} 集)'
              : widget.work.resources.length > 1
              ? '资源版本 (${widget.work.resources.length})'
              : '媒体资源',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: cs.foreground,
          ),
        ),
        const SizedBox(height: 8),
        if (isSeries && episodesBySeason.isNotEmpty)
          for (final entry in episodesBySeason.entries) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 6),
              child: Text(
                '第 ${entry.key} 季',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: cs.foreground,
                ),
              ),
            ),
            ...entry.value.map(
              (resource) => _resourceTile(
                resource,
                cs,
                episode: ParsedMediaName.parse(resource.file.name).episode,
              ),
            ),
          ]
        else
          ...widget.work.resources.map(
            (resource) => _resourceTile(resource, cs),
          ),
      ],
    );
  }

  Widget _resourceTile(
    MediaLibraryItem resource,
    ShadColorScheme cs, {
    int? episode,
  }) {
    final selected = resource.id == _resource.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ShadContextMenuRegion(
        items: [
          ShadContextMenuItem.inset(
            leading: const Icon(LucideIcons.play, size: 16),
            onPressed: () => widget.onPlay(resource),
            child: const Text('播放'),
          ),
          ShadContextMenuItem.inset(
            leading: const Icon(LucideIcons.monitorPlay, size: 16),
            onPressed: () => widget.onExternalPlay(resource),
            child: const Text('外部播放器'),
          ),
          ShadContextMenuItem.inset(
            leading: const Icon(LucideIcons.download, size: 16),
            onPressed: () => widget.onDownload(resource),
            child: const Text('下载'),
          ),
        ],
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => setState(() => _resource = resource),
            borderRadius: BorderRadius.circular(6),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: selected ? cs.primary.withValues(alpha: 0.10) : cs.card,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: selected ? cs.primary : cs.border),
              ),
              child: Row(
                children: [
                  if (episode != null)
                    SizedBox(
                      width: 38,
                      child: Text(
                        'E${episode.toString().padLeft(2, '0')}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: cs.primary,
                        ),
                      ),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(
                          resource.file.name,
                          maxLines: 2,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: cs.foreground,
                          ),
                        ),
                        const SizedBox(height: 4),
                        SelectableText(
                          '${resource.file.formattedSize} · ${resource.file.modifiedAt}',
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.mutedForeground,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (selected)
                    Icon(
                      Icons.check_circle_rounded,
                      size: 16,
                      color: cs.primary,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ManualTMDBMatchDialog extends ConsumerStatefulWidget {
  final String initialQuery;

  const _ManualTMDBMatchDialog({required this.initialQuery});

  @override
  ConsumerState<_ManualTMDBMatchDialog> createState() =>
      _ManualTMDBMatchDialogState();
}

class _ManualTMDBMatchDialogState
    extends ConsumerState<_ManualTMDBMatchDialog> {
  late final TextEditingController _queryController;
  bool _searching = false;
  String? _error;
  List<Map<String, dynamic>> _results = const [];

  @override
  void initState() {
    super.initState();
    _queryController = TextEditingController(text: widget.initialQuery);
    Future.microtask(_search);
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _queryController.text.trim();
    final apiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    if (query.isEmpty || apiKey.isEmpty) {
      setState(() {
        _results = const [];
        _error = apiKey.isEmpty ? '请先在设置中配置 TMDB API Key。' : null;
      });
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(authProvider.notifier)
          .api
          .tmdbSearch(
            query,
            apiKey: apiKey,
            proxyHost:
                StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '',
            proxyPort:
                StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '',
          );
      final values =
          (result['results'] as List?)
              ?.whereType<Map>()
              .map(Map<String, dynamic>.from)
              .where(
                (item) =>
                    item['id'] != null &&
                    (item['media_type'] == 'movie' ||
                        item['media_type'] == 'tv'),
              )
              .toList() ??
          const <Map<String, dynamic>>[];
      if (mounted) setState(() => _results = values);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ShadDialog(
      title: const Text('手动匹配 TMDB'),
      description: const Text('选择一个结果后，会应用到该作品的全部资源版本。'),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ShadButton(
          onPressed: _searching ? null : _search,
          leading: const Icon(Icons.search_rounded, size: 16),
          child: const Text('搜索'),
        ),
      ],
      child: SizedBox(
        width: 620,
        height: 500,
        child: Column(
          children: [
            ShadInput(
              controller: _queryController,
              placeholder: const Text('输入片名'),
              onSubmitted: (_) => _search(),
              leading: Icon(
                Icons.search_rounded,
                size: 16,
                color: cs.mutedForeground,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _searching
                  ? const Center(child: ShadProgress())
                  : _error != null
                  ? Center(
                      child: Text(
                        _error!,
                        style: TextStyle(color: cs.destructive),
                      ),
                    )
                  : _results.isEmpty
                  ? Center(
                      child: Text(
                        '没有匹配结果',
                        style: TextStyle(color: cs.mutedForeground),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _results.length,
                      separatorBuilder: (_, _) =>
                          Divider(height: 1, color: cs.border),
                      itemBuilder: (context, index) =>
                          _candidateRow(context, cs, _results[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _candidateRow(
    BuildContext context,
    ShadColorScheme cs,
    Map<String, dynamic> candidate,
  ) {
    final title = (candidate['title'] ?? candidate['name'] ?? '未知标题')
        .toString();
    final release =
        (candidate['release_date'] ?? candidate['first_air_date'] ?? '')
            .toString();
    final posterPath = candidate['poster_path']?.toString();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => Navigator.of(context).pop(candidate),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              SizedBox(
                width: 44,
                height: 64,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: posterPath == null || posterPath.isEmpty
                      ? Container(
                          color: cs.muted,
                          child: Icon(
                            Icons.movie_rounded,
                            size: 20,
                            color: cs.mutedForeground,
                          ),
                        )
                      : CachedNetworkImage(
                          imageUrl: _tmdbImageURL(posterPath, size: 'w154'),
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => _tmdbDirectFallback(
                            path: posterPath,
                            size: 'w154',
                            fallback: Container(
                              color: cs.muted,
                              child: Icon(
                                Icons.movie_rounded,
                                size: 20,
                                color: cs.mutedForeground,
                              ),
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: cs.foreground,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${release.length >= 4 ? release.substring(0, 4) : '未知年份'} · ${candidate['media_type'] == 'tv' ? '剧集' : '电影'}',
                      style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      candidate['overview']?.toString() ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: cs.mutedForeground),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: cs.mutedForeground),
            ],
          ),
        ),
      ),
    );
  }
}
