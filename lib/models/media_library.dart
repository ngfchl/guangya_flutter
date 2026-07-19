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
    var total = 0;
    var movies = 0;
    var series = 0;
    var unmatched = 0;
    final collections = <String>{};
    for (final item in items) {
      total++;
      if (item.mediaKind == TMDBMediaKind.movie) movies++;
      if (item.mediaKind == TMDBMediaKind.tv) series++;
      if (!item.isMatched) unmatched++;
      final collectionKey =
          item.collectionID?.toString() ?? item.collectionName;
      if (collectionKey != null && collectionKey.isNotEmpty) {
        collections.add(collectionKey);
      }
    }
    return MediaLibraryStatistics(
      total: total,
      movies: movies,
      series: series,
      unmatched: unmatched,
      collections: collections.length,
    );
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
    final stem = name.replaceFirst(RegExp(r'\.[^.]+$'), '');
    final normalized = stem
        .replaceAll('&', ' and ')
        .replaceAll('＆', ' and ')
        .replaceAll(RegExp(r'''[._!@#\$%^*+=|~`｜，、；？！…<>?"':;]+'''), ' ');
    final episodeMatch = RegExp(
      r'\bS(\d{1,2})[ ._-]*E(\d{1,3})\b|\b(\d{1,2})x(\d{1,3})\b|第\s*(\d{1,2})\s*季\s*第?\s*(\d{1,3})\s*[集话]',
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
            r'\b(?:E|EP|Episode)[ ._-]*(\d{1,3})\b|第\s*(\d{1,3})\s*[集话]',
            caseSensitive: false,
          ).firstMatch(normalized)
        : null;
    if (episodeOnly != null) {
      season = 1;
      episode = int.tryParse(
        episodeOnly.group(1) ?? episodeOnly.group(2) ?? '',
      );
    }
    String? first(String pattern) =>
        RegExp(pattern, caseSensitive: false).firstMatch(normalized)?.group(0);
    final yearMatches = RegExp(
      r'\b(19\d{2}|20\d{2})\b',
    ).allMatches(normalized).toList();
    // Some release names carry an upload year before the real title and
    // release year. Prefer the later year in that specific form.
    final yearMatch = yearMatches.length > 1 && yearMatches.first.start == 0
        ? yearMatches.last
        : yearMatches.firstOrNull;
    final boundary = RegExp(
      r'\b(?:19\d{2}|20\d{2}|S\d{1,2}[ ._-]*E\d{1,3}|\d{1,2}x\d{1,3}|\d{3,4}x\d{3,4}|2160p|1080p|720p|480p|4k|web[- ]?(?:dl|rip)?|bluray|bdrip|remux|hdtv|dvd|bd|x26[45]|h\.?26[45]|hevc|av1|aac|ac3|eac3|flac|truehd|dts|ddp|atmos|hdr|dv|国语|粤语|国粤(?:双语)?|中(?:英|日|韩)?(?:双语|字幕)|中文字幕|简繁(?:字幕)?)\b',
      caseSensitive: false,
    );
    final boundaryMatches = boundary.allMatches(normalized).toList();
    final boundaryMatch =
        boundaryMatches.length > 1 &&
            boundaryMatches.first.start == 0 &&
            RegExp(
              r'^(?:19\d{2}|20\d{2})$',
            ).hasMatch(boundaryMatches.first.group(0) ?? '')
        ? boundaryMatches[1]
        : boundaryMatches.firstOrNull;
    var title = boundaryMatch != null
        ? normalized.substring(0, boundaryMatch.start)
        : normalized;
    if (yearMatches.length > 1 && yearMatches.first.start == 0) {
      title = title.replaceFirst(RegExp(r'^\s*\d{4}[ ._-]+'), '');
    }
    title = _cleanTitle(title);
    // A trailing season marker is release metadata, never part of the TMDB
    // query title. It can appear with or without an episode marker.
    title = title
        .replaceFirst(
          RegExp(r'(?:\s|[._-])+S\s*0?\d{1,2}$', caseSensitive: false),
          '',
        )
        .trim();
    final genericName =
        title.isEmpty ||
        RegExp(r'^\d+$').hasMatch(title) ||
        RegExp(r'^S\d{1,2}E\d{1,3}$', caseSensitive: false).hasMatch(title);
    ParsedMediaName? parent;
    if (genericName &&
        ((directoryName != null && directoryName.trim().isNotEmpty) ||
            (directoryPath != null && directoryPath.trim().isNotEmpty))) {
      parent = _bestParentContext(directoryName, directoryPath);
      if (parent?.title.isNotEmpty == true) title = parent!.title;
    }
    final seasonOnly = RegExp(
      r'\b(?:Season|S)\s*0?(\d{1,2})\b',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (season == null && seasonOnly != null) {
      season = int.tryParse(seasonOnly.group(1)!);
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

    return ParsedMediaName(
      title: title,
      year: yearMatch == null
          ? parent?.year
          : int.tryParse(yearMatch.group(1)!),
      season: season ?? parent?.season,
      episode: episode,
      isEpisode: (season ?? parent?.season) != null && episode != null,
      resolution: first(r'\b(?:2160p|1080p|720p|480p|4k|\d{3,4}x\d{3,4})\b'),
      source: first(
        r'\b(?:WEB[- ]?DL|WEBRip|BluRay|BDRip|REMUX|HDTV|DVD|UHD)\b',
      ),
      videoCodec: first(r'\b(?:x26[45]|h\.?26[45]|HEVC|AV1|VC-1)\b'),
      audio: first(
        r'\b(?:Atmos|TrueHD|DTS(?:-HD)?|DDP?(?: ?[0-9.]+)?|AAC|FLAC)\b',
      ),
      dynamicRange: first(r'(?:HDR10?\+?|HDR|Dolby[ .-]?Vision|DV)'),
    );
  }

  static String _cleanTitle(String value) {
    var title = value.trim();

    // Some folders are named as `2008见龙卸甲` (or `2008 见龙卸甲`) while
    // the file itself contains only the year. The year remains available to
    // the parser, but it must not become part of the TMDB search title.
    title = title.replaceFirst(
      RegExp(r'^\s*(?:19|20)\d{2}(?=[ ._-]*(?!年)[\u4e00-\u9fff])[ ._-]*'),
      '',
    );

    // Paths often preserve an already-known TMDB identifier. It is handled by
    // the recognizer directly and must never become part of the search title.
    title = title.replaceAll(RegExp(r'\{\s*tmdb\s*[-_:]?\s*\d+\s*\}'), ' ');

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
      r'(?:\b(?:ULTRA[ .-]?HD|UHD|Blu[- ]?ray|BDRip|REMUX|BDJ|BDMV)\b|原盘|DIY|菜单|音轨|国语|国配|字幕|次时代|SGNB|CHDBits)',
      caseSensitive: false,
    ).firstMatch(title);
    if (releaseBoundary != null) {
      title = title.substring(0, releaseBoundary.start);
    }

    // Prefer the localized title when an English original title follows it.
    // TMDB receives a compact Chinese query first; the original title remains
    // available from TMDB after matching.
    final chineseEnglishBoundary = RegExp(
      r'[\u4e00-\u9fff\)）]\s*(?=[A-Z][A-Za-z])',
    ).firstMatch(title);
    if (chineseEnglishBoundary != null) {
      title = title.substring(0, chineseEnglishBoundary.start + 1);
    }

    title = title
        .replaceFirst(RegExp(r'^\s*[\[【(（]\s*\d{1,3}\s*[\]】)）][ ._-]*'), '')
        .replaceFirst(RegExp(r'^\s*\d{1,3}[ ._-]+'), '')
        .replaceAll(RegExp(r'[\(（](?:港台|港版?|台版?|国配|国语|简繁?|中字?)[\)）]'), ' ')
        .replaceAll(
          RegExp(
            r'(?:[ ._-]+|^)(?:国[粤英日韩][语字]?|国粤(?:双语)?(?:中字|中英(?:字幕|双字)?)?|国语|粤语|(?:中英|中日|中韩)(?:双语|字幕)?|中文字幕|中字|简繁(?:字幕)?|内封(?:特效)?中英(?:双字|字幕)?|CHINESE|CHN)(?=$|[ ._-])',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'[\[\]【】{}()（）]'), ' ')
        .replaceFirst(RegExp(r'^\s*[A-Za-z]\s+(?=[\u4e00-\u9fff])'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
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
