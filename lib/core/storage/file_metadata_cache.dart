import '../../models/cloud_file.dart';
import 'media_library_store.dart';

/// File metadata indexes live in the same SQLite database as scraped media.
class FileMetadataCache {
  static final _store = MediaLibraryStore();

  static Future<void> cacheFolderChildren(
    String? folderID,
    List<CloudFile> files,
  ) => _store.cacheFolderChildren(folderID, files);

  static Future<void> cacheFiles(List<CloudFile> files) =>
      _store.cacheFiles(files);

  static Future<void> cacheFolderChildrenBatch(
    Map<String?, List<CloudFile>> folders,
  ) => _store.cacheFolderChildrenBatch(folders);

  static Future<List<CloudFile>?> folderChildren(String? folderID) =>
      _store.folderChildren(folderID);

  static Future<List<CloudFile>> allCachedFolderChildren() =>
      _store.allCachedFolderChildren();

  static Future<List<CloudFile>?> siblingFiles(String fileID) =>
      _store.siblingFiles(fileID);

  static Future<CloudFile?> file(String fileID) => _store.cachedFile(fileID);

  static Future<void> updateFolderChildren(
    String? folderID, {
    Iterable<String> removeIDs = const [],
    Iterable<CloudFile> addOrReplace = const [],
    bool invalidate = false,
  }) => _store.updateFolderChildren(
    folderID,
    removeIDs: removeIDs,
    addOrReplace: addOrReplace,
    invalidate: invalidate,
  );

  static Future<void> removeFilesFromAllFolders(Iterable<String> fileIDs) =>
      _store.removeFilesFromAllFolders(fileIDs);
}
