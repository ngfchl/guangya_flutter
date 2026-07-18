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

  factory MediaLibraryItem.fromFile(String libraryID, CloudFile file) {
    final parsed = ParsedMediaName.parse(file.name);
    final kind = parsed.isEpisode ? TMDBMediaKind.tv : TMDBMediaKind.movie;
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

class ParsedMediaName {
  final String title;
  final int? year;
  final int? season;
  final int? episode;
  final bool isEpisode;

  const ParsedMediaName({
    required this.title,
    this.year,
    this.season,
    this.episode,
    this.isEpisode = false,
  });

  factory ParsedMediaName.parse(String name) {
    var stem = name.replaceFirst(RegExp(r'\.[^.]+$'), '');
    stem = stem.replaceAll(RegExp(r'[\._]+'), ' ');

    final episodeMatch =
        RegExp(
          r'(?:S|第)\s*(\d{1,2})\s*(?:E|季\s*第?)\s*(\d{1,3})',
          caseSensitive: false,
        ).firstMatch(stem) ??
        RegExp(r'(\d{1,2})x(\d{1,3})', caseSensitive: false).firstMatch(stem);
    final yearMatch = RegExp(r'(19\d{2}|20\d{2})').firstMatch(stem);

    final cutIndex =
        [
          episodeMatch?.start,
          yearMatch?.start,
          RegExp(
            r'\b(2160p|1080p|720p|bluray|web[- ]?dl|hdtv|x264|x265|hevc)\b',
            caseSensitive: false,
          ).firstMatch(stem)?.start,
        ].whereType<int>().fold<int?>(
          null,
          (min, value) => min == null || value < min ? value : min,
        );

    var title = cutIndex == null ? stem : stem.substring(0, cutIndex);
    title = title
        .replaceAll(RegExp(r'[\[\]\(\)]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (title.isEmpty) title = stem.trim();

    return ParsedMediaName(
      title: title,
      year: yearMatch == null ? null : int.tryParse(yearMatch.group(1)!),
      season: episodeMatch == null
          ? null
          : int.tryParse(episodeMatch.group(1)!),
      episode: episodeMatch == null
          ? null
          : int.tryParse(episodeMatch.group(2)!),
      isEpisode: episodeMatch != null,
    );
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
