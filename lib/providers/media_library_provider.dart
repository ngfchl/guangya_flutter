import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:pinyin/pinyin.dart';

import '../api/guangya_api.dart';
import '../core/http/http_error.dart';
import '../core/logging/app_logger.dart';
import '../core/storage/file_metadata_cache.dart';
import '../core/storage/media_library_store.dart';
import '../core/storage/storage_manager.dart';
import '../core/utils/concurrent_map.dart';
import '../core/utils/format_bytes.dart';
import '../core/utils/json_deep.dart';
import '../models/cloud_file.dart';
import '../models/media_library.dart';
import '../models/media_navigation.dart';
import '../utils/media_known_match_index.dart';
import '../utils/media_artwork.dart';
import '../utils/media_title_matcher.dart';
import '../utils/media_tmdb_candidate_resolver.dart';
import 'watch_history_provider.dart';

const _mediaScanTaskZoneKey = #mediaScanTaskID;
const globalMediaLibraryID = '__global__';
const globalMediaLibraryName = '全局';

/// Blu-ray and DVD folders contain transport streams rather than standalone
/// media. They must be handled as a disc structure, never as individual files.
bool isMediaScanDiscInternalPath(String path) {
  return path
      .split(RegExp(r'[/\\]+'))
      .map((component) => component.trim().toUpperCase())
      .any((component) => component == 'BDMV' || component == 'VIDEO_TS');
}

bool isMediaScanDiscLayout(Iterable<CloudFile> children) {
  final directoryNames = children
      .where((file) => file.isDirectory)
      .map((file) => file.name.trim().toUpperCase())
      .toSet();
  return directoryNames.contains('BDMV') || directoryNames.contains('VIDEO_TS');
}

/// Returns `true` when the given file is an ISO disc image.
/// ISO files are playable, but media scraping ignores them because they
/// represent original disc images rather than standalone movie files.
bool isMediaScanIsoFile(CloudFile file) {
  if (file.isDirectory) return false;
  return file.name.toLowerCase().endsWith('.iso');
}

/// Returns `true` when the file or its path indicates a Blu-ray or DVD disc
/// structure (BDMV folder, VIDEO_TS folder, or ISO disc image).
bool isMediaScanDiscItem(CloudFile file, {String? cloudPath}) {
  if (isMediaScanIsoFile(file)) return true;
  if (isMediaScanDiscLayout([file])) return true;
  final path = cloudPath ?? file.cloudPath;
  return isMediaScanDiscInternalPath(path);
}

bool isConfirmedCloudFileMissingError(Object error) {
  bool isMissingStatus(int? status) => status == 404 || status == 410;

  if (error is ApiException) {
    return isMissingStatus(error.status) ||
        _containsCloudFileMissingMessage(error.message);
  }
  if (error is DioException) {
    final response = error.response;
    if (isMissingStatus(response?.statusCode)) return true;
    final body = response?.data;
    if (body is Map) {
      final code = int.tryParse(body['code']?.toString() ?? '');
      if (isMissingStatus(code)) return true;
    }
    final message = extractHttpMessage(body) ?? error.message ?? '';
    return _containsCloudFileMissingMessage(message);
  }
  return _containsCloudFileMissingMessage(error.toString());
}

bool _containsCloudFileMissingMessage(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized.isEmpty) return false;
  return const [
    '文件不存在',
    '资源不存在',
    '文件已删除',
    '资源已删除',
    '文件已被删除',
    '资源已被删除',
    '文件已移入回收站',
    'file not found',
    'resource not found',
    'no such file',
    'file does not exist',
    'resource does not exist',
  ].any(normalized.contains);
}

String? mediaParentIDFromMetadata(
  CloudFile knownFile, {
  CloudFile? cachedFile,
}) {
  String? nonEmpty(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  final direct = nonEmpty(knownFile.parentID) ?? nonEmpty(cachedFile?.parentID);
  if (direct != null) return direct;

  String? fromFullParents(String? value) {
    final normalized = nonEmpty(value);
    if (normalized == null) return null;
    final candidates = RegExp(r'[A-Za-z0-9][A-Za-z0-9_-]*')
        .allMatches(normalized)
        .map((match) => match.group(0)!)
        .where((value) {
          final lower = value.toLowerCase();
          return value != knownFile.id &&
              lower != 'null' &&
              lower != 'root' &&
              lower != 'true' &&
              lower != 'false';
        })
        .toList(growable: false);
    return candidates.isEmpty ? null : candidates.last;
  }

  return fromFullParents(knownFile.fullParentIDs) ??
      fromFullParents(cachedFile?.fullParentIDs);
}

String safeMediaCloudName(String value) {
  final withoutControls = String.fromCharCodes(
    value.runes.where((codePoint) => codePoint >= 0x20 && codePoint != 0x7f),
  );
  final cleaned = withoutControls
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final fallback = cleaned.isEmpty ? 'Untitled' : cleaned;
  return fallback.length > 180 ? fallback.substring(0, 180).trim() : fallback;
}

String simplifiedMediaTitle(String value) =>
    ChineseHelper.convertToSimplifiedChinese(value);

int? mediaTMDBIDFromPath(String cloudPath) {
  final match = RegExp(
    r'[\[{(（【]\s*tmdb\s*[-_:]?\s*([\d\s]+)\s*[\]})）】]',
    caseSensitive: false,
  ).firstMatch(cloudPath);
  if (match == null) return null;
  final repaired = match.group(1)!.replaceAll(RegExp(r'\s'), '0');
  return int.tryParse(repaired);
}

String recoverCloudFilePath({
  required String fileName,
  String? candidatePath,
  String knownPath = '',
}) {
  String normalize(String value) =>
      value.trim().replaceAll(RegExp(r'\\+'), '/');

  String parentPath(String value) {
    final normalized = normalize(value);
    final index = normalized.lastIndexOf('/');
    return index <= 0 ? '' : normalized.substring(0, index);
  }

  final candidate = normalize(candidatePath ?? '');
  final known = normalize(knownPath);
  if (parentPath(candidate).isNotEmpty) return candidate;
  final knownParent = parentPath(known);
  if (knownParent.isNotEmpty) {
    return '$knownParent/${normalize(fileName)}';
  }
  if (known.startsWith('/')) return '/${normalize(fileName)}';
  return candidate.isEmpty ? normalize(fileName) : candidate;
}

bool shouldRecognizeMediaScanItem({
  required MediaLibraryScanMode mode,
  required MediaLibraryItem? existing,
  required bool sameCloudResource,
}) {
  return mode == MediaLibraryScanMode.forceAll ||
      existing == null ||
      !sameCloudResource ||
      !existing.isMatched;
}

class MediaTMDBMatchRequest {
  final List<MediaLibraryItem> items;
  final List<Map<String, dynamic>> candidates;

  const MediaTMDBMatchRequest({required this.items, required this.candidates});
}

/// A title can be present in more than one part of a release path.  The file
/// name is usually the best signal, but a parent folder often contains the
/// localized/official title while the file keeps a romanized release name.
/// Keep the source alongside the value so diagnostics can explain why a
/// candidate was accepted.
class _MediaTitleVariant {
  final String value;
  final String source;

  const _MediaTitleVariant(this.value, this.source);
}

class _TMDBRecognitionSearchResult {
  final List<Map<String, dynamic>> candidates;
  final List<String> attempts;

  const _TMDBRecognitionSearchResult({
    required this.candidates,
    required this.attempts,
  });
}

class MediaDetailHeader {
  final String title;
  final TMDBMediaKind? mediaKind;
  final String year;

  const MediaDetailHeader({
    required this.title,
    required this.mediaKind,
    required this.year,
  });
}

/// Lets the workspace title bar reflect the media detail currently open in
/// the content pane, without rendering a second detail-specific header.
final activeMediaDetailHeaderProvider = StateProvider<MediaDetailHeader?>(
  (ref) => null,
);

class CloudBackupSyncProgress {
  final String phase;
  final String destination;
  final int transferredBytes;
  final int totalBytes;
  final bool isActive;
  final double bytesPerSecond;
  final String? error;

  const CloudBackupSyncProgress({
    required this.phase,
    required this.destination,
    required this.transferredBytes,
    required this.totalBytes,
    required this.isActive,
    this.bytesPerSecond = 0,
    this.error,
  });

  double get fraction =>
      totalBytes <= 0 ? 0 : (transferredBytes / totalBytes).clamp(0.0, 1.0);
}

class _BackupTransferRate {
  DateTime _lastTime = DateTime.now();
  int _lastBytes = 0;

  double update(int bytes) {
    final now = DateTime.now();
    final seconds = now.difference(_lastTime).inMicroseconds / 1000000;
    if (seconds < 0.3 || bytes <= _lastBytes) return 0;
    final rate = (bytes - _lastBytes) / seconds;
    _lastTime = now;
    _lastBytes = bytes;
    return rate;
  }
}

class MediaLibraryState {
  final List<MediaLibraryDefinition> libraries;
  final String? selectedLibraryID;
  final List<MediaLibraryItem> items;
  final List<MediaLibraryItem> allItems;
  final List<MediaLibraryItem> moviePreviewItems;
  final List<MediaLibraryItem> seriesPreviewItems;
  final Map<String, MediaLibraryStatistics> libraryStatistics;
  final MediaLibraryStatistics storedGlobalStatistics;
  final String? loadedLibraryID;
  final bool allItemsLoaded;
  final bool hasMoreContent;
  final bool isLoadingMore;
  final bool isLoading;
  final List<MediaLibraryScanTask> scanTasks;
  final bool isRefreshingCloudIndex;
  final CloudBackupSyncProgress? cloudBackupSync;
  final List<MediaLibraryScanLog> scanLogs;
  final String searchQuery;
  final MediaLibrarySort sort;
  final MediaSortDirection sortDirection;
  final String? errorMessage;
  final String? statusMessage;

  const MediaLibraryState({
    this.libraries = const [],
    this.selectedLibraryID,
    this.items = const [],
    this.allItems = const [],
    this.libraryStatistics = const {},
    this.storedGlobalStatistics = const MediaLibraryStatistics(),
    this.loadedLibraryID,
    this.allItemsLoaded = false,
    this.moviePreviewItems = const [],
    this.seriesPreviewItems = const [],
    this.hasMoreContent = false,
    this.isLoadingMore = false,
    this.isLoading = false,
    this.scanTasks = const [],
    this.isRefreshingCloudIndex = false,
    this.cloudBackupSync,
    this.scanLogs = const [],
    this.searchQuery = '',
    this.sort = MediaLibrarySort.addedAt,
    this.sortDirection = MediaSortDirection.descending,
    this.errorMessage,
    this.statusMessage,
  });

  MediaLibraryDefinition? get selectedLibrary {
    for (final library in libraries) {
      if (library.id == selectedLibraryID) return library;
    }
    return libraries.isEmpty ? null : libraries.first;
  }

  MediaLibraryScanTask? taskForLibrary(String? libraryID) {
    if (libraryID == null) return null;
    for (final task in scanTasks) {
      if (task.libraryID == libraryID && task.isActive) return task;
    }
    for (final task in scanTasks) {
      if (task.libraryID == libraryID) return task;
    }
    return null;
  }

  MediaLibraryScanTask? taskByID(String taskID) {
    for (final task in scanTasks) {
      if (task.id == taskID) return task;
    }
    return null;
  }

  bool isLibraryScanning(String? libraryID) =>
      taskForLibrary(libraryID)?.isActive == true;

  bool get isScanning => isLibraryScanning(selectedLibraryID);

  bool get hasActiveScans => scanTasks.any((task) => task.isActive);

  int get activeScanCount => scanTasks.where((task) => task.isActive).length;

  MediaLibraryScanProgress progressForLibrary(String? libraryID) {
    return taskForLibrary(libraryID)?.progress ??
        const MediaLibraryScanProgress();
  }

  MediaLibraryScanProgress get progress =>
      progressForLibrary(selectedLibraryID);

  List<MediaLibraryItem> get visibleItems {
    final query = searchQuery.trim().toLowerCase();
    if (query.isEmpty) return items;
    return items.where((item) => item.matchesSearch(query)).toList();
  }

  MediaLibraryStatistics get statistics =>
      libraryStatistics[selectedLibraryID] ?? const MediaLibraryStatistics();

  List<MediaLibraryItem> get globalVisibleItems {
    final query = searchQuery.trim().toLowerCase();
    if (query.isEmpty) return allItems;
    return allItems.where((item) => item.matchesSearch(query)).toList();
  }

  MediaLibraryStatistics get globalStatistics => storedGlobalStatistics;

  MediaLibraryState copyWith({
    List<MediaLibraryDefinition>? libraries,
    String? selectedLibraryID,
    bool clearSelectedLibrary = false,
    List<MediaLibraryItem>? items,
    List<MediaLibraryItem>? allItems,
  List<MediaLibraryItem>? moviePreviewItems,
  List<MediaLibraryItem>? seriesPreviewItems,
    Map<String, MediaLibraryStatistics>? libraryStatistics,
    MediaLibraryStatistics? storedGlobalStatistics,
    String? loadedLibraryID,
    bool clearLoadedLibrary = false,
    bool? allItemsLoaded,
    bool? hasMoreContent,
    bool? isLoadingMore,
    bool? isLoading,
    List<MediaLibraryScanTask>? scanTasks,
    bool? isRefreshingCloudIndex,
    CloudBackupSyncProgress? cloudBackupSync,
    bool clearCloudBackupSync = false,
    List<MediaLibraryScanLog>? scanLogs,
    String? searchQuery,
    MediaLibrarySort? sort,
    MediaSortDirection? sortDirection,
    String? errorMessage,
    bool clearError = false,
    String? statusMessage,
    bool clearStatus = false,
  }) {
    return MediaLibraryState(
      libraries: libraries ?? this.libraries,
      selectedLibraryID: clearSelectedLibrary
          ? null
          : (selectedLibraryID ?? this.selectedLibraryID),
      items: items ?? this.items,
      allItems: allItems ?? this.allItems,
      moviePreviewItems: moviePreviewItems ?? this.moviePreviewItems,
      seriesPreviewItems: seriesPreviewItems ?? this.seriesPreviewItems,
      libraryStatistics: libraryStatistics ?? this.libraryStatistics,
      storedGlobalStatistics:
          storedGlobalStatistics ?? this.storedGlobalStatistics,
      loadedLibraryID: clearLoadedLibrary
          ? null
          : (loadedLibraryID ?? this.loadedLibraryID),
      allItemsLoaded: allItemsLoaded ?? this.allItemsLoaded,
      hasMoreContent: hasMoreContent ?? this.hasMoreContent,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      isLoading: isLoading ?? this.isLoading,
      scanTasks: scanTasks ?? this.scanTasks,
      isRefreshingCloudIndex:
          isRefreshingCloudIndex ?? this.isRefreshingCloudIndex,
      cloudBackupSync: clearCloudBackupSync
          ? null
          : (cloudBackupSync ?? this.cloudBackupSync),
      scanLogs: scanLogs ?? this.scanLogs,
      searchQuery: searchQuery ?? this.searchQuery,
      sort: sort ?? this.sort,
      sortDirection: sortDirection ?? this.sortDirection,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      statusMessage: clearStatus ? null : (statusMessage ?? this.statusMessage),
    );
  }
}

class MediaLibraryNotifier extends StateNotifier<MediaLibraryState> {
  /// How often the global scan writes an aggregated recognition-progress line
  /// to the user-facing scan log (instead of one line per file).
  static const _globalScanRecognitionLogStep = 50;
  // 统计刷新频率：每识别这么多条就重算一次全库统计（电影/电视剧/未识别），
  // 让左侧菜单栏数字实时变化。独立于日志打印步长。
  static const _globalScanStatisticsRefreshStep = 10;

  /// 识别进度刷新统计的在途任务（合并并发请求，避免每批都重算全库统计）。
  Future<void>? _statisticsRefreshInFlight;
  /// 在途计算期间又收到刷新请求时置位，完成后立即尾随重算一次，
  /// 确保 UI 数字不会因合并而长期停留旧值。
  bool _statisticsRefreshPending = false;

  /// 重新计算全局统计并写入 state，供 UI 实时展示电影/电视剧/未识别数量。
  /// 并发调用合并：在途时只标记 pending，完成后尾随重算保证最新。
  Future<void> _refreshGlobalStatistics() async {
    final inFlight = _statisticsRefreshInFlight;
    if (inFlight != null) {
      _statisticsRefreshPending = true;
      await inFlight;
      return;
    }
    _statisticsRefreshPending = false;
    final future = () async {
      try {
        final statistics = await _store.statistics();
        state = state.copyWith(storedGlobalStatistics: statistics.global);
      } catch (error) {
        AppLogger.warning('Media', '刷新媒体库统计失败：$error');
      } finally {
        _statisticsRefreshInFlight = null;
        if (_statisticsRefreshPending) {
          _statisticsRefreshPending = false;
          await _refreshGlobalStatistics();
        }
      }
    }();
    _statisticsRefreshInFlight = future;
    await future;
  }

  final Future<void> Function(Set<String>)? _removeWatchHistory;
  GuangyaAPI? _api;
  final MediaLibraryStore _store;
  final _tmdbDetailsRequests = <String, Future<Map<String, dynamic>>>{};
  final _cloudFolderDetails = <String, Future<CloudFile?>>{};
  Future<Map<String, CloudFile>>? _cachedCloudEntries;
  final _searchResultsCache = <String, List<MediaLibraryItem>>{};
  final _artworkHydrationLibraries = <String>{};
  bool _loaded = false;
  int _librarySelectionSerial = 0;
  final _cancelledScanLibraries = <String>{};
  final _stoppedScanLibraries = <String>{};
  final _pausedScanLibraries = <String>{};
  final _scanPauseGates = <String, Completer<void>>{};
  final _scanRuns = <String, Future<void>>{};
  Future<void> _scanTaskHistoryPersistence = Future.value();
  Future<void> _scanHistoryPersistence = Future.value();
  bool _cancelDetailSync = false;
  bool _refreshingCloudIndex = false;
  /// Number of in-flight background manual-match enrichment tasks.
  ///
  /// Search results keyed by (title + year + kind + apiKey). Many files share
  /// the same parsed title (e.g. 24 episodes of a season, or multiple releases
  /// of the same movie), so caching here avoids redundant network round-trips.
  /// In-flight requests are also merged: if two workers hit the same title at
  /// the same time they share the same Future instead of firing two requests.
  final _recognitionSearchCache = <String, Future<({
    _TMDBRecognitionSearchResult tmdb,
    List<Map<String, dynamic>> douban,
    List<String> attempts,
  })>>{};
  int _manualMatchEnrichment = 0;
  /// Serializes background manual-match enrichment so concurrent tasks do not
  /// race on shared state (items list / allItems reload).
  Future<void> _manualMatchEnrichmentTail = Future.value();
  bool _reconcilingMediaGCIDs = false;
  Future<void> _mediaRemovalQueue = Future.value();
  int _pendingMediaRemovals = 0;
  String? _contentKey;
  MediaLibraryBrowseFilter _contentFilter = MediaLibraryBrowseFilter.all;
  String _contentSearch = '';
  bool _contentHome = false;
  int _contentOffset = 0;
  int _contentLoadSerial = 0;
  bool _nextContentPageInFlight = false;
  Timer? _cloudIndexTimer;
  Completer<bool>? _cloudIndexRefreshCompleter;

  MediaLibraryNotifier({
    Future<void> Function(Set<String>)? removeWatchHistory,
    MediaLibraryStore? store,
  }) : _removeWatchHistory = removeWatchHistory,
       _store = store ?? MediaLibraryStore(),
       super(const MediaLibraryState());

  set api(GuangyaAPI value) => _api = value;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await _store.initialize();
      await _migrateLegacyHiveIfNeeded();
      final libraries = await _loadLibraries();
      final selectedID = libraries.isEmpty ? null : libraries.first.id;
      final statistics = await _store.statistics();
      final logs = _loadScanHistory();
      final scanTasks = _loadScanTaskHistory();
      state = state.copyWith(
        libraries: libraries,
        selectedLibraryID: selectedID,
        items: const [],
        allItems: const [],
        libraryStatistics: statistics.libraries,
        storedGlobalStatistics: statistics.global,
        clearLoadedLibrary: true,
        allItemsLoaded: false,
        scanLogs: logs,
        scanTasks: scanTasks,
        clearStatus: true,
      );
      unawaited(refreshGlobalCloudIndex());
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> loadContent({
    bool home = false,
    MediaLibraryBrowseFilter filter = MediaLibraryBrowseFilter.all,
    String search = '',
    bool reset = true,
    bool force = false,
  }) async {
    final serial = reset ? ++_contentLoadSerial : _contentLoadSerial;
    await load();
    if (serial != _contentLoadSerial) return;
    final selectedID = state.selectedLibraryID;
    final normalizedSearch = search.trim().toLowerCase();
    final global =
        home ||
        normalizedSearch.isNotEmpty ||
        filter == MediaLibraryBrowseFilter.movies ||
        filter == MediaLibraryBrowseFilter.series ||
        filter == MediaLibraryBrowseFilter.unmatched;
    final sort = state.sort;
    final direction = state.sortDirection;
    final key =
        '$selectedID|$home|${filter.name}|$normalizedSearch|${sort.name}|${direction.name}';
    if (!reset && (_contentKey != key || !state.hasMoreContent)) return;
    if (reset &&
        _contentKey == key &&
        (global ? state.allItems : state.items).isNotEmpty &&
        !force) {
      return;
    }
    if (state.isLoadingMore) return;
    if (reset) {
      _contentKey = key;
      _contentFilter = filter;
      _contentSearch = normalizedSearch;
      _contentHome = home;
      _contentOffset = 0;
      state = state.copyWith(
        isLoading: true,
        isLoadingMore: false,
        hasMoreContent: false,
        searchQuery: normalizedSearch,
        items: global ? state.items : const [],
        allItems: global ? const [] : state.allItems,
        clearError: true,
      );
    } else {
      state = state.copyWith(isLoadingMore: true, clearError: true);
    }
    try {
      if (home) {
        final previewCount = StorageManager.configuredMediaHomePreviewCount;
        final pages = await Future.wait(
          state.libraries.map(
            (library) => _store.workPreviewPage(
              libraryID: library.id,
              limit: previewCount,
            ),
          ),
        );
        if (serial != _contentLoadSerial || _contentKey != key) return;
        final values = pages.expand((page) => page).toList(growable: false);
        AppLogger.info(
          'Media',
          '首页预览已加载：${[for (var index = 0; index < state.libraries.length; index++) '${state.libraries[index].name} ${pages[index].length} 条'].join('，')}',
        );
        // 单独加载电影和剧集预览（按作品去重）
        final moviePages = await Future.wait(
          state.libraries.map(
            (library) => _store.itemsPage(
              libraryID: library.id,
              mediaKind: 'movie',
              limit: previewCount,
              distinctWorks: true,
            ),
          ),
        );
        final seriesPages = await Future.wait(
          state.libraries.map(
            (library) => _store.itemsPage(
              libraryID: library.id,
              mediaKind: 'tv',
              limit: previewCount,
              distinctWorks: true,
            ),
          ),
        );
        final movieValues = moviePages.expand((page) => page).toList(growable: false);
        final seriesValues = seriesPages.expand((page) => page).toList(growable: false);
        AppLogger.info(
          'Media',
          '首页预览已加载：全局 ${values.length} 条，电影 ${movieValues.length} 条，剧集 ${seriesValues.length} 条',
        );
        state = state.copyWith(
          allItems: values,
          moviePreviewItems: movieValues,
          seriesPreviewItems: seriesValues,
          allItemsLoaded: false,
          hasMoreContent: false,
        );
      } else {
        final pageSize = StorageManager.configuredMediaLibraryPageSize;
        final page = await _store.itemsPage(
          libraryID: global ? null : selectedID,
          mediaKind: filter == MediaLibraryBrowseFilter.movies
              ? 'movie'
              : filter == MediaLibraryBrowseFilter.series
              ? 'tv'
              : null,
          unmatchedOnly: filter == MediaLibraryBrowseFilter.unmatched,
          search: normalizedSearch,
          limit: pageSize,
          offset: _contentOffset,
          sort: sort,
          direction: direction,
          distinctWorks: true,
        );
        if (serial != _contentLoadSerial || _contentKey != key) return;
        _contentOffset += page.length;
        if (global) {
          state = state.copyWith(
            allItems: [...state.allItems, ...page],
            allItemsLoaded: false,
            hasMoreContent: page.length == pageSize,
          );
        } else {
          state = state.copyWith(
            items: [...state.items, ...page],
            loadedLibraryID: selectedID,
            hasMoreContent: page.length == pageSize,
          );
          if (selectedID != null) {
            unawaited(_hydrateMissingArtwork(selectedID, page));
          }
        }
      }
    } catch (error) {
      if (serial != _contentLoadSerial) return;
      state = state.copyWith(errorMessage: error.toString());
    } finally {
      if (serial == _contentLoadSerial) {
        state = state.copyWith(isLoading: false, isLoadingMore: false);
      }
    }
  }

  Future<void> loadNextContentPage() async {
    if (_nextContentPageInFlight || !state.hasMoreContent) return;
    _nextContentPageInFlight = true;
    try {
      await loadContent(
        home: _contentHome,
        filter: _contentFilter,
        search: _contentSearch,
        reset: false,
      );
    } finally {
      _nextContentPageInFlight = false;
    }
  }

  Future<void> selectLibrary(String id) async {
    final serial = ++_librarySelectionSerial;
    if (!state.libraries.any((library) => library.id == id)) return;
    state = state.copyWith(
      selectedLibraryID: id,
      items: const [],
      clearLoadedLibrary: true,
      allItems: const [],
      allItemsLoaded: false,
      searchQuery: '',
      clearError: true,
    );
    await loadContent(reset: true);
    if (serial != _librarySelectionSerial) return;
  }

  Future<void> createLibrary({
    required String name,
    required String? rootID,
    required String rootPath,
    List<MediaLibrarySource>? sources,
    MediaLibraryKind kind = MediaLibraryKind.mixed,
    bool recursive = true,
    int minimumSizeMB = 50,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final now = DateTime.now();
    final id = now.microsecondsSinceEpoch.toString();
    final library = MediaLibraryDefinition(
      id: id,
      name: trimmed,
      sources:
          sources ??
          [
            MediaLibrarySource(
              id: '$id-source-0',
              rootID: rootID,
              path: rootPath,
            ),
          ],
      kind: kind,
      recursive: recursive,
      minimumSizeMB: minimumSizeMB,
      updatedAt: now,
    );
    await _saveLibraries([library]);
    final libraries = [
      ...state.libraries.where((item) => item.id != library.id),
      library,
    ];
    _librarySelectionSerial += 1;
    _contentLoadSerial += 1;
    state = state.copyWith(
      libraries: libraries,
      selectedLibraryID: library.id,
      items: const [],
      statusMessage: '已创建媒体库「${library.name}」',
    );
  }

  Future<void> deleteLibrary(String id) async {
    if (state.isLibraryScanning(id)) {
      state = state.copyWith(
        statusMessage: '请先停止该媒体库的扫描任务，再删除媒体库',
        clearError: true,
      );
      return;
    }
    // Pre-check: ensure the library actually exists in state; bail early if not.
    if (!state.libraries.any((l) => l.id == id)) {
      state = state.copyWith(
        statusMessage: '媒体库不存在或已被删除',
        clearError: true,
      );
      return;
    }
    try {
      final removedItems = (await _loadAllItems())
          .where((item) => item.libraryID == id)
          .toList(growable: false);
      await _store.deleteLibrary(id);
      final allItems = await _loadAllItems();
      final retainedFileIDs = allItems.map((item) => item.id).toSet();
      final orphanedHistoryIDs = removedItems
          .map((item) => item.id)
          .where((fileID) => !retainedFileIDs.contains(fileID))
          .toSet();
      if (orphanedHistoryIDs.isNotEmpty) {
        try {
          await _removeWatchHistory?.call(orphanedHistoryIDs);
        } catch (error) {
          AppLogger.warning('Media', '媒体库已删除，但观看历史清理失败：$error');
        }
      }
      _librarySelectionSerial += 1;
      final libraries = state.libraries
          .where((library) => library.id != id)
          .toList(growable: false);
      final selectedID = state.selectedLibraryID == id
          ? (libraries.isEmpty ? null : libraries.first.id)
          : state.selectedLibraryID;
      final selectedItems = selectedID == null
          ? const <MediaLibraryItem>[]
          : allItems
                .where((item) => item.libraryID == selectedID)
                .toList(growable: false);
      state = state.copyWith(
        libraries: libraries,
        selectedLibraryID: selectedID,
        clearSelectedLibrary: selectedID == null,
        items: selectedItems,
        allItems: allItems,
        statusMessage: '媒体库已删除',
      );
    } catch (error) {
      AppLogger.warning('Media', '删除媒体库失败：$error');
      state = state.copyWith(
        errorMessage: '删除媒体库失败：$error',
        clearStatus: true,
      );
    }
  }

  Future<void> clearLibrary(String id) async {
    if (state.isLibraryScanning(id)) {
      state = state.copyWith(
        statusMessage: '请先停止该媒体库的扫描任务，再清空',
        clearError: true,
      );
      return;
    }
    final removedItems = (await _loadAllItems())
        .where((item) => item.libraryID == id)
        .toList(growable: false);
    if (removedItems.isEmpty) {
      state = state.copyWith(statusMessage: '媒体库已是空的');
      return;
    }
    await _store.deleteItems(removedItems);
    final allItems = await _loadAllItems();
    final selectedItems = state.selectedLibraryID == id
        ? const <MediaLibraryItem>[]
        : allItems
              .where((item) => item.libraryID == state.selectedLibraryID)
              .toList(growable: false);
    final statistics = await _store.statistics();
    state = state.copyWith(
      items: selectedItems,
      allItems: allItems,
      libraryStatistics: statistics.libraries,
      storedGlobalStatistics: statistics.global,
      statusMessage: '已清空「${state.libraries.firstWhere((l) => l.id == id).name}」的 ${removedItems.length} 条记录',
    );
    AppLogger.info('Media', '清空媒体库 $id：${removedItems.length} 条记录');
  }

  Future<int> removeMediaRecords(Iterable<MediaLibraryItem> values) {
    final requested = values.toList(growable: false);
    if (requested.isEmpty) return Future.value(0);
    final blockedLibrary = requested
        .map((item) => item.libraryID)
        .where(state.isLibraryScanning)
        .firstOrNull;
    if (blockedLibrary != null) {
      state = state.copyWith(
        statusMessage: '请先停止该媒体库的扫描任务，再移除影视记录',
        clearError: true,
      );
      return Future.value(0);
    }

    final completer = Completer<int>();
    _pendingMediaRemovals += 1;
    _mediaRemovalQueue = _mediaRemovalQueue.then((_) async {
      try {
        completer.complete(await _removeMediaRecordsNow(requested));
      } catch (error) {
        state = state.copyWith(
          errorMessage: '移除影视记录失败：$error',
          clearStatus: true,
        );
        completer.complete(0);
      } finally {
        _pendingMediaRemovals -= 1;
      }
    });
    return completer.future;
  }

  Future<int> _removeMediaRecordsNow(List<MediaLibraryItem> requested) async {
    final requestedKeys = <(String, String)>{
      for (final item in requested) (item.libraryID, item.id),
    };
    var removed = 0;

    try {
      final before = await _loadAllItems();
      final existing = before
          .where((item) => requestedKeys.contains((item.libraryID, item.id)))
          .toList(growable: false);
      if (existing.isEmpty) {
        _searchResultsCache.clear();
        final selectedID = state.selectedLibraryID;
        state = state.copyWith(
          items: selectedID == null
              ? const <MediaLibraryItem>[]
              : before
                    .where((item) => item.libraryID == selectedID)
                    .toList(growable: false),
          allItems: before,
          statusMessage: '所选影视记录已不存在',
          clearError: true,
        );
        return 0;
      }

      removed = await _store.deleteItems(existing);
      _searchResultsCache.clear();
      final allItems = await _loadAllItems();
      final selectedID = state.selectedLibraryID;
      final currentItems = selectedID == null
          ? const <MediaLibraryItem>[]
          : allItems
                .where((item) => item.libraryID == selectedID)
                .toList(growable: false);
      final remainingKeys = {
        for (final item in allItems) (item.libraryID, item.id),
      };
      final retainedFileIDs = allItems.map((item) => item.id).toSet();
      final orphanedHistoryIDs = existing
          .where((item) => !remainingKeys.contains((item.libraryID, item.id)))
          .map((item) => item.id)
          .where((id) => !retainedFileIDs.contains(id))
          .toSet();
      Object? historyError;
      if (orphanedHistoryIDs.isNotEmpty && _removeWatchHistory != null) {
        try {
          await _removeWatchHistory(orphanedHistoryIDs);
        } catch (error) {
          historyError = error;
          AppLogger.warning('Media', '影视记录已移除，但观看历史清理失败：$error');
        }
      }

      state = state.copyWith(
        items: currentItems,
        allItems: allItems,
        statusMessage: removed == 0
            ? '所选影视记录已不存在'
            : '已从影视库移除 $removed 条记录，云盘文件未删除',
        errorMessage: historyError == null
            ? null
            : '影视记录已移除，但观看历史清理失败：$historyError',
        clearError: historyError == null,
      );
      return removed;
    } catch (error) {
      if (removed > 0) {
        _searchResultsCache.clear();
        state = state.copyWith(
          statusMessage: '已从影视库移除 $removed 条记录，云盘文件未删除',
          errorMessage: '影视记录已移除，但刷新媒体库状态失败：$error',
        );
        return removed;
      }
      state = state.copyWith(
        errorMessage: '移除影视记录失败：$error',
        clearStatus: true,
      );
      return 0;
    }
  }

  Future<void> updateLibrary(MediaLibraryDefinition library) async {
    if (library.name.trim().isEmpty || library.sources.isEmpty) return;
    if (state.isLibraryScanning(library.id)) {
      state = state.copyWith(
        statusMessage: '请先停止该媒体库的扫描任务，再修改媒体库',
        clearError: true,
      );
      return;
    }
    await _saveLibraries([library]);
    final libraries = state.libraries
        .map((item) => item.id == library.id ? library : item)
        .toList(growable: false);
    state = state.copyWith(
      libraries: libraries,
      statusMessage: '媒体库「${library.name}」已更新',
    );
  }

  Future<void> importScrapedData(String backupPath) async {
    if (state.isLoading || state.hasActiveScans) return;
    state = state.copyWith(
      clearError: true,
      clearStatus: true,
      cloudBackupSync: const CloudBackupSyncProgress(
        phase: '导入中',
        destination: '',
        transferredBytes: 0,
        totalBytes: 0,
        isActive: true,
      ),
    );
    try {
      await _applyImportedBackup(backupPath);
      final fileName = backupPath.split('/').last;
      state = state.copyWith(
        cloudBackupSync: CloudBackupSyncProgress(
          phase: '导入完成',
          destination: fileName,
          transferredBytes: 0,
          totalBytes: 0,
          isActive: false,
        ),
      );
    } catch (error) {
      state = state.copyWith(
        errorMessage: '导入失败：$error',
        cloudBackupSync: const CloudBackupSyncProgress(
          phase: '导入失败',
          destination: '',
          transferredBytes: 0,
          totalBytes: 0,
          isActive: false,
        ),
      );
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> exportScrapedData(String destinationPath) async {
    if (state.isLoading || state.hasActiveScans) return;
    state = state.copyWith(
      clearError: true,
      clearStatus: true,
      cloudBackupSync: const CloudBackupSyncProgress(
        phase: '导出中',
        destination: '',
        transferredBytes: 0,
        totalBytes: 0,
        isActive: true,
      ),
    );
    try {
      await _store.exportBackupTo(destinationPath);
      final fileName = destinationPath.split('/').last;
      state = state.copyWith(
        statusMessage: '刮削数据已导出',
        cloudBackupSync: CloudBackupSyncProgress(
          phase: '导出完成',
          destination: fileName,
          transferredBytes: 0,
          totalBytes: 0,
          isActive: false,
        ),
      );
    } catch (error) {
      state = state.copyWith(
        errorMessage: '导出失败：$error',
        cloudBackupSync: const CloudBackupSyncProgress(
          phase: '导出失败',
          destination: '',
          transferredBytes: 0,
          totalBytes: 0,
          isActive: false,
        ),
      );
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  /// 导出本地 TMDB/豆瓣 works 刮削数据为 JSON 文件（不含影视条目本身）。
  Future<void> exportWorksData(String destinationPath) async {
    if (state.isLoading || state.hasActiveScans) return;
    state = state.copyWith(
      clearError: true,
      clearStatus: true,
      cloudBackupSync: const CloudBackupSyncProgress(
        phase: '导出 works 中',
        destination: '',
        transferredBytes: 0,
        totalBytes: 0,
        isActive: true,
      ),
    );
    try {
      final json = await _store.exportWorksJSON();
      final file = File(destinationPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(json);
      final fileName = destinationPath.split('/').last;
      state = state.copyWith(
        statusMessage: '刮削数据已导出到 $fileName',
        cloudBackupSync: CloudBackupSyncProgress(
          phase: '导出完成',
          destination: fileName,
          transferredBytes: 0,
          totalBytes: 0,
          isActive: false,
        ),
      );
    } catch (error) {
      state = state.copyWith(
        errorMessage: '导出失败：$error',
        cloudBackupSync: const CloudBackupSyncProgress(
          phase: '导出失败',
          destination: '',
          transferredBytes: 0,
          totalBytes: 0,
          isActive: false,
        ),
      );
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  /// 从 JSON 文件导入 TMDB/豆瓣 works 刮削数据（按 tmdb_id/douban_id 去重合并）。
  Future<({int tmdb, int douban})> importWorksData(String sourcePath) async {
    if (state.isLoading || state.hasActiveScans) {
      return (tmdb: 0, douban: 0);
    }
    state = state.copyWith(
      clearError: true,
      clearStatus: true,
      cloudBackupSync: const CloudBackupSyncProgress(
        phase: '导入 works 中',
        destination: '',
        transferredBytes: 0,
        totalBytes: 0,
        isActive: true,
      ),
    );
    try {
      final json = await File(sourcePath).readAsString();
      final result = await _store.importWorksJSON(json);
      final fileName = sourcePath.split('/').last;
      state = state.copyWith(
        statusMessage: '已导入 $fileName（TMDB ${result.tmdb}，豆瓣 ${result.douban}）',
        cloudBackupSync: CloudBackupSyncProgress(
          phase: '导入完成',
          destination: fileName,
          transferredBytes: 0,
          totalBytes: 0,
          isActive: false,
        ),
      );
      return result;
    } catch (error) {
      state = state.copyWith(
        errorMessage: '导入失败：$error',
        cloudBackupSync: const CloudBackupSyncProgress(
          phase: '导入失败',
          destination: '',
          transferredBytes: 0,
          totalBytes: 0,
          isActive: false,
        ),
      );
      return (tmdb: 0, douban: 0);
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> exportScrapedDataToCloud() async {
    if (_api == null || state.isLoading || state.hasActiveScans) {
      _appendBackupLog('跳过同步：API未就绪或扫描进行中');
      return;
    }
    _appendBackupLog('开始备份');
    state = state.copyWith(
      clearError: true,
      clearStatus: true,
      cloudBackupSync: const CloudBackupSyncProgress(
        phase: '备份中',
        destination: '云盘根目录/小黄鸭备份',
        transferredBytes: 0,
        totalBytes: 0,
        isActive: true,
      ),
    );
    Directory? temporaryDirectory;
    try {
      _appendBackupLog('定位云盘备份目录…');
      final destination = await _resolveCloudBackupDestination();
      _appendBackupLog('备份目录：${destination.path}（id=${destination.id})');
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'guangya-media-',
      );
      final backup = File(
        '${temporaryDirectory.path}/${_cloudBackupFileName(DateTime.now())}',
      );
      _appendBackupLog('导出本地数据库到 ${backup.path}');
      await _store.exportBackupTo(backup.path);
      final size = await backup.length();
      _appendBackupLog('已导出 ${FormatBytes.format(size)}，正在上传');
      state = state.copyWith(
        cloudBackupSync: CloudBackupSyncProgress(
          phase: '备份中',
          destination: '${destination.path}/${backup.uri.pathSegments.last}',
          transferredBytes: 0,
          totalBytes: size,
          isActive: true,
        ),
      );
      _appendBackupLog('上传到 ${destination.path}');
      final uploadRate = _BackupTransferRate();
      String? uploadedTaskID;
      try {
        _appendBackupLog(
          '调用 fileUpload：parent=${destination.id}，大小=${FormatBytes.format(size)}',
        );
        await _api!.fileUpload(
          backup,
          parentID: destination.id,
          contentType: 'application/vnd.sqlite3',
          onTaskCreated: (taskID) {
            uploadedTaskID = taskID;
            _appendBackupLog('已创建上传任务：$taskID');
          },
          onProgress: (sent, total) {
            state = state.copyWith(
              cloudBackupSync: CloudBackupSyncProgress(
                phase: '备份中',
                destination:
                    '${destination.path}/${backup.uri.pathSegments.last}',
                transferredBytes: sent,
                totalBytes: total,
                isActive: true,
                bytesPerSecond: uploadRate.update(sent),
              ),
            );
          },
          onProcessing: () {
            final current = state.cloudBackupSync;
            _appendBackupLog('云端处理中（落盘）');
            state = state.copyWith(
              cloudBackupSync: CloudBackupSyncProgress(
                phase: '处理中',
                destination:
                    '${destination.path}/${backup.uri.pathSegments.last}',
                transferredBytes: size,
                totalBytes: size,
                isActive: true,
                bytesPerSecond: current?.bytesPerSecond ?? 0,
              ),
            );
          },
        );
        _appendBackupLog('fileUpload 返回，任务=$uploadedTaskID');
      } catch (uploadError) {
        _appendBackupLog(
          '上传抛错：${uploadError.runtimeType}：$uploadError',
          isError: true,
          error: uploadError,
        );
        // Delete the partially uploaded file on failure
        if (uploadedTaskID != null) {
          try {
            await _api!.deleteUploadTask([uploadedTaskID!]);
            _appendBackupLog('已清理上传残留');
          } catch (cleanupError) {
            _appendBackupLog(
              '清理上传残留失败：$cleanupError',
              isError: true,
              error: cleanupError,
            );
          }
        }
        rethrow;
      }
      final uploadedPath =
          '${destination.path}/${backup.uri.pathSegments.last}';
      state = state.copyWith(
        statusMessage: '刮削数据已同步到：$uploadedPath',
        cloudBackupSync: CloudBackupSyncProgress(
          phase: '同步完成',
          destination: uploadedPath,
          transferredBytes: size,
          totalBytes: size,
          isActive: false,
        ),
      );
      _appendBackupLog('上传完成：$uploadedPath');
    } catch (error) {
      final current = state.cloudBackupSync;
      final destination = current?.destination ?? '云盘根目录/小黄鸭备份';
      final reason = _backupFailureReason(error);
      _appendBackupLog(
        '备份失败：$reason\n原始错误：${error.runtimeType}：$error',
        isError: true,
        error: error,
      );
      state = state.copyWith(
        errorMessage: '同步到云盘失败：$reason',
        cloudBackupSync: CloudBackupSyncProgress(
          phase: '同步失败',
          destination: destination,
          transferredBytes: current?.transferredBytes ?? 0,
          totalBytes: current?.totalBytes ?? 0,
          isActive: false,
          error: reason,
        ),
      );
    } finally {
      if (temporaryDirectory != null && await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    }
  }

  Future<_CloudBackupDestination> _resolveCloudBackupDestination() async {
    const folderName = '小黄鸭备份';
    final existing = await _findCloudBackupDestination();
    if (existing != null) {
      _appendBackupLog('复用已有备份目录：${existing.path}（id=${existing.id})');
      return existing;
    }
    _appendBackupLog('未找到备份目录，创建「$folderName」');
    final folderID = JsonDeep.findString(
      await _api!.fsCreateDir(folderName, parentID: null),
      const ['fileId', 'file_id', 'resId', 'res_id', 'id'],
    );
    if (folderID == null || folderID.isEmpty) {
      throw Exception('无法创建云盘备份目录「$folderName」');
    }
    await StorageManager.set(StorageKeys.cloudScrapedBackupFolderID, folderID);
    _appendBackupLog('已创建云盘备份目录：云盘根目录/$folderName');
    return _CloudBackupDestination(id: folderID, path: '云盘根目录/$folderName');
  }

  Future<_CloudBackupDestination?> _findCloudBackupDestination() async {
    const folderName = '小黄鸭备份';
    final storedID = StorageManager.get<String>(
      StorageKeys.cloudScrapedBackupFolderID,
    )?.trim();
    if (storedID != null && storedID.isNotEmpty) {
      _appendBackupLog('使用已缓存备份目录 id：$storedID');
      return _CloudBackupDestination(id: storedID, path: '云盘根目录/小黄鸭备份');
    }
    _appendBackupLog('未缓存目录 id，列举云盘根目录查找「$folderName」');
    final root = await _api!.fsFiles(parentID: null, pageSize: 1000);
    final existing = _extractFiles(
      root,
    ).where((file) => file.isDirectory && file.name == folderName);
    final folder = existing.isEmpty ? null : existing.first;
    if (folder == null) {
      _appendBackupLog('根目录未找到「$folderName」');
      return null;
    }
    _appendBackupLog('命中目录「$folderName」（id=${folder.id}）');
    await StorageManager.set(StorageKeys.cloudScrapedBackupFolderID, folder.id);
    return _CloudBackupDestination(id: folder.id, path: '云盘根目录/$folderName');
  }

  Future<List<CloudFile>> cloudScrapedBackups() async {
    if (_api == null) return const [];
    _appendBackupLog('查找云盘备份');
    state = state.copyWith(
      clearError: true,
      clearStatus: true,
      cloudBackupSync: const CloudBackupSyncProgress(
        phase: '查找备份',
        destination: '云盘根目录/小黄鸭备份',
        transferredBytes: 0,
        totalBytes: 0,
        isActive: true,
      ),
    );
    try {
      final destination = await _findCloudBackupDestination();
      if (destination == null) {
        _appendBackupLog('未找到备份目录');
        state = state.copyWith(
          cloudBackupSync: const CloudBackupSyncProgress(
            phase: '未找到备份',
            destination: '云盘根目录/小黄鸭备份',
            transferredBytes: 0,
            totalBytes: 0,
            isActive: false,
          ),
        );
        return const [];
      }
      _appendBackupLog('读取备份目录：${destination.path}');
      final response = await _api!.fsFiles(
        parentID: destination.id,
        pageSize: 1000,
      );
      final backups =
          _extractFiles(response)
              .where(
                (file) =>
                    !file.isDirectory &&
                    file.name.toLowerCase().endsWith('.sqlite3'),
              )
              .toList()
            ..sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
      _appendBackupLog('找到 ${backups.length} 个备份');
      state = state.copyWith(
        cloudBackupSync: const CloudBackupSyncProgress(
          phase: '选择备份',
          destination: '云盘根目录/小黄鸭备份',
          transferredBytes: 0,
          totalBytes: 0,
          isActive: false,
        ),
      );
      return backups;
    } catch (error) {
      final reason = _backupFailureReason(error);
      _appendBackupLog('查找云盘备份失败：$reason', isError: true, error: error);
      state = state.copyWith(
        errorMessage: '查找云盘备份失败：$reason',
        cloudBackupSync: CloudBackupSyncProgress(
          phase: '恢复失败',
          destination: '云盘根目录/小黄鸭备份',
          transferredBytes: 0,
          totalBytes: 0,
          isActive: false,
          error: reason,
        ),
      );
      rethrow;
    }
  }

  Future<CloudFile> renameCloudScrapedBackup(
    CloudFile backup,
    String newName,
  ) async {
    if (_api == null) throw StateError('云盘服务未就绪');
    await _api!.fsRename(backup.id, newName);
    _appendBackupLog('备份已重命名：$newName');
    return backup.copyWith(
      name: newName,
      cloudPath: _cloudPathWithName(backup.cloudPath, newName),
    );
  }

  Future<void> deleteCloudScrapedBackup(CloudFile backup) async {
    if (_api == null) throw StateError('云盘服务未就绪');
    await _api!.fsDelete([backup.id]);
    _appendBackupLog('已删除云盘备份：${backup.name}');
  }

  Future<void> importScrapedDataFromCloud(CloudFile backup) async {
    if (_api == null || state.isLoading || state.hasActiveScans) return;
    _appendBackupLog('恢复：${backup.name}');
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      clearStatus: true,
      cloudBackupSync: CloudBackupSyncProgress(
        phase: '恢复中',
        destination: backup.name,
        transferredBytes: 0,
        totalBytes: backup.size ?? 0,
        isActive: true,
      ),
    );
    Directory? temporaryDirectory;
    try {
      final download = await _api!.downloadURL(backup.id);
      final url = _findDownloadUrlDeep(download);
      if (url == null) {
        final fields = _describeDownloadResponse(download);
        _appendBackupLog('下载失败：$fields', isError: true);
        throw Exception('云盘未返回有效下载地址（字段：$fields）');
      }
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'guangya-media-',
      );
      final localBackup = File(
        '${temporaryDirectory.path}/media-library.sqlite3',
      );
      _appendBackupLog('下载备份：${backup.name}');
      final downloadRate = _BackupTransferRate();
      final fileSize = backup.size ?? 0;
      if (fileSize > 4 * 1024 * 1024) {
        // Parallel chunk download for files > 4 MB
        await _parallelDownload(
          url: url,
          destination: localBackup.path,
          totalBytes: fileSize,
          onProgress: (received) {
            state = state.copyWith(
              cloudBackupSync: CloudBackupSyncProgress(
                phase: '恢复中',
                destination: backup.name,
                transferredBytes: received,
                totalBytes: fileSize > 0 ? fileSize : (backup.size ?? 0),
                isActive: true,
                bytesPerSecond: downloadRate.update(received),
              ),
            );
          },
          logPrefix: '备份下载',
        );
      } else {
        await Dio().download(
          url,
          localBackup.path,
          onReceiveProgress: (received, total) {
            state = state.copyWith(
              cloudBackupSync: CloudBackupSyncProgress(
                phase: '恢复中',
                destination: backup.name,
                transferredBytes: received,
                totalBytes: total > 0 ? total : (backup.size ?? 0),
                isActive: true,
                bytesPerSecond: downloadRate.update(received),
              ),
            );
          },
        );
      }
      _appendBackupLog('下载完成，覆盖本地数据库');
      state = state.copyWith(
        cloudBackupSync: CloudBackupSyncProgress(
          phase: '处理中',
          destination: backup.name,
          transferredBytes: 0,
          totalBytes: 0,
          isActive: true,
        ),
      );
      // 第一步：下载完成，不自动覆盖本地数据。保留临时文件供弹窗确认后应用。
      _pendingImportedBackupPath = localBackup.path;
      _pendingImportedBackupName = backup.name;
      _pendingImportedBackupSize = backup.size ?? 0;
      _pendingImportedTempDir = temporaryDirectory;
      _appendBackupLog('下载完成，等待确认是否恢复（会清空本地数据）');
      state = state.copyWith(
        statusMessage: '备份已下载，等待确认恢复',
        cloudBackupSync: CloudBackupSyncProgress(
          phase: '等待确认',
          destination: backup.name,
          transferredBytes: backup.size ?? 0,
          totalBytes: backup.size ?? 0,
          isActive: false,
        ),
      );
    } catch (error) {
      final current = state.cloudBackupSync;
      final reason = _backupFailureReason(error);
      _appendBackupLog('从云盘下载备份失败：$reason', isError: true, error: error);
      state = state.copyWith(
        errorMessage: '从云盘下载备份失败：$reason',
        cloudBackupSync: CloudBackupSyncProgress(
          phase: '下载失败',
          destination: backup.name,
          transferredBytes: current?.transferredBytes ?? 0,
          totalBytes: current?.totalBytes ?? (backup.size ?? 0),
          isActive: false,
          error: reason,
        ),
      );
    } finally {
      // 不删临时目录——applyDownloadedBackup 或放弃恢复时才清理。
      state = state.copyWith(isLoading: false);
    }
  }

  /// 下载完成待应用的备份路径与元数据。null 表示无待恢复备份。
  String? _pendingImportedBackupPath;
  String? _pendingImportedBackupName;
  int _pendingImportedBackupSize = 0;
  Directory? _pendingImportedTempDir;

  /// 当前是否有下载完成、等待确认恢复的备份。
  bool get hasPendingBackup => _pendingImportedBackupPath != null;

  /// 放弃已下载的备份：删除临时文件并清标记。
  Future<void> discardDownloadedBackup() async {
    final path = _pendingImportedBackupPath;
    final tempDir = _pendingImportedTempDir;
    _pendingImportedBackupPath = null;
    _pendingImportedBackupName = null;
    _pendingImportedBackupSize = 0;
    _pendingImportedTempDir = null;
    if (path != null) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    if (tempDir != null && await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
    _appendBackupLog('已放弃恢复，删除下载的备份文件');
    state = state.copyWith(
      statusMessage: '已放弃恢复',
      cloudBackupSync: const CloudBackupSyncProgress(
        phase: '已放弃',
        destination: '',
        transferredBytes: 0,
        totalBytes: 0,
        isActive: false,
      ),
    );
  }

  /// 第二步：确认恢复——用已下载的备份覆盖本地数据库并重新加载。
  /// 调用前应通过 UI 弹窗明确告知用户"会清空本地数据"。
  Future<void> applyDownloadedBackup() async {
    final path = _pendingImportedBackupPath;
    final name = _pendingImportedBackupName ?? '备份';
    final size = _pendingImportedBackupSize;
    final tempDir = _pendingImportedTempDir;
    if (path == null) {
      _appendBackupLog('无待恢复的备份', isError: true);
      return;
    }
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      clearStatus: true,
      cloudBackupSync: CloudBackupSyncProgress(
        phase: '恢复中',
        destination: name,
        transferredBytes: 0,
        totalBytes: size,
        isActive: true,
      ),
    );
    try {
      await _applyImportedBackup(path);
      _appendBackupLog('恢复完成：$name');
      state = state.copyWith(
        cloudBackupSync: CloudBackupSyncProgress(
          phase: '恢复完成',
          destination: name,
          transferredBytes: size,
          totalBytes: size,
          isActive: false,
        ),
      );
    } catch (error) {
      final reason = _backupFailureReason(error);
      _appendBackupLog('恢复失败：$reason', isError: true, error: error);
      state = state.copyWith(
        errorMessage: '恢复失败：$reason',
        cloudBackupSync: CloudBackupSyncProgress(
          phase: '恢复失败',
          destination: name,
          transferredBytes: 0,
          totalBytes: size,
          isActive: false,
          error: reason,
        ),
      );
    } finally {
      // 应用完成后清理临时文件与标记。
      _pendingImportedBackupPath = null;
      _pendingImportedBackupName = null;
      _pendingImportedBackupSize = 0;
      _pendingImportedTempDir = null;
      if (tempDir != null && await tempDir.exists()) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> _applyImportedBackup(String backupPath) async {
    final stats = await _store.importBackup(backupPath);
    // Force a full reload: reset _loaded so load() re-reads everything from DB.
    _loaded = false;
    await load();
    await loadContent(home: true, reset: true, force: true);
    state = state.copyWith(
      statusMessage: '刮削数据已覆盖，已回收 ${FormatBytes.format(stats.reclaimedBytes)}',
    );
  }

  /// Parallel chunk download — splits [totalBytes] into [concurrency] chunks
  /// and downloads them concurrently, then merges into [destination].
  /// Falls back to single connection if the server doesn't support Range.
  static const int _chunkSize = 4 * 1024 * 1024; // 4 MB per chunk
  static const int _concurrency = 8;

  Future<void> _parallelDownload({
    required String url,
    required String destination,
    required int totalBytes,
    required void Function(int receivedBytes) onProgress,
    String logPrefix = '下载',
  }) async {
    final chunkCount = (totalBytes / _chunkSize).ceil();
    final actualConcurrency = chunkCount.clamp(1, _concurrency);
    _appendBackupLog(
      '$logPrefix：${FormatBytes.format(totalBytes)}，'
      '$actualConcurrency 路并发',
    );

    // Probe: try a small Range request to see if the server supports it.
    // 用 bytes=0-0 只请求 1 字节，避免 Dio 完整下载整个响应体；ResponseType.bytes
    // 让 Dio 不缓冲完整 body，服务端支持 Range 时返回 206。
    final probeDio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        headers: {'Range': 'bytes=0-0'},
        responseType: ResponseType.bytes,
      ),
    );
    try {
      final probe = await probeDio.get<Uint8List>(url);
      if (probe.statusCode != 206) {
        // Server doesn't support Range — fall back to single connection.
        _appendBackupLog('$logPrefix：服务器不支持分片（${probe.statusCode}），退回单连接');
        await _singleDownload(
          url: url,
          destination: destination,
          onProgress: onProgress,
        );
        return;
      }
    } on DioException catch (probeError) {
      // Range not supported or network issue — fall back to single.
      _appendBackupLog(
        '$logPrefix：Range 探测失败（${probeError.type}：${probeError.message}），退回单连接',
        isError: true,
        error: probeError,
      );
      await _singleDownload(
        url: url,
        destination: destination,
        onProgress: onProgress,
      );
      return;
    } finally {
      probeDio.close(force: true);
    }

    // Split into chunks and download concurrently.
    final tempDir = await Directory.systemTemp.createTemp('guangya-dl-');
    final chunkPaths = <String>[];
    // Per-chunk received counters for accurate progress tracking.
    final chunkReceived = List<int>.filled(chunkCount, 0);
    int totalReceived = 0;

    Future<void> downloadChunk(int index) async {
      final start = index * _chunkSize;
      final end = (start + _chunkSize - 1).clamp(0, totalBytes - 1);
      final chunkPath = '${tempDir.path}/chunk_$index';
      chunkPaths.add(chunkPath);
      final chunkDio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(minutes: 10),
        ),
      );
      await chunkDio.download(
        url,
        chunkPath,
        options: Options(headers: {'Range': 'bytes=$start-$end'}),
        onReceiveProgress: (received, _) {
          final prev = chunkReceived[index];
          chunkReceived[index] = received;
          totalReceived += received - prev;
          onProgress(totalReceived);
        },
      );
      // chunk 下载完后把该 chunk 标记为已收满，避免合并前 onProgress 漏算
      // 最后一批 bytes；同时重置 chunkReceived[index] 防止重试时重复累加。
      final prev = chunkReceived[index];
      final chunkLength = (end - start + 1);
      if (prev < chunkLength) {
        chunkReceived[index] = chunkLength;
        totalReceived += chunkLength - prev;
        onProgress(totalReceived);
      }
    }

    try {
      // Launch chunks in batches of [_concurrency].
      for (var i = 0; i < chunkCount; i += actualConcurrency) {
        final batch = <Future<void>>[];
        for (var j = i; j < (i + actualConcurrency) && j < chunkCount; j++) {
          batch.add(downloadChunk(j));
        }
        await Future.wait(batch);
        // 每个 batch 完成后汇报一次累计进度（已收字节，由各 chunk 回调维护）。
        onProgress(totalReceived.clamp(0, totalBytes));
      }

      // Merge chunks into final file.
      final sink = File(destination).openSync(mode: FileMode.write);
      try {
        for (var i = 0; i < chunkCount; i++) {
          final chunkFile = File(chunkPaths[i]);
          if (await chunkFile.exists()) {
            sink.writeFromSync(await chunkFile.readAsBytes());
          }
        }
      } finally {
        await sink.close();
      }
    } finally {
      // Clean up temp chunks.
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }

    _appendBackupLog('$logPrefix完成：${FormatBytes.format(totalBytes)}');
  }

  Future<void> _singleDownload({
    required String url,
    required String destination,
    required void Function(int receivedBytes) onProgress,
  }) async {
    await Dio().download(
      url,
      destination,
      onReceiveProgress: (received, _) {
        // Dio download 的 received 是本次累计已收字节，直接传出即可，
        // 不要再累加（之前 received += got 会重复计数导致进度远超实际）。
        onProgress(received);
      },
    );
  }

  Future<void> optimizeLocalStorage() async {
    if (state.isLoading || state.hasActiveScans) return;
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      clearStatus: true,
    );
    try {
      final stats = await _store.optimizeStorage();
      state = state.copyWith(
        statusMessage: stats.removedArtworkCount == 0
            ? '本地刮削数据库已是最优状态'
            : '已清理 ${stats.removedArtworkCount} 条本地图片缓存，回收 ${FormatBytes.format(stats.reclaimedBytes)}',
      );
    } catch (error) {
      state = state.copyWith(errorMessage: '数据库优化失败：$error');
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  void _updateScanTask(
    String taskID, {
    MediaLibraryScanTaskStatus? status,
    MediaLibraryScanProgress? progress,
    String? log,
    bool isError = false,
    String? failureReason,
    bool clearFailure = false,
  }) {
    final current = state.taskByID(taskID);
    if (current == null) return;
    var logs = current.logs;
    if (log != null) {
      logs = [
        ...logs,
        MediaLibraryScanLog(
          createdAt: DateTime.now(),
          message: log,
          isError: isError,
        ),
      ];
      if (logs.length > 240) {
        logs = logs.sublist(logs.length - 240);
      }
    }
    final updated = current.copyWith(
      status: status,
      progress: progress,
      logs: logs,
      updatedAt: DateTime.now(),
      failureReason: failureReason,
      clearFailure: clearFailure,
    );
    state = state.copyWith(
      scanTasks: [
        for (final task in state.scanTasks)
          if (task.id == taskID) updated else task,
      ],
    );
    unawaited(_persistScanTaskHistory());
    if (isError) {
      AppLogger.error('Media', log ?? failureReason ?? '媒体库任务失败');
    } else if (log != null) {
      AppLogger.info('Media', log);
    }
  }

  void _setScanProgress(String libraryID, MediaLibraryScanProgress progress) {
    final task = state.taskForLibrary(libraryID);
    if (task == null) return;
    _updateScanTask(task.id, progress: progress);
  }

  bool _scanShouldAbort(String libraryID) =>
      _cancelledScanLibraries.contains(libraryID) ||
      _stoppedScanLibraries.contains(libraryID);

  Future<bool> _waitIfScanPaused(String libraryID) async {
    if (_scanShouldAbort(libraryID)) return false;
    while (_pausedScanLibraries.contains(libraryID)) {
      final gate = _scanPauseGates.putIfAbsent(
        libraryID,
        () => Completer<void>(),
      );
      await gate.future;
      if (_scanShouldAbort(libraryID)) return false;
    }
    return !_scanShouldAbort(libraryID);
  }

  void _releaseScanPauseGate(String libraryID) {
    _scanPauseGates.remove(libraryID)?.complete();
  }

  /// Clears the title-level search memo so a new scan does not accidentally
  /// reuse stale results from a previous run.
  void _clearRecognitionSearchCache() {
    _recognitionSearchCache.clear();
  }

  /// Cache key for title-level search results.
  String _searchCacheKey(
    List<_MediaTitleVariant> variants,
    String mediaKind,
    int? year,
    String apiKey,
    bool douban,
  ) {
    final variantKey = variants.map((v) => '${v.source}:${v.value}').join('|');
    return '$variantKey#$mediaKind#${year ?? '_'}#$apiKey#${douban ? '1' : '0'}';
  }

  /// Waits up to [duration], but returns early as soon as the scan for
  /// [libraryID] is cancelled or stopped. Polling keeps this dependency-free
  /// while making cancellation feel immediate during retry backoffs.
  Future<void> _abortableDelay(String libraryID, Duration duration) async {
    const tick = Duration(milliseconds: 200);
    var waited = Duration.zero;
    while (waited < duration) {
      if (_scanShouldAbort(libraryID)) return;
      final step = duration - waited < tick ? duration - waited : tick;
      await Future<void>.delayed(step);
      waited += step;
    }
  }

  /// Picks the scan mode used when a stopped task is resumed.
  ///
  /// A stopped run already walked the cloud directories and persisted the file
  /// index, so re-running `forceAll` would redo that whole traversal — which is
  /// exactly the "resume restarts from scratch" symptom. Once any file has been
  /// indexed we downgrade to recognition-only so the run picks up at the first
  /// still-unrecognised item.
  MediaLibraryScanMode _resumeModeFor(MediaLibraryScanTask task) {
    final indexedSomething =
        task.progress.completed > 0 || task.progress.scanned > 0;
    if (!indexedSomething) return task.mode;
    switch (task.mode) {
      case MediaLibraryScanMode.forceAll:
      case MediaLibraryScanMode.unindexedOnly:
        return MediaLibraryScanMode.unrecognizedOnly;
      case MediaLibraryScanMode.unrecognizedOnly:
        return MediaLibraryScanMode.unrecognizedOnly;
    }
  }

  List<MediaLibraryScanTask> _loadScanTaskHistory() {
    final raw = StorageManager.get<dynamic>(StorageKeys.mediaScanTaskHistory);
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map(
          (entry) =>
              MediaLibraryScanTask.fromJson(Map<String, dynamic>.from(entry)),
        )
        .where((task) => task.libraryID.isNotEmpty)
        .take(80)
        .toList(growable: false);
  }

  Future<void> _persistScanTaskHistory() {
    final snapshot = state.scanTasks
        .take(80)
        .map((task) => task.toJson())
        .toList(growable: false);
    _scanTaskHistoryPersistence = _scanTaskHistoryPersistence
        .catchError((_) {})
        .then(
          (_) => StorageManager.set(StorageKeys.mediaScanTaskHistory, snapshot),
        )
        .catchError((error) {
          AppLogger.warning('Media', '刮削任务历史保存失败：$error');
        });
    return _scanTaskHistoryPersistence;
  }

  Future<void> scanLibrary(
    String libraryID, {
    MediaLibraryScanMode mode = MediaLibraryScanMode.unrecognizedOnly,
  }) async {
    final library = state.libraries
        .where((candidate) => candidate.id == libraryID)
        .firstOrNull;
    if (library == null || _api == null || state.isLibraryScanning(libraryID)) {
      return;
    }
    _cancelledScanLibraries.remove(libraryID);
    _stoppedScanLibraries.remove(libraryID);
    _pausedScanLibraries.remove(libraryID);
    _releaseScanPauseGate(libraryID);
    _clearRecognitionSearchCache();
    final task = MediaLibraryScanTask.create(library: library, mode: mode);
    state = state.copyWith(
      scanTasks: [task, ...state.scanTasks.where((item) => item.id != task.id)],
      clearError: true,
      clearStatus: true,
    );
    unawaited(_persistScanTaskHistory());
    final run = runZoned(
      () => _runLibraryScan(library, taskID: task.id, mode: mode),
      zoneValues: {_mediaScanTaskZoneKey: task.id},
    );
    _scanRuns[libraryID] = run;
    await run;
    if (identical(_scanRuns[libraryID], run)) _scanRuns.remove(libraryID);
  }

  /// Scans only the folders configured by the selected media library. A
  /// rescan bypasses the directory cache, but deliberately never falls back
  /// to the account-wide cloud index: that index is slow and cannot provide
  /// useful per-library progress or cancellation.
  Future<void> scanSelectedLibrary({
    MediaLibraryScanMode mode = MediaLibraryScanMode.unrecognizedOnly,
  }) async {
    final libraryID = state.selectedLibraryID;
    if (libraryID == null) return;
    await scanLibrary(libraryID, mode: mode);
  }

  Future<void> _runLibraryScan(
    MediaLibraryDefinition library, {
    required String taskID,
    required MediaLibraryScanMode mode,
  }) async {
    _cachedCloudEntries = null;
    if (_pendingMediaRemovals > 0) {
      _updateScanTask(
        taskID,
        status: MediaLibraryScanTaskStatus.stopped,
        progress: const MediaLibraryScanProgress(phase: '等待移除影视记录完成'),
        log: '正在移除影视记录，任务未启动',
      );
      state = state.copyWith(
        statusMessage: '正在移除影视记录，请稍后开始扫描',
        clearError: true,
      );
      return;
    }
    final forceAll = mode.refreshesFileIndex;
    final modeLabel = forceAll ? '强制全部重新识别' : '仅扫描未识别资源';

    _updateScanTask(
      taskID,
      status: MediaLibraryScanTaskStatus.running,
      progress: const MediaLibraryScanProgress(phase: '准备扫描'),
      log: '开始$modeLabel：「${library.name}」',
      clearFailure: true,
    );

    try {
      AppLogger.info('Media', '$modeLabel [1/5] 清理光盘目录内部文件');
      final removedDiscStreams = await _removeDiscInternalItems();
      if (removedDiscStreams > 0) {
        _appendScanLog('已清理 $removedDiscStreams 个已入库的光盘目录内部文件');
      }
      AppLogger.info('Media', '$modeLabel [2/5] 加载已有条目');
      final previousLibraryItems = await _loadItems(library.id);
      final existingByID = {
        for (final item in previousLibraryItems) item.id: item,
      };
      final existingByGCID = {
        for (final item in previousLibraryItems)
          if (item.file.gcid?.isNotEmpty == true) item.file.gcid!: item,
      };
      final unique = <String, MediaLibraryItem>{
        if (!forceAll)
          for (final item in previousLibraryItems) item.id: item,
      };
      final tmdbApiKey =
          StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
      final tmdbProxyHost =
          StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '';
      final tmdbProxyPort =
          StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '';
      var completed = 0;
      Future<void> pendingPersistence = Future.value();
      // Throttle the two most expensive per-item side effects during a scan:
      //   1. Persisting each recognized item as its own SQLite transaction.
      //   2. Rebuilding + sorting the entire visible list on every file, which
      //      is O(N log N) per item → O(N² log N) for a large library.
      // Instead we buffer upserts and only flush / refresh the UI every
      // [_scanFlushCount] items or [_scanFlushInterval], cutting transaction
      // count and eliminating the quadratic re-sort blowup.
      const scanFlushCount = 50;
      const scanFlushInterval = Duration(milliseconds: 600);
      final pendingUpserts = <MediaLibraryItem>[];
      var lastUiRefresh = DateTime.fromMillisecondsSinceEpoch(0);
      Future<void> flushPendingUpserts({bool force = false}) async {
        if (pendingUpserts.isEmpty) return;
        if (!force && pendingUpserts.length < scanFlushCount) return;
        final batch = List<MediaLibraryItem>.of(pendingUpserts);
        pendingUpserts.clear();
        pendingPersistence = pendingPersistence.then(
          (_) => _upsertItems(batch),
        );
        await pendingPersistence;
      }
      final seriesMatches = <String, MediaLibraryItem>{};
      final knownMatches = MediaKnownMatchIndex(previousLibraryItems);
      if (!forceAll) {
        for (final item in previousLibraryItems) {
          final key = _seriesRecognitionKey(item);
          if (key != null && item.isMatched) {
            seriesMatches.putIfAbsent(key, () => item);
          }
        }
      }
      // Multiple episodes in one directory are discovered together, and the
      // scanner processes that batch concurrently. Keep the first TMDB
      // recognition in flight so siblings wait for it instead of starting
      // duplicate TMDB requests before [seriesMatches] has been populated.
      final seriesRecognitionTasks = <String, Future<MediaLibraryItem>>{};

      MediaLibraryItem applySeriesMetadata(
        MediaLibraryItem matched,
        MediaLibraryItem target,
      ) {
        // Scraped show metadata is shared by episodes, but technical flags are
        // properties of each individual file and must not be copied from the
        // episode that happened to match first.
        return matched.copyWith(
          file: target.file,
          hasChineseAudio: target.hasChineseAudio,
          hasChineseSubtitle: target.hasChineseSubtitle,
          updatedAt: DateTime.now(),
        );
      }

      final concurrency =
          (int.tryParse(
                    StorageManager.get<String>(
                          StorageKeys.mediaScanConcurrency,
                        ) ??
                        '6',
                  ) ??
                  6)
              .clamp(1, 20);
      final recognitionQueue = <CloudFile>[];
      final queuedRecognitionIDs = <String>{};
      Future<void> recognitionTail = Future.value();
      var recognizedCount = 0;
      var unmatchedCount = 0;
      var skippedCount = 0;
      var discoveredCount = 0;
      // Rows matched with deferred details, drained by the detail consumer.
      final deferredDetailItems = <MediaLibraryItem>[];
      var nextDetail = 0;
      var detailPhaseDone = false;
      // 详情补全按作品去重，攒批提交以摊薄每批的数据库/网络开销。
      const detailBatchSize = 100;
      _appendScanLog('$modeLabel，媒体识别并发数：$concurrency');
      final doubanAutoRecognition = _doubanAutoRecognitionEnabled;
      if (tmdbApiKey.trim().isEmpty && doubanAutoRecognition) {
        _appendScanLog('未配置 TMDB API Key，本次使用豆瓣自动识别');
      } else if (tmdbApiKey.trim().isEmpty) {
        _appendScanLog('未配置 TMDB API Key，且豆瓣自动识别已关闭');
      }

      Future<void> indexBatch(List<CloudFile> files) async {
        final pending = files.toList();
        if (pending.isEmpty || _scanShouldAbort(library.id)) return;
        // 本地预筛是纯 SQLite 查询，可用更高并发；远程 API 沿用用户并发。
        final localConcurrency = (concurrency * 4).clamp(4, 40);
        // 本地预筛未命中（需远程 API 识别）的文件，由远程消费者流水线消费。
        final remotePending = <CloudFile>[];
        var nextLocal = 0;
        var nextRemote = 0;
        var localPhaseDone = false;
        Future<void> worker(bool localStage) async {
          while (!_scanShouldAbort(library.id)) {
            // Claim the index synchronously before any await so that two
            // workers cannot both read the same slot (fixes RangeError
            // when _waitIfScanPaused yields the event loop).
            late final CloudFile file;
            if (localStage) {
              if (nextLocal >= pending.length) break;
              final idx = nextLocal++;
              if (!await _waitIfScanPaused(library.id)) return;
              file = pending[idx];
            } else {
              if (nextRemote >= remotePending.length) {
                if (localPhaseDone) break;
                await Future<void>.delayed(const Duration(milliseconds: 20));
                continue;
              }
              final idx = nextRemote++;
              if (!await _waitIfScanPaused(library.id)) return;
              file = remotePending[idx];
            }
            final fallback = MediaLibraryItem.fromFile(
              library.id,
              file,
              directoryName: _parentDirectoryName(file.cloudPath),
            );
            final seriesKey = _seriesRecognitionKey(fallback);
            final existing =
                unique[file.id] ??
                existingByID[file.id] ??
                (file.gcid?.isNotEmpty == true
                    ? existingByGCID[file.gcid!]
                    : null);
            final sameCloudResource =
                existing != null &&
                (existing.id == file.id ||
                    (file.gcid?.isNotEmpty == true &&
                        file.gcid == existing.file.gcid));
            // Keep complete entries during a rescan. New resources and rows
            // missing scraped metadata follow the same automatic recognition,
            // detail hydration and canonical naming path as detail-page media
            // recognition.
            final shouldRecognize = shouldRecognizeMediaScanItem(
              mode: mode,
              existing: existing,
              sameCloudResource: sameCloudResource,
            );
            // An already complete record that this run does not need to touch
            // counts as skipped rather than freshly recognised.
            if (!shouldRecognize && existing != null && existing.isMatched) {
              skippedCount += 1;
            }
            var item =
                existing?.copyWith(file: file, updatedAt: DateTime.now()) ??
                fallback;
            final cachedSeriesMatch = seriesKey == null
                ? null
                : seriesMatches[seriesKey];
            final parsedFallback = ParsedMediaName.parse(
              fallback.file.name,
              directoryName: _parentDirectoryName(fallback.file.cloudPath),
              directoryPath: fallback.file.cloudPath,
            );
            final knownSeriesMatch = seriesKey == null
                ? null
                : knownMatches.resolve(
                    title: parsedFallback.title,
                    mediaKind: TMDBMediaKind.tv,
                    year: parsedFallback.year,
                  );
            final reusableSeriesMatch = cachedSeriesMatch ?? knownSeriesMatch;
            if (reusableSeriesMatch != null) {
              item = applySeriesMetadata(reusableSeriesMatch, item);
              if (cachedSeriesMatch == null) {
                seriesMatches[seriesKey!] = reusableSeriesMatch;
              }
            } else if (shouldRecognize) {
              if (seriesKey == null) {
                item = await _recognizeMediaItem(
                  fallback,
                  tmdbApiKey,
                  proxyHost: tmdbProxyHost,
                  proxyPort: tmdbProxyPort,
                  deferDetails: true,
                  localOnly: localStage,
                );
              } else {
                final inFlight = seriesRecognitionTasks[seriesKey];
                late final MediaLibraryItem recognized;
                if (inFlight != null) {
                  final shared = await inFlight;
                  recognized =
                      shared.tmdbID != null &&
                          shared.mediaKind == TMDBMediaKind.tv
                      ? shared
                      : await _recognizeMediaItem(
                          fallback,
                          tmdbApiKey,
                          proxyHost: tmdbProxyHost,
                          proxyPort: tmdbProxyPort,
                          deferDetails: true,
                          localOnly: localStage,
                        );
                } else {
                  final task = _recognizeMediaItem(
                    fallback,
                    tmdbApiKey,
                    proxyHost: tmdbProxyHost,
                    proxyPort: tmdbProxyPort,
                    deferDetails: true,
                    localOnly: localStage,
                  );
                  seriesRecognitionTasks[seriesKey] = task;
                  recognized = await task;
                }
                if (inFlight == null) {
                  // The first episode owns this request. Remove failed tasks
                  // so a differently named sibling can still try a fallback
                  // match, while successful matches stay in seriesMatches.
                  seriesRecognitionTasks.remove(seriesKey);
                }
                if (recognized.tmdbID != null &&
                    recognized.mediaKind == TMDBMediaKind.tv) {
                  seriesMatches[seriesKey] = recognized;
                  item = applySeriesMetadata(recognized, item);
                } else {
                  item = recognized.copyWith(
                    file: file,
                    updatedAt: DateTime.now(),
                  );
                }
              }
            }
            if (_scanShouldAbort(library.id)) return;
            // 本地预筛阶段：本地 works 表未命中 → 放入远程识别队列，
            // 由远程消费者流水线消费（不在此处入库/计数）。
            if (localStage && !item.isMatched && item.tmdbID == null) {
              remotePending.add(file);
              continue;
            }
            // Do not lose an existing match solely because a transient TMDB
            // lookup failed while filling an incomplete record.
            if (item.tmdbID == null && existing?.tmdbID != null) {
              item = existing!.copyWith(file: file, updatedAt: DateTime.now());
            }
            if (seriesKey != null &&
                item.tmdbID != null &&
                item.mediaKind == TMDBMediaKind.tv) {
              seriesMatches[seriesKey] = item;
              knownMatches.add(item);
            }
            item = await _renameMatchedMediaFile(item);
            if (_scanShouldAbort(library.id)) return;
            unique[file.id] = item;
            completed += 1;
            if (item.isMatched) {
              recognizedCount += 1;
              if (item.needsDetailHydration) deferredDetailItems.add(item);
            } else {
              unmatchedCount += 1;
            }
            // Buffer the write; flush in batches instead of one txn per item.
            pendingUpserts.add(item);
            await flushPendingUpserts();
            final progress = MediaLibraryScanProgress(
              phase: '正在识别 ${file.name}',
              completed: completed,
              total: discoveredCount,
              scanned: discoveredCount,
              pending: (discoveredCount - completed).clamp(0, discoveredCount),
              matched: recognizedCount,
              unmatched: unmatchedCount,
              skipped: skippedCount,
            );
            _setScanProgress(library.id, progress);
            // Only rebuild + sort the visible list (O(N log N)) periodically,
            // not on every single file. Time-based throttle keeps the UI live
            // without the quadratic cost on large libraries.
            final now = DateTime.now();
            if (state.selectedLibraryID == library.id &&
                now.difference(lastUiRefresh) >= scanFlushInterval) {
              lastUiRefresh = now;
              final visible = unique.values.toList()
                ..sort(
                  (a, b) =>
                      a.title.toLowerCase().compareTo(b.title.toLowerCase()),
                );
              state = state.copyWith(items: visible);
            }
            _appendScanLog(
              !item.isMatched
                  ? '已入库：${file.name}（未匹配）'
                  : item.file.name == file.name
                  ? '已识别并入库：${file.name} → ${item.title}'
                  : '已识别并重命名：${file.name} → ${item.file.name}',
            );
          }
        }

        // 本地预筛与远程识别并行启动（流水线）：本地未命中的文件
        // 进入 remotePending 后立即被远程 worker 消费，无需等待本地全部结束。
        final localWorkers = List.generate(
          localConcurrency,
          (_) => worker(true),
        );
        final remoteWorkers = List.generate(
          concurrency,
          (_) => worker(false),
        );
        await Future.wait(localWorkers);
        localPhaseDone = true;
        await Future.wait(remoteWorkers);
      }

      // 详情补全消费者：与识别批次并行运行，识别一产出带 tmdbID 且需补
      // 详情的条目即按作品去重批量拉取详情并入库，无需等识别全部结束。
      Future<void> detailConsumer(int id) async {
        while (!_scanShouldAbort(library.id)) {
          if (!await _waitIfScanPaused(library.id)) return;
          if (nextDetail >= deferredDetailItems.length) {
            if (detailPhaseDone) break;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            continue;
          }
          final end = (nextDetail + detailBatchSize)
              .clamp(0, deferredDetailItems.length);
          final batch = deferredDetailItems.sublist(nextDetail, end);
          nextDetail = end;
          if (batch.isEmpty) continue;
          try {
            final hydrated = await _hydrateDeferredDetails(
              batch,
              apiKey: tmdbApiKey,
              proxyHost: tmdbProxyHost,
              proxyPort: tmdbProxyPort,
              libraryID: library.id,
              concurrency: concurrency,
            );
            // Fold hydrated rows back into the set that gets persisted below.
            for (final item in hydrated) {
              if (unique.containsKey(item.id)) unique[item.id] = item;
            }
          } catch (e) {
            AppLogger.warning('Media', '详情补全失败（跳过批次）：$e');
          }
        }
      }

      int scheduledRecognitionBatches = 0;
      const recognitionBatchSize = 50;

      void scheduleRecognitionBatch(List<CloudFile> batch) {
        scheduledRecognitionBatches += 1;
        recognitionTail = recognitionTail.then((_) async {
          try {
            await indexBatch(batch);
          } finally {
            scheduledRecognitionBatches -= 1;
          }
        });
      }

      Future<void> enqueueForRecognition(List<CloudFile> files) async {
        if (_scanShouldAbort(library.id)) return;
        if (!await _waitIfScanPaused(library.id)) return;
        for (final file in files) {
          // 双重去重：既检查队列，也检查已发现的文件
          if (queuedRecognitionIDs.add(file.id)) {
            recognitionQueue.add(file);
            discoveredCount += 1;
          }
        }
        // 只要队列达到批次大小就触发批处理
        if (recognitionQueue.length >= recognitionBatchSize) {
          final batch = recognitionQueue.take(recognitionBatchSize).toList();
          recognitionQueue.removeRange(0, batch.length);
          scheduleRecognitionBatch(batch);
          if (scheduledRecognitionBatches >= 1) await recognitionTail;
        }
      }

      Future<void> flushRecognitionQueue() async {
        // 将剩余所有文件一次性处理
        if (recognitionQueue.isNotEmpty) {
          final batch = recognitionQueue.toList();
          recognitionQueue.clear();
          scheduleRecognitionBatch(batch);
          // 等待批处理完成后再返回
          await recognitionTail;
        }
      }

      // 详情补全消费者与识别批次并行启动：识别一旦产出带 tmdbID 且需补
      // 详情的条目，detailConsumer 立即批量拉取详情并入库。
      final detailConsumers = List.generate(
        concurrency.clamp(1, 4),
        (i) => detailConsumer(i + 1),
      );

      if (forceAll && !_scanShouldAbort(library.id)) {
        _appendScanLog('正在强制刷新当前媒体库目录…');
        AppLogger.info('Media', '$modeLabel [3/5] 开始扫描目录源，并发=$concurrency');
        _setScanProgress(
          library.id,
          const MediaLibraryScanProgress(phase: '正在读取当前媒体库目录'),
        );
        List<CloudFile> mediaFiles;
        try {
          mediaFiles = await _scanLibrarySourcesConcurrently(
            library,
            concurrency: concurrency,
            libraryID: library.id,
            onMediaFiles: enqueueForRecognition,
          );
        } catch (error) {
          _appendScanLog('媒体库目录并发刷新失败，回退逐目录读取：$error', isError: true);
          final fallback = <String, CloudFile>{};
          for (final source in library.sources) {
            if (_scanShouldAbort(library.id)) break;
            if (!await _waitIfScanPaused(library.id)) break;
            await _scanSource(
              source.rootID,
              source.path,
              libraryID: library.id,
              recursive: library.recursive,
              minimumSizeBytes: library.minimumSizeMB * 1024 * 1024,
              forceRemote: true,
              initialCompleted: completed,
              onMediaFiles: (files) async {
                for (final file in files) {
                  fallback[file.id] = file;
                }
                await enqueueForRecognition(files);
              },
            );
          }
          mediaFiles = fallback.values.toList(growable: false);
        }
        _appendScanLog('当前媒体库目录刷新完成，发现 ${mediaFiles.length} 个媒体文件');
        AppLogger.info('Media', '$modeLabel [3/5] 目录扫描完成，发现 ${mediaFiles.length} 个媒体文件');
      } else if (!_scanShouldAbort(library.id)) {
        // 扫描未识别的文件：数据库中存在但 isMatched = false
        final unrecognized = previousLibraryItems
            .where((item) => !item.isMatched)
            .map((item) => item.file)
            .toList(growable: false);
        _appendScanLog('未刷新文件索引，直接识别媒体库中 ${unrecognized.length} 个未识别资源');
        _setScanProgress(
          library.id,
          MediaLibraryScanProgress(
            phase: '正在识别未匹配资源',
            total: unrecognized.length,
          ),
        );
        await enqueueForRecognition(unrecognized);
        AppLogger.info('Media', '$modeLabel [4/5] 识别 ${unrecognized.length} 个未识别资源');
      }
      if (!_scanShouldAbort(library.id)) {
        AppLogger.info('Media', '$modeLabel [4/5] 等待识别队列完成');
        await flushRecognitionQueue();
      }
      // 识别批次全部结束后，通知详情补全消费者处理完剩余条目后退出
      detailPhaseDone = true;
      await Future.wait(detailConsumers);
      AppLogger.info('Media', '$modeLabel [5/5] 识别完成，入库中');
      // Flush any items still buffered by the throttled writer.
      await flushPendingUpserts(force: true);
      await pendingPersistence;
      var items = unique.values.toList()
        ..sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
      // A cancelled rescan has only seen part of the configured folders. Keep
      // unseen rows rather than incorrectly treating them as deleted.
      if (_scanShouldAbort(library.id)) {
        final merged = <String, MediaLibraryItem>{
          for (final item in previousLibraryItems) item.id: item,
          for (final item in items) item.id: item,
        };
        items = merged.values.toList()
          ..sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          );
      }
      final discoveredIDs = items.map((item) => item.id).toSet();
      final removedMissing = _scanShouldAbort(library.id) || !forceAll
          ? 0
          : previousLibraryItems
                .where((item) => !discoveredIDs.contains(item.id))
                .length;
      final updatedLibrary = library.copyWith(updatedAt: DateTime.now());
      await _store.replaceLibraryItems(library.id, items);
      await _saveLibraries([updatedLibrary]);
      final libraries = state.libraries
          .map((item) => item.id == library.id ? updatedLibrary : item)
          .toList(growable: false);
      final statistics = await _store.statistics();
      final allItems = await _loadAllItems();
      final visibleItems = state.selectedLibraryID == library.id
          ? await _loadItems(library.id)
          : state.items;
      final aborted = _scanShouldAbort(library.id);
      final finalStatus = _cancelledScanLibraries.contains(library.id)
          ? MediaLibraryScanTaskStatus.cancelled
          : _stoppedScanLibraries.contains(library.id)
          ? MediaLibraryScanTaskStatus.stopped
          : MediaLibraryScanTaskStatus.completed;
      state = state.copyWith(
        libraries: libraries,
        items: visibleItems,
        allItems: allItems,
        libraryStatistics: statistics.libraries,
        storedGlobalStatistics: statistics.global,
        statusMessage: aborted
            ? '扫描已停止，已保留 ${items.length} 个项目'
            : removedMissing == 0
            ? '$modeLabel完成：${items.length} 个视频文件'
            : '$modeLabel完成：${items.length} 个视频文件，已移除 $removedMissing 个不存在的条目',
      );
      _appendScanLog(
        aborted
            ? '扫描已停止，已保留 ${items.length} 个条目'
            : removedMissing == 0
            ? '$modeLabel完成，本次处理 $completed 个资源，识别 $recognizedCount 个，未匹配 $unmatchedCount 个；媒体库现有 ${items.length} 个条目'
            : '$modeLabel完成，本次处理 $completed 个资源，识别 $recognizedCount 个，未匹配 $unmatchedCount 个；媒体库现有 ${items.length} 个条目，已清理 $removedMissing 个失效条目',
      );
      _updateScanTask(
        taskID,
        status: finalStatus,
        progress: MediaLibraryScanProgress(
          phase: aborted ? '扫描已停止' : '任务完成',
          completed: items.length,
          total: forceAll ? items.length + removedMissing : items.length,
        ),
      );
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
      _appendScanLog('扫描失败：$e', isError: true);
      _updateScanTask(
        taskID,
        status: MediaLibraryScanTaskStatus.failed,
        progress: const MediaLibraryScanProgress(phase: '扫描失败'),
        failureReason: e.toString(),
        log: '扫描失败：$e',
        isError: true,
      );
    } finally {
      _pausedScanLibraries.remove(library.id);
      _stoppedScanLibraries.remove(library.id);
      _cancelledScanLibraries.remove(library.id);
      _releaseScanPauseGate(library.id);
      unawaited(_persistScanHistory());
      unawaited(_persistScanTaskHistory());
    }
  }

  void cancelScan({String? libraryID}) {
    libraryID ??= state.selectedLibraryID;
    if (libraryID == null) return;
    stopLibraryScan(libraryID);
  }

  void pauseLibraryScan(String libraryID) {
    final task = state.taskForLibrary(libraryID);
    if (task == null || !task.status.canPause) return;
    _pausedScanLibraries.add(libraryID);
    _updateScanTask(
      task.id,
      status: MediaLibraryScanTaskStatus.paused,
      progress: MediaLibraryScanProgress(
        phase: '扫描已暂停',
        completed: task.progress.completed,
        total: task.progress.total,
      ),
      log: '用户暂停了任务',
    );
  }

  Future<void> resumeLibraryScan(String libraryID) async {
    final task = state.taskForLibrary(libraryID);
    if (task == null || !task.status.canResume) return;
    if (task.status == MediaLibraryScanTaskStatus.paused) {
      _pausedScanLibraries.remove(libraryID);
      _releaseScanPauseGate(libraryID);
      _updateScanTask(
        task.id,
        status: MediaLibraryScanTaskStatus.running,
        progress: MediaLibraryScanProgress(
          phase: '正在继续扫描',
          completed: task.progress.completed,
          total: task.progress.total,
        ),
        log: '用户继续了任务',
      );
      return;
    }
    await resumeScanTask(task.id);
  }

  void stopLibraryScan(String libraryID) {
    final task = state.taskForLibrary(libraryID);
    if (task == null || !task.status.canStop) return;
    _stoppedScanLibraries.add(libraryID);
    _pausedScanLibraries.remove(libraryID);
    _releaseScanPauseGate(libraryID);
    _updateScanTask(
      task.id,
      status: MediaLibraryScanTaskStatus.stopping,
      progress: MediaLibraryScanProgress(
        phase: '正在停止扫描',
        completed: task.progress.completed,
        total: task.progress.total,
      ),
      log: '正在请求停止扫描…',
    );
  }

  void cancelLibraryScan(String libraryID) {
    final task = state.taskForLibrary(libraryID);
    if (task == null) return;
    cancelScanTask(task.id);
  }

  void pauseScanTask(String taskID) {
    final task = state.taskByID(taskID);
    if (task == null) return;
    pauseLibraryScan(task.libraryID);
  }

  Future<void> resumeScanTask(String taskID) async {
    final task = state.taskByID(taskID);
    if (task == null || !task.status.canResume) return;
    if (task.status == MediaLibraryScanTaskStatus.paused) {
      _pausedScanLibraries.remove(task.libraryID);
      _releaseScanPauseGate(task.libraryID);
      _updateScanTask(
        task.id,
        status: MediaLibraryScanTaskStatus.running,
        progress: MediaLibraryScanProgress(
          phase: '正在继续扫描',
          completed: task.progress.completed,
          total: task.progress.total,
        ),
        log: '用户继续了任务',
      );
      return;
    }
    final isGlobalTask = task.libraryID == globalMediaLibraryID;
    final library = state.libraries
        .where((candidate) => candidate.id == task.libraryID)
        .firstOrNull;
    if ((library == null && !isGlobalTask) ||
        _api == null ||
        state.scanTasks.any(
          (candidate) =>
              candidate.id != task.id &&
              candidate.libraryID == task.libraryID &&
              candidate.isActive,
        )) {
      return;
    }
    _cancelledScanLibraries.remove(task.libraryID);
    _stoppedScanLibraries.remove(task.libraryID);
    _pausedScanLibraries.remove(task.libraryID);
    _releaseScanPauseGate(task.libraryID);
    _updateScanTask(
      task.id,
      status: MediaLibraryScanTaskStatus.queued,
      progress: MediaLibraryScanProgress(
        phase: '准备继续任务',
        completed: task.progress.completed,
        total: task.progress.total,
      ),
      log: task.status == MediaLibraryScanTaskStatus.failed
          ? '用户重试任务'
          : '用户继续任务',
      clearFailure: true,
    );
    // Resuming continues where the run stopped: the file index was already
    // built, so only unfinished recognition work is replayed. A retry after a
    // failure keeps the original mode.
    final isRetry = task.status == MediaLibraryScanTaskStatus.failed;
    final resumeMode = isRetry
        ? task.mode
        : _resumeModeFor(task);
    final run = runZoned(
      () => isGlobalTask
          ? _runGlobalScan(taskID: task.id, mode: resumeMode)
          : _runLibraryScan(library!, taskID: task.id, mode: resumeMode),
      zoneValues: {_mediaScanTaskZoneKey: task.id},
    );
    _scanRuns[task.libraryID] = run;
    await run;
    if (identical(_scanRuns[task.libraryID], run)) {
      _scanRuns.remove(task.libraryID);
    }
  }

  void stopScanTask(String taskID) {
    final task = state.taskByID(taskID);
    if (task == null) return;
    stopLibraryScan(task.libraryID);
  }

  void cancelScanTask(String taskID) {
    final task = state.taskByID(taskID);
    if (task == null) return;
    _cancelledScanLibraries.add(task.libraryID);
    _stoppedScanLibraries.remove(task.libraryID);
    _pausedScanLibraries.remove(task.libraryID);
    _releaseScanPauseGate(task.libraryID);
    _updateScanTask(
      task.id,
      status: task.isActive
          ? MediaLibraryScanTaskStatus.cancelling
          : MediaLibraryScanTaskStatus.cancelled,
      progress: MediaLibraryScanProgress(
        phase: task.isActive ? '正在取消任务' : '任务已取消',
        completed: task.progress.completed,
        total: task.progress.total,
      ),
      log: '用户取消了任务',
    );
  }

  void removeScanTask(String taskID) {
    final task = state.taskByID(taskID);
    if (task == null || task.isActive) return;
    state = state.copyWith(
      scanTasks: [
        for (final candidate in state.scanTasks)
          if (candidate.id != taskID) candidate,
      ],
    );
    unawaited(_persistScanTaskHistory());
  }

  void clearFinishedScanTasks() {
    state = state.copyWith(
      scanTasks: state.scanTasks
          .where((task) => task.isActive)
          .toList(growable: false),
    );
    unawaited(_persistScanTaskHistory());
  }

  Future<void> rescanSelectedLibrary({
    MediaLibraryScanMode mode = MediaLibraryScanMode.unrecognizedOnly,
  }) => scanSelectedLibrary(mode: mode);

  void cancelDetailSync() {
    _cancelDetailSync = true;
    _appendScanLog('[同步识别][调试] 已请求取消同步识别');
  }

  Future<bool> refreshGlobalCloudIndex({
    bool force = false,
    bool forceIncrementalCheck = false,
  }) async {
    if (_api == null) {
      AppLogger.warning('CloudIndex', '无法刷新全盘文件索引：云盘接口尚未初始化');
      return false;
    }
    if (_refreshingCloudIndex) {
      AppLogger.debug('CloudIndex', '全盘文件索引正在刷新，本次请求已合并');
      return await _cloudIndexRefreshCompleter?.future ?? false;
    }
    _cachedCloudEntries = null;
    final minutes =
        (int.tryParse(
                  StorageManager.get<String>(
                        StorageKeys.cloudIndexRefreshMinutes,
                      ) ??
                      '30',
                ) ??
                30)
            .clamp(5, 1440);
    final lastUpdated = int.tryParse(
      StorageManager.get<String>(StorageKeys.cloudIndexLastUpdatedAt) ?? '',
    );
    // 全量刷新只在首次（无时间标记）或用户手动触发时执行；
    // 冷启动只要时间标记未过期就走增量，不再因 rootSnapshot/liveGCIDVersion
    // 这两个易丢条件触发全量。
    final needsFullRebuild = force || lastUpdated == null;
    if (!force && !forceIncrementalCheck && !needsFullRebuild) {
      final elapsed = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(lastUpdated),
      );
      if (elapsed < Duration(minutes: minutes)) {
        final remaining = Duration(minutes: minutes) - elapsed;
        AppLogger.info(
          'CloudIndex',
          '全盘文件索引缓存仍有效，已跳过本次刷新；约 ${remaining.inMinutes + 1} 分钟后自动更新',
        );
        _scheduleCloudIndexRefresh(minutes);
        await _reconcileMediaItemsWithCloudIndex();
        return true;
      }
    }
    _refreshingCloudIndex = true;
    _cloudIndexRefreshCompleter = Completer<bool>();
    state = state.copyWith(isRefreshingCloudIndex: true);
    var succeeded = false;
    try {
      late final _CloudIndexRefreshResult result;
      if (needsFullRebuild) {
        final reason = force ? '用户手动触发' : '本地缓存为空';
        if (force) {
          AppLogger.info('CloudIndex', '手动全量刷新：正在清空本地文件索引');
          await FileMetadataCache.clearFolderChildrenIndex();
          await StorageManager.delete(StorageKeys.cloudIndexLastUpdatedAt);
          await StorageManager.delete(StorageKeys.cloudIndexLiveGCIDVersion);
        }
        AppLogger.info('CloudIndex', '开始通过全盘分页接口刷新索引：$reason');
        result = await _rebuildGlobalCloudIndex();
        AppLogger.info(
          'CloudIndex',
          '全盘文件索引刷新完成：${result.updatedFolders} 个目录，${result.updatedEntries} 项',
        );
      } else {
        AppLogger.info('CloudIndex', '开始按目录修改时间增量检查全盘索引');
        result = await _refreshChangedCloudIndex();
        AppLogger.info(
          'CloudIndex',
          '全盘索引增量检查完成：检查 ${result.checkedFolders} 个目录，'
              '更新 ${result.updatedFolders} 个目录、${result.updatedEntries} 项',
        );
      }
      await StorageManager.set(
        StorageKeys.cloudIndexLastUpdatedAt,
        DateTime.now().millisecondsSinceEpoch.toString(),
      );
      await StorageManager.set(StorageKeys.cloudIndexLiveGCIDVersion, '1');
      _appendScanLog(
        needsFullRebuild
            ? '[云盘索引] 已刷新 ${result.updatedFolders} 个目录、${result.updatedEntries} 项缓存'
            : '[云盘索引] 已检查 ${result.checkedFolders} 个目录，更新 ${result.updatedFolders} 个目录',
      );
      await _reconcileMediaItemsWithCloudIndex();
      succeeded = true;
      return true;
    } catch (error) {
      AppLogger.error('CloudIndex', '刷新全盘文件索引失败', error: error);
      _appendScanLog('[云盘索引] 刷新失败：$error', isError: true);
      return false;
    } finally {
      _refreshingCloudIndex = false;
      state = state.copyWith(isRefreshingCloudIndex: false);
      _cloudIndexRefreshCompleter?.complete(succeeded);
      _cloudIndexRefreshCompleter = null;
      _scheduleCloudIndexRefresh(minutes);
    }
  }

  Future<void> scanGlobalLibrary({MediaLibraryScanMode mode = MediaLibraryScanMode.forceAll}) async {
    if (_api == null ||
        state.isLoading ||
        state.isLibraryScanning(globalMediaLibraryID)) {
      AppLogger.info('Media', '全局扫描请求被忽略：正在加载或已在扫描中');
      return;
    }
    const libraryID = globalMediaLibraryID;
    final modeLabel = mode.title;
    AppLogger.info('Media', '开始$modeLabel');

    // Ensure global library definition exists
    if (!state.libraries.any((l) => l.id == libraryID)) {
      final globalLib = MediaLibraryDefinition(
        id: libraryID,
        name: globalMediaLibraryName,
        sources: const [],
        minimumSizeMB: _globalMediaScanMinimumSizeMB,
      );
      state = state.copyWith(libraries: [...state.libraries, globalLib]);
      await _saveLibraries(state.libraries);
    }

    _cancelledScanLibraries.remove(libraryID);
    _stoppedScanLibraries.remove(libraryID);
    _pausedScanLibraries.remove(libraryID);
    _releaseScanPauseGate(libraryID);
    _clearRecognitionSearchCache();

    final taskID = 'global-${DateTime.now().microsecondsSinceEpoch}';
    final task = MediaLibraryScanTask(
      id: taskID,
      libraryID: libraryID,
      libraryName: globalMediaLibraryName,
      mode: mode,
      status: MediaLibraryScanTaskStatus.queued,
      progress: const MediaLibraryScanProgress(phase: '等待开始'),
      logs: [
        MediaLibraryScanLog(
          createdAt: DateTime.now(),
          message: '任务已创建，等待$modeLabel',
        ),
      ],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    state = state.copyWith(scanTasks: [task, ...state.scanTasks]);
    unawaited(_persistScanTaskHistory());

    final run = runZoned(
      () => _runGlobalScan(taskID: task.id, mode: mode),
      zoneValues: {_mediaScanTaskZoneKey: task.id},
    );
    _scanRuns[libraryID] = run;
    await run;
    if (identical(_scanRuns[libraryID], run)) _scanRuns.remove(libraryID);
  }

  Future<void> _runGlobalScan({
    required String taskID,
    required MediaLibraryScanMode mode,
  }) async {
    const libraryID = globalMediaLibraryID;
    final modeLabel = mode.title;
    final forceAll = mode.refreshesFileIndex;
    final minimumSizeMB = _globalMediaScanMinimumSizeMB;
    final minimumSizeBytes = minimumSizeMB * 1024 * 1024;
    final tmdbApiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    final tmdbProxyHost =
        StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '';
    final tmdbProxyPort =
        StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '';
    final concurrency =
        (int.tryParse(
                  StorageManager.get<String>(StorageKeys.mediaScanConcurrency) ??
                      '6',
                ) ??
                6)
            .clamp(1, 20);

    _updateScanTask(
      taskID,
      status: MediaLibraryScanTaskStatus.running,
      progress: const MediaLibraryScanProgress(phase: '准备全局刮削'),
      log: '开始$modeLabel，最小 $minimumSizeMB MB，并发 $concurrency',
      clearFailure: true,
    );
    AppLogger.info('Media', '$modeLabel 参数：最小 $minimumSizeMB MB，并发 $concurrency');

    var completed = 0;

    try {
      // ── 0. 后台并行准备 ID 集合：与流式生产者同时启动，扫描一开始
      //    就开流水线，生产者抓到数据立刻入队给识别消费者，不再等 ID 集齐。
      final existingGlobalFileIDs = <String>{};
      final otherLibraryFileIDs = <String>{};
      final unmatchedFileIDs = <String>{};
      var idPrepDone = false;
      final idPrepFuture = Future.wait([
        _store.fileIdsByLibraryBatched(
          (libID, ids) async {
            if (libID == libraryID) {
              existingGlobalFileIDs.addAll(ids);
            } else {
              otherLibraryFileIDs.addAll(ids);
            }
          },
        ),
        if (!forceAll)
          _store.unmatchedFileIDsBatched(
            (ids) async {
              unmatchedFileIDs.addAll(ids);
            },
            libraryID: libraryID,
          ),
      ]).then((_) {
        idPrepDone = true;
        AppLogger.info('Media', '$modeLabel 全局条目 ${existingGlobalFileIDs.length} 个，其他库 ${otherLibraryFileIDs.length} 个');
        _appendScanLog('当前媒体库已匹配 ${existingGlobalFileIDs.length - unmatchedFileIDs.length} 个，未匹配 ${unmatchedFileIDs.length} 个');
      });

      _appendScanLog('从缓存读取文件列表…');
      // ── 从远端遍历重建全盘文件索引，避免读到旧/不完整的
      //    folder_children 缓存。forceAll（强制全盘）与 unindexedOnly
      //    （扫描未入库）都依赖完整索引；unrecognizedOnly 走 media_items
      //    表，不经过此缓存，无需重建。
      if (mode.scansSource) {
        _appendScanLog('正在重建全盘文件索引（远端遍历）…');
        final refreshed = await refreshGlobalCloudIndex(force: true);
        if (!refreshed) {
          throw StateError('全盘文件索引重建失败');
        }
      }
      // ── 流式管道：DB 分批读取，边筛选边入队，消费者立刻开始消费 ──
      // 以前 allCachedFolderChildren() 一次性把全表读进内存（7万条≈几十MB），
      // 筛选完才开始入库，延迟高且内存压力大。现在用 batched 游标读取，
      // 每批 500 条，筛选后直接入 recognizeQueue，消费者并行刮削。
      const batchSize = 500;
      var totalCachedFiles = 0;

      // ── 加载排除设置 ──
      final excludedFolderIDs = Set<String>.from(
        StorageManager.get<List>(StorageKeys.globalScanExcludedFolders)
                ?.cast<String>() ??
            [],
      );
      final excludedKeywords = List<String>.from(
        StorageManager.get<List>(StorageKeys.globalScanExcludedKeywords)
                ?.cast<String>() ??
            [],
      );
      final hasExclusions =
          excludedFolderIDs.isNotEmpty || excludedKeywords.isNotEmpty;

      bool isExcluded(CloudFile file) {
        if (excludedFolderIDs.isNotEmpty && file.fullParentIDs != null) {
          for (final fid in excludedFolderIDs) {
            if (file.fullParentIDs!.contains(fid)) return true;
          }
        }
        if (excludedKeywords.isNotEmpty) {
          final lowerName = file.name.toLowerCase();
          final lowerPath = file.cloudPath.toLowerCase();
          for (final kw in excludedKeywords) {
            final lk = kw.toLowerCase();
            if (lowerName.contains(lk) || lowerPath.contains(lk)) return true;
          }
        }
        return false;
      }

      AppLogger.info('Media', '$modeLabel 开始流式读取，批大小 $batchSize，'
          '排除文件夹 ${excludedFolderIDs.length} 个，排除关键词 ${excludedKeywords.length} 个');
      _appendScanLog('开始流式读取并筛选…');

      var scannedFiles = 0;
      var insertedCount = 0;
      var skippedIso = 0;
      var skippedSmall = 0;
      var skippedDiscInternal = 0;
      var skippedOtherLib = 0;
      var skippedDuplicate = 0;
      var skippedNotVideo = 0;
      var skippedExcluded = 0;
      var recognizedCount = 0;
      var unmatchedCount = 0;

      final recognizeQueue = <MediaLibraryItem>[];
      // Rows matched with deferred details, drained by the detail consumer.
      final deferredDetailItems = <MediaLibraryItem>[];
      // 本地预筛未命中（需远程 API 识别）的条目，由远程消费者流水线消费。
      final remoteRecognizeQueue = <MediaLibraryItem>[];
      var producerDone = false;
      var localPhaseDone = false;
      var remotePhaseDone = false;
      var nextRecognize = 0;
      var nextRemote = 0;
      var nextDetail = 0;
      // 本地预筛是纯 SQLite 查询，可安全使用更高并发；远程 API 受限流
      // 约束，仍沿用用户配置的 concurrency。
      final localConcurrency = (concurrency * 4).clamp(4, 40);
      // 详情补全按作品去重，攒批提交以摊薄每批的数据库/网络开销。
      const globalDetailBatchSize = 100;
      // 批量入库缓冲：识别结果攒够一批再写库，避免每条一个事务。
      const globalUpsertFlushCount = 50;
      final pendingUpserts = <MediaLibraryItem>[];
      // 全局刮削有 40+10+详情 多组消费者并发攒批，若同时写 SQLite 会锁竞争
      // （此前日志反复出现 database has been locked）。与单库扫描一致，
      // 用串行链把批量 upsert 排队执行，避免并发写。
      Future<void> pendingPersistence = Future<void>.value();
      Future<void> flushPendingUpserts({bool force = false}) async {
        if (pendingUpserts.isEmpty) return;
        if (!force && pendingUpserts.length < globalUpsertFlushCount) return;
        final batch = List<MediaLibraryItem>.of(pendingUpserts);
        pendingUpserts.clear();
        pendingPersistence = pendingPersistence.then(
          (_) => _upsertItems(batch),
        );
        await pendingPersistence;
      }

      // Consumers are defined here but launched after the variables they
      // close over (recognizeQueue, nextRecognize, producerDone) are ready.
      //
      // 两阶段识别：
      //  阶段一（本地预筛，localConcurrency 高并发）：只查本地 works 表，
      //  命中的直接入库；未命中的放入 remoteRecognizeQueue。
      //  阶段二（远程 API，concurrency）：等本地预筛结束后统一消费
      //  remoteRecognizeQueue，走 TMDB/豆瓣网络搜索。
      Future<void> localConsumer(int id) async {
        while (!_scanShouldAbort(libraryID)) {
          if (!await _waitIfScanPaused(libraryID)) return;
          if (nextRecognize >= recognizeQueue.length) {
            if (producerDone) break;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            continue;
          }
          final item = recognizeQueue[nextRecognize++];
          try {
            // 本地预筛：仅命中本地 works 表才返回匹配结果，否则原样返回，
            // 由阶段二做远程 API 识别。模式筛选已在生产者入队前完成。
            final recognized = await _recognizeMediaItem(
              item, tmdbApiKey,
              proxyHost: tmdbProxyHost, proxyPort: tmdbProxyPort,
              deferDetails: true,
              localOnly: true,
            );
            if (_scanShouldAbort(libraryID)) return;
            if (!recognized.isMatched) {
              // 本地未命中 → 进入远程识别队列
              remoteRecognizeQueue.add(item);
              continue;
            }
            // Route through _upsertItems so the shared TMDB/Douban works cache
            // is mirrored for globally-scanned matches too.
            pendingUpserts.add(recognized);
            await flushPendingUpserts();
            if (recognized.needsDetailHydration) {
              deferredDetailItems.add(recognized);
            }
            completed += 1;
            recognizedCount += 1;
          } catch (e) {
            // 本地预筛异常不影响整体流程，转入远程队列重试
            AppLogger.warning(
              'Media',
              '本地预筛失败（转远程识别）：${item.file.name}，$e',
            );
            if (_scanShouldAbort(libraryID)) return;
            remoteRecognizeQueue.add(item);
          }
          if (completed % 5 == 0) {
            // Reloading + enriching the entire library from SQLite is O(N);
            // doing it every 10 items makes a large scan O(N²). A coarser
            // interval keeps the grid live without the quadratic cost.
            if (completed % 200 == 0) {
              final refreshedItems = await _loadItems(libraryID);
              state = state.copyWith(items: refreshedItems);
            }
            _setScanProgress(
              libraryID,
              MediaLibraryScanProgress(
                phase: '正在本地预筛 ${item.file.name}',
                completed: completed,
                total: insertedCount,
                scanned: scannedFiles,
                pending: (insertedCount - nextRecognize).clamp(0, insertedCount),
                matched: recognizedCount,
                unmatched: unmatchedCount,
              ),
            );
          }
        }
      }

      // 阶段二：远程 API 识别（受流控约束，沿用用户配置的 concurrency）。
      // 与本地预筛并行运行：本地未命中的条目一进队列即被消费，
      // 仅当本地预筛全部结束（localPhaseDone）且队列清空后才退出。
      Future<void> remoteConsumer(int id) async {
        while (!_scanShouldAbort(libraryID)) {
          if (!await _waitIfScanPaused(libraryID)) return;
          if (nextRemote >= remoteRecognizeQueue.length) {
            if (localPhaseDone) break;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            continue;
          }
          final item = remoteRecognizeQueue[nextRemote++];
          try {
            final recognized = await _recognizeMediaItem(
              item, tmdbApiKey,
              proxyHost: tmdbProxyHost, proxyPort: tmdbProxyPort,
              deferDetails: true,
            );
            if (_scanShouldAbort(libraryID)) return;
            pendingUpserts.add(recognized);
            await flushPendingUpserts();
            if (recognized.needsDetailHydration) {
              deferredDetailItems.add(recognized);
            }
            completed += 1;
            if (recognized.isMatched) {
              recognizedCount += 1;
            } else {
              unmatchedCount += 1;
            }
            if (!recognized.isMatched) {
              AppLogger.debug(
                'Media',
                '[$modeLabel] 未匹配 [$completed/$insertedCount] ${item.file.name}',
              );
            }
          } catch (e) {
            AppLogger.warning('Media', '识别失败（跳过）：${item.file.name}，$e');
            completed += 1;
            unmatchedCount += 1;
          }
          if (completed % 5 == 0) {
            if (completed % 200 == 0) {
              final refreshedItems = await _loadItems(libraryID);
              state = state.copyWith(items: refreshedItems);
            }
            _setScanProgress(
              libraryID,
              MediaLibraryScanProgress(
                phase: '正在远程识别 ${item.file.name}',
                completed: completed,
                total: insertedCount,
                scanned: scannedFiles,
                pending:
                    (insertedCount - nextRemote).clamp(0, insertedCount),
                matched: recognizedCount,
                unmatched: unmatchedCount,
              ),
            );
          }
          if (completed % _globalScanRecognitionLogStep == 0) {
            _appendScanLog(
              '识别进度 $completed/$insertedCount'
              '（匹配 $recognizedCount，未匹配 $unmatchedCount）',
            );
          }
          // 统计刷新频率独立于日志：每 _globalScanStatisticsRefreshStep 条
          // 重算一次（电影/电视剧/未识别），让左侧菜单栏数字实时变化。
          if (completed % _globalScanStatisticsRefreshStep == 0) {
            await _refreshGlobalStatistics();
          }
        }
      }

      // 阶段三：详情补全消费者。与识别并行运行——识别一旦产出带 tmdbID
      // 且需要补详情的条目，这里就按作品去重批量拉取详情并入库，
      // 无需等识别全部结束（localPhaseDone && remotePhaseDone 后才退出）。
      Future<void> detailConsumer(int id) async {
        while (!_scanShouldAbort(libraryID)) {
          if (!await _waitIfScanPaused(libraryID)) return;
          if (nextDetail >= deferredDetailItems.length) {
            if (localPhaseDone && remotePhaseDone) break;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            continue;
          }
          final end = (nextDetail + globalDetailBatchSize)
              .clamp(0, deferredDetailItems.length);
          final batch = deferredDetailItems.sublist(nextDetail, end);
          nextDetail = end;
          if (batch.isEmpty) continue;
          try {
            await _hydrateDeferredDetails(
              batch,
              apiKey: tmdbApiKey,
              proxyHost: tmdbProxyHost,
              proxyPort: tmdbProxyPort,
              libraryID: libraryID,
              concurrency: concurrency,
            );
          } catch (e) {
            AppLogger.warning('Media', '详情补全失败（跳过批次）：$e');
          }
          if (completed % _globalScanRecognitionLogStep == 0) {
            _appendScanLog(
              '详情补全 $nextDetail/${deferredDetailItems.length} 条',
            );
          }
          // 统计刷新频率独立于日志：每 _globalScanStatisticsRefreshStep 条
          // 重算一次（电影/电视剧/未识别），让左侧菜单栏数字实时变化。
          if (completed % _globalScanStatisticsRefreshStep == 0) {
            await _refreshGlobalStatistics();
          }
        }
      }

      // 流式生产者：每批从 DB 读取 → 筛选 → 入队，消费者并行消费。
      // 本地预筛、远程识别、详情补全三组消费者同时启动（流水线并行），
      // 识别一产出结果即入库、一产出待补详情即拉取详情，互不等待。
      _appendScanLog(
        '启动 $localConcurrency 个本地预筛消费者、$concurrency 个远程识别消费者'
        '与详情补全消费者（流水线并行）…',
      );
      final consumers = List.generate(
        localConcurrency,
        (i) => localConsumer(i + 1),
      );
      final remoteConsumers = List.generate(
        concurrency,
        (i) => remoteConsumer(i + 1),
      );
      final detailConsumers = List.generate(
        concurrency.clamp(1, 4),
        (i) => detailConsumer(i + 1),
      );

      final insertBatch = <MediaLibraryItem>[];
      if (mode == MediaLibraryScanMode.unrecognizedOnly) {
        // 扫描未识别：直接从 media_items 的未匹配行读取，不扫全量缓存。
        // global 库（__global__）是逻辑视图，数据库中没有其 media_items 行，
        // 必须读取所有具体媒体库的未匹配行（libraryID 传 null 即不过滤）。
        await _store.allItemsBatched(
          libraryID: null,
          unmatchedOnly: true,
          onBatch: (items) async {
            if (_scanShouldAbort(libraryID)) return;
            totalCachedFiles += items.length;
            for (final item in items) {
              if (_scanShouldAbort(libraryID)) return;
              scannedFiles += 1;
              final file = item.file;
              if (file.isDirectory) continue;
              if (!file.isVideo) { skippedNotVideo += 1; continue; }
              if (hasExclusions && isExcluded(file)) { skippedExcluded += 1; continue; }
              if (isMediaScanIsoFile(file)) { skippedIso += 1; continue; }
              if (isMediaScanDiscInternalPath(file.cloudPath)) {
                skippedDiscInternal += 1;
                continue;
              }
              if ((file.size ?? 0) < minimumSizeBytes) { skippedSmall += 1; continue; }
              recognizeQueue.add(item);
              insertedCount += 1;
            }
            await Future<void>.delayed(Duration.zero);
            if (scannedFiles % 500 == 0) {
              _appendScanLog(
                '扫描进度 $scannedFiles 个文件，已入队 $insertedCount 条…',
              );
            }
          },
        );
      } else {
      await FileMetadataCache.allCachedFolderChildrenBatched(
        (batch) async {
          if (_scanShouldAbort(libraryID)) return;
          totalCachedFiles += batch.length;
          for (final file in batch) {
            if (_scanShouldAbort(libraryID)) return;
            scannedFiles += 1;
            if (file.isDirectory) continue;
            if (!file.isVideo) { skippedNotVideo += 1; continue; }
            if (hasExclusions && isExcluded(file)) { skippedExcluded += 1; continue; }
            if (isMediaScanIsoFile(file)) { skippedIso += 1; continue; }
            if (isMediaScanDiscInternalPath(file.cloudPath)) {
              skippedDiscInternal += 1;
              continue;
            }
            if ((file.size ?? 0) < minimumSizeBytes) { skippedSmall += 1; continue; }
            // 第二步：入队前模式筛选（流水线环节）。
            // forceAll 全部识别，无需筛选，保持乐观放行；
            // unindexedOnly/unrecognizedOnly 的筛选依赖 ID 集合（判断未入库/
            // 未匹配），ID 集合与 folder_children 读取并行填充，就绪前等待
            // 该次（之后恒就绪），就绪后精确筛选——保证扫描范围正确，
            // 不把已入库/已匹配的文件误入队。
            if (otherLibraryFileIDs.contains(file.id)) { skippedOtherLib += 1; continue; }
            if (!forceAll) {
              if (!idPrepDone) {
                await idPrepFuture;
              }
              switch (mode) {
                case MediaLibraryScanMode.forceAll:
                  break;
                case MediaLibraryScanMode.unindexedOnly:
                  if (existingGlobalFileIDs.contains(file.id)) {
                    // 已入库 → 跳过（本次只扫描未入库的新文件）
                    skippedDuplicate += 1;
                    continue;
                  }
                  break;
                case MediaLibraryScanMode.unrecognizedOnly:
                  if (!unmatchedFileIDs.contains(file.id)) {
                    // 不在未匹配集合 → 跳过（本次只识别已入库但未匹配的文件）
                    skippedDuplicate += 1;
                    continue;
                  }
                  break;
              }
            }
            final item = MediaLibraryItem.fromFile(
              libraryID,
              file,
              directoryName: _parentDirectoryName(file.cloudPath),
            );
            if (item.file.cloudPath.trim().isEmpty ||
                !item.file.cloudPath.contains('/')) {
              // 缓存缺失完整路径时，识别会丢失父目录/标题变体上下文，
              // 尝试从 gcid_details 缓存恢复完整 cloudPath。
              final enriched = await _store.cachedFile(file.id);
              if (enriched != null &&
                  enriched.cloudPath.trim().isNotEmpty &&
                  enriched.cloudPath.contains('/')) {
                insertBatch.add(
                  MediaLibraryItem.fromFile(
                    libraryID,
                    enriched,
                    directoryName: _parentDirectoryName(enriched.cloudPath),
                  ),
                );
                recognizeQueue.add(item.copyWith(file: enriched));
                insertedCount += 1;
                if (insertBatch.length >= 200) {
                  await _store.upsertItems(insertBatch);
                  insertBatch.clear();
                }
                continue;
              }
            }
            insertBatch.add(item);
            recognizeQueue.add(item);
            insertedCount += 1;
            if (insertBatch.length >= 200) {
              await _store.upsertItems(insertBatch);
              insertBatch.clear();
            }
          }
          // 每批处理完让出事件循环，使消费者有机会消费
          await Future<void>.delayed(Duration.zero);
          if (scannedFiles % 500 == 0) {
            _appendScanLog(
              '扫描进度 $scannedFiles 个文件，'
              '已写入 $insertedCount 条，排除 $skippedExcluded 个',
            );
          }
        },
        batchSize: batchSize,
        shouldStop: () => _scanShouldAbort(libraryID),
      );
      }
      if (insertBatch.isNotEmpty) await _store.upsertItems(insertBatch);

      final totalSkipped = skippedNotVideo + skippedIso + skippedSmall +
          skippedDiscInternal + skippedOtherLib + skippedDuplicate + skippedExcluded;
      _appendScanLog(
        '筛选完成：缓存共 $totalCachedFiles 个，写入 $insertedCount 条，'
        '跳过 $totalSkipped 个（非视频$skippedNotVideo ISO$skippedIso '
        '小文件$skippedSmall 原盘$skippedDiscInternal 已归属$skippedOtherLib '
        '重复$skippedDuplicate'
        '${skippedExcluded > 0 ? ' 排除$skippedExcluded' : ''}）',
      );

      // 生产者结束：等待本地预筛消费者处理完队列中剩余数据
      producerDone = true;
      await Future.wait(consumers);
      // 本地预筛全部结束，通知远程消费者处理完剩余条目后退出
      localPhaseDone = true;
      if (remoteRecognizeQueue.isNotEmpty) {
        _appendScanLog(
          '本地预筛完成，${remoteRecognizeQueue.length} 条待远程识别…',
        );
      }
      await Future.wait(remoteConsumers);
      // 远程识别全部结束，通知详情补全消费者处理完剩余条目后退出
      remotePhaseDone = true;
      await Future.wait(detailConsumers);
      // 强制写入剩余缓冲的识别结果
      await flushPendingUpserts(force: true);
      // ID 集合预取是后台并行跑完的，收尾前确保其完成（统计依赖完整集合）
      await idPrepFuture;

      // ── 4. 最终统计 ──
      final stats = await _store.statistics();
      // Final grid refresh so the throttled UI reflects every recognized item.
      final finalItems = state.selectedLibraryID == libraryID
          ? await _loadItems(libraryID)
          : null;
      state = state.copyWith(
        storedGlobalStatistics: stats.global,
        items: finalItems,
      );

      final aborted = _scanShouldAbort(libraryID);
      final finalStatus = _cancelledScanLibraries.contains(libraryID)
          ? MediaLibraryScanTaskStatus.cancelled
          : _stoppedScanLibraries.contains(libraryID)
          ? MediaLibraryScanTaskStatus.stopped
          : MediaLibraryScanTaskStatus.completed;

      _appendScanLog(
        aborted
            ? '$modeLabel已停止：识别 $completed 条'
            : '$modeLabel完成：识别 $completed 条，匹配 $recognizedCount 个，未匹配 $unmatchedCount 个',
      );
      AppLogger.info(
        'Media',
        '$modeLabel${aborted ? '已停止' : '完成'}：识别 $completed 条，'
            '匹配 $recognizedCount，未匹配 $unmatchedCount',
      );
      _updateScanTask(
        taskID,
        status: finalStatus,
        progress: MediaLibraryScanProgress(
          phase: aborted ? '已停止' : '任务完成',
          completed: completed,
          total: insertedCount,
          scanned: scannedFiles,
        ),
      );
    } catch (e) {
      AppLogger.error('Media', '$modeLabel失败', error: e);
      state = state.copyWith(errorMessage: e.toString());
      _appendScanLog('$modeLabel失败：$e', isError: true);
      _updateScanTask(
        taskID,
        status: MediaLibraryScanTaskStatus.failed,
        progress: const MediaLibraryScanProgress(phase: '任务失败'),
        failureReason: e.toString(),
        log: '$modeLabel失败：$e',
        isError: true,
      );
    } finally {
      _pausedScanLibraries.remove(libraryID);
      _stoppedScanLibraries.remove(libraryID);
      _cancelledScanLibraries.remove(libraryID);
      _releaseScanPauseGate(libraryID);
      unawaited(_persistScanHistory());
      unawaited(_persistScanTaskHistory());
    }
  }

  int get _globalMediaScanMinimumSizeMB {
    final configured = int.tryParse(
      StorageManager.get<String>(StorageKeys.globalMediaScanMinimumSizeMB) ??
          '500',
    );
    return (configured ?? 500).clamp(1, 1024 * 1024);
  }

  void _scheduleCloudIndexRefresh(int minutes) {
    _cloudIndexTimer?.cancel();
    _cloudIndexTimer = Timer(Duration(minutes: minutes), () {
      unawaited(refreshGlobalCloudIndex());
    });
  }

  Future<void> _reconcileMediaItemsWithCloudIndex() async {
    if (_reconcilingMediaGCIDs) return;
    _reconcilingMediaGCIDs = true;
    try {
      final allItems = await _loadAllItems();
      if (allItems.isEmpty) return;
      final indexedFiles = (await FileMetadataCache.allCachedFolderChildren())
          .where((file) => !file.isDirectory)
          .toList();
      final liveByID = {for (final file in indexedFiles) file.id: file};
      final liveByGCID = <String, List<CloudFile>>{};
      for (final file in indexedFiles) {
        final gcid = file.gcid?.trim();
        if (gcid == null || gcid.isEmpty) continue;
        (liveByGCID[gcid] ??= []).add(file);
      }
      final missing = <MediaLibraryItem>[];
      final replacements = <String, MediaLibraryItem>{};
      final assignedFileIDs = <String, Set<String>>{};
      for (final item in allItems) {
        final gcid = item.file.gcid?.trim() ?? '';
        final liveFiles = gcid.isEmpty
            ? const <CloudFile>[]
            : liveByGCID[gcid] ?? const <CloudFile>[];
        final assigned = gcid.isEmpty
            ? <String>{}
            : assignedFileIDs[gcid] ??= <String>{};
        CloudFile? live = liveByID[item.id];
        if (live == null && gcid.isNotEmpty) {
          live = liveFiles
              .where(
                (file) =>
                    !assigned.contains(file.id) &&
                    file.cloudPath.isNotEmpty &&
                    file.cloudPath == item.file.cloudPath,
              )
              .firstOrNull;
          live ??= liveFiles
              .where(
                (file) =>
                    !assigned.contains(file.id) && file.name == item.file.name,
              )
              .firstOrNull;
          live ??= liveFiles
              .where((file) => !assigned.contains(file.id))
              .firstOrNull;
        }
        if (live == null) {
          var confirmedNotFound = false;
          live = await _resolveCurrentCloudFile(
            item.file,
            libraryID: item.libraryID,
            onConfirmedNotFound: () => confirmedNotFound = true,
          );
          if (live == null) {
            if (confirmedNotFound) missing.add(item);
            continue;
          }
        }
        if (_parentPath(live.cloudPath).isEmpty) {
          live = await _restoreCloudFilePath(
            live,
            item.file,
            libraryID: item.libraryID,
          );
        }
        if (gcid.isNotEmpty) assigned.add(live.id);
        final liveName = live.name.isEmpty ? item.file.name : live.name;
        final livePath = recoverCloudFilePath(
          fileName: liveName,
          candidatePath: live.cloudPath,
          knownPath: item.file.cloudPath,
        );
        if (live.id == item.id &&
            liveName == item.file.name &&
            livePath == item.file.cloudPath) {
          continue;
        }
        replacements['${item.libraryID}:${item.id}'] = item.copyWith(
          file: item.file.copyWith(
            id: live.id,
            name: liveName,
            size: live.size ?? item.file.size,
            gcid: live.gcid?.trim().isNotEmpty == true
                ? live.gcid
                : item.file.gcid,
            modifiedAt: live.modifiedAt.isEmpty
                ? item.file.modifiedAt
                : live.modifiedAt,
            cloudPath: livePath,
            parentID: live.parentID ?? item.file.parentID,
            fullParentIDs: live.fullParentIDs ?? item.file.fullParentIDs,
            fileType: live.fileType,
          ),
          updatedAt: DateTime.now(),
        );
      }
      if (replacements.isNotEmpty) {
        await _replaceItemsByPreviousIDs(replacements);
      }
      if (missing.isNotEmpty) {
        await _removeMissingMediaItems(missing);
      }
      if (replacements.isNotEmpty || missing.isNotEmpty) {
        final refreshed = await _loadAllItems();
        state = state.copyWith(
          allItems: refreshed,
          items: refreshed
              .where((item) => item.libraryID == state.selectedLibraryID)
              .toList(),
        );
        _appendScanLog(
          '[云盘索引校验] 更新 ${replacements.length} 条资源映射，'
          '移除 ${missing.length} 条已不存在的媒体记录；GCID 内容缓存已保留',
        );
      }
    } catch (error) {
      AppLogger.warning('Media', '定期 GCID 校验失败：$error');
    } finally {
      _reconcilingMediaGCIDs = false;
    }
  }

  void updateCloudIndexRefreshSchedule() {
    final minutes =
        (int.tryParse(
                  StorageManager.get<String>(
                        StorageKeys.cloudIndexRefreshMinutes,
                      ) ??
                      '30',
                ) ??
                30)
            .clamp(5, 1440);
    _scheduleCloudIndexRefresh(minutes);
  }

  int get _cloudIndexConcurrency =>
      (int.tryParse(
                StorageManager.get<String>(StorageKeys.cloudIndexConcurrency) ??
                    '6',
              ) ??
              6)
          .clamp(1, 20);

  bool get _doubanAutoRecognitionEnabled {
    final value = StorageManager.get<dynamic>(
      StorageKeys.doubanAutoRecognitionEnabled,
    );
    return value == true || value?.toString() == 'true';
  }

  Future<_CloudIndexRefreshResult> _rebuildGlobalCloudIndex() async {
    try {
      AppLogger.info('CloudIndex', '开始全盘分页索引（全量）');
      final files = await _allGlobalRemoteFiles();
      AppLogger.info('CloudIndex', '全盘分页索引完成：获取 ${files.length} 项（文件+目录）');
      final snapshots = <String?, List<CloudFile>>{null: <CloudFile>[]};
      var fileCount = 0;
      var dirCount = 0;
      for (final file in files) {
        final rawParentID = file.parentID?.trim();
        final parentID = rawParentID == null || rawParentID.isEmpty
            ? null
            : rawParentID;
        (snapshots[parentID] ??= []).add(file);
        if (file.isDirectory) {
          snapshots.putIfAbsent(file.id, () => <CloudFile>[]);
          dirCount++;
        } else {
          fileCount++;
        }
      }
      AppLogger.info('CloudIndex', '全盘分页索引分类：文件 $fileCount 个，目录 $dirCount 个，缓存 ${snapshots.length} 个文件夹');
      await FileMetadataCache.cacheFolderChildrenBatch(snapshots);
      return _CloudIndexRefreshResult(
        checkedFolders: snapshots.length,
        updatedFolders: snapshots.length,
        updatedEntries: files.length,
      );
    } catch (error, stackTrace) {
      AppLogger.warning('CloudIndex', '全盘分页接口刷新失败：$error');
      AppLogger.warning('CloudIndex', '堆栈：$stackTrace');
      return _CloudIndexRefreshResult(
        checkedFolders: 0,
        updatedFolders: 0,
        updatedEntries: 0,
      );
    }
  }

  Future<List<CloudFile>> _allGlobalRemoteFiles() async {
    final concurrency = _cloudIndexConcurrency;
    final files = await _allGlobalRemoteFilesByType(
      resType: 1,
      concurrency: concurrency,
    );
    final directories = await _allGlobalRemoteFilesByType(
      resType: 2,
      concurrency: concurrency,
    );
    final resources = <String, CloudFile>{
      for (final file in files) file.id: file,
      for (final directory in directories) directory.id: directory,
    }.values.toList(growable: false);
    AppLogger.info(
      'CloudIndex',
      '_allGlobalRemoteFiles 结果：文件 ${files.length} 项，目录 ${directories.length} 项',
    );
    return resources;
  }

  Future<List<CloudFile>> _allGlobalRemoteFilesByType({
    int? resType,
    required int concurrency,
  }) async {
    const pageSize = 1000;
    final values = <CloudFile>[];
    final seenIDs = <String>{};
    final typeLabel = resType == 2 ? '目录' : '文件';
    var nextPage = 0;
    var reachedEnd = false;
    var apiTotal = 0;

    while (!reachedEnd) {
      final pages = List.generate(concurrency, (index) => nextPage + index);
      final responses = await concurrentMapOrdered(
        pages,
        concurrency: concurrency,
        action: (page) async {
          AppLogger.debug('CloudIndex', '正在获取全盘$typeLabel索引，第 ${page + 1} 页');
          return _api!.fsFiles(
            parentID: '*',
            page: page,
            pageSize: pageSize,
            orderBy: 0,
            sortType: 0,
            resType: resType,
          );
        },
      );
      var allNewEmpty = true;
      for (var index = 0; index < responses.length; index++) {
        final page = pages[index];
        final respData = responses[index]['data'];
        if (respData is Map) {
          final t = respData['total'];
          if (t is int && t > apiTotal) apiTotal = t;
        }
        final batch = _extractFiles(responses[index]);
        final added = batch.where((file) => seenIDs.add(file.id)).toList();
        values.addAll(added);
        AppLogger.info(
          'CloudIndex',
          '全盘$typeLabel索引第 ${page + 1} 页完成，获取 ${batch.length} 项，'
              '新增 ${added.length} 项，累计 ${values.length} 项 / $apiTotal',
        );
        if (added.isNotEmpty) allNewEmpty = false;
        if (apiTotal > 0 && values.length >= apiTotal) {
          reachedEnd = true;
          break;
        }
        if (batch.isEmpty) {
          reachedEnd = true;
          break;
        }
      }
      if (!reachedEnd && allNewEmpty && responses.length < concurrency) {
        reachedEnd = true;
      }
      nextPage += pages.length;
    }
    return values;
  }

  Future<_CloudIndexRefreshResult> _rebuildGlobalCloudIndexByFolder() async {
    await FileMetadataCache.clearFolderChildrenIndex();
    final folders = <_CloudIndexFolder>[const _CloudIndexFolder(null, '根目录')];
    final visited = <String>{};
    final concurrency = _cloudIndexConcurrency;
    var nextFolder = 0;
    var updatedFolders = 0;
    var updatedEntries = 0;

    AppLogger.info('CloudIndex', '全量索引目录请求并发数：$concurrency');
    while (nextFolder < folders.length) {
      final batch = <_CloudIndexFolder>[];
      while (nextFolder < folders.length && batch.length < concurrency) {
        final folder = folders[nextFolder++];
        if (visited.add(folder.id ?? '@root')) batch.add(folder);
      }
      if (batch.isEmpty) continue;

      final snapshots = await concurrentMapOrdered(
        batch,
        concurrency: concurrency,
        action: _loadCloudIndexFolder,
      );
      await FileMetadataCache.cacheFolderChildrenBatch({
        for (var index = 0; index < batch.length; index++)
          batch[index].id: snapshots[index],
      });
      updatedFolders += batch.length;
      for (final snapshot in snapshots) {
        updatedEntries += snapshot.length;
        for (final child in snapshot.where((file) => file.isDirectory)) {
          folders.add(_CloudIndexFolder(child.id, child.name));
        }
      }
    }
    return _CloudIndexRefreshResult(
      checkedFolders: updatedFolders,
      updatedFolders: updatedFolders,
      updatedEntries: updatedEntries,
    );
  }

  Future<_CloudIndexRefreshResult> _refreshChangedCloudIndex() async {
    final root = const _CloudIndexFolder(null, '根目录');
    final folders = <_CloudIndexFolder>[root];
    final queued = <String>{'@root'};
    final concurrency = _cloudIndexConcurrency;
    var nextFolder = 0;
    var checkedFolders = 0;
    var updatedFolders = 0;
    var updatedEntries = 0;

    AppLogger.info('CloudIndex', '增量索引目录请求并发数：$concurrency');
    while (nextFolder < folders.length) {
      final end = (nextFolder + concurrency).clamp(0, folders.length);
      final batch = folders.sublist(nextFolder, end);
      nextFolder = end;
      final previousSnapshots = await Future.wait(
        batch.map(
          (folder) async =>
              await FileMetadataCache.folderChildren(folder.id) ??
              const <CloudFile>[],
        ),
      );
      final currentSnapshots = await concurrentMapOrdered(
        batch,
        concurrency: concurrency,
        action: _loadCloudIndexFolder,
      );
      checkedFolders += batch.length;

      final changed = <String?, List<CloudFile>>{};
      final removedFolders = <String>[];
      for (var index = 0; index < batch.length; index++) {
        final folder = batch[index];
        final previous = previousSnapshots[index];
        final current = currentSnapshots[index];
        if (!_sameCloudIndexSnapshot(previous, current)) {
          changed[folder.id] = current;
          updatedFolders += 1;
          updatedEntries += current.length;
          final currentIDs = current.map((file) => file.id).toSet();
          removedFolders.addAll(
            previous
                .where(
                  (file) => file.isDirectory && !currentIDs.contains(file.id),
                )
                .map((file) => file.id),
          );
        }
        _queueChangedIndexFolders(
          folders: folders,
          queued: queued,
          previous: previous,
          current: current,
        );
      }
      await FileMetadataCache.cacheFolderChildrenBatch(changed);
      if (removedFolders.isNotEmpty) {
        await FileMetadataCache.removeFolderChildrenSubtrees(removedFolders);
      }
    }
    return _CloudIndexRefreshResult(
      checkedFolders: checkedFolders,
      updatedFolders: updatedFolders,
      updatedEntries: updatedEntries,
    );
  }

  Future<List<CloudFile>> _loadCloudIndexFolder(
    _CloudIndexFolder folder,
  ) async {
    const pageSize = 1000;
    final values = <CloudFile>[];
    final ids = <String>{};
    for (var page = 0; ; page++) {
      AppLogger.info('CloudIndex', '正在检查目录「${folder.label}」第 ${page + 1} 页');
      List<CloudFile> batch = [];
      for (var retry = 0; retry < 3; retry++) {
        try {
          final response = await _api!.fsFiles(
            parentID: folder.id,
            page: page,
            pageSize: pageSize,
            orderBy: 0,
            sortType: 0,
          );
          batch = _extractFiles(response);
          break;
        } catch (e) {
          if (retry < 2) {
            AppLogger.warning('CloudIndex', '读取目录 ${folder.label} 失败（${retry + 1}/3），重试：$e');
            await Future<void>.delayed(Duration(seconds: (retry + 1) * 2));
          } else {
            AppLogger.warning('CloudIndex', '读取目录 ${folder.label} 3次均失败，跳过：$e');
            return values;
          }
        }
      }
      final added = batch.where((file) => ids.add(file.id)).toList();
      values.addAll(added);
      AppLogger.info(
        'CloudIndex',
        '目录「${folder.label}」第 ${page + 1} 页检查完成，获取 ${batch.length} 项',
      );
      if (batch.length < pageSize || added.isEmpty) break;
    }
    return values;
  }

  void _queueChangedIndexFolders({
    required List<_CloudIndexFolder> folders,
    required Set<String> queued,
    required List<CloudFile> previous,
    required List<CloudFile> current,
  }) {
    final previousByID = {for (final file in previous) file.id: file};
    for (final folder in current.where((file) => file.isDirectory)) {
      final prior = previousByID[folder.id];
      if (prior == null || _cloudIndexEntryChanged(prior, folder)) {
        if (queued.add(folder.id)) {
          folders.add(_CloudIndexFolder(folder.id, folder.name));
        }
      }
    }
  }

  bool _sameCloudIndexSnapshot(
    List<CloudFile> previous,
    List<CloudFile> current,
  ) {
    if (previous.length != current.length) return false;
    final previousByID = {for (final file in previous) file.id: file};
    if (previousByID.length != current.length) return false;
    return current.every(
      (file) =>
          previousByID[file.id] != null &&
          !_cloudIndexEntryChanged(previousByID[file.id]!, file),
    );
  }

  bool _cloudIndexEntryChanged(CloudFile previous, CloudFile current) =>
      previous.name != current.name ||
      previous.isDirectory != current.isDirectory ||
      previous.size != current.size ||
      previous.gcid != current.gcid ||
      previous.modifiedAt != current.modifiedAt ||
      previous.subDirectoryCount != current.subDirectoryCount ||
      previous.subFileCount != current.subFileCount;

  @override
  void dispose() {
    _cloudIndexTimer?.cancel();
    super.dispose();
  }

  void _appendScanLog(String message, {bool isError = false}) {
    final taskID = Zone.current[_mediaScanTaskZoneKey] as String?;
    if (isError) {
      AppLogger.error('Media', message);
    } else {
      AppLogger.info('Media', message);
    }
    if (taskID != null) {
      final current = state.taskByID(taskID);
      if (current != null) {
        var logs = [
          ...current.logs,
          MediaLibraryScanLog(
            createdAt: DateTime.now(),
            message: message,
            isError: isError,
          ),
        ];
        if (logs.length > 240) {
          logs = logs.sublist(logs.length - 240);
        }
        state = state.copyWith(
          scanTasks: [
            for (final task in state.scanTasks)
              if (task.id == taskID)
                current.copyWith(logs: logs, updatedAt: DateTime.now())
              else
                task,
          ],
        );
      }
    }
    final logs = [
      ...state.scanLogs,
      MediaLibraryScanLog(
        createdAt: DateTime.now(),
        message: message,
        isError: isError,
      ),
    ];
    if (logs.length > 120) logs.removeRange(0, logs.length - 120);
    state = state.copyWith(scanLogs: logs);
  }

  void _appendBackupLog(String message, {bool isError = false, Object? error}) {
    if (isError) {
      AppLogger.error('Backup', message, error: error);
    } else {
      AppLogger.info('Backup', message);
    }
    final logs = [
      ...state.scanLogs,
      MediaLibraryScanLog(
        createdAt: DateTime.now(),
        message: '【数据备份】$message',
        isError: isError,
      ),
    ];
    if (logs.length > 120) logs.removeRange(0, logs.length - 120);
    state = state.copyWith(scanLogs: logs);
    unawaited(_persistScanHistory());
  }

  String _backupFailureReason(Object error) {
    final value = error.toString().trim();
    var reason = value
        .replaceFirst(RegExp(r'^Exception:\s*'), '')
        .replaceFirst(RegExp(r'^DioException \[[^\]]+\]:\s*'), '网络请求失败：');
    // Deduplicate identical prefix before colon (e.g. "上传中：上传中" → "上传中")
    final colonIndex = reason.indexOf('：');
    if (colonIndex > 0) {
      final prefix = reason.substring(0, colonIndex).trim();
      final suffix = reason.substring(colonIndex + 1).trim();
      if (prefix.isNotEmpty && suffix.isNotEmpty && prefix == suffix) {
        reason = prefix;
      }
    }
    return reason;
  }

  String _cloudBackupFileName(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return 'media-library-${value.year}${two(value.month)}${two(value.day)}-'
        '${two(value.hour)}${two(value.minute)}${two(value.second)}.sqlite3';
  }

  List<MediaLibraryScanLog> _loadScanHistory() {
    final raw = StorageManager.get<dynamic>(StorageKeys.mediaScanHistory);
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map(
          (entry) =>
              MediaLibraryScanLog.fromJson(Map<String, dynamic>.from(entry)),
        )
        .where((entry) => entry.message.isNotEmpty)
        .take(120)
        .toList();
  }

  Future<void> _persistScanHistory() {
    final snapshot = state.scanLogs
        .map((entry) => entry.toJson())
        .toList(growable: false);
    _scanHistoryPersistence = _scanHistoryPersistence
        .catchError((_) {})
        .then((_) => StorageManager.set(StorageKeys.mediaScanHistory, snapshot))
        .catchError((error) {
          AppLogger.warning('Media', '媒体库扫描日志保存失败：$error');
        });
    return _scanHistoryPersistence;
  }

  void setSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
    unawaited(
      loadContent(home: _contentHome, filter: _contentFilter, search: query),
    );
  }

  Future<void> setSort(MediaLibrarySort sort) async {
    if (sort == state.sort) return;
    state = state.copyWith(sort: sort);
    await loadContent(
      home: _contentHome,
      filter: _contentFilter,
      search: _contentSearch,
    );
  }

  Future<void> setSortDirection(MediaSortDirection direction) async {
    if (direction == state.sortDirection) return;
    state = state.copyWith(sortDirection: direction);
    await loadContent(
      home: _contentHome,
      filter: _contentFilter,
      search: _contentSearch,
    );
  }

  Future<List<MediaLibraryItem>> searchAllItems(String query) async {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return const [];
    final cached = _searchResultsCache[normalized];
    if (cached != null) return cached;
    final results = await _store.itemsPage(search: normalized, limit: 500);
    results.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    _searchResultsCache[normalized] = results;
    return results;
  }

  Future<MediaLibraryItem> relocateMediaItemAsUnmatched(
    MediaLibraryItem previous,
    String libraryID,
    CloudFile file,
  ) async {
    final item = MediaLibraryItem.fromFile(
      libraryID,
      file,
      directoryName: _parentDirectoryName(file.cloudPath),
    );
    await _replaceItemsByPreviousIDs({
      '${previous.libraryID}:${previous.id}': item,
    });
    _searchResultsCache.clear();
    final allItems = await _loadAllItems();
    state = state.copyWith(
      items: state.selectedLibraryID == libraryID
          ? await _loadItems(libraryID)
          : state.items,
      allItems: allItems,
      statusMessage: '已加入目标媒体库，正在自动识别 ${file.name}',
      clearError: true,
    );
    await recognizeItems([item]);
    final refreshedItems = await _loadAllItems();
    final refreshed =
        refreshedItems
            .where(
              (value) => value.libraryID == libraryID && value.id == file.id,
            )
            .firstOrNull ??
        item;
    state = state.copyWith(
      items: state.selectedLibraryID == libraryID
          ? await _loadItems(libraryID)
          : state.items,
      allItems: refreshedItems,
      statusMessage: refreshed.isMatched
          ? '已加入目标媒体库并完成自动识别'
          : '已加入目标媒体库，自动识别未匹配',
      clearError: true,
    );
    return refreshed;
  }

  Future<void> recognizeItems(Iterable<MediaLibraryItem> values) async {
    final apiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    if (_api == null) return;
    final groups = <String, List<MediaLibraryItem>>{};
    for (final item in values) {
      final parsed = ParsedMediaName.parse(
        item.file.name,
        directoryName: _parentDirectoryName(item.file.cloudPath),
        directoryPath: item.file.cloudPath,
      );
      final key =
          '${item.mediaKind?.name ?? 'automatic'}:${parsed.title.toLowerCase()}';
      groups.putIfAbsent(key, () => []).add(item);
    }
    final updates = <MediaLibraryItem>[];
    for (final group in groups.values) {
      final prototype = group.first;
      final fallback = MediaLibraryItem.fromFile(
        prototype.libraryID,
        prototype.file,
        directoryName: _parentDirectoryName(prototype.file.cloudPath),
      );
      final recognized = await _recognizeMediaItem(
        fallback,
        apiKey,
        proxyHost: StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '',
        proxyPort: StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '',
      );
      final resolved = !recognized.isMatched && prototype.isMatched
          ? prototype
          : recognized.tmdbID == null && prototype.tmdbID != null
          ? prototype
          : recognized;
      updates.addAll(group.map((item) => resolved.copyWith(file: item.file)));
    }
    if (updates.isEmpty) return;
    await _store.upsertItems(updates);
    _searchResultsCache.clear();
    final byID = {for (final item in updates) item.id: item};
    final statistics = await _store.statistics();
    state = state.copyWith(
      items: state.items.map((item) => byID[item.id] ?? item).toList(),
      allItems: await _loadAllItems(),
      libraryStatistics: statistics.libraries,
      storedGlobalStatistics: statistics.global,
      statusMessage: '已识别 ${updates.length} 个资源（${groups.length} 个作品）',
    );
    final aggregatedSeries = <String>{};
    for (final item in updates) {
      final seriesKey = _seriesRecognitionKey(item);
      if (seriesKey != null &&
          item.tmdbID != null &&
          item.mediaKind == TMDBMediaKind.tv &&
          aggregatedSeries.add(seriesKey)) {
        await _aggregateStoredSeriesRecognition(seriesKey, item);
      }
    }
  }

  @visibleForTesting
  Future<MediaLibraryItem> recognizeMediaItemForTesting(
    MediaLibraryItem item, {
    required String apiKey,
  }) {
    return _recognizeMediaItem(item, apiKey, proxyHost: '', proxyPort: '');
  }

  @visibleForTesting
  bool validatePersistedTMDBDetailsForTesting(
    MediaLibraryItem item,
    Map<String, dynamic> details,
    TMDBMediaKind kind,
  ) {
    return _validatePersistedTMDBDetails(item, details, kind).isValid;
  }

  /// Pulls current file metadata from the cloud before parsing and matching it.
  /// This is required after a file was renamed outside the media scanner.
  Future<List<MediaTMDBMatchRequest>> refreshAndRecognizeItems(
    Iterable<MediaLibraryItem> values,
  ) async {
    final originals = values.toList(growable: false);
    if (originals.isEmpty) return const [];
    _cancelDetailSync = false;

    final seriesGroups = <String, List<MediaLibraryItem>>{};
    final ordinaryItems = <MediaLibraryItem>[];
    for (final item in originals) {
      final seriesKey = _seriesRecognitionKey(item);
      if (seriesKey == null) {
        ordinaryItems.add(item);
      } else {
        seriesGroups.putIfAbsent(seriesKey, () => []).add(item);
      }
    }
    final stagedGroups = seriesGroups.entries
        .where((entry) => entry.value.length > 1)
        .toList(growable: false);
    if (stagedGroups.isEmpty) {
      return _refreshAndRecognizeItemsBatch(originals);
    }

    final representatives = stagedGroups
        .map((entry) => entry.value.first)
        .toList(growable: false);
    _appendScanLog(
      '[同步识别][调试] 检测到 ${stagedGroups.length} 个剧集目录，'
      '先各识别 1 条代表资源，再处理同目录其余文件',
    );
    final pending = await _refreshAndRecognizeItemsBatch(representatives);
    if (_cancelDetailSync) return pending;

    final pendingSeriesKeys = <String>{};
    for (final request in pending) {
      for (final item in request.items) {
        final key = _seriesRecognitionKey(item);
        if (key != null) pendingSeriesKeys.add(key);
      }
    }
    final remainingKeys = <(String, String)>{
      for (final item in ordinaryItems) (item.libraryID, item.id),
      for (final entry in stagedGroups)
        if (!pendingSeriesKeys.contains(entry.key))
          for (final item in entry.value.skip(1)) (item.libraryID, item.id),
      for (final entry in seriesGroups.entries)
        if (entry.value.length == 1)
          (entry.value.first.libraryID, entry.value.first.id),
    };
    if (remainingKeys.isEmpty) return pending;

    final refreshedItems = await _loadAllItems();
    final refreshedByKey = {
      for (final item in refreshedItems) (item.libraryID, item.id): item,
    };
    final remaining = <MediaLibraryItem>[
      for (final original in originals)
        if (remainingKeys.contains((original.libraryID, original.id)))
          refreshedByKey[(original.libraryID, original.id)] ?? original,
    ];
    if (remaining.isEmpty) return pending;
    final followUp = await _refreshAndRecognizeItemsBatch(remaining);
    return [...pending, ...followUp];
  }

  Future<List<MediaTMDBMatchRequest>> _refreshAndRecognizeItemsBatch(
    Iterable<MediaLibraryItem> values,
  ) async {
    if (_api == null) return const [];
    final originals = values.toList();
    if (originals.isEmpty) return const [];
    final apiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    state = state.copyWith(statusMessage: '正在同步云盘文件信息…', clearError: true);
    final synced = <_SyncedMediaItem>[];
    final failures = <String>[];
    final missingByKey = <(String, String), MediaLibraryItem>{};
    final siblingReplacements = <String, MediaLibraryItem>{};
    final originalKeys = {
      for (final item in originals) (item.libraryID, item.id),
    };
    final expandedDirectories = <(String, String)>{};
    final resolutionRequests =
        <
          (String, String),
          Future<({CloudFile? file, bool confirmedNotFound})>
        >{};
    final folderFilesRequests = <String, Future<List<CloudFile>>>{};
    Future<List<MediaLibraryItem>>? storedItemsRequest;

    Future<({CloudFile? file, bool confirmedNotFound})> resolveItem(
      MediaLibraryItem item,
    ) {
      final key = (item.libraryID, item.id);
      return resolutionRequests.putIfAbsent(key, () async {
        var confirmedNotFound = false;
        final file = await _resolveCurrentCloudFile(
          item.file,
          libraryID: item.libraryID,
          folderFilesRequests: folderFilesRequests,
          onConfirmedNotFound: () => confirmedNotFound = true,
        );
        return (file: file, confirmedNotFound: confirmedNotFound);
      });
    }

    void addMissing(MediaLibraryItem item) {
      missingByKey[(item.libraryID, item.id)] = item;
    }

    Future<void> verifyDirectorySiblings(MediaLibraryItem trigger) async {
      final parentPath = _normalizedParentCloudPath(trigger.file.cloudPath);
      if (parentPath == null) {
        _appendScanLog(
          '[同步识别][调试] 无法从路径确定父目录，跳过兄弟资源核验：'
          '${trigger.file.cloudPath}',
        );
        return;
      }
      final directoryKey = (trigger.libraryID, parentPath);
      if (!expandedDirectories.add(directoryKey)) return;

      final storedItems = await (storedItemsRequest ??= _loadAllItems());
      final siblings = storedItems
          .where(
            (item) =>
                item.libraryID == trigger.libraryID &&
                item.id != trigger.id &&
                _normalizedParentCloudPath(item.file.cloudPath) == parentPath,
          )
          .toList(growable: false);
      final displayPath = parentPath.isEmpty ? '/' : parentPath;
      _appendScanLog(
        '[同步识别][调试] 已确认 ${trigger.file.name} 不存在，'
        '开始逐条核验同目录 $displayPath 的 ${siblings.length} 条媒体记录',
      );

      var recovered = 0;
      var confirmedMissing = 0;
      var retained = 0;
      for (final sibling in siblings) {
        if (_cancelDetailSync) break;
        try {
          final resolution = await resolveItem(sibling);
          if (_cancelDetailSync) break;
          final latest = resolution.file == null
              ? null
              : await _restoreCloudFilePath(
                  resolution.file!,
                  sibling.file,
                  libraryID: sibling.libraryID,
                );
          if (latest != null) {
            retained += 1;
            if (_cloudFileMappingChanged(sibling.file, latest)) {
              recovered += 1;
              if (!originalKeys.contains((sibling.libraryID, sibling.id))) {
                siblingReplacements['${sibling.libraryID}:${sibling.id}'] =
                    sibling.copyWith(file: latest, updatedAt: DateTime.now());
              }
              _appendScanLog(
                '[同步识别][调试] 同目录资源已恢复映射：'
                '${sibling.file.name} (${sibling.id} -> ${latest.id})，'
                '路径=${latest.cloudPath}',
              );
            }
            continue;
          }
          if (resolution.confirmedNotFound) {
            addMissing(sibling);
            confirmedMissing += 1;
            _appendScanLog(
              '[同步识别][调试] 同目录资源经独立 GCID/目录回查后确认不存在：'
              '${sibling.file.name} (fileId=${sibling.id})',
            );
          } else {
            retained += 1;
            _appendScanLog(
              '[同步识别][调试] 同目录资源未确认丢失，保留媒体记录：'
              '${sibling.file.name}',
            );
          }
        } catch (error) {
          retained += 1;
          failures.add('${sibling.file.name}: $error');
          _appendScanLog(
            '[同步识别][调试] 同目录资源核验失败，保留媒体记录：'
            '${sibling.file.name}，$error',
            isError: true,
          );
        }
      }
      _appendScanLog(
        '[同步识别][调试] 同目录核验完成：保留 $retained 条，'
        '更新映射 $recovered 条，确认不存在 $confirmedMissing 条',
      );
    }

    for (final original in originals) {
      if (_cancelDetailSync) break;
      try {
        _appendScanLog(
          '[同步识别][调试] 开始：${original.file.name} '
          '(fileId=${original.id}, gcid=${original.file.gcid ?? '-'})',
        );
        final resolution = await resolveItem(original);
        var latestFile = resolution.file;
        if (latestFile != null) {
          latestFile = await _restoreCloudFilePath(
            latestFile,
            original.file,
            libraryID: original.libraryID,
          );
        }
        if (_cancelDetailSync) break;
        if (latestFile == null) {
          if (!resolution.confirmedNotFound) {
            throw StateError('文件定位失败，未确认 404，已保留媒体记录');
          }
          addMissing(original);
          _appendScanLog(
            '[同步识别][调试] GCID 与目录回查均未找到：${original.file.name}，'
            '已确认为不存在记录',
          );
          await verifyDirectorySiblings(original);
          continue;
        }
        _appendScanLog(
          '[同步识别][调试] 云盘已同步：文件 ID ${original.id} -> '
          '${latestFile.id}，名称=${latestFile.name}，gcid=${latestFile.gcid ?? '-'}',
        );
        final recognitionFile = _withRecognitionPath(latestFile, original.file);
        synced.add(
          _SyncedMediaItem(
            original: original,
            fallback: MediaLibraryItem.fromFile(
              original.libraryID,
              recognitionFile,
              directoryName: _parentDirectoryName(recognitionFile.cloudPath),
            ),
          ),
        );
      } catch (error) {
        failures.add('${original.file.name}: $error');
        _appendScanLog(
          '[同步识别][调试] 同步失败：${original.file.name}，$error',
          isError: true,
        );
      }
    }
    if (siblingReplacements.isNotEmpty && !_cancelDetailSync) {
      await _replaceItemsByPreviousIDs(siblingReplacements);
      _searchResultsCache.clear();
      _appendScanLog('[同步识别][调试] 已更新 ${siblingReplacements.length} 条同目录资源映射');
    }
    final missing = missingByKey.values.toList(growable: false);
    if (missing.isNotEmpty && !_cancelDetailSync) {
      await _removeMissingMediaItems(missing);
      _appendScanLog('已删除 ${missing.length} 条云盘中不存在的媒体记录');
    }
    if (synced.isEmpty) {
      state = state.copyWith(
        errorMessage: _cancelDetailSync || failures.isEmpty
            ? null
            : '同步失败：${failures.first}',
        statusMessage: _cancelDetailSync
            ? '同步识别已取消'
            : missing.isNotEmpty && failures.isEmpty
            ? '已清理 ${missing.length} 条云盘中不存在的媒体记录'
            : '未能同步云盘文件信息',
      );
      return const [];
    }
    if (_cancelDetailSync) {
      state = state.copyWith(statusMessage: '同步识别已取消', clearError: true);
      return const [];
    }

    state = state.copyWith(statusMessage: '正在自动识别并规范命名…');
    final updates = <MediaLibraryItem>[];
    final replacements = <String, MediaLibraryItem>{};
    final pendingMatches = <MediaTMDBMatchRequest>[];
    final automaticMatches = <String, MediaLibraryItem>{};
    final matchedSeries = <String, MediaLibraryItem>{};
    var recognizedCount = 0;
    var renamedCount = 0;
    for (final entry in synced) {
      if (_cancelDetailSync) break;
      final original = entry.original;
      try {
        final fallback = entry.fallback;
        final parsed = ParsedMediaName.parse(
          fallback.file.name,
          directoryName: _parentDirectoryName(fallback.file.cloudPath),
          directoryPath: fallback.file.cloudPath,
        );
        final seriesKey = _seriesRecognitionKey(fallback);
        final recognitionKey =
            seriesKey ??
            '${fallback.libraryID}:${_normalizedParentCloudPath(fallback.file.cloudPath) ?? ''}:'
                '${_normalizeMediaTitle(parsed.title)}:${parsed.isEpisode}';
        _appendScanLog(
          '[同步识别][调试] 解析：${fallback.file.name} -> '
          '标题=${parsed.title}，年份=${parsed.year?.toString() ?? '未提供'}，'
          '类型=${fallback.mediaKind?.name ?? 'automatic'}',
        );
        final persistedKind = original.mediaKind ?? fallback.mediaKind;
        var rejectedPersistedMatch = false;
        var updated = original.tmdbID != null
            ? original.copyWith(
                file: fallback.file,
                mediaKind: persistedKind,
                updatedAt: DateTime.now(),
              )
            : automaticMatches[recognitionKey]?.copyWith(
                    file: fallback.file,
                    hasChineseAudio: original.hasChineseAudio,
                    hasChineseSubtitle: original.hasChineseSubtitle,
                    updatedAt: DateTime.now(),
                  ) ??
                  fallback;
        if (original.tmdbID != null && apiKey.trim().isNotEmpty) {
          if (persistedKind == null) {
            rejectedPersistedMatch = true;
            updated = fallback.copyWith(
              hasChineseAudio: original.hasChineseAudio,
              hasChineseSubtitle: original.hasChineseSubtitle,
            );
            _appendScanLog(
              '[同步识别][调试] 已保存的 TMDB ID 缺少媒体类型，'
              '废弃旧匹配并重新识别：${original.tmdbID}',
            );
          } else {
            try {
              final details = await _tmdbDetails(
                original.tmdbID!,
                persistedKind,
                apiKey: apiKey,
                proxyHost:
                    StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '',
                proxyPort:
                    StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '',
              );
              final validation = _validatePersistedTMDBDetails(
                fallback,
                details,
                persistedKind,
              );
              if (validation.isValid) {
                updated = _itemFromTMDBDetails(updated, details);
                _appendScanLog(
                  '[同步识别][调试] 使用已保存的 TMDB ID 刷新详情：'
                  '${original.tmdbID}（${validation.reason}）',
                );
              } else {
                rejectedPersistedMatch = true;
                updated = fallback.copyWith(
                  hasChineseAudio: original.hasChineseAudio,
                  hasChineseSubtitle: original.hasChineseSubtitle,
                );
                _appendScanLog(
                  '[同步识别][调试] 已保存的 TMDB ID 与当前资源不一致，'
                  '废弃旧匹配并重新识别：${original.tmdbID}，'
                  '${validation.reason}',
                );
              }
            } catch (error) {
              _appendScanLog(
                '[同步识别][调试] 已保存的 TMDB ID 详情刷新失败，'
                '保留现有匹配：${original.tmdbID}，$error',
                isError: true,
              );
            }
          }
        }
        if (updated.tmdbID == null && apiKey.trim().isNotEmpty) {
          final candidates = await _tmdbCandidatesForItem(
            fallback,
            apiKey,
            proxyHost:
                StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '',
            proxyPort:
                StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '',
          );
          if (_cancelDetailSync) break;
          if (candidates.length == 1) {
            updated = await _applyTMDBCandidateAndDetails(
              fallback,
              candidates.first,
              apiKey,
              proxyHost:
                  StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '',
              proxyPort:
                  StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '',
            );
            _appendScanLog(
              '[同步识别][调试] 自动匹配 TMDB 候选：'
              '${updated.title} (tmdbId=${updated.tmdbID ?? '-'})',
            );
            if (seriesKey == null || updated.mediaKind == TMDBMediaKind.tv) {
              automaticMatches[recognitionKey] = updated;
            }
          } else if (candidates.length > 1 &&
              (original.tmdbID == null || rejectedPersistedMatch)) {
            final parsed = ParsedMediaName.parse(
              fallback.file.name,
              directoryName: _parentDirectoryName(fallback.file.cloudPath),
              directoryPath: fallback.file.cloudPath,
            );
            final titleVariants = _recognitionTitleVariants(
              fallback,
              primaryTitle: parsed.title.trim().isEmpty
                  ? fallback.title
                  : parsed.title,
            );
            final doubanItems = await _searchDoubanCandidates(
              titleVariants,
              _requestedTMDBMediaKind(fallback, parsed),
              parsed.year,
            );
            var narrowed = candidates;
            if (doubanItems.isNotEmpty) {
              narrowed = _crossReferenceWithDouban(
                candidates,
                doubanItems,
                parsed,
              );
              final boosted = narrowed
                  .where((c) => c['_douban_boost'] == true)
                  .toList();
              if (boosted.length == 1) {
                updated = await _applyTMDBCandidateAndDetails(
                  fallback,
                  boosted.first,
                  apiKey,
                  proxyHost:
                      StorageManager.get<String>(StorageKeys.tmdbProxyHost) ??
                      '',
                  proxyPort:
                      StorageManager.get<String>(StorageKeys.tmdbProxyPort) ??
                      '',
                );
                _appendScanLog(
                  '[同步识别][调试] 豆瓣比对收敛：TMDB ${candidates.length} 候选中，'
                  '豆瓣匹配后自动选定 "${updated.title}" (tmdbId=${updated.tmdbID ?? '-'})',
                );
                if (seriesKey == null ||
                    updated.mediaKind == TMDBMediaKind.tv) {
                  automaticMatches[recognitionKey] = updated;
                }
              } else {
                pendingMatches.add(
                  MediaTMDBMatchRequest(
                    items: [fallback],
                    candidates: narrowed,
                  ),
                );
                _appendScanLog(
                  '[同步识别][调试] 豆瓣比对后仍有 ${narrowed.length} 个候选，等待用户选择',
                );
              }
            } else {
              pendingMatches.add(
                MediaTMDBMatchRequest(
                  items: [fallback],
                  candidates: candidates,
                ),
              );
              _appendScanLog(
                '[同步识别][调试] 存在 ${candidates.length} 个 TMDB 候选，等待用户选择',
              );
            }
          } else if (candidates.isEmpty && updated.tmdbID == null) {
            final parsed = ParsedMediaName.parse(
              fallback.file.name,
              directoryName: _parentDirectoryName(fallback.file.cloudPath),
              directoryPath: fallback.file.cloudPath,
            );
            final titleVariants = _recognitionTitleVariants(
              fallback,
              primaryTitle: parsed.title.trim().isEmpty
                  ? fallback.title
                  : parsed.title,
            );
            final doubanItems = await _searchDoubanCandidates(
              titleVariants,
              _requestedTMDBMediaKind(fallback, parsed),
              parsed.year,
            );
            if (doubanItems.isNotEmpty) {
              final doubanResult = _pickBestDoubanCandidate(
                fallback,
                parsed,
                titleVariants,
                _requestedTMDBMediaKind(fallback, parsed),
                doubanItems,
              );
              if (doubanResult != null) {
                updated = doubanResult;
                if (seriesKey == null ||
                    updated.mediaKind == TMDBMediaKind.tv) {
                  automaticMatches[recognitionKey] = updated;
                }
              }
            }
          }
        }
        if (updated.isMatched) {
          if (seriesKey != null && updated.mediaKind == TMDBMediaKind.tv) {
            automaticMatches[seriesKey] = updated;
            matchedSeries[seriesKey] = updated;
            pendingMatches.removeWhere(
              (request) => request.items.any(
                (item) => _seriesRecognitionKey(item) == seriesKey,
              ),
            );
          }
          recognizedCount++;
          final source = updated.tmdbID != null
              ? 'TMDB ${updated.tmdbID}'
              : '豆瓣 ${updated.doubanID ?? '-'}';
          _appendScanLog(
            '[同步识别][调试] 自动识别命中：${updated.title} '
            '($source, ${updated.year.isEmpty ? '年份未知' : updated.year})',
          );
        } else {
          _appendScanLog(
            '[同步识别][调试] 自动识别未命中：${parsed.title} '
            '(年份参数=${parsed.year?.toString() ?? '未提供'})',
          );
        }
        // A temporary TMDB or network failure must not erase a previously
        // scraped item just because its refreshed file metadata was available.
        if (((!updated.isMatched && original.isMatched) ||
                (updated.tmdbID == null && original.tmdbID != null)) &&
            !rejectedPersistedMatch) {
          updated = original.copyWith(
            file: fallback.file,
            updatedAt: DateTime.now(),
          );
        }
        final beforeName = updated.file.name;
        if (_cancelDetailSync) break;
        updated = await _renameMatchedMediaFile(updated);
        if (_cancelDetailSync) break;
        if (seriesKey != null &&
            updated.tmdbID != null &&
            updated.mediaKind == TMDBMediaKind.tv) {
          // Aggregation must use the final cloud mapping. Keeping the
          // pre-rename item here can overwrite the new file ID/path when the
          // sibling records are persisted below.
          matchedSeries[seriesKey] = updated;
          automaticMatches[seriesKey] = updated;
        }
        if (updated.file.name != beforeName) {
          renamedCount++;
          _appendScanLog(
            '[同步识别][调试] 已规范命名：$beforeName -> ${updated.file.name}',
          );
        } else if (updated.isMatched) {
          _appendScanLog('[同步识别][调试] 跳过规范命名：名称已符合规则');
        }
        updates.add(updated);
        replacements['${original.libraryID}:${original.id}'] = updated;
      } catch (error) {
        failures.add('${original.file.name}: $error');
        _appendScanLog(
          '[同步识别][调试] 识别失败：${original.file.name}，$error',
          isError: true,
        );
      }
    }
    if (_cancelDetailSync) {
      state = state.copyWith(statusMessage: '同步识别已取消', clearError: true);
      return const [];
    }
    if (updates.isNotEmpty) {
      await _replaceItemsByPreviousIDs(replacements);
      _searchResultsCache.clear();
      final byID = {for (final item in updates) item.id: item};
      final statistics = await _store.statistics();
      state = state.copyWith(
        items: state.items
            .map(
              (item) =>
                  replacements['${item.libraryID}:${item.id}'] ??
                  byID[item.id] ??
                  item,
            )
            .toList(),
        allItems: await _loadAllItems(),
        libraryStatistics: statistics.libraries,
        storedGlobalStatistics: statistics.global,
        statusMessage: _cancelDetailSync
            ? '同步识别已取消，已处理 ${updates.length} 个资源'
            : failures.isEmpty
            ? '已同步 ${updates.length} 个资源，自动识别 $recognizedCount 个，规范命名 $renamedCount 个'
            : '已同步 ${updates.length} 个资源，识别 $recognizedCount 个，规范命名 $renamedCount 个，${failures.length} 个失败',
        errorMessage: failures.isEmpty ? null : failures.first,
      );
      for (final entry in matchedSeries.entries) {
        await _aggregateStoredSeriesRecognition(entry.key, entry.value);
      }
    }
    return pendingMatches;
  }

  /// Keeps SQLite media records aligned with file-manager rename operations
  /// without re-scraping or overriding a user-initiated name change.
  Future<void> synchronizeRenamedFiles(Iterable<CloudFile> values) async {
    if (_api == null) return;
    final renamed = {for (final file in values) file.id: file}.values.toList();
    if (renamed.isEmpty) return;
    final allItems = await _loadAllItems();
    final replacements = <String, MediaLibraryItem>{};

    for (final renamedFile in renamed) {
      final oldPath = renamedFile.cloudPath;
      final newPath = _cloudPathWithName(oldPath, renamedFile.name);
      if (renamedFile.isDirectory) {
        for (final item in allItems) {
          final path = item.file.cloudPath;
          if (path != oldPath && !path.startsWith('$oldPath/')) continue;
          final suffix = path.substring(oldPath.length);
          final updated = item.copyWith(
            file: item.file.copyWith(cloudPath: '$newPath$suffix'),
            updatedAt: DateTime.now(),
          );
          replacements['${item.libraryID}:${item.id}'] = updated;
        }
        final resolved = await _resolveCurrentCloudFile(renamedFile);
        if (resolved != null && resolved.id != renamedFile.id) {
          await FileMetadataCache.updateFolderChildren(
            renamedFile.id,
            invalidate: true,
          );
        }
        continue;
      }

      for (final item in allItems.where((item) => item.id == renamedFile.id)) {
        final known = item.file.copyWith(
          name: renamedFile.name,
          cloudPath: newPath,
          parentID: renamedFile.parentID,
          fullParentIDs: renamedFile.fullParentIDs,
        );
        final resolved =
            await _resolveCurrentCloudFile(known, libraryID: item.libraryID) ??
            known;
        replacements['${item.libraryID}:${item.id}'] = item.copyWith(
          file: resolved,
          updatedAt: DateTime.now(),
        );
      }
    }
    if (replacements.isEmpty) return;
    await _replaceItemsByPreviousIDs(replacements);
    _searchResultsCache.clear();
    state = state.copyWith(
      items: state.items
          .map((item) => replacements['${item.libraryID}:${item.id}'] ?? item)
          .toList(),
      allItems: await _loadAllItems(),
    );
  }

  Future<void> transferMediaRecords(
    Iterable<MediaLibraryItem> values, {
    required String targetLibraryID,
    required String sourceRootPath,
    required String destinationRootPath,
    required String movedNodeID,
    required String? targetParentID,
  }) async {
    final records = {
      for (final item in values) '${item.libraryID}:${item.id}': item,
    }.values.toList(growable: false);
    if (records.isEmpty) return;

    String destinationPathFor(String path) {
      if (path == sourceRootPath) return destinationRootPath;
      if (!path.startsWith('$sourceRootPath/')) {
        throw StateError('资源路径不在所选移动层级中：$path');
      }
      return '$destinationRootPath${path.substring(sourceRootPath.length)}';
    }

    final now = DateTime.now();
    final replacements = <String, MediaLibraryItem>{};
    for (final item in records) {
      final movesFileDirectly = item.id == movedNodeID;
      final file = item.file.copyWith(
        cloudPath: destinationPathFor(item.file.cloudPath),
        parentID: movesFileDirectly ? targetParentID : item.file.parentID,
        clearParentID: movesFileDirectly && targetParentID == null,
        clearFullParentIDs: movesFileDirectly,
      );
      replacements['${item.libraryID}:${item.id}'] = item.copyWith(
        libraryID: targetLibraryID,
        file: file,
        updatedAt: now,
      );
    }

    await _replaceItemsByPreviousIDs(replacements);
    await _store.removeFilesFromAllFolders(records.map((item) => item.id));
    _cachedCloudEntries = null;
    _searchResultsCache.clear();
    final allItems = await _loadAllItems();
    final selectedLibraryID = state.selectedLibraryID;
    state = state.copyWith(
      items: selectedLibraryID == null
          ? const <MediaLibraryItem>[]
          : await _loadItems(selectedLibraryID),
      allItems: allItems,
      statusMessage: '已移动 ${records.length} 个媒体资源到其他媒体库',
      clearError: true,
    );
  }

  Future<void> clearMediaMetadata(
    Iterable<MediaLibraryItem> values, {
    required bool clearTMDB,
    required bool clearDouban,
  }) async {
    final records = {
      for (final item in values) '${item.libraryID}:${item.id}': item,
    }.values.toList();
    if (records.isEmpty || (!clearTMDB && !clearDouban)) return;

    final replacements = <String, MediaLibraryItem>{};
    for (final item in records) {
      final keepsTMDB = !clearTMDB && item.tmdbID != null;
      final keepsDouban =
          !clearDouban && item.doubanID?.trim().isNotEmpty == true;
      final updated = keepsTMDB || keepsDouban
          ? item.copyWith(
              clearTMDBID: clearTMDB,
              clearDoubanID: clearDouban,
              clearTMDBRating: clearTMDB,
              clearDoubanRating: clearDouban,
              clearImdbID: clearTMDB,
              clearCollectionID: clearTMDB,
              clearCollectionName: clearTMDB,
              updatedAt: DateTime.now(),
            )
          : MediaLibraryItem.fromFile(
              item.libraryID,
              item.file,
              directoryName: _parentDirectoryName(item.file.cloudPath),
            ).copyWith(
              hasChineseAudio: item.hasChineseAudio,
              hasChineseSubtitle: item.hasChineseSubtitle,
            );
      replacements['${item.libraryID}:${item.id}'] = updated;
    }

    await _replaceItemsByPreviousIDs(replacements);
    _searchResultsCache.clear();
    state = state.copyWith(
      items: state.items
          .map((item) => replacements['${item.libraryID}:${item.id}'] ?? item)
          .toList(),
      allItems: await _loadAllItems(),
      statusMessage: clearTMDB && clearDouban
          ? '已清除识别信息'
          : clearTMDB
          ? '已清除 TMDB 信息'
          : '已清除豆瓣信息',
      clearError: true,
    );
  }

  /// Manual match fast path.
  ///
  /// Writes the selected TMDB/Douban id and the metadata already carried by the
  /// search candidate (title, poster, rating, kind) to the database
  /// immediately, updates the UI and returns — so the manual-match dialog is
  /// snappy instead of blocking on a TMDB detail request and a cloud rename.
  /// The expensive work (full detail hydration + canonical file rename) is then
  /// scheduled as a background task via [_enrichManualMatchInBackground].
  Future<MediaLibraryItem> applyTMDBMatch(
    MediaLibraryItem item,
    Map<String, dynamic> candidate, {
    bool applyManualEpisodeOverride = true,
  }) async {
    final candidateSeason = _toInt(candidate['_manualSeason']);
    final candidateEpisode = _toInt(candidate['_manualEpisode']);
    final manualSeason = applyManualEpisodeOverride ? candidateSeason : null;
    final manualEpisode = applyManualEpisodeOverride ? candidateEpisode : null;
    // Instant: build the row from the search candidate (id + basic metadata).
    final updated = _itemFromTMDBCandidate(
      item,
      candidate,
    ).copyWith(updatedAt: DateTime.now());
    await _replaceItemsByPreviousIDs({'${item.libraryID}:${item.id}': updated});
    state = state.copyWith(
      items: state.items
          .map(
            (current) =>
                current.libraryID == item.libraryID && current.id == item.id
                ? updated
                : current,
          )
          .toList(),
      statusMessage: '已匹配《${updated.title}》，正在后台补全刮削信息…',
      clearError: true,
    );
    // Background: hydrate full details, rename the file, re-persist, refresh.
    // Serialized through a tail future so concurrent episode matches don't race
    // on the shared items list.
    _manualMatchEnrichment += 1;
    _manualMatchEnrichmentTail = _manualMatchEnrichmentTail.then(
      (_) => _enrichManualMatchInBackground(
        updated,
        manualSeason: manualSeason,
        manualEpisode: manualEpisode,
      ),
    );
    // 后台补全完成后刷新 allItems
    unawaited(_manualMatchEnrichmentTail.then((_) async {
      state = state.copyWith(allItems: await _loadAllItems());
    }));
    return updated;
  }

  /// Completes a manual match off the UI path: fetches full TMDB details,
  /// applies the canonical rename, persists the result and refreshes state.
  Future<void> _enrichManualMatchInBackground(
    MediaLibraryItem item, {
    int? manualSeason,
    int? manualEpisode,
  }) async {
    try {
      final apiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
      var enriched = item;
      if (enriched.tmdbID != null && apiKey.isNotEmpty) {
        try {
          final details = await _tmdbDetails(
            enriched.tmdbID!,
            enriched.mediaKind,
            apiKey: apiKey,
            proxyHost:
                StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '',
            proxyPort:
                StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '',
          );
          enriched = _itemFromTMDBDetails(enriched, details);
        } catch (error) {
          // A selected candidate is still valid if its detail request fails.
          AppLogger.warning(
            'Media',
            '手动匹配后台详情补全失败：id=${enriched.tmdbID}，$error',
          );
        }
      }
      final renamed = await _renameMatchedMediaFile(
        enriched,
        manualSeason: manualSeason,
        manualEpisode: manualEpisode,
      );
      // The instant write used the candidate id as the row key; the rename may
      // have changed the underlying cloud file id, so replace by that key.
      await _replaceItemsByPreviousIDs({
        '${item.libraryID}:${item.id}': renamed,
      });
      final pending = _manualMatchEnrichment - 1;
      state = state.copyWith(
        items: state.items
            .map(
              (current) =>
                  current.libraryID == item.libraryID && current.id == item.id
                  ? renamed
                  : current,
            )
            .toList(),
        allItems: await _loadAllItems(),
        statusMessage: pending > 0
            ? '正在后台补全刮削信息…（剩余 $pending 项）'
            : renamed.file.name == item.file.name
            ? '已补全《${renamed.title}》的刮削信息'
            : '已补全并规范命名《${renamed.title}》',
        clearError: true,
      );
      final seriesKey = _seriesRecognitionKey(item);
      if (seriesKey != null &&
          renamed.tmdbID != null &&
          renamed.mediaKind == TMDBMediaKind.tv) {
        await _aggregateStoredSeriesRecognition(seriesKey, renamed);
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        'Media',
        '手动匹配后台任务异常：${item.file.name}',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _manualMatchEnrichment -= 1;
    }
  }

  /// Refresh legacy unmatched records with the current filename parser before
  /// showing a manual TMDB search. Matched items retain TMDB's canonical title.
  Future<List<MediaLibraryItem>> refreshParsedTitles(
    Iterable<MediaLibraryItem> values,
  ) async {
    final updates = <MediaLibraryItem>[];
    for (final item in values) {
      if (item.tmdbID != null) {
        updates.add(item);
        continue;
      }
      final parsed = ParsedMediaName.parse(
        item.file.name,
        directoryName: _parentDirectoryName(item.file.cloudPath),
        directoryPath: item.file.cloudPath,
      );
      final title = parsed.title.trim();
      if (title.isEmpty) {
        updates.add(item);
        continue;
      }
      updates.add(
        item.copyWith(
          title: title,
          originalTitle: title,
          releaseDate: parsed.year == null
              ? item.releaseDate
              : '${parsed.year}-01-01',
          updatedAt: DateTime.now(),
        ),
      );
    }
    if (updates.isEmpty) return const [];
    final replacements = {
      for (final item in updates) '${item.libraryID}:${item.id}': item,
    };
    await _replaceItemsByPreviousIDs(replacements);
    _searchResultsCache.clear();
    state = state.copyWith(
      items: state.items
          .map((item) => replacements['${item.libraryID}:${item.id}'] ?? item)
          .toList(),
      allItems: await _loadAllItems(),
    );
    return updates;
  }

  /// Old scrape backups stored artwork as BLOBs.  The compact SQLite schema
  /// deliberately drops those images, so restore the durable TMDB paths from
  /// their retained IDs in the background after an import or first load.
  Future<void> _hydrateMissingArtwork(
    String libraryID,
    List<MediaLibraryItem> items,
  ) async {
    if (_api == null || _artworkHydrationLibraries.contains(libraryID)) return;
    final apiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    if (apiKey.trim().isEmpty) return;

    final missingByTMDB = <String, List<MediaLibraryItem>>{};
    for (final item in items) {
      final id = item.tmdbID;
      final kind = item.mediaKind;
      final missingPoster = item.posterPath == null || item.posterPath!.isEmpty;
      final missingBackdrop =
          item.backdropPath == null || item.backdropPath!.isEmpty;
      if (id == null || kind == null || (!missingPoster && !missingBackdrop)) {
        continue;
      }
      missingByTMDB.putIfAbsent('${kind.name}:$id', () => []).add(item);
    }
    if (missingByTMDB.isEmpty) return;

    _artworkHydrationLibraries.add(libraryID);
    final proxyHost =
        StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '';
    final proxyPort =
        StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '';
    final concurrency =
        (int.tryParse(
                  StorageManager.get<String>(
                        StorageKeys.mediaScanConcurrency,
                      ) ??
                      '6',
                ) ??
                6)
            .clamp(1, 12);
    final groups = missingByTMDB.entries.toList();
    var completed = 0;

    try {
      for (var start = 0; start < groups.length; start += concurrency) {
        final batch = groups.sublist(
          start,
          (start + concurrency).clamp(0, groups.length),
        );
        final results = await Future.wait(
          batch.map((entry) async {
            final prototype = entry.value.first;
            try {
              final details = await _tmdbDetails(
                prototype.tmdbID!,
                prototype.mediaKind,
                apiKey: apiKey,
                proxyHost: proxyHost,
                proxyPort: proxyPort,
              );
              return entry.value
                  .map((item) => _itemFromTMDBDetails(item, details))
                  .toList();
            } catch (error) {
              AppLogger.warning(
                'Media',
                '影视详情补图失败：tmdbId=${prototype.tmdbID}，$error',
              );
              return const <MediaLibraryItem>[];
            }
          }),
        );
        final updates = results.expand((items) => items).toList();
        completed += batch.length;
        if (updates.isNotEmpty) await _store.upsertItems(updates);
        if (state.selectedLibraryID == libraryID) {
          final updatedByID = {for (final item in updates) item.id: item};
          state = state.copyWith(
            items: state.items
                .map((item) => updatedByID[item.id] ?? item)
                .toList(),
            statusMessage: completed == groups.length
                ? '已补齐 ${groups.length} 个影视条目的海报与横幅'
                : '正在补齐影视图片 $completed/${groups.length}',
          );
        }
      }
    } finally {
      _artworkHydrationLibraries.remove(libraryID);
    }
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }

  /// Exhausts the ordered title evidence for one resource. Each title is
  /// searched with the parsed year first, then without a year constraint.
  /// Recognition only fails after every title/year strategy has been tried.
  Future<_TMDBRecognitionSearchResult> _tmdbSearchForRecognition(
    List<_MediaTitleVariant> variants, {
    required String mediaKind,
    required int? year,
    required String apiKey,
    required String proxyHost,
    required String proxyPort,
    required String? country,
  }) async {
    if (_api == null || variants.isEmpty) {
      return const _TMDBRecognitionSearchResult(candidates: [], attempts: []);
    }

    final attempts = <String>[];
    final allRelated = <String, Map<String, dynamic>>{};
    for (final variant in variants) {
      final years = year == null ? <int?>[null] : <int?>[year, null];
      for (final attemptYear in years) {
        Map<String, dynamic> result;
        // 1. 先不带国家参数查询（获取原始发行时间）
        Map<String, dynamic>? originalResult;
        try {
          originalResult = await _api!.tmdbSearch(
            variant.value,
            apiKey: apiKey,
            mediaKind: mediaKind,
            proxyHost: proxyHost,
            proxyPort: proxyPort,
            year: attemptYear,
            // country: null,
          );
        } catch (error) {
          attempts.add(
            '${variant.source}="${variant.value}"，'
            '${attemptYear == null ? '不带年份' : '年份=$attemptYear'} -> 请求失败：$error',
          );
          continue;
        }

        // 2. 检查返回结果是否年份匹配
        final values = originalResult['results'];
        if (values is! List) {
          attempts.add(
            '${variant.source}="${variant.value}"，'
            '${attemptYear == null ? '不带年份' : '年份=$attemptYear'} -> 返回格式无效',
          );
          continue;
        }

        // 检查是否有年份匹配的候选
        final yearCompatibleCandidates = <Map<String, dynamic>>[];
        for (final value in values) {
          if (value is! Map) continue;
          final candidate = Map<String, dynamic>.from(value);
          final releaseDate =
              (candidate['release_date'] ?? candidate['first_air_date'])?.toString() ??
              '';
          if (releaseDate.isEmpty || releaseDate.startsWith('$attemptYear')) {
            yearCompatibleCandidates.add(candidate);
          }
        }

        // 3. 如果没有匹配的候选，尝试用国家参数查询
        if (yearCompatibleCandidates.isEmpty && country != null && country != 'CN' && attemptYear != null) {
          try {
            final countryResult = await _api!.tmdbSearch(
              variant.value,
              apiKey: apiKey,
              mediaKind: mediaKind,
              proxyHost: proxyHost,
              proxyPort: proxyPort,
              year: attemptYear,
              country: country,
            );

            // 检查国家参数查询结果是否有匹配的候选
            final countryValues = countryResult['results'];
            if (countryValues is! List) continue;

            for (final value in countryValues) {
              if (value is! Map) continue;
              final candidate = Map<String, dynamic>.from(value);
              final releaseDate =
                  (candidate['release_date'] ?? candidate['first_air_date'])?.toString() ??
                  '';
              if (releaseDate.isEmpty || releaseDate.startsWith('$attemptYear')) {
                yearCompatibleCandidates.add(candidate);
              }
            }

            // 如果国家参数查询找到了年份匹配的候选，用国家查询结果替换原始结果
            if (yearCompatibleCandidates.isNotEmpty) {
              originalResult = countryResult;
            }
          } catch (retryError) {
            attempts.add(
              '${variant.source}="${variant.value}"，'
              '年份=$attemptYear，国家=$country -> 重试失败：$retryError',
            );
          }
        }

        // 4. 使用匹配的候选，如果没有则使用原始结果
        if (yearCompatibleCandidates.isNotEmpty) {
          result = originalResult!;
        } else {
          attempts.add(
            '${variant.source}="${variant.value}"，'
            '${attemptYear == null ? '不带年份' : '年份=$attemptYear'} -> 无匹配结果',
          );
        }

        final typedCandidates = <Map<String, dynamic>>[];
        final yearCompatibleTypedCandidates = <Map<String, dynamic>>[];
        for (final value in values) {
          if (value is! Map) continue;
          final candidate = Map<String, dynamic>.from(value);
          final type =
              candidate['media_type']?.toString() ??
              (mediaKind == 'movie' || mediaKind == 'tv' ? mediaKind : null);
          if (type != 'movie' && type != 'tv') continue;
          if (mediaKind != 'auto' && type != mediaKind) continue;
          candidate['media_type'] = type;
          typedCandidates.add(candidate);
          if (attemptYear != null) {
            final releaseDate =
                (candidate['release_date'] ?? candidate['first_air_date'])
                    ?.toString() ??
                '';
            if (releaseDate.isEmpty || releaseDate.startsWith('$attemptYear')) {
              yearCompatibleTypedCandidates.add(candidate);
            }
          }
        }
        final detailFallbackYear = attemptYear ?? year;
        final detailFallbackCandidates =
            typedCandidates.length == 1 &&
                _allowsUniqueQueryFallback(variant.value)
            ? typedCandidates
            : detailFallbackYear == null
            ? typedCandidates
            : typedCandidates
                  .where((candidate) {
                    final candidateYear = _tmdbCandidateYear(candidate);
                    return candidateYear == null ||
                        _tmdbYearDelta(candidateYear, detailFallbackYear) <= 1;
                  })
                  .toList(growable: false);

        var relatedCount = 0;
        final related = <String, Map<String, dynamic>>{};
        for (final value in values) {
          if (value is! Map) continue;
          final candidate = Map<String, dynamic>.from(value);
          final type =
              candidate['media_type']?.toString() ??
              (mediaKind == 'movie' || mediaKind == 'tv' ? mediaKind : null);
          if (type != 'movie' && type != 'tv') continue;
          if (mediaKind != 'auto' && type != mediaKind) continue;
          candidate['media_type'] = type;
          final releaseDate =
              (candidate['release_date'] ?? candidate['first_air_date'])
                  ?.toString() ??
              '';
          final expectedYearMatches =
              attemptYear == null ||
              releaseDate.isEmpty ||
              releaseDate.startsWith('$attemptYear');
          final titleMatch = _bestMediaTitleMatch(
            variant.value,
            title: (candidate['title'] ?? candidate['name'] ?? '').toString(),
            originalTitle:
                (candidate['original_title'] ??
                        candidate['original_name'] ??
                        '')
                    .toString(),
          );
          final uniqueExactYearFallback =
              titleMatch.score == 0 &&
              attemptYear != null &&
              expectedYearMatches &&
              yearCompatibleTypedCandidates.length == 1 &&
              yearCompatibleTypedCandidates.single['id']?.toString() ==
                  candidate['id']?.toString();
          final uniqueSpecificQueryFallback =
              titleMatch.score == 0 &&
              year == null &&
              attemptYear == null &&
              typedCandidates.length == 1 &&
              _allowsUniqueQueryFallback(variant.value) &&
              typedCandidates.single['id']?.toString() ==
                  candidate['id']?.toString();
          if ((titleMatch.score > 0 ||
                  uniqueExactYearFallback ||
                  uniqueSpecificQueryFallback) &&
              expectedYearMatches) {
            relatedCount++;
            candidate['_recognitionTitle'] = variant.value;
            candidate['_recognitionSource'] = variant.source;
            candidate['_recognitionYear'] = attemptYear;
            candidate['_recognitionTitleScore'] = titleMatch.score;
            if (uniqueExactYearFallback) {
              candidate['_recognitionUniqueExactYear'] = true;
            }
            if (uniqueSpecificQueryFallback) {
              candidate['_recognitionUniqueSpecificQuery'] = true;
            }
            final id = candidate['id']?.toString();
            final key = id == null || id.isEmpty
                ? '$type:${candidate['title'] ?? candidate['name']}'
                : '$type:$id';
            related[key] = candidate;
          }
        }
        final fallbackLabel =
            related.values.any(
              (candidate) => candidate['_recognitionUniqueExactYear'] == true,
            )
            ? '（含精确查询+年份唯一候选兜底）'
            : related.values.any(
                (candidate) =>
                    candidate['_recognitionUniqueSpecificQuery'] == true,
              )
            ? '（含无年份具体查询唯一候选兜底）'
            : '';
        attempts.add(
          '${variant.source}="${variant.value}"，'
          '${attemptYear == null ? '不带年份' : '年份=$attemptYear'} -> '
          '${values.length} 条，相关 $relatedCount 条$fallbackLabel',
        );
        if (relatedCount == 0 &&
            detailFallbackCandidates.isNotEmpty &&
            detailFallbackCandidates.length <= 6 &&
            (_allowsDetailsQueryFallback(variant.value) ||
                (detailFallbackCandidates.length == 1 &&
                    _allowsSingleCandidateDetailsFallback(variant.value)))) {
          for (final candidate in detailFallbackCandidates) {
            candidate['_recognitionTitle'] = variant.value;
            candidate['_recognitionSource'] = variant.source;
            candidate['_recognitionYear'] = detailFallbackYear;
            candidate['_recognitionTitleScore'] = 0;
            candidate['_recognitionNeedsDetails'] = true;
            final type = candidate['media_type']?.toString() ?? mediaKind;
            final id = candidate['id']?.toString();
            final key = id == null || id.isEmpty
                ? '$type:${candidate['title'] ?? candidate['name']}'
                : '$type:$id';
            allRelated.putIfAbsent(key, () => candidate);
          }
          attempts[attempts.length - 1] =
              '${attempts.last}（保留 ${detailFallbackCandidates.length} 条待详情翻译核验）';
        }
        if (relatedCount > 0) {
          for (final entry in related.entries) {
            final previous = allRelated[entry.key];
            final previousScore =
                _toInt(previous?['_recognitionTitleScore']) ?? -1;
            final currentScore =
                _toInt(entry.value['_recognitionTitleScore']) ?? -1;
            if (previous == null || currentScore > previousScore) {
              allRelated[entry.key] = entry.value;
            }
          }
          final decisive = related.values
              .where((candidate) {
                return candidate['_recognitionUniqueExactYear'] == true ||
                    candidate['_recognitionUniqueSpecificQuery'] == true ||
                    (_toInt(candidate['_recognitionTitleScore']) ?? 0) >= 95;
              })
              .toList(growable: false);
          // A broad title can produce several plausible works. Keep trying
          // parent, alias and alternate-language evidence until one strategy
          // produces a single exact candidate.
          if (decisive.length == 1) {
            return _TMDBRecognitionSearchResult(
              candidates: decisive,
              attempts: attempts,
            );
          }
          if (related.length == 1 &&
              typedCandidates.length == 1 &&
              _allowsSpecificRelatedResultFallback(variant.value)) {
            return _TMDBRecognitionSearchResult(
              candidates: related.values.toList(growable: false),
              attempts: attempts,
            );
          }
        }
      }
    }
    // ── 指定类型(movie/tv)无结果或结果不足时，用 auto 重试并比对年份 ──
    if (mediaKind != 'auto') {
      for (final variant in variants) {
        try {
          final autoResult = await _api!.tmdbSearch(
            variant.value,
            apiKey: apiKey,
            mediaKind: 'auto',
            proxyHost: proxyHost,
            proxyPort: proxyPort,
            year: year,
          );
          final values = autoResult['results'];
          if (values is! List) continue;
          for (final value in values) {
            if (value is! Map) continue;
            final candidate = Map<String, dynamic>.from(value);
            final type = candidate['media_type']?.toString();
            if (type != 'movie' && type != 'tv') continue;
            candidate['media_type'] = type;
            final releaseDate =
                (candidate['release_date'] ?? candidate['first_air_date'])
                    ?.toString() ?? '';
            // 年份比对：有年份时要求匹配，无年份时只要类型正确就接受
            final yearMatch = year == null ||
                releaseDate.isEmpty ||
                releaseDate.startsWith('$year');
            if (yearMatch) {
              candidate['_recognitionTitle'] = variant.value;
              candidate['_recognitionSource'] = variant.source;
              candidate['_recognitionYear'] = year;
              candidate['_recognitionFromAutoRetry'] = true;
              final id = candidate['id']?.toString();
              final key = id == null || id.isEmpty
                  ? '$type:${candidate['title'] ?? candidate['name']}'
                  : '$type:$id';
              allRelated[key] = candidate;
            }
          }
          attempts.add(
            'auto 重试：${variant.value}，年份=$year -> '
            '${allRelated.length} 条',
          );
          if (allRelated.length == 1) break;
        } catch (retryError) {
          attempts.add(
            'auto 重试失败：${variant.value}，$retryError',
          );
        }
      }
    }
    return _TMDBRecognitionSearchResult(
      candidates: allRelated.values.toList(growable: false),
      attempts: attempts,
    );
  }

  bool _allowsUniqueQueryFallback(String value) {
    final normalized = _normalizeMediaTitle(value);
    if (normalized.length < 6) return false;
    if (RegExp(
      r'\b(?:web[- ]?dl|webrip|bluray|remux|hdtv|kktv|aac\d*|ddp\d*|hevc|avc|x26[45]|h[ .]?26[45]|2160p|1080p|720p)\b',
      caseSensitive: false,
    ).hasMatch(value)) {
      return false;
    }
    if (RegExp(r'[\u4e00-\u9fff]').hasMatch(value)) {
      return normalized.length >= 6;
    }
    if (RegExp(r'[\u0400-\u052f]').hasMatch(value)) {
      return normalized.length >= 10;
    }
    if (RegExp(r'[\u3040-\u30ff\uac00-\ud7af]').hasMatch(value)) {
      return normalized.length >= 4;
    }
    final words = RegExp(r'[A-Za-z0-9]+')
        .allMatches(value)
        .map((match) => match.group(0)!)
        .where((word) => word.length >= 2)
        .toList(growable: false);
    return normalized.length >= 15 && words.length >= 4;
  }

  bool _allowsDetailsQueryFallback(String value) {
    if (_allowsUniqueQueryFallback(value)) return true;
    final normalized = _normalizeMediaTitle(value);
    if (normalized.length < 4) return false;
    if (RegExp(
      r'\b(?:web[- ]?dl|webrip|bluray|remux|hdtv|kktv|aac\d*|ddp\d*|hevc|avc|x26[45]|h[ .]?26[45]|2160p|1080p|720p)\b',
      caseSensitive: false,
    ).hasMatch(value)) {
      return false;
    }
    if (!RegExp(r'[\u4e00-\u9fff]').hasMatch(value)) return false;
    return RegExp(r'\d').hasMatch(value) && normalized.length >= 4;
  }

  bool _allowsSingleCandidateDetailsFallback(String value) {
    if (RegExp(
      r'\b(?:web[- ]?dl|webrip|bluray|remux|hdtv|kktv|aac\d*|ddp\d*|hevc|avc|x26[45]|h[ .]?26[45]|2160p|1080p|720p)\b',
      caseSensitive: false,
    ).hasMatch(value)) {
      return false;
    }
    final normalized = _normalizeMediaTitle(value);
    final withoutDigits = normalized.replaceAll(RegExp(r'\d'), '');
    if (RegExp(r'[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]').hasMatch(value)) {
      return withoutDigits.length >= 2;
    }
    return withoutDigits.length >= 4;
  }

  bool _allowsSpecificRelatedResultFallback(String value) {
    if (_allowsUniqueQueryFallback(value)) return true;
    final normalized = _normalizeMediaTitle(value);
    if (normalized.length < 4) return false;
    return RegExp(r'[\u4e00-\u9fff]').hasMatch(value) &&
        RegExp(r'\d').hasMatch(value);
  }

  /// Resolves [fallback] to a TMDB/Douban work.
  ///
  /// When [deferDetails] is true the method returns as soon as a candidate is
  /// picked, *without* fetching the TMDB detail document. The row is then
  /// considered "matched" (production done) and the detail hydration is left to
  /// the enrichment consumer, which batches those requests separately. This
  /// keeps the matching stage from blocking on a second round-trip per file.
  Future<MediaLibraryItem> _recognizeMediaItem(
    MediaLibraryItem fallback,
    String apiKey, {
    required String proxyHost,
    required String proxyPort,
    bool deferDetails = false,
    bool localOnly = false,
  }) async {
    if (_api == null) return fallback;
    try {
      final hasTMDBKey = apiKey.trim().isNotEmpty;
      final doubanAutoRecognition = _doubanAutoRecognitionEnabled;
      final parsed = ParsedMediaName.parse(
        fallback.file.name,
        directoryName: _parentDirectoryName(fallback.file.cloudPath),
        directoryPath: fallback.file.cloudPath,
      );
      final requestedKind = _requestedTMDBMediaKind(fallback, parsed);
      final searchTitle = parsed.title.trim().isEmpty
          ? fallback.title
          : parsed.title;
      final titleVariants = _recognitionTitleVariants(
        fallback,
        primaryTitle: searchTitle,
      );
      if (titleVariants.isEmpty) {
        _appendScanLog('[同步识别][调试] 跳过：无法从文件名解析有效标题，文件=${fallback.file.name}');
        return fallback;
      }

      // ── Layer 0: 路径中的 TMDB ID 标记（如 {tmdb-984951}、[tmdb 123]）
      //    是最可靠的识别信号，命中直接返回，不再走标题搜索。
      if (hasTMDBKey && !localOnly) {
        final tagged = await _tmdbCandidateFromPathTag(
          fallback,
          apiKey,
          proxyHost: proxyHost,
          proxyPort: proxyPort,
        );
        if (tagged != null) {
          _appendScanLog(
            '[同步识别][调试] TMDB 路径标记命中：'
            'id=${tagged['id']}，类型=${tagged['media_type']}',
          );
          final item = _itemFromTMDBCandidate(fallback, tagged);
          return _itemFromTMDBDetails(item, tagged);
        }
      }

      _TMDBRecognitionSearchResult searchResult =
          const _TMDBRecognitionSearchResult(candidates: [], attempts: []);

      // ── Layer 1: local works pre-match. The tmdb_works / douban_works tables
      // accumulate every title ever matched, so over time this short-circuits
      // more and more files with zero network cost.
      if (parsed.title.trim().isNotEmpty) {
        final localTMDB = await _store.searchTMDBWorksByTitle(
          parsed.title,
          year: parsed.year,
          mediaKind: requestedKind == 'auto' ? null : requestedKind,
          limit: 5,
        );
        if (localTMDB.isNotEmpty) {
          // Convert the local work record into the candidate shape the rest of
          // the pipeline expects.
          final candidates = [
            for (final work in localTMDB)
              <String, dynamic>{
                'id': work.tmdbID,
                'title': work.title,
                'original_title': work.originalTitle,
                'media_type': work.mediaKind.name == 'tv' ? 'tv' : 'movie',
                'release_date': work.releaseDate,
                'poster_path': work.posterPath,
                'backdrop_path': work.backdropPath,
                'vote_average': work.rating,
                'overview': work.overview,
                '_recognitionResolvedByLocal': true,
              },
          ];
          searchResult = _TMDBRecognitionSearchResult(
            candidates: candidates,
            attempts: ['本地 works 表命中：${parsed.title}'],
          );
          AppLogger.info('Media', '本地预匹配命中：${parsed.title} → ${localTMDB.first.title}');
        }

        if (searchResult.candidates.isEmpty && doubanAutoRecognition) {
          final localDouban = await _store.searchDoubanWorksByTitle(
            parsed.title,
            year: parsed.year,
            mediaKind: requestedKind == 'auto' ? null : requestedKind,
            limit: 5,
          );
          if (localDouban.isNotEmpty) {
            // Build a synthetic candidate set so the downstream cross-reference
            // logic can still fuse TMDB + Douban signals if both exist.
            final candidates = [
              for (final work in localDouban)
                <String, dynamic>{
                  'id': work.doubanID,
                  'title': work.title,
                  'original_title': work.originalTitle,
                  'media_type': work.mediaKind.name == 'tv' ? 'tv' : 'movie',
                  'release_date': work.releaseDate,
                  'poster_path': work.posterPath,
                  'vote_average': work.rating,
                  'overview': work.overview,
                  '_recognitionResolvedByLocal': true,
                  '_source': 'douban',
                },
            ];
            // Store as a pseudo-TMDB result so the rest of the convergence
            // logic treats it uniformly.
            searchResult = _TMDBRecognitionSearchResult(
              candidates: candidates,
              attempts: ['本地豆瓣 works 表命中：${parsed.title}'],
            );
          }
        }
      }

      // localOnly 模式（本地预筛阶段）：本地 works 表未命中则直接返回，
      // 由调用方将该条目放入远程识别队列，避免在预筛阶段触发网络请求。
      if (localOnly && searchResult.candidates.isEmpty) {
        return fallback;
      }

      // ── Title-level search cache: many files share the same parsed title
      // (e.g. 24 episodes of a season, or multiple releases of the same movie).
      // Caching the raw search results avoids redundant network round-trips.
      final cacheKey = _searchCacheKey(
        titleVariants,
        requestedKind,
        parsed.year,
        apiKey,
        doubanAutoRecognition,
      );
      final cachedSearch = _recognitionSearchCache[cacheKey];

      Future<List<Map<String, dynamic>>>? doubanFuture;
      if (cachedSearch != null) {
        // Reuse the in-flight or completed search from a previous file.
        final resolved = await cachedSearch;
        searchResult = resolved.tmdb;
        doubanFuture = Future.value(resolved.douban);
      } else if (searchResult.candidates.isNotEmpty) {
        // Layer 1 local match already resolved; skip network search.
        doubanFuture = Future.value(const <Map<String, dynamic>>[]);
      } else {
        // Douban search is independent of the TMDB search, so kick it off in
        // parallel and await it only once both are needed.
        if (doubanAutoRecognition) {
          doubanFuture = _searchDoubanCandidates(
            titleVariants,
            requestedKind,
            parsed.year,
          );
        }
        // Create a shared Future so concurrent workers on the same title
        // merge into one request.
        final request = () async {
          late final _TMDBRecognitionSearchResult tmdbResult;
          late final List<Map<String, dynamic>> doubanResult;
          late final List<String> attemptLog;
          if (hasTMDBKey) {
            tmdbResult = await _tmdbSearchForRecognition(
              titleVariants,
              mediaKind: requestedKind,
              apiKey: apiKey,
              proxyHost: proxyHost,
              proxyPort: proxyPort,
              year: parsed.year,
              country: parsed.country,
            );
            attemptLog = tmdbResult.attempts;
          } else {
            tmdbResult = const _TMDBRecognitionSearchResult(
              candidates: [],
              attempts: [],
            );
            attemptLog = [];
          }
          doubanResult = doubanFuture == null
              ? const <Map<String, dynamic>>[]
              : await doubanFuture;
          return (tmdb: tmdbResult, douban: doubanResult, attempts: attemptLog);
        }();
        _recognitionSearchCache[cacheKey] = request;
        final resolved = await request;
        searchResult = resolved.tmdb;
        doubanFuture = Future.value(resolved.douban);
      }
      final values = searchResult.candidates;
      final List<Map<String, dynamic>> doubanItems;
      if (doubanFuture == null) {
        doubanItems = const [];
      } else {
        doubanItems = await doubanFuture;
      }
      if (values.isEmpty && doubanItems.isEmpty) {
        final missMessage = hasTMDBKey
            ? doubanAutoRecognition
                  ? '[同步识别][调试] TMDB + 豆瓣均未命中：${fallback.file.name}；'
                        '${_describeTMDBRecognitionAttempts(searchResult.attempts)}'
                  : '[同步识别][调试] TMDB 未命中，豆瓣自动识别已关闭：${fallback.file.name}；'
                        '${_describeTMDBRecognitionAttempts(searchResult.attempts)}'
            : doubanAutoRecognition
            ? '[同步识别][调试] 豆瓣未命中：${fallback.file.name}'
            : '[同步识别][调试] 无可用自动识别源：${fallback.file.name}';
        _appendScanLog(missMessage);
        return fallback;
      }
      if (values.isEmpty && doubanItems.isNotEmpty) {
        _appendScanLog(
          hasTMDBKey
              ? '[同步识别][调试] TMDB 未命中，豆瓣返回 ${doubanItems.length} 条：${fallback.file.name}'
              : '[同步识别][调试] 豆瓣返回 ${doubanItems.length} 条：${fallback.file.name}',
        );
        final doubanResult = _pickBestDoubanCandidate(
          fallback,
          parsed,
          titleVariants,
          requestedKind,
          doubanItems,
        );
        if (doubanResult != null) return doubanResult;
        return fallback;
      }
      var refinedValues = _refineTMDBCandidates(fallback, parsed, values);
      if (doubanItems.isNotEmpty) {
        refinedValues = _crossReferenceWithDouban(
          refinedValues,
          doubanItems,
          parsed,
        );
      }
      if (refinedValues.length > 1 ||
          _tmdbCandidatesNeedDetails(refinedValues)) {
        final resolution = await _resolveAmbiguousTMDBCandidates(
          refinedValues,
          parsed,
          titleVariants,
          apiKey: apiKey,
          proxyHost: proxyHost,
          proxyPort: proxyPort,
        );
        refinedValues = resolution.candidates;
        if (resolution.diagnostics.isNotEmpty) {
          _appendScanLog(
            '[同步识别][调试] 多候选详情评估：'
            '${resolution.diagnostics.join('；')}',
          );
        }
      }
      if (refinedValues.length != 1) {
        _appendScanLog(
          '[同步识别][调试] 自动识别未完成：候选收敛后仍有 '
          '${refinedValues.length} 条，保留为未识别以避免误匹配。'
          '文件=${fallback.file.name}；'
          '${_describeTMDBRecognitionAttempts(searchResult.attempts)}',
        );
        return fallback;
      }
      Map<String, dynamic>? candidate;
      var bestScore = -1;
      // 唯一候选 + 搜索阶段已确认命中（_recognitionTitleScore > 0）时，
      // 年份差异不再一票否决——年份常来自文件/目录标注，可能与 TMDB 首播
      // 年份差 1-2 年但标题完全正确。
      final singleSearchHit =
          refinedValues.length == 1 &&
          (_toInt(refinedValues.first['_recognitionTitleScore']) ?? 0) > 0;
      for (final value in refinedValues) {
        final map = Map<String, dynamic>.from(value);
        final type = map['media_type']?.toString();
        if (type != 'movie' && type != 'tv') continue;
        final releaseDate =
            (map['release_date'] ?? map['first_air_date'])?.toString() ?? '';
        final recognitionYear = _toInt(map['_recognitionYear']);
        final resolvedByDetails = map['_recognitionResolvedByDetails'] == true;
        final candidateYear = _releaseYearFromDate(releaseDate);
        if (!resolvedByDetails &&
            !singleSearchHit &&
            recognitionYear != null &&
            candidateYear != null &&
            _tmdbYearDelta(candidateYear, recognitionYear) > 1) {
          continue;
        }
        final recognitionTitle = map['_recognitionTitle']?.toString();
        final expectedTitle = recognitionTitle?.trim().isNotEmpty == true
            ? recognitionTitle!
            : searchTitle;
        final titleMatch = _bestMediaTitleMatch(
          expectedTitle,
          title: (map['title'] ?? map['name'] ?? '').toString(),
          originalTitle: (map['original_title'] ?? map['original_name'] ?? '')
              .toString(),
        );
        var score = titleMatch.score;
        // 搜索阶段已用父目录/别名标题命中该候选时，其评分被记录在
        // _recognitionTitleScore 中。最终评分重新用 _bestMediaTitleMatch
        // 对比候选的英文 title/originalTitle，中文标题可能得 0 分而被误杀，
        // 因此优先沿用搜索阶段已确认的命中评分。
        final storedScore = _toInt(map['_recognitionTitleScore']) ?? 0;
        if (storedScore > score) score = storedScore;
        final detailTitleScore = MediaTitleMatcher.bestCandidateScore([
          expectedTitle,
        ], map);
        if (detailTitleScore > score) score = detailTitleScore;
        final uniqueExactYearFallback =
            map['_recognitionUniqueExactYear'] == true;
        final uniqueSpecificQueryFallback =
            map['_recognitionUniqueSpecificQuery'] == true;
        if (score == 0 &&
            !uniqueExactYearFallback &&
            !uniqueSpecificQueryFallback &&
            !resolvedByDetails) {
          continue;
        }
        if (resolvedByDetails) {
          score = score < 95 ? 95 : score;
        } else if (uniqueExactYearFallback || uniqueSpecificQueryFallback) {
          score = 1;
        }
        if (parsed.year != null && candidateYear != null) {
          final delta = _tmdbYearDelta(candidateYear, parsed.year!);
          if (delta == 0) {
            score += 30;
          } else if (delta == 1) {
            score += 20;
          } else {
            score -= 40;
          }
        } else if (parsed.year != null &&
            recognitionYear == null &&
            !resolvedByDetails) {
          // A no-year fallback is deliberately less trusted, but an exact
          // title can still recover metadata whose release year is absent or
          // differs from a release/package year embedded in the file name.
          score -= 15;
        }
        if (map['_douban_boost'] == true) {
          score += 20;
        }
        if (score > bestScore) {
          bestScore = score;
          map['media_type'] = type;
          candidate = map;
        }
      }
      if (candidate == null) {
        _appendScanLog(
          '[同步识别][调试] TMDB 候选被过滤：${fallback.file.name}；'
          '${_describeTMDBRecognitionAttempts(searchResult.attempts)}',
        );
        return fallback;
      }
      var item = _itemFromTMDBCandidate(fallback, candidate);
      if (item.tmdbID == null) return item;
      // Matching is done here. With deferred details the row is handed to the
      // enrichment consumer instead of paying for a detail round-trip inline;
      // `needsDetailHydration` is what puts it on that queue.
      if (deferDetails) return item;
      try {
        final details = await _tmdbDetails(
          item.tmdbID!,
          item.mediaKind,
          apiKey: apiKey,
          proxyHost: proxyHost,
          proxyPort: proxyPort,
        );
        item = _itemFromTMDBDetails(item, details);
      } catch (error) {
        // The search result already has enough information for an initial row.
        AppLogger.warning(
          'Media',
          'TMDB 候选已命中，但详情补全失败：id=${item.tmdbID}，$error',
        );
      }
      return item;
    } catch (error, stackTrace) {
      _appendScanLog(
        '[同步识别][调试] 自动识别异常：${fallback.file.name}，$error',
        isError: true,
      );
      AppLogger.error(
        'Media',
        '自动识别流程异常：${fallback.file.name}',
        error: error,
        stackTrace: stackTrace,
      );
      return fallback;
    }
  }

  String _describeTMDBRecognitionAttempts(List<String> attempts) {
    if (attempts.isEmpty) return '没有可用的 TMDB 查询尝试';
    final visible = attempts.take(4).join('；');
    final remaining = attempts.length - 4;
    return remaining <= 0 ? '查询尝试：$visible' : '查询尝试：$visible；另有 $remaining 次';
  }

  Future<List<Map<String, dynamic>>> _searchDoubanCandidates(
    List<_MediaTitleVariant> titleVariants,
    String requestedKind,
    int? year,
  ) async {
    if (!_doubanAutoRecognitionEnabled) return const [];
    if (_api == null || titleVariants.isEmpty) return const [];
    for (final variant in titleVariants) {
      final q = variant.value.trim();
      if (RegExp(r'合集|出品|系列|合辑|收藏|精选|套装|全集|典藏').hasMatch(q)) {
        _appendScanLog('[豆瓣][跳过] 疑似合集/合辑名，不搜索："$q"');
        continue;
      }
      Map<String, dynamic> result;
      try {
        result = await _api!.doubanSearch(variant.value);
      } catch (error) {
        _appendScanLog('[豆瓣][搜索] 请求失败：query="${variant.value}"，错误=$error');
        continue;
      }
      final items = result['items'];
      if (items is! List || items.isEmpty) {
        _appendScanLog('[豆瓣][搜索] 无结果：query="${variant.value}"');
        continue;
      }
      _appendScanLog('[豆瓣][搜索] 返回 ${items.length} 条：query="${variant.value}"');
      final candidates = <Map<String, dynamic>>[];
      for (final raw in items) {
        if (raw is! Map) continue;
        final target = raw['target'];
        if (target is! Map) continue;
        final candidate = Map<String, dynamic>.from(target);
        final id = candidate['id']?.toString();
        if (id == null || id.isEmpty) continue;
        final cardSubtitle = (candidate['card_subtitle'] ?? '').toString();
        final type = cardSubtitle.contains('集') ? 'tv' : 'movie';
        if (requestedKind != 'auto' && type != requestedKind) continue;
        candidate['media_type'] = type;
        candidate['douban_id'] = id;
        final yearStr = candidate['year']?.toString() ?? '';
        if (yearStr.length >= 4) {
          candidate['release_date'] = '$yearStr-01-01';
        }
        candidate['poster_path'] = doubanPosterPath(candidate);
        candidate['overview'] = cardSubtitle;
        final rating = candidate['rating'];
        if (rating is Map) {
          candidate['vote_average'] = rating['value'];
          candidate['vote_count'] = rating['count'];
        }
        candidates.add(candidate);
      }
      if (candidates.isEmpty) continue;
      _appendScanLog('[豆瓣][筛选] ${candidates.length} 条候选通过类型筛选');
      return candidates;
    }
    return const [];
  }

  List<Map<String, dynamic>> _crossReferenceWithDouban(
    List<Map<String, dynamic>> tmdbCandidates,
    List<Map<String, dynamic>> doubanItems,
    ParsedMediaName parsed,
  ) {
    if (doubanItems.isEmpty || tmdbCandidates.isEmpty) return tmdbCandidates;
    final doubanYears = <int>{};
    final doubanTypes = <String>{};
    for (final item in doubanItems) {
      final date = item['release_date']?.toString() ?? '';
      final y = date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null;
      if (y != null) doubanYears.add(y);
      final t = item['media_type']?.toString();
      if (t != null) doubanTypes.add(t);
    }
    final boosted = <Map<String, dynamic>>[];
    for (final candidate in tmdbCandidates) {
      var map = Map<String, dynamic>.from(candidate);
      final date =
          (map['release_date'] ?? map['first_air_date'])?.toString() ?? '';
      final candidateYear = date.length >= 4
          ? int.tryParse(date.substring(0, 4))
          : null;
      final type = map['media_type']?.toString();
      final yearMatch =
          candidateYear != null && doubanYears.contains(candidateYear);
      final typeMatch = type != null && doubanTypes.contains(type);
      if (yearMatch && typeMatch) {
        final doubanMatch = doubanItems.firstWhere((d) {
          final dDate = d['release_date']?.toString() ?? '';
          final dYear = dDate.length >= 4
              ? int.tryParse(dDate.substring(0, 4))
              : null;
          return dYear == candidateYear && d['media_type'] == type;
        }, orElse: () => {});
        if (doubanMatch.isNotEmpty) {
          map['_douban_boost'] = true;
          map['douban_id'] = doubanMatch['douban_id'];
          _appendScanLog(
            '[豆瓣][比对] TMDB "${map['title'] ?? map['name']}" '
            '与豆瓣 "${doubanMatch['title']}" 年份=$candidateYear 类型=$type 匹配，加分 +20',
          );
        }
      }
      boosted.add(map);
    }
    return boosted;
  }

  MediaLibraryItem? _pickBestDoubanCandidate(
    MediaLibraryItem fallback,
    ParsedMediaName parsed,
    List<_MediaTitleVariant> titleVariants,
    String requestedKind,
    List<Map<String, dynamic>> candidates,
  ) {
    var refined = candidates;
    if (parsed.year != null) {
      final sameYear = refined.where((c) {
        final date = c['release_date']?.toString() ?? '';
        return date.startsWith('${parsed.year}');
      }).toList();
      if (sameYear.isNotEmpty) refined = sameYear;
    }
    final ranked = <({int score, Map<String, dynamic> value})>[];
    for (final candidate in refined.take(5)) {
      final title = (candidate['title'] ?? candidate['name'])?.toString() ?? '';
      final titleScore = _bestMediaTitleMatch(
        titleVariants.first.value,
        title: title,
        originalTitle: title,
      ).score;
      var score = titleScore;
      if (score == 0) {
        score = _fuzzyTitleScore(titleVariants.first.value, title);
      }
      final date = candidate['release_date']?.toString() ?? '';
      final candidateYear = date.length >= 4
          ? int.tryParse(date.substring(0, 4))
          : null;
      if (parsed.year != null && candidateYear != null) {
        final delta = (candidateYear - parsed.year!).abs();
        if (delta == 0) {
          score += 30;
        } else if (delta == 1) {
          score += 20;
        } else {
          score -= 40;
        }
      }
      ranked.add((score: score, value: candidate));
      _appendScanLog(
        '[豆瓣][评分] "${candidate['title']}" 标题分=$titleScore，'
        '模糊分=${_fuzzyTitleScore(titleVariants.first.value, title)}，'
        '年份=${date.isEmpty ? '-' : date}，总分=$score',
      );
    }
    ranked.sort((a, b) => b.score.compareTo(a.score));
    final yearMatched =
        parsed.year != null &&
        refined.every((c) {
          final date = c['release_date']?.toString() ?? '';
          return date.startsWith('${parsed.year}');
        });
    final uniqueByYear = yearMatched && refined.length == 1;
    final uniqueAltogether = refined.length == 1;
    if (ranked.isEmpty ||
        (ranked.first.score < 30 && !uniqueByYear && !uniqueAltogether)) {
      _appendScanLog(
        '[豆瓣][结果] 最高分 ${ranked.isEmpty ? 0 : ranked.first.score} < 30'
        '${uniqueByYear ? '，年份唯一匹配，采纳' : ''}'
        '${uniqueAltogether && !uniqueByYear ? '，唯一候选，采纳' : ''}'
        '${!uniqueByYear && !uniqueAltogether ? '，放弃' : ''}',
      );
      if (!uniqueByYear && !uniqueAltogether) return null;
    }
    final best = ranked.first.value;
    final title = (best['title'] ?? best['name'])?.toString().trim() ?? '';
    final date = best['release_date']?.toString() ?? '';
    final type = best['media_type']?.toString() ?? 'movie';
    final doubanId = best['douban_id']?.toString();
    _appendScanLog(
      '[豆瓣][命中] ${fallback.file.name} -> '
      '"$title" ($date)，豆瓣ID=$doubanId',
    );
    return fallback.copyWith(
      title: title.isEmpty ? fallback.title : title,
      originalTitle: title.isEmpty ? fallback.originalTitle : title,
      doubanID: doubanId,
      mediaKind: type == 'tv' ? TMDBMediaKind.tv : TMDBMediaKind.movie,
      releaseDate: date,
      overview: best['overview']?.toString() ?? '',
      posterPath: best['poster_path']?.toString() ?? doubanPosterPath(best),
      doubanRating: _ratingValue(best['vote_average']),
      updatedAt: DateTime.now(),
    );
  }

  /// fs_detail/search responses sometimes return only a bare filename. Keep
  /// the persisted parent path in that case so parser rules based on folder
  /// names (for example `2008见龙卸甲/2008.mkv`) still participate in TMDB
  /// recognition.
  CloudFile _withRecognitionPath(CloudFile latest, CloudFile known) {
    final path = recoverCloudFilePath(
      fileName: latest.name,
      candidatePath: latest.cloudPath,
      knownPath: known.cloudPath,
    );
    return latest.copyWith(cloudPath: path);
  }

  Future<Map<String, CloudFile>> _cachedCloudEntryMap() {
    return _cachedCloudEntries ??= () async {
      final entries = await FileMetadataCache.allCachedFolderChildren();
      return {for (final entry in entries) entry.id: entry};
    }();
  }

  Future<CloudFile?> _cloudFolderDetail(String id) {
    return _cloudFolderDetails.putIfAbsent(id, () async {
      if (_api == null) return null;
      try {
        final detail = await _api!.fsDetail(id);
        final value = _extractFiles(
          detail,
        ).where((entry) => entry.id == id).firstOrNull;
        if (value != null) return value;
        return CloudFile.fromJson({
          'id': id,
          'name': JsonDeep.findString(detail, const ['name', 'fileName']) ?? '',
          'isDir': true,
          'parentId': JsonDeep.findString(detail, const [
            'parentId',
            'parent_id',
            'parentID',
          ]),
        });
      } catch (_) {
        return null;
      }
    });
  }

  Future<CloudFile> _restoreCloudFilePath(
    CloudFile file,
    CloudFile known, {
    String? libraryID,
  }) async {
    var restored = _withRecognitionPath(file, known);
    if (_parentPath(restored.cloudPath).isNotEmpty || _api == null) {
      return restored;
    }

    final sources = state.libraries
        .where((library) => libraryID == null || library.id == libraryID)
        .expand((library) => library.sources)
        .toList(growable: false);
    var parentID = restored.parentID?.trim();
    if (parentID == null || parentID.isEmpty) {
      parentID = known.parentID?.trim();
    }
    parentID ??= mediaParentIDFromMetadata(restored, cachedFile: known);
    if (parentID == null) {
      final rootSource = sources
          .where((value) => value.rootID?.trim().isNotEmpty != true)
          .firstOrNull;
      if (rootSource == null || rootSource.path.trim().isEmpty) return restored;
      final sourceParts = rootSource.path
          .replaceAll(' / ', '/')
          .split(RegExp(r'[\\/]'))
          .where((part) => part.trim().isNotEmpty)
          .toList();
      return restored.copyWith(
        cloudPath: '/${[...sourceParts, restored.name].join('/')}',
      );
    }
    final names = <String>[restored.name];
    final visited = <String>{restored.id};
    final cachedEntries = await _cachedCloudEntryMap();

    final rootSource = sources
        .where((value) => (value.rootID?.trim() ?? '') == parentID)
        .firstOrNull;
    if (parentID.isEmpty &&
        rootSource != null &&
        rootSource.path.trim().isNotEmpty) {
      final sourceParts = rootSource.path
          .replaceAll(' / ', '/')
          .split(RegExp(r'[\\/]'))
          .where((part) => part.trim().isNotEmpty)
          .toList();
      return restored.copyWith(
        cloudPath: '/${[...sourceParts, restored.name].join('/')}',
      );
    }

    while (parentID != null && parentID.isNotEmpty) {
      final currentParentID = parentID;
      if (!visited.add(currentParentID)) break;
      final source = sources
          .where((value) => value.rootID?.trim() == currentParentID)
          .firstOrNull;
      if (source != null && source.path.trim().isNotEmpty) {
        final sourceParts = source.path
            .replaceAll(' / ', '/')
            .split(RegExp(r'[\\/]'))
            .where((part) => part.trim().isNotEmpty)
            .toList();
        names.insertAll(0, sourceParts);
        break;
      }

      final folder =
          cachedEntries[currentParentID] ??
          await _cloudFolderDetail(currentParentID);
      if (folder == null || folder.name.trim().isEmpty) break;
      names.insert(0, folder.name.trim());
      parentID = mediaParentIDFromMetadata(folder);
    }
    if (names.length <= 1) return restored;
    restored = restored.copyWith(cloudPath: '/${names.join('/')}');
    return restored;
  }

  String? _seriesRecognitionKey(MediaLibraryItem item) {
    final parsed = ParsedMediaName.parse(
      item.file.name,
      directoryName: _parentDirectoryName(item.file.cloudPath),
      directoryPath: item.file.cloudPath,
    );
    if ((!parsed.isEpisode && parsed.season == null) ||
        parsed.title.trim().isEmpty) {
      return null;
    }
    final parentPath = _normalizedParentCloudPath(item.file.cloudPath);
    if (parentPath == null) return null;
    final titlePattern = _normalizeMediaTitle(parsed.title);
    if (titlePattern.isEmpty) return null;
    final yearPattern = parsed.year?.toString() ?? '-';
    return '${item.libraryID}:$parentPath:$titlePattern:$yearPattern';
  }

  /// A TV match describes the show, not merely the selected episode. Mark
  /// every already-indexed sibling in the same directory as identified as
  /// soon as one episode has been matched manually.
  Future<void> _aggregateStoredSeriesRecognition(
    String seriesKey,
    MediaLibraryItem matched,
  ) async {
    final siblings = (await _loadItems(
      matched.libraryID,
    )).where((item) => _seriesRecognitionKey(item) == seriesKey).toList();
    if (siblings.isEmpty) return;

    final now = DateTime.now();
    final replacements = <String, MediaLibraryItem>{};
    for (final sibling in siblings) {
      var updated = sibling.id == matched.id
          ? matched
          : matched.copyWith(
              file: sibling.file,
              // These flags belong to the individual file rather than the
              // show, so retain the sibling's values.
              hasChineseAudio: sibling.hasChineseAudio,
              hasChineseSubtitle: sibling.hasChineseSubtitle,
              updatedAt: now,
            );
      try {
        updated = await _renameMatchedMediaFile(updated);
      } catch (error) {
        _appendScanLog(
          '剧集聚合后规范命名失败，已保留识别结果：'
          '${sibling.file.name}，$error',
          isError: true,
        );
      }
      replacements['${sibling.libraryID}:${sibling.id}'] = updated;
    }
    await _replaceItemsByPreviousIDs(replacements);
    _searchResultsCache.clear();
    state = state.copyWith(
      items: state.selectedLibraryID == matched.libraryID
          ? state.items
                .map(
                  (item) =>
                      replacements['${item.libraryID}:${item.id}'] ?? item,
                )
                .toList()
          : state.items,
      allItems: await _loadAllItems(),
    );
    _appendScanLog('剧集已聚合：${matched.title}，同目录 ${siblings.length} 集已标记为已识别');
  }

  Future<List<Map<String, dynamic>>> _tmdbCandidatesForItem(
    MediaLibraryItem fallback,
    String apiKey, {
    required String proxyHost,
    required String proxyPort,
  }) async {
    if (_api == null || apiKey.trim().isEmpty) return const [];
    final parsed = ParsedMediaName.parse(
      fallback.file.name,
      directoryName: _parentDirectoryName(fallback.file.cloudPath),
      directoryPath: fallback.file.cloudPath,
    );
    final requestedKind = _requestedTMDBMediaKind(fallback, parsed);
    final searchTitle = parsed.title.trim().isEmpty
        ? fallback.title
        : parsed.title;
    final titleVariants = _recognitionTitleVariants(
      fallback,
      primaryTitle: searchTitle,
    );
    final taggedCandidate = await _tmdbCandidateFromPathTag(
      fallback,
      apiKey,
      proxyHost: proxyHost,
      proxyPort: proxyPort,
    );
    if (taggedCandidate != null) {
      _appendScanLog(
        '[同步识别][调试] TMDB 路径标记命中：'
        'id=${taggedCandidate['id']}，类型=${taggedCandidate['media_type']}',
      );
      return [taggedCandidate];
    }
    final searchResult = await _tmdbSearchForRecognition(
      titleVariants,
      mediaKind: requestedKind,
      apiKey: apiKey,
      proxyHost: proxyHost,
      proxyPort: proxyPort,
      year: parsed.year,
      country: parsed.country,
    );
    final values = searchResult.candidates;
    if (values.isEmpty) {
      _appendScanLog(
        '[同步识别][调试] TMDB 未返回可解析候选：查询="$searchTitle"，'
        '类型=$requestedKind，年份参数=${parsed.year?.toString() ?? '未提供'}，'
        '已执行 ${searchResult.attempts.length} 种策略。'
        '${searchResult.attempts.join('；')}',
      );
      return const [];
    }
    final expectedType = requestedKind == 'auto' ? null : requestedKind;
    if (titleVariants.isEmpty) return const [];
    final scored = <({int score, Map<String, dynamic> candidate})>[];
    final diagnostics = <String>[];
    String describe(Map<String, dynamic> candidate, String? type) {
      final title = (candidate['title'] ?? candidate['name'] ?? '-').toString();
      final original =
          (candidate['original_title'] ?? candidate['original_name'] ?? '-')
              .toString();
      final date =
          (candidate['release_date'] ?? candidate['first_air_date'] ?? '-')
              .toString();
      return 'id=${candidate['id'] ?? '-'} type=${type ?? '-'} '
          '标题="$title" 原名="$original" 日期=$date';
    }

    for (final candidate in values.take(20)) {
      final type = candidate['media_type']?.toString() ?? expectedType;
      if (type != 'movie' && type != 'tv') {
        diagnostics.add('${describe(candidate, type)} -> 跳过：类型无效');
        continue;
      }
      final releaseDate =
          (candidate['release_date'] ?? candidate['first_air_date'])
              ?.toString() ??
          '';
      final recognitionYear = _toInt(candidate['_recognitionYear']);
      final yearMismatch = recognitionYear != null &&
          releaseDate.isNotEmpty &&
          !releaseDate.startsWith('$recognitionYear');
      if (yearMismatch &&
          values.length > 1) {
        diagnostics.add('${describe(candidate, type)} -> 跳过：年份不匹配');
        continue;
      }
      final recognitionTitle = candidate['_recognitionTitle']?.toString();
      final titleMatch = _bestMediaTitleMatch(
        recognitionTitle?.trim().isNotEmpty == true
            ? recognitionTitle!
            : searchTitle,
        title: (candidate['title'] ?? candidate['name'] ?? '').toString(),
        originalTitle:
            (candidate['original_title'] ?? candidate['original_name'] ?? '')
                .toString(),
      );
      var score = titleMatch.score;
      final uniqueExactYearFallback =
          candidate['_recognitionUniqueExactYear'] == true;
      final uniqueSpecificQueryFallback =
          candidate['_recognitionUniqueSpecificQuery'] == true;
      final needsDetails = candidate['_recognitionNeedsDetails'] == true;
      if (score == 0 &&
          !uniqueExactYearFallback &&
          !uniqueSpecificQueryFallback &&
          !needsDetails) {
        diagnostics.add('${describe(candidate, type)} -> 跳过：标题不相关');
        continue;
      }
      if (uniqueExactYearFallback ||
          uniqueSpecificQueryFallback ||
          needsDetails) {
        score = 1;
      }
      if (parsed.year != null && releaseDate.startsWith('${parsed.year}')) {
        score += 30;
      } else if (parsed.year != null && recognitionYear == null) {
        score -= 15;
      }
      candidate['media_type'] = type;
      scored.add((score: score, candidate: candidate));
      diagnostics.add(
        '${describe(candidate, type)} -> 命中：'
        '${uniqueExactYearFallback
            ? '精确查询+年份唯一候选兜底'
            : uniqueSpecificQueryFallback
            ? '无年份具体查询唯一候选兜底'
            : titleMatch.basis}，'
        '评分=$score',
      );
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    var refined = _refineTMDBCandidates(
      fallback,
      parsed,
      scored.map((entry) => entry.candidate),
    );
    if (refined.length > 1 || _tmdbCandidatesNeedDetails(refined)) {
      final resolution = await _resolveAmbiguousTMDBCandidates(
        refined,
        parsed,
        titleVariants,
        apiKey: apiKey,
        proxyHost: proxyHost,
        proxyPort: proxyPort,
      );
      refined = resolution.candidates;
      diagnostics.addAll(resolution.diagnostics);
    }
    _appendScanLog(
      '[同步识别][调试] TMDB 候选评估：查询="$searchTitle"，'
      '类型=$requestedKind，年份参数=${parsed.year?.toString() ?? '未提供'}，原始 ${values.length} 条，'
      '有效 ${scored.length} 条。策略：${searchResult.attempts.join('；')}。'
      '${diagnostics.isEmpty ? '无可解析候选' : diagnostics.join('；')}',
    );
    return refined;
  }

  bool _tmdbCandidatesNeedDetails(Iterable<Map<String, dynamic>> candidates) {
    return candidates.any(
      (candidate) => candidate['_recognitionNeedsDetails'] == true,
    );
  }

  int? _tmdbCandidateYear(Map<String, dynamic> candidate) {
    final releaseDate =
        (candidate['release_date'] ?? candidate['first_air_date'])
            ?.toString() ??
        '';
    return _releaseYearFromDate(releaseDate);
  }

  int? _releaseYearFromDate(String value) {
    if (value.length < 4) return null;
    return int.tryParse(value.substring(0, 4));
  }

  int _tmdbYearDelta(int first, int second) => (first - second).abs();

  String _requestedTMDBMediaKind(
    MediaLibraryItem fallback,
    ParsedMediaName parsed,
  ) {
    final isExplicitMovie = fallback.mediaKind == TMDBMediaKind.movie;
    final hasEpisodeMarker = _hasExplicitEpisodeMarker(fallback.file.name);
    if ((parsed.isEpisode && (!isExplicitMovie || hasEpisodeMarker)) ||
        (parsed.season != null && !isExplicitMovie)) {
      return 'tv';
    }
    return switch (fallback.mediaKind) {
      TMDBMediaKind.movie => 'movie',
      TMDBMediaKind.tv => 'tv',
      TMDBMediaKind.automatic => 'auto',
      null => 'auto',
    };
  }

  bool _hasExplicitEpisodeMarker(String value) {
    return RegExp(
          r'\bS\s*0?\d{1,2}[ ._-]*E\s*0?\d{1,4}\b',
          caseSensitive: false,
        ).hasMatch(value) ||
        RegExp(
          r'\b(?:E|EP|Episode|SP|Special)\s*0?\d{1,4}\b',
          caseSensitive: false,
        ).hasMatch(value) ||
        RegExp(r'第\s*\d{1,4}\s*[集话話]').hasMatch(value);
  }

  List<Map<String, dynamic>> _refineTMDBCandidates(
    MediaLibraryItem fallback,
    ParsedMediaName parsed,
    Iterable<Map<String, dynamic>> candidates,
  ) {
    final expectedType = _requestedTMDBMediaKind(fallback, parsed);
    final variants = _recognitionTitleVariants(
      fallback,
      primaryTitle: parsed.title,
    );
    // 分离 auto 重试候选，避免被类型过滤
    final autoRetry = <Map<String, dynamic>>[];
    final regular = <Map<String, dynamic>>[];
    for (final c in candidates) {
      if (c['_recognitionFromAutoRetry'] == true) {
        autoRetry.add(c);
      } else {
        regular.add(c);
      }
    }
    final refined = MediaTMDBCandidateResolver.refine(
      candidates: regular,
      expectedType: expectedType,
      year: parsed.year,
      titleEvidence: variants.map((variant) => variant.value),
    );
    // auto 重试结果直接加入，不经过类型过滤
    final result = refined.toList(growable: true);
    result.addAll(autoRetry);
    return result;
  }

  Future<TMDBCandidateResolution> _resolveAmbiguousTMDBCandidates(
    List<Map<String, dynamic>> candidates,
    ParsedMediaName parsed,
    List<_MediaTitleVariant> variants, {
    required String apiKey,
    required String proxyHost,
    required String proxyPort,
  }) {
    return MediaTMDBCandidateResolver.resolveAmbiguous(
      candidates: candidates,
      year: parsed.year,
      titleEvidence: variants.map((variant) => variant.value),
      loadDetails: (id, mediaType) => _tmdbDetails(
        id,
        mediaType == 'tv' ? TMDBMediaKind.tv : TMDBMediaKind.movie,
        apiKey: apiKey,
        proxyHost: proxyHost,
        proxyPort: proxyPort,
      ),
    );
  }

  Future<Map<String, dynamic>?> _tmdbCandidateFromPathTag(
    MediaLibraryItem fallback,
    String apiKey, {
    required String proxyHost,
    required String proxyPort,
  }) async {
    final id = _tmdbIDFromPath(fallback.file.cloudPath);
    if (id == null) return null;
    final preferred = fallback.mediaKind == TMDBMediaKind.tv
        ? TMDBMediaKind.tv
        : TMDBMediaKind.movie;
    final kinds = <TMDBMediaKind>{
      preferred,
      TMDBMediaKind.movie,
      TMDBMediaKind.tv,
    };
    for (final kind in kinds) {
      try {
        final details = await _tmdbDetails(
          id,
          kind,
          apiKey: apiKey,
          proxyHost: proxyHost,
          proxyPort: proxyPort,
        );
        final title = (details['title'] ?? details['name'])?.toString().trim();
        if (title == null || title.isEmpty) continue;
        return {
          ...details,
          'id': id,
          'media_type': kind == TMDBMediaKind.tv ? 'tv' : 'movie',
        };
      } catch (_) {
        // A TMDB id does not encode its media type. Try the other endpoint
        // before falling back to a regular title search.
      }
    }
    return null;
  }

  int? _tmdbIDFromPath(String cloudPath) {
    return mediaTMDBIDFromPath(cloudPath);
  }

  ({bool isValid, String reason}) _validatePersistedTMDBDetails(
    MediaLibraryItem fallback,
    Map<String, dynamic> details,
    TMDBMediaKind kind,
  ) {
    final parsed = ParsedMediaName.parse(
      fallback.file.name,
      directoryName: _parentDirectoryName(fallback.file.cloudPath),
      directoryPath: fallback.file.cloudPath,
    );
    if ((parsed.isEpisode || parsed.season != null) &&
        kind != TMDBMediaKind.tv) {
      return (isValid: false, reason: '剧集资源却保存为电影类型');
    }

    final releaseDate =
        (details['release_date'] ?? details['first_air_date'])?.toString() ??
        '';
    if (parsed.year != null &&
        releaseDate.isNotEmpty &&
        !releaseDate.startsWith('${parsed.year}')) {
      return (
        isValid: false,
        reason: '年份不一致：文件=${parsed.year}，TMDB=$releaseDate',
      );
    }

    final expected = parsed.title.trim().isEmpty
        ? fallback.title
        : parsed.title;
    final titleMatch = _bestMediaTitleMatchForVariants(
      _recognitionTitleVariants(fallback, primaryTitle: expected),
      title: (details['title'] ?? details['name'] ?? '').toString(),
      originalTitle:
          (details['original_title'] ?? details['original_name'] ?? '')
              .toString(),
    );
    if (titleMatch.score < 95) {
      return (
        isValid: false,
        reason: titleMatch.score == 0
            ? '标题与文件名、目录名均不相关'
            : '标题相似度不足：${titleMatch.basis}，评分=${titleMatch.score}',
      );
    }
    return (
      isValid: true,
      reason: '${titleMatch.basis}，评分=${titleMatch.score}',
    );
  }

  Future<MediaLibraryItem> _applyTMDBCandidateAndDetails(
    MediaLibraryItem fallback,
    Map<String, dynamic> candidate,
    String apiKey, {
    required String proxyHost,
    required String proxyPort,
  }) async {
    var item = _itemFromTMDBCandidate(fallback, candidate);
    if (item.tmdbID == null) return item;
    try {
      final details = await _tmdbDetails(
        item.tmdbID!,
        item.mediaKind,
        apiKey: apiKey,
        proxyHost: proxyHost,
        proxyPort: proxyPort,
      );
      item = _itemFromTMDBDetails(item, details);
    } catch (error) {
      _appendScanLog(
        '[同步识别][调试] TMDB 详情刷新失败，保留搜索候选：'
        'tmdbId=${item.tmdbID}，$error',
        isError: true,
      );
      // The selected search candidate remains usable when detail hydration fails.
    }
    return item;
  }

  Future<MediaLibraryItem> _renameMatchedMediaFile(
    MediaLibraryItem item, {
    int? manualSeason,
    int? manualEpisode,
  }) async {
    if (_api == null || item.mediaKind == null) {
      return item;
    }
    if (item.tmdbID == null && item.doubanID == null) {
      return item;
    }
    // 原盘文件夹内的资源不改名，保持源文件名
    if (isMediaScanDiscInternalPath(item.file.cloudPath)) {
      return item;
    }
    final directoryName = _parentDirectoryName(item.file.cloudPath);
    // Parse with the parent context first: numeric/disc file names commonly
    // keep title, year, season and release tags only on their parent folder.
    final fileParsed = ParsedMediaName.parse(
      item.file.name,
      directoryName: directoryName,
      directoryPath: item.file.cloudPath,
    );
    final parentParsed = directoryName == null
        ? null
        : ParsedMediaName.parse(directoryName);
    final parsed = ParsedMediaName(
      title: fileParsed.title,
      year: fileParsed.year ?? parentParsed?.year,
      season: manualSeason ?? fileParsed.season ?? parentParsed?.season,
      episode: manualEpisode ?? fileParsed.episode,
      isEpisode:
          (manualSeason ?? fileParsed.season ?? parentParsed?.season) != null &&
          (manualEpisode ?? fileParsed.episode) != null,
      resolution: fileParsed.resolution ?? parentParsed?.resolution,
      source: fileParsed.source ?? parentParsed?.source,
      videoCodec: fileParsed.videoCodec ?? parentParsed?.videoCodec,
      audio: fileParsed.audio ?? parentParsed?.audio,
      dynamicRange: fileParsed.dynamicRange ?? parentParsed?.dynamicRange,
    );
    final extension = _extensionOf(item.file.name);
    final year = item.year.isEmpty
        ? (fileParsed.year != null
            ? '.${fileParsed.year.toString().padLeft(4, '0').substring(0, 4)}'
            : '')
        : '.${item.year}';
    final episode = (item.mediaKind == TMDBMediaKind.tv ||
            item.mediaKind == null ||
            item.mediaKind == TMDBMediaKind.automatic) &&
        parsed.isEpisode
        ? '.S${parsed.season!.toString().padLeft(2, '0')}E${parsed.episode!.toString().padLeft(2, '0')}'
        : '';
    // 原文件名中的光盘标记（CD1/CD2/DISC1/DISK2 等）不能被丢弃：
    // 解析器会把它当作噪音剥离，重命名时若丢失会让多光盘文件无法区分。
    String? discMarker;
    final discMatch = RegExp(
      r'(?:\b(?:cd|disc|disk)[ ._-]*(\d{1,2})\b)',
      caseSensitive: false,
    ).firstMatch(item.file.name);
    if (discMatch != null) {
      final raw = discMatch.group(0)!.trim();
      final normalized = raw.toUpperCase().replaceAll(RegExp(r'[\s._-]+'), '');
      if (normalized.isNotEmpty) discMarker = normalized;
    }
    final technical = <String>[
      if (parsed.resolution?.isNotEmpty == true) parsed.resolution!,
      if (parsed.source?.isNotEmpty == true) parsed.source!,
      if (parsed.dynamicRange?.isNotEmpty == true) parsed.dynamicRange!,
      if (parsed.videoCodec?.isNotEmpty == true) parsed.videoCodec!,
      if (parsed.audio?.isNotEmpty == true) parsed.audio!,
      if (discMarker != null) discMarker!,
    ].join('.');
    // Keep every recognized technical tag when it is present, but a successful
    // TMDB match must also repair bare or otherwise irregular names such as
    // `1989.mp4`: `福星闯江湖.1989.mp4` is still a useful canonical name even
    // when the source provides no resolution or release information.
    final renameTitle = simplifiedMediaTitle(item.title);
    final baseName = (item.mediaKind == TMDBMediaKind.tv ||
                item.mediaKind == null ||
                item.mediaKind == TMDBMediaKind.automatic) &&
            parsed.isEpisode
        ? '$renameTitle$episode$year'
        : '$renameTitle$year';
    final targetName =
        '${_safeCloudName(technical.isEmpty ? baseName : '$baseName.$technical')}'
        '${extension.isEmpty ? '' : '.$extension'}';
    if (targetName == item.file.name) return item;

    try {
      await _api!.fsRename(item.file.id, targetName);
      final renamedFile =
          await _resolveCurrentCloudFile(
            item.file.copyWith(name: targetName),
          ) ??
          item.file.copyWith(name: targetName);
      return item.copyWith(file: renamedFile);
    } catch (error) {
      AppLogger.warning('Media', '识别成功但云盘重命名失败：fileId=${item.file.id}，$error');
      return item;
    }
  }

  String _extensionOf(String value) {
    final index = value.lastIndexOf('.');
    return index <= 0 ? '' : value.substring(index + 1).toLowerCase();
  }

  String? _parentDirectoryName(String cloudPath) {
    final values = cloudPath
        .split(RegExp(r'[\\/]'))
        .where((part) => part.isNotEmpty)
        .toList();
    return values.length < 2 ? null : values[values.length - 2];
  }

  String _parentPath(String cloudPath) {
    final index = cloudPath.lastIndexOf(RegExp(r'[\\/]'));
    return index <= 0 ? '' : cloudPath.substring(0, index);
  }

  String? _normalizedParentCloudPath(String cloudPath) {
    var normalized = cloudPath.trim().replaceAll(RegExp(r'\\+'), '/');
    normalized = normalized.replaceAll(RegExp(r'/+'), '/');
    while (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    final index = normalized.lastIndexOf('/');
    if (index < 0) return null;
    return normalized.substring(0, index);
  }

  bool _cloudFileMappingChanged(CloudFile previous, CloudFile current) {
    return previous.id != current.id ||
        previous.name != current.name ||
        previous.size != current.size ||
        previous.gcid != current.gcid ||
        previous.modifiedAt != current.modifiedAt ||
        previous.cloudPath != current.cloudPath ||
        previous.parentID != current.parentID ||
        previous.fullParentIDs != current.fullParentIDs ||
        previous.fileType != current.fileType;
  }

  String _cloudPathWithName(String cloudPath, String name) {
    final parentPath = _parentPath(cloudPath);
    return parentPath.isEmpty ? name : '$parentPath/$name';
  }

  /// Returns the searchable title evidence carried by a media path.  Do not
  /// replace the filename-derived title: release folders and filenames often
  /// intentionally use different languages.  Instead, score each meaningful
  /// variant independently and keep the strongest result.
  List<_MediaTitleVariant> _recognitionTitleVariants(
    MediaLibraryItem fallback, {
    String? primaryTitle,
  }) {
    final variants = <_MediaTitleVariant>[];
    final seen = <String>{};
    final parsedContext = ParsedMediaName.parse(
      fallback.file.name,
      directoryName: _parentDirectoryName(fallback.file.cloudPath),
      directoryPath: fallback.file.cloudPath,
    );

    bool isNoise(String value) {
      final normalized = value.trim();
      if (normalized.isEmpty) return true;
      if (const {
        '电影',
        '电视剧',
        '国产剧',
        '外语电影',
        '日韩剧',
        '综艺',
        '动漫',
        '纪录片',
        '音乐',
        '其他',
      }.contains(normalized)) {
        return true;
      }
      return RegExp(
        r'^(?:season|s)\s*\d{1,2}$',
        caseSensitive: false,
      ).hasMatch(normalized);
    }

    void add(String? raw, String source) {
      final value = raw?.trim() ?? '';
      if (isNoise(value)) return;
      final normalized = _normalizeMediaTitle(value);
      if (normalized.length < 2 || !seen.add(normalized)) return;
      variants.add(_MediaTitleVariant(value, source));
    }

    void addChineseSubtitleVariants(String? raw, String source) {
      final value = raw?.trim() ?? '';
      final match = RegExp(
        r'^([\u4e00-\u9fff][\u4e00-\u9fff\s]{1,})[·•・:：]([\u4e00-\u9fff][\u4e00-\u9fff\s]{1,})$',
      ).firstMatch(value);
      if (match == null) return;
      final mainTitle = match.group(1)!.trim();
      final subtitle = match.group(2)!.trim();
      add('$mainTitle$subtitle', '$source去副标题分隔符');
      add('$mainTitle之$subtitle', '$source副标题连接词');
      // Keep the broader series title last. TMDB sometimes stores a release
      // under its franchise title while scene names append the arc subtitle.
      add(mainTitle, '$source系列主名');
    }

    void addBilingualTitleVariant(String? raw, String source) {
      final value = (raw?.trim() ?? '')
          .replaceAll(RegExp(r'[._]+'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ');
      if (!RegExp(r'[\u4e00-\u9fff]').hasMatch(value)) return;
      final matches = RegExp(
        r"[A-Za-z][A-Za-z0-9]*(?:[ '\-]+[A-Za-z0-9]+){1,}",
      ).allMatches(value).toList(growable: false);
      if (matches.isEmpty) return;
      final englishTitle = matches
          .map((match) => match.group(0)!.trim())
          .where(
            (candidate) => !RegExp(
              r'\b(?:WEB[- ]?DL|WEBRip|BluRay|REMUX|HDTV|KKTV|AAC\d*|DDP\d*|HEVC|AVC|x26[45]|H[ .]?26[45])\b',
              caseSensitive: false,
            ).hasMatch(candidate),
          )
          .toList(growable: false);
      if (englishTitle.isEmpty) return;
      final preferredEnglishTitle = englishTitle.reduce(
        (first, second) => first.length >= second.length ? first : second,
      );
      add(preferredEnglishTitle, '$source英文标题');
    }

    void addEnglishSpellingVariants(String? raw, String source) {
      final value = raw?.trim() ?? '';
      if (!RegExp(r'[A-Za-z]').hasMatch(value)) return;
      const replacements = {
        'daeth': 'death',
        'asteriks': 'asterix',
        'saber': 'sabre',
        'sabre': 'saber',
        'color': 'colour',
        'colour': 'color',
        'center': 'centre',
        'centre': 'center',
        'honor': 'honour',
        'honour': 'honor',
        'gray': 'grey',
        'grey': 'gray',
      };
      for (final entry in replacements.entries) {
        final variant = value.replaceAllMapped(
          RegExp('\\b${entry.key}\\b', caseSensitive: false),
          (match) {
            final matched = match.group(0)!;
            if (matched == matched.toUpperCase()) {
              return entry.value.toUpperCase();
            }
            if (matched[0] == matched[0].toUpperCase()) {
              return '${entry.value[0].toUpperCase()}${entry.value.substring(1)}';
            }
            return entry.value;
          },
        );
        if (variant != value) add(variant, '$source拼写变体');
      }
    }

    void addEnglishSubtitleArticleVariants(String? raw, String source) {
      final value = raw?.trim() ?? '';
      final match = RegExp(
        r'^(.{4,}?)\s+the\s+(.{3,})$',
        caseSensitive: false,
      ).firstMatch(value);
      if (match == null) return;
      final franchise = match.group(1)!.trim();
      final subtitle = match.group(2)!.trim();
      if (!RegExp(r'[A-Za-z]').hasMatch(franchise) ||
          !RegExp(r'[A-Za-z]').hasMatch(subtitle)) {
        return;
      }
      add('$franchise: $subtitle', '$source英文副标题');
      add('$franchise $subtitle', '$source去副标题冠词');
    }

    void addAliasTitleVariants(String? raw, String source) {
      final value = raw?.trim() ?? '';
      final parts = value
          .split(
            RegExp(r'\s+(?:aka|又名|别名|亦名)\s*[:：,，.-]?\s*', caseSensitive: false),
          )
          .map((part) => part.trim())
          .where((part) => part.length >= 2)
          .toList(growable: false);
      if (parts.length < 2) return;
      for (final part in parts) {
        add(part, '$source别名');
        final cleaned = ParsedMediaName.parse(part).title.trim();
        if (cleaned.isNotEmpty && cleaned != part) {
          add(cleaned, '$source别名清理后');
        }
      }
    }

    void addNumberGlyphVariants(String? raw, String source) {
      final value = raw?.trim() ?? '';
      if (!RegExp(r'[①②③④⑤⑥⑦⑧⑨⑩]').hasMatch(value)) return;
      const replacements = {
        '①': '1',
        '②': '2',
        '③': '3',
        '④': '4',
        '⑤': '5',
        '⑥': '6',
        '⑦': '7',
        '⑧': '8',
        '⑨': '9',
        '⑩': '10',
      };
      final cleaned = ParsedMediaName.parse(value).title.trim();
      var normalized = cleaned.isEmpty ? value : cleaned;
      for (final entry in replacements.entries) {
        normalized = normalized.replaceAll(entry.key, entry.value);
      }
      add(normalized, '$source圈号归一');
      final firstInstallment = RegExp(
        r'^(.+?[\u4e00-\u9fff])\s*1$',
      ).firstMatch(normalized);
      if (firstInstallment != null) {
        add(firstInstallment.group(1), '$source首部标题');
      }
    }

    void addFranchiseReleaseTitleVariants(String? raw, String source) {
      final value = (raw?.trim() ?? '')
          .replaceFirst(
            RegExp(
              r'[ ._-]*(?:混剪完整版|重新调色版|(?:美亚|泰吉)?修复版?|完整版|加长版)\s*$',
              caseSensitive: false,
            ),
            '',
          )
          .trim();
      final numbered = RegExp(
        r'^(.{2,}?)(?:剧场版|電影|电影)\s*0*\d{1,2}\s*[:：]?\s*(.{2,})$',
        caseSensitive: false,
      ).firstMatch(value);
      if (numbered != null) {
        final franchise = numbered.group(1)!.trim();
        final subtitle = numbered.group(2)!.trim();
        add('$franchise：$subtitle', '$source去剧场版序号');
        add('$franchise $subtitle', '$source去剧场版序号');
        return;
      }
      final movieLabel = RegExp(
        r'^(.{2,}?)(?:電影|电影)\s+(.{2,})$',
        caseSensitive: false,
      ).firstMatch(value);
      if (movieLabel != null) {
        final franchise = movieLabel.group(1)!.trim();
        final subtitle = movieLabel.group(2)!.trim();
        add('$franchise：$subtitle', '$source去电影标签');
        add('$franchise $subtitle', '$source去电影标签');
      }
    }

    void addDescriptiveTitleVariants(String? raw, String source) {
      final value = raw?.trim() ?? '';
      final withoutParenthetical = value
          .replaceFirst(RegExp(r'\s*[（(][^（）()]{1,30}[）)]\s*$'), '')
          .trim();
      if (withoutParenthetical != value) {
        add(withoutParenthetical, '$source去尾注');
        final cleaned = ParsedMediaName.parse(
          withoutParenthetical,
        ).title.trim();
        if (cleaned.isNotEmpty && cleaned != withoutParenthetical) {
          add(cleaned, '$source去尾注清理后');
        }
      }
      final firstSentence = value.split(RegExp(r'[。；;！!]')).first.trim();
      if (firstSentence.length >= 2 && firstSentence != value) {
        add(firstSentence, '$source主标题');
      }
      final withoutEdition = value
          .replaceFirst(
            RegExp(
              r'[ ._-]*(?:混剪完整版|重新调色版|(?:美亚|泰吉)?修复版?|完整版|加长版)\s*$',
              caseSensitive: false,
            ),
            '',
          )
          .trim();
      if (withoutEdition != value) {
        add(withoutEdition, '$source去版本说明');
      }
    }

    void addReleaseCleanVariant(String? raw, String source) {
      final value = raw?.trim() ?? '';
      if (value.isEmpty) return;
      final cleaned = ParsedMediaName.parse(value).title.trim();
      if (cleaned.isNotEmpty && cleaned != value) {
        add(cleaned, '$source清理后');
      }
      // Old TV folders frequently use a two-digit broadcast year as a suffix
      // (笑傲江湖96). Keep the original evidence, then try the title without
      // that edition suffix. This does not affect ordinary Title 1 names.
      final withoutEdition = RegExp(
        r'^(.+?[\u4e00-\u9fff][\u4e00-\u9fff\s]*)\s*(?:19|20)?\d{2}$',
      ).firstMatch(value);
      if (withoutEdition != null) {
        add(withoutEdition.group(1), '$source去版本年份');
      }
    }

    void addTVSeasonTitleVariants(String? raw, String source) {
      if (!parsedContext.isEpisode || parsedContext.season == null) return;
      final value = raw?.trim() ?? '';
      final match = RegExp(
        r'^(.+?[\u4e00-\u9fff])\s*(\d{1,2})$',
      ).firstMatch(value);
      if (match == null) return;
      final season = int.tryParse(match.group(2)!);
      if (season == null || season != parsedContext.season) return;
      final seriesTitle = match.group(1)!.trim();
      add(seriesTitle, '$source去季号');
      add('$seriesTitle 第$season季', '$source季标题');
    }

    void addSimplifiedChineseVariants(String? raw, String source) {
      final value = raw?.trim() ?? '';
      if (!RegExp(r'[\u4e00-\u9fff]').hasMatch(value)) return;
      final simplified = ChineseHelper.convertToSimplifiedChinese(value);
      if (simplified == value) return;
      add(simplified, '$source简体标题');
      final cleaned = ParsedMediaName.parse(simplified).title.trim();
      if (cleaned.isNotEmpty && cleaned != simplified) {
        add(cleaned, '$source简体标题清理后');
      }
      addTVSeasonTitleVariants(simplified, '$source简体标题');
      addDescriptiveTitleVariants(simplified, '$source简体标题');
      addFranchiseReleaseTitleVariants(simplified, '$source简体标题');
      addChineseSubtitleVariants(simplified, '$source简体标题');

      final firstInstallment = RegExp(
        r'^(.+?[\u4e00-\u9fff])\s+1$',
      ).firstMatch(cleaned.isEmpty ? simplified : cleaned);
      if (firstInstallment != null) {
        add(firstInstallment.group(1), '$source简体首部标题');
      }
    }

    void addWithVariants(String? raw, String source) {
      add(raw, source);
      addReleaseCleanVariant(raw, source);
      addTVSeasonTitleVariants(raw, source);
      addAliasTitleVariants(raw, source);
      addNumberGlyphVariants(raw, source);
      addFranchiseReleaseTitleVariants(raw, source);
      addDescriptiveTitleVariants(raw, source);
      // Prefer a complete alternate-language title before falling back to a
      // broader franchise name.
      addBilingualTitleVariant(raw, source);
      addEnglishSpellingVariants(raw, source);
      addEnglishSubtitleArticleVariants(raw, source);
      addChineseSubtitleVariants(raw, source);
      addSimplifiedChineseVariants(raw, source);
    }

    final fileStem = fallback.file.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
    final lastReleaseBracket = fileStem.lastIndexOf(RegExp(r'[\]】]'));
    if (lastReleaseBracket >= 0 && lastReleaseBracket + 1 < fileStem.length) {
      final suffix = fileStem.substring(lastReleaseBracket + 1).trim();
      final suffixYear = RegExp(r'\b(?:19|20)\d{2}\b').firstMatch(suffix);
      final suffixTitle =
          (suffixYear == null ? suffix : suffix.substring(0, suffixYear.start))
              .replaceAll(RegExp(r'[._]+'), ' ')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
      addWithVariants(suffixTitle, '括号后作品名');
    }
    final episodeMarker = RegExp(
      r'\bS\s*0?\d{1,2}[ ._-]*E\s*0?\d{1,4}\b',
      caseSensitive: false,
    ).firstMatch(fileStem);
    if (episodeMarker != null && episodeMarker.start > 0) {
      final rawFileTitle = fileStem
          .substring(0, episodeMarker.start)
          .replaceAll(RegExp(r'[._]+'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      // 优先加入剥离年份的干净标题：如「超级宝贝JOJO 2019」→「超级宝贝
      // JOJO」。若把带年份的原始标题当作整体去 TMDB 搜索，叠加年份参数
      // 双重限制几乎必然失败。ParsedMediaName 的年份负向后顾不会误伤
      // 「你好1983」这类年份本就是剧名的情形。
      final parsedRaw = ParsedMediaName.parse(rawFileTitle);
      final cleanedRawTitle = parsedRaw.title.trim();
      if (parsedRaw.year != null &&
          cleanedRawTitle.isNotEmpty &&
          cleanedRawTitle != rawFileTitle) {
        addWithVariants(cleanedRawTitle, '文件名原始标题去年份');
      }
      // Keep this before the parsed title. A real work title may itself end
      // in `S01` or `S02`, while the following marker still identifies the
      // resource episode, for example `Project.S01.S01E01`.
      addWithVariants(rawFileTitle, '文件名原始标题');
    }
    addWithVariants(primaryTitle, '文件名');
    addBilingualTitleVariant(fileStem, '文件名原始标题');
    addAliasTitleVariants(fileStem, '文件名原始标题');
    addDescriptiveTitleVariants(fileStem, '文件名原始标题');

    final pathSegments = fallback.file.cloudPath
        .replaceAll(RegExp(r'\\+'), '/')
        .split('/')
        .where((segment) => segment.trim().isNotEmpty)
        .toList(growable: false);
    final lastDirectoryIndex = pathSegments.length - 2;
    // Inspect a few ancestors.  This covers a localized series/movie folder
    // nested below a season, resolution, or collection directory without
    // allowing an entire deep path to become a noisy search query.
    for (
      var index = lastDirectoryIndex;
      index >= 0 && index >= pathSegments.length - 6;
      index--
    ) {
      final segment = pathSegments[index];
      final parsed = ParsedMediaName.parse(segment);
      final source = index == lastDirectoryIndex ? '父目录' : '上级目录';
      // Keep the raw segment before the parsed title. A number that looks like
      // a year can be part of the actual show name, for example `你好1983`.
      addWithVariants(segment, '$source原名');
      addWithVariants(parsed.title, '$source解析');
    }

    // Legacy rows may have a better parsed title than the current filename.
    addWithVariants(fallback.title, '已有记录');
    // An unmatched legacy row can contain a stale original title from an old
    // guess; only reuse it when the row is already backed by a TMDB id.
    if (fallback.tmdbID != null) {
      addWithVariants(fallback.originalTitle, '原有原名');
    }
    return variants;
  }

  ({int score, String basis}) _bestMediaTitleMatchForVariants(
    Iterable<_MediaTitleVariant> variants, {
    required String title,
    required String originalTitle,
  }) {
    var best = (score: 0, basis: '');
    for (final variant in variants) {
      final match = _bestMediaTitleMatch(
        variant.value,
        title: title,
        originalTitle: originalTitle,
      );
      if (match.score > best.score) {
        best = (score: match.score, basis: '${variant.source}${match.basis}');
      }
    }
    return best;
  }

  /// Compares titles progressively. Literal text remains the strongest signal;
  /// punctuation and connector normalization only provide a fallback for
  /// release names that differ from TMDB's original title.
  ({int score, String basis}) _bestMediaTitleMatch(
    String expected, {
    required String title,
    required String originalTitle,
  }) {
    final match = MediaTitleMatcher.bestTMDBMatch(
      expected,
      title: title,
      originalTitle: originalTitle,
    );
    return (score: match.score, basis: match.basis);
  }

  int _fuzzyTitleScore(String query, String doubanTitle) {
    final q = MediaTitleMatcher.normalize(query);
    final d = MediaTitleMatcher.normalize(doubanTitle);
    if (q.isEmpty || d.isEmpty) return 0;
    if (q == d) return 80;
    if (q.contains(d) || d.contains(q)) return 60;
    var shared = 0;
    for (final rune in q.runes) {
      if (d.contains(String.fromCharCode(rune))) shared++;
    }
    final ratio = shared / q.length;
    if (ratio >= 0.6) return (ratio * 50).toInt();
    return 0;
  }

  String _normalizeMediaTitle(String value) {
    return MediaTitleMatcher.normalize(value);
  }

  String _safeCloudName(String value) {
    return safeMediaCloudName(value);
  }

  MediaLibraryItem _itemFromTMDBCandidate(
    MediaLibraryItem fallback,
    Map<String, dynamic> candidate,
  ) {
    final type = candidate['media_type']?.toString();
    final title = (candidate['title'] ?? candidate['name'])?.toString().trim();
    final originalTitle =
        (candidate['original_title'] ?? candidate['original_name'])
            ?.toString()
            .trim();
    final releaseDate =
        (candidate['release_date'] ?? candidate['first_air_date'])
            ?.toString() ??
        '';
    final source = candidate['_source']?.toString();
    final isDouban = source == 'douban';
    // Douban release_date is typically the China theatrical date, which may be
    // later than the TMDB (worldwide/US) date.  When both are available, keep
    // the earlier year so the displayed year matches the earliest known release
    // rather than a later local release.
    String effectiveReleaseDate = releaseDate;
    if (isDouban && fallback.releaseDate.isNotEmpty && releaseDate.isNotEmpty) {
      final fallbackYear = _releaseYearFromDate(fallback.releaseDate);
      final candidateYear = _releaseYearFromDate(releaseDate);
      if (fallbackYear != null &&
          candidateYear != null &&
          fallbackYear < candidateYear) {
        effectiveReleaseDate = fallback.releaseDate;
      }
    } else if (isDouban && fallback.releaseDate.isNotEmpty) {
      effectiveReleaseDate = fallback.releaseDate;
    }
    // TMDB and Douban ids co-exist on a single item: matching one source must
    // not clear the other. A Douban candidate keeps any existing TMDB id/rating
    // (and vice versa), so a resource can carry both scores and both links.
    final candidateDoubanID = isDouban
        ? candidate['id']?.toString()
        : candidate['douban_id']?.toString();
    final candidateRating = _ratingValue(candidate['vote_average']);
    return fallback.copyWith(
      // Only overwrite the id belonging to the matched source; leave the other
      // untouched (copyWith keeps the existing value when the arg is null).
      tmdbID: isDouban ? null : _toInt(candidate['id']),
      doubanID: (candidateDoubanID != null && candidateDoubanID.isNotEmpty)
          ? candidateDoubanID
          : null,
      title: title == null || title.isEmpty ? fallback.title : title,
      originalTitle: originalTitle == null || originalTitle.isEmpty
          ? fallback.originalTitle
          : originalTitle,
      mediaKind: type == 'tv'
          ? TMDBMediaKind.tv
          : type == 'movie'
          ? TMDBMediaKind.movie
          : fallback.mediaKind,
      releaseDate: effectiveReleaseDate.isNotEmpty ? effectiveReleaseDate : fallback.releaseDate,
      overview: candidate['overview']?.toString().trim().isNotEmpty == true
          ? candidate['overview'].toString()
          : fallback.overview,
      posterPath:
          candidate['poster_path']?.toString() ??
          (isDouban ? doubanPosterPath(candidate) : null) ??
          fallback.posterPath,
      backdropPath:
          candidate['backdrop_path']?.toString() ?? fallback.backdropPath,
      // Each source updates only its own rating; the other rating persists.
      tmdbRating: isDouban ? null : candidateRating,
      doubanRating: isDouban ? candidateRating : null,
      imdbID: _extractImdbID(candidate) ?? fallback.imdbID,
      updatedAt: DateTime.now(),
    );
  }

  Future<Map<String, dynamic>> _tmdbDetails(
    int id,
    TMDBMediaKind? kind, {
    required String apiKey,
    required String proxyHost,
    required String proxyPort,
  }) {
    final mediaKind = kind == TMDBMediaKind.tv ? 'tv' : 'movie';
    final key = '$mediaKind:$id';
    return _tmdbDetailsRequests.putIfAbsent(
      key,
      () => _api!.tmdbDetails(
        id,
        mediaKind: mediaKind,
        apiKey: apiKey,
        proxyHost: proxyHost,
        proxyPort: proxyPort,
      ),
    );
  }

  MediaLibraryItem _itemFromTMDBDetails(
    MediaLibraryItem item,
    Map<String, dynamic> details,
  ) {
    final title = (details['title'] ?? details['name'])?.toString().trim();
    final originalTitle =
        (details['original_title'] ?? details['original_name'])
            ?.toString()
            .trim();
    final releaseDate =
        (details['release_date'] ?? details['first_air_date'])?.toString() ??
        item.releaseDate;
    final collection = details['belongs_to_collection'];
    final collectionMap = collection is Map
        ? Map<String, dynamic>.from(collection)
        : const <String, dynamic>{};
    return item.copyWith(
      title: title == null || title.isEmpty ? item.title : title,
      originalTitle: originalTitle == null || originalTitle.isEmpty
          ? item.originalTitle
          : originalTitle,
      releaseDate: releaseDate,
      overview: details['overview']?.toString().trim().isNotEmpty == true
          ? details['overview'].toString()
          : item.overview,
      posterPath:
          _preferredArtworkPath(details, 'posters') ??
          details['poster_path']?.toString() ??
          item.posterPath,
      backdropPath:
          _preferredArtworkPath(details, 'backdrops') ??
          details['backdrop_path']?.toString() ??
          item.backdropPath,
      tmdbRating: _ratingValue(details['vote_average']) ?? item.tmdbRating,
      collectionID: _toInt(collectionMap['id']) ?? item.collectionID,
      collectionName: collectionMap['name']?.toString() ?? item.collectionName,
      imdbID: _extractImdbID(details) ?? item.imdbID,
      updatedAt: DateTime.now(),
    );
  }

  String? _preferredArtworkPath(Map<String, dynamic> details, String key) {
    final images = details['images'];
    if (images is! Map) return null;
    final values = images[key];
    if (values is! List) return null;
    const languages = ['zh-CN', 'zh', null, 'en'];
    for (final language in languages) {
      for (final value in values) {
        if (value is! Map || value['iso_639_1'] != language) continue;
        final path = value['file_path']?.toString();
        if (path != null && path.isNotEmpty) return path;
      }
    }
    for (final value in values) {
      if (value is! Map) continue;
      final path = value['file_path']?.toString();
      if (path != null && path.isNotEmpty) return path;
    }
    return null;
  }

  String? _extractImdbID(Map<String, dynamic> data) {
    final externalIDs = data['external_ids'];
    if (externalIDs is Map) {
      final imdbID = externalIDs['imdb_id']?.toString();
      if (imdbID != null && imdbID.isNotEmpty) return imdbID;
    }
    final imdbID = data['imdb_id']?.toString();
    if (imdbID != null && imdbID.isNotEmpty) return imdbID;
    return null;
  }

  int? _toInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '');
  }

  double? _ratingValue(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  Future<List<CloudFile>> _scanLibrarySourcesConcurrently(
    MediaLibraryDefinition library, {
    required int concurrency,
    required String libraryID,
    required Future<void> Function(List<CloudFile> files) onMediaFiles,
  }) async {
    final folders = [
      for (final source in library.sources)
        _ScanFolder(source.rootID, source.path),
    ];
    final visited = <String>{};
    final mediaFiles = <String, CloudFile>{};
    var nextFolder = 0;

    while (nextFolder < folders.length && !_scanShouldAbort(libraryID)) {
      if (!await _waitIfScanPaused(libraryID)) break;
      final batch = <_ScanFolder>[];
      while (nextFolder < folders.length && batch.length < concurrency) {
        final folder = folders[nextFolder++];
        if (visited.add(folder.id ?? '@root')) batch.add(folder);
      }
      if (batch.isEmpty) continue;

      final detailConcurrency = (concurrency / batch.length).ceil().clamp(
        1,
        concurrency,
      );
      final snapshots = await concurrentMapOrdered(
        batch,
        concurrency: concurrency,
        action: (folder) async {
          if (_scanShouldAbort(libraryID)) return const <CloudFile>[];
          if (!await _waitIfScanPaused(libraryID)) return const <CloudFile>[];
          final files = await _loadCloudIndexFolder(
            _CloudIndexFolder(folder.id, folder.path),
          );
          if (_scanShouldAbort(libraryID)) return const <CloudFile>[];
          return _enrichAndCacheFiles(
            files,
            concurrency: detailConcurrency,
            libraryID: libraryID,
          );
        },
      );
      if (_scanShouldAbort(libraryID)) break;
      final pathfulSnapshots = [
        for (var index = 0; index < batch.length; index++)
          [
            for (final file in snapshots[index])
              _withPath(
                file,
                batch[index].path.endsWith('/')
                    ? '${batch[index].path}${file.name}'
                    : '${batch[index].path}/${file.name}',
              ),
          ],
      ];
      await FileMetadataCache.cacheFolderChildrenBatch({
        for (var index = 0; index < batch.length; index++)
          batch[index].id: pathfulSnapshots[index],
      });

      for (var index = 0; index < batch.length; index++) {
        final files = pathfulSnapshots[index];
        final isDiscRoot = isMediaScanDiscLayout(files);
        final discoveredBatch = <CloudFile>[];
        if (isDiscRoot) {
          final mainFile = await _findDiscMainVideoFile(
            batch[index],
            files,
            libraryID: libraryID,
          );
          if (mainFile != null &&
              (mainFile.size ?? 0) >= library.minimumSizeMB * 1024 * 1024 &&
              !mediaFiles.containsKey(mainFile.id)) {
            mediaFiles[mainFile.id] = mainFile;
            discoveredBatch.add(mainFile);
            _appendScanLog(
              '原盘目录已选主体文件：${batch[index].path} → ${mainFile.name}',
            );
          } else if (mainFile == null) {
            _appendScanLog('原盘目录未找到主体播放文件：${batch[index].path}');
          }
        } else {
          for (final file in files) {
            final path = file.cloudPath;
            if (file.isDirectory) {
              if (library.recursive) {
                folders.add(_ScanFolder(file.id, path));
              }
              continue;
            }
            if (file.isVideo &&
                (file.size ?? 0) >= library.minimumSizeMB * 1024 * 1024 &&
                !isMediaScanIsoFile(file) &&
                !isMediaScanDiscInternalPath(path)) {
              final mediaFile = _withPath(file, path);
              if (!mediaFiles.containsKey(file.id)) {
                mediaFiles[file.id] = mediaFile;
                discoveredBatch.add(mediaFile);
              }
            }
          }
        }
        if (discoveredBatch.isNotEmpty) {
          await onMediaFiles(discoveredBatch);
        }
      }
      _setScanProgress(
        libraryID,
        MediaLibraryScanProgress(
          phase: '正在刷新媒体库目录，已检查 ${visited.length} 个文件夹',
          completed: mediaFiles.length,
        ),
      );
      _appendScanLog(
        '目录并发批次完成：检查 ${batch.length} 个文件夹，'
        '累计发现 ${mediaFiles.length} 个媒体文件',
      );
    }
    return mediaFiles.values.toList(growable: false);
  }

  Future<CloudFile?> _findDiscMainVideoFile(
    _ScanFolder root,
    List<CloudFile> immediateChildren, {
    String? libraryID,
  }) async {
    bool isDiscContainer(String name) {
      final upper = name.trim().toUpperCase();
      return upper == 'BDMV' || upper == 'VIDEO_TS' || upper == 'STREAM';
    }

    String pathFor(_ScanFolder folder, CloudFile file) {
      return folder.path.endsWith('/')
          ? '${folder.path}${file.name}'
          : '${folder.path}/${file.name}';
    }

    final rootName = root.path
        .split(RegExp(r'[/\\]+'))
        .lastWhere((part) => part.isNotEmpty, orElse: () => root.path)
        .toUpperCase();
    final selectedDiscDirectory = rootName == 'BDMV' || rootName == 'VIDEO_TS';
    final videos = <CloudFile>[
      for (final file in immediateChildren)
        if (!file.isDirectory && file.isVideo && !isMediaScanIsoFile(file))
          file,
    ];
    final queue = Queue<({CloudFile folder, int depth})>();
    for (final child in immediateChildren.where((file) => file.isDirectory)) {
      final upper = child.name.trim().toUpperCase();
      if (selectedDiscDirectory) {
        if (isDiscContainer(upper)) queue.add((folder: child, depth: 1));
      } else if (upper == 'BDMV' || upper == 'VIDEO_TS') {
        queue.add((folder: child, depth: 1));
      }
    }

    while (queue.isNotEmpty) {
      if (libraryID != null && _scanShouldAbort(libraryID)) break;
      if (libraryID != null && !await _waitIfScanPaused(libraryID)) break;
      final entry = queue.removeFirst();
      if (entry.depth > 3) continue;
      if (!isDiscContainer(entry.folder.name)) continue;
      final parent = _ScanFolder(entry.folder.id, entry.folder.cloudPath);
      try {
        var children = await _loadCloudIndexFolder(
          _CloudIndexFolder(entry.folder.id, entry.folder.cloudPath),
        );
        children = [
          for (final file in await _enrichAndCacheFiles(
            children,
            libraryID: libraryID,
          ))
            _withPath(file, pathFor(parent, file)),
        ];
        await FileMetadataCache.cacheFolderChildren(entry.folder.id, children);
        for (final child in children) {
          if (child.isDirectory) {
            if (isDiscContainer(child.name)) {
              queue.add((folder: child, depth: entry.depth + 1));
            }
          } else if (child.isVideo && !isMediaScanIsoFile(child)) {
            videos.add(child);
          }
        }
      } catch (error) {
        _appendScanLog(
          '原盘目录读取失败：${entry.folder.cloudPath}，$error',
          isError: true,
        );
      }
    }

    if (videos.isEmpty) return null;
    videos.sort((a, b) => (b.size ?? 0).compareTo(a.size ?? 0));
    return videos.first;
  }

  Future<void> _scanSource(
    String? rootID,
    String rootPath, {
    required String libraryID,
    required bool recursive,
    required int minimumSizeBytes,
    required bool forceRemote,
    required int initialCompleted,
    required Future<void> Function(List<CloudFile> files) onMediaFiles,
  }) async {
    final folders = <_ScanFolder>[_ScanFolder(rootID, rootPath)];
    final visited = <String>{};
    var discovered = 0;
    const parallelDirs = 5;

    while (folders.isNotEmpty && !_scanShouldAbort(libraryID)) {
      if (!await _waitIfScanPaused(libraryID)) break;

      final batch = <_ScanFolder>[];
      while (folders.isNotEmpty && batch.length < parallelDirs) {
        final folder = folders.removeAt(0);
        if (visited.add(folder.id ?? 'root')) {
          batch.add(folder);
        }
      }
      if (batch.isEmpty) continue;

      await Future.wait(batch.map((folder) async {
        if (_scanShouldAbort(libraryID)) return;
        AppLogger.info('Media', '扫描目录「${folder.path}」');
        var page = 0;
        final cachedFolder = forceRemote
            ? null
            : await FileMetadataCache.folderChildren(folder.id);
        if (cachedFolder != null && cachedFolder.isNotEmpty) {
          AppLogger.info('Media', '目录「${folder.path}」使用缓存，${cachedFolder.length} 项');
        } else {
          AppLogger.info('Media', '目录「${folder.path}」无缓存，调 API');
        }
        final folderSnapshot = <CloudFile>[];
        while (!_scanShouldAbort(libraryID)) {
          if (!await _waitIfScanPaused(libraryID)) break;
          late List<CloudFile> files;
          if (cachedFolder != null && cachedFolder.isNotEmpty && page == 0) {
            files = cachedFolder;
          } else {
            List<CloudFile>? apiFiles;
            for (var retry = 0; retry < 3; retry++) {
              if (_scanShouldAbort(libraryID)) break;
              try {
                final response = await _api!.fsFiles(
                  parentID: folder.id,
                  page: page,
                  pageSize: 200,
                  orderBy: 0,
                  sortType: 0,
                );
                apiFiles = _extractFiles(response);
                break;
              } catch (e) {
                if (retry < 2) {
                  AppLogger.warning('Media', '读取目录 ${folder.path} 失败（${retry + 1}/3），稍后重试：$e');
                  // Interruptible backoff: a cancel request during the wait
                  // takes effect immediately instead of after the full delay.
                  await _abortableDelay(
                    libraryID,
                    Duration(seconds: (retry + 1) * 2),
                  );
                  if (_scanShouldAbort(libraryID)) break;
                } else {
                  AppLogger.warning('Media', '读取目录 ${folder.path} 3次均失败，跳过：$e');
                  _appendScanLog('跳过目录 ${folder.path}（网络错误）');
                }
              }
            }
            if (apiFiles == null) break;
            files = apiFiles;
            files = await _enrichAndCacheFiles(files, libraryID: libraryID);
            if (_scanShouldAbort(libraryID)) break;
          }
          files = [
            for (final file in files)
              _withPath(
                file,
                folder.path.endsWith('/')
                    ? '${folder.path}${file.name}'
                    : '${folder.path}/${file.name}',
              ),
          ];
          folderSnapshot.addAll(files);
          final isDiscRoot = isMediaScanDiscLayout(files);
          final mediaBatch = <CloudFile>[];
          if (isDiscRoot) {
            final mainFile = await _findDiscMainVideoFile(
              folder,
              files,
              libraryID: libraryID,
            );
            if (mainFile != null && (mainFile.size ?? 0) >= minimumSizeBytes) {
              mediaBatch.add(mainFile);
            }
          } else {
            var libDirCount = 0;
            var libVideoCount = 0;
            var libSmallCount = 0;
            var libIsoCount = 0;
            var libOtherCount = 0;
            for (final file in files) {
              if (file.isDirectory) {
                libDirCount += 1;
                if (recursive) {
                  final childPath = file.cloudPath;
                  if (!isMediaScanDiscInternalPath(childPath)) {
                    folders.add(_ScanFolder(file.id, childPath));
                  }
                }
              } else if (file.isVideo) {
                if (isMediaScanIsoFile(file)) {
                  libIsoCount += 1;
                } else if ((file.size ?? 0) < minimumSizeBytes) {
                  libSmallCount += 1;
                } else {
                  libVideoCount += 1;
                  mediaBatch.add(file);
                }
              } else {
                libOtherCount += 1;
              }
            }
            if (mediaBatch.isEmpty && files.isNotEmpty) {
              _appendScanLog(
                '目录 ${folder.path}：共 ${files.length} 项，'
                '子目录 $libDirCount，视频 $libVideoCount，'
                '小文件 $libSmallCount，ISO $libIsoCount，其他 $libOtherCount',
              );
            }
          }
          discovered += mediaBatch.length;
          if (mediaBatch.isNotEmpty) {
            await onMediaFiles(mediaBatch);
          }
          if (cachedFolder != null || files.length < 200) {
            await FileMetadataCache.cacheFolderChildren(
              folder.id,
              folderSnapshot,
            );
            break;
          }
          page += 1;
        }
      }));
    }
  }

  Future<List<CloudFile>> _enrichAndCacheFiles(
    List<CloudFile> files, {
    int concurrency = 6,
    String? libraryID,
  }) async {
    final resolved = <CloudFile>[];
    final pending = <CloudFile>[];
    for (final file in files) {
      final cached = await FileMetadataCache.file(file.id);
      if (cached != null) {
        final cachedPath = recoverCloudFilePath(
          fileName: file.name,
          candidatePath: file.cloudPath,
          knownPath: cached.cloudPath,
        );
        resolved.add(
          file.copyWith(
            size: cached.size,
            gcid: cached.gcid,
            modifiedAt: cached.modifiedAt,
            cloudPath: cachedPath,
          ),
        );
      } else if (!file.isDirectory &&
          (file.gcid == null || file.gcid!.isEmpty)) {
        pending.add(file);
      } else {
        resolved.add(file);
      }
    }
    if (pending.isEmpty) {
      await FileMetadataCache.cacheFiles(resolved);
      return resolved;
    }

    final enriched = <String, CloudFile>{
      for (final file in resolved) file.id: file,
    };
    var next = 0;
    Future<void> worker() async {
      while ((libraryID == null || !_scanShouldAbort(libraryID)) &&
          next < pending.length) {
        if (libraryID != null && !await _waitIfScanPaused(libraryID)) return;
        final file = pending[next++];
        try {
          final detail = await _api!.fsDetail(file.id);
          final detailFile = _extractFiles(
            detail,
          ).where((candidate) => candidate.id == file.id).firstOrNull;
          final gcid =
              detailFile?.gcid ??
              JsonDeep.findString(detail, const [
                'gcid',
                'gcId',
                'gcidValue',
                'hash',
              ]);
          final size =
              detailFile?.size ??
              JsonDeep.findInt(detail, const [
                'size',
                'fileSize',
                'resSize',
                'totalSize',
              ]);
          final detailPath = recoverCloudFilePath(
            fileName: detailFile?.name ?? file.name,
            candidatePath: detailFile?.cloudPath,
            knownPath: file.cloudPath,
          );
          enriched[file.id] = file.copyWith(
            name: detailFile?.name ?? file.name,
            cloudPath: detailPath,
            parentID: detailFile?.parentID ?? file.parentID,
            fullParentIDs: detailFile?.fullParentIDs ?? file.fullParentIDs,
            gcid: gcid,
            size: size,
          );
        } catch (_) {
          enriched[file.id] = file;
        }
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
    if (libraryID != null && _scanShouldAbort(libraryID)) return resolved;
    final values = [for (final file in files) enriched[file.id] ?? file];
    await FileMetadataCache.cacheFiles(values);
    return values;
  }

  /// 下载接口有时会将签名链接包在对象或 JSON 字符串中，不能直接把
  /// `url` 字段转换为字符串，否则会得到 "{url: ...}" 这样的无效地址。
  String? _findDownloadUrlDeep(dynamic value) {
    if (value is String) {
      final text = value.trim();
      final uri = Uri.tryParse(text);
      if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
        return uri.toString();
      }
      if ((text.startsWith('{') && text.endsWith('}')) ||
          (text.startsWith('[') && text.endsWith(']'))) {
        try {
          return _findDownloadUrlDeep(jsonDecode(text));
        } on FormatException {
          return null;
        }
      }
      return null;
    }
    if (value is Map) {
      const fields = <String>{
        'url',
        'downloadurl',
        'download_url',
        'downloadlink',
        'download_link',
        'signedurl',
        'signed_url',
        'signedlink',
        'signed_link',
        'directurl',
        'direct_url',
        'directlink',
        'direct_link',
        'dlink',
      };
      for (final entry in value.entries) {
        if (fields.contains(entry.key.toString().toLowerCase())) {
          final found = _findDownloadUrlDeep(entry.value);
          if (found != null) return found;
        }
      }
      for (final entry in value.values) {
        final found = _findDownloadUrlDeep(entry);
        if (found != null) return found;
      }
      return null;
    }
    if (value is Iterable) {
      for (final entry in value) {
        final found = _findDownloadUrlDeep(entry);
        if (found != null) return found;
      }
    }
    return null;
  }

  /// 仅记录字段名与类型，不写入包含临时签名的下载地址。
  String _describeDownloadResponse(dynamic value) {
    final entries = <String>[];
    void collect(dynamic current, [String path = '', int depth = 0]) {
      if (depth > 3 || entries.length >= 24) return;
      if (current is Map) {
        for (final entry in current.entries) {
          if (entries.length >= 24) return;
          final key = entry.key.toString();
          final nextPath = path.isEmpty ? key : '$path.$key';
          final type = entry.value is Map
              ? '对象'
              : entry.value is Iterable
              ? '列表'
              : entry.value.runtimeType.toString();
          entries.add('$nextPath($type)');
          collect(entry.value, nextPath, depth + 1);
        }
      } else if (current is Iterable && current is! String) {
        for (final entry in current.take(3)) {
          collect(entry, '$path[]', depth + 1);
        }
      }
    }

    collect(value);
    return entries.isEmpty ? '无可用字段' : entries.join('、');
  }

  CloudFile _withPath(CloudFile file, String path) {
    return CloudFile(
      id: file.id,
      name: file.name,
      isDirectory: file.isDirectory,
      size: file.size,
      gcid: file.gcid,
      subDirectoryCount: file.subDirectoryCount,
      subFileCount: file.subFileCount,
      modifiedAt: file.modifiedAt,
      cloudPath: path,
      parentID: file.parentID,
      fullParentIDs: file.fullParentIDs,
      fileType: file.fileType,
    );
  }

  Future<CloudFile?> _resolveCurrentCloudFile(
    CloudFile knownFile, {
    String? libraryID,
    Map<String, Future<List<CloudFile>>>? folderFilesRequests,
    void Function()? onConfirmedNotFound,
  }) async {
    var oldFileIDConfirmedMissing = false;
    var remoteFallbackCompleted = false;
    var gcidIndexExhausted = false;
    var fallbackLookupFailed = false;
    try {
      final detail = await _api!.fsDetail(knownFile.id);
      final current = _fileFromDetail(detail, knownFile.id, knownFile);
      if (current != null) {
        return _cacheResolvedCloudFile(knownFile, current);
      }
      _appendScanLog(
        '[同步识别][调试] 旧文件 ID 返回了无法解析的详情：${knownFile.id}；'
        '未确认资源已删除，继续按 GCID 与目录核验',
        isError: true,
      );
    } catch (error) {
      oldFileIDConfirmedMissing = isConfirmedCloudFileMissingError(error);
      // A rename can replace the cloud record. Locate its new ID below.
      _appendScanLog(
        oldFileIDConfirmedMissing
            ? '[同步识别][调试] 旧文件 ID 已失效：${knownFile.id}；'
                  '开始核验原文件路径'
            : '[同步识别][调试] 旧文件 ID 暂时查询失败：${knownFile.id}，$error；'
                  '未确认丢失，继续按 GCID 与目录核验',
      );
    }

    final cached = await FileMetadataCache.file(knownFile.id);
    var parentID = mediaParentIDFromMetadata(knownFile, cachedFile: cached);
    var parentLocationKnown = parentID != null;
    if (!parentLocationKnown) {
      final cachedFolderID = await FileMetadataCache.parentFolderID(
        knownFile.id,
      );
      if (cachedFolderID != null) {
        parentLocationKnown = true;
        parentID = cachedFolderID.isEmpty ? null : cachedFolderID;
      }
    }
    if (!parentLocationKnown && _parentPath(knownFile.cloudPath).isEmpty) {
      // A path without a parent component represents a root-level resource.
      parentLocationKnown = true;
    }
    final gcid = knownFile.gcid?.trim();
    if (oldFileIDConfirmedMissing) {
      if (!parentLocationKnown) {
        _appendScanLog(
          '[同步识别][调试] 旧文件 ID 已失效，但缺少父目录 ID，'
          '无法继续核验原路径，按失效记录直接移除影视条目',
        );
        onConfirmedNotFound?.call();
        return null;
      } else {
        Future<List<CloudFile>> loadParentFiles() async {
          return _allRemoteFolderFiles(parentID);
        }

        final parentRequestKey = parentID ?? '@root';
        try {
          final children = await (folderFilesRequests == null
              ? loadParentFiles()
              : folderFilesRequests.putIfAbsent(
                  parentRequestKey,
                  loadParentFiles,
                ));
          final exactPathCandidates = children.where(
            (candidate) =>
                candidate.id != knownFile.id &&
                candidate.isDirectory == knownFile.isDirectory &&
                candidate.name == knownFile.name,
          );
          for (final candidate in exactPathCandidates) {
            var resolved = candidate;
            if (gcid != null &&
                gcid.isNotEmpty &&
                candidate.gcid?.isNotEmpty != true) {
              try {
                final detail = await _api!.fsDetail(candidate.id);
                resolved =
                    _fileFromDetail(detail, candidate.id, candidate) ??
                    candidate;
              } catch (error) {
                if (!isConfirmedCloudFileMissingError(error)) {
                  _appendScanLog(
                    '[同步识别][调试] 原路径发现候选文件但暂时无法核验，'
                    '保留影视记录：${candidate.id}，$error',
                    isError: true,
                  );
                  return null;
                }
                continue;
              }
            }
            if (gcid != null && gcid.isNotEmpty && resolved.gcid != gcid) {
              continue;
            }
            _appendScanLog(
              '[同步识别][调试] 原路径发现新的文件 ID：'
              '${knownFile.id} -> ${resolved.id}',
            );
            return _cacheResolvedCloudFile(
              knownFile,
              resolved,
              cloudPath: knownFile.cloudPath,
            );
          }
          _appendScanLog(
            '[同步识别][调试] 旧文件 ID 与原路径均已失效，'
            '确认资源不存在，将移除影视记录',
          );
          onConfirmedNotFound?.call();
          return null;
        } catch (error) {
          if (isConfirmedCloudFileMissingError(error)) {
            _appendScanLog(
              '[同步识别][调试] 旧文件 ID 与原父目录均已失效，'
              '确认资源不存在，将移除影视记录',
            );
            onConfirmedNotFound?.call();
          } else {
            _appendScanLog('[同步识别][调试] 原路径核验失败，保留影视记录：$error', isError: true);
          }
          return null;
        }
      }
    }

    if (gcid != null && gcid.isNotEmpty) {
      final liveIndexReady =
          StorageManager.get<String>(StorageKeys.cloudIndexLiveGCIDVersion) ==
          '1';
      if (liveIndexReady) {
        final indexed =
            (await FileMetadataCache.liveFilesByGCIDs([gcid]))[gcid] ??
            const <CloudFile>[];
        var lookupFailed = false;
        for (final candidate in indexed) {
          if (candidate.id == knownFile.id) continue;
          try {
            final detail = await _api!.fsDetail(candidate.id);
            final current = _fileFromDetail(detail, candidate.id, candidate);
            if (current == null) continue;
            if (current.gcid?.isNotEmpty == true && current.gcid != gcid) {
              continue;
            }
            _appendScanLog(
              '[同步识别][调试] 从实时 GCID 索引恢复新文件：'
              '${knownFile.id} -> ${current.id}',
            );
            return _cacheResolvedCloudFile(
              knownFile,
              current,
              cloudPath: candidate.cloudPath.isEmpty
                  ? null
                  : candidate.cloudPath,
            );
          } catch (error) {
            if (!isConfirmedCloudFileMissingError(error)) {
              lookupFailed = true;
              fallbackLookupFailed = true;
            }
          }
        }
        gcidIndexExhausted = !lookupFailed;
        _appendScanLog(
          '[同步识别][调试] 实时 GCID 索引回查完成：GCID=$gcid，'
          '候选 ${indexed.length} 个，未找到有效文件',
        );
      }
    }
    final candidates = <CloudFile>[];
    final candidateIDs = <String>{};
    void addCandidates(Iterable<CloudFile> files) {
      for (final file in files) {
        if (file.isDirectory == knownFile.isDirectory &&
            file.name == knownFile.name &&
            candidateIDs.add(file.id)) {
          candidates.add(file);
        }
      }
    }

    if (parentID != null && parentID.isNotEmpty) {
      try {
        final response = await _api!.fsFiles(
          parentID: parentID,
          page: 0,
          pageSize: 1000,
          orderBy: 0,
          sortType: 0,
        );
        addCandidates(_extractFiles(response));
        remoteFallbackCompleted = true;
      } catch (error) {
        if (isConfirmedCloudFileMissingError(error)) {
          remoteFallbackCompleted = true;
        } else {
          fallbackLookupFailed = true;
        }
        // The global search below remains available when the parent is stale.
      }
    }
    try {
      final response = await _api!.searchFiles(
        knownFile.name,
        page: 0,
        pageSize: 100,
      );
      addCandidates(_extractFiles(response));
      remoteFallbackCompleted = true;
    } catch (error) {
      if (isConfirmedCloudFileMissingError(error)) {
        remoteFallbackCompleted = true;
      } else {
        fallbackLookupFailed = true;
      }
      // Return null below so callers can surface an actionable sync failure.
    }

    for (final candidate in candidates) {
      var resolved = candidate;
      if ((knownFile.gcid?.isNotEmpty ?? false) &&
          candidate.gcid != knownFile.gcid) {
        try {
          final detail = await _api!.fsDetail(candidate.id);
          resolved =
              _fileFromDetail(detail, candidate.id, candidate) ?? candidate;
        } catch (error) {
          if (!isConfirmedCloudFileMissingError(error)) {
            fallbackLookupFailed = true;
          }
          continue;
        }
      }
      if (knownFile.gcid?.isNotEmpty == true &&
          resolved.gcid != knownFile.gcid) {
        continue;
      }
      return _cacheResolvedCloudFile(knownFile, resolved);
    }

    if (gcid != null && gcid.isNotEmpty && parentID != null) {
      final located = await _resolveFromCurrentDirectory(
        knownFile,
        parentID: parentID,
      );
      if (located != null) return located;
    }
    final hasGCID = gcid != null && gcid.isNotEmpty;
    final fallbackExhausted = hasGCID
        ? gcidIndexExhausted && remoteFallbackCompleted
        : remoteFallbackCompleted;
    final confirmedNotFound =
        oldFileIDConfirmedMissing && fallbackExhausted && !fallbackLookupFailed;
    if (confirmedNotFound) {
      _appendScanLog(
        '[同步识别][调试] 旧文件 ID、GCID 与远端回查均未命中，'
        '确认资源已不存在，将移除影视记录',
      );
    } else {
      _appendScanLog(
        '[同步识别][调试] 未完成可靠的资源不存在核验，保留影视记录；'
        '建议刷新全盘索引后重试',
        isError: true,
      );
    }
    if (confirmedNotFound) onConfirmedNotFound?.call();
    return null;
  }

  Future<CloudFile?> _resolveFromCurrentDirectory(
    CloudFile knownFile, {
    required String parentID,
  }) async {
    final gcid = knownFile.gcid?.trim();
    if (gcid == null || gcid.isEmpty) return null;
    _appendScanLog('[同步识别][调试] 从当前文件目录扫描：父目录 ID=$parentID，GCID=$gcid');
    final parentPath = _parentPath(knownFile.cloudPath);
    List<CloudFile> children;
    try {
      children = await _allRemoteFolderFiles(parentID);
    } catch (_) {
      return null;
    }
    await FileMetadataCache.cacheFolderChildren(parentID, children);
    final extension = _extensionOf(knownFile.name).toLowerCase();
    final candidates = children
        .where((child) {
          if (child.isDirectory) return false;
          if (knownFile.size != null && child.size != knownFile.size) {
            return false;
          }
          return extension.isEmpty ||
              _extensionOf(child.name).toLowerCase() == extension;
        })
        .take(12);
    for (final child in candidates) {
      var resolved = child;
      if (resolved.gcid != gcid) {
        try {
          final detail = await _api!.fsDetail(child.id);
          resolved = _fileFromDetail(detail, child.id, child) ?? child;
        } catch (_) {
          continue;
        }
      }
      if (resolved.gcid == gcid) {
        final exact = _withRecognitionPath(
          resolved,
          knownFile.copyWith(
            cloudPath: parentPath.isEmpty
                ? knownFile.name
                : '$parentPath/${knownFile.name}',
          ),
        );
        _appendScanLog(
          '[同步识别][调试] 当前目录定位成功：${knownFile.id} -> '
          '${exact.id}，路径=${exact.cloudPath}',
        );
        return _cacheResolvedCloudFile(
          knownFile,
          exact,
          cloudPath: exact.cloudPath,
        );
      }
    }
    _appendScanLog(
      '[同步识别][调试] 当前文件目录未命中：已检查 ${children.length} 个条目，详情查询不超过 12 次',
    );
    return null;
  }

  Future<List<CloudFile>> _allRemoteFolderFiles(String? parentID) async {
    const pageSize = 1000;
    final files = <CloudFile>[];
    for (var page = 0; ; page++) {
      final response = await _api!.fsFiles(
        parentID: parentID,
        page: page,
        pageSize: pageSize,
        orderBy: 0,
        sortType: 0,
      );
      final batch = _extractFiles(response);
      files.addAll(batch);
      if (batch.length < pageSize) break;
    }
    return files;
  }

  Future<CloudFile> _cacheResolvedCloudFile(
    CloudFile knownFile,
    CloudFile resolved, {
    String? cloudPath,
  }) async {
    final resolvedPath = recoverCloudFilePath(
      fileName: resolved.name,
      candidatePath: cloudPath ?? resolved.cloudPath,
      knownPath: knownFile.cloudPath,
    );
    final file = knownFile.copyWith(
      id: resolved.id,
      name: resolved.name,
      size: resolved.size,
      gcid: resolved.gcid,
      modifiedAt: resolved.modifiedAt,
      cloudPath: resolvedPath,
      parentID: resolved.parentID ?? knownFile.parentID,
      fullParentIDs: resolved.fullParentIDs ?? knownFile.fullParentIDs,
      fileType: resolved.fileType,
    );
    await FileMetadataCache.cacheFiles([file]);
    final parentID = file.parentID ?? knownFile.parentID;
    if (parentID != null && parentID.isNotEmpty) {
      await FileMetadataCache.updateFolderChildren(
        parentID,
        removeIDs: file.id == knownFile.id ? const [] : [knownFile.id],
        addOrReplace: [file],
      );
    }
    return file;
  }

  CloudFile? _fileFromDetail(
    Map<String, dynamic> detail,
    String fileID,
    CloudFile fallback,
  ) {
    final extracted = _extractFiles(
      detail,
    ).where((file) => file.id == fileID).firstOrNull;
    if (extracted != null && extracted.name.isNotEmpty) return extracted;

    Map<String, dynamic>? findExactMap(dynamic value) {
      if (value is Map) {
        final map = Map<String, dynamic>.from(value);
        for (final key in const [
          'fileId',
          'file_id',
          'resId',
          'res_id',
          'id',
        ]) {
          if (map[key]?.toString() == fileID) return map;
        }
        for (final child in map.values) {
          final found = findExactMap(child);
          if (found != null) return found;
        }
      } else if (value is List) {
        for (final child in value) {
          final found = findExactMap(child);
          if (found != null) return found;
        }
      }
      return null;
    }

    final exact = findExactMap(detail);
    if (exact == null) return null;
    try {
      final parsed = CloudFile.fromJson(exact);
      if (parsed.name.isNotEmpty) return parsed;
    } catch (_) {
      // Fall back to extracting fields directly from the exact File ID object.
    }
    return fallback.copyWith(
      name:
          JsonDeep.findString(exact, const ['fileName', 'name', 'resName']) ??
          fallback.name,
      gcid: JsonDeep.findString(exact, const [
        'gcid',
        'gcId',
        'gcidValue',
        'hash',
      ]),
      size: JsonDeep.findInt(exact, const [
        'size',
        'fileSize',
        'resSize',
        'totalSize',
      ]),
      parentID: JsonDeep.findString(exact, const [
        'parentId',
        'parent_id',
        'parentFileId',
      ]),
    );
  }

  List<CloudFile> _extractFiles(Map<String, dynamic> json) {
    final result = <CloudFile>[];
    final seen = <String>{};

    void appendList(List<dynamic> values) {
      for (final value in values) {
        if (value is Map) {
          try {
            final file = CloudFile.fromJson(Map<String, dynamic>.from(value));
            if (seen.add(file.id)) result.add(file);
          } catch (_) {
            final id = value['fileId']?.toString() ?? value['id']?.toString() ?? '';
            final name = value['fileName']?.toString() ?? value['name']?.toString() ?? '';
            if (id.isNotEmpty && seen.add(id)) {
              result.add(CloudFile(id: id, name: name, isDirectory: value['isDir'] == true || value['resType'] == 2));
            }
          }
        }
      }
    }

    final preferred = _findArrayDeep(json, const [
      'list',
      'files',
      'fileList',
      'items',
      'records',
      'rows',
      'resList',
      'resourceList',
    ]);
    if (preferred != null) {
      appendList(preferred);
    }

    void visit(dynamic value) {
      if (value is Map) {
        try {
          final file = CloudFile.fromJson(Map<String, dynamic>.from(value));
          if (seen.add(file.id)) result.add(file);
        } catch (_) {
          final map = Map<String, dynamic>.from(value);
          final id = map['fileId']?.toString() ?? map['file_id']?.toString() ?? map['id']?.toString() ?? map['dirId']?.toString() ?? '';
          final name = map['fileName']?.toString() ?? map['dirName']?.toString() ?? map['name']?.toString() ?? '';
          if (id.isNotEmpty && seen.add(id)) {
            result.add(CloudFile(id: id, name: name, isDirectory: map['resType'] == 2 || map['isDir'] == true));
          }
        }
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
    return result;
  }

  Future<void> _migrateLegacyHiveIfNeeded() async {
    if (!await _store.isEmpty) return;
    final rawLibraries = StorageManager.get<dynamic>(
      StorageKeys.mediaLibraries,
    );
    if (rawLibraries is! List) return;
    final libraries = rawLibraries
        .whereType<Map>()
        .map(
          (item) =>
              MediaLibraryDefinition.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList();
    if (libraries.isEmpty) return;
    final rawItems = StorageManager.get<dynamic>(StorageKeys.mediaLibraryItems);
    final items = rawItems is List
        ? rawItems
              .whereType<Map>()
              .map(
                (item) =>
                    MediaLibraryItem.fromJson(Map<String, dynamic>.from(item)),
              )
              .where((item) => item.file.id.isNotEmpty)
              .toList()
        : <MediaLibraryItem>[];
    await _store.saveLibraries(libraries);
    await _store.replaceItems(items);
  }

  Future<List<MediaLibraryDefinition>> _loadLibraries() {
    return _store.libraries();
  }

  Future<List<MediaLibraryItem>> _loadItems(String libraryID) {
    return _store.items(libraryID: libraryID);
  }

  Future<List<MediaLibraryItem>> _loadAllItems() {
    return _store.items();
  }

  /// Loads every row belonging to one work (all episodes / all versions),
  /// bypassing `distinctWorks` pagination so detail pages can show the full
  /// episode list.
  Future<List<MediaLibraryItem>> itemsForWork({
    int? tmdbID,
    String? doubanID,
    String? title,
    int? year,
  }) => _store.itemsForWork(
    tmdbID: tmdbID,
    doubanID: doubanID,
    title: title,
    year: year,
  );

  Future<void> _saveLibraries(List<MediaLibraryDefinition> libraries) {
    return _store.saveLibraries(libraries);
  }

  Future<void> _replaceItemsByPreviousIDs(
    Map<String, MediaLibraryItem> replacements,
  ) async {
    if (replacements.isEmpty) return;
    await _store.replaceItemsByPreviousIDs(
      replacements.entries.map((entry) {
        final separator = entry.key.indexOf(':');
        if (separator <= 0 || separator == entry.key.length - 1) {
          throw FormatException('无效的媒体记录键：${entry.key}');
        }
        return (
          previousLibraryID: entry.key.substring(0, separator),
          previousFileID: entry.key.substring(separator + 1),
          item: entry.value,
        );
      }),
    );
  }

  Future<void> _removeMissingMediaItems(
    Iterable<MediaLibraryItem> values,
  ) async {
    final removedItems = values.toList(growable: false);
    final keys = removedItems
        .map((item) => '${item.libraryID}:${item.id}')
        .toSet();
    if (keys.isEmpty) return;
    final fileIDs = removedItems.map((item) => item.id).toSet();
    await _store.deleteItems(removedItems);
    final allItems = await _loadAllItems();
    final retainedFileIDs = allItems.map((item) => item.id).toSet();
    final orphanedFileIDs = fileIDs
        .where((fileID) => !retainedFileIDs.contains(fileID))
        .toSet();
    if (orphanedFileIDs.isNotEmpty) {
      await FileMetadataCache.removeFilesFromAllFolders(orphanedFileIDs);
      await FileMetadataCache.removeLiveFileIDs(orphanedFileIDs);
      await _removeWatchHistory?.call(orphanedFileIDs);
    }
    _searchResultsCache.clear();
    state = state.copyWith(
      items: state.items
          .where((item) => !keys.contains('${item.libraryID}:${item.id}'))
          .toList(),
      allItems: allItems,
    );
  }

  Future<int> _removeDiscInternalItems() async {
    final items = await _loadAllItems();
    final removed = items
        .where((item) => isMediaScanDiscInternalPath(item.file.cloudPath))
        .toList(growable: false);
    if (removed.isEmpty) return 0;
    return _store.deleteItems(removed);
  }

  Future<void> _upsertItems(Iterable<MediaLibraryItem> items) async {
    final list = items.toList(growable: false);
    await _store.upsertItems(list);
    // Mirror matched metadata into the shared TMDB/Douban works cache so that
    // enrichItemsWithWorkDetails can rehydrate any item that merely carries a
    // tmdb_id / douban_id. Runs in the background; never blocks the scan.
    unawaited(_mirrorWorksCache(list));
  }

  /// Fills in TMDB detail fields for rows that were matched with deferred
  /// details, then persists them.
  ///
  /// This is the consumer half of the scrape pipeline: matching (the producer)
  /// only resolves an id, and this stage turns that id into a full record.
  /// Work is deduplicated per `tmdbID`, so a season of 24 episodes costs a
  /// single detail request, and already-cached works cost none at all.
  Future<List<MediaLibraryItem>> _hydrateDeferredDetails(
    List<MediaLibraryItem> items, {
    required String apiKey,
    required String proxyHost,
    required String proxyPort,
    required String libraryID,
    int concurrency = 6,
  }) async {
    if (items.isEmpty || apiKey.trim().isEmpty) return items;
    final pending = [
      for (final item in items)
        if (item.needsDetailHydration && item.tmdbID != null) item,
    ];
    if (pending.isEmpty) return items;

    // Group by work: one detail fetch serves every file of the same title.
    final byWork = <int, List<MediaLibraryItem>>{};
    for (final item in pending) {
      byWork.putIfAbsent(item.tmdbID!, () => []).add(item);
    }

    // Reuse anything already mirrored into the works cache before hitting API.
    final cached = await _store.tmdbWorksByIDs(byWork.keys);
    final toFetch = byWork.keys.where((id) => !cached.containsKey(id)).toList();

    final details = <int, Map<String, dynamic>>{};
    var next = 0;
    Future<void> worker() async {
      while (!_scanShouldAbort(libraryID)) {
        if (next >= toFetch.length) break;
        final id = toFetch[next++];
        if (!await _waitIfScanPaused(libraryID)) return;
        final kind = byWork[id]!.first.mediaKind;
        try {
          details[id] = await _tmdbDetails(
            id,
            kind,
            apiKey: apiKey,
            proxyHost: proxyHost,
            proxyPort: proxyPort,
          );
        } catch (error) {
          AppLogger.warning('Media', '详情补全失败：tmdbId=$id，$error');
        }
      }
    }

    await Future.wait(
      List.generate(concurrency.clamp(1, 12), (_) => worker()),
    );

    final hydrated = <MediaLibraryItem>[];
    final result = [
      for (final item in items)
        () {
          final id = item.tmdbID;
          if (id == null || !item.needsDetailHydration) return item;
          final detail = details[id];
          if (detail != null) {
            final next = _itemFromTMDBDetails(item, detail);
            hydrated.add(next);
            return next;
          }
          final work = cached[id];
          if (work != null) {
            final next = item.copyWith(
              overview: item.overview.trim().isEmpty
                  ? work.overview
                  : item.overview,
              posterPath: item.posterPath?.trim().isNotEmpty == true
                  ? item.posterPath
                  : work.posterPath,
              backdropPath: item.backdropPath?.trim().isNotEmpty == true
                  ? item.backdropPath
                  : work.backdropPath,
              updatedAt: DateTime.now(),
            );
            hydrated.add(next);
            return next;
          }
          return item;
        }(),
    ];
    if (hydrated.isNotEmpty) {
      await _upsertItems(hydrated);
      _appendScanLog(
        '详情补全：${hydrated.length} 条'
        '（作品 ${byWork.length} 个，API 拉取 ${details.length} 次）',
      );
    }
    return result;
  }

  /// Persists TMDB/Douban work metadata from freshly matched items into the
  /// shared works tables (deduplicated per id within the batch).
  Future<void> _mirrorWorksCache(List<MediaLibraryItem> items) async {
    if (items.isEmpty) return;
    final tmdbWorks = <int, TMDBWork>{};
    final doubanWorks = <String, DoubanWork>{};
    final now = DateTime.now();
    for (final item in items) {
      final tmdbID = item.tmdbID;
      if (tmdbID != null && tmdbID != 0 && item.title.trim().isNotEmpty) {
        tmdbWorks[tmdbID] = TMDBWork(
          id: 0,
          tmdbID: tmdbID,
          title: item.title,
          originalTitle: item.originalTitle,
          mediaKind: item.mediaKind ?? TMDBMediaKind.automatic,
          releaseDate: item.releaseDate,
          overview: item.overview,
          posterPath: item.posterPath,
          backdropPath: item.backdropPath,
          rating: item.tmdbRating,
          imdbID: item.imdbID,
          createdAt: now,
        );
      }
      final doubanID = item.doubanID;
      if (doubanID != null &&
          doubanID.isNotEmpty &&
          item.title.trim().isNotEmpty) {
        doubanWorks[doubanID] = DoubanWork(
          id: 0,
          doubanID: doubanID,
          title: item.title,
          originalTitle: item.originalTitle,
          mediaKind: item.mediaKind ?? TMDBMediaKind.automatic,
          releaseDate: item.releaseDate,
          overview: item.overview,
          posterPath: item.posterPath,
          rating: item.doubanRating,
          createdAt: now,
        );
      }
    }
    try {
      await _store.upsertTMDBWorks(tmdbWorks.values);
      await _store.upsertDoubanWorks(doubanWorks.values);
    } catch (error, stackTrace) {
      AppLogger.warning(
        'Media',
        '同步 TMDB/豆瓣作品缓存失败：$error',
      );
      AppLogger.error('Media', '作品缓存同步异常', error: error, stackTrace: stackTrace);
    }
  }

  /*
  List<MediaLibraryDefinition> _loadLibraries() {
    final raw = StorageManager.get<dynamic>(StorageKeys.mediaLibraries);
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map(
          (item) =>
              MediaLibraryDefinition.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList();
  }

  List<MediaLibraryItem> _loadItems(String libraryID) {
    return _loadAllItems()
        .where((item) => item.libraryID == libraryID)
        .toList();
  }

  List<MediaLibraryItem> _loadAllItems() {
    final raw = StorageManager.get<dynamic>(StorageKeys.mediaLibraryItems);
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map(
          (item) => MediaLibraryItem.fromJson(Map<String, dynamic>.from(item)),
        )
        .where((item) => item.file.id.isNotEmpty)
        .toList();
  }

  Future<void> _saveLibraries(List<MediaLibraryDefinition> libraries) {
    return StorageManager.set(
      StorageKeys.mediaLibraries,
      libraries.map((library) => library.toJson()).toList(),
    );
  }

  Future<void> _saveAllItems(List<MediaLibraryItem> items) {
    return StorageManager.set(
      StorageKeys.mediaLibraryItems,
      items.map((item) => item.toJson()).toList(),
    );
  }
  */

  static List<dynamic>? _findArrayDeep(
    Map<String, dynamic> json,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = json[key];
      if (value is List) return value;
    }
    const preferredKeys = ['data', 'result', 'payload'];
    for (final key in preferredKeys) {
      final value = json[key];
      if (value is Map<String, dynamic>) {
        final found = _findArrayDeep(value, keys);
        if (found != null) return found;
      }
    }
    for (final entry in json.entries) {
      if (preferredKeys.contains(entry.key)) continue;
      final value = entry.value;
      if (value is Map<String, dynamic>) {
        final found = _findArrayDeep(value, keys);
        if (found != null) return found;
      }
    }
    return null;
  }
}

class _ScanFolder {
  final String? id;
  final String path;

  const _ScanFolder(this.id, this.path);
}

class _CloudIndexFolder {
  final String? id;
  final String label;

  const _CloudIndexFolder(this.id, this.label);
}

class _CloudIndexRefreshResult {
  final int checkedFolders;
  final int updatedFolders;
  final int updatedEntries;

  const _CloudIndexRefreshResult({
    required this.checkedFolders,
    required this.updatedFolders,
    required this.updatedEntries,
  });
}

class _CloudBackupDestination {
  final String id;
  final String path;

  const _CloudBackupDestination({required this.id, required this.path});
}

class _SyncedMediaItem {
  final MediaLibraryItem original;
  final MediaLibraryItem fallback;

  const _SyncedMediaItem({required this.original, required this.fallback});
}

final mediaLibraryProvider =
    StateNotifierProvider<MediaLibraryNotifier, MediaLibraryState>(
      (ref) => MediaLibraryNotifier(
        removeWatchHistory: (fileIDs) =>
            ref.read(watchHistoryProvider.notifier).removeFiles(fileIDs),
      ),
    );
