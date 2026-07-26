import 'dart:async';

import '../../api/guangya_api.dart';
import '../../models/cloud_file.dart';
import '../logging/app_logger.dart';
import '../storage/file_metadata_cache.dart';

/// Fills in the per-folder child counts that the file *list* endpoint omits.
///
/// `get_file_list` returns only the basic fields, so `subDirCount` /
/// `subFileCount` arrive as null and folder rows cannot show "N 个文件夹，M 个文件".
/// Those numbers live in `sizeInfo` on the `get_file_detail` response, which is
/// a per-file call — so they are fetched lazily, in the background, only for the
/// folders currently on screen.
///
/// Results are memoised process-wide: revisiting a directory or re-rendering a
/// column costs no extra requests.
class FolderStatsLoader {
  FolderStatsLoader._();

  static final instance = FolderStatsLoader._();

  /// Resolved stats, keyed by file id.
  final _cache = <String, _FolderStats>{};

  /// In-flight requests, so concurrent callers share one round-trip per folder.
  final _inFlight = <String, Future<_FolderStats?>>{};

  /// Folders that answered without usable counts; not worth asking again.
  final _unavailable = <String>{};

  /// Maximum number of detail requests issued at once.
  static const _concurrency = 5;

  /// Returns [files] with folder statistics applied where already known.
  /// Purely synchronous — safe to call while building a widget tree.
  List<CloudFile> applyCached(List<CloudFile> files) {
    if (_cache.isEmpty) return files;
    var changed = false;
    final result = [
      for (final file in files)
        () {
          if (!file.isDirectory) return file;
          final stats = _cache[file.id];
          if (stats == null || !stats.improves(file)) return file;
          changed = true;
          return stats.applyTo(file);
        }(),
    ];
    return changed ? result : files;
  }

  /// Fetches missing statistics for the folders in [files].
  ///
  /// [onUpdated] receives the enriched list as batches complete, so early rows
  /// fill in without waiting for the whole column. Returns once every folder
  /// has been resolved or skipped.
  ///
  /// [parentID] identifies the folder listing being displayed, so the resolved
  /// counts can be written back into its cached snapshot.
  ///
  /// [visibleIDs], when given, restricts network requests to those rows — the
  /// caller passes the ids currently scrolled into view. Anything outside stays
  /// untouched until it becomes visible, which keeps a 200-item directory from
  /// firing 200 detail requests on open. The persistent cache is still consulted
  /// for *every* row, since that costs one local query for the whole batch.
  Future<void> hydrate(
    List<CloudFile> files, {
    required GuangyaAPI api,
    required void Function(List<CloudFile> files) onUpdated,
    String? parentID,
    Set<String>? visibleIDs,
    bool Function()? isCancelled,
  }) async {
    final pending = <CloudFile>[
      for (final file in files)
        if (file.isDirectory &&
            file.subDirectoryCount == null &&
            file.subFileCount == null &&
            !_cache.containsKey(file.id) &&
            !_unavailable.contains(file.id))
          file,
    ];
    if (pending.isEmpty) return;

    // Persistent cache first: folder_children snapshots already carry these
    // counts, so a previously visited directory costs no network at all —
    // even across restarts.
    final persisted = await FileMetadataCache.filesByIDs(
      pending.map((file) => file.id),
    );
    var restored = 0;
    for (final file in pending) {
      final cached = persisted[file.id];
      if (cached == null) continue;
      final stats = _FolderStats(
        subDirectoryCount: cached.subDirectoryCount,
        subFileCount: cached.subFileCount,
        size: cached.size,
      );
      if (stats.isEmpty) continue;
      _cache[file.id] = stats;
      restored += 1;
    }
    if (restored > 0 && !(isCancelled?.call() ?? false)) {
      onUpdated(applyCached(files));
    }
    pending.removeWhere((file) => _cache.containsKey(file.id));
    // Only rows the user can actually see are worth a network round-trip.
    if (visibleIDs != null) {
      pending.removeWhere((file) => !visibleIDs.contains(file.id));
    }
    if (pending.isEmpty) return;

    var next = 0;
    var resolvedSinceFlush = 0;

    void flush() {
      if (resolvedSinceFlush == 0) return;
      resolvedSinceFlush = 0;
      if (isCancelled?.call() ?? false) return;
      onUpdated(applyCached(files));
    }

    Future<void> worker() async {
      while (true) {
        if (isCancelled?.call() ?? false) return;
        // Claim the index synchronously so two workers never take the same
        // slot across the await below.
        if (next >= pending.length) return;
        final file = pending[next++];
        final stats = await _fetch(file.id, api);
        if (stats != null) resolvedSinceFlush += 1;
        if (resolvedSinceFlush >= 4) flush();
      }
    }

    final workerCount = pending.length < _concurrency
        ? pending.length
        : _concurrency;
    await Future.wait(List.generate(workerCount, (_) => worker()));
    flush();

    // Write the enriched rows back into the folder snapshot so the counts
    // survive a restart and other views pick them up for free.
    if (!(isCancelled?.call() ?? false)) {
      unawaited(_persist(files, parentID: parentID));
    }
  }

  /// Updates the cached folder listing with the statistics resolved above.
  Future<void> _persist(
    List<CloudFile> files, {
    required String? parentID,
  }) async {
    final enriched = [
      for (final file in applyCached(files))
        if (file.isDirectory &&
            (file.subDirectoryCount != null || file.subFileCount != null))
          file,
    ];
    if (enriched.isEmpty) return;
    try {
      await FileMetadataCache.updateFolderChildren(
        parentID,
        addOrReplace: enriched,
      );
    } catch (error) {
      AppLogger.debug('Files', '目录统计写回缓存失败：$error');
    }
  }

