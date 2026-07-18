import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/legacy.dart';

import '../api/guangya_api.dart';
import '../core/storage/file_metadata_cache.dart';
import '../core/storage/media_library_store.dart';
import '../core/storage/storage_manager.dart';
import '../models/cloud_file.dart';
import '../models/media_library.dart';

class MediaLibraryState {
  final List<MediaLibraryDefinition> libraries;
  final String? selectedLibraryID;
  final List<MediaLibraryItem> items;
  final bool isLoading;
  final bool isScanning;
  final MediaLibraryScanProgress progress;
  final List<MediaLibraryScanLog> scanLogs;
  final String searchQuery;
  final String? errorMessage;
  final String? statusMessage;

  const MediaLibraryState({
    this.libraries = const [],
    this.selectedLibraryID,
    this.items = const [],
    this.isLoading = false,
    this.isScanning = false,
    this.progress = const MediaLibraryScanProgress(),
    this.scanLogs = const [],
    this.searchQuery = '',
    this.errorMessage,
    this.statusMessage,
  });

  MediaLibraryDefinition? get selectedLibrary {
    for (final library in libraries) {
      if (library.id == selectedLibraryID) return library;
    }
    return libraries.isEmpty ? null : libraries.first;
  }

  List<MediaLibraryItem> get visibleItems {
    final query = searchQuery.trim().toLowerCase();
    if (query.isEmpty) return items;
    return items.where((item) {
      return item.title.toLowerCase().contains(query) ||
          item.file.name.toLowerCase().contains(query) ||
          item.file.cloudPath.toLowerCase().contains(query);
    }).toList();
  }

  MediaLibraryStatistics get statistics =>
      MediaLibraryStatistics.fromItems(items);

  MediaLibraryState copyWith({
    List<MediaLibraryDefinition>? libraries,
    String? selectedLibraryID,
    bool clearSelectedLibrary = false,
    List<MediaLibraryItem>? items,
    bool? isLoading,
    bool? isScanning,
    MediaLibraryScanProgress? progress,
    List<MediaLibraryScanLog>? scanLogs,
    String? searchQuery,
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
      isLoading: isLoading ?? this.isLoading,
      isScanning: isScanning ?? this.isScanning,
      progress: progress ?? this.progress,
      scanLogs: scanLogs ?? this.scanLogs,
      searchQuery: searchQuery ?? this.searchQuery,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      statusMessage: clearStatus ? null : (statusMessage ?? this.statusMessage),
    );
  }
}

class MediaLibraryNotifier extends StateNotifier<MediaLibraryState> {
  GuangyaAPI? _api;
  final _store = MediaLibraryStore();
  final _tmdbDetailsRequests = <String, Future<Map<String, dynamic>>>{};
  final _searchResultsCache = <String, List<MediaLibraryItem>>{};
  final _artworkHydrationLibraries = <String>{};
  bool _loaded = false;
  bool _cancelScan = false;

  MediaLibraryNotifier() : super(const MediaLibraryState());

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
      final items = selectedID == null
          ? <MediaLibraryItem>[]
          : await _loadItems(selectedID);
      final logs = _loadScanHistory();
      state = state.copyWith(
        libraries: libraries,
        selectedLibraryID: selectedID,
        items: items,
        scanLogs: logs,
      );
      if (selectedID != null) {
        unawaited(_hydrateMissingArtwork(selectedID, items));
      }
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> selectLibrary(String id) async {
    final items = await _loadItems(id);
    state = state.copyWith(
      selectedLibraryID: id,
      items: items,
      searchQuery: '',
      clearError: true,
    );
    unawaited(_hydrateMissingArtwork(id, items));
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
    final libraries = [...state.libraries, library];
    await _saveLibraries(libraries);
    state = state.copyWith(
      libraries: libraries,
      selectedLibraryID: library.id,
      items: const [],
      statusMessage: '已创建媒体库「${library.name}」',
    );
  }

  Future<void> deleteLibrary(String id) async {
    final libraries = state.libraries
        .where((library) => library.id != id)
        .toList();
    final allItems = await _loadAllItems()
      ..removeWhere((item) => item.libraryID == id);
    await _saveLibraries(libraries);
    await _saveAllItems(allItems);
    final selectedID = libraries.isEmpty ? null : libraries.first.id;
    state = state.copyWith(
      libraries: libraries,
      selectedLibraryID: selectedID,
      clearSelectedLibrary: selectedID == null,
      items: selectedID == null ? const [] : await _loadItems(selectedID),
      statusMessage: '媒体库已删除',
    );
  }

