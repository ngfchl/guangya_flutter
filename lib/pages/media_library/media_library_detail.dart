part of '../media_library_page.dart';

class _MediaDetailPanel extends ConsumerStatefulWidget {
  final _MediaWork work;
  final ValueChanged<MediaLibraryItem> onDownload;
  final ValueChanged<MediaLibraryItem> onPlay;
  final ValueChanged<MediaLibraryItem> onExternalPlay;
  final Future<void> Function(MediaLibraryItem) onRenameFile;
  final Future<void> Function(MediaLibraryItem) onMoveMediaResource;
  final Future<void> Function(MediaLibraryItem) onMoveCloudFile;
  final Future<void> Function(_MediaMetadataSource) onClearMetadata;
  final VoidCallback onRecognize;
  final ValueChanged<MediaLibraryItem> onManualMatch;
  final VoidCallback onRefreshDetail;
  final VoidCallback? onRefreshScrape;
  final Future<void> Function(List<MediaLibraryItem>) onRemoveRecords;
  final Future<bool> Function(List<MediaLibraryItem>) onDeleteFiles;
  final Set<String> manualMatchBusyResourceKeys;
  final Set<String> manualMatchLoadingResourceKeys;
  final bool removalDisabled;
  final bool recognizing;

  const _MediaDetailPanel({
    super.key,
    required this.work,
    required this.onDownload,
    required this.onPlay,
    required this.onExternalPlay,
    required this.onRenameFile,
    required this.onMoveMediaResource,
    required this.onMoveCloudFile,
    required this.onClearMetadata,
    required this.onRecognize,
    required this.onManualMatch,
    required this.onRefreshDetail,
    this.onRefreshScrape,
    required this.onRemoveRecords,
    required this.onDeleteFiles,
    this.manualMatchBusyResourceKeys = const {},
    this.manualMatchLoadingResourceKeys = const {},
    this.removalDisabled = false,
    this.recognizing = false,
  });

  @override
  ConsumerState<_MediaDetailPanel> createState() => _MediaDetailPanelState();
}

class _MediaDetailPanelState extends ConsumerState<_MediaDetailPanel> {
  late MediaLibraryItem _resource = widget.work.primary;
  Map<String, dynamic>? _tmdbDetails;
  Map<String, dynamic>? _episodeDetails;
  int? _loadedTMDBID;
  TMDBMediaKind? _loadedTMDBKind;
  int? _selectedSeason;
  String? _selectedEpisodeID;
  bool _loadingTMDBDetails = false;
  int _tmdbDetailRequestSerial = 0;
  bool _loadingEpisodeDetails = false;
  bool _removingRecords = false;
  bool _refreshScrapeBusy = false;
  bool _pageLoading = false;
  bool _initialEpisodeSelectionRequested = false;
  final _backdropController = PageController();
  final _removeMenuController = ShadPopoverController();
  Timer? _backdropTimer;
  var _backdropIndex = 0;

