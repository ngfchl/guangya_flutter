import 'cloud_file.dart';

enum TMDBMediaKind { automatic, movie, tv }

extension TMDBMediaKindX on TMDBMediaKind {
  String get title {
    switch (this) {
      case TMDBMediaKind.automatic:
        return '自动识别';
      case TMDBMediaKind.movie:
        return '电影';
      case TMDBMediaKind.tv:
        return '剧集';
    }
  }
}

class MediaCategoryRule {
  final String id;
  final String name;
  final TMDBMediaKind mediaKind;
  final List<String> languages;
  final bool isFallback;

  const MediaCategoryRule({
    required this.id,
    required this.name,
    required this.mediaKind,
    this.languages = const [],
    this.isFallback = false,
  });

  MediaCategoryRule copyWith({
    String? name,
    TMDBMediaKind? mediaKind,
    List<String>? languages,
    bool? isFallback,
  }) {
    return MediaCategoryRule(
      id: id,
      name: name ?? this.name,
      mediaKind: mediaKind ?? this.mediaKind,
      languages: languages ?? this.languages,
      isFallback: isFallback ?? this.isFallback,
    );
  }

  factory MediaCategoryRule.fromJson(Map<String, dynamic> json) {
    return MediaCategoryRule(
      id:
          json['id']?.toString() ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: json['name']?.toString() ?? '未命名分类',
      mediaKind: TMDBMediaKind.values.firstWhere(
        (kind) => kind.name == json['mediaKind']?.toString(),
        orElse: () => TMDBMediaKind.movie,
      ),
      languages:
          (json['languages'] as List?)
              ?.map((value) => value.toString().trim())
              .where((value) => value.isNotEmpty)
              .toList() ??
          const [],
      isFallback: json['isFallback'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'mediaKind': mediaKind.name,
    'languages': languages,
    'isFallback': isFallback,
  };

  static List<MediaCategoryRule> presets() => const [
    MediaCategoryRule(
      id: 'preset-movie-cn',
      name: '国产电影',
      mediaKind: TMDBMediaKind.movie,
      languages: ['zh', 'cn', 'yue'],
    ),
    MediaCategoryRule(
      id: 'preset-movie-jpkr',
      name: '日韩电影',
      mediaKind: TMDBMediaKind.movie,
      languages: ['ja', 'ko', 'th'],
    ),
    MediaCategoryRule(
      id: 'preset-movie-west',
      name: '欧美电影',
      mediaKind: TMDBMediaKind.movie,
      languages: ['en'],
    ),
    MediaCategoryRule(
      id: 'preset-movie-other',
      name: '其他电影',
      mediaKind: TMDBMediaKind.movie,
      isFallback: true,
    ),
    MediaCategoryRule(
      id: 'preset-tv-cn',
      name: '国产剧集',
      mediaKind: TMDBMediaKind.tv,
      languages: ['zh', 'cn', 'yue'],
    ),
    MediaCategoryRule(
      id: 'preset-tv-jpkr',
      name: '日韩剧集',
      mediaKind: TMDBMediaKind.tv,
      languages: ['ja', 'ko', 'th'],
    ),
    MediaCategoryRule(
      id: 'preset-tv-west',
      name: '欧美剧集',
      mediaKind: TMDBMediaKind.tv,
      languages: ['en'],
    ),
    MediaCategoryRule(
      id: 'preset-tv-other',
      name: '其他剧集',
      mediaKind: TMDBMediaKind.tv,
      isFallback: true,
    ),
  ];
}

enum MediaLibraryKind { movies, series, mixed }

extension MediaLibraryKindX on MediaLibraryKind {
  String get title {
    switch (this) {
      case MediaLibraryKind.movies:
        return '电影';
      case MediaLibraryKind.series:
        return '电视剧';
      case MediaLibraryKind.mixed:
        return '混合内容';
    }
  }
}

class MediaLibrarySource {
  final String id;
  final String? rootID;
  final String path;

  const MediaLibrarySource({
    required this.id,
    required this.rootID,
    required this.path,
  });

  factory MediaLibrarySource.fromJson(Map<String, dynamic> json) {
    return MediaLibrarySource(
      id:
          json['id']?.toString() ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      rootID: json['rootID']?.toString(),
      path: json['path']?.toString() ?? '未配置目录',
    );
  }

  Map<String, dynamic> toJson() => {'id': id, 'rootID': rootID, 'path': path};
}

class MediaLibraryDefinition {
  final String id;
  final String name;
  final List<MediaLibrarySource> sources;
  final MediaLibraryKind kind;
  final bool recursive;
  final int minimumSizeMB;
  final DateTime? updatedAt;

  const MediaLibraryDefinition({
    required this.id,
    required this.name,
    required this.sources,
    this.kind = MediaLibraryKind.mixed,
    this.recursive = true,
    this.minimumSizeMB = 50,
    this.updatedAt,
  });

  String? get rootID => sources.isEmpty ? null : sources.first.rootID;

  String get rootPath {
    if (sources.length == 1) return sources.first.path;
    if (sources.isEmpty) return '未配置目录';
    return '${sources.length} 个媒体目录';
  }

  MediaLibraryDefinition copyWith({
    String? name,
    List<MediaLibrarySource>? sources,
    MediaLibraryKind? kind,
    bool? recursive,
    int? minimumSizeMB,
    DateTime? updatedAt,
  }) {
    return MediaLibraryDefinition(
      id: id,
      name: name ?? this.name,
      sources: sources ?? this.sources,
      kind: kind ?? this.kind,
      recursive: recursive ?? this.recursive,
      minimumSizeMB: minimumSizeMB ?? this.minimumSizeMB,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory MediaLibraryDefinition.fromJson(Map<String, dynamic> json) {
    final rawSources = json['sources'];
    final sources = rawSources is List
        ? rawSources
              .whereType<Map>()
              .map(
                (item) => MediaLibrarySource.fromJson(
                  Map<String, dynamic>.from(item),
                ),
              )
              .toList()
        : [
            MediaLibrarySource(
              id: '${json['id'] ?? DateTime.now().microsecondsSinceEpoch}-legacy',
              rootID: json['rootID']?.toString(),
              path: json['rootPath']?.toString() ?? '未配置目录',
            ),
          ];
    return MediaLibraryDefinition(
      id:
          json['id']?.toString() ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: json['name']?.toString() ?? '未命名媒体库',
      sources: sources,
      kind: MediaLibraryKind.values.firstWhere(
        (kind) => kind.name == json['kind']?.toString(),
        orElse: () => MediaLibraryKind.mixed,
      ),
      recursive: json['recursive'] != false,
      minimumSizeMB: _toInt(json['minimumSizeMB']) ?? 50,
      updatedAt: _parseDate(json['updatedAt']),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'sources': sources.map((source) => source.toJson()).toList(),
    'kind': kind.name,
    'recursive': recursive,
    'minimumSizeMB': minimumSizeMB,
    'updatedAt': updatedAt?.toIso8601String(),
  };
}

class MediaLibraryItem {
  final String libraryID;
  final CloudFile file;
  final int? tmdbID;
  final String title;
  final String originalTitle;
  final TMDBMediaKind? mediaKind;
  final String releaseDate;
  final String overview;
  final String? posterPath;
  final String? backdropPath;
  final bool hasChineseAudio;
  final bool hasChineseSubtitle;
  final int? collectionID;
  final String? collectionName;
  final DateTime updatedAt;

  const MediaLibraryItem({
    required this.libraryID,
    required this.file,
    this.tmdbID,
    required this.title,
    required this.originalTitle,
    this.mediaKind,
    this.releaseDate = '',
    this.overview = '',
    this.posterPath,
    this.backdropPath,
    this.hasChineseAudio = false,
    this.hasChineseSubtitle = false,
    this.collectionID,
    this.collectionName,
    required this.updatedAt,
  });

  String get id => file.id;
  String get year => releaseDate.length >= 4 ? releaseDate.substring(0, 4) : '';
  bool get isMatched => mediaKind != null && tmdbID != null;

  MediaLibraryItem copyWith({
    CloudFile? file,
    int? tmdbID,
    bool clearTMDBID = false,
    String? title,
    String? originalTitle,
    TMDBMediaKind? mediaKind,
    bool clearMediaKind = false,
    String? releaseDate,
    String? overview,
    String? posterPath,
    String? backdropPath,
    bool? hasChineseAudio,
    bool? hasChineseSubtitle,
    int? collectionID,
    String? collectionName,
    DateTime? updatedAt,
  }) {
    return MediaLibraryItem(
      libraryID: libraryID,
      file: file ?? this.file,
      tmdbID: clearTMDBID ? null : (tmdbID ?? this.tmdbID),
      title: title ?? this.title,
      originalTitle: originalTitle ?? this.originalTitle,
      mediaKind: clearMediaKind ? null : (mediaKind ?? this.mediaKind),
      releaseDate: releaseDate ?? this.releaseDate,
      overview: overview ?? this.overview,
      posterPath: posterPath ?? this.posterPath,
      backdropPath: backdropPath ?? this.backdropPath,
      hasChineseAudio: hasChineseAudio ?? this.hasChineseAudio,
      hasChineseSubtitle: hasChineseSubtitle ?? this.hasChineseSubtitle,
      collectionID: collectionID ?? this.collectionID,
      collectionName: collectionName ?? this.collectionName,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory MediaLibraryItem.fromFile(
    String libraryID,
    CloudFile file, {
    String? directoryName,
  }) {
    final parsed = ParsedMediaName.parse(
      file.name,
      directoryName: directoryName,
      directoryPath: file.cloudPath,
    );
    // A season pack may not carry an individual episode number. It is still
    // a TV resource and must use the TV TMDB endpoint rather than movie.
    final kind = parsed.isEpisode || parsed.season != null
        ? TMDBMediaKind.tv
        : TMDBMediaKind.movie;
    return MediaLibraryItem(
      libraryID: libraryID,
      file: file,
      title: parsed.title,
      originalTitle: parsed.title,
      mediaKind: kind,
      releaseDate: parsed.year == null ? '' : '${parsed.year}-01-01',
      updatedAt: DateTime.now(),
    );
  }

  factory MediaLibraryItem.fromJson(Map<String, dynamic> json) {
    return MediaLibraryItem(
      libraryID: json['libraryID']?.toString() ?? '',
      file: CloudFile(
        id: json['fileID']?.toString() ?? '',
        name: json['cloudName']?.toString() ?? '',
        isDirectory: false,
        size: _toInt(json['fileSize']),
        gcid: json['gcid']?.toString(),
        modifiedAt: json['modifiedAt']?.toString() ?? '',
        cloudPath: json['resourcePath']?.toString() ?? '',
        parentID: json['parentID']?.toString(),
        fullParentIDs: json['fullParentIDs']?.toString(),
        fileType: _toInt(json['fileType']) ?? 2,
      ),
      tmdbID: _toInt(json['tmdbID']),
      title: json['title']?.toString() ?? '',
      originalTitle: json['originalTitle']?.toString() ?? '',
      mediaKind: TMDBMediaKind.values
          .where((kind) => kind.name == json['mediaKind'])
          .firstOrNull,
      releaseDate: json['releaseDate']?.toString() ?? '',
      overview: json['overview']?.toString() ?? '',
      posterPath: json['posterPath']?.toString(),
      backdropPath: json['backdropPath']?.toString(),
      hasChineseAudio: json['hasChineseAudio'] == true,
      hasChineseSubtitle: json['hasChineseSubtitle'] == true,
      collectionID: _toInt(json['collectionID']),
      collectionName: json['collectionName']?.toString(),
      updatedAt: _parseDate(json['updatedAt']) ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'libraryID': libraryID,
    'fileID': file.id,
    'resourcePath': file.cloudPath,
    'cloudName': file.name,
    'fileSize': file.size,
    'gcid': file.gcid,
    'fileType': file.fileType,
    'modifiedAt': file.modifiedAt,
    'parentID': file.parentID,
    'fullParentIDs': file.fullParentIDs,
    'tmdbID': tmdbID,
    'mediaKind': mediaKind?.name,
    'title': title,
    'originalTitle': originalTitle,
    'releaseDate': releaseDate,
    'overview': overview,
    'posterPath': posterPath,
    'backdropPath': backdropPath,
    'hasChineseAudio': hasChineseAudio,
    'hasChineseSubtitle': hasChineseSubtitle,
    'collectionID': collectionID,
    'collectionName': collectionName,
    'updatedAt': updatedAt.toIso8601String(),
  };
}

class MediaLibraryStatistics {
  final int total;
  final int movies;
  final int series;
  final int unmatched;
  final int collections;

  const MediaLibraryStatistics({
    this.total = 0,
    this.movies = 0,
    this.series = 0,
    this.unmatched = 0,
    this.collections = 0,
  });

  factory MediaLibraryStatistics.fromItems(Iterable<MediaLibraryItem> items) {
    final workGroups = <String, List<MediaLibraryItem>>{};
    final unmatchedGroups = <String>{};
    final collections = <String>{};
    for (final item in items) {
      final workKey = _statisticsWorkKey(item);
      workGroups.putIfAbsent(workKey, () => []).add(item);
      if (!item.isMatched) unmatchedGroups.add(workKey);
      final collectionKey =
          item.collectionID?.toString() ?? item.collectionName;
      if (collectionKey != null && collectionKey.isNotEmpty) {
        collections.add(collectionKey);
      }
    }

    var movies = 0;
    var series = 0;
    for (final group in workGroups.values) {
      final kind = group
          .map((item) => item.mediaKind)
          .where(
            (kind) => kind == TMDBMediaKind.movie || kind == TMDBMediaKind.tv,
          )
          .firstOrNull;
      if (kind == TMDBMediaKind.movie) {
        movies++;
      } else if (kind == TMDBMediaKind.tv) {
        series++;
      }
    }
    return MediaLibraryStatistics(
      total: workGroups.length,
      movies: movies,
      series: series,
      unmatched: unmatchedGroups.length,
      collections: collections.length,
    );
  }

  static String _statisticsWorkKey(MediaLibraryItem item) {
    final title = item.title.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9\u4e00-\u9fff]'),
      '',
    );
    final kind = item.mediaKind?.name ?? 'unknown';
    return item.tmdbID == null
        ? '$kind:$title:${item.year}'
        : '$kind:tmdb:${item.tmdbID}';
  }
}

class MediaLibraryScanProgress {
  final String phase;
  final int completed;
  final int total;

  const MediaLibraryScanProgress({
    this.phase = '',
    this.completed = 0,
    this.total = 0,
  });
}

enum MediaLibraryScanMode { unrecognizedOnly, forceAll }

extension MediaLibraryScanModeBehavior on MediaLibraryScanMode {
  bool get refreshesFileIndex => this == MediaLibraryScanMode.forceAll;

  String get title {
    switch (this) {
      case MediaLibraryScanMode.unrecognizedOnly:
        return '扫描未识别';
      case MediaLibraryScanMode.forceAll:
        return '强制重新扫描';
    }
  }
}

class MediaLibraryScanLog {
  final DateTime createdAt;
  final String message;
  final bool isError;

  const MediaLibraryScanLog({
    required this.createdAt,
    required this.message,
    this.isError = false,
  });

  factory MediaLibraryScanLog.fromJson(Map<String, dynamic> json) {
    return MediaLibraryScanLog(
      createdAt: _parseDate(json['createdAt']) ?? DateTime.now(),
      message: json['message']?.toString() ?? '',
      isError: json['isError'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'createdAt': createdAt.toIso8601String(),
    'message': message,
    'isError': isError,
  };
}

enum MediaLibraryScanTaskStatus {
  queued,
  running,
  paused,
  stopping,
  stopped,
  cancelling,
  cancelled,
  completed,
  failed,
}

extension MediaLibraryScanTaskStatusX on MediaLibraryScanTaskStatus {
  String get title {
    switch (this) {
      case MediaLibraryScanTaskStatus.queued:
        return '等待开始';
      case MediaLibraryScanTaskStatus.running:
        return '正在刮削';
      case MediaLibraryScanTaskStatus.paused:
        return '已暂停';
      case MediaLibraryScanTaskStatus.stopping:
        return '正在停止';
      case MediaLibraryScanTaskStatus.stopped:
        return '已停止';
      case MediaLibraryScanTaskStatus.cancelling:
        return '正在取消';
      case MediaLibraryScanTaskStatus.cancelled:
        return '已取消';
      case MediaLibraryScanTaskStatus.completed:
        return '已完成';
      case MediaLibraryScanTaskStatus.failed:
        return '失败';
    }
  }

  bool get isActive => switch (this) {
    MediaLibraryScanTaskStatus.queued ||
    MediaLibraryScanTaskStatus.running ||
    MediaLibraryScanTaskStatus.paused ||
    MediaLibraryScanTaskStatus.stopping ||
    MediaLibraryScanTaskStatus.cancelling => true,
    _ => false,
  };

  bool get canPause => this == MediaLibraryScanTaskStatus.running;

  bool get canResume =>
      this == MediaLibraryScanTaskStatus.paused ||
      this == MediaLibraryScanTaskStatus.stopped ||
      this == MediaLibraryScanTaskStatus.failed;

  bool get canStop =>
      this == MediaLibraryScanTaskStatus.queued ||
      this == MediaLibraryScanTaskStatus.running ||
      this == MediaLibraryScanTaskStatus.paused;
}

class MediaLibraryScanTask {
  final String id;
  final String libraryID;
  final String libraryName;
  final MediaLibraryScanMode mode;
  final MediaLibraryScanTaskStatus status;
  final MediaLibraryScanProgress progress;
  final List<MediaLibraryScanLog> logs;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? failureReason;

  const MediaLibraryScanTask({
    required this.id,
    required this.libraryID,
    required this.libraryName,
    required this.mode,
    required this.status,
    required this.progress,
    required this.logs,
    required this.createdAt,
    required this.updatedAt,
    this.failureReason,
  });

  factory MediaLibraryScanTask.create({
    required MediaLibraryDefinition library,
    required MediaLibraryScanMode mode,
  }) {
    final now = DateTime.now();
    return MediaLibraryScanTask(
      id: '${library.id}-${now.microsecondsSinceEpoch}',
      libraryID: library.id,
      libraryName: library.name,
      mode: mode,
      status: MediaLibraryScanTaskStatus.queued,
      progress: const MediaLibraryScanProgress(phase: '等待开始'),
      logs: [
        MediaLibraryScanLog(
          createdAt: now,
          message: '任务已创建，等待${mode.title}「${library.name}」',
        ),
      ],
      createdAt: now,
      updatedAt: now,
    );
  }

  bool get isActive => status.isActive;

  MediaLibraryScanTask copyWith({
    String? libraryName,
    MediaLibraryScanMode? mode,
    MediaLibraryScanTaskStatus? status,
    MediaLibraryScanProgress? progress,
    List<MediaLibraryScanLog>? logs,
    DateTime? updatedAt,
    String? failureReason,
    bool clearFailure = false,
  }) {
    return MediaLibraryScanTask(
      id: id,
      libraryID: libraryID,
      libraryName: libraryName ?? this.libraryName,
      mode: mode ?? this.mode,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      logs: logs ?? this.logs,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      failureReason: clearFailure
          ? null
          : (failureReason ?? this.failureReason),
    );
  }

  factory MediaLibraryScanTask.fromJson(Map<String, dynamic> json) {
    final createdAt = _parseDate(json['createdAt']) ?? DateTime.now();
    final restoredStatus = MediaLibraryScanTaskStatus.values.firstWhere(
      (status) => status.name == json['status']?.toString(),
      orElse: () => MediaLibraryScanTaskStatus.stopped,
    );
    final status = restoredStatus.isActive
        ? MediaLibraryScanTaskStatus.stopped
        : restoredStatus;
    final rawProgress = json['progress'];
    final progressMap = rawProgress is Map
        ? Map<String, dynamic>.from(rawProgress)
        : const <String, dynamic>{};
    final logs =
        (json['logs'] as List?)
            ?.whereType<Map>()
            .map(
              (entry) => MediaLibraryScanLog.fromJson(
                Map<String, dynamic>.from(entry),
              ),
            )
            .toList() ??
        <MediaLibraryScanLog>[];
    if (restoredStatus.isActive) {
      logs.add(
        MediaLibraryScanLog(
          createdAt: DateTime.now(),
          message: '应用重新启动，未完成任务已停止',
        ),
      );
    }
    return MediaLibraryScanTask(
      id:
          json['id']?.toString() ??
          'restored-${createdAt.microsecondsSinceEpoch}',
      libraryID: json['libraryID']?.toString() ?? '',
      libraryName: json['libraryName']?.toString() ?? '未知媒体库',
      mode: MediaLibraryScanMode.values.firstWhere(
        (mode) => mode.name == json['mode']?.toString(),
        orElse: () => MediaLibraryScanMode.unrecognizedOnly,
      ),
      status: status,
      progress: MediaLibraryScanProgress(
        phase: restoredStatus.isActive
            ? '应用重新启动，任务已停止'
            : progressMap['phase']?.toString() ?? '',
        completed:
            int.tryParse(progressMap['completed']?.toString() ?? '') ?? 0,
        total: int.tryParse(progressMap['total']?.toString() ?? '') ?? 0,
      ),
      logs: logs,
      createdAt: createdAt,
      updatedAt: _parseDate(json['updatedAt']) ?? createdAt,
      failureReason: json['failureReason']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'libraryID': libraryID,
    'libraryName': libraryName,
    'mode': mode.name,
    'status': status.name,
    'progress': {
      'phase': progress.phase,
      'completed': progress.completed,
      'total': progress.total,
    },
    'logs': logs.map((entry) => entry.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'failureReason': failureReason,
  };
}

class ParsedMediaName {
  final String title;
  final int? year;
  final int? season;
  final int? episode;
  final bool isEpisode;
  final String? resolution;
  final String? source;
  final String? videoCodec;
  final String? audio;
  final String? dynamicRange;

  const ParsedMediaName({
    required this.title,
    this.year,
    this.season,
    this.episode,
    this.isEpisode = false,
    this.resolution,
    this.source,
    this.videoCodec,
    this.audio,
    this.dynamicRange,
  });

  factory ParsedMediaName.parse(
    String name, {
    String? directoryName,
    String? directoryPath,
  }) {
    final stem = name.replaceFirst(
      RegExp(
        r'\.(?:mkv|mp4|avi|rmvb?|mov|m4v|wmv|flv|ts|m2ts|mts|iso|mpg|mpeg|webm|vob)$',
        caseSensitive: false,
      ),
      '',
    );
    final bracketedRelease = _parseBracketedRelease(stem);
    final normalized = stem
        .replaceAll('&', ' and ')
        .replaceAll('＆', ' and ')
        // Keep apostrophes in English contractions such as Li'l and Can't;
        // they are part of the searchable title, not release separators.
        .replaceAll(RegExp(r'''[._!@#\$%^*=|~`｜，、；？！…<>?"\:;]+'''), ' ');
    final episodeMatch = RegExp(
      r'\bS\s*0?(\d{1,2})[ ._-]*E\s*0?(\d{1,4})\b|\b(\d{1,2})x(\d{1,4})\b|第\s*(\d{1,2})\s*季\s*第?\s*(\d{1,4})\s*[集话期]',
      caseSensitive: false,
    ).firstMatch(normalized);
    int? season;
    int? episode;
    if (episodeMatch != null) {
      final groups = [
        [1, 2],
        [3, 4],
        [5, 6],
      ];
      for (final pair in groups) {
        final a = episodeMatch.group(pair[0]);
        final b = episodeMatch.group(pair[1]);
        if (a != null && b != null) {
          season = int.tryParse(a);
          episode = int.tryParse(b);
          break;
        }
      }
    }
    final episodeOnly = season == null
        ? RegExp(
            r'\b(?:E|EP|Episode)[ ._-]*(\d{1,4})\b|第\s*(\d{1,4})\s*[集话期]',
            caseSensitive: false,
          ).firstMatch(normalized)
        : null;
    if (episodeOnly != null) {
      episode = int.tryParse(
        episodeOnly.group(1) ?? episodeOnly.group(2) ?? '',
      );
    }
    episode ??= bracketedRelease.episode;
    final damagedSeasonEpisodeMarker = RegExp(
      r'\bS\s+\d{1,2}|\bE\s+\d{1,4}',
      caseSensitive: false,
    ).hasMatch(normalized);
    final varietyPhase = RegExp(r'第\s*(\d{1,4})\s*期').firstMatch(normalized);
    final varietyPart = RegExp(r'[（(]\s*([上下])\s*[）)]').firstMatch(normalized);
    if (damagedSeasonEpisodeMarker &&
        varietyPhase != null &&
        varietyPart != null) {
      final phase = int.tryParse(varietyPhase.group(1)!);
      if (phase != null && phase > 0) {
        episode = (phase - 1) * 2 + (varietyPart.group(1) == '下' ? 2 : 1);
      }
    }
    String? first(String pattern) =>
        RegExp(pattern, caseSensitive: false).firstMatch(normalized)?.group(0);
    final yearMatches = RegExp(
      r'\b(19\d{2}|20\d{2})\b',
    ).allMatches(normalized).toList();
    final repairedYear = _repairSpacedYear(normalized);
    // Some release names carry an upload year before the real title and
    // release year. Prefer the later year in that specific form.
    final yearMatch = yearMatches.length > 1 && yearMatches.first.start == 0
        ? yearMatches.last
        : yearMatches.firstOrNull;
    final boundary = RegExp(
      r'(?:\b(?:19\d{2}|20\d{2}|S\s*0?\d{1,2}[ ._-]*E\s*0?\d{1,4}|\d{1,2}x\d{1,4}|\d{3,4}x\d{3,4}|2160p|1080p|720p|480p|4k|web[- ]?(?:dl|rip)?|bluray|bdrip|remux|hdtv|dvd|bd|(?:cd|disc|disk)[ ._-]*0?\d{1,2}|x26[45]|h\.?26[45]|hevc|av1|aac|ac3|eac3|flac|truehd|dts|ddp|atmos|hdr|dv|国语|粤语|国粤(?:双语)?|中(?:英|日|韩)?(?:双语|字幕)|中文字幕|简繁(?:字幕)?)\b|[\[(（]\s*\d[\d\s]{2,4}\s*[\])）]|第\s*\d{1,4}\s*[集话期])',
      caseSensitive: false,
    );
    final boundaryMatches = boundary.allMatches(normalized).toList();
    final leadingArchiveDate = RegExp(
      r'^\s*(?:19|20)\d{2}\s*年\s*\d{1,2}\s*月\s*\d{1,2}\s*[日号]?[ ._-]*',
    ).firstMatch(normalized);
    final leadingYear = RegExp(
      r'^\s*(?:[\[(（]\s*)?((?:19|20)\d{2})(?:\s*[\])）])?[ ._-]*',
    ).firstMatch(normalized);
    var titleStart = 0;
    var titleEnd = boundaryMatches.firstOrNull?.start ?? normalized.length;
    if (leadingArchiveDate != null) {
      titleStart = leadingArchiveDate.end;
      titleEnd =
          boundaryMatches
              .where((match) => match.start >= titleStart)
              .map((match) => match.start)
              .firstOrNull ??
          normalized.length;
    } else if (leadingYear != null) {
      final laterYear = yearMatches.skip(1).firstOrNull;
      final textBeforeLaterYear = laterYear == null
          ? ''
          : normalized.substring(leadingYear.end, laterYear.start).trim();
      if (laterYear != null && textBeforeLaterYear.isEmpty) {
        // A numeric work title followed by its release year, e.g. `2046.2004`.
        titleEnd = laterYear.start;
      } else {
        // Legacy archives commonly use `(1985)Title` or `1985 Title`.
        titleStart = leadingYear.end;
        titleEnd =
            boundaryMatches
                .where((match) => match.start >= titleStart)
                .map((match) => match.start)
                .firstOrNull ??
            normalized.length;
      }
    }
    var title = normalized.substring(titleStart, titleEnd).trim();
    // Movie archives may prefix the title with a studio/catalog label, for
    // example `中国香港邵氏出品.1968.拜倒石榴裙`.
    final catalogTitle = RegExp(
      r'^(.+?)[ ._-]+((?:19|20)\d{2})[ ._-]+(.+)$',
    ).firstMatch(normalized);
    if (catalogTitle != null &&
        RegExp(
          r'(?:出品|片库|电影库|合集|收藏|目录)$',
        ).hasMatch(catalogTitle.group(1)!.trim())) {
      title = catalogTitle.group(3)!;
    }
    title = _cleanTitle(title);
    if (bracketedRelease.title != null) {
      title = bracketedRelease.title!;
    }
    // A trailing season marker is release metadata, never part of the TMDB
    // query title. It can appear with or without an episode marker.
    title = title
        .replaceFirst(
          RegExp(r'(?:\s|[._-])*S\s*0?\d{1,2}$', caseSensitive: false),
          '',
        )
        .replaceFirst(RegExp(r'(?:\s|[._-])+第\s*[一二三四五六七八九十两\d]+\s*季$'), '')
        .trim();
    ParsedMediaName? parent;
    int? directoryEditionYear;
    ParsedMediaName? immediateParent;
    ParsedMediaName? parseImmediateParent() {
      if (directoryName?.trim().isNotEmpty != true) return null;
      return immediateParent ??= ParsedMediaName.parse(directoryName!.trim());
    }

    if (episode == null && directoryName?.trim().isNotEmpty == true) {
      final trailingNumber = RegExp(
        r'^(?:(.+?[\u4e00-\u9fff])(\d{1,4})|(.+?)[\s._-]+(\d{1,4}))$',
      ).firstMatch(title);
      if (trailingNumber != null) {
        final candidateTitle = _cleanTitle(
          trailingNumber.group(1) ?? trailingNumber.group(3)!,
        );
        final candidateEpisode = int.tryParse(
          trailingNumber.group(2) ?? trailingNumber.group(4)!,
        );
        final directory = parseImmediateParent()!;
        final directoryTitleWithoutEdition = directory.title.replaceFirst(
          RegExp(r'(?<=[\u4e00-\u9fff])(?:19|20)?\d{2}$'),
          '',
        );
        final editionMatch = RegExp(
          r'(?<=[\u4e00-\u9fff])(\d{2})$',
        ).firstMatch(directory.title);
        if (candidateEpisode != null &&
            candidateEpisode > 0 &&
            (_titleComparisonKey(candidateTitle) ==
                    _titleComparisonKey(directory.title) ||
                _titleComparisonKey(candidateTitle) ==
                    _titleComparisonKey(directoryTitleWithoutEdition))) {
          title = candidateTitle;
          episode = candidateEpisode;
          season ??= directory.season;
          parent = directory;
          final edition = int.tryParse(editionMatch?.group(1) ?? '');
          if (edition != null) {
            directoryEditionYear = edition >= 70
                ? 1900 + edition
                : 2000 + edition;
          }
        }
      }
    }
    var inheritedTitleFromParent = false;
    final genericName =
        title.isEmpty ||
        RegExp(r'^\d+$').hasMatch(title) ||
        RegExp(r'^S\d{1,2}E\d{1,4}$', caseSensitive: false).hasMatch(title);
    if (genericName &&
        ((directoryName != null && directoryName.trim().isNotEmpty) ||
            (directoryPath != null && directoryPath.trim().isNotEmpty))) {
      parent = _bestParentContext(directoryName, directoryPath);
      if (parent?.title.isNotEmpty == true) {
        title = parent!.title;
        inheritedTitleFromParent = true;
      }
    }
    final seasonOnly = RegExp(
      r'\b(?:Season|S)\s*0?(\d{1,2})\b',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (season == null && seasonOnly != null) {
      season = int.tryParse(seasonOnly.group(1)!);
    }
    final chineseSeasonOnly = RegExp(
      r'第\s*([一二三四五六七八九十两\d]{1,3})\s*季',
    ).firstMatch(normalized);
    if (season == null && chineseSeasonOnly != null) {
      season = _parseChineseNumber(chineseSeasonOnly.group(1)!);
    }
    // Disc/episode files are frequently named only "0102" or "02". Use an
    // explicit season from the parent directory first; otherwise only infer
    // the unambiguous SS EE form to avoid treating years as episode numbers.
    final numericPrefix = RegExp(r'^\s*(\d{1,4})(?=$|[ ._-])').firstMatch(stem);
    final numericOnly = numericPrefix != null && genericName;
    if (episode == null &&
        numericOnly &&
        (directoryName != null || directoryPath != null) &&
        !RegExp(r'^(?:19|20)\d{2}$').hasMatch(numericPrefix.group(1)!)) {
      final digits = numericPrefix.group(1)!;
      final parentSeason = parent?.season;
      if (parentSeason != null) {
        season = parentSeason;
        episode = int.tryParse(digits);
      } else if (digits.length <= 2 && parent != null) {
        // A bare file such as `13.mkv` inside a meaningful series directory is
        // an episode even when the folder omits an explicit season marker.
        season = 1;
        episode = int.tryParse(digits);
      } else if (digits.length == 3 || digits.length == 4) {
        final split = digits.length - 2;
        final inferredSeason = int.tryParse(digits.substring(0, split));
        final inferredEpisode = int.tryParse(digits.substring(split));
        if (inferredSeason != null &&
            inferredSeason > 0 &&
            inferredSeason <= 99 &&
            inferredEpisode != null &&
            inferredEpisode > 0) {
          season = inferredSeason;
          episode = inferredEpisode;
        }
      }
    }
    if (title.isEmpty) title = _cleanTitle(normalized);

    final directory = parseImmediateParent();
    final relatedDirectory =
        directory != null && _titlesShareContext(title, directory.title)
        ? directory
        : null;
    final metadataParent = parent ?? relatedDirectory;
    final resolvedSeason =
        season ?? metadataParent?.season ?? (episode == null ? null : 1);
    var resolution = first(r'(?:2160p|1080p|720p|480p|4k|\d{3,4}x\d{3,4})');
    resolution ??= _repairSpacedResolution(normalized);
    resolution ??= metadataParent?.resolution;
    final inheritedYear =
        metadataParent?.year ??
        directoryEditionYear ??
        (directoryName == null ? null : _repairSpacedYear(directoryName)) ??
        (directoryPath == null ? null : _repairSpacedYear(directoryPath));
    final source =
        first(r'\b(?:WEB[- ]?DL|WEBRip|BluRay|BDRip|REMUX|HDTV|DVD|UHD)\b') ??
        metadataParent?.source;
    final videoCodec =
        first(r'\b(?:x26[45]|h\.?26[45]|AVC|HEVC|AV1|VC-1)\b') ??
        metadataParent?.videoCodec;
    final audio =
        first(
          r'\b(?:Atmos|TrueHD|DTS(?:-HD)?|DDP?(?: ?[0-9.]+)?|AAC|FLAC)\b',
        ) ??
        metadataParent?.audio;
    final dynamicRange =
        first(r'(?:HDR10?\+?|HDR|Dolby[ .-]?Vision|DV)') ??
        metadataParent?.dynamicRange;
    return ParsedMediaName(
      title: title,
      year: inheritedTitleFromParent && metadataParent?.year != null
          ? metadataParent!.year
          : bracketedRelease.title != null && bracketedRelease.year != null
          ? bracketedRelease.year
          : yearMatch == null
          ? (bracketedRelease.year ?? repairedYear ?? inheritedYear)
          : int.tryParse(yearMatch.group(1)!),
      season: resolvedSeason,
      episode: episode,
      isEpisode: resolvedSeason != null && episode != null,
      resolution: resolution,
      source: source,
      videoCodec: videoCodec,
      audio: audio,
      dynamicRange: dynamicRange,
    );
  }

  static bool _titlesShareContext(String first, String second) {
    final firstKey = _titleComparisonKey(first);
    final secondKey = _titleComparisonKey(second);
    if (firstKey.isEmpty || secondKey.isEmpty) return false;
    if (firstKey == secondKey) return true;
    if (firstKey.length < 4 || secondKey.length < 4) return false;
    return firstKey.contains(secondKey) || secondKey.contains(firstKey);
  }

  static ({String? title, int? year, int? episode}) _parseBracketedRelease(
    String value,
  ) {
    final matches = RegExp(r'[\[【]([^\]】]+)[\]】]').allMatches(value).toList();
    final segments = matches
        .map((match) => match.group(1)?.trim() ?? '')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.length < 4) {
      return (title: null, year: null, episode: null);
    }

    String? title;
    int? year;
    int? episode;
    final suffix = matches.isEmpty
        ? ''
        : value.substring(matches.last.end).trim();
    if (suffix.isNotEmpty) {
      final suffixYear = RegExp(r'\b(19\d{2}|20\d{2})\b').firstMatch(suffix);
      final suffixTitle = _cleanTitle(
        suffixYear == null ? suffix : suffix.substring(0, suffixYear.start),
      );
      if (suffixTitle.isNotEmpty) {
        title = suffixTitle;
        year = suffixYear == null ? null : int.tryParse(suffixYear.group(1)!);
      }
    }
    for (final segment in segments) {
      final numeric = int.tryParse(segment);
      if (numeric != null) {
        if (numeric >= 1900 && numeric <= 2099) {
          year ??= numeric;
        } else if (numeric > 0 && numeric <= 9999) {
          episode = numeric;
        }
        continue;
      }
      if (title == null &&
          RegExp(r'[\u4e00-\u9fff]').hasMatch(segment) &&
          !_isBracketMetadata(segment)) {
        title = segment;
      }
    }

    return (
      title: title,
      year: year,
      episode: title != null && segments.length >= 5 ? episode : null,
    );
  }

  static bool _isBracketMetadata(String value) {
    final normalized = value.trim();
    if (RegExp(
      r'^(?:国漫|日漫|美漫|动漫|动画|国创|国产|国产剧|剧集|电视剧|电影|合集|完结|连载|简中|繁中|中字|字幕|内封|国配|国语|粤语)$',
      caseSensitive: false,
    ).hasMatch(normalized)) {
      return true;
    }
    return RegExp(
      r'(?:字幕|编码|压制|发布组|音轨|特效|内封|简繁|国配)',
      caseSensitive: false,
    ).hasMatch(normalized);
  }

  static int? _parseChineseNumber(String value) {
    final normalized = value.trim().replaceAll('两', '二');
    final numeric = int.tryParse(normalized);
    if (numeric != null) return numeric;
    const digits = {
      '一': 1,
      '二': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    if (normalized == '十') return 10;
    final parts = normalized.split('十');
    if (parts.length == 2) {
      final tens = parts.first.isEmpty ? 1 : digits[parts.first];
      final units = parts.last.isEmpty ? 0 : digits[parts.last];
      if (tens != null && units != null) return tens * 10 + units;
    }
    return digits[normalized];
  }

  static String? _repairSpacedResolution(String value) {
    const damaged = <String, String>{
      r'\b216\s+p\b': '2160p',
      r'\b1\s+8\s+p\b': '1080p',
      r'\b72\s+p\b': '720p',
      r'\b48\s+p\b': '480p',
    };
    for (final entry in damaged.entries) {
      if (RegExp(entry.key, caseSensitive: false).hasMatch(value)) {
        return entry.value;
      }
    }
    return null;
  }

  static int? _repairSpacedYear(String value) {
    final matches = RegExp(
      r'[\[(（]\s*(\d[\d\s]{2,4})\s*[\])）]',
    ).allMatches(value);
    for (final match in matches) {
      final raw = match.group(1);
      if (raw == null || !RegExp(r'\s').hasMatch(raw)) continue;
      var repaired = raw.replaceAll(RegExp(r'\s'), '0');
      if (repaired.length == 3 &&
          (repaired.startsWith('1') || repaired.startsWith('2'))) {
        repaired = '${repaired[0]}0${repaired.substring(1)}';
      }
      final year = int.tryParse(repaired);
      if (year != null && year >= 1900 && year <= 2099) return year;
    }
    return null;
  }

  static String _cleanTitle(String value) {
    var title = value.trim();

    // A leading ASCII-only bracket is a scene release group, not a title.
    title = title.replaceFirst(
      RegExp(r'^\s*[\[【][A-Za-z0-9][A-Za-z0-9 ._-]{1,31}[\]】]\s*[-_. ]*'),
      '',
    );

    // Download sites and uploader labels are transport metadata even when
    // their bracket contains Chinese text. Preserve ordinary localized title
    // brackets, but remove URL/domain/upload prefixes.
    title = title.replaceFirst(
      RegExp(
        r'^\s*[\[【](?=[^\]】]*(?:www\.|\.(?:com|cn|net|org)\b|upload\b|电影天堂|电影湾|影视))[^\]】]*[\]】]\s*[-_. ]*',
        caseSensitive: false,
      ),
      '',
    );

    // Collection folders often append uploader/account labels after the
    // actual title, for example 倚天屠龙记@猪猪乐园@zerocool9527 or
    // 片名 6v电影 地址发布页. These labels are not useful search terms.
    title = title
        .replaceFirst(RegExp(r'\s*[@＠].*$'), '')
        .replaceFirst(
          RegExp(
            r'\s+(?:猪猪乐园|6v电影|地址发布页|收藏不迷路|不迷路|发布页|V信|微信|Q裙|QQ群|公众号|下载地址).*$',
            caseSensitive: false,
          ),
          '',
        );

    // Some library folders use a single Latin letter only as a manual sort
    // prefix, for example `Q-翘楚`. Strip it only when a Chinese title follows
    // so legitimate English and mixed-language titles remain untouched.
    title = title.replaceFirst(
      RegExp(r'^\s*[A-Za-z]\s*[-_]\s*(?=[\u4e00-\u9fff])'),
      '',
    );

    // Broadcaster names are occasionally prepended to documentary releases,
    // for example `BBC-One Life`. Keep this allowlist narrow so hyphenated
    // work titles such as Spider-Man are not damaged.
    title = title.replaceFirst(
      RegExp(r'^\s*(?:BBC|PBS|NHK)[ ._-]+(?=[A-Za-z])', caseSensitive: false),
      '',
    );

    // Some folders are named as `2008见龙卸甲` (or `2008 见龙卸甲`) while
    // the file itself contains only the year. The year remains available to
    // the parser, but it must not become part of the TMDB search title.
    title = title.replaceFirst(
      RegExp(r'^\s*(?:19|20)\d{2}(?=[ ._-]*(?!年)[\u4e00-\u9fff])[ ._-]*'),
      '',
    );

    // Paths often preserve an already-known TMDB identifier. It is handled by
    // the recognizer directly and must never become part of the search title.
    title = title.replaceAll(
      RegExp(r'\{\s*tmdb\s*[-_:]?\s*[\d\s]+\}', caseSensitive: false),
      ' ',
    );

    // Release collectors often prepend their collection date. It has no
    // relation to the movie year and degrades a TMDB query substantially.
    title = title.replaceFirst(
      RegExp(r'^\s*(?:19|20)\d{2}\s*年\s*\d{1,2}\s*月\s*\d{1,2}\s*[日号]?\s*'),
      '',
    );

    // Release groups frequently put all disc/menu/audio/subtitle information
    // in a bracket between the Chinese and original titles. Keep the leading
    // title and discard the whole release block instead of joining both sides.
    final bracket = RegExp(r'[\[【]([^\]】]*)[\]】]').firstMatch(title);
    if (bracket != null &&
        RegExp(
          r'UHD|ULTRAHD|Blu[- ]?ray|BDJ|BDMV|原盘|DIY|菜单|音轨|国语|国配|字幕|SGNB|CHDBits',
          caseSensitive: false,
        ).hasMatch(bracket.group(1) ?? '')) {
      title = title.substring(0, bracket.start);
    }

    // Episode totals, subtitle notes and bitrate labels are folder metadata,
    // not part of a work title. Unlike a localized title in parentheses, these
    // markers are safe to discard wherever they appear.
    title = title.replaceAll(
      RegExp(
        r'[\[【{](?:[^\]】}]*)(?:全\s*\d+\s*集|更新至\s*\d+\s*集|高码|帧率|无字|字幕|音轨|杜比|HDR|WEB[- ]?DL|Blu[- ]?ray|REMUX)[^\]】}]*[\]】}]',
        caseSensitive: false,
      ),
      ' ',
    );

    // A few release tags are written without brackets. They are never part of
    // a searchable title and should terminate the human-readable name.
    final releaseBoundary = RegExp(
      r'(?:\b(?:ULTRA[ .-]?HD|UHD|Blu[- ]?ray|BDRip|REMUX|BDJ|BDMV|DVD|(?:CD|DISC|DISK)[ ._-]*0?\d{1,2})\b|蓝光(?:原盘)?|原盘|DIY|菜单|音轨|国语|国配|字幕|次时代|SGNB|CHDBits)',
      caseSensitive: false,
    ).firstMatch(title);
    if (releaseBoundary != null) {
      title = title.substring(0, releaseBoundary.start);
    }

    // Prefer the localized title when an English original title follows it.
    // TMDB receives a compact Chinese query first; the original title remains
    // available from TMDB after matching.
    final chineseEnglishBoundary = RegExp(
      r'[\u4e00-\u9fff\d\)）]\s*(?=[A-Z][A-Za-z])',
    ).firstMatch(title);
    if (chineseEnglishBoundary != null &&
        RegExp(
          r'[\u4e00-\u9fff]',
        ).hasMatch(title.substring(0, chineseEnglishBoundary.end))) {
      title = title.substring(0, chineseEnglishBoundary.start + 1);
    }

    title = title
        .replaceFirst(
          RegExp(
            r'[ ._-]*(?:国语|粤语|日语|韩语|英语|德语|法语|俄语)?(?:中字|无字|字幕)$',
            caseSensitive: false,
          ),
          '',
        )
        .replaceFirst(RegExp(r'^\s*[\[【(（]\s*\d{1,3}\s*[\]】)）][ ._-]*'), '')
        .replaceFirst(RegExp(r'^\s*\d{1,3}[ ._-]+'), '')
        .replaceAll(RegExp(r'[\(（](?:港台|港版?|台版?|国配|国语|简繁?|中字?)[\)）]'), ' ')
        .replaceAll(
          RegExp(
            r'[\(（](?:高清(?:粤|国)?|超清|(?:美亚|泰吉)?修复版?|完整版?|加长版?)[\)）]',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'(?:[ ._-]+|^)(?:国[粤英日韩][语字]?|国粤(?:双语)?(?:中字|中英(?:字幕|双字)?)?|国语|粤语|日语|韩语|英语|德语|法语|俄语|(?:中英|中日|中韩)(?:双语|字幕)?|中文字幕|中字|无字|简繁(?:字幕)?|内封(?:特效)?中英(?:双字|字幕)?|CHINESE|CHN)(?=$|[ ._-])',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'[\[\]【】{}()（）]'), ' ')
        .replaceFirst(RegExp(r'^\s*[A-Za-z]\s+(?=[\u4e00-\u9fff])'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceFirst(RegExp(r'[\s._-]+$'), '')
        .trim();
    return title;
  }

  static ParsedMediaName? _bestParentContext(
    String? directoryName,
    String? directoryPath,
  ) {
    final candidates = <String>{
      if (directoryName?.trim().isNotEmpty == true) directoryName!.trim(),
    };
    if (directoryPath?.trim().isNotEmpty == true) {
      final segments = directoryPath!
          .split(RegExp(r'[\\/]'))
          .where((segment) => segment.trim().isNotEmpty)
          .toList();
      // The final segment is the file name. Inspect a few ancestors so a
      // numeric episode inside a resolution/season folder can inherit the
      // actual series title from the enclosing release directory.
      for (
        var index = segments.length - 2;
        index >= 0 && index >= segments.length - 6;
        index--
      ) {
        candidates.add(segments[index]);
      }
    }

    ParsedMediaName? best;
    var bestScore = -1;
    for (final candidate in candidates) {
      final parsed = ParsedMediaName.parse(candidate);
      final score = _parentTitleScore(parsed.title);
      if (score > bestScore) {
        best = parsed;
        bestScore = score;
      }
    }
    return best;
  }

  static int _parentTitleScore(String value) {
    final title = value.trim();
    final compact = title.replaceAll(RegExp(r'[^a-zA-Z0-9\u4e00-\u9fff]'), '');
    if (compact.length < 2 || RegExp(r'^\d+$').hasMatch(compact)) return -1;
    var score = compact.length;
    if (RegExp(r'[\u4e00-\u9fff]').hasMatch(compact)) score += 8;
    if (RegExp(
      r'\b(?:4k|2160p|1080p|720p|web|bluray|remux|hdtv|season)\b',
      caseSensitive: false,
    ).hasMatch(title)) {
      score -= 18;
    }
    if (RegExp(r'^(?:电影|电视剧|国产剧|日韩剧|外语电影|综艺)$').hasMatch(title)) {
      score -= 30;
    }
    if (RegExp(r'(?:系列|合集|收藏|分类)$').hasMatch(title)) score -= 12;
    return score;
  }

  static String _titleComparisonKey(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]+'), '');
}

int? _toInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is double) return value.toInt();
  return int.tryParse(value.toString());
}

DateTime? _parseDate(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  return DateTime.tryParse(value.toString());
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
