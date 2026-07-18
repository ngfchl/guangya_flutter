import 'dart:async';

import 'package:flutter_riverpod/legacy.dart';

import '../api/guangya_api.dart';
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
  bool _loaded = false;
  bool _cancelScan = false;

  MediaLibraryNotifier() : super(const MediaLibraryState());

  set api(GuangyaAPI value) => _api = value;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final libraries = _loadLibraries();
      final selectedID = libraries.isEmpty ? null : libraries.first.id;
      final items = selectedID == null
          ? <MediaLibraryItem>[]
          : _loadItems(selectedID);
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
      items: _loadItems(id),
      searchQuery: '',
      clearError: true,
    );
  }

  Future<void> createLibrary({
    required String name,
    required String? rootID,
    required String rootPath,
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
      sources: [
        MediaLibrarySource(id: '$id-source-0', rootID: rootID, path: rootPath),
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
    final allItems = _loadAllItems()
      ..removeWhere((item) => item.libraryID == id);
    await _saveLibraries(libraries);
    await _saveAllItems(allItems);
    final selectedID = libraries.isEmpty ? null : libraries.first.id;
    state = state.copyWith(
      libraries: libraries,
      selectedLibraryID: selectedID,
      clearSelectedLibrary: selectedID == null,
      items: selectedID == null ? const [] : _loadItems(selectedID),
      statusMessage: '媒体库已删除',
    );
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
      final discovered = <CloudFile>[];
      for (final source in library.sources) {
        if (_cancelScan) break;
        state = state.copyWith(
          progress: MediaLibraryScanProgress(
            phase: '扫描 ${source.path}',
            completed: discovered.length,
          ),
        );
        final files = await _scanSource(
          source.rootID,
          source.path,
          recursive: library.recursive,
          minimumSizeBytes: library.minimumSizeMB * 1024 * 1024,
        );
        discovered.addAll(files);
      }

      final unique = <String, MediaLibraryItem>{};
      final tmdbApiKey =
          StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
      final tmdbProxyHost =
          StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '';
      final tmdbProxyPort =
          StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '';
      final input = <String, CloudFile>{
        for (final file in discovered) file.id: file,
      }.values.toList();
      var nextIndex = 0;
      var completed = 0;
      Future<void> pendingPersistence = Future.value();
      final initialItems = _loadAllItems()
        ..removeWhere((item) => item.libraryID == library.id);

      Future<void> worker() async {
        while (!_cancelScan) {
          if (nextIndex >= input.length) return;
          final file = input[nextIndex++];
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
              (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
            );
          // Serialize writes so an earlier, smaller snapshot cannot overwrite
          // a later batch while recognition workers finish out of order.
          pendingPersistence = pendingPersistence.then(
            (_) => _saveAllItems([...initialItems, ...unique.values]),
          );
          await pendingPersistence;
          state = state.copyWith(
            items: visible,
            progress: MediaLibraryScanProgress(
              phase: tmdbApiKey.isEmpty ? '正在建立本地索引' : '正在识别 ${file.name}',
              completed: completed,
              total: input.length,
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
    return _loadAllItems().where((item) {
        return item.title.toLowerCase().contains(normalized) ||
            item.file.name.toLowerCase().contains(normalized) ||
            item.file.cloudPath.toLowerCase().contains(normalized);
      }).toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
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

  Future<List<CloudFile>> _scanSource(
    String? rootID,
    String rootPath, {
    required bool recursive,
    required int minimumSizeBytes,
  }) async {
    final folders = <_ScanFolder>[_ScanFolder(rootID, rootPath)];
    final visited = <String>{};
    final mediaFiles = <CloudFile>[];

    while (folders.isNotEmpty && !_cancelScan) {
      final folder = folders.removeAt(0);
      final visitKey = folder.id ?? 'root';
      if (!visited.add(visitKey)) continue;

      var page = 0;
      while (!_cancelScan) {
        final response = await _api!.fsFiles(
          parentID: folder.id,
          page: page,
          pageSize: 200,
          orderBy: 0,
          sortType: 0,
        );
        final files = _extractFiles(response);
        for (final file in files) {
          if (file.isDirectory) {
            if (recursive) {
              folders.add(_ScanFolder(file.id, '${folder.path}/${file.name}'));
            }
          } else if (file.isVideo && (file.size ?? 0) >= minimumSizeBytes) {
            mediaFiles.add(_withPath(file, '${folder.path}/${file.name}'));
          }
        }

        state = state.copyWith(
          progress: MediaLibraryScanProgress(
            phase: '扫描 ${folder.path}',
            completed: mediaFiles.length,
            total: folders.length + visited.length,
          ),
        );

        if (files.length < 200) break;
        page += 1;
      }
    }
    return mediaFiles;
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
