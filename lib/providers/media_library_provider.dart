import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../api/guangya_api.dart';
import '../core/http/http_error.dart';
import '../core/logging/app_logger.dart';
import '../core/storage/file_metadata_cache.dart';
import '../core/storage/media_library_store.dart';
import '../core/storage/storage_manager.dart';
import '../core/utils/concurrent_map.dart';
import '../models/cloud_file.dart';
import '../models/media_library.dart';
import 'watch_history_provider.dart';

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
  final String? error;

  const CloudBackupSyncProgress({
    required this.phase,
    required this.destination,
    required this.transferredBytes,
    required this.totalBytes,
    required this.isActive,
    this.error,
  });

  double get fraction =>
      totalBytes <= 0 ? 0 : (transferredBytes / totalBytes).clamp(0.0, 1.0);
}

class MediaLibraryState {
  final List<MediaLibraryDefinition> libraries;
  final String? selectedLibraryID;
  final List<MediaLibraryItem> items;
  final List<MediaLibraryItem> allItems;
  final bool isLoading;
  final bool isScanning;
  final bool isRefreshingCloudIndex;
  final CloudBackupSyncProgress? cloudBackupSync;
  final MediaLibraryScanProgress progress;
  final List<MediaLibraryScanLog> scanLogs;
  final String searchQuery;
  final String? errorMessage;
  final String? statusMessage;

