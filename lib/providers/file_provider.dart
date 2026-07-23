import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api/guangya_api.dart';
import '../core/http/http_error.dart';
import '../core/logging/app_logger.dart';
import '../core/storage/file_metadata_cache.dart';
import '../core/storage/storage_manager.dart';
import '../core/utils/json_deep.dart';
import '../models/cloud_file.dart';
import '../models/fast_transfer.dart';

enum FileSort { name, size, modifiedAt, createdAt, type }

enum ExternalPlayerLaunchMode {
  macOSBundle,
  executable,
  androidPackage,
  urlScheme,
}

class ExternalPlayer {
  final String name;
  final String bundleID;
  final String? applicationPath;
  final ExternalPlayerLaunchMode launchMode;
  final String? urlScheme;

  const ExternalPlayer(
    this.name,
    this.bundleID, {
    this.applicationPath,
    this.launchMode = ExternalPlayerLaunchMode.macOSBundle,
    this.urlScheme,
  });

  ExternalPlayer withApplicationPath(String value) => ExternalPlayer(
    name,
    bundleID,
    applicationPath: value,
    launchMode: launchMode,
    urlScheme: urlScheme,
  );
}

Uri externalPlayerURL(ExternalPlayer player, Uri mediaURL) {
  final source = Uri.encodeComponent(mediaURL.toString());
  if (player.bundleID == 'nplayer') {
    return Uri.parse('nplayer-${mediaURL.toString()}');
  }
  return switch (player.urlScheme) {
    'vlc-x-callback' => Uri.parse(
      'vlc-x-callback://x-callback-url/stream?url=$source',
    ),
    'infuse' => Uri.parse('infuse://x-callback-url/play?url=$source'),
    final scheme when scheme != null => Uri.parse('$scheme://play?url=$source'),
    _ => mediaURL,
  };
}

String? preferredExternalPlayerApplicationPath(
  Iterable<String> candidates, {
  required String currentExecutable,
}) {
  final appMarker = '.app/Contents/MacOS/';
  final markerIndex = currentExecutable.indexOf(appMarker);
  final currentAppPath = markerIndex < 0
      ? null
      : currentExecutable.substring(0, markerIndex + 4);
  final paths = candidates
      .map((path) => path.trim())
      .where((path) => path.endsWith('.app'))
      .where(
        (path) =>
            currentAppPath == null ||
            !path.startsWith('$currentAppPath/Contents/'),
      )
      .toList(growable: false);
  if (paths.isEmpty) return null;
  return paths.firstWhere(
    (path) => path.startsWith('/Applications/'),
    orElse: () => paths.first,
  );
}

String? firstExistingExecutablePath(
  Iterable<String?> candidates,
  bool Function(String path) exists,
) {
  for (final candidate in candidates) {
    if (candidate != null && candidate.isNotEmpty && exists(candidate)) {
      return candidate;
    }
  }
  return null;
}

class _FastTransferSource {
  final CloudFile file;
  final String path;

  const _FastTransferSource(this.file, this.path);
}

extension FileSortExt on FileSort {
  String get title {
    switch (this) {
      case FileSort.name:
        return '名称';
      case FileSort.size:
        return '大小';
      case FileSort.modifiedAt:
        return '修改时间';
      case FileSort.createdAt:
        return '创建时间';
      case FileSort.type:
        return '类型';
    }
  }

  int get apiOrderBy {
    switch (this) {
      case FileSort.name:
        return 0;
      case FileSort.size:
        return 1;
      case FileSort.createdAt:
        return 2;
      case FileSort.modifiedAt:
        return 3;
      case FileSort.type:
        return 4;
    }
  }
}

enum SortDirection { ascending, descending }

class UploadProgress {
  final int totalFiles;
  final int completedFiles;
  final int failedFiles;
  final int totalBytes;
  final int transferredBytes;
  final String currentFileName;
  final bool isActive;

  const UploadProgress({
    required this.totalFiles,
    required this.completedFiles,
    required this.failedFiles,
    required this.totalBytes,
    required this.transferredBytes,
    required this.currentFileName,
    required this.isActive,
  });

  int get processedFiles => completedFiles + failedFiles;

  double get fraction {
    if (totalBytes > 0) {
      return (transferredBytes / totalBytes).clamp(0.0, 1.0);
    }
    if (totalFiles == 0) return 0;
    return (processedFiles / totalFiles).clamp(0.0, 1.0);
  }
}

enum WorkspaceSection {
  files('全部', 'folder'),
  recentViewed('最近查看', 'clock'),
  recentRestored('最近转存', 'history'),
  photos('图片', 'image'),
  videos('视频', 'movie'),
  audio('音频', 'music_note'),
  documents('文档', 'description'),
  cloud('云下载', 'cloud_download'),
  shares('我的分享', 'share'),
  recycle('回收站', 'delete'),
  mediaLibrary('光鸭影视', 'movie_filter');

  final String label;
  final String icon;
  const WorkspaceSection(this.label, this.icon);
}

class FileState {
  final WorkspaceSection section;
  final List<CloudFile> files;
  final List<CloudFile> folderPath;
  final bool isLoading;
  final int currentPage;
  final int pageSize;
  final int totalPages;
  final FileSort serverSort;
  final SortDirection serverSortDirection;
  final String currentListSearchQuery;
  final String? errorMessage;
  final String? statusMessage;
  final Set<String> selectedIDs;
  final List<CloudFile>? clipboard;
  final bool clipboardIsMove;
  final UploadProgress? uploadProgress;

  const FileState({
    this.section = WorkspaceSection.files,
    this.files = const [],
    this.folderPath = const [],
    this.isLoading = false,
    this.currentPage = 0,
    this.pageSize = 50,
    this.totalPages = 1,
    this.serverSort = FileSort.name,
    this.serverSortDirection = SortDirection.ascending,
    this.currentListSearchQuery = '',
    this.errorMessage,
    this.statusMessage,
    this.selectedIDs = const {},
    this.clipboard,
    this.clipboardIsMove = false,
    this.uploadProgress,
  });

  bool get hasSelection => selectedIDs.isNotEmpty;
  int get selectedCount => selectedIDs.length;

  FileState copyWith({
    WorkspaceSection? section,
    List<CloudFile>? files,
    List<CloudFile>? folderPath,
    bool? isLoading,
    int? currentPage,
    int? pageSize,
    int? totalPages,
    FileSort? serverSort,
    SortDirection? serverSortDirection,
    String? currentListSearchQuery,
    String? errorMessage,
    bool clearError = false,
    String? statusMessage,
    bool clearStatus = false,
    Set<String>? selectedIDs,
    List<CloudFile>? clipboard,
    bool clearClipboard = false,
    bool? clipboardIsMove,
    UploadProgress? uploadProgress,
    bool clearUploadProgress = false,
  }) {
    return FileState(
      section: section ?? this.section,
      files: files ?? this.files,
      folderPath: folderPath ?? this.folderPath,
      isLoading: isLoading ?? this.isLoading,
      currentPage: currentPage ?? this.currentPage,
      pageSize: pageSize ?? this.pageSize,
      totalPages: totalPages ?? this.totalPages,
      serverSort: serverSort ?? this.serverSort,
      serverSortDirection: serverSortDirection ?? this.serverSortDirection,
      currentListSearchQuery:
          currentListSearchQuery ?? this.currentListSearchQuery,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      statusMessage: clearStatus ? null : (statusMessage ?? this.statusMessage),
      selectedIDs: selectedIDs ?? this.selectedIDs,
      clipboard: clearClipboard ? null : (clipboard ?? this.clipboard),
      clipboardIsMove: clipboardIsMove ?? this.clipboardIsMove,
      uploadProgress: clearUploadProgress
          ? null
          : (uploadProgress ?? this.uploadProgress),
    );
  }
}

class FileNotifier extends StateNotifier<FileState> {
  GuangyaAPI? _api;
  var _detailGeneration = 0;
  String? _selectionAnchorID;

  FileNotifier() : super(const FileState());

