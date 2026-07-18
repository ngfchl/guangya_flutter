import '../../models/cloud_file.dart';
import 'storage_manager.dart';

/// Permanent cloud-file indexes used by the workspace and media scanner.
///
/// Folder records retain ordered child IDs as their index; the snapshots make
/// an offline scan possible before the server needs to be consulted again.
class FileMetadataCache {
  static const _rootFolderID = '@root';
  static Future<void> _writes = Future.value();

  static String _folderKey(String? folderID) => folderID ?? _rootFolderID;

  static Future<void> cacheFolderChildren(
    String? folderID,
    List<CloudFile> files,
  ) {
    return _enqueue(() async {
      final folders = _map(StorageKeys.folderChildrenIndex);
      final fileIndex = _map(StorageKeys.fileGcidIndex);
      final details = _map(StorageKeys.gcidDetails);
      folders[_folderKey(folderID)] = {
        'childIds': files.map((file) => file.id).toList(),
        'children': files.map((file) => file.toJson()).toList(),
      };
      _indexFiles(files, fileIndex, details);
      await StorageManager.set(StorageKeys.folderChildrenIndex, folders);
      await StorageManager.set(StorageKeys.fileGcidIndex, fileIndex);
      await StorageManager.set(StorageKeys.gcidDetails, details);
    });
  }

  static Future<void> cacheFiles(List<CloudFile> files) {
    return _enqueue(() async {
      final fileIndex = _map(StorageKeys.fileGcidIndex);
      final details = _map(StorageKeys.gcidDetails);
      _indexFiles(files, fileIndex, details);
      await StorageManager.set(StorageKeys.fileGcidIndex, fileIndex);
      await StorageManager.set(StorageKeys.gcidDetails, details);
    });
  }

  static Future<void> updateFolderChildren(
    String? folderID, {
    Iterable<String> removeIDs = const [],
    Iterable<CloudFile> addOrReplace = const [],
    bool invalidate = false,
  }) {
    return _enqueue(() async {
      final folders = _map(StorageKeys.folderChildrenIndex);
      final key = _folderKey(folderID);
      if (invalidate) {
        folders.remove(key);
        await StorageManager.set(StorageKeys.folderChildrenIndex, folders);
        return;
      }
      final entry = folders[key];
      if (entry is! Map || entry['children'] is! List) return;
      final removed = removeIDs.toSet();
      final children = (entry['children'] as List)
          .whereType<Map>()
          .map((value) => CloudFile.fromJson(Map<String, dynamic>.from(value)))
          .where((file) => !removed.contains(file.id))
          .toList();
      final replacement = {for (final file in addOrReplace) file.id: file};
      children.removeWhere((file) => replacement.containsKey(file.id));
      children.addAll(replacement.values);
      folders[key] = {
        'childIds': children.map((file) => file.id).toList(),
        'children': children.map((file) => file.toJson()).toList(),
      };
      final fileIndex = _map(StorageKeys.fileGcidIndex);
      final details = _map(StorageKeys.gcidDetails);
      _indexFiles(replacement.values.toList(), fileIndex, details);
      await StorageManager.set(StorageKeys.folderChildrenIndex, folders);
      await StorageManager.set(StorageKeys.fileGcidIndex, fileIndex);
      await StorageManager.set(StorageKeys.gcidDetails, details);
    });
  }

  static Future<void> removeFilesFromAllFolders(Iterable<String> fileIDs) {
    final removed = fileIDs.toSet();
    if (removed.isEmpty) return Future.value();
    return _enqueue(() async {
      final folders = _map(StorageKeys.folderChildrenIndex);
      for (final entry in folders.entries.toList()) {
        final snapshot = entry.value;
        if (snapshot is! Map || snapshot['children'] is! List) continue;
        final children = (snapshot['children'] as List)
            .whereType<Map>()
            .where((child) => !removed.contains(_fileID(child)))
            .toList();
        final original = snapshot['children'] as List;
        if (children.length == original.length) continue;
        folders[entry.key] = {
          'childIds': children.map(_fileID).whereType<String>().toList(),
          'children': children,
        };
      }
      await StorageManager.set(StorageKeys.folderChildrenIndex, folders);
    });
  }

  static List<CloudFile>? folderChildren(String? folderID) {
    final folders = _map(StorageKeys.folderChildrenIndex);
    final entry = folders[_folderKey(folderID)];
    if (entry is! Map || entry['children'] is! List) return null;
    try {
      return (entry['children'] as List)
          .whereType<Map>()
          .map((value) => CloudFile.fromJson(Map<String, dynamic>.from(value)))
          .toList();
    } catch (_) {
      return null;
    }
  }

  static CloudFile? file(String fileID) {
    final fileIndex = _map(StorageKeys.fileGcidIndex);
    final gcid = fileIndex[fileID]?.toString();
    if (gcid == null || gcid.isEmpty) return null;
    final details = _map(StorageKeys.gcidDetails);
    final value = details[gcid];
    if (value is! Map) return null;
    try {
      return CloudFile.fromJson(Map<String, dynamic>.from(value));
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> _map(String key) {
    final raw = StorageManager.get<dynamic>(key);
    if (raw is! Map) return <String, dynamic>{};
    return raw.map((mapKey, value) => MapEntry(mapKey.toString(), value));
  }

  static void _indexFiles(
    List<CloudFile> files,
    Map<String, dynamic> fileIndex,
    Map<String, dynamic> details,
  ) {
    for (final file in files) {
      final gcid = file.gcid?.trim();
      if (gcid == null || gcid.isEmpty) continue;
      fileIndex[file.id] = gcid;
      details[gcid] = file.toJson();
    }
  }

  static String? _fileID(Map value) {
    for (final key in const ['id', 'fileId', 'file_id', 'resId', 'res_id']) {
      final candidate = value[key];
      if (candidate != null && candidate.toString().isNotEmpty) {
        return candidate.toString();
      }
    }
    return null;
  }

  static Future<void> _enqueue(Future<void> Function() operation) {
    _writes = _writes.then((_) => operation());
    return _writes;
  }
}
