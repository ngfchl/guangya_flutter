import 'dart:async';
import 'dart:typed_data';

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
      searchQuery: searchQuery ?? this.searchQuery,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      statusMessage: clearStatus ? null : (statusMessage ?? this.statusMessage),
    );
  }
}

class MediaLibraryNotifier extends StateNotifier<MediaLibraryState> {
  GuangyaAPI? _api;
  final _store = MediaLibraryStore();
  final _posterRequests = <String, Future<Uint8List?>>{};
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
      state = state.copyWith(
        libraries: libraries,
        selectedLibraryID: selectedID,
        items: items,
      );
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> selectLibrary(String id) async {
    state = state.copyWith(
      selectedLibraryID: id,
      items: await _loadItems(id),
      searchQuery: '',
      clearError: true,
    );
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
      await _store.importBackup(backupPath);
      final libraries = await _loadLibraries();
      final selectedID = libraries.isEmpty ? null : libraries.first.id;
      state = state.copyWith(
        libraries: libraries,
        selectedLibraryID: selectedID,
        clearSelectedLibrary: selectedID == null,
        items: selectedID == null ? const [] : await _loadItems(selectedID),
        statusMessage: '刮削数据已导入',
      );
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

  Future<void> scanSelectedLibrary() async {
    final library = state.selectedLibrary;
    if (library == null || _api == null || state.isScanning) return;

    _cancelScan = false;
    state = state.copyWith(
      isScanning: true,
      progress: const MediaLibraryScanProgress(phase: '准备扫描'),
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
        final pending = files
            .where((file) => !unique.containsKey(file.id))
            .toList();
        if (pending.isEmpty || _cancelScan) return;
        var next = 0;
        Future<void> worker() async {
          while (!_cancelScan && next < pending.length) {
            final file = pending[next++];
            final fallback = MediaLibraryItem.fromFile(library.id, file);
            final item = await _recognizeMediaItem(
              fallback,
              tmdbApiKey,
              proxyHost: tmdbProxyHost,
              proxyPort: tmdbProxyPort,
            );
            unique[file.id] = item;
            completed += 1;
            final visible = unique.values.toList()
              ..sort(
                (a, b) =>
                    a.title.toLowerCase().compareTo(b.title.toLowerCase()),
              );
            pendingPersistence = pendingPersistence.then(
              (_) => _saveAllItems([...initialItems, ...unique.values]),
            );
            await pendingPersistence;
            state = state.copyWith(
              items: visible,
              progress: MediaLibraryScanProgress(
                phase: tmdbApiKey.isEmpty ? '正在建立本地索引' : '正在识别 ${file.name}',
                completed: completed,
              ),
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
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    } finally {
      state = state.copyWith(
        isScanning: false,
        progress: const MediaLibraryScanProgress(),
      );
    }
  }

  void cancelScan() {
    _cancelScan = true;
    state = state.copyWith(
      progress: const MediaLibraryScanProgress(phase: '正在停止扫描'),
    );
  }

  void setSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
  }

  Future<List<MediaLibraryItem>> searchAllItems(String query) async {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return const [];
    return (await _loadAllItems()).where((item) {
        return item.title.toLowerCase().contains(normalized) ||
            item.file.name.toLowerCase().contains(normalized) ||
            item.file.cloudPath.toLowerCase().contains(normalized);
      }).toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }

  Future<Uint8List?> posterBytes(MediaLibraryItem item) {
    final key = '${item.libraryID}:${item.file.id}';
    return _posterRequests.putIfAbsent(key, () async {
      final bytes = await _store.posterBytes(item.libraryID, item.file.id);
      if (_posterRequests.length > 48) {
        _posterRequests.remove(_posterRequests.keys.first);
      }
      return bytes;
    });
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
      final type = candidate['media_type']?.toString();
      final title = (candidate['title'] ?? candidate['name'])
          ?.toString()
          .trim();
      final originalTitle =
          (candidate['original_title'] ?? candidate['original_name'])
              ?.toString()
              .trim();
      final releaseDate =
          (candidate['release_date'] ?? candidate['first_air_date'])
              ?.toString() ??
          '';
      return MediaLibraryItem(
        libraryID: fallback.libraryID,
        file: fallback.file,
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
    } catch (_) {
      return fallback;
    }
  }

  int? _toInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '');
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