  const MediaLibraryState({
    this.libraries = const [],
    this.selectedLibraryID,
    this.items = const [],
    this.allItems = const [],
    this.isLoading = false,
    this.isScanning = false,
    this.isRefreshingCloudIndex = false,
    this.cloudBackupSync,
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

  List<MediaLibraryItem> get globalVisibleItems {
    final query = searchQuery.trim().toLowerCase();
    if (query.isEmpty) return allItems;
    return allItems.where((item) {
      return item.title.toLowerCase().contains(query) ||
          item.file.name.toLowerCase().contains(query) ||
          item.file.cloudPath.toLowerCase().contains(query);
    }).toList();
  }

  MediaLibraryStatistics get globalStatistics =>
      MediaLibraryStatistics.fromItems(allItems);

  MediaLibraryState copyWith({
    List<MediaLibraryDefinition>? libraries,
    String? selectedLibraryID,
    bool clearSelectedLibrary = false,
    List<MediaLibraryItem>? items,
    List<MediaLibraryItem>? allItems,
    bool? isLoading,
    bool? isScanning,
    bool? isRefreshingCloudIndex,
    CloudBackupSyncProgress? cloudBackupSync,
    bool clearCloudBackupSync = false,
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
      allItems: allItems ?? this.allItems,
      isLoading: isLoading ?? this.isLoading,
      isScanning: isScanning ?? this.isScanning,
      isRefreshingCloudIndex:
          isRefreshingCloudIndex ?? this.isRefreshingCloudIndex,
      cloudBackupSync: clearCloudBackupSync
          ? null
          : (cloudBackupSync ?? this.cloudBackupSync),
      progress: progress ?? this.progress,
      scanLogs: scanLogs ?? this.scanLogs,
      searchQuery: searchQuery ?? this.searchQuery,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      statusMessage: clearStatus ? null : (statusMessage ?? this.statusMessage),
    );
  }
}

class MediaLibraryNotifier extends StateNotifier<MediaLibraryState> {
  final Future<void> Function(Set<String>)? _removeWatchHistory;
  GuangyaAPI? _api;
  final _store = MediaLibraryStore();
  final _tmdbDetailsRequests = <String, Future<Map<String, dynamic>>>{};
  final _searchResultsCache = <String, List<MediaLibraryItem>>{};
  final _artworkHydrationLibraries = <String>{};
  bool _loaded = false;
  bool _cancelScan = false;
  bool _cancelDetailSync = false;
  bool _refreshingCloudIndex = false;
  bool _reconcilingMediaGCIDs = false;
  Timer? _cloudIndexTimer;
  Completer<bool>? _cloudIndexRefreshCompleter;

  MediaLibraryNotifier({Future<void> Function(Set<String>)? removeWatchHistory})
    : _removeWatchHistory = removeWatchHistory,
      super(const MediaLibraryState());

  set api(GuangyaAPI value) => _api = value;

  Future<void> load() async {
    if (_loaded) {
      if (state.allItems.isEmpty) unawaited(_refreshAllItemsState());
      return;
    }
    _loaded = true;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await _store.initialize();
      await _migrateLegacyHiveIfNeeded();
      final removedDiscStreams = await _removeDiscInternalItems();
      final libraries = await _loadLibraries();
      final selectedID = libraries.isEmpty ? null : libraries.first.id;
      final items = selectedID == null
          ? <MediaLibraryItem>[]
          : await _loadItems(selectedID);
      final allItems = await _loadAllItems();
      final logs = _loadScanHistory();
      state = state.copyWith(
        libraries: libraries,
        selectedLibraryID: selectedID,
        items: items,
        allItems: allItems,
        scanLogs: logs,
        statusMessage: removedDiscStreams == 0
            ? null
            : '已清理 $removedDiscStreams 个光盘目录内部文件',
      );
      if (selectedID != null) {
        unawaited(_hydrateMissingArtwork(selectedID, items));
      }
      unawaited(refreshGlobalCloudIndex());
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> _refreshAllItemsState() async {
    try {
      await _store.initialize();
      final allItems = await _loadAllItems();
      if (allItems.isNotEmpty || state.allItems.isEmpty) {
        state = state.copyWith(allItems: allItems);
      }
    } catch (_) {
      // The normal load path reports initialization failures. This compatibility
      // refresh is best effort for an already-mounted provider instance.
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
      allItems: allItems,
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
      await _applyImportedBackup(backupPath);
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

  Future<void> exportScrapedDataToCloud() async {
    if (_api == null || state.isLoading || state.isScanning) return;
    _appendBackupLog('开始同步刮削数据到云盘');
    state = state.copyWith(
      clearError: true,
      clearStatus: true,
      cloudBackupSync: const CloudBackupSyncProgress(
        phase: '正在准备备份',
        destination: '云盘根目录/小黄鸭备份',
        transferredBytes: 0,
        totalBytes: 0,
        isActive: true,
      ),
    );
    Directory? temporaryDirectory;
    try {
      _appendBackupLog('正在确认云盘备份目录');
      final destination = await _resolveCloudBackupDestination();
      state = state.copyWith(
        cloudBackupSync: CloudBackupSyncProgress(
          phase: '正在导出本地数据库',
          destination: destination.path,
          transferredBytes: 0,
          totalBytes: 0,
          isActive: true,
        ),
      );
      _appendBackupLog('备份目录已就绪：${destination.path}');
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'guangya-media-',
      );
      final backup = File(
        '${temporaryDirectory.path}/${_cloudBackupFileName(DateTime.now())}',
      );
      _appendBackupLog('正在导出本地刮削数据库');
      await _store.exportBackupTo(backup.path);
      final size = await backup.length();
      _appendBackupLog('本地数据库导出完成，大小 ${_formatBytes(size)}');
      state = state.copyWith(
        cloudBackupSync: CloudBackupSyncProgress(
          phase: '正在上传备份',
          destination: '${destination.path}/${backup.uri.pathSegments.last}',
          transferredBytes: 0,
          totalBytes: size,
          isActive: true,
        ),
      );
      _appendBackupLog('正在上传备份到 ${destination.path}');
      await _api!.fileUpload(
        backup,
        parentID: destination.id,
        contentType: 'application/vnd.sqlite3',
        onProgress: (sent, total) {
          state = state.copyWith(
            cloudBackupSync: CloudBackupSyncProgress(
              phase: '正在上传备份',
              destination:
                  '${destination.path}/${backup.uri.pathSegments.last}',
              transferredBytes: sent,
              totalBytes: total,
              isActive: true,
            ),
          );
        },
      );
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
      _appendBackupLog('云盘备份同步完成：$uploadedPath');
    } catch (error) {
      final destination = state.cloudBackupSync?.destination ?? '云盘根目录/小黄鸭备份';
      final reason = _backupFailureReason(error);
      _appendBackupLog('同步到云盘失败：$reason', isError: true, error: error);
      state = state.copyWith(
        errorMessage: '同步到云盘失败：$reason',
        cloudBackupSync: CloudBackupSyncProgress(
          phase: '同步失败',
          destination: destination,
          transferredBytes: 0,
          totalBytes: 0,
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
    if (existing != null) return existing;
    final folderID = _findStringDeep(
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
      return _CloudBackupDestination(id: storedID, path: '云盘根目录/小黄鸭备份');
    }
    final root = await _api!.fsFiles(parentID: null, pageSize: 1000);
    final existing = _extractFiles(
      root,
    ).where((file) => file.isDirectory && file.name == folderName);
    final folder = existing.isEmpty ? null : existing.first;
    if (folder == null) return null;
    await StorageManager.set(StorageKeys.cloudScrapedBackupFolderID, folder.id);
    return _CloudBackupDestination(id: folder.id, path: '云盘根目录/$folderName');
  }

  Future<List<CloudFile>> cloudScrapedBackups() async {
    if (_api == null) return const [];
    _appendBackupLog('正在查找云盘中的 SQLite 备份');
    state = state.copyWith(
      clearError: true,
      clearStatus: true,
      cloudBackupSync: const CloudBackupSyncProgress(
        phase: '正在查找云盘备份',
        destination: '云盘根目录/小黄鸭备份',
        transferredBytes: 0,
        totalBytes: 0,
        isActive: true,
      ),
    );
    try {
      final destination = await _findCloudBackupDestination();
      if (destination == null) {
        _appendBackupLog('未找到云盘备份目录，当前没有可恢复的备份');
        state = state.copyWith(
          cloudBackupSync: const CloudBackupSyncProgress(
            phase: '未找到云盘备份',
            destination: '云盘根目录/小黄鸭备份',
            transferredBytes: 0,
            totalBytes: 0,
            isActive: false,
          ),
        );
        return const [];
      }
      _appendBackupLog('正在读取备份目录：${destination.path}');
      final response = await _api!.fsFiles(
        parentID: destination.id,
        pageSize: 1000,
      );
      final backups =
          _extractFiles(response)
              .where(
                (file) =>
                    !file.isDirectory &&
                    file.name.toLowerCase().endsWith('.sqlite3') &&
                    file.name.startsWith('media-library-'),
              )
              .toList()
            ..sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
      _appendBackupLog('云盘备份查找完成，找到 ${backups.length} 个文件');
      state = state.copyWith(
        cloudBackupSync: const CloudBackupSyncProgress(
          phase: '请选择要恢复的备份',
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

  Future<void> importScrapedDataFromCloud(CloudFile backup) async {
    if (_api == null || state.isLoading || state.isScanning) return;
    _appendBackupLog('开始从云盘恢复：${backup.name}');
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      clearStatus: true,
      cloudBackupSync: CloudBackupSyncProgress(
        phase: '正在获取备份下载地址',
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
        _appendBackupLog('下载地址解析失败，接口返回字段：$fields', isError: true);
        throw Exception('云盘未返回有效下载地址（字段：$fields）');
      }
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'guangya-media-',
      );
      final localBackup = File(
        '${temporaryDirectory.path}/media-library.sqlite3',
      );
      _appendBackupLog('正在下载云盘备份：${backup.name}');
      await Dio().download(
        url,
        localBackup.path,
        onReceiveProgress: (received, total) {
          state = state.copyWith(
            cloudBackupSync: CloudBackupSyncProgress(
              phase: '正在下载云盘备份',
              destination: backup.name,
              transferredBytes: received,
              totalBytes: total > 0 ? total : (backup.size ?? 0),
              isActive: true,
            ),
          );
        },
      );
      _appendBackupLog('备份下载完成，正在导入本地数据库');
      state = state.copyWith(
        cloudBackupSync: CloudBackupSyncProgress(
          phase: '正在导入刮削数据',
          destination: backup.name,
          transferredBytes: backup.size ?? 0,
          totalBytes: backup.size ?? 0,
          isActive: true,
        ),
      );
      await _applyImportedBackup(localBackup.path);
      _appendBackupLog('云盘备份恢复完成：${backup.name}');
      state = state.copyWith(
        cloudBackupSync: CloudBackupSyncProgress(
          phase: '恢复完成',
          destination: backup.name,
          transferredBytes: backup.size ?? 0,
          totalBytes: backup.size ?? 0,
          isActive: false,
        ),
      );
    } catch (error) {
      final reason = _backupFailureReason(error);
      _appendBackupLog('从云盘恢复失败：$reason', isError: true, error: error);
      state = state.copyWith(
        errorMessage: '从云盘恢复失败：$reason',
        cloudBackupSync: CloudBackupSyncProgress(
          phase: '恢复失败',
          destination: backup.name,
          transferredBytes: 0,
          totalBytes: backup.size ?? 0,
          isActive: false,
          error: reason,
        ),
      );
    } finally {
      if (temporaryDirectory != null && await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> _applyImportedBackup(String backupPath) async {
    final stats = await _store.importBackup(backupPath);
    final libraries = await _loadLibraries();
    final selectedID = libraries.isEmpty ? null : libraries.first.id;
    final allItems = await _loadAllItems();
    state = state.copyWith(
      libraries: libraries,
      selectedLibraryID: selectedID,
      clearSelectedLibrary: selectedID == null,
      items: selectedID == null ? const [] : await _loadItems(selectedID),
      allItems: allItems,
      statusMessage: '刮削数据已导入，已回收 ${_formatBytes(stats.reclaimedBytes)}',
    );
    if (selectedID != null) {
      unawaited(_hydrateMissingArtwork(selectedID, state.items));
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

  /// Scans only the folders configured by the selected media library. A
  /// rescan bypasses the directory cache, but deliberately never falls back
  /// to the account-wide cloud index: that index is slow and cannot provide
  /// useful per-library progress or cancellation.
  Future<void> scanSelectedLibrary({
    MediaLibraryScanMode mode = MediaLibraryScanMode.unrecognizedOnly,
  }) async {
    final library = state.selectedLibrary;
    if (library == null || _api == null || state.isScanning) return;
    final forceAll = mode == MediaLibraryScanMode.forceAll;
    final modeLabel = forceAll ? '强制全部重新识别' : '仅扫描未识别资源';

    _cancelScan = false;
    state = state.copyWith(
      isScanning: true,
      progress: const MediaLibraryScanProgress(phase: '准备扫描'),
      scanLogs: [
        MediaLibraryScanLog(
          createdAt: DateTime.now(),
          message: '任务已创建，$modeLabel：「${library.name}」',
        ),
      ],
      clearError: true,
      clearStatus: true,
    );

    try {
      final removedDiscStreams = await _removeDiscInternalItems();
      if (removedDiscStreams > 0) {
        _appendScanLog('已清理 $removedDiscStreams 个已入库的光盘目录内部文件');
      }
      final previousLibraryItems = await _loadItems(library.id);
      final existingByID = {
        for (final item in previousLibraryItems) item.id: item,
      };
      final existingByGCID = {
        for (final item in previousLibraryItems)
          if (item.file.gcid?.isNotEmpty == true) item.file.gcid!: item,
      };
      final initialItems = await _loadAllItems()
        ..removeWhere((item) => item.libraryID == library.id);
      final unique = <String, MediaLibraryItem>{};
      final tmdbApiKey =
          StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
      final tmdbProxyHost =
          StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '';
      final tmdbProxyPort =
          StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '';
      var completed = 0;
      Future<void> pendingPersistence = Future.value();
      final seriesMatches = <String, MediaLibraryItem>{};
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
      final aggregatedSeriesKeys = <String>{};

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

      Future<void> aggregateRecognizedSeries(
        String seriesKey,
        MediaLibraryItem matched,
      ) async {
        if (!aggregatedSeriesKeys.add(seriesKey)) return;

        // Include records already stored for the directory as well as rows
        // discovered earlier in this scan. This makes all known episodes show
        // as recognized immediately; when their file is reached later it only
        // needs per-episode canonical renaming, never another TMDB lookup.
        final siblings = <String, MediaLibraryItem>{
          for (final item in previousLibraryItems)
            if (_seriesRecognitionKey(item) == seriesKey) item.id: item,
          for (final item in unique.values)
            if (_seriesRecognitionKey(item) == seriesKey) item.id: item,
        };
        if (siblings.isEmpty) return;

        final updates = siblings.values
            .map((item) => applySeriesMetadata(matched, item))
            .toList();
        for (final item in updates) {
          unique[item.id] = item;
        }
        pendingPersistence = pendingPersistence.then(
          (_) => _upsertItems(updates),
        );
        await pendingPersistence;
        _searchResultsCache.clear();
        _appendScanLog(
          '剧集已聚合：${matched.title}，已将 ${updates.length} 集标记为已识别，'
          '其余集将跳过 TMDB 识别队列',
        );
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
      final recognitionBatchSize = concurrency * 4;
      final queuedForRecognition = <CloudFile>[];
      final queuedRecognitionIDs = <String>{};
      Future<void> recognitionTail = Future.value();
      var scheduledRecognitionBatches = 0;
      _appendScanLog('$modeLabel，媒体识别并发数：$concurrency');

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
            var item =
                existing?.copyWith(file: file, updatedAt: DateTime.now()) ??
                fallback;
            final cachedSeriesMatch = seriesKey == null
                ? null
                : seriesMatches[seriesKey];
            if (cachedSeriesMatch != null) {
              item = applySeriesMetadata(cachedSeriesMatch, item);
            } else if (shouldRecognize) {
              if (seriesKey == null) {
                item = await _recognizeMediaItem(
                  fallback,
                  tmdbApiKey,
                  proxyHost: tmdbProxyHost,
                  proxyPort: tmdbProxyPort,
                );
              } else {
                final inFlight = seriesRecognitionTasks[seriesKey];
                late final MediaLibraryItem recognized;
                if (inFlight != null) {
                  recognized = await inFlight;
                } else {
                  final task = _recognizeMediaItem(
                    fallback,
                    tmdbApiKey,
                    proxyHost: tmdbProxyHost,
                    proxyPort: tmdbProxyPort,
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
                  await aggregateRecognizedSeries(seriesKey, recognized);
                  item = applySeriesMetadata(recognized, item);
                } else {
                  item = recognized.copyWith(
                    file: file,
                    updatedAt: DateTime.now(),
                  );
                }
              }
            }
            if (_cancelScan) return;
            // Do not lose an existing match solely because a transient TMDB
            // lookup failed while filling an incomplete record.
            if (item.tmdbID == null && existing?.tmdbID != null) {
              item = existing!.copyWith(file: file, updatedAt: DateTime.now());
            }
            if (seriesKey != null &&
                item.tmdbID != null &&
                item.mediaKind == TMDBMediaKind.tv) {
              seriesMatches[seriesKey] = item;
            }
            item = await _renameMatchedMediaFile(item);
            if (_cancelScan) return;
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

        await Future.wait(List.generate(concurrency, (_) => worker()));
      }

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
        for (final file in files) {
          if (queuedRecognitionIDs.add(file.id)) {
            queuedForRecognition.add(file);
          }
        }
        if (queuedForRecognition.length < recognitionBatchSize) return;
        final batch = queuedForRecognition.toList(growable: false);
        queuedForRecognition.clear();
        scheduleRecognitionBatch(batch);
        if (scheduledRecognitionBatches >= 2) await recognitionTail;
      }

      Future<void> flushRecognitionQueue() async {
        if (queuedForRecognition.isNotEmpty) {
          final batch = queuedForRecognition.toList(growable: false);
          queuedForRecognition.clear();
          scheduleRecognitionBatch(batch);
        }
        await recognitionTail;
      }

      _appendScanLog('正在强制刷新当前媒体库目录…');
      state = state.copyWith(
        progress: const MediaLibraryScanProgress(phase: '正在读取当前媒体库目录'),
      );
      if (!_cancelScan) {
        List<CloudFile> mediaFiles;
        try {
          mediaFiles = await _scanLibrarySourcesConcurrently(
            library,
            concurrency: concurrency,
            onMediaFiles: enqueueForRecognition,
          );
        } catch (error) {
          _appendScanLog('媒体库目录并发刷新失败，回退逐目录读取：$error', isError: true);
          final fallback = <String, CloudFile>{};
          for (final source in library.sources) {
            if (_cancelScan) break;
            await _scanSource(
              source.rootID,
              source.path,
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
      }
      if (!_cancelScan) await flushRecognitionQueue();
      await pendingPersistence;
      var items = unique.values.toList()
        ..sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
      // A cancelled rescan has only seen part of the configured folders. Keep
      // unseen rows rather than incorrectly treating them as deleted.
      if (_cancelScan) {
        final merged = <String, MediaLibraryItem>{
          for (final item in previousLibraryItems) item.id: item,
          for (final item in items) item.id: item,
        };
        items = merged.values.toList()
          ..sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          );
      }
      final allItems = [...initialItems, ...items];
      final discoveredIDs = items.map((item) => item.id).toSet();
      final removedMissing = _cancelScan
          ? 0
          : previousLibraryItems
                .where((item) => !discoveredIDs.contains(item.id))
                .length;
      final updatedLibrary = library.copyWith(updatedAt: DateTime.now());
      final libraries = state.libraries
          .map((item) => item.id == library.id ? updatedLibrary : item)
          .toList();

      await _saveAllItems(allItems);
      await _saveLibraries(libraries);
      state = state.copyWith(
        libraries: libraries,
        items: items,
        allItems: allItems,
        statusMessage: _cancelScan
            ? '扫描已停止，已保留 ${items.length} 个项目'
            : removedMissing == 0
            ? '$modeLabel完成：${items.length} 个视频文件'
            : '$modeLabel完成：${items.length} 个视频文件，已移除 $removedMissing 个不存在的条目',
      );
      _appendScanLog(
        _cancelScan
            ? '扫描已停止，已保留 ${items.length} 个条目'
            : removedMissing == 0
            ? '$modeLabel完成，共入库 ${items.length} 个条目'
            : '$modeLabel完成，共入库 ${items.length} 个条目，已清理 $removedMissing 个失效条目',
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

  Future<void> rescanSelectedLibrary({
    MediaLibraryScanMode mode = MediaLibraryScanMode.unrecognizedOnly,
  }) => scanSelectedLibrary(mode: mode);

  void cancelDetailSync() {
    _cancelDetailSync = true;
    _appendScanLog('[同步识别][调试] 已请求取消同步识别');
  }

  Future<bool> refreshGlobalCloudIndex({bool force = false}) async {
    if (_api == null) {
      AppLogger.warning('CloudIndex', '无法刷新全盘文件索引：云盘接口尚未初始化');
      return false;
    }
    if (_refreshingCloudIndex) {
      AppLogger.debug('CloudIndex', '全盘文件索引正在刷新，本次请求已合并');
      return await _cloudIndexRefreshCompleter?.future ?? false;
    }
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
    final rootSnapshot = await FileMetadataCache.folderChildren(null);
    final liveGCIDIndexReady =
        StorageManager.get<String>(StorageKeys.cloudIndexLiveGCIDVersion) ==
        '1';
    final needsFullRebuild =
        force ||
        lastUpdated == null ||
        rootSnapshot == null ||
        !liveGCIDIndexReady;
    if (!force && !needsFullRebuild) {
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
        await StorageManager.delete(StorageKeys.cloudIndexLiveGCIDVersion);
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
      final indexedItems = allItems
          .where((item) => item.file.gcid?.trim().isNotEmpty == true)
          .toList();
      if (indexedItems.isEmpty) return;
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
      for (final item in indexedItems) {
        final gcid = item.file.gcid!.trim();
        final liveFiles = liveByGCID[gcid] ?? const <CloudFile>[];
        final assigned = assignedFileIDs[gcid] ??= <String>{};
        CloudFile? live = liveByID[item.id];
        live ??= liveFiles
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
        assigned.add(live.id);
        if (live.id == item.id &&
            (live.name.isEmpty || live.name == item.file.name) &&
            (live.cloudPath.isEmpty || live.cloudPath == item.file.cloudPath)) {
          continue;
        }
        replacements['${item.libraryID}:${item.id}'] = item.copyWith(
          file: item.file.copyWith(
            id: live.id,
            name: live.name.isEmpty ? item.file.name : live.name,
            size: live.size ?? item.file.size,
            gcid: gcid,
            modifiedAt: live.modifiedAt.isEmpty
                ? item.file.modifiedAt
                : live.modifiedAt,
            cloudPath: live.cloudPath.isEmpty
                ? item.file.cloudPath
                : live.cloudPath,
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
          '[GCID 校验] 更新 ${replacements.length} 条资源映射，'
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

  Future<_CloudIndexRefreshResult> _rebuildGlobalCloudIndex() async {
    try {
      final files = await _allGlobalRemoteFiles();
      final snapshots = <String?, List<CloudFile>>{null: <CloudFile>[]};
      for (final file in files) {
        final rawParentID = file.parentID?.trim();
        final parentID = rawParentID == null || rawParentID.isEmpty
            ? null
            : rawParentID;
        (snapshots[parentID] ??= []).add(file);
        if (file.isDirectory) {
          snapshots.putIfAbsent(file.id, () => <CloudFile>[]);
        }
      }
      await FileMetadataCache.clearFolderChildrenIndex();
      await FileMetadataCache.cacheFolderChildrenBatch(snapshots);
      return _CloudIndexRefreshResult(
        checkedFolders: snapshots.length,
        updatedFolders: snapshots.length,
        updatedEntries: files.length,
      );
    } catch (error) {
      AppLogger.warning('CloudIndex', '全盘分页接口刷新失败，回退到目录遍历：$error');
      return _rebuildGlobalCloudIndexByFolder();
    }
  }

  Future<List<CloudFile>> _allGlobalRemoteFiles() async {
    final concurrency = _cloudIndexConcurrency;
    late final List<List<CloudFile>> batches;
    if (concurrency == 1) {
      batches = [
        await _allGlobalRemoteFilesByType(concurrency: 1),
        await _allGlobalRemoteFilesByType(resType: 2, concurrency: 1),
      ];
    } else {
      final fileConcurrency = (concurrency + 1) ~/ 2;
      final directoryConcurrency = (concurrency - fileConcurrency).clamp(1, 20);
      batches = await Future.wait([
        _allGlobalRemoteFilesByType(concurrency: fileConcurrency),
        _allGlobalRemoteFilesByType(
          resType: 2,
          concurrency: directoryConcurrency,
        ),
      ]);
    }
    final unique = <String, CloudFile>{};
    for (final file in batches.expand((batch) => batch)) {
      unique[file.id] = file;
    }
    return unique.values.toList(growable: false);
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
      for (var index = 0; index < responses.length; index++) {
        final page = pages[index];
        final batch = _extractFiles(responses[index]);
        final added = batch.where((file) => seenIDs.add(file.id)).toList();
        values.addAll(added);
        AppLogger.info(
          'CloudIndex',
          '全盘$typeLabel索引第 ${page + 1} 页完成，获取 ${batch.length} 项，'
              '新增 ${added.length} 项，累计 ${values.length} 项',
        );
        if (batch.length < pageSize || added.isEmpty) {
          reachedEnd = true;
          break;
        }
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
      final response = await _api!.fsFiles(
        parentID: folder.id,
        page: page,
        pageSize: pageSize,
        orderBy: 0,
        sortType: 0,
      );
      final batch = _extractFiles(response);
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
    if (isError) {
      AppLogger.error('Media', message);
    } else {
      AppLogger.info('Media', message);
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
    return value
        .replaceFirst(RegExp(r'^Exception:\s*'), '')
        .replaceFirst(RegExp(r'^DioException \[[^\]]+\]:\s*'), '网络请求失败：');
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
      final resolved = recognized.tmdbID == null && prototype.tmdbID != null
          ? prototype
          : recognized;
      updates.addAll(group.map((item) => resolved.copyWith(file: item.file)));
    }
    if (updates.isEmpty) return;
    await _store.upsertItems(updates);
    _searchResultsCache.clear();
    final byID = {for (final item in updates) item.id: item};
    state = state.copyWith(
      items: state.items.map((item) => byID[item.id] ?? item).toList(),
      allItems: await _loadAllItems(),
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

  /// Pulls current file metadata from the cloud before parsing and matching it.
  /// This is required after a file was renamed outside the media scanner.
  Future<List<MediaTMDBMatchRequest>> refreshAndRecognizeItems(
    Iterable<MediaLibraryItem> values,
  ) async {
    if (_api == null) return const [];
    final originals = values.toList();
    if (originals.isEmpty) return const [];
    _cancelDetailSync = false;
    final apiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    state = state.copyWith(statusMessage: '正在同步云盘文件信息…', clearError: true);
    final synced = <_SyncedMediaItem>[];
    final failures = <String>[];
    final missing = <MediaLibraryItem>[];
    for (final original in originals) {
      if (_cancelDetailSync) break;
      try {
        _appendScanLog(
          '[同步识别][调试] 开始：${original.file.name} '
          '(fileId=${original.id}, gcid=${original.file.gcid ?? '-'})',
        );
        var confirmedNotFound = false;
        final latestFile = await _resolveCurrentCloudFile(
          original.file,
          libraryID: original.libraryID,
          onConfirmedNotFound: () => confirmedNotFound = true,
        );
        if (_cancelDetailSync) break;
        if (latestFile == null) {
          if (!confirmedNotFound) {
            throw StateError('文件定位失败，未确认 404，已保留媒体记录');
          }
          missing.add(original);
          _appendScanLog(
            '[同步识别][调试] GCID 与目录回查均未找到：${original.file.name}，'
            '删除媒体库记录',
          );
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
        final recognitionKey =
            '${fallback.libraryID}:${_parentDirectoryName(fallback.file.cloudPath) ?? ''}:'
            '${parsed.title.toLowerCase()}:${parsed.isEpisode}';
        _appendScanLog(
          '[同步识别][调试] 解析：${fallback.file.name} -> '
          '标题=${parsed.title}，年份=${parsed.year?.toString() ?? '未提供'}，'
          '类型=${fallback.mediaKind?.name ?? 'automatic'}',
        );
        var updated =
            automaticMatches[recognitionKey]?.copyWith(
              file: fallback.file,
              updatedAt: DateTime.now(),
            ) ??
            fallback;
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
          // A uniquely scored candidate is safe to apply automatically even
          // when TMDB localizes or slightly expands the title. Ambiguous
          // results still go to the manual picker below.
          if (candidates.length == 1 ||
              (candidates.isNotEmpty &&
                  _isHighConfidenceTMDBCandidate(fallback, candidates.first))) {
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
            automaticMatches[recognitionKey] = updated;
          } else if (candidates.length > 1 && original.tmdbID == null) {
            pendingMatches.add(
              MediaTMDBMatchRequest(items: [fallback], candidates: candidates),
            );
            _appendScanLog(
              '[同步识别][调试] 存在 ${candidates.length} 个 TMDB 候选，等待用户选择',
            );
          }
        }
        if (updated.tmdbID != null) {
          recognizedCount++;
          _appendScanLog(
            '[同步识别][调试] TMDB 命中：${updated.title} '
            '(tmdbId=${updated.tmdbID}, ${updated.year.isEmpty ? '年份未知' : updated.year})',
          );
        } else {
          _appendScanLog(
            '[同步识别][调试] TMDB 未命中：${parsed.title} '
            '(年份参数=${parsed.year?.toString() ?? '未提供'})',
          );
        }
        // A temporary TMDB or network failure must not erase a previously
        // scraped item just because its refreshed file metadata was available.
        if (updated.tmdbID == null && original.tmdbID != null) {
          updated = original.copyWith(
            file: fallback.file,
            updatedAt: DateTime.now(),
          );
        }
        final beforeName = updated.file.name;
        if (_cancelDetailSync) break;
        updated = await _renameMatchedMediaFile(updated);
        if (_cancelDetailSync) break;
        if (updated.file.name != beforeName) {
          renamedCount++;
          _appendScanLog(
            '[同步识别][调试] 已规范命名：$beforeName -> ${updated.file.name}',
          );
        } else if (updated.tmdbID != null) {
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
        statusMessage: apiKey.trim().isEmpty
            ? '已同步 ${updates.length} 个资源，未配置 TMDB，未执行自动识别'
            : _cancelDetailSync
            ? '同步识别已取消，已处理 ${updates.length} 个资源'
            : failures.isEmpty
            ? '已同步 ${updates.length} 个资源，自动识别 $recognizedCount 个，规范命名 $renamedCount 个'
            : '已同步 ${updates.length} 个资源，识别 $recognizedCount 个，规范命名 $renamedCount 个，${failures.length} 个失败',
        errorMessage: failures.isEmpty ? null : failures.first,
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

  Future<MediaLibraryItem> applyTMDBMatch(
    MediaLibraryItem item,
    Map<String, dynamic> candidate,
  ) async {
    final apiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    final manualSeason = _toInt(candidate['_manualSeason']);
    final manualEpisode = _toInt(candidate['_manualEpisode']);
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
    updated = await _renameMatchedMediaFile(
      updated,
      manualSeason: manualSeason,
      manualEpisode: manualEpisode,
    );
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
      allItems: await _loadAllItems(),
      statusMessage: updated.file.name == item.file.name
          ? '已匹配《${updated.title}》'
          : '已匹配并规范命名《${updated.title}》',
      clearError: true,
    );
    final seriesKey = _seriesRecognitionKey(item);
    if (seriesKey != null &&
        updated.tmdbID != null &&
        updated.mediaKind == TMDBMediaKind.tv) {
      await _aggregateStoredSeriesRecognition(seriesKey, updated);
    }
    return updated;
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
      final parsed = ParsedMediaName.parse(
        fallback.file.name,
        directoryName: _parentDirectoryName(fallback.file.cloudPath),
        directoryPath: fallback.file.cloudPath,
      );
      // Automatic recognition deliberately uses TMDB multi-search. The
      // filename-derived kind is only a hint and may be wrong for legacy rows.
      final requestedKind = 'auto';
      final searchTitle = parsed.title.trim().isEmpty
          ? fallback.title
          : parsed.title;
      final taggedCandidate = await _tmdbCandidateFromPathTag(
        fallback,
        apiKey,
        proxyHost: proxyHost,
        proxyPort: proxyPort,
      );
      if (taggedCandidate != null) {
        final item = _itemFromTMDBCandidate(fallback, taggedCandidate);
        return _itemFromTMDBDetails(item, taggedCandidate);
      }
      final result = await _api!.tmdbSearch(
        searchTitle,
        apiKey: apiKey,
        mediaKind: requestedKind,
        proxyHost: proxyHost,
        proxyPort: proxyPort,
        year: parsed.year,
      );
      final values = result['results'];
      if (values is! List) return fallback;
      final expectedType = requestedKind == 'auto' ? null : requestedKind;
      if (_normalizeMediaTitle(searchTitle).isEmpty) return fallback;
      Map<String, dynamic>? candidate;
      var bestScore = -1;
      for (final value in values) {
        if (value is! Map) continue;
        final map = Map<String, dynamic>.from(value);
        final type = map['media_type']?.toString() ?? expectedType;
        if (type != 'movie' && type != 'tv') continue;
        final releaseDate =
            (map['release_date'] ?? map['first_air_date'])?.toString() ?? '';
        // An explicit year in the file name is authoritative. Do not silently
        // attach a remake or same-title work from a different year.
        if (parsed.year != null && !releaseDate.startsWith('${parsed.year}')) {
          continue;
        }
        final titleMatch = _bestMediaTitleMatch(
          searchTitle,
          title: (map['title'] ?? map['name'] ?? '').toString(),
          originalTitle: (map['original_title'] ?? map['original_name'] ?? '')
              .toString(),
        );
        var score = titleMatch.score;
        if (score == 0) continue;
        if (parsed.year != null && releaseDate.startsWith('${parsed.year}')) {
          score += 30;
        }
        if (score > bestScore) {
          bestScore = score;
          map['media_type'] = type;
          candidate = map;
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

  /// fs_detail/search responses sometimes return only a bare filename. Keep
  /// the persisted parent path in that case so parser rules based on folder
  /// names (for example `2008见龙卸甲/2008.mkv`) still participate in TMDB
  /// recognition.
  CloudFile _withRecognitionPath(CloudFile latest, CloudFile known) {
    final latestParent = _parentDirectoryName(latest.cloudPath);
    final knownParent = _parentDirectoryName(known.cloudPath);
    if (latestParent != null || knownParent == null) return latest;
    return latest.copyWith(cloudPath: '$knownParent/${latest.name}');
  }

  String? _seriesRecognitionKey(MediaLibraryItem item) {
    final parsed = ParsedMediaName.parse(
      item.file.name,
      directoryName: _parentDirectoryName(item.file.cloudPath),
      directoryPath: item.file.cloudPath,
    );
    if (!parsed.isEpisode || parsed.title.trim().isEmpty) return null;
    final parent = item.file.parentID?.trim().isNotEmpty == true
        ? item.file.parentID!
        : _parentDirectoryName(item.file.cloudPath) ?? '';
    if (parent.isEmpty) return null;
    return '${item.libraryID}:$parent:${_normalizeMediaTitle(parsed.title)}';
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
    if (siblings.length <= 1) return;

    final now = DateTime.now();
    final replacements = <String, MediaLibraryItem>{};
    for (final sibling in siblings) {
      replacements['${sibling.libraryID}:${sibling.id}'] =
          sibling.id == matched.id
          ? matched
          : matched.copyWith(
              file: sibling.file,
              // These flags belong to the individual file rather than the
              // show, so retain the sibling's values.
              hasChineseAudio: sibling.hasChineseAudio,
              hasChineseSubtitle: sibling.hasChineseSubtitle,
              updatedAt: now,
            );
    }
    await _replaceItemsByPreviousIDs(replacements);
    _searchResultsCache.clear();
    if (state.selectedLibraryID == matched.libraryID) {
      state = state.copyWith(
        items: state.items
            .map((item) => replacements['${item.libraryID}:${item.id}'] ?? item)
            .toList(),
        allItems: await _loadAllItems(),
      );
    }
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
    // Automatic recognition deliberately uses TMDB multi-search. The
    // filename-derived kind is only a hint and may be wrong for legacy rows.
    final requestedKind = 'auto';
    final searchTitle = parsed.title.trim().isEmpty
        ? fallback.title
        : parsed.title;
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
    final result = await _api!.tmdbSearch(
      searchTitle,
      apiKey: apiKey,
      mediaKind: requestedKind,
      proxyHost: proxyHost,
      proxyPort: proxyPort,
      year: parsed.year,
    );
    final values = result['results'];
    if (values is! List) {
      _appendScanLog(
        '[同步识别][调试] TMDB 原始结果格式异常：查询="$searchTitle"，'
        '类型=$requestedKind，年份参数=${parsed.year?.toString() ?? '未提供'}，'
        'results=${values.runtimeType}',
        isError: true,
      );
      return const [];
    }
    final expectedType = requestedKind == 'auto' ? null : requestedKind;
    if (_normalizeMediaTitle(searchTitle).isEmpty) return const [];
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

    for (final value in values.take(20)) {
      if (value is! Map) continue;
      final candidate = Map<String, dynamic>.from(value);
      final type = candidate['media_type']?.toString() ?? expectedType;
      if (type != 'movie' && type != 'tv') {
        diagnostics.add('${describe(candidate, type)} -> 跳过：类型无效');
        continue;
      }
      final releaseDate =
          (candidate['release_date'] ?? candidate['first_air_date'])
              ?.toString() ??
          '';
      if (parsed.year != null && !releaseDate.startsWith('${parsed.year}')) {
        diagnostics.add('${describe(candidate, type)} -> 跳过：年份不匹配');
        continue;
      }
      final titleMatch = _bestMediaTitleMatch(
        searchTitle,
        title: (candidate['title'] ?? candidate['name'] ?? '').toString(),
        originalTitle:
            (candidate['original_title'] ?? candidate['original_name'] ?? '')
                .toString(),
      );
      var score = titleMatch.score;
      if (score == 0) {
        diagnostics.add('${describe(candidate, type)} -> 跳过：标题不相关');
        continue;
      }
      if (parsed.year != null) score += 30;
      candidate['media_type'] = type;
      scored.add((score: score, candidate: candidate));
      diagnostics.add(
        '${describe(candidate, type)} -> 命中：${titleMatch.basis}，评分=$score',
      );
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    _appendScanLog(
      '[同步识别][调试] TMDB 候选评估：查询="$searchTitle"，'
      '类型=$requestedKind，年份参数=${parsed.year?.toString() ?? '未提供'}，原始 ${values.length} 条，'
      '有效 ${scored.length} 条。${diagnostics.isEmpty ? '无可解析候选' : diagnostics.join('；')}',
    );
    return scored.map((entry) => entry.candidate).toList();
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
    final match = RegExp(
      r'[\[{(（【]\s*tmdb\s*[-_:]?\s*(\d+)\s*[\]})）】]',
      caseSensitive: false,
    ).firstMatch(cloudPath);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  bool _isHighConfidenceTMDBCandidate(
    MediaLibraryItem fallback,
    Map<String, dynamic> candidate,
  ) {
    final parsed = ParsedMediaName.parse(
      fallback.file.name,
      directoryName: _parentDirectoryName(fallback.file.cloudPath),
      directoryPath: fallback.file.cloudPath,
    );
    final expected = parsed.title.trim().isEmpty
        ? fallback.title
        : parsed.title;
    final titleMatch = _bestMediaTitleMatch(
      expected,
      title: (candidate['title'] ?? candidate['name'] ?? '').toString(),
      originalTitle:
          (candidate['original_title'] ?? candidate['original_name'] ?? '')
              .toString(),
    );
    if (titleMatch.score >= 95) return true;

    // Candidate collection has already discarded unrelated titles. When the
    // resource has an explicit year and the best remaining candidate has the
    // same release year, that year is a strong enough disambiguator to apply
    // the match automatically instead of interrupting the scan with a picker.
    final releaseDate =
        (candidate['release_date'] ?? candidate['first_air_date'])
            ?.toString() ??
        '';
    final yearMatches =
        parsed.year != null && releaseDate.startsWith('${parsed.year}');
    return yearMatches && titleMatch.score > 0;
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
    } catch (_) {
      // The selected search candidate remains usable when detail hydration fails.
    }
    return item;
  }

  Future<MediaLibraryItem> _renameMatchedMediaFile(
    MediaLibraryItem item, {
    int? manualSeason,
    int? manualEpisode,
  }) async {
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
    final year = item.year.isEmpty ? '' : '.${item.year}';
    final episode = item.mediaKind == TMDBMediaKind.tv && parsed.isEpisode
        ? '.S${parsed.season!.toString().padLeft(2, '0')}E${parsed.episode!.toString().padLeft(2, '0')}'
        : '';
    final technical = <String>[
      if (parsed.resolution?.isNotEmpty == true) parsed.resolution!,
      if (parsed.source?.isNotEmpty == true) parsed.source!,
      if (parsed.dynamicRange?.isNotEmpty == true) parsed.dynamicRange!,
      if (parsed.videoCodec?.isNotEmpty == true) parsed.videoCodec!,
      if (parsed.audio?.isNotEmpty == true) parsed.audio!,
    ].join('.');
    // Keep every recognized technical tag when it is present, but a successful
    // TMDB match must also repair bare or otherwise irregular names such as
    // `1989.mp4`: `福星闯江湖.1989.mp4` is still a useful canonical name even
    // when the source provides no resolution or release information.
    final baseName = '${item.title}$year$episode';
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
      final updated = item.copyWith(file: renamedFile);
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

  String _cloudPathWithName(String cloudPath, String name) {
    final parentPath = _parentPath(cloudPath);
    return parentPath.isEmpty ? name : '$parentPath/$name';
  }

  /// Compares titles progressively. Literal text remains the strongest signal;
  /// punctuation and connector normalization only provide a fallback for
  /// release names that differ from TMDB's original title.
  ({int score, String basis}) _bestMediaTitleMatch(
    String expected, {
    required String title,
    required String originalTitle,
  }) {
    final displayMatch = _mediaTitleMatch(expected, title);
    final originalMatch = _mediaTitleMatch(expected, originalTitle);
    if (originalMatch.score > displayMatch.score) {
      return (score: originalMatch.score, basis: '原名${originalMatch.basis}');
    }
    return (score: displayMatch.score, basis: '标题${displayMatch.basis}');
  }

  ({int score, String basis}) _mediaTitleMatch(
    String expected,
    String candidate,
  ) {
    final literalExpected = _literalMediaTitle(expected);
    final literalCandidate = _literalMediaTitle(candidate);
    if (literalExpected.isEmpty || literalCandidate.isEmpty) {
      return (score: 0, basis: '');
    }
    if (literalExpected == literalCandidate) {
      return (score: 120, basis: '原样一致');
    }

    final compactExpected = _normalizeMediaTitle(expected);
    final compactCandidate = _normalizeMediaTitle(candidate);
    if (compactExpected == compactCandidate) {
      return (score: 100, basis: '标点归一一致');
    }

    final semanticExpected = _semanticMediaTitle(expected);
    final semanticCandidate = _semanticMediaTitle(candidate);
    if (semanticExpected == semanticCandidate) {
      return (score: 95, basis: '连接符归一一致');
    }

    if (_containsRelatedTitle(literalExpected, literalCandidate)) {
      return (score: 55, basis: '原样包含');
    }
    if (_containsRelatedTitle(compactExpected, compactCandidate)) {
      return (score: 48, basis: '标点归一包含');
    }
    if (_containsRelatedTitle(semanticExpected, semanticCandidate)) {
      return (score: 45, basis: '连接符归一包含');
    }
    return (score: 0, basis: '');
  }

  bool _containsRelatedTitle(String first, String second) {
    if (first.length < 4 || second.length < 4) return false;
    return first.contains(second) || second.contains(first);
  }

  String _literalMediaTitle(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r"[‘’`´]"), "'")
        .replaceAll(RegExp(r'[‐‑‒–—―]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _normalizeMediaTitle(String value) {
    return _literalMediaTitle(
      value,
    ).replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]+'), '');
  }

  String _semanticMediaTitle(String value) {
    return _normalizeMediaTitle(
      value.replaceAll('&', ' and ').replaceAll('＆', ' and '),
    );
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
      // A manual selection is authoritative. In particular, do not retain an
      // earlier filename-based guess when the selected TMDB result says this
      // is a movie or a TV series. Keep the existing value only for malformed
      // legacy candidates that do not contain a media type at all.
      mediaKind: type == 'tv'
          ? TMDBMediaKind.tv
          : type == 'movie'
          ? TMDBMediaKind.movie
          : fallback.mediaKind,
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

  Future<List<CloudFile>> _scanLibrarySourcesConcurrently(
    MediaLibraryDefinition library, {
    required int concurrency,
    required Future<void> Function(List<CloudFile> files) onMediaFiles,
  }) async {
    final folders = [
      for (final source in library.sources)
        _ScanFolder(source.rootID, source.path),
    ];
    final visited = <String>{};
    final mediaFiles = <String, CloudFile>{};
    var nextFolder = 0;

    while (nextFolder < folders.length && !_cancelScan) {
      final batch = <_ScanFolder>[];
      while (nextFolder < folders.length && batch.length < concurrency) {
        final folder = folders[nextFolder++];
        if (isMediaScanDiscInternalPath(folder.path)) {
          _appendScanLog('跳过光盘目录内部文件：${folder.path}');
          continue;
        }
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
          if (_cancelScan) return const <CloudFile>[];
          final files = await _loadCloudIndexFolder(
            _CloudIndexFolder(folder.id, folder.path),
          );
          if (_cancelScan) return const <CloudFile>[];
          return _enrichAndCacheFiles(files, concurrency: detailConcurrency);
        },
      );
      if (_cancelScan) break;
      await FileMetadataCache.cacheFolderChildrenBatch({
        for (var index = 0; index < batch.length; index++)
          batch[index].id: snapshots[index],
      });

      for (var index = 0; index < batch.length; index++) {
        final folder = batch[index];
        final files = snapshots[index];
        final isDiscRoot = isMediaScanDiscLayout(files);
        final discoveredBatch = <CloudFile>[];
        for (final file in files) {
          final path = folder.path.endsWith('/')
              ? '${folder.path}${file.name}'
              : '${folder.path}/${file.name}';
          if (file.isDirectory) {
            if (library.recursive && !isDiscRoot) {
              folders.add(_ScanFolder(file.id, path));
            }
            continue;
          }
          if (file.isVideo &&
              (file.size ?? 0) >= library.minimumSizeMB * 1024 * 1024 &&
              !isMediaScanDiscInternalPath(path)) {
            final mediaFile = _withPath(file, path);
            if (!mediaFiles.containsKey(file.id)) {
              mediaFiles[file.id] = mediaFile;
              discoveredBatch.add(mediaFile);
            }
          }
        }
        if (discoveredBatch.isNotEmpty) {
          await onMediaFiles(discoveredBatch);
        }
      }
      state = state.copyWith(
        progress: MediaLibraryScanProgress(
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

  Future<void> _scanSource(
    String? rootID,
    String rootPath, {
    required bool recursive,
    required int minimumSizeBytes,
    required bool forceRemote,
    required int initialCompleted,
    required Future<void> Function(List<CloudFile> files) onMediaFiles,
  }) async {
    final folders = <_ScanFolder>[_ScanFolder(rootID, rootPath)];
    final visited = <String>{};
    var discovered = 0;

    while (folders.isNotEmpty && !_cancelScan) {
      final folder = folders.removeAt(0);
      final visitKey = folder.id ?? 'root';
      if (!visited.add(visitKey)) continue;
      // A library source can point at BDMV/VIDEO_TS directly. There is no
      // parent disc folder to inspect in that case, so skip it before listing
      // and scraping its internal transport streams.
      if (isMediaScanDiscInternalPath(folder.path)) {
        _appendScanLog('跳过光盘目录内部文件：${folder.path}');
        continue;
      }

      var page = 0;
      final cachedFolder = forceRemote
          ? null
          : await FileMetadataCache.folderChildren(folder.id);
      final folderSnapshot = <CloudFile>[];
      if (cachedFolder != null) {
        final cacheLabel = '正在从目录缓存读取 ${folder.path}';
        state = state.copyWith(
          progress: MediaLibraryScanProgress(
            phase: cacheLabel,
            completed: initialCompleted + discovered,
          ),
        );
        _appendScanLog(cacheLabel);
      }
      while (!_cancelScan) {
        late List<CloudFile> files;
        if (cachedFolder != null) {
          files = cachedFolder;
        } else {
          final pageLabel = '正在读取目录 ${folder.path}，第 ${page + 1} 页';
          state = state.copyWith(
            progress: MediaLibraryScanProgress(
              phase: pageLabel,
              completed: initialCompleted + discovered,
            ),
          );
          _appendScanLog(pageLabel);
          AppLogger.info('Media', '正在读取目录「${folder.path}」第 ${page + 1} 页');
          final response = await _api!.fsFiles(
            parentID: folder.id,
            page: page,
            pageSize: 200,
            orderBy: 0,
            sortType: 0,
          );
          if (_cancelScan) break;
          files = _extractFiles(response);
          AppLogger.info(
            'Media',
            '目录「${folder.path}」第 ${page + 1} 页读取完成，获取 ${files.length} 项',
          );
          files = await _enrichAndCacheFiles(files);
          if (_cancelScan) break;
          folderSnapshot.addAll(files);
        }
        // A folder containing BDMV or VIDEO_TS is a disc root. Do not descend
        // into any of its children: BDMV/STREAM and VIDEO_TS files are segments
        // of one work, not separately scrapeable media files.
        final isDiscRoot = isMediaScanDiscLayout(files);
        final mediaBatch = <CloudFile>[];
        for (final file in files) {
          if (file.isDirectory) {
            if (recursive && !isDiscRoot) {
              final childPath = '${folder.path}/${file.name}';
              if (!isMediaScanDiscInternalPath(childPath)) {
                folders.add(_ScanFolder(file.id, childPath));
              }
            }
          } else if (file.isVideo && (file.size ?? 0) >= minimumSizeBytes) {
            mediaBatch.add(_withPath(file, '${folder.path}/${file.name}'));
          }
        }
        discovered += mediaBatch.length;
        _appendScanLog(
          '目录 ${folder.path} 第 ${page + 1} 页完成，发现 ${mediaBatch.length} 个媒体文件，累计 ${initialCompleted + discovered} 个',
        );
        if (mediaBatch.isNotEmpty) {
          await onMediaFiles(mediaBatch);
          if (_cancelScan) break;
        }

        state = state.copyWith(
          progress: MediaLibraryScanProgress(
            phase: '已读取 ${folder.path}，正在识别与刮削',
            completed: initialCompleted + discovered,
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

  Future<List<CloudFile>> _enrichAndCacheFiles(
    List<CloudFile> files, {
    int concurrency = 6,
  }) async {
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
      while (!_cancelScan && next < pending.length) {
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

    await Future.wait(List.generate(concurrency, (_) => worker()));
    if (_cancelScan) return resolved;
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

  Future<CloudFile?> _resolveCurrentCloudFile(
    CloudFile knownFile, {
    String? libraryID,
    void Function()? onConfirmedNotFound,
  }) async {
    var confirmedNotFound = false;
    var remoteFallbackCompleted = false;
    var gcidIndexExhausted = false;
    try {
      final detail = await _api!.fsDetail(knownFile.id);
      final current = _fileFromDetail(detail, knownFile.id, knownFile);
      if (current != null) {
        return _cacheResolvedCloudFile(knownFile, current);
      }
      confirmedNotFound = true;
      _appendScanLog('[同步识别][调试] 旧文件 ID 返回空详情，确认资源不存在：${knownFile.id}');
    } catch (error) {
      confirmedNotFound = isConfirmedCloudFileMissingError(error);
      // A rename can replace the cloud record. Locate its new ID below.
      _appendScanLog('[同步识别][调试] 旧文件 ID 查询失败：${knownFile.id}，$error；开始回退定位');
    }

    final cached = await FileMetadataCache.file(knownFile.id);
    final parentID = knownFile.parentID ?? cached?.parentID;
    final gcid = knownFile.gcid?.trim();
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
          confirmedNotFound = true;
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
        confirmedNotFound = true;
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
        } catch (_) {
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
    if (!confirmedNotFound && gcidIndexExhausted && remoteFallbackCompleted) {
      confirmedNotFound = true;
      _appendScanLog('[同步识别][调试] 实时 GCID 索引与远端文件搜索均未命中，确认资源已不存在');
    }
    _appendScanLog(
      '[同步识别][调试] 未定位到当前文件目录中的 GCID；停止自动查找，建议重新扫描媒体库',
      isError: true,
    );
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
        final exact = _withPath(resolved, '$parentPath/${resolved.name}');
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
    final parentPath = _parentPath(knownFile.cloudPath);
    final file = knownFile.copyWith(
      id: resolved.id,
      name: resolved.name,
      size: resolved.size,
      gcid: resolved.gcid,
      modifiedAt: resolved.modifiedAt,
      cloudPath:
          cloudPath ??
          (parentPath.isEmpty ? resolved.name : '$parentPath/${resolved.name}'),
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
          _findStringDeep(exact, const ['fileName', 'name', 'resName']) ??
          fallback.name,
      gcid: _findStringDeep(exact, const ['gcid', 'gcId', 'gcidValue', 'hash']),
      size: _findIntDeep(exact, const [
        'size',
        'fileSize',
        'resSize',
        'totalSize',
      ]),
      parentID: _findStringDeep(exact, const [
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

  Future<void> _replaceItemsByPreviousIDs(
    Map<String, MediaLibraryItem> replacements,
  ) async {
    if (replacements.isEmpty) return;
    final allItems = await _loadAllItems();
    final replacementIDs = replacements.values
        .map((item) => '${item.libraryID}:${item.id}')
        .toSet();
    allItems.removeWhere((item) {
      final key = '${item.libraryID}:${item.id}';
      return replacements.containsKey(key) || replacementIDs.contains(key);
    });
    allItems.addAll(replacements.values);
    await _saveAllItems(allItems);
  }

  Future<void> _removeMissingMediaItems(
    Iterable<MediaLibraryItem> values,
  ) async {
    final keys = values.map((item) => '${item.libraryID}:${item.id}').toSet();
    if (keys.isEmpty) return;
    final fileIDs = values.map((item) => item.id).toSet();
    final allItems = await _loadAllItems()
      ..removeWhere((item) => keys.contains('${item.libraryID}:${item.id}'));
    await _saveAllItems(allItems);
    await FileMetadataCache.removeFilesFromAllFolders(fileIDs);
    await FileMetadataCache.removeLiveFileIDs(fileIDs);
    await _removeWatchHistory?.call(fileIDs);
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
    final retained = items
        .where((item) => !isMediaScanDiscInternalPath(item.file.cloudPath))
        .toList();
    final removed = items.length - retained.length;
    if (removed > 0) await _saveAllItems(retained);
    return removed;
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