  Future<_FolderStats?> _fetch(String fileID, GuangyaAPI api) {
    final cached = _cache[fileID];
    if (cached != null) return Future.value(cached);
    final existing = _inFlight[fileID];
    if (existing != null) return existing;

    final request = () async {
      try {
        final response = await api.fsDetail(fileID);
        final stats = _FolderStats.fromDetailResponse(response);
        if (stats == null) {
          _unavailable.add(fileID);
          return null;
        }
        _cache[fileID] = stats;
        return stats;
      } catch (error) {
        // A folder that fails to report its size must not break the listing.
        AppLogger.debug('Files', '目录统计获取失败：$fileID，$error');
        _unavailable.add(fileID);
        return null;
      } finally {
        _inFlight.remove(fileID);
      }
    }();
    _inFlight[fileID] = request;
    return request;
  }

  /// Drops memoised data for one folder, e.g. after its contents change.
  void invalidate(String fileID) {
    _cache.remove(fileID);
    _unavailable.remove(fileID);
  }

  void clear() {
    _cache.clear();
    _unavailable.clear();
  }

  /// True when [fileID] already has statistics available synchronously.
  bool isResolved(String fileID) => _cache.containsKey(fileID);
}

/// Collects the rows a lazy list has built and hydrates them in debounced
/// batches.
///
/// `ListView.builder` only calls `itemBuilder` for items near the viewport, so
/// reporting from there is an accurate and cheap visibility signal — no
/// scroll-offset maths or extra observer widgets required. Requests are
/// debounced so a fast scroll through a long directory does not queue a
/// round-trip for every row that flashes past.
class VisibleFolderStatsTracker {
  final GuangyaAPI Function() _api;
  final void Function(List<CloudFile> files) _onUpdated;
  final List<CloudFile> Function() _currentFiles;
  final String? Function() _parentID;
  final bool Function() _isCancelled;
  final Duration _debounce;

  final _requested = <String>{};
  Timer? _timer;
  var _disposed = false;

  VisibleFolderStatsTracker({
    required GuangyaAPI Function() api,
    required List<CloudFile> Function() currentFiles,
    required void Function(List<CloudFile> files) onUpdated,
    String? Function()? parentID,
    bool Function()? isCancelled,
    Duration debounce = const Duration(milliseconds: 250),
  }) : _api = api,
       _currentFiles = currentFiles,
       _onUpdated = onUpdated,
       _parentID = parentID ?? (() => null),
       _isCancelled = isCancelled ?? (() => false),
       _debounce = debounce;

  /// Reports that [file] was just built by the list, i.e. it is on or near
  /// screen. Safe to call from `itemBuilder`.
  void onItemBuilt(CloudFile file) {
    if (_disposed || !file.isDirectory) return;
    if (file.subDirectoryCount != null || file.subFileCount != null) return;
    if (FolderStatsLoader.instance.isResolved(file.id)) return;
    if (!_requested.add(file.id)) return;
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(_debounce, _flush);
  }

  void _flush() {
    if (_disposed || _requested.isEmpty) return;
    final batch = _requested.toSet();
    _requested.clear();
    final files = _currentFiles();
    if (files.isEmpty) return;
    unawaited(
      FolderStatsLoader.instance.hydrate(
        files,
        api: _api(),
        parentID: _parentID(),
        visibleIDs: batch,
        isCancelled: () => _disposed || _isCancelled(),
        onUpdated: _onUpdated,
      ),
    );
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _requested.clear();
  }
}

class _FolderStats {
  final int? subDirectoryCount;
  final int? subFileCount;
  final int? size;

  const _FolderStats({this.subDirectoryCount, this.subFileCount, this.size});

  bool get isEmpty =>
      subDirectoryCount == null && subFileCount == null && size == null;

  /// True when these stats add something the listing row does not already have.
  bool improves(CloudFile file) {
    if (subDirectoryCount != null && file.subDirectoryCount == null) {
      return true;
    }
    if (subFileCount != null && file.subFileCount == null) return true;
    if (size != null && (file.size == null || file.size == 0)) return true;
    return false;
  }

  CloudFile applyTo(CloudFile file) => file.copyWith(
    subDirectoryCount: subDirectoryCount ?? file.subDirectoryCount,
    subFileCount: subFileCount ?? file.subFileCount,
    size: (file.size == null || file.size == 0) ? size : file.size,
  );

  /// Reads `data.sizeInfo` from a `get_file_detail` payload.
  ///
  /// The envelope is walked defensively because the field has appeared at
  /// different nesting depths across API revisions.
  static _FolderStats? fromDetailResponse(Map<String, dynamic> response) {
    Map<String, dynamic>? sizeInfo;

    void visit(dynamic node) {
      if (sizeInfo != null) return;
      if (node is Map) {
        final candidate = node['sizeInfo'] ?? node['size_info'];
        if (candidate is Map) {
          sizeInfo = Map<String, dynamic>.from(candidate);
          return;
        }
        for (final child in node.values) {
          visit(child);
        }
      } else if (node is List) {
        for (final child in node) {
          visit(child);
        }
      }
    }

    visit(response);
    final info = sizeInfo;
    if (info == null) return null;

    int? readInt(List<String> keys) {
      for (final key in keys) {
        final value = info[key];
        if (value is int) return value;
        if (value is num) return value.toInt();
        final parsed = int.tryParse(value?.toString() ?? '');
        if (parsed != null) return parsed;
      }
      return null;
    }

    final stats = _FolderStats(
      subDirectoryCount: readInt(['subDirCount', 'subDirectoryCount']),
      subFileCount: readInt(['subFileCount', 'subFileNum']),
      size: readInt(['size', 'totalSize']),
    );
    return stats.isEmpty ? null : stats;
  }
}
