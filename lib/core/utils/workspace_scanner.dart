import '../../models/cloud_file.dart';
import 'json_deep.dart';

typedef WorkspaceFolderLoader =
    Future<List<CloudFile>> Function(String? folderID);

class WorkspaceScanProgress {
  final int foldersScanned;
  final int filesScanned;

  const WorkspaceScanProgress({
    required this.foldersScanned,
    required this.filesScanned,
  });
}

class WorkspaceScanResult {
  final List<CloudFile> emptyFolders;
  final List<List<CloudFile>> duplicateFiles;
  final List<List<CloudFile>> similarFolders;
  final int foldersScanned;
  final int filesScanned;

  const WorkspaceScanResult({
    required this.emptyFolders,
    required this.duplicateFiles,
    required this.similarFolders,
    required this.foldersScanned,
    required this.filesScanned,
  });
}

/// Recursively scans one cloud-drive subtree and produces all cleanup groups.
///
/// The caller supplies SQLite directory snapshots through [loadChildren]. This
/// keeps traversal identical for all three scan pages and makes the selected
/// folder ID part of the actual scan call chain.
class WorkspaceScanner {
  final WorkspaceFolderLoader loadChildren;

  const WorkspaceScanner({required this.loadChildren});

  /// Scans the workspace tree starting at [rootFolderID].
  ///
  /// [onFilesBatch] is called periodically with accumulated files so callers
  /// can update progress without retaining the complete file list. Only the
  /// first file for each GCID and files that are actually duplicated remain in
  /// memory.
  Future<WorkspaceScanResult> scan({
    required String? rootFolderID,
    String rootPath = '',
    void Function(WorkspaceScanProgress progress)? onProgress,
    void Function(List<CloudFile> batch)? onFilesBatch,
    int filesBatchSize = 5000,
    bool includeSimilarFolders = true,
  }) async {
    final emptyFolders = <CloudFile>[];
    final folders = <CloudFile>[];
    final pendingFiles = <CloudFile>[];
    final firstFileByGcid = <String, CloudFile>{};
    final duplicateFilesByGcid = <String, List<CloudFile>>{};
    final visitedFolderIDs = <String>{};
    final seenFileIDs = <String>{};
    final queue = <_PendingFolder>[];

    var foldersScanned = 0;
    var filesScanned = 0;

    /// Adds children of [parentID] and returns whether it has no immediate
    /// children. "Empty folder" intentionally means a directory whose direct
    /// listing is empty; a directory containing an empty child is not empty.
    Future<bool> addChildren(String? parentID, String parentPath) async {
      final children = await loadChildren(parentID);
      foldersScanned += 1;
      for (final child in children) {
        final path = _joinCloudPath(parentPath, child.name);
        final enriched = child.copyWith(
          cloudPath: _useProvidedPath(child.cloudPath, child.name)
              ? child.cloudPath
              : path,
        );
        if (enriched.isDirectory) {
          if (visitedFolderIDs.add(enriched.id)) {
            if (includeSimilarFolders) folders.add(enriched);
            queue.add(_PendingFolder(enriched, path));
          }
        } else if (seenFileIDs.add(enriched.id)) {
          filesScanned += 1;
          pendingFiles.add(enriched);
          final gcid = enriched.gcid?.trim();
          if (gcid != null && gcid.isNotEmpty) {
            final duplicates = duplicateFilesByGcid[gcid];
            if (duplicates != null) {
              duplicates.add(enriched);
            } else {
              final first = firstFileByGcid.remove(gcid);
              if (first == null) {
                firstFileByGcid[gcid] = enriched;
              } else {
                duplicateFilesByGcid[gcid] = [first, enriched];
              }
            }
          }
        }
      }

      if (onFilesBatch != null && pendingFiles.length >= filesBatchSize) {
        onFilesBatch(List.of(pendingFiles));
        pendingFiles.clear();
      }

      onProgress?.call(
        WorkspaceScanProgress(
          foldersScanned: foldersScanned,
          filesScanned: filesScanned,
        ),
      );
      return children.isEmpty;
    }

    final normalizedRootPath = _normalizeRootPath(rootPath);
    await addChildren(rootFolderID, normalizedRootPath);

    while (queue.isNotEmpty) {
      final pending = queue.removeLast();
      if (await addChildren(pending.folder.id, pending.path)) {
        emptyFolders.add(pending.folder);
      }
    }

    if (onFilesBatch != null && pendingFiles.isNotEmpty) {
      onFilesBatch(List.of(pendingFiles));
    }

    final duplicateFiles =
        duplicateFilesByGcid.values
            .map(_sortByPath)
            .toList()
          ..sort((a, b) => a.first.cloudPath.compareTo(b.first.cloudPath));

    // ── Similar folders ──
    final similarByName = <String, List<CloudFile>>{};
    for (final folder in folders) {
      final key = normalizeWorkspaceFolderName(folder.name);
      if (key.isNotEmpty) similarByName.putIfAbsent(key, () => []).add(folder);
    }
    final similarFolders =
        similarByName.values
            .where((group) => group.length > 1)
            .map(_sortByPath)
            .toList()
          ..sort((a, b) => a.first.cloudPath.compareTo(b.first.cloudPath));

    emptyFolders.sort((a, b) => a.cloudPath.compareTo(b.cloudPath));
    return WorkspaceScanResult(
      emptyFolders: emptyFolders,
      duplicateFiles: duplicateFiles,
      similarFolders: similarFolders,
      foldersScanned: foldersScanned,
      filesScanned: filesScanned,
    );
  }
}