  // 剧集单集详情缓存，key = "$seriesID:$season:$episode"
  final _episodeDetailsCache = <String, Map<String, dynamic>>{};

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadTMDBDetails);
    Future.microtask(_selectInitialEpisode);
  }

  @override
  void didUpdateWidget(covariant _MediaDetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.work.primary.id != widget.work.primary.id) {
      _initialEpisodeSelectionRequested = false;
      _selectedEpisodeID = null;
      _episodeDetails = null;
      Future.microtask(_selectInitialEpisode);
    }
    final updatedResource = widget.work.resources
        .where((item) => item.id == _resource.id)
        .firstOrNull;
    if (updatedResource != null) {
      _resource = updatedResource;
    } else {
      _resource = widget.work.primary;
      if (_selectedEpisodeID != null) {
        _selectedEpisodeID = null;
        _episodeDetails = null;
        _initialEpisodeSelectionRequested = false;
        Future.microtask(_selectInitialEpisode);
      }
    }
    if (widget.work.primary.tmdbID != _loadedTMDBID ||
        widget.work.primary.mediaKind != _loadedTMDBKind) {
      _tmdbDetails = null;
      _selectedSeason = null;
      _selectedEpisodeID = null;
      _episodeDetails = null;
      Future.microtask(_loadTMDBDetails);
    }
  }

  @override
  void dispose() {
    _backdropTimer?.cancel();
    _backdropController.dispose();
    _removeMenuController.dispose();
    super.dispose();
  }

  Future<void> _loadTMDBDetails({bool force = false}) async {
    if (!mounted) return;
    final item = widget.work.primary;
    final tmdbID = item.tmdbID;
    final kind = item.mediaKind;
    if (tmdbID == null) {
      if (_tmdbDetails != null) {
        setState(() {
          _tmdbDetails = null;
          _loadedTMDBID = null;
          _loadedTMDBKind = null;
        });
      }
      return;
    }
    final apiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    if (kind == null ||
        apiKey.isEmpty ||
        (!force && _loadedTMDBID == tmdbID && _loadedTMDBKind == kind)) {
      return;
    }
    final requestSerial = ++_tmdbDetailRequestSerial;
    // 如果条目已有 TMDB 基础信息（posterPath），识别已完成，
    // 详情页不应显示 loading，而是在后台静默加载额外富数据（演职员、海报等）
    final itemHasBasicData =
        item.posterPath?.isNotEmpty == true || item.overview.isNotEmpty;
    if (!itemHasBasicData) {
      setState(() => _loadingTMDBDetails = true);
    }
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
      if (mounted &&
          requestSerial == _tmdbDetailRequestSerial &&
          widget.work.primary.tmdbID == tmdbID) {
        setState(() {
          _tmdbDetails = details;
          _loadedTMDBID = tmdbID;
          _loadedTMDBKind = kind;
        });
        _restartBackdropCarousel();
      }
    } catch (_) {
      // Artwork enrichments are optional and should not interrupt playback.
    } finally {
      if (mounted && requestSerial == _tmdbDetailRequestSerial) {
        setState(() => _loadingTMDBDetails = false);
      }
    }
  }

  Future<void> _selectEpisode(MediaLibraryItem resource) async {
    final parsed = ParsedMediaName.parse(
      resource.file.name,
      directoryName: _parentDirectoryName(resource.file.cloudPath),
    );
    setState(() {
      _resource = resource;
      _selectedSeason = parsed.season ?? _selectedSeason ?? 1;
      _selectedEpisodeID = resource.id;
      _episodeDetails = null;
    });
    final tmdbID = widget.work.primary.tmdbID;
    final season = parsed.season;
    final episode = parsed.episode;
    final apiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    if (tmdbID == null || season == null || episode == null || apiKey.isEmpty) {
      return;
    }
    setState(() => _loadingEpisodeDetails = true);
    // 检查缓存
    final cacheKey = '$tmdbID:$season:$episode';
    final cached = _episodeDetailsCache[cacheKey];
    if (cached != null) {
      if (mounted && _selectedEpisodeID == resource.id) {
        setState(() {
          _episodeDetails = cached;
          _loadingEpisodeDetails = false;
        });
      }
      return;
    }
    try {
      final details = await ref
          .read(authProvider.notifier)
          .api
          .tmdbEpisodeDetails(
            tmdbID,
            season: season,
            episode: episode,
            apiKey: apiKey,
            proxyHost:
                StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '',
            proxyPort:
                StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '',
          );
      if (mounted && _selectedEpisodeID == resource.id) {
        _episodeDetailsCache[cacheKey] = details;
        setState(() => _episodeDetails = details);
      }
    } catch (_) {
      // File metadata remains available when an episode detail request fails.
    } finally {
      if (mounted && _selectedEpisodeID == resource.id) {
        setState(() => _loadingEpisodeDetails = false);
      }
    }
  }

  Future<void> _selectInitialEpisode() async {
    if (_initialEpisodeSelectionRequested ||
        widget.work.primary.mediaKind != TMDBMediaKind.tv) {
      return;
    }
    _initialEpisodeSelectionRequested = true;
    final episodes =
        widget.work.resources
            .map(
              (resource) => (
                resource: resource,
                parsed: ParsedMediaName.parse(
                  resource.file.name,
                  directoryName: _parentDirectoryName(resource.file.cloudPath),
                ),
              ),
            )
            .where((entry) => entry.parsed.episode != null)
            .toList()
          ..sort((left, right) {
            final season = (left.parsed.season ?? 1).compareTo(
              right.parsed.season ?? 1,
            );
            if (season != 0) return season;
            return (left.parsed.episode ?? 0).compareTo(
              right.parsed.episode ?? 0,
            );
          });
    if (episodes.isEmpty) return;
    final historyByID = {
      for (final entry in ref.read(watchHistoryProvider)) entry.fileID: entry,
    };
    final lastPlayed = episodes
        .where((entry) => historyByID.containsKey(entry.resource.id))
        .fold<({MediaLibraryItem resource, ParsedMediaName parsed})?>(null, (
          current,
          entry,
        ) {
          if (current == null) return entry;
          final currentHistory = historyByID[current.resource.id]!;
          final candidateHistory = historyByID[entry.resource.id]!;
          return candidateHistory.updatedAt.isAfter(currentHistory.updatedAt)
              ? entry
              : current;
        });
    await _selectEpisode((lastPlayed ?? episodes.first).resource);
  }

  List<String> _heroBackdropPaths(MediaLibraryItem item) {
    final images = _tmdbDetails?['images'];
    final paths = <String>[
      ?mediaBackdropPath(item),
      if (_tmdbDetails?['backdrop_path']?.toString().isNotEmpty == true)
        _tmdbDetails!['backdrop_path'].toString(),
      if (images is Map) ..._imagePaths(images['backdrops']),
    ];
    return paths.toSet().take(10).toList();
  }

  List<String> _detailStringList(
    MediaLibraryItem item, {
    required bool genres,
  }) {
    final persisted = genres ? item.genres : item.originCountries;
    if (persisted.isNotEmpty) return persisted;
    final Object? raw;
    if (genres) {
      raw = _tmdbDetails?['genres'];
    } else {
      raw =
          _tmdbDetails?['production_countries'] ??
          _tmdbDetails?['origin_country'];
    }
    if (raw is! List) return const [];
    return raw
        .map((entry) {
          if (entry is Map) {
            return (genres
                    ? (entry['name'] ?? entry['english_name'])
                    : (entry['iso_3166_1'] ?? entry['code']))
                ?.toString()
                .trim();
          }
          return entry?.toString().trim();
        })
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  void _restartBackdropCarousel() {
    _backdropTimer?.cancel();
    final count = _heroBackdropPaths(widget.work.primary).length;
    if (count < 2) return;
    _backdropIndex = 0;
    if (_backdropController.hasClients) _backdropController.jumpToPage(0);
    _backdropTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!mounted || !_backdropController.hasClients) return;
      _backdropIndex = (_backdropIndex + 1) % count;
      _backdropController.animateToPage(
        _backdropIndex,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final item = widget.work.primary;
    final isSeries = item.mediaKind == TMDBMediaKind.tv;
    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _detailInformation(context, item, isSeries),
                    const SizedBox(height: 22),
                    if (item.isMatched) ...[
                      _tmdbEnrichment(context, showPosters: false),
                      const SizedBox(height: 22),
                    ],
                    _resourceList(context, cs),
                    if (item.isMatched) ...[
                      const SizedBox(height: 22),
                      _tmdbEnrichment(context, showCast: false),
                    ],
                    const SizedBox(height: 22),
                    _fileInformation(context, item),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (_pageLoading)
          Positioned.fill(
            child: AbsorbPointer(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.34),
                child: Center(
                  child: const AppLoadingIndicator(
                    size: AppLoadingSize.page,
                    semanticsLabel: '正在重新加载',
                  ),
                ),
              ),
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
    final genres = _detailStringList(item, genres: true);
    final originCountries = _detailStringList(
      item,
      genres: false,
    ).map(mediaCountryLabel).toSet().toList(growable: false);
    final ratingBadges = _ratingBadges(item);
    final posterURL = item.posterPath?.isNotEmpty == true
        ? _tmdbImageURL(item.posterPath!, size: 'w342')
        : null;
    final backdrops = _heroBackdropPaths(item);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600;
        return SizedBox(
          height: compact ? 560 : 370,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (backdrops.isNotEmpty)
                  PageView.builder(
                    controller: _backdropController,
                    itemCount: backdrops.length,
                    onPageChanged: (index) => _backdropIndex = index,
                    itemBuilder: (_, index) => CachedNetworkImage(
                      imageUrl: _tmdbImageURL(backdrops[index], size: 'w1280'),
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) => _tmdbDirectFallback(
                        path: backdrops[index],
                        size: 'w1280',
                        fallback: ColoredBox(color: cs.muted),
                      ),
                    ),
                  )
                else
                  ColoredBox(color: cs.muted),
                ColoredBox(color: Colors.black.withValues(alpha: 0.58)),
                Padding(
                  padding: EdgeInsets.all(compact ? 16 : 22),
                  child: Flex(
                    direction: compact ? Axis.vertical : Axis.horizontal,
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: compact
                        ? CrossAxisAlignment.start
                        : CrossAxisAlignment.end,
                    children: [
                      SizedBox(
                        width: compact ? 104 : 150,
                        height: compact ? 156 : 225,
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
                                    fallback: _detailPosterFallback(
                                      cs,
                                      isSeries,
                                    ),
                                  ),
                                ),
                        ),
                      ),
                      SizedBox(
                        width: compact ? 0 : 20,
                        height: compact ? 12 : 0,
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SelectableText(
                                item.title,
                                style: TextStyle(
                                  fontSize: compact ? 23 : 28,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              if (item.originalTitle.isNotEmpty &&
                                  item.originalTitle != item.title) ...[
                                const SizedBox(height: 3),
                                SelectableText(
                                  item.originalTitle,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.white.withValues(alpha: 0.72),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  ShadBadge(
                                    child: Text(isSeries ? '剧集' : '电影'),
                                  ),
                                  if (item.year.isNotEmpty)
                                    ShadBadge.outline(child: Text(item.year)),
                                  if (genres.isNotEmpty)
                                    ShadBadge.outline(
                                      child: Text(genres.join(' / ')),
                                    ),
                                  if (originCountries.isNotEmpty)
                                    ShadBadge.outline(
                                      child: Text(originCountries.join(' / ')),
                                    ),
                                  // ShadBadge.outline(
                                  //   child: Text(item.file.typeName),
                                  // ),
                                  if (item.hasChineseAudio)
                                    const ShadBadge.outline(
                                      child: Text('中文音轨'),
                                    ),
                                  if (item.hasChineseSubtitle)
                                    const ShadBadge.outline(
                                      child: Text('中文字幕'),
                                    ),
                                ],
                              ),
                              if (ratingBadges.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: ratingBadges,
                                ),
                              ],
                              const SizedBox(height: 14),
                              Text(
                                item.overview.isEmpty
                                    ? '暂无影视简介。'
                                    : item.overview,
                                maxLines: compact ? 3 : 4,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.55,
                                  color: Colors.white.withValues(alpha: 0.82),
                                ),
                              ),
                              const SizedBox(height: 14),
                              _detailLinks(item, cs),
                              const SizedBox(height: 14),
                              _mediaActions(),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Rating badges for the current resource. Shows TMDB and/or Douban scores
  /// when available; each badge opens the matching web page on tap.
  List<Widget> _ratingBadges(MediaLibraryItem item) {
    final badges = <Widget>[];
    final tmdbRating = item.tmdbRating;
    if (tmdbRating != null && tmdbRating > 0 && item.tmdbID != null) {
      final kind = item.mediaKind == TMDBMediaKind.tv ? 'tv' : 'movie';
      badges.add(
        _ratingBadge(
          label: 'TMDB',
          score: tmdbRating,
          color: const Color(0xFF01B4E4),
          url: 'https://www.themoviedb.org/$kind/${item.tmdbID}',
        ),
      );
    }
    final doubanRating = item.doubanRating;
    if (doubanRating != null &&
        doubanRating > 0 &&
        item.doubanID != null &&
        item.doubanID!.isNotEmpty) {
      badges.add(
        _ratingBadge(
          label: '豆瓣',
          score: doubanRating,
          color: const Color(0xFF2E963B),
          url: 'https://movie.douban.com/subject/${item.doubanID}/',
        ),
      );
    }
    return badges;
  }

  Widget _ratingBadge({
    required String label,
    required double score,
    required Color color,
    required String url,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => launchUrl(Uri.parse(url)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withValues(alpha: 0.55)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.star_rounded, size: 13, color: color),
              const SizedBox(width: 3),
              Text(
                '$label ${score.toStringAsFixed(1)}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailLinks(MediaLibraryItem item, ShadColorScheme cs) {
    final links = <(String, String, IconData)>[];
    if (item.tmdbID != null) {
      final kind = item.mediaKind == TMDBMediaKind.tv ? 'tv' : 'movie';
      links.add((
        'TMDB',
        'https://www.themoviedb.org/$kind/${item.tmdbID}',
        Icons.movie_filter_rounded,
      ));
    }
    if (item.doubanID != null) {
      links.add((
        '豆瓣',
        'https://movie.douban.com/subject/${item.doubanID}/',
        Icons.rate_review_rounded,
      ));
    }
    if (item.imdbID != null && item.imdbID!.isNotEmpty) {
      links.add((
        'IMDB',
        'https://www.imdb.com/title/${item.imdbID}/',
        Icons.star_rounded,
      ));
    }
    if (links.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        for (final (label, url, icon) in links)
          ShadButton.outline(
            size: ShadButtonSize.sm,
            onPressed: () => launchUrl(Uri.parse(url)),
            leading: Icon(icon, size: 14),
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
      ],
    );
  }

  Widget _fileInformation(BuildContext context, MediaLibraryItem item) {
    final cs = ShadTheme.of(context).colorScheme;
    final parsed = ParsedMediaName.parse(
      _resource.file.name,
      directoryName: _parentDirectoryName(_resource.file.cloudPath),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '文件与媒体信息',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: cs.foreground,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _metadataPill(context, 'TMDB', item.tmdbID?.toString() ?? '未匹配'),
            if (item.doubanID != null && item.doubanID!.isNotEmpty)
              _metadataPill(context, '豆瓣', item.doubanID!),
            if (item.imdbID != null && item.imdbID!.isNotEmpty)
              _metadataPill(context, 'IMDB', item.imdbID!),
            _metadataPill(context, '资源', '${widget.work.resources.length}'),
            _metadataPill(context, '大小', _resource.file.formattedSize),
            if (parsed.resolution != null)
              _metadataPill(context, '分辨率', parsed.resolution!),
            if (parsed.videoCodec != null)
              _metadataPill(context, '编码', parsed.videoCodec!),
            if (parsed.audio != null)
              _metadataPill(context, '音频', parsed.audio!),
          ],
        ),
        const SizedBox(height: 14),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cs.muted.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _metadataRow(context, '文件', _resource.file.name),
              _metadataRow(context, '文件 ID', _resource.file.id),
              _metadataRow(
                context,
                'GCID',
                _resource.file.gcid?.isNotEmpty == true
                    ? _resource.file.gcid!
                    : '未获取',
              ),
              _metadataRow(context, '云盘位置', _resource.file.cloudPath),
              if (item.doubanID != null && item.doubanID!.isNotEmpty)
                _metadataRow(context, '豆瓣 ID', item.doubanID!),
            ],
          ),
        ),
      ],
    );
  }

  bool get _removalBlocked => widget.removalDisabled || _removingRecords;

  bool get _manualMatchBusy =>
      widget.manualMatchBusyResourceKeys.contains(_mediaRecordKey(_resource));

  bool get _manualMatchLoading => widget.manualMatchLoadingResourceKeys
      .contains(_mediaRecordKey(_resource));

  ParsedMediaName _parsedResource(MediaLibraryItem resource) =>
      ParsedMediaName.parse(
        resource.file.name,
        directoryName: _parentDirectoryName(resource.file.cloudPath),
      );

  List<MediaLibraryItem> _episodeRecords(MediaLibraryItem resource) {
    final parsed = _parsedResource(resource);
    final episode = parsed.episode;
    if (episode == null) return [resource];
    final season = parsed.season ?? 1;
    return widget.work.resources.where((candidate) {
      if (candidate.libraryID != resource.libraryID) return false;
      final candidateParsed = _parsedResource(candidate);
      return (candidateParsed.season ?? 1) == season &&
          candidateParsed.episode == episode;
    }).toList();
  }

  List<MediaLibraryItem> _currentLibraryWorkRecords() => widget.work.resources
      .where((resource) => resource.libraryID == _resource.libraryID)
      .toList();

  MediaLibraryItem? _nextResourceAfterRemoving(Set<String> removedKeys) {
    final ordered = widget.work.resources.toList()
      ..sort((left, right) {
        final leftParsed = _parsedResource(left);
        final rightParsed = _parsedResource(right);
        final season = (leftParsed.season ?? 1).compareTo(
          rightParsed.season ?? 1,
        );
        if (season != 0) return season;
        final episode = (leftParsed.episode ?? 0).compareTo(
          rightParsed.episode ?? 0,
        );
        if (episode != 0) return episode;
        return left.file.name.toLowerCase().compareTo(
          right.file.name.toLowerCase(),
        );
      });
    final currentIndex = ordered.indexWhere(
      (resource) => _mediaRecordKey(resource) == _mediaRecordKey(_resource),
    );
    if (currentIndex < 0) {
      return ordered
          .where((resource) => !removedKeys.contains(_mediaRecordKey(resource)))
          .firstOrNull;
    }
    for (var index = currentIndex + 1; index < ordered.length; index++) {
      if (!removedKeys.contains(_mediaRecordKey(ordered[index]))) {
        return ordered[index];
      }
    }
    for (var index = currentIndex - 1; index >= 0; index--) {
      if (!removedKeys.contains(_mediaRecordKey(ordered[index]))) {
        return ordered[index];
      }
    }
    return null;
  }

  Future<void> _confirmAndRemoveRecords({
    required Iterable<MediaLibraryItem> records,
    required String title,
    required String description,
  }) async {
    if (_removalBlocked) return;
    final unique = <String, MediaLibraryItem>{
      for (final record in records) _mediaRecordKey(record): record,
    }.values.toList();
    if (unique.isEmpty) return;
    _removeMenuController.hide();
    final confirmed = await showShadDialog<bool>(
      context: context,
      builder: (dialogContext) => ShadDialog(
        closeIcon: const SizedBox.shrink(),
        title: Text(title),
        description: Text(description),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          ShadButton.destructive(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            leading: const Icon(LucideIcons.trash2, size: 16),
            child: const Text('移除'),
          ),
        ],
        child: const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('只会移除媒体库记录及相关观看历史，不会删除云盘中的实际文件。后续强制扫描时仍可能重新加入。'),
        ),
      ),
    );
    if (confirmed != true || !mounted || _removalBlocked) return;

    final removedKeys = unique.map(_mediaRecordKey).toSet();
    final removesCurrent = removedKeys.contains(_mediaRecordKey(_resource));
    final nextResource = removesCurrent
        ? _nextResourceAfterRemoving(removedKeys)
        : null;
    setState(() => _removingRecords = true);
    try {
      AppLogger.info(
        'Media',
        '[详情页-移除记录] 确认移除 ${unique.length} 条记录，标题「${widget.work.primary.title}」，媒体库ID=${unique.first.libraryID}',
      );
      for (final r in unique) {
        AppLogger.info(
          'Media',
          '[详情页-移除记录] 待移除：${r.file.name}，路径=${r.file.cloudPath}，ID=${r.id}',
        );
      }
      await widget.onRemoveRecords(unique);
    } finally {
      if (mounted) setState(() => _removingRecords = false);
    }
    if (!mounted || !removesCurrent || nextResource == null) return;
    if (widget.work.primary.mediaKind == TMDBMediaKind.tv) {
      await _selectEpisode(nextResource);
    } else {
      setState(() => _resource = nextResource);
    }
  }

  Future<void> _removeResource(MediaLibraryItem resource) =>
      _confirmAndRemoveRecords(
        records: [resource],
        title: '仅删除当前条目？',
        description: resource.file.name,
      );

  Future<void> _deleteResourceFile(MediaLibraryItem resource) async {
    if (_removalBlocked) return;
    _removeMenuController.hide();
    final confirmed = await showDeleteFilesConfirmDialog(
      context,
      [resource.file],
      title: '删除云盘文件？',
      description: resource.file.name,
      confirmText: '删除文件',
      warning: '将删除云盘中的实际文件，并清理引用该文件的媒体库条目。此操作无法通过重新扫描恢复。',
    );
    if (!confirmed || !mounted || _removalBlocked) return;

    final removedKey = _mediaRecordKey(resource);
    final nextResource = _nextResourceAfterRemoving({removedKey});
    setState(() => _removingRecords = true);
    try {
      AppLogger.info(
        'Media',
        '[详情页-删除文件] 确认删除云盘文件：${resource.file.name}，路径=${resource.file.cloudPath}，ID=${resource.id}，媒体库ID=${resource.libraryID}',
      );
      final deleted = await widget.onDeleteFiles([resource]);
      if (!deleted || !mounted) return;
      if (nextResource == null) return;
      if (widget.work.primary.mediaKind == TMDBMediaKind.tv) {
        await _selectEpisode(nextResource);
      } else {
        setState(() => _resource = nextResource);
      }
    } finally {
      if (mounted) setState(() => _removingRecords = false);
    }
  }

  Future<void> _removeEpisode(MediaLibraryItem resource) {
    final parsed = _parsedResource(resource);
    final records = _episodeRecords(resource);
    final season = parsed.season ?? 1;
    final episode = parsed.episode;
    return _confirmAndRemoveRecords(
      records: records,
      title: episode == null ? '移除当前剧集资源？' : '移除第 $season 季第 $episode 集？',
      description: records.length == 1
          ? records.first.file.name
          : '将移除本集的 ${records.length} 个资源版本。',
    );
  }

  Future<void> _removeCurrentLibraryWork() {
    final isSeries = widget.work.primary.mediaKind == TMDBMediaKind.tv;
    final records = _currentLibraryWorkRecords();
    final episodeCount = records
        .map((resource) {
          final parsed = _parsedResource(resource);
          return '${parsed.season ?? 1}:${parsed.episode ?? resource.id}';
        })
        .toSet()
        .length;
    return _confirmAndRemoveRecords(
      records: records,
      title: '从当前媒体库移除「${widget.work.primary.title}」？',
      description: isSeries
          ? '将移除整部剧集的 $episodeCount 集，共 ${records.length} 个资源记录。'
          : '将移除整部电影的 ${records.length} 个资源版本。',
    );
  }

  Future<void> _refreshCurrentScrape() async {
    if (_refreshScrapeBusy || _pageLoading) return;
    setState(() {
      _refreshScrapeBusy = true;
      _pageLoading = true;
    });
    try {
      widget.onRefreshScrape?.call();
    } finally {
      if (mounted) {
        setState(() {
          _refreshScrapeBusy = false;
          _pageLoading = false;
        });
      }
    }
  }

  Future<void> _refreshDetailWithLoading() async {
    if (_pageLoading) return;
    setState(() => _pageLoading = true);
    try {
      widget.onRefreshDetail.call();
      // 给 onRefreshDetail 的 unawaited 透传留一帧执行时间，下轮 build 会因 _pageLoading 仍 true 保持遮罩，
      // 实际清掉由 _refreshDetailData 完成后父层 setState 触发——这里延时兜底避免卡死。
      await Future<void>.delayed(const Duration(milliseconds: 120));
    } finally {
      if (mounted) setState(() => _pageLoading = false);
    }
  }

  Widget _mediaActions() {
    final manualMatchLoading = _manualMatchLoading;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (!_resource.file.isIso) ...[
          ShadButton(
            size: ShadButtonSize.sm,
            onPressed: () => widget.onPlay(_resource),
            leading: const Icon(Icons.play_arrow_rounded, size: 16),
            child: const Text('播放'),
          ),
          ShadButton.outline(
            size: ShadButtonSize.sm,
            onPressed: () => widget.onExternalPlay(_resource),
            leading: const Icon(Icons.launch_rounded, size: 16),
            child: const Text('外部播放'),
          ),
        ],
        ShadButton.outline(
          size: ShadButtonSize.sm,
          onPressed: () => widget.onDownload(_resource),
          leading: const Icon(Icons.download_rounded, size: 16),
          child: const Text('下载'),
        ),
        ShadButton.outline(
          size: ShadButtonSize.sm,
          onPressed: widget.recognizing ? null : widget.onRecognize,
          leading: widget.recognizing
              ? const AppLoadingIndicator(
                  size: AppLoadingSize.inline,
                  semanticsLabel: '正在识别媒体信息',
                )
              : const Icon(Icons.auto_awesome_rounded, size: 16),
          child: const Text('媒体识别'),
        ),
        ShadButton.outline(
          size: ShadButtonSize.sm,
          onPressed: _manualMatchBusy
              ? null
              : () => widget.onManualMatch(_resource),
          leading: manualMatchLoading
              ? const AppLoadingIndicator(
                  size: AppLoadingSize.inline,
                  semanticsLabel: '正在准备手动匹配',
                )
              : const Icon(Icons.manage_search_rounded, size: 16),
          child: Text(manualMatchLoading ? '正在匹配' : '手动匹配'),
        ),
        ShadButton.outline(
          size: ShadButtonSize.sm,
          onPressed: _pageLoading ? null : _refreshDetailWithLoading,
          leading: const Icon(Icons.refresh_rounded, size: 16),
          child: const Text('刷新'),
        ),
        if (widget.onRefreshScrape != null)
          ShadButton.outline(
            size: ShadButtonSize.sm,
            onPressed: _refreshScrapeBusy ? null : _refreshCurrentScrape,
            leading: _refreshScrapeBusy
                ? const AppLoadingIndicator(
                    size: AppLoadingSize.inline,
                    semanticsLabel: '正在刷新刮削数据',
                  )
                : const Icon(Icons.sync_rounded, size: 16),
            child: Text(_refreshScrapeBusy ? '正在刷新' : '刷新刮削'),
          ),
        _removeActionsPopover(),
      ],
    );
  }

  Widget _episodeVersionSwitcher(ShadColorScheme cs) {
    final episodeResources = _episodeRecords(_resource);
    if (episodeResources.length <= 1) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '资源版本 (${episodeResources.length})',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: cs.mutedForeground,
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final r in episodeResources)
              ShadButton.outline(
                size: ShadButtonSize.sm,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                backgroundColor: r.id == _resource.id ? cs.primary : null,
                foregroundColor: r.id == _resource.id
                    ? cs.primaryForeground
                    : null,
                onPressed: () => unawaited(_selectEpisode(r)),
                child: Text(
                  r.file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: r.id == _resource.id
                        ? cs.primaryForeground
                        : cs.foreground,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _removeActionsPopover() {
    final cs = ShadTheme.of(context).colorScheme;
    final isSeries = widget.work.primary.mediaKind == TMDBMediaKind.tv;
    final parsed = _parsedResource(_resource);
    final episodeRecords = isSeries ? _episodeRecords(_resource) : const [];
    final libraryRecords = _currentLibraryWorkRecords();
    return ShadPopover(
      controller: _removeMenuController,
      popover: (_) => RemoteFocusMenu(
        child: SizedBox(
          width: 292,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: (MediaQuery.sizeOf(context).height - 96).clamp(
                260.0,
                520.0,
              ),
            ),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 7),
                      child: Text(
                        '资源操作',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: cs.mutedForeground,
                        ),
                      ),
                    ),
                    _removalMenuItem(
                      icon: LucideIcons.folderInput,
                      title: '移动到其他媒体库',
                      description: '选择移动层级和目标媒体目录',
                      destructive: false,
                      onPressed: () => widget.onMoveMediaResource(_resource),
                    ),
                    if (widget.work.resources.any(
                          (item) => item.tmdbID != null,
                        ) ||
                        widget.work.resources.any(
                          (item) => item.doubanID?.trim().isNotEmpty == true,
                        )) ...[
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 5),
                        child: ShadSeparator.horizontal(),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 5),
                        child: Text(
                          '清理刮削信息',
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.mutedForeground,
                          ),
                        ),
                      ),
                    ],
                    if (widget.work.resources.any(
                      (item) => item.tmdbID != null,
                    )) ...[
                      const SizedBox(height: 3),
                      _removalMenuItem(
                        icon: LucideIcons.unlink,
                        title: '清理 TMDB 信息',
                        description: '保留豆瓣信息（如有）',
                        onPressed: () =>
                            widget.onClearMetadata(_MediaMetadataSource.tmdb),
                      ),
                    ],
                    if (widget.work.resources.any(
                      (item) => item.doubanID?.trim().isNotEmpty == true,
                    )) ...[
                      const SizedBox(height: 3),
                      _removalMenuItem(
                        icon: LucideIcons.unlink,
                        title: '清理豆瓣信息',
                        description: '保留 TMDB 信息（如有）',
                        onPressed: () =>
                            widget.onClearMetadata(_MediaMetadataSource.douban),
                      ),
                    ],
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 5),
                      child: ShadSeparator.horizontal(),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 5),
                      child: Text(
                        '删除',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.mutedForeground,
                        ),
                      ),
                    ),
                    _removalMenuItem(
                      icon: LucideIcons.fileX,
                      title: '仅删除条目（默认）',
                      description: '保留云盘文件，强制扫描后可重新加入',
                      onPressed: () => _removeResource(_resource),
                    ),
                    const SizedBox(height: 3),
                    _removalMenuItem(
                      icon: LucideIcons.trash2,
                      title: '删除文件',
                      description: '同时清理媒体库条目',
                      onPressed: () => _deleteResourceFile(_resource),
                    ),
                    if (isSeries && parsed.episode != null) ...[
                      const SizedBox(height: 3),
                      _removalMenuItem(
                        icon: LucideIcons.listX,
                        title:
                            '移除第 ${parsed.season ?? 1} 季第 ${parsed.episode} 集',
                        description: episodeRecords.length > 1
                            ? '包含 ${episodeRecords.length} 个资源版本'
                            : '移除当前单集记录',
                        onPressed: () => _removeEpisode(_resource),
                      ),
                    ],
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 5),
                      child: ShadSeparator.horizontal(),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 5),
                      child: Text(
                        '批量删除条目',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.mutedForeground,
                        ),
                      ),
                    ),
                    _removalMenuItem(
                      icon: LucideIcons.trash2,
                      title: isSeries ? '移除当前媒体库内整部剧集' : '移除当前媒体库内整部电影',
                      description: isSeries
                          ? '${libraryRecords.length} 个资源记录'
                          : '${libraryRecords.length} 个资源版本',
                      onPressed: _removeCurrentLibraryWork,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      child: ShadTooltip(
        builder: (_) => const Text('更多媒体操作'),
        child: ShadButton.outline(
          size: ShadButtonSize.sm,
          onPressed: _removalBlocked ? null : _removeMenuController.toggle,
          leading: _removingRecords
              ? const AppLoadingIndicator(
                  size: AppLoadingSize.inline,
                  semanticsLabel: '正在移除媒体库记录',
                )
              : const Icon(Icons.more_horiz_rounded, size: 16),
          child: Text(_removingRecords ? '正在移除' : '更多'),
        ),
      ),
    );
  }

  Widget _removalMenuItem({
    required IconData icon,
    required String title,
    required String description,
    required Future<void> Function() onPressed,
    bool destructive = true,
  }) {
    final cs = ShadTheme.of(context).colorScheme;
    final color = destructive ? cs.destructive : cs.foreground;
    return ShadButton.ghost(
      width: double.infinity,
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      mainAxisAlignment: MainAxisAlignment.start,
      leading: Icon(icon, size: 17, color: color),
      onPressed: _removalBlocked
          ? null
          : () {
              _removeMenuController.hide();
              unawaited(onPressed());
            },
      child: SizedBox(
        width: 226,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: cs.mutedForeground),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metadataPill(BuildContext context, String label, String value) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: cs.muted.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label ',
            style: TextStyle(fontSize: 12, color: cs.mutedForeground),
          ),
          SelectableText(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: cs.foreground,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tmdbEnrichment(
    BuildContext context, {
    bool showPosters = true,
    bool showCast = true,
  }) {
    final cs = ShadTheme.of(context).colorScheme;
    if (_loadingTMDBDetails && _tmdbDetails == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Align(
          alignment: Alignment.centerLeft,
          child: AppLoadingIndicator(
            size: AppLoadingSize.compact,
            label: '正在加载影视资料',
          ),
        ),
      );
    }
    final details = _tmdbDetails;
    if (details == null) return const SizedBox.shrink();
    final images = details['images'] is Map
        ? Map<String, dynamic>.from(details['images'] as Map)
        : const <String, dynamic>{};
    final posters = _imagePaths(images['posters']);
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
    if ((!showPosters || posters.isEmpty) && (!showCast || cast.isEmpty)) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showPosters && posters.isNotEmpty) ...[
          Text(
            '更多海报',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: cs.foreground,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 180,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: posters.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) => Container(
                width: 120,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CachedNetworkImage(
                    imageUrl: _tmdbImageURL(posters[index], size: 'w342'),
                    width: 120,
                    height: 180,
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) => _tmdbDirectFallback(
                      path: posters[index],
                      size: 'w342',
                      width: 120,
                      height: 180,
                      fallback: Container(
                        width: 120,
                        height: 180,
                        color: cs.muted,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 22),
        ],
        if (showCast && cast.isNotEmpty) ...[
          Text(
            '演职员',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: cs.foreground,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 200,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: cast.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final person = cast[index];
                final profile = person['profile_path']?.toString();
                final name = person['name']?.toString() ?? '';
                final character = person['character']?.toString() ?? '';
                return SizedBox(
                  width: 100,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: profile == null || profile.isEmpty
                            ? Container(
                                width: 100,
                                height: 130,
                                decoration: BoxDecoration(
                                  color: cs.muted,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  Icons.person_rounded,
                                  color: cs.mutedForeground,
                                  size: 32,
                                ),
                              )
                            : CachedNetworkImage(
                                imageUrl: _tmdbImageURL(profile, size: 'w185'),
                                width: 100,
                                height: 130,
                                fit: BoxFit.cover,
                                errorWidget: (_, _, _) => _tmdbDirectFallback(
                                  path: profile,
                                  size: 'w185',
                                  width: 100,
                                  height: 130,
                                  fallback: Container(
                                    width: 100,
                                    height: 130,
                                    color: cs.muted,
                                  ),
                                ),
                              ),
                      ),
                      const SizedBox(height: 6),
                      if (name.isNotEmpty)
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: cs.foreground,
                          ),
                        ),
                      if (character.isNotEmpty) ...[
                        const SizedBox(height: 1),
                        Text(
                          character,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: cs.mutedForeground,
                          ),
                        ),
                      ],
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
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 58,
            child: Text(
              label,
              style: TextStyle(fontSize: 11.5, color: cs.mutedForeground),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(fontSize: 11.5, color: cs.foreground),
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
        final parsed = ParsedMediaName.parse(
          resource.file.name,
          directoryName: _parentDirectoryName(resource.file.cloudPath),
        );
        (episodesBySeason[parsed.season ?? 1] ??= []).add(resource);
      }
      for (final values in episodesBySeason.values) {
        values.sort((a, b) {
          final aEpisode =
              ParsedMediaName.parse(
                a.file.name,
                directoryName: _parentDirectoryName(a.file.cloudPath),
              ).episode ??
              9999;
          final bEpisode =
              ParsedMediaName.parse(
                b.file.name,
                directoryName: _parentDirectoryName(b.file.cloudPath),
              ).episode ??
              9999;
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
              ? '剧集 (${_episodeCount(widget.work.resources)} 集)'
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
        if (isSeries && episodesBySeason.isNotEmpty) ...[
          _seasonPicker(episodesBySeason, cs),
          const SizedBox(height: 10),
          _episodePicker(
            episodesBySeason[_activeSeason(episodesBySeason)]!,
            cs,
          ),
          _episodeIntroduction(context, cs),
        ] else
          ...widget.work.resources.map(
            (resource) => _resourceTile(resource, cs),
          ),
      ],
    );
  }

  int _activeSeason(Map<int, List<MediaLibraryItem>> episodesBySeason) {
    if (_selectedSeason != null &&
        episodesBySeason.containsKey(_selectedSeason)) {
      return _selectedSeason!;
    }
    return episodesBySeason.keys.reduce((a, b) => a < b ? a : b);
  }

  int _episodeCount(List<MediaLibraryItem> episodes) {
    final seen = <int?>{};
    for (final r in episodes) {
      final parsed = ParsedMediaName.parse(
        r.file.name,
        directoryName: _parentDirectoryName(r.file.cloudPath),
      );
      seen.add(parsed.episode);
    }
    return seen.length;
  }

  Widget _seasonPicker(
    Map<int, List<MediaLibraryItem>> episodesBySeason,
    ShadColorScheme cs,
  ) {
    final selectedSeason = _activeSeason(episodesBySeason);
    final seasons = episodesBySeason.keys.toList()..sort();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final season in seasons)
            Padding(
              padding: EdgeInsets.only(right: season == seasons.last ? 0 : 8),
              child: ShadButton.outline(
                size: ShadButtonSize.sm,
                onPressed: () => setState(() {
                  _selectedSeason = season;
                  _selectedEpisodeID = null;
                  _episodeDetails = null;
                }),
                backgroundColor: season == selectedSeason ? cs.primary : null,
                foregroundColor: season == selectedSeason
                    ? cs.primaryForeground
                    : null,
                child: Text(
                  '第 $season 季 · ${_episodeCount(episodesBySeason[season]!)} 集',
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _episodePicker(List<MediaLibraryItem> episodes, ShadColorScheme cs) {
    final grouped = <int?, List<MediaLibraryItem>>{};
    for (final resource in episodes) {
      final parsed = ParsedMediaName.parse(
        resource.file.name,
        directoryName: _parentDirectoryName(resource.file.cloudPath),
      );
      (grouped[parsed.episode] ??= []).add(resource);
    }
    final entries = grouped.entries.toList()
      ..sort((a, b) => (a.key ?? 9999).compareTo(b.key ?? 9999));
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final entry in entries)
          Builder(
            builder: (context) {
              final episode = entry.key;
              final resources = entry.value;
              final multi = resources.length > 1;
              final selected = resources.any((r) => r.id == _selectedEpisodeID);
              final label = episode == null
                  ? '未编号'
                  : 'E${episode.toString().padLeft(2, '0')}';
              final current = resources.firstWhere(
                (r) => r.id == _selectedEpisodeID,
                orElse: () => resources.first,
              );
              return ShadContextMenuRegion(
                tapEnabled: false,
                items: [
                  if (multi)
                    for (final resource in resources)
                      ShadContextMenuItem.inset(
                        leading: Icon(
                          resource.id == _selectedEpisodeID
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          size: 16,
                          color: cs.foreground,
                        ),
                        onPressed: () => unawaited(_selectEpisode(resource)),
                        child: Text(
                          resource.file.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  if (multi) const Divider(),
                  ShadContextMenuItem.inset(
                    leading: Icon(
                      LucideIcons.trash2,
                      size: 16,
                      color: cs.destructive,
                    ),
                    onPressed: _removalBlocked
                        ? null
                        : () => unawaited(_removeEpisode(current)),
                    child: Text(
                      episode == null ? '移除当前剧集资源' : '移除本集',
                      style: TextStyle(color: cs.destructive),
                    ),
                  ),
                ],
                child: ShadTooltip(
                  builder: (_) {
                    if (!multi) {
                      return Text(episode == null ? '未识别集号' : '第 $episode 集');
                    }
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('第 $episode 集 · ${resources.length} 个版本'),
                        for (final r in resources)
                          Text(
                            '· ${r.file.name}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                      ],
                    );
                  },
                  child: ShadButton.outline(
                    size: ShadButtonSize.sm,
                    width: 58,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    backgroundColor: selected ? cs.primary : null,
                    foregroundColor: selected ? cs.primaryForeground : null,
                    onPressed: () => unawaited(_selectEpisode(resources.first)),
                    child: SizedBox(
                      width: 50,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(label, maxLines: 1),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _episodeIntroduction(BuildContext context, ShadColorScheme cs) {
    final selected = _selectedEpisodeID == _resource.id;
    if (!selected) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          '选择一集查看当前集介绍',
          style: TextStyle(fontSize: 12, color: cs.mutedForeground),
        ),
      );
    }
    if (_loadingEpisodeDetails) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: AppLoadingIndicator(
          size: AppLoadingSize.compact,
          label: '正在加载剧集资料',
        ),
      );
    }
    final parsed = ParsedMediaName.parse(
      _resource.file.name,
      directoryName: _parentDirectoryName(_resource.file.cloudPath),
    );
    final details = _episodeDetails;
    final title = details?['name']?.toString().trim();
    final overview = details?['overview']?.toString().trim();
    final airDate = details?['air_date']?.toString().trim();
    final runtime = details?['runtime'];
    final stillPath = details?['still_path']?.toString();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.muted.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: cs.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (stillPath?.isNotEmpty == true)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: CachedNetworkImage(
                imageUrl: _tmdbImageURL(stillPath!, size: 'w300'),
                width: 128,
                height: 72,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => _tmdbDirectFallback(
                  path: stillPath,
                  size: 'w300',
                  width: 128,
                  height: 72,
                  fallback: Container(color: cs.card),
                ),
              ),
            ),
          if (stillPath?.isNotEmpty == true) const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText(
                            title?.isNotEmpty == true
                                ? title!
                                : '第 ${parsed.episode?.toString() ?? '-'} 集',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: cs.foreground,
                            ),
                          ),
                          if (airDate?.isNotEmpty == true ||
                              runtime != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              [
                                if (airDate?.isNotEmpty == true) airDate!,
                                if (runtime != null) '$runtime 分钟',
                              ].join(' · '),
                              style: TextStyle(
                                fontSize: 11,
                                color: cs.mutedForeground,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (!_resource.file.isIso) ...[
                      const SizedBox(width: 12),
                      ShadButton.ghost(
                        size: ShadButtonSize.sm,
                        onPressed: () => widget.onPlay(_resource),
                        leading: const Icon(Icons.play_arrow_rounded, size: 16),
                        child: const Text('播放'),
                      ),
                    ],
                  ],
                ),
                if (overview?.isNotEmpty == true) ...[
                  const SizedBox(height: 6),
                  SelectableText(
                    overview!,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.45,
                      color: cs.foreground,
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 6),
                  Text(
                    '暂无本集简介',
                    style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                  ),
                ],
                if (widget.work.resources.length > 1 &&
                    widget.work.primary.mediaKind == TMDBMediaKind.tv) ...[
                  const SizedBox(height: 10),
                  _episodeVersionSwitcher(cs),
                ],
              ],
            ),
          ),
        ],
      ),
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
        tapEnabled: false,
        items: [
          if (!resource.file.isIso) ...[
            ShadContextMenuItem.inset(
              leading: const Icon(LucideIcons.play, size: 16),
              onPressed: () => widget.onPlay(resource),
              child: const Text('播放'),
            ),
            ShadContextMenuItem.inset(
              leading: const Icon(LucideIcons.monitorPlay, size: 16),
              onPressed: () => widget.onExternalPlay(resource),
              child: const Text('外部播放'),
            ),
          ],
          ShadContextMenuItem.inset(
            leading: const Icon(LucideIcons.download, size: 16),
            onPressed: () => widget.onDownload(resource),
            child: const Text('下载'),
          ),
          const Divider(height: 8),
          ShadContextMenuItem.inset(
            leading: const Icon(LucideIcons.filePenLine, size: 16),
            onPressed: () => unawaited(widget.onRenameFile(resource)),
            child: const Text('重命名'),
          ),
          ShadContextMenuItem.inset(
            leading: const Icon(LucideIcons.folderInput, size: 16),
            onPressed: () => unawaited(widget.onMoveCloudFile(resource)),
            child: const Text('移动到…'),
          ),
          const Divider(height: 8),
          ShadContextMenuItem.inset(
            leading: Icon(LucideIcons.trash2, size: 16, color: cs.destructive),
            onPressed: _removalBlocked
                ? null
                : () => unawaited(_removeResource(resource)),
            child: Text('从媒体库移除此资源', style: TextStyle(color: cs.destructive)),
          ),
        ],
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _selectEpisode(resource),
            borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: selected ? cs.primary.withValues(alpha: 0.08) : cs.card,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected
                      ? cs.primary.withValues(alpha: 0.8)
                      : cs.border,
                  width: selected ? 1.4 : 1,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Leading: episode badge for series, file-type icon otherwise.
                  if (episode != null)
                    Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected
                            ? cs.primary
                            : cs.primary.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        episode.toString().padLeft(2, '0'),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: selected ? cs.primaryForeground : cs.primary,
                        ),
                      ),
                    )
                  else
                    Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: cs.muted,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Icon(
                        resource.file.isIso
                            ? LucideIcons.disc
                            : LucideIcons.clapperboard,
                        size: 18,
                        color: cs.mutedForeground,
                      ),
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          resource.file.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: cs.foreground,
                          ),
                        ),
                        const SizedBox(height: 6),
                        _resourceTags(resource, cs),
                      ],
                    ),
                  ),
                  if (selected) ...[
                    const SizedBox(width: 8),
                    Icon(
                      Icons.check_circle_rounded,
                      size: 18,
                      color: cs.primary,
                    ),
                  ],
                  const SizedBox(width: 8),
                  if (!resource.file.isIso)
                    ShadButton(
                      size: ShadButtonSize.sm,
                      onPressed: () => widget.onPlay(resource),
                      leading: const Icon(Icons.play_arrow_rounded, size: 16),
                      child: const Text('播放'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Compact tag row for a resource: size + technical spec (resolution, codec,
  /// HDR, audio) + Chinese audio/subtitle flags. Helps distinguish multiple
  /// versions of the same title at a glance.
  Widget _resourceTags(MediaLibraryItem resource, ShadColorScheme cs) {
    final parsed = ParsedMediaName.parse(
      resource.file.name,
      directoryName: _parentDirectoryName(resource.file.cloudPath),
    );
    final specs = <String>[
      if (parsed.resolution?.isNotEmpty == true) parsed.resolution!,
      if (parsed.dynamicRange?.isNotEmpty == true) parsed.dynamicRange!,
      if (parsed.videoCodec?.isNotEmpty == true) parsed.videoCodec!,
      if (parsed.audio?.isNotEmpty == true) parsed.audio!,
    ];
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _resourceChip(resource.file.formattedSize, cs, muted: true),
        for (final spec in specs) _resourceChip(spec, cs),
        if (resource.hasChineseAudio) _resourceChip('中文音轨', cs, accent: true),
        if (resource.hasChineseSubtitle)
          _resourceChip('中文字幕', cs, accent: true),
        if (resource.file.modifiedAt.isNotEmpty)
          _resourceChip(resource.file.modifiedAt, cs, muted: true),
      ],
    );
  }

  Widget _resourceChip(
    String label,
    ShadColorScheme cs, {
    bool muted = false,
    bool accent = false,
  }) {
    final Color bg;
    final Color fg;
    if (accent) {
      bg = cs.primary.withValues(alpha: 0.12);
      fg = cs.primary;
    } else if (muted) {
      bg = Colors.transparent;
      fg = cs.mutedForeground;
    } else {
      bg = cs.muted;
      fg = cs.foreground;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
        border: muted
            ? null
            : Border.all(color: cs.border.withValues(alpha: 0.6)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: accent ? FontWeight.w600 : FontWeight.w500,
          color: fg,
        ),
      ),
    );
  }
}