  bool _sameParentID(String? left, String? right) {
    final normalizedLeft = left?.trim();
    final normalizedRight = right?.trim();
    final effectiveLeft = normalizedLeft == null || normalizedLeft.isEmpty
        ? null
        : normalizedLeft;
    final effectiveRight = normalizedRight == null || normalizedRight.isEmpty
        ? null
        : normalizedRight;
    return effectiveLeft == effectiveRight;
  }

  set api(GuangyaAPI value) => _api = value;

  String? get _currentParentID =>
      state.folderPath.isNotEmpty ? state.folderPath.last.id : null;

  void setSection(WorkspaceSection section) {
    final preservePath = section == WorkspaceSection.mediaLibrary;
    state = state.copyWith(
      section: section,
      files: [],
      folderPath: preservePath ? state.folderPath : [],
      currentPage: 0,
      selectedIDs: {},
      currentListSearchQuery: '',
    );
    loadFiles();
  }

  /// Filters only the file page currently held in memory. This is deliberately
  /// separate from global cloud search and never sends another API request.
  void setCurrentListSearchQuery(String query) {
    final normalized = query.trim();
    if (normalized == state.currentListSearchQuery) return;
    state = state.copyWith(currentListSearchQuery: normalized, selectedIDs: {});
  }

  Future<void> loadFiles({String? parentID, bool forceRefresh = false}) async {
    if (_api == null) return;
    final generation = ++_detailGeneration;
    final resolvedParentID = parentID ?? _currentParentID;
    final cacheKey =
        'v3|${state.section.name}|${resolvedParentID ?? 'root'}|${state.currentPage}|${state.pageSize}|${state.serverSort.name}|${state.serverSortDirection.name}';
    if (!forceRefresh) {
      final cached = _readCachedFiles(cacheKey);
      if (cached != null) {
        state = state.copyWith(files: cached, clearError: true);
        if (state.section == WorkspaceSection.shares) {
          unawaited(_enrichShareSizes(cached, generation));
        } else {
          unawaited(_enrichFolderSizes(cached, generation));
        }
        return;
      }
    }
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final result = await _fetchFiles(resolvedParentID);
      final extracted = _sortFiles(_extractFiles(result));
      final totalPages = _extractTotalPages(result, extracted.length);
      state = state.copyWith(files: extracted, totalPages: totalPages);
      await _writeCachedFiles(cacheKey, extracted);
      await FileMetadataCache.cacheFolderChildren(resolvedParentID, extracted);
      if (state.section == WorkspaceSection.shares) {
        unawaited(_enrichShareSizes(extracted, generation));
      } else {
        unawaited(_enrichFolderSizes(extracted, generation));
      }
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  List<CloudFile>? _readCachedFiles(String key) {
    final raw = StorageManager.get<dynamic>(StorageKeys.fileListCache);
    if (raw is! Map || raw[key] is! Map) return null;
    final entry = Map<dynamic, dynamic>.from(raw[key] as Map);
    final cachedAt = int.tryParse(entry['cachedAt']?.toString() ?? '');
    final files = entry['files'];
    final ttlMinutes =
        int.tryParse(
          StorageManager.get<String>(StorageKeys.fileCacheTTLMinutes) ?? '3',
        ) ??
        3;
    if (cachedAt == null ||
        files is! List ||
        DateTime.now().millisecondsSinceEpoch - cachedAt >
            Duration(minutes: ttlMinutes.clamp(0, 60)).inMilliseconds) {
      return null;
    }
    try {
      return files
          .whereType<Map>()
          .map((value) => CloudFile.fromJson(Map<String, dynamic>.from(value)))
          .toList();
    } catch (_) {
      AppLogger.debug('Storage', '文件列表缓存解析失败，key=$key');
      return null;
    }
  }

  Future<void> _writeCachedFiles(String key, List<CloudFile> files) async {
    final raw = StorageManager.get<dynamic>(StorageKeys.fileListCache);
    final cache = raw is Map
        ? Map<dynamic, dynamic>.from(raw)
        : <dynamic, dynamic>{};
    cache[key] = {
      'cachedAt': DateTime.now().millisecondsSinceEpoch,
      'files': files.map((file) => file.toJson()).toList(),
    };
    if (cache.length > 80) cache.remove(cache.keys.first);
    await StorageManager.set(StorageKeys.fileListCache, cache);
  }

  Future<void> _enrichFolderSizes(List<CloudFile> files, int generation) async {
    if (_api == null || files.isEmpty) return;
    final cache = _readMetadataCache();
    final now = DateTime.now().millisecondsSinceEpoch;
    final ttl = Duration(
      minutes:
          (int.tryParse(
                    StorageManager.get<String>(
                          StorageKeys.fileCacheTTLMinutes,
                        ) ??
                        '3',
                  ) ??
                  3)
              .clamp(1, 60),
    ).inMilliseconds;
    final pending = <CloudFile>[];
    final known = <String, int>{};
    for (final file in files.where((file) => file.isDirectory)) {
      final entry = cache[file.id];
      final cachedAt = int.tryParse(entry?['cachedAt']?.toString() ?? '');
      final cachedSize = int.tryParse(entry?['size']?.toString() ?? '');
      if (cachedAt != null &&
          cachedSize != null &&
          cachedSize > 0 &&
          now - cachedAt <= ttl) {
        known[file.id] = cachedSize;
      } else {
        pending.add(file);
      }
    }

    void apply(Map<String, int> sizes) {
      if (generation != _detailGeneration || sizes.isEmpty) return;
      final updated = state.files
          .map(
            (file) => sizes.containsKey(file.id)
                ? file.copyWith(size: sizes[file.id])
                : file,
          )
          .toList();
      state = state.copyWith(files: updated);
    }

    apply(known);
    if (pending.isEmpty) return;

    final queue = List<CloudFile>.from(pending);
    const concurrency = 6;
    final resolved = <String, int>{};
    await Future.wait(
      List.generate(concurrency, (_) async {
        while (queue.isNotEmpty) {
          final file = queue.removeLast();
          try {
            final detail = await _api!.fsDetail(file.id);
            final detailFile = _extractFiles(detail)
                .cast<CloudFile?>()
                .firstWhere(
                  (candidate) => candidate?.id == file.id,
                  orElse: () => null,
                );
            final size =
                JsonDeep.findInt(detail, const [
                  'size',
                  'fileSize',
                  'resSize',
                  'totalSize',
                  'dirSize',
                  'folderSize',
                ]) ??
                detailFile?.size;
            if (size == null) continue;
            cache[file.id] = {'size': size, 'cachedAt': now};
            resolved[file.id] = size;
            apply({file.id: size});
          } catch (e) {
            AppLogger.debug(
              'Storage',
              '文件夹 size enrichment 失败：fileId=${file.id}，$e',
            );
          }
        }
      }),
    );
    if (resolved.isNotEmpty) {
      await StorageManager.set(StorageKeys.fileMetadataCache, cache);
    }
  }

  /// Enrich share records with recursive total size.
  Future<void> _enrichShareSizes(List<CloudFile> shares, int generation) async {
    if (_api == null || shares.isEmpty) return;
    final spCache = _readMetadataCache();
    final now = DateTime.now().millisecondsSinceEpoch;
    final ttl = Duration(
      minutes:
          (int.tryParse(
                    StorageManager.get<String>(
                          StorageKeys.fileCacheTTLMinutes,
                        ) ??
                        '3',
                  ) ??
                  3)
              .clamp(1, 60),
    ).inMilliseconds;

    void apply(Map<String, int> sizes) {
      if (generation != _detailGeneration || sizes.isEmpty) return;
      final updated = state.files
          .map(
            (file) => sizes.containsKey(file.id)
                ? file.copyWith(size: sizes[file.id])
                : file,
          )
          .toList();
      state = state.copyWith(files: updated);
    }

    final known = <String, int>{};
    final pending = <CloudFile>[];
    for (final share in shares) {
      final entry = spCache['share_${share.id}'];
      final cachedAt = int.tryParse(entry?['cachedAt']?.toString() ?? '');
      final cachedSize = int.tryParse(entry?['size']?.toString() ?? '');
      if (cachedAt != null &&
          cachedSize != null &&
          cachedSize >= 0 &&
          now - cachedAt <= ttl) {
        known[share.id] = cachedSize;
        continue;
      }
      pending.add(share);
    }

    apply(known);
    if (pending.isEmpty) return;

    final queue = List<CloudFile>.from(pending);
    const concurrency = 4;
    final resolved = <String, int>{};
    await Future.wait(
      List.generate(concurrency, (_) async {
        while (queue.isNotEmpty) {
          final share = queue.removeLast();
          try {
            final size = await _loadShareSize(share);
            if (size == null) continue;
            spCache['share_${share.id}'] = {'size': size, 'cachedAt': now};
            resolved[share.id] = size;
            apply({share.id: size});
          } catch (e) {
            AppLogger.debug(
              'Storage',
              '分享 size enrichment 失败：id=${share.id}，shareId=${share.shareID}，$e',
            );
          }
        }
      }),
    );
    if (resolved.isNotEmpty || known.isNotEmpty) {
      await StorageManager.set(StorageKeys.fileMetadataCache, spCache);
    }
  }

  Future<int?> _loadShareSize(CloudFile share) async {
    final shareID = share.shareID?.trim();
    if (shareID == null || shareID.isEmpty) return null;
    final accessResponse = await _api!.shareAccessToken(
      shareID,
      share.shareCode?.trim() ?? '',
    );
    final accessToken = JsonDeep.findString(accessResponse, const [
      'accessToken',
      'access_token',
    ]);
    if (accessToken == null) return null;

    final rootEntries = await _loadShareEntries(accessToken, parentID: '');
    if (rootEntries.isEmpty) return 0;
    final sizeTargetIDs = <String>[];
    for (final entry in rootEntries) {
      final id = _shareEntryID(entry);
      if (id == null) continue;
      if (!_shareEntryIsDirectory(entry)) {
        sizeTargetIDs.add(id);
        continue;
      }
      final children = await _loadShareEntries(accessToken, parentID: id);
      final childIDs = children.map(_shareEntryID).whereType<String>().toList();
      sizeTargetIDs.addAll(childIDs.isEmpty ? [id] : childIDs);
    }
    if (sizeTargetIDs.isEmpty) return 0;
    try {
      final response = await _api!.shareFilesSize(
        accessToken,
        sizeTargetIDs,
        download: false,
      );
      return JsonDeep.findInt(response, const ['totalSize', 'total_size']);
    } on ApiException catch (error) {
      if (error.status == 216) return 0;
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> _loadShareEntries(
    String accessToken, {
    required String parentID,
  }) async {
    const pageSize = 500;
    final result = <Map<String, dynamic>>[];
    for (var page = 1; ; page += 1) {
      final response = await _api!.shareFilesList(
        accessToken,
        parentID: parentID,
        page: page,
        pageSize: pageSize,
      );
      final values = JsonDeep.findArray(response, const [
        'list',
        'files',
        'items',
      ]);
      final pageEntries =
          values
              ?.whereType<Map>()
              .map((value) => Map<String, dynamic>.from(value))
              .toList() ??
          const <Map<String, dynamic>>[];
      result.addAll(pageEntries);
      final total = JsonDeep.findInt(response, const ['total', 'totalCount']);
      if (pageEntries.isEmpty ||
          (total != null
              ? result.length >= total
              : pageEntries.length < pageSize)) {
        break;
      }
    }
    return result;
  }

  String? _shareEntryID(Map<String, dynamic> entry) =>
      JsonDeep.findString(entry, const ['fileId', 'file_id', 'id']);

  bool _shareEntryIsDirectory(Map<String, dynamic> entry) {
    final resType = JsonDeep.findInt(entry, const ['resType', 'res_type']);
    if (resType != null) return resType == 2;
    final dirType = JsonDeep.findInt(entry, const ['dirType', 'dir_type']);
    return dirType == 1;
  }

  Map<String, Map<String, dynamic>> _readMetadataCache() {
    final raw = StorageManager.get<dynamic>(StorageKeys.fileMetadataCache);
    if (raw is! Map) return <String, Map<String, dynamic>>{};
    return raw.map(
      (key, value) => MapEntry(
        key.toString(),
        value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{},
      ),
    );
  }

  Future<Map<String, dynamic>> _fetchFiles(String? parentID) async {
    switch (state.section) {
      case WorkspaceSection.files:
        return await _api!.fsFiles(
          parentID: parentID,
          page: state.currentPage,
          pageSize: state.pageSize,
          orderBy: state.serverSort.apiOrderBy,
          sortType: state.serverSortDirection == SortDirection.ascending
              ? 0
              : 1,
        );
      case WorkspaceSection.recentViewed:
        return await _api!.recentViewed(pageSize: 100);
      case WorkspaceSection.recentRestored:
        return await _api!.recentRestored(pageSize: 100);
      case WorkspaceSection.photos:
        return await _api!.fsFiles(
          parentID: '*',
          orderBy: 3,
          sortType: 1,
          fileTypes: [1],
          resType: 1,
        );
      case WorkspaceSection.videos:
        return await _api!.fsFiles(
          parentID: '*',
          orderBy: 3,
          sortType: 1,
          fileTypes: [2],
          resType: 1,
        );
      case WorkspaceSection.audio:
        return await _api!.fsFiles(
          parentID: '*',
          orderBy: 3,
          sortType: 1,
          fileTypes: [3],
          resType: 1,
          needPlayRecord: true,
        );
      case WorkspaceSection.documents:
        return await _api!.fsFiles(
          parentID: '*',
          orderBy: 3,
          sortType: 1,
          fileTypes: [4],
          resType: 1,
        );
      case WorkspaceSection.cloud:
        return await _api!.cloudTaskList();
      case WorkspaceSection.shares:
        return await _api!.shareUserList(
          page: state.currentPage,
          pageSize: state.pageSize,
        );
      case WorkspaceSection.recycle:
        return await _api!.fsFiles(orderBy: 10, dirType: 4);
      case WorkspaceSection.mediaLibrary:
        return {
          'code': 0,
          'data': {'list': <dynamic>[], 'total': 0},
        };
    }
  }

  Future<void> navigateToFolder(CloudFile folder) async {
    final newPath = [...state.folderPath, folder];
    state = state.copyWith(
      folderPath: newPath,
      currentPage: 0,
      selectedIDs: {},
      currentListSearchQuery: '',
    );
    await loadFiles(parentID: folder.id);
  }

  /// Opens the location returned by a global search. Search results are not
  /// necessarily below the currently visible directory, so appending their
  /// folder to [state.folderPath] would produce a misleading breadcrumb.
  /// Instead replace the visible location with the matched folder itself.
  Future<void> navigateToSearchResult(CloudFile result) async {
    final folderID = result.isDirectory ? result.id : result.parentID;
    if (folderID == null || folderID.isEmpty) {
      state = state.copyWith(
        folderPath: const [],
        currentPage: 0,
        selectedIDs: {},
        currentListSearchQuery: '',
      );
      await loadFiles(parentID: null);
      return;
    }

    final folder = result.isDirectory
        ? result
        : CloudFile(
            id: folderID,
            name: _searchResultParentName(result),
            isDirectory: true,
            cloudPath: _searchResultParentPath(result.cloudPath),
          );
    state = state.copyWith(
      folderPath: [folder],
      currentPage: 0,
      selectedIDs: {},
      currentListSearchQuery: '',
    );
    await loadFiles(parentID: folderID);
  }

  String _searchResultParentName(CloudFile file) {
    final parts = file.cloudPath
        .split(RegExp(r'[/\\]+'))
        .where((part) => part.trim().isNotEmpty)
        .toList();
    return parts.length >= 2 ? parts[parts.length - 2] : '所在文件夹';
  }

  String _searchResultParentPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index > 0 ? normalized.substring(0, index) : '';
  }

  Future<void> navigateBack() async {
    if (state.folderPath.isEmpty) return;
    final newPath = List<CloudFile>.from(state.folderPath)..removeLast();
    state = state.copyWith(
      folderPath: newPath,
      currentPage: 0,
      selectedIDs: {},
      currentListSearchQuery: '',
    );
    final parentID = newPath.isNotEmpty ? newPath.last.id : null;
    await loadFiles(parentID: parentID);
  }

  void navigateToPathIndex(int index) {
    if (index < 0) {
      state = state.copyWith(
        folderPath: const [],
        currentPage: 0,
        selectedIDs: {},
        currentListSearchQuery: '',
      );
      loadFiles(parentID: null);
      return;
    }
    if (index >= state.folderPath.length) return;
    final newPath = state.folderPath.sublist(0, index + 1);
    state = state.copyWith(
      folderPath: newPath,
      currentPage: 0,
      selectedIDs: {},
      currentListSearchQuery: '',
    );
    final parentID = index >= 0 ? newPath[index].id : null;
    loadFiles(parentID: parentID);
  }

  Future<void> navigateToFolderPath(List<CloudFile> path) async {
    final newPath = List<CloudFile>.unmodifiable(path);
    state = state.copyWith(
      folderPath: newPath,
      currentPage: 0,
      selectedIDs: {},
    );
    await loadFiles(parentID: newPath.isEmpty ? null : newPath.last.id);
  }

  void toggleSelection(String id) {
    final newSelected = Set<String>.from(state.selectedIDs);
    if (newSelected.contains(id)) {
      newSelected.remove(id);
    } else {
      newSelected.add(id);
    }
    state = state.copyWith(selectedIDs: newSelected);
  }

  void selectWithModifiers(
    String id, {
    required bool command,
    required bool shift,
  }) {
    final index = state.files.indexWhere((file) => file.id == id);
    if (index < 0) return;
    final selected = Set<String>.from(state.selectedIDs);
    if (shift && _selectionAnchorID != null) {
      final anchor = state.files.indexWhere(
        (file) => file.id == _selectionAnchorID,
      );
      if (anchor >= 0) {
        final start = anchor < index ? anchor : index;
        final end = anchor > index ? anchor : index;
        final range = state.files
            .sublist(start, end + 1)
            .map((file) => file.id);
        if (command) {
          selected.addAll(range);
        } else {
          selected
            ..clear()
            ..addAll(range);
        }
      }
    } else if (command) {
      selected.contains(id) ? selected.remove(id) : selected.add(id);
      _selectionAnchorID = id;
    } else {
      selected
        ..clear()
        ..add(id);
      _selectionAnchorID = id;
    }
    state = state.copyWith(selectedIDs: selected);
  }

  void selectAll() {
    state = state.copyWith(selectedIDs: state.files.map((f) => f.id).toSet());
  }

  void clearSelection() {
    state = state.copyWith(selectedIDs: {});
  }

  /// Replaces the active desktop selection, used by Finder-style marquee drag.
  void setSelection(Set<String> ids) {
    state = state.copyWith(selectedIDs: Set<String>.from(ids));
  }

  void setSort(FileSort sort) {
    SortDirection direction;
    if (state.serverSort == sort) {
      direction = state.serverSortDirection == SortDirection.ascending
          ? SortDirection.descending
          : SortDirection.ascending;
    } else {
      direction = SortDirection.ascending;
    }
    state = state.copyWith(
      serverSort: sort,
      serverSortDirection: direction,
      currentPage: 0,
    );
    loadFiles(parentID: _currentParentID);
  }

  void toggleSortDirection() {
    final direction = state.serverSortDirection == SortDirection.ascending
        ? SortDirection.descending
        : SortDirection.ascending;
    state = state.copyWith(serverSortDirection: direction, currentPage: 0);
    loadFiles(parentID: _currentParentID);
  }

  List<CloudFile> _sortFiles(List<CloudFile> files) {
    final sorted = List<CloudFile>.from(files);
    int compare(CloudFile a, CloudFile b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      final value = switch (state.serverSort) {
        FileSort.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        FileSort.size => (a.size ?? 0).compareTo(b.size ?? 0),
        FileSort.modifiedAt ||
        FileSort.createdAt => a.modifiedAt.compareTo(b.modifiedAt),
        FileSort.type => a.typeName.compareTo(b.typeName),
      };
      if (value != 0) {
        return state.serverSortDirection == SortDirection.ascending
            ? value
            : -value;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    }

    sorted.sort(compare);
    return sorted;
  }

  void nextPage() {
    if (state.currentPage < state.totalPages - 1) {
      state = state.copyWith(currentPage: state.currentPage + 1);
      loadFiles(parentID: _currentParentID);
    }
  }

  void prevPage() {
    if (state.currentPage > 0) {
      state = state.copyWith(currentPage: state.currentPage - 1);
      loadFiles(parentID: _currentParentID);
    }
  }

  void setPageSize(int size) {
    state = state.copyWith(pageSize: size, currentPage: 0);
    loadFiles(parentID: _currentParentID);
  }

  // ── File operations ─────────────────────────────────────────────

  Future<void> createFolder(String name) async {
    if (_api == null) return;
    state = state.copyWith(statusMessage: '正在创建文件夹…');
    try {
      await _api!.fsCreateDir(name, parentID: _currentParentID);
      state = state.copyWith(statusMessage: '文件夹已创建');
      await _invalidateFolderCaches(_currentParentID);
      await loadFiles(parentID: _currentParentID);
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString(), clearStatus: true);
    }
  }

  Future<bool> renameFile(CloudFile file, String newName) async {
    if (_api == null) return false;
    try {
      await _api!.fsRename(file.id, newName);
      final renamed = file.copyWith(name: newName);
      state = state.copyWith(statusMessage: '重命名成功');
      await FileMetadataCache.updateFolderChildren(
        _currentParentID,
        addOrReplace: [renamed],
      );
      await FileMetadataCache.cacheFiles([renamed]);
      await _invalidateListCache(_currentParentID);
      await loadFiles(parentID: _currentParentID);
      return true;
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
      return false;
    }
  }

  Future<bool> deleteFiles(List<CloudFile> files) async {
    if (_api == null || files.isEmpty) return false;
    final deletingShares = state.section == WorkspaceSection.shares;
    state = state.copyWith(statusMessage: deletingShares ? '正在删除分享…' : '正在删除…');
    try {
      final ids = files.map((file) => file.id).toList();
      if (deletingShares) {
        await _api!.shareDelete(ids);
      } else {
        await _api!.fsDelete(ids);
        await FileMetadataCache.removeFilesFromAllFolders(ids);
        await FileMetadataCache.updateFolderChildren(
          _currentParentID,
          removeIDs: ids,
        );
      }
      await _invalidateListCache(_currentParentID);
      state = state.copyWith(
        files: deletingShares
            ? state.files.where((file) => !ids.contains(file.id)).toList()
            : state.files,
        statusMessage: deletingShares
            ? '已删除 ${files.length} 条分享'
            : '已删除 ${files.length} 个项目',
        selectedIDs: {},
      );
      await loadFiles(parentID: _currentParentID, forceRefresh: true);
      return true;
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
      return false;
    }
  }

  Future<void> recycleFiles(List<CloudFile> files) async {
    if (_api == null) return;
    try {
      await _api!.fsRecycle(files.map((f) => f.id).toList());
      await FileMetadataCache.removeFilesFromAllFolders(
        files.map((file) => file.id),
      );
      await FileMetadataCache.updateFolderChildren(
        _currentParentID,
        removeIDs: files.map((file) => file.id),
      );
      await _invalidateListCache(_currentParentID);
      state = state.copyWith(statusMessage: '已移入回收站', selectedIDs: {});
      await loadFiles(parentID: _currentParentID);
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  Future<void> clearRecycleBin() async {
    if (_api == null) return;
    try {
      await _api!.fsClearRecycleBin();
      await _invalidateFolderCaches(_currentParentID);
      state = state.copyWith(statusMessage: '回收站已清空');
      await loadFiles();
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  void copyToClipboard(List<CloudFile> files) {
    state = state.copyWith(clipboard: files, clipboardIsMove: false);
  }

  void cutToClipboard(List<CloudFile> files) {
    state = state.copyWith(clipboard: files, clipboardIsMove: true);
  }

  Future<void> pasteFromClipboard() async {
    await pasteFromClipboardTo(_currentParentID);
  }

  /// Pastes into an explicit panel destination. The secondary file pane uses
  /// this rather than the notifier's primary-path destination.
  Future<void> pasteFromClipboardTo(String? parentID) async {
    if (_api == null || state.clipboard == null || state.clipboard!.isEmpty) {
      return;
    }
    final clipboard = state.clipboard!;
    if (state.clipboardIsMove) {
      final movable = clipboard
          .where((file) => !_sameParentID(file.parentID, parentID))
          .toList(growable: false);
      if (movable.isEmpty) {
        state = state.copyWith(statusMessage: '不能移动至相同目录', clearError: true);
        return;
      }
      if (movable.length != clipboard.length) {
        state = state.copyWith(
          statusMessage: '已跳过 ${clipboard.length - movable.length} 个同目录项目',
          clearError: true,
        );
      }
    }
    state = state.copyWith(
      statusMessage: state.clipboardIsMove ? '正在移动…' : '正在复制…',
    );
    try {
      final moveFiles = state.clipboardIsMove
          ? clipboard
                .where((file) => !_sameParentID(file.parentID, parentID))
                .toList(growable: false)
          : clipboard;
      final ids = moveFiles.map((f) => f.id).toList();
      if (state.clipboardIsMove) {
        await _api!.fsMove(ids, parentID: parentID);
        await FileMetadataCache.removeFilesFromAllFolders(ids);
        await FileMetadataCache.updateFolderChildren(
          parentID,
          addOrReplace: moveFiles,
        );
      } else {
        await _api!.fsCopy(ids, parentID: parentID);
        await FileMetadataCache.updateFolderChildren(
          parentID,
          invalidate: true,
        );
      }
      await _invalidateListCache(parentID);
      state = state.copyWith(statusMessage: '操作完成');
      if (parentID == _currentParentID) {
        await loadFiles(parentID: _currentParentID);
      }
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  Future<void> copyFilesTo(List<CloudFile> files, {String? parentID}) async {
    if (_api == null || files.isEmpty) return;
    state = state.copyWith(statusMessage: '正在复制 ${files.length} 个项目…');
    try {
      await _api!.fsCopy(
        files.map((file) => file.id).toList(),
        parentID: parentID,
      );
      await FileMetadataCache.updateFolderChildren(parentID, invalidate: true);
      await _invalidateListCache(parentID);
      state = state.copyWith(statusMessage: '复制完成');
      await loadFiles(parentID: _currentParentID);
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  void clearClipboard() {
    state = state.copyWith(clearClipboard: true);
  }

  Future<void> copyFastTransferJSON(CloudFile target) async {
    if (_api == null) return;
    state = state.copyWith(statusMessage: '正在生成秒传信息…', clearError: true);
    try {
      final sources = target.isDirectory
          ? await _collectFastTransferFolder(target)
          : [_FastTransferSource(target, target.name)];
      if (sources.isEmpty) {
        throw Exception('该目录中没有可生成秒传信息的文件');
      }
      final entries = <FastTransferEntry>[];
      var skipped = 0;
      var next = 0;
      Future<void> worker() async {
        while (next < sources.length) {
          final source = sources[next++];
          final file = await _resolveFastTransferFile(source.file);
          final gcid = file.gcid?.trim();
          final size = file.size;
          if (gcid == null || gcid.isEmpty || size == null || size < 0) {
            skipped += 1;
            continue;
          }
          entries.add(
            FastTransferEntry.create(path: source.path, size: size, gcid: gcid),
          );
        }
      }

      await Future.wait(List.generate(6, (_) => worker()));
      if (entries.isEmpty) {
        throw Exception('没有找到包含 GCID 和大小的有效文件');
      }
      entries.sort((a, b) => a.path.compareTo(b.path));
      await Clipboard.setData(
        ClipboardData(
          text: jsonEncode({
            'files': entries
                .map((entry) => {
                      'path': entry.path,
                      'size': entry.size,
                      'gcid': entry.gcid,
                    })
                .toList(),
          }),
        ),
      );
      state = state.copyWith(
        statusMessage: skipped == 0
            ? '已复制 ${entries.length} 个文件的秒传 JSON'
            : '已复制 ${entries.length} 个文件的秒传 JSON，跳过 $skipped 个无 GCID 项目',
      );
    } catch (error) {
      state = state.copyWith(errorMessage: '复制秒传失败：$error');
    }
  }

  Future<List<_FastTransferSource>> _collectFastTransferFolder(
    CloudFile folder,
  ) async {
    final queue = <_FastTransferSource>[
      _FastTransferSource(folder, folder.name),
    ];
    final result = <_FastTransferSource>[];
    final visited = <String>{};
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      if (!visited.add(current.file.id)) continue;
      final children = await _folderChildrenForFastTransfer(current.file);
      for (final child in children) {
        final path = '${current.path}/${child.name}';
        if (child.isDirectory) {
          queue.add(_FastTransferSource(child, path));
        } else {
          result.add(_FastTransferSource(child, path));
        }
      }
    }
    return result;
  }

  Future<List<CloudFile>> _folderChildrenForFastTransfer(
    CloudFile folder,
  ) async {
    final cached = await FileMetadataCache.folderChildren(folder.id);
    if (cached != null) return cached;
    final children = <CloudFile>[];
    var page = 0;
    while (true) {
      final response = await _api!.fsFiles(
        parentID: folder.id,
        page: page,
        pageSize: 200,
        orderBy: 0,
        sortType: 0,
      );
      final values = _extractFiles(response);
      children.addAll(values);
      if (values.length < 200) break;
      page += 1;
    }
    await FileMetadataCache.cacheFolderChildren(folder.id, children);
    return children;
  }

  Future<CloudFile> _resolveFastTransferFile(CloudFile file) async {
    final cached = await FileMetadataCache.file(file.id);
    var resolved = cached == null
        ? file
        : file.copyWith(size: cached.size, gcid: cached.gcid);
    if (resolved.gcid?.isNotEmpty == true && resolved.size != null) {
      return resolved;
    }
    final detail = await _api!.fsDetail(file.id);
    final detailFile = _extractFiles(detail).cast<CloudFile?>().firstWhere(
      (candidate) => candidate?.id == file.id,
      orElse: () => null,
    );
    resolved = resolved.copyWith(
      gcid:
          detailFile?.gcid ??
          JsonDeep.findString(detail, const [
            'gcid',
            'gcId',
            'gcidValue',
            'hash',
          ]),
      size:
          detailFile?.size ??
          JsonDeep.findInt(detail, const [
            'size',
            'fileSize',
            'resSize',
            'totalSize',
          ]),
    );
    await FileMetadataCache.cacheFiles([resolved]);
    return resolved;
  }

  Future<void> downloadFile(CloudFile file) async {
    await _openRemoteFile(
      file,
      preparingMessage: '正在准备下载…',
      completedMessage: '下载链接已交给系统处理',
    );
  }

  Future<void> playFile(CloudFile file) async {
    if (file.isIso) {
      state = state.copyWith(errorMessage: '不支持播放 ISO 文件');
      return;
    }
    await _openRemoteFile(
      file,
      preparingMessage: '正在准备播放…',
      completedMessage: '已交给系统默认播放器',
    );
  }

  static const _macOSExternalPlayers = [
    ExternalPlayer('IINA', 'com.colliderli.iina'),
    ExternalPlayer('VLC', 'org.videolan.vlc'),
    ExternalPlayer('Infuse', 'com.firecore.Infuse'),
    ExternalPlayer('nPlayer', 'com.nplayer.nplayer'),
    ExternalPlayer('Movist Pro', 'com.movist.MovistPro'),
    ExternalPlayer('VidHub', 'com.mac.utility.media.hub'),
    ExternalPlayer('Forward', 'flux.inchmade.app'),
    ExternalPlayer('SenPlayer', 'com.wuziqi.SenPlayer'),
    ExternalPlayer('PotPlayer', 'com.kakao.PotPlayer'),
    ExternalPlayer('mpv', 'io.mpv'),
  ];

  static const _windowsExternalPlayers = [
    ExternalPlayer(
      'VLC',
      'vlc.exe',
      launchMode: ExternalPlayerLaunchMode.executable,
    ),
    ExternalPlayer(
      'mpv',
      'mpv.exe',
      launchMode: ExternalPlayerLaunchMode.executable,
    ),
    ExternalPlayer(
      'PotPlayer',
      'PotPlayerMini64.exe',
      launchMode: ExternalPlayerLaunchMode.executable,
    ),
    ExternalPlayer(
      'MPC-HC',
      'mpc-hc64.exe',
      launchMode: ExternalPlayerLaunchMode.executable,
    ),
  ];

  static const _linuxExternalPlayers = [
    ExternalPlayer(
      'VLC',
      'vlc',
      launchMode: ExternalPlayerLaunchMode.executable,
    ),
    ExternalPlayer(
      'mpv',
      'mpv',
      launchMode: ExternalPlayerLaunchMode.executable,
    ),
    ExternalPlayer(
      'Celluloid',
      'celluloid',
      launchMode: ExternalPlayerLaunchMode.executable,
    ),
    ExternalPlayer(
      'SMPlayer',
      'smplayer',
      launchMode: ExternalPlayerLaunchMode.executable,
    ),
  ];

  static const _androidExternalPlayers = [
    ExternalPlayer(
      'VLC',
      'org.videolan.vlc',
      launchMode: ExternalPlayerLaunchMode.androidPackage,
    ),
    ExternalPlayer(
      'MX Player',
      'com.mxtech.videoplayer.ad',
      launchMode: ExternalPlayerLaunchMode.androidPackage,
    ),
    ExternalPlayer(
      'mpv',
      'is.xyz.mpv',
      launchMode: ExternalPlayerLaunchMode.androidPackage,
    ),
    ExternalPlayer(
      'Nova Video Player',
      'org.courville.nova',
      launchMode: ExternalPlayerLaunchMode.androidPackage,
    ),
    ExternalPlayer(
      'Just Player',
      'com.brouken.player',
      launchMode: ExternalPlayerLaunchMode.androidPackage,
    ),
  ];

  static const _iOSExternalPlayers = [
    ExternalPlayer(
      'VLC',
      'vlc-x-callback',
      launchMode: ExternalPlayerLaunchMode.urlScheme,
      urlScheme: 'vlc-x-callback',
    ),
    ExternalPlayer(
      'Infuse',
      'infuse',
      launchMode: ExternalPlayerLaunchMode.urlScheme,
      urlScheme: 'infuse',
    ),
    ExternalPlayer(
      'nPlayer',
      'nplayer',
      launchMode: ExternalPlayerLaunchMode.urlScheme,
      urlScheme: 'nplayer-https',
    ),
  ];

  static const _externalPlayerChannel = MethodChannel(
    'com.ptools.guangya/external_player',
  );

  Future<List<ExternalPlayer>> availableExternalPlayers() async {
    if (Platform.isMacOS) return _availableMacOSExternalPlayers();
    if (Platform.isWindows) {
      return _availableWindowsExternalPlayers();
    }
    if (Platform.isLinux) {
      return _availableExecutablePlayers(
        _linuxExternalPlayers,
        lookupCommand: 'which',
      );
    }
    if (Platform.isAndroid) return _availableAndroidExternalPlayers();
    if (Platform.isIOS) return _availableIOSExternalPlayers();
    return const [];
  }

  Future<List<ExternalPlayer>> _availableMacOSExternalPlayers() async {
    final installed = <ExternalPlayer>[];
    for (final player in _macOSExternalPlayers) {
      try {
        final result = await Process.run('/usr/bin/mdfind', [
          "kMDItemCFBundleIdentifier == '${player.bundleID}'",
        ]);
        if (result.exitCode == 0) {
          final path = preferredExternalPlayerApplicationPath(
            result.stdout.toString().split('\n'),
            currentExecutable: Platform.resolvedExecutable,
          );
          if (path != null && await Directory(path).exists()) {
            installed.add(player.withApplicationPath(path));
          }
        }
      } catch (_) {
        // A missing application is expected and should not affect playback.
      }
    }
    return installed;
  }

  Future<List<ExternalPlayer>> _availableExecutablePlayers(
    List<ExternalPlayer> players, {
    required String lookupCommand,
  }) async {
    final installed = <ExternalPlayer>[];
    for (final player in players) {
      try {
        final result = await Process.run(lookupCommand, [player.bundleID]);
        if (result.exitCode != 0) continue;
        String? path;
        for (final value in result.stdout.toString().split(
          RegExp(r'[\r\n]+'),
        )) {
          final candidate = value.trim();
          if (candidate.isNotEmpty) {
            path = candidate;
            break;
          }
        }
        if (path != null) installed.add(player.withApplicationPath(path));
      } catch (_) {
        // A missing executable is expected.
      }
    }
    return installed;
  }

  Future<List<ExternalPlayer>> _availableWindowsExternalPlayers() async {
    final programFiles = Platform.environment['ProgramFiles'];
    final programFilesX86 = Platform.environment['ProgramFiles(x86)'];
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final knownPaths = <String, List<String?>>{
      'vlc.exe': [
        if (programFiles != null) '$programFiles\\VideoLAN\\VLC\\vlc.exe',
        if (programFilesX86 != null) '$programFilesX86\\VideoLAN\\VLC\\vlc.exe',
      ],
      'PotPlayerMini64.exe': [
        if (programFiles != null)
          '$programFiles\\DAUM\\PotPlayer\\PotPlayerMini64.exe',
        if (programFilesX86 != null)
          '$programFilesX86\\DAUM\\PotPlayer\\PotPlayerMini64.exe',
      ],
      'mpc-hc64.exe': [
        if (programFiles != null) '$programFiles\\MPC-HC\\mpc-hc64.exe',
        if (programFilesX86 != null) '$programFilesX86\\MPC-HC\\mpc-hc64.exe',
      ],
      'mpv.exe': [
        if (localAppData != null) '$localAppData\\Programs\\mpv\\mpv.exe',
      ],
    };
    final installed = <ExternalPlayer>[];
    for (final player in _windowsExternalPlayers) {
      var path = firstExistingExecutablePath(
        knownPaths[player.bundleID] ?? const [],
        (candidate) => File(candidate).existsSync(),
      );
      if (path == null) {
        try {
          final result = await Process.run('where.exe', [player.bundleID]);
          if (result.exitCode == 0) {
            path = firstExistingExecutablePath(
              result.stdout
                  .toString()
                  .split(RegExp(r'[\r\n]+'))
                  .map((value) => value.trim()),
              (candidate) => candidate.isNotEmpty,
            );
          }
        } catch (_) {
          // A missing executable is expected.
        }
      }
      if (path != null) installed.add(player.withApplicationPath(path));
    }
    return installed;
  }

  Future<List<ExternalPlayer>> _availableAndroidExternalPlayers() async {
    try {
      final packages = await _externalPlayerChannel.invokeMethod<List<dynamic>>(
        'availablePlayers',
        {
          'packages': _androidExternalPlayers
              .map((item) => item.bundleID)
              .toList(),
        },
      );
      final available =
          packages?.map((value) => value.toString()).toSet() ?? {};
      return _androidExternalPlayers
          .where((player) => available.contains(player.bundleID))
          .toList(growable: false);
    } catch (error) {
      AppLogger.warning('Player', '检测 Android 外部播放器失败：$error');
      return const [];
    }
  }

  Future<List<ExternalPlayer>> _availableIOSExternalPlayers() async {
    final installed = <ExternalPlayer>[];
    for (final player in _iOSExternalPlayers) {
      final scheme = player.urlScheme;
      if (scheme == null) continue;
      try {
        if (await canLaunchUrl(Uri.parse('$scheme://'))) installed.add(player);
      } catch (_) {}
    }
    return installed;
  }

  Future<void> playWithExternalPlayer(
    CloudFile file, [
    ExternalPlayer? player,
  ]) async {
    if (_api == null) return;
    if (file.isIso) {
      state = state.copyWith(errorMessage: '不支持播放 ISO 文件');
      return;
    }
    try {
      state = state.copyWith(
        statusMessage: player == null ? '正在准备外部播放…' : '正在使用 ${player.name} 播放…',
      );
      final url = await _resolveOpenUrl(file);
      final selectedPlayer = player;
      if (selectedPlayer != null &&
          selectedPlayer.launchMode == ExternalPlayerLaunchMode.macOSBundle) {
        final applicationPath = selectedPlayer.applicationPath;
        final iinaCLI = applicationPath == null
            ? null
            : '$applicationPath/Contents/MacOS/iina-cli';
        final useIINACommand =
            selectedPlayer.bundleID == 'com.colliderli.iina' &&
            iinaCLI != null &&
            await File(iinaCLI).exists();
        final result = useIINACommand
            ? await Process.run(iinaCLI, [url.toString()])
            : await Process.run('/usr/bin/open', [
                if (applicationPath != null) ...[
                  '-a',
                  applicationPath,
                ] else ...[
                  '-b',
                  selectedPlayer.bundleID,
                ],
                url.toString(),
              ]);
        if (result.exitCode != 0) {
          throw Exception('无法启动 ${selectedPlayer.name}：${result.stderr}');
        }
      } else if (player?.launchMode == ExternalPlayerLaunchMode.executable) {
        final executable = player?.applicationPath;
        if (executable == null || executable.isEmpty) {
          throw Exception('未找到 ${player?.name ?? '外部播放器'} 可执行文件');
        }
        await Process.start(executable, [
          url.toString(),
        ], mode: ProcessStartMode.detached);
      } else if (player?.launchMode ==
          ExternalPlayerLaunchMode.androidPackage) {
        final opened = await _externalPlayerChannel.invokeMethod<bool>(
          'openPlayer',
          {'package': player!.bundleID, 'url': url.toString()},
        );
        if (opened != true) throw Exception('无法启动 ${player.name}');
      } else if (player?.launchMode == ExternalPlayerLaunchMode.urlScheme) {
        final target = externalPlayerURL(player!, url);
        if (!await launchUrl(target, mode: LaunchMode.externalApplication)) {
          throw Exception('无法启动 ${player.name}');
        }
      } else if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw Exception('无法调用系统默认外部播放器');
      }
      state = state.copyWith(
        statusMessage: player == null ? '已交给外部播放器' : '已交给 ${player.name}',
      );
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  Future<Uri> playbackUrl(CloudFile file) {
    if (file.isIso) throw UnsupportedError('不支持播放 ISO 文件');
    return _resolveOpenUrl(file);
  }

  Future<List<CloudFile>> siblingFiles(CloudFile file) async {
    final siblings = await FileMetadataCache.siblingFiles(file.id);
    if (siblings == null) return [file];
    return siblings;
  }

  Future<List<CloudFile>> siblingMediaFiles(CloudFile file) async {
    final siblings = await siblingFiles(file);
    return siblings.where((candidate) => candidate.isVideo).toList();
  }

  /// For a disc root folder (BDMV/VIDEO_TS), list its children and return
  /// the largest video file (typically the main feature .m2ts) that can be
  /// streamed by the built-in player.  Returns `null` when the folder is
  /// not a disc structure or no suitable file is found.
  Future<CloudFile?> discMainVideoFile(CloudFile file) async {
    if (!file.isDirectory) return null;
    try {
      final response = await _api!.fsFiles(
        parentID: file.id,
        page: 0,
        pageSize: 200,
        orderBy: 0,
        sortType: 0,
      );
      final children = _extractFiles(response);
      // Check if this is a disc root by looking for BDMV/VIDEO_TS among
      // immediate children.
      final childNames = children
          .where((f) => f.isDirectory)
          .map((f) => f.name.toUpperCase())
          .toSet();
      final selectedName = file.name.trim().toUpperCase();
      final selectedDiscDirectory =
          selectedName == 'BDMV' || selectedName == 'VIDEO_TS';
      final isDiscRoot =
          selectedDiscDirectory ||
          childNames.contains('BDMV') ||
          childNames.contains('VIDEO_TS');
      if (!isDiscRoot) return null;
      // Walk the disc container before looking for the largest transport
      // stream. BDMV/STREAM is two levels below the selected root, while
      // VIDEO_TS files are often directly inside VIDEO_TS.
      final videoFiles = <CloudFile>[];
      final queue = <(CloudFile file, int depth)>[
        if (selectedDiscDirectory) (file, 0),
        if (!selectedDiscDirectory)
          for (final child in children.where((child) => child.isDirectory))
            (child, 1),
      ];
      while (queue.isNotEmpty) {
        final (directory, depth) = queue.removeAt(0);
        if (depth > 3) continue;
        final upper = directory.name.toUpperCase();
        if (upper != 'BDMV' && upper != 'VIDEO_TS' && upper != 'STREAM') {
          continue;
        }
        try {
          final subResponse = await _api!.fsFiles(
            parentID: directory.id,
            page: 0,
            pageSize: 500,
            orderBy: 0,
            sortType: 0,
          );
          final subChildren = _extractFiles(subResponse);
          for (final sub in subChildren) {
            if (sub.isVideo) {
              videoFiles.add(sub);
            } else if (sub.isDirectory) {
              queue.add((sub, depth + 1));
            }
          }
        } catch (_) {
          // Ignore inaccessible optional disc directories and use any stream
          // files already discovered.
        }
      }
      if (videoFiles.isEmpty) return null;
      // Return the largest file (main feature).
      videoFiles.sort((a, b) => (b.size ?? 0).compareTo(a.size ?? 0));
      return videoFiles.first;
    } catch (_) {
      return null;
    }
  }

  Future<void> _openRemoteFile(
    CloudFile file, {
    required String preparingMessage,
    required String completedMessage,
  }) async {
    if (_api == null) return;
    try {
      state = state.copyWith(statusMessage: preparingMessage);
      final url = await _resolveOpenUrl(file);
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw Exception('无法调用系统默认应用打开签名链接');
      }
      state = state.copyWith(statusMessage: completedMessage);
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  Future<String?> createShare(CloudFile file) async {
    if (_api == null) return null;
    try {
      state = state.copyWith(statusMessage: '正在创建分享…');
      final result = await _api!.shareCreate([file.id], title: file.name);
      final link = JsonDeep.findString(result, const [
        'url',
        'shareUrl',
        'share_url',
        'link',
      ]);
      if (link != null) {
        state = state.copyWith(statusMessage: '分享链接已生成');
        return link;
      } else {
        state = state.copyWith(statusMessage: '分享已创建');
      }
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    }
    return null;
  }

  Future<void> restoreFiles(List<CloudFile> files) async {
    if (_api == null || files.isEmpty) return;
    try {
      state = state.copyWith(statusMessage: '正在恢复 ${files.length} 个项目…');
      await _api!.fsRecycle(files.map((file) => file.id).toList());
      state = state.copyWith(statusMessage: '已恢复 ${files.length} 个项目');
      await _invalidateFolderCaches(_currentParentID);
      await loadFiles(parentID: _currentParentID);
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  /// Keys used to search for a downloadable URL in API responses.
  static const _downloadUrlKeys = [
    'url',
    'dlink',
    'downloadUrl',
    'download_url',
    'downloadlink',
    'download_link',
    'signedUrl',
    'signedURL',
    'signed_url',
    'signedlink',
    'signed_link',
  ];

  Future<Uri> _resolveOpenUrl(CloudFile file) async {
    String? url;
    if (file.isVideo) {
      try {
        final detail = await _api!.fsDetail(file.id);
        final gcid =
            file.gcid ?? JsonDeep.findString(detail, const ['gcid', 'gcId']);
        if (gcid != null && gcid.isNotEmpty) {
          try {
            final videoResult = await _api!.vodDownloadURL(file.id, gcid);
            url = JsonDeep.findString(videoResult, _downloadUrlKeys);
          } catch (error) {
            // VOD acceleration may reject m2ts/iso files even though the
            // regular download endpoint can still issue a playable URL.
            AppLogger.warning('Player', 'VOD 链接不可用，降级普通下载链接：$error');
          }
        }
      } catch (error) {
        AppLogger.warning('Player', '获取视频详情失败，降级普通下载链接：$error');
      }
    }
    if (url == null) {
      final result = await _api!.downloadURL(file.id);
      AppLogger.info('File', '下载链接响应: $result');
      url = JsonDeep.findString(result, _downloadUrlKeys);
    }
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      throw Exception('响应缺少可打开的签名链接');
    }
    return uri;
  }

  Future<void> uploadLocalFiles(List<File> files, {String? parentID}) async {
    if (_api == null || files.isEmpty) return;
    final targetParentID = parentID ?? _currentParentID;
    final uploadFiles = <File>[];
    var totalBytes = 0;
    for (final file in files) {
      if (!await file.exists()) continue;
      uploadFiles.add(file);
      totalBytes += await file.length();
    }
    if (uploadFiles.isEmpty) {
      state = state.copyWith(errorMessage: '没有可上传的本地文件');
      return;
    }

    UploadProgress progress({
      required int completed,
      required int failed,
      required int transferred,
      required String currentName,
      required bool active,
    }) => UploadProgress(
      totalFiles: uploadFiles.length,
      completedFiles: completed,
      failedFiles: failed,
      totalBytes: totalBytes,
      transferredBytes: transferred,
      currentFileName: currentName,
      isActive: active,
    );

    state = state.copyWith(
      statusMessage: '正在上传 ${uploadFiles.length} 个文件…',
      uploadProgress: progress(
        completed: 0,
        failed: 0,
        transferred: 0,
        currentName: uploadFiles.first.uri.pathSegments.last,
        active: true,
      ),
    );
    var completed = 0;
    var failed = 0;
    var completedBytes = 0;
    for (final file in uploadFiles) {
      final fileSize = await file.length();
      final fileName = file.uri.pathSegments.last;
      state = state.copyWith(
        statusMessage:
            '正在上传 ${completed + failed + 1}/${uploadFiles.length}：$fileName',
        uploadProgress: progress(
          completed: completed,
          failed: failed,
          transferred: completedBytes,
          currentName: fileName,
          active: true,
        ),
      );
      try {
        await _api!.fileUpload(
          file,
          parentID: targetParentID,
          onProgress: (sent, total) {
            final currentTransferred =
                completedBytes + sent.clamp(0, total == 0 ? 0 : total).toInt();
            state = state.copyWith(
              uploadProgress: progress(
                completed: completed,
                failed: failed,
                transferred: currentTransferred,
                currentName: fileName,
                active: true,
              ),
            );
          },
        );
        completed += 1;
        completedBytes += fileSize;
      } catch (e) {
        AppLogger.warning('Storage', '上传文件失败：$fileName，$e');
        failed += 1;
        completedBytes += fileSize;
      }
    }
    state = state.copyWith(
      statusMessage: failed == 0
          ? '已上传 $completed 个文件'
          : '已上传 $completed 个文件，失败 $failed 个',
      uploadProgress: progress(
        completed: completed,
        failed: failed,
        transferred: completedBytes,
        currentName: '',
        active: false,
      ),
    );
    try {
      await _invalidateFolderCaches(targetParentID);
      await loadFiles(parentID: _currentParentID);
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  Future<void> moveFilesTo(List<CloudFile> files, {String? parentID}) async {
    if (_api == null || files.isEmpty) return;
    final movable = files
        .where((file) => !_sameParentID(file.parentID, parentID))
        .toList(growable: false);
    if (movable.isEmpty) {
      state = state.copyWith(statusMessage: '不能移动至相同目录', clearError: true);
      return;
    }
    final skipped = files.length - movable.length;
    state = state.copyWith(
      statusMessage: skipped == 0
          ? '正在移动 ${movable.length} 个项目…'
          : '已跳过 $skipped 个同目录项目，正在移动 ${movable.length} 个项目…',
      clearError: true,
    );
    try {
      await _api!.fsMove(
        movable.map((file) => file.id).toList(),
        parentID: parentID,
      );
      await FileMetadataCache.removeFilesFromAllFolders(
        movable.map((file) => file.id),
      );
      await FileMetadataCache.updateFolderChildren(
        _currentParentID,
        removeIDs: movable.map((file) => file.id),
      );
      await FileMetadataCache.updateFolderChildren(
        parentID,
        addOrReplace: movable,
      );
      await _invalidateListCache(_currentParentID);
      if (parentID != _currentParentID) await _invalidateListCache(parentID);
      state = state.copyWith(
        statusMessage: skipped == 0 ? '移动完成' : '移动完成，已跳过 $skipped 个',
        selectedIDs: {},
      );
      await loadFiles(parentID: _currentParentID);
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }

  void clearStatus() {
    state = state.copyWith(clearStatus: true);
  }

  Future<void> _invalidateFolderCaches(String? parentID) async {
    await FileMetadataCache.updateFolderChildren(parentID, invalidate: true);
    await _invalidateListCache(parentID);
  }

  Future<void> _invalidateListCache(String? parentID) async {
    final raw = StorageManager.get<dynamic>(StorageKeys.fileListCache);
    if (raw is! Map) return;
    final cache = Map<dynamic, dynamic>.from(raw);
    final location = parentID ?? 'root';
    final currentPrefix = 'v3|${state.section.name}|$location|';
    final previousPrefix = 'v2|${state.section.name}|$location|';
    final legacyPrefix = '${state.section.name}:$location:';
    cache.removeWhere((key, _) {
      final value = key.toString();
      return value.startsWith(currentPrefix) ||
          value.startsWith(previousPrefix) ||
          value.startsWith(legacyPrefix);
    });
    await StorageManager.set(StorageKeys.fileListCache, cache);
  }

  // ── Helpers ─────────────────────────────────────────────────────

  List<CloudFile> _extractFiles(Map<String, dynamic> json) {
    final result = <CloudFile>[];
    final seen = <String>{};

    void visit(dynamic value) {
      if (value is Map) {
        final map = Map<String, dynamic>.from(value);
        try {
          final file = CloudFile.fromJson(map);
          if (seen.add(file.id)) result.add(file);
        } catch (_) {
          AppLogger.debug(
            'Storage',
            'CloudFile 解析跳过：id=${map['fileId'] ?? map['id']}',
          );
        }
        for (final v in map.values) {
          visit(v);
        }
      } else if (value is List) {
        for (final v in value) {
          visit(v);
        }
      }
    }

    final preferred = _findArrayDeep(json, const [
      'list',
      'files',
      'fileList',
      'file_list',
      'items',
      'records',
      'rows',
      'dataList',
      'resList',
      'resourceList',
    ]);
    if (preferred != null) {
      visit(preferred);
      return result;
    }

    visit(json);
    return result;
  }

  int _extractTotalPages(Map<String, dynamic> json, int itemCount) {
    final explicitPages = _extractInt(json, [
      'totalPages',
      'pages',
      'pageCount',
    ]);
    if (explicitPages != null && explicitPages > 0) return explicitPages;
    final totalItems = _extractInt(json, ['total', 'totalCount', 'count']);
    if (totalItems == null || totalItems <= 0) {
      return itemCount < state.pageSize ? 1 : state.currentPage + 2;
    }
    return (totalItems / state.pageSize).ceil().clamp(1, 1 << 31).toInt();
  }

  static List<dynamic>? _findArrayDeep(
    Map<String, dynamic> json,
    List<String> keys,
  ) {
    for (final key in keys) {
      final v = json[key];
      if (v is List) return v;
    }
    const preferredKeys = ['data', 'result', 'payload'];
    for (final key in preferredKeys) {
      final v = json[key];
      if (v is Map) {
        final found = _findArrayDeep(Map<String, dynamic>.from(v), keys);
        if (found != null) return found;
      }
    }
    for (final entry in json.entries) {
      if (preferredKeys.contains(entry.key)) continue;
      final v = entry.value;
      if (v is Map) {
        final found = _findArrayDeep(Map<String, dynamic>.from(v), keys);
        if (found != null) return found;
      }
    }
    return null;
  }

  static int? _extractInt(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final v = json[key];
      if (v != null) return v is int ? v : int.tryParse(v.toString());
    }
    for (final entry in json.entries) {
      if (entry.value is Map<String, dynamic>) {
        final found = _extractInt(entry.value as Map<String, dynamic>, keys);
        if (found != null) return found;
      }
    }
    return null;
  }
}

final fileProvider = StateNotifierProvider<FileNotifier, FileState>(
  (ref) => FileNotifier(),
);