/// Extracts the actual page list from a cloud drive response. The response
/// contains metadata maps with incidental `id` fields, so recursively parsing
/// every map can turn those metadata records into false folder children.
List<CloudFile> extractWorkspaceCloudFiles(Map<String, dynamic> response) {
  final values = JsonDeep.findArray(response, const [
    'list',
    'files',
    'fileList',
    'items',
    'records',
    'rows',
    'resList',
    'resourceList',
  ]);
  if (values == null) return const [];
  final files = <String, CloudFile>{};
  for (final value in values) {
    if (value is! Map) continue;
    try {
      final file = CloudFile.fromJson(Map<String, dynamic>.from(value));
      files[file.id] = file;
    } catch (_) {
      // Skip non-file response metadata.
    }
  }
  return files.values.toList(growable: false);
}

String normalizeWorkspaceFolderName(String value) {
  var normalized = value.toLowerCase().trim();
  normalized = normalized.replaceAll(
    RegExp(
      r'(?:[\s._-]*(?:copy|duplicate|backup|副本|复制|拷贝|备份))(?:[\s._-]*\d+)?$',
      caseSensitive: false,
    ),
    '',
  );
  normalized = normalized.replaceAll(
    RegExp(r'(?:[（(\[]\s*\d{1,3}\s*[）)\]])$'),
    '',
  );
  return normalized.replaceAll(RegExp(r'[\s._()\[\]{}-]+'), '');
}

class _PendingFolder {
  final CloudFile folder;
  final String path;

  const _PendingFolder(this.folder, this.path);
}

List<CloudFile> _sortByPath(List<CloudFile> files) =>
    List.of(files)..sort((a, b) => a.cloudPath.compareTo(b.cloudPath));

String _normalizeRootPath(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed == '云盘根目录') return '';
  return '/${trimmed.replaceAll(' / ', '/').replaceFirst(RegExp(r'^/+'), '')}';
}

String _joinCloudPath(String parent, String name) {
  final normalizedParent = parent.replaceFirst(RegExp(r'/+$'), '');
  return normalizedParent.isEmpty ? '/$name' : '$normalizedParent/$name';
}

bool _useProvidedPath(String path, String name) {
  final trimmed = path.trim();
  return trimmed.isNotEmpty && trimmed != name && trimmed.contains('/');
}
