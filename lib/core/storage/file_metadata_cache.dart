import 'dart:async';

import '../../models/cloud_file.dart';
import 'media_library_store.dart';

/// File metadata indexes live in the same SQLite database as scraped media.
class FileMetadataCache {
  static final _store = MediaLibraryStore();
  static Future<void> _writeTail = Future<void>.value();

  static Future<void> _enqueueWrite(Future<void> Function() operation) {
    final next = _writeTail.then(
      (_) => operation(),
      onError: (_, __) => operation(),
    );
    _writeTail = next.then<void>((_) {}, onError: (_, __) {});
    return next;
  }

  static Future<Map<String, String>> gcidsByFileIDs(Iterable<String> fileIDs) =>
      _store.gcidsByFileIDs(fileIDs);

  static Future<void> cacheFolderChildren(
    String? folderID,
    List<CloudFile> files,
  ) => _enqueueWrite(() => _store.cacheFolderChildren(folderID, files));

  static Future<void> cacheFiles(List<CloudFile> files) =>
      _enqueueWrite(() => _store.cacheFiles(files));

  static Future<void> cacheResourceMetadata(Iterable<CloudFile> files) =>
      _enqueueWrite(() => _store.cacheResourceMetadata(files));

  static Future<void> cacheFolderChildrenBatch(
    Map<String?, List<CloudFile>> folders,
  ) => _enqueueWrite(() => _store.cacheFolderChildrenBatch(folders));

  static Future<void> clearFolderChildrenIndex() =>
      _enqueueWrite(_store.clearFolderChildrenIndex);

  static Future<void> removeFolderChildrenSubtrees(
    Iterable<String> folderIDs,
  ) => _enqueueWrite(() => _store.removeFolderChildrenSubtrees(folderIDs));

  static Future<void> removeMissingFolderSubtrees(Iterable<String> folderIDs) {
    final ids = folderIDs.where((id) => id.isNotEmpty).toSet();
    if (ids.isEmpty) return Future<void>.value();
    return _enqueueWrite(() async {
      await _store.removeFilesAllFoldersAndUpdateParent(ids, null);
      await _store.removeFolderChildrenSubtrees(ids);
    });
  }

  static Future<List<CloudFile>?> folderChildren(String? folderID) =>
      _store.folderChildren(folderID);

  static Future<List<CloudFile>?> folderChildrenForScan(String? folderID) =>
      _store.folderChildrenForScan(folderID);

  static Future<List<CloudFile>> allCachedFolderChildren() =>
      _store.allCachedFolderChildren();

  static Future<List<CloudFile>> searchCachedDirectories(
    String query, {
    int limit = 200,
  }) => _store.searchCachedDirectories(query, limit: limit);

  /// Loads the complete directory snapshot index in one SQLite read.
  ///
  /// The null key represents the cloud root. Empty directories are retained
  /// as empty lists, which is required by the empty-folder scanner.
  static Future<Map<String?, List<CloudFile>>> allFolderChildrenSnapshots() =>
      _store.allFolderChildrenSnapshots();

  static Future<void> allCachedFolderChildrenBatched(
    Future<void> Function(List<CloudFile> batch) onBatch, {
    int batchSize = 500,
  }) => _store.allCachedFolderChildrenBatched(onBatch, batchSize: batchSize);

  static Future<void> folderChildrenSnapshotsBatched(
    Future<void> Function(Map<String?, List<CloudFile>> batch) onBatch, {
    int batchSize = 250,
  }) => _store.folderChildrenSnapshotsBatched(onBatch, batchSize: batchSize);

  static Future<List<CloudFile>?> siblingFiles(String fileID) =>
      _store.siblingFiles(fileID);

  static Future<String?> parentFolderID(String fileID) =>
      _store.parentFolderID(fileID);

  static Future<CloudFile?> file(String fileID) => _store.cachedFile(fileID);

  /// Batch lookup that also resolves directories (no gcid required).
  static Future<Map<String, CloudFile>> filesByIDs(Iterable<String> fileIDs) =>
      _store.cachedFilesByIDs(fileIDs);

  static Future<Map<String, List<CloudFile>>> liveFilesByGCIDs(
    Iterable<String> gcids,
  ) => _store.liveFilesByGCIDs(gcids);

  static Future<void> removeLiveFileIDs(Iterable<String> fileIDs) =>
      _enqueueWrite(() => _store.removeLiveFileIDs(fileIDs));

  static Future<void> updateFolderChildren(
    String? folderID, {
    Iterable<String> removeIDs = const [],
    Iterable<CloudFile> addOrReplace = const [],
    bool invalidate = false,
  }) => _enqueueWrite(
    () => _store.updateFolderChildren(
      folderID,
      removeIDs: removeIDs,
      addOrReplace: addOrReplace,
      invalidate: invalidate,
    ),
  );

  static Future<void> removeFilesFromAllFolders(Iterable<String> fileIDs) =>
      _enqueueWrite(() => _store.removeFilesFromAllFolders(fileIDs));

  /// Atomically removes [fileIDs] from all folders and updates the parent
  /// folder's children list in a single database transaction.
  static Future<void> removeFilesAllFoldersAndUpdateParent(
    Iterable<String> fileIDs,
    String? parentID,
  ) => _enqueueWrite(
    () => _store.removeFilesAllFoldersAndUpdateParent(fileIDs, parentID),
  );
}