  Future<void> updateLibrary(MediaLibraryDefinition library) async {
    if (library.name.trim().isEmpty || library.sources.isEmpty) return;
    final libraries = state.libraries
        .map((item) => item.id == library.id ? library : item)
        .toList();
    await _saveLibraries(libraries);
    state = state.copyWith(
      libraries: libraries,
      selectedLibraryID: library.id,
      items: await _loadItems(library.id),
      statusMessage: '媒体库「${library.name}」已更新',
    );
  }

  Future<void> importScrapedData(String backupPath) async {
    if (state.isLoading || state.isScanning) return;
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      clearStatus: true,
    );
    try {
      final stats = await _store.importBackup(backupPath);
      final libraries = await _loadLibraries();
      final selectedID = libraries.isEmpty ? null : libraries.first.id;
      state = state.copyWith(
        libraries: libraries,
        selectedLibraryID: selectedID,
        clearSelectedLibrary: selectedID == null,
        items: selectedID == null ? const [] : await _loadItems(selectedID),
        statusMessage: '刮削数据已导入，已回收 ${_formatBytes(stats.reclaimedBytes)}',
      );
      if (selectedID != null) {
        unawaited(_hydrateMissingArtwork(selectedID, state.items));
      }
    } catch (error) {
      state = state.copyWith(errorMessage: '导入失败：$error');
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> exportScrapedData(String destinationPath) async {
    if (state.isLoading || state.isScanning) return;
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      clearStatus: true,
    );
    try {
      await _store.exportBackupTo(destinationPath);
      state = state.copyWith(statusMessage: '刮削数据已导出');
    } catch (error) {
      state = state.copyWith(errorMessage: '导出失败：$error');
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> optimizeLocalStorage() async {
    if (state.isLoading || state.isScanning) return;
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
            : '已清理 ${stats.removedArtworkCount} 条本地图片缓存，回收 ${_formatBytes(stats.reclaimedBytes)}',
      );
    } catch (error) {
      state = state.copyWith(errorMessage: '数据库优化失败：$error');
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> scanSelectedLibrary() async {
    final library = state.selectedLibrary;
    if (library == null || _api == null || state.isScanning) return;

    _cancelScan = false;
    state = state.copyWith(
      isScanning: true,
      progress: const MediaLibraryScanProgress(phase: '准备扫描'),
      scanLogs: [
        MediaLibraryScanLog(
          createdAt: DateTime.now(),
          message: '任务已创建，开始扫描「${library.name}」',
        ),
      ],
      clearError: true,
      clearStatus: true,
    );

    try {
      final initialItems = await _loadAllItems()
        ..removeWhere((item) => item.libraryID == library.id);
      final unique = <String, MediaLibraryItem>{
        for (final item in await _loadItems(library.id)) item.file.id: item,
      };
      state = state.copyWith(items: unique.values.toList());
      final tmdbApiKey =
          StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
      final tmdbProxyHost =
          StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '';
      final tmdbProxyPort =
          StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '';
      var completed = 0;
      Future<void> pendingPersistence = Future.value();

      Future<void> indexBatch(List<CloudFile> files) async {
        final pending = files.toList();
        if (pending.isEmpty || _cancelScan) return;
        var next = 0;
        Future<void> worker() async {
          while (!_cancelScan && next < pending.length) {
            final file = pending[next++];
            final fallback = MediaLibraryItem.fromFile(
              library.id,
              file,
              directoryName: _parentDirectoryName(file.cloudPath),
            );
            final existing = unique[file.id];
            final fileChanged =
                existing != null &&
                (existing.file.name != file.name ||
                    existing.file.gcid != file.gcid ||
                    existing.file.cloudPath != file.cloudPath);
            var item = existing == null || fileChanged
                ? await _recognizeMediaItem(
                    fallback,
                    tmdbApiKey,
                    proxyHost: tmdbProxyHost,
                    proxyPort: tmdbProxyPort,
                  )
                : existing.copyWith(file: file);
            item = await _renameMatchedMediaFile(item);
            unique[file.id] = item;
            completed += 1;
            final visible = unique.values.toList()
              ..sort(
                (a, b) =>
                    a.title.toLowerCase().compareTo(b.title.toLowerCase()),
              );
            pendingPersistence = pendingPersistence.then(
              (_) => _upsertItems([item]),
            );
            await pendingPersistence;
            state = state.copyWith(
              items: visible,
              progress: MediaLibraryScanProgress(
                phase: tmdbApiKey.isEmpty ? '正在建立本地索引' : '正在识别 ${file.name}',
                completed: completed,
              ),
            );
            _appendScanLog(
              item.tmdbID == null
                  ? '已入库：${file.name}（未匹配 TMDB）'
                  : item.file.name == file.name
                  ? '已识别并入库：${file.name} → ${item.title}'
                  : '已识别并重命名：${file.name} → ${item.file.name}',
            );
          }
        }

        final concurrency =
            (int.tryParse(
                      StorageManager.get<String>(
                            StorageKeys.mediaScanConcurrency,
                          ) ??
                          '3',
                    ) ??
                    3)
                .clamp(1, 20);
        await Future.wait(List.generate(concurrency, (_) => worker()));
      }

      for (final source in library.sources) {
        if (_cancelScan) break;
        _appendScanLog('扫描目录：${source.path}');
        state = state.copyWith(
          progress: MediaLibraryScanProgress(
            phase: '扫描 ${source.path}',
            completed: completed,
          ),
        );
        await _scanSource(
          source.rootID,
          source.path,
          recursive: library.recursive,
          minimumSizeBytes: library.minimumSizeMB * 1024 * 1024,
          onMediaFiles: indexBatch,
        );
      }
      await pendingPersistence;
      final items = unique.values.toList()
        ..sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );

      final allItems = [...initialItems, ...items];
      final updatedLibrary = library.copyWith(updatedAt: DateTime.now());
      final libraries = state.libraries
          .map((item) => item.id == library.id ? updatedLibrary : item)
          .toList();

      await _saveAllItems(allItems);
      await _saveLibraries(libraries);
      state = state.copyWith(
        libraries: libraries,
        items: items,
        statusMessage: _cancelScan
            ? '扫描已停止，已保留 ${items.length} 个项目'
            : '扫描完成：${items.length} 个视频文件',
      );
      _appendScanLog(
        _cancelScan
            ? '扫描已停止，已保留 ${items.length} 个条目'
            : '扫描完成，共入库 ${items.length} 个条目',
      );
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
      _appendScanLog('扫描失败：$e', isError: true);
    } finally {
      state = state.copyWith(
        isScanning: false,
        progress: const MediaLibraryScanProgress(),
      );
      unawaited(_persistScanHistory());
    }
  }

  void cancelScan() {
    _cancelScan = true;
    state = state.copyWith(
      progress: const MediaLibraryScanProgress(phase: '正在停止扫描'),
    );
    _appendScanLog('正在请求停止扫描…');
  }

  void _appendScanLog(String message, {bool isError = false}) {
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

  Future<void> _persistScanHistory() => StorageManager.set(
    StorageKeys.mediaScanHistory,
    state.scanLogs.map((entry) => entry.toJson()).toList(),
  );

  void setSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
  }

  Future<List<MediaLibraryItem>> searchAllItems(String query) async {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return const [];
    final cached = _searchResultsCache[normalized];
    if (cached != null) return cached;
    final results =
        (await _loadAllItems()).where((item) {
          return item.title.toLowerCase().contains(normalized) ||
              item.file.name.toLowerCase().contains(normalized) ||
              item.file.cloudPath.toLowerCase().contains(normalized);
        }).toList()..sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
    _searchResultsCache[normalized] = results;
    return results;
  }

  Future<void> recognizeItems(Iterable<MediaLibraryItem> values) async {
    final apiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    if (_api == null || apiKey.trim().isEmpty) return;
    final groups = <String, List<MediaLibraryItem>>{};
    for (final item in values) {
      final parsed = ParsedMediaName.parse(item.file.name);
      final key =
          '${item.mediaKind?.name ?? 'automatic'}:${parsed.title.toLowerCase()}';
      groups.putIfAbsent(key, () => []).add(item);
    }
    final updates = <MediaLibraryItem>[];
    for (final group in groups.values) {
      final prototype = group.first;
      final recognized = await _recognizeMediaItem(
        prototype.copyWith(file: prototype.file),
        apiKey,
        proxyHost: StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '',
        proxyPort: StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '',
      );
      updates.addAll(group.map((item) => recognized.copyWith(file: item.file)));
    }
    if (updates.isEmpty) return;
    await _store.upsertItems(updates);
    _searchResultsCache.clear();
    final byID = {for (final item in updates) item.id: item};
    state = state.copyWith(
      items: state.items.map((item) => byID[item.id] ?? item).toList(),
      statusMessage: '已识别 ${updates.length} 个资源（${groups.length} 个作品）',
    );
  }

  /// Pulls current file metadata from the cloud before parsing and matching it.
  /// This is required after a file was renamed outside the media scanner.
  Future<void> refreshAndRecognizeItems(
    Iterable<MediaLibraryItem> values,
  ) async {
    if (_api == null) return;
    final originals = values.toList();
    if (originals.isEmpty) return;
    final apiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    state = state.copyWith(statusMessage: '正在同步云盘文件信息…', clearError: true);
    final updates = <MediaLibraryItem>[];
    for (final original in originals) {
      try {
        final detail = await _api!.fsDetail(original.file.id);
        final fromCloud = _extractFiles(
          detail,
        ).where((file) => file.id == original.file.id).firstOrNull;
        final latestName =
            fromCloud?.name ??
            _findStringDeep(detail, const ['fileName', 'name', 'resName']) ??
            original.file.name;
        final latestGCID =
            fromCloud?.gcid ??
            _findStringDeep(detail, const [
              'gcid',
              'gcId',
              'gcidValue',
              'hash',
            ]) ??
            original.file.gcid;
        final parentPath = _parentPath(original.file.cloudPath);
        final latestFile = original.file.copyWith(
          name: latestName,
          size: fromCloud?.size,
          gcid: latestGCID,
          modifiedAt: fromCloud?.modifiedAt,
          cloudPath: parentPath.isEmpty
              ? latestName
              : '$parentPath/$latestName',
          parentID: fromCloud?.parentID,
          fullParentIDs: fromCloud?.fullParentIDs,
        );
        await FileMetadataCache.cacheFiles([latestFile]);
        final fallback = MediaLibraryItem.fromFile(
          original.libraryID,
          latestFile,
          directoryName: _parentDirectoryName(latestFile.cloudPath),
        );
        var updated = apiKey.trim().isEmpty
            ? fallback
            : await _recognizeMediaItem(
                fallback,
                apiKey,
                proxyHost:
                    StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '',
                proxyPort:
                    StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '',
              );
        updated = await _renameMatchedMediaFile(updated);
        updates.add(updated);
      } catch (_) {
        // Keep indexing the remaining resources when one cloud detail fails.
      }
    }
    if (updates.isEmpty) return;
    await _store.upsertItems(updates);
    _searchResultsCache.clear();
    final byID = {for (final item in updates) item.id: item};
    state = state.copyWith(
      items: state.items.map((item) => byID[item.id] ?? item).toList(),
      statusMessage: '已同步并重新识别 ${updates.length} 个资源',
    );
  }

  Future<MediaLibraryItem> applyTMDBMatch(
    MediaLibraryItem item,
    Map<String, dynamic> candidate,
  ) async {
    final apiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    var updated = _itemFromTMDBCandidate(item, candidate);
    if (updated.tmdbID != null && apiKey.isNotEmpty) {
      try {
        final details = await _tmdbDetails(
          updated.tmdbID!,
          updated.mediaKind,
          apiKey: apiKey,
          proxyHost:
              StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '',
          proxyPort:
              StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '',
        );
        updated = _itemFromTMDBDetails(updated, details);
      } catch (_) {
        // A selected candidate is still valid if its detail request fails.
      }
    }
    await _store.upsertItems([updated]);
    state = state.copyWith(
      items: state.items
          .map((current) => current.id == updated.id ? updated : current)
          .toList(),
      statusMessage: '已匹配《${updated.title}》',
      clearError: true,
    );
    return updated;
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
                      '3',
                ) ??
                3)
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
            } catch (_) {
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

  Future<MediaLibraryItem> _recognizeMediaItem(
    MediaLibraryItem fallback,
    String apiKey, {
    required String proxyHost,
    required String proxyPort,
  }) async {
    if (_api == null || apiKey.trim().isEmpty) return fallback;
    try {
      final result = await _api!.tmdbSearch(
        fallback.title,
        apiKey: apiKey,
        proxyHost: proxyHost,
        proxyPort: proxyPort,
      );
      final values = result['results'];
      if (values is! List) return fallback;
      Map<String, dynamic>? candidate;
      for (final value in values) {
        if (value is! Map) continue;
        final map = Map<String, dynamic>.from(value);
        final type = map['media_type']?.toString();
        if (type == 'movie' || type == 'tv') {
          candidate = map;
          break;
        }
      }
      if (candidate == null) return fallback;
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
      } catch (_) {
        // The search result already has enough information for an initial row.
      }
      return item;
    } catch (_) {
      return fallback;
    }
  }

  Future<MediaLibraryItem> _renameMatchedMediaFile(
    MediaLibraryItem item,
  ) async {
    if (_api == null || item.tmdbID == null || item.mediaKind == null) {
      return item;
    }
    final directoryName = _parentDirectoryName(item.file.cloudPath);
    // Parse with the parent context first: numeric/disc file names commonly
    // keep title, year, season and release tags only on their parent folder.
    final fileParsed = ParsedMediaName.parse(
      item.file.name,
      directoryName: directoryName,
    );
    final parentParsed = directoryName == null
        ? null
        : ParsedMediaName.parse(directoryName);
    final parsed = ParsedMediaName(
      title: fileParsed.title,
      year: fileParsed.year ?? parentParsed?.year,
      season: fileParsed.season ?? parentParsed?.season,
      episode: fileParsed.episode,
      isEpisode: fileParsed.isEpisode,
      resolution: fileParsed.resolution ?? parentParsed?.resolution,
      source: fileParsed.source ?? parentParsed?.source,
      videoCodec: fileParsed.videoCodec ?? parentParsed?.videoCodec,
      audio: fileParsed.audio ?? parentParsed?.audio,
      dynamicRange: fileParsed.dynamicRange ?? parentParsed?.dynamicRange,
    );
    // A canonical media name must retain a resolution. If neither the file nor
    // its immediate directory provides one, leave the resource untouched.
    if (parsed.resolution == null || parsed.resolution!.isEmpty) return item;
    final extension = _extensionOf(item.file.name);
    final year = item.year.isEmpty ? '' : '.${item.year}';
    final episode = item.mediaKind == TMDBMediaKind.tv && parsed.isEpisode
        ? '.S${parsed.season!.toString().padLeft(2, '0')}E${parsed.episode!.toString().padLeft(2, '0')}'
        : '';
    final technical = <String>[
      parsed.resolution!,
      if (parsed.source?.isNotEmpty == true) parsed.source!,
      if (parsed.dynamicRange?.isNotEmpty == true) parsed.dynamicRange!,
      if (parsed.videoCodec?.isNotEmpty == true) parsed.videoCodec!,
      if (parsed.audio?.isNotEmpty == true) parsed.audio!,
    ].join('.');
    final targetName =
        '${_safeCloudName('${item.title}$year$episode.$technical')}${extension.isEmpty ? '' : '.$extension'}';
    if (targetName == item.file.name) return item;

    try {
      await _api!.fsRename(item.file.id, targetName);
      final updated = item.copyWith(file: item.file.copyWith(name: targetName));
      await _writeNfoForRenamedMedia(updated, parsed);
      return updated;
    } catch (_) {
      return item;
    }
  }

  Future<void> _writeNfoForRenamedMedia(
    MediaLibraryItem item,
    ParsedMediaName parsed,
  ) async {
    try {
      final detail = await _api!.fsDetail(item.file.id);
      final parentID = _findStringDeep(detail, const [
        'parentId',
        'parent_id',
        'parentFileId',
      ]);
      if (parentID == null || parentID.isEmpty) return;
      final isEpisode = item.mediaKind == TMDBMediaKind.tv && parsed.isEpisode;
      final nfoName = isEpisode
          ? '${_safeCloudName(item.title)}.S${parsed.season!.toString().padLeft(2, '0')}E${parsed.episode!.toString().padLeft(2, '0')}.nfo'
          : item.mediaKind == TMDBMediaKind.tv
          ? 'tvshow.nfo'
          : 'movie.nfo';
      final root = isEpisode
          ? 'episodedetails'
          : item.mediaKind == TMDBMediaKind.tv
          ? 'tvshow'
          : 'movie';
      final technical = <String>[
        if (parsed.resolution != null)
          '<resolution>${_xml(parsed.resolution!)}</resolution>',
        if (parsed.source != null) '<source>${_xml(parsed.source!)}</source>',
        if (parsed.videoCodec != null)
          '<codec>${_xml(parsed.videoCodec!)}</codec>',
        if (parsed.dynamicRange != null)
          '<hdr>${_xml(parsed.dynamicRange!)}</hdr>',
        if (parsed.audio != null) '<audio>${_xml(parsed.audio!)}</audio>',
      ].join();
      final episodeFields = isEpisode
          ? '<season>${parsed.season}</season><episode>${parsed.episode}</episode>'
          : '';
      final xml =
          '<?xml version="1.0" encoding="UTF-8"?>'
          '<$root><uniqueid type="tmdb" default="true">${item.tmdbID}</uniqueid>'
          '<title>${_xml(item.title)}</title>'
          '<originaltitle>${_xml(item.originalTitle)}</originaltitle>'
          '<year>${_xml(item.year)}</year>'
          '<plot>${_xml(item.overview)}</plot>$episodeFields'
          '<fileinfo><streamdetails><video>$technical</video></streamdetails></fileinfo>'
          '</$root>';
      final temp = File('${Directory.systemTemp.path}/$nfoName');
      await temp.writeAsString(xml, flush: true);
      try {
        await _api!.fileUpload(
          temp,
          parentID: parentID,
          contentType: 'application/xml',
        );
      } finally {
        if (await temp.exists()) await temp.delete();
      }
    } catch (_) {
      // File renaming remains successful if sidecar upload is unavailable.
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

  String _safeCloudName(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final fallback = cleaned.isEmpty ? 'Untitled' : cleaned;
    return fallback.length > 180 ? fallback.substring(0, 180).trim() : fallback;
  }

  String _xml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

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
    return fallback.copyWith(
      tmdbID: _toInt(candidate['id']),
      title: title == null || title.isEmpty ? fallback.title : title,
      originalTitle: originalTitle == null || originalTitle.isEmpty
          ? fallback.originalTitle
          : originalTitle,
      mediaKind: type == 'tv' ? TMDBMediaKind.tv : TMDBMediaKind.movie,
      releaseDate: releaseDate,
      overview: candidate['overview']?.toString() ?? '',
      posterPath: candidate['poster_path']?.toString(),
      backdropPath: candidate['backdrop_path']?.toString(),
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
      collectionID: _toInt(collectionMap['id']) ?? item.collectionID,
      collectionName: collectionMap['name']?.toString() ?? item.collectionName,
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

  int? _toInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '');
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Future<void> _scanSource(
    String? rootID,
    String rootPath, {
    required bool recursive,
    required int minimumSizeBytes,
    required Future<void> Function(List<CloudFile> files) onMediaFiles,
  }) async {
    final folders = <_ScanFolder>[_ScanFolder(rootID, rootPath)];
    final visited = <String>{};
    var discovered = 0;

    while (folders.isNotEmpty && !_cancelScan) {
      final folder = folders.removeAt(0);
      final visitKey = folder.id ?? 'root';
      if (!visited.add(visitKey)) continue;

      var page = 0;
      final cachedFolder = await FileMetadataCache.folderChildren(folder.id);
      final folderSnapshot = <CloudFile>[];
      while (!_cancelScan) {
        late List<CloudFile> files;
        if (cachedFolder != null) {
          files = cachedFolder;
        } else {
          final response = await _api!.fsFiles(
            parentID: folder.id,
            page: page,
            pageSize: 200,
            orderBy: 0,
            sortType: 0,
          );
          files = _extractFiles(response);
          files = await _enrichAndCacheFiles(files);
          folderSnapshot.addAll(files);
        }
        final mediaBatch = <CloudFile>[];
        for (final file in files) {
          if (file.isDirectory) {
            if (recursive) {
              folders.add(_ScanFolder(file.id, '${folder.path}/${file.name}'));
            }
          } else if (file.isVideo && (file.size ?? 0) >= minimumSizeBytes) {
            mediaBatch.add(_withPath(file, '${folder.path}/${file.name}'));
          }
        }
        discovered += mediaBatch.length;
        if (mediaBatch.isNotEmpty) await onMediaFiles(mediaBatch);

        state = state.copyWith(
          progress: MediaLibraryScanProgress(
            phase: '扫描 ${folder.path}',
            completed: discovered,
            total: folders.length + visited.length,
          ),
        );

        if (cachedFolder != null || files.length < 200) {
          if (cachedFolder == null) {
            await FileMetadataCache.cacheFolderChildren(
              folder.id,
              folderSnapshot,
            );
          }
          break;
        }
        page += 1;
      }
    }
  }

  Future<List<CloudFile>> _enrichAndCacheFiles(List<CloudFile> files) async {
    final resolved = <CloudFile>[];
    final pending = <CloudFile>[];
    for (final file in files) {
      final cached = await FileMetadataCache.file(file.id);
      if (cached != null) {
        resolved.add(
          file.copyWith(
            size: cached.size,
            gcid: cached.gcid,
            modifiedAt: cached.modifiedAt,
            cloudPath: file.cloudPath,
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
      while (next < pending.length) {
        final file = pending[next++];
        try {
          final detail = await _api!.fsDetail(file.id);
          final detailFile = _extractFiles(
            detail,
          ).where((candidate) => candidate.id == file.id).firstOrNull;
          final gcid =
              detailFile?.gcid ??
              _findStringDeep(detail, const [
                'gcid',
                'gcId',
                'gcidValue',
                'hash',
              ]);
          final size =
              detailFile?.size ??
              _findIntDeep(detail, const [
                'size',
                'fileSize',
                'resSize',
                'totalSize',
              ]);
          enriched[file.id] = file.copyWith(gcid: gcid, size: size);
        } catch (_) {
          enriched[file.id] = file;
        }
      }
    }

    await Future.wait(List.generate(6, (_) => worker()));
    final values = [for (final file in files) enriched[file.id] ?? file];
    await FileMetadataCache.cacheFiles(values);
    return values;
  }

  String? _findStringDeep(Map<String, dynamic> value, List<String> keys) {
    for (final entry in value.entries) {
      if (keys.contains(entry.key) && entry.value != null) {
        final text = entry.value.toString().trim();
        if (text.isNotEmpty) return text;
      }
      if (entry.value is Map) {
        final found = _findStringDeep(
          Map<String, dynamic>.from(entry.value),
          keys,
        );
        if (found != null) return found;
      } else if (entry.value is List) {
        for (final child in entry.value as List) {
          if (child is Map) {
            final found = _findStringDeep(
              Map<String, dynamic>.from(child),
              keys,
            );
            if (found != null) return found;
          }
        }
      }
    }
    return null;
  }

  int? _findIntDeep(Map<String, dynamic> value, List<String> keys) {
    for (final entry in value.entries) {
      if (keys.contains(entry.key)) {
        final parsed = int.tryParse(entry.value?.toString() ?? '');
        if (parsed != null) return parsed;
      }
      if (entry.value is Map) {
        final found = _findIntDeep(
          Map<String, dynamic>.from(entry.value),
          keys,
        );
        if (found != null) return found;
      } else if (entry.value is List) {
        for (final child in entry.value as List) {
          if (child is Map) {
            final found = _findIntDeep(Map<String, dynamic>.from(child), keys);
            if (found != null) return found;
          }
        }
      }
    }
    return null;
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

  List<CloudFile> _extractFiles(Map<String, dynamic> json) {
    final result = <CloudFile>[];
    final seen = <String>{};

    void appendList(List<dynamic> values) {
      for (final value in values) {
        if (value is Map) {
          try {
            final file = CloudFile.fromJson(Map<String, dynamic>.from(value));
            if (seen.add(file.id)) result.add(file);
          } catch (_) {}
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
      return result;
    }

    void visit(dynamic value) {
      if (value is Map) {
        try {
          final file = CloudFile.fromJson(Map<String, dynamic>.from(value));
          if (seen.add(file.id)) result.add(file);
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

  Future<void> _saveLibraries(List<MediaLibraryDefinition> libraries) {
    return _store.saveLibraries(libraries);
  }

  Future<void> _saveAllItems(List<MediaLibraryItem> items) {
    return _store.replaceItems(items);
  }

  Future<void> _upsertItems(Iterable<MediaLibraryItem> items) {
    return _store.upsertItems(items);
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

final mediaLibraryProvider =
    StateNotifierProvider<MediaLibraryNotifier, MediaLibraryState>(
      (ref) => MediaLibraryNotifier(),
    );
