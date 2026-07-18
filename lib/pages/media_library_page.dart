import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../core/storage/storage_manager.dart';
import '../models/media_library.dart';
import '../providers/auth_provider.dart';
import '../providers/file_provider.dart';
import '../providers/media_library_provider.dart';

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
  String _tmdbApiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
  bool _showApiKeyInput = false;
  bool _tmdbSearching = false;
  String? _tmdbError;
  List<Map<String, dynamic>> _tmdbResults = [];
  final _apiKeyController = TextEditingController();
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _apiKeyController.text = _tmdbApiKey;
    Future.microtask(() {
      ref.read(mediaLibraryProvider.notifier).api = ref
          .read(authProvider.notifier)
          .api;
      ref.read(mediaLibraryProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
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
        _statPill(context, '全部', stats.total.toString()),
        _statPill(context, '电影', stats.movies.toString()),
        _statPill(context, '剧集', stats.series.toString()),
        _statPill(context, '待匹配', stats.unmatched.toString()),
      ],
    );
  }

  Widget _statPill(BuildContext context, String label, String value) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.muted,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.border),
      ),
      child: Text(
        '$label $value',
        style: TextStyle(fontSize: 12, color: cs.mutedForeground),
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
            placeholder: const Text('搜索影视库或 TMDB…'),
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
        ShadButton.outline(
          onPressed: () => setState(() => _showApiKeyInput = !_showApiKeyInput),
          leading: Icon(
            _tmdbApiKey.isEmpty ? Icons.key_off_rounded : Icons.key_rounded,
            size: 16,
          ),
          child: const Text('TMDB'),
        ),
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
          if (_showApiKeyInput) _buildTMDBConfig(context),
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

  Widget _buildTMDBConfig(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: cs.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          ShadInput(
            controller: _apiKeyController,
            placeholder: const Text('TMDB API Key'),
            obscureText: true,
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ShadButton(onPressed: _saveApiKey, child: const Text('保存')),
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
    if (state.isScanning) {
      return _scanProgress(context, state);
    }
    if (_tmdbSearching || _tmdbResults.isNotEmpty || _tmdbError != null) {
      return _tmdbResultPanel(context);
    }
    final items = state.visibleItems;
    if (state.selectedLibrary == null) {
      return _mainEmpty(context, '还没有媒体库', '从云盘根目录或当前目录创建一个媒体库');
    }
    if (items.isEmpty) {
      return _mainEmpty(context, '没有扫描结果', '点击扫描读取该媒体库下的视频文件');
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 220).floor().clamp(2, 6);
        return GridView.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.8,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) => _MediaItemTile(item: items[index]),
        );
      },
    );
  }

  Widget _scanProgress(BuildContext context, MediaLibraryState state) {
    final cs = ShadTheme.of(context).colorScheme;
    return Center(
      child: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ShadProgress(),
            const SizedBox(height: 16),
            Text(
              state.progress.phase,
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.foreground),
            ),
            const SizedBox(height: 6),
            Text(
              '已发现 ${state.progress.completed} 个视频文件',
              style: TextStyle(fontSize: 12, color: cs.mutedForeground),
            ),
          ],
        ),
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
                : Image.network(
                    'https://image.tmdb.org/t/p/w200$posterPath',
                    width: 74,
                    height: 110,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        _posterPlaceholder(context, 74, 110),
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
    final currentRootID = fileState.folderPath.isEmpty
        ? null
        : fileState.folderPath.last.id;
    final currentPath = fileState.folderPath.isEmpty
        ? '云盘根目录'
        : fileState.folderPath.map((file) => file.name).join(' / ');
    final nameController = TextEditingController(
      text: fileState.folderPath.isEmpty
          ? '我的影视库'
          : fileState.folderPath.last.name,
    );
    final minSizeController = TextEditingController(text: '50');
    var kind = MediaLibraryKind.mixed;
    var recursive = true;

    showShadDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => ShadDialog(
          title: const Text('创建媒体库'),
          description: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('来源：$currentPath'),
          ),
          actions: [
            ShadButton.outline(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            ShadButton(
              onPressed: () {
                ref
                    .read(mediaLibraryProvider.notifier)
                    .createLibrary(
                      name: nameController.text,
                      rootID: currentRootID,
                      rootPath: currentPath,
                      kind: kind,
                      recursive: recursive,
                      minimumSizeMB:
                          int.tryParse(minSizeController.text.trim()) ?? 50,
                    );
                Navigator.of(ctx).pop();
              },
              child: const Text('创建'),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ShadInput(
                controller: nameController,
                placeholder: const Text('媒体库名称'),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: ShadSelect<MediaLibraryKind>(
                      initialValue: kind,
                      placeholder: const Text('媒体类型'),
                      selectedOptionBuilder: (context, value) =>
                          Text(value.title),
                      options: [
                        for (final value in MediaLibraryKind.values)
                          ShadOption(value: value, child: Text(value.title)),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => kind = value);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 120,
                    child: ShadInput(
                      controller: minSizeController,
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
                  value: recursive,
                  label: const Text('递归扫描子目录'),
                  onChanged: (value) => setDialogState(() => recursive = value),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _saveApiKey() {
    final key = _apiKeyController.text.trim();
    StorageManager.set(StorageKeys.tmdbApiKey, key);
    setState(() {
      _tmdbApiKey = key;
      _showApiKeyInput = false;
    });
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
      final result = await api.tmdbSearch(text, apiKey: _tmdbApiKey);
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
}

class _LibraryRow extends StatelessWidget {
  final MediaLibraryDefinition library;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _LibraryRow({
    required this.library,
    required this.selected,
    required this.onTap,
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
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
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
                      style: TextStyle(fontSize: 11, color: cs.mutedForeground),
                    ),
                  ],
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
    );
  }
}

class _MediaItemTile extends StatelessWidget {
  final MediaLibraryItem item;

  const _MediaItemTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.border),
      ),
      child: Row(
        children: [
          Container(
            width: 54,
            height: 76,
            decoration: BoxDecoration(
              color: cs.muted,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              Icons.movie_rounded,
              size: 24,
              color: cs.mutedForeground,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  item.year.isEmpty
                      ? item.title
                      : '${item.title} (${item.year})',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: cs.foreground,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  item.file.formattedSize,
                  style: TextStyle(fontSize: 11, color: cs.mutedForeground),
                ),
                const SizedBox(height: 2),
                Text(
                  item.file.cloudPath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: cs.mutedForeground),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
