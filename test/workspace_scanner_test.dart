import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/core/utils/workspace_scanner.dart';
import 'package:guangya_flutter/models/cloud_file.dart';

CloudFile folder(
  String id,
  String name, {
  int? subDirectoryCount,
  int? subFileCount,
}) => CloudFile(
  id: id,
  name: name,
  isDirectory: true,
  parentID: 'parent-$id',
  subDirectoryCount: subDirectoryCount,
  subFileCount: subFileCount,
);

CloudFile file(String id, String name, {String? gcid}) => CloudFile(
  id: id,
  name: name,
  isDirectory: false,
  gcid: gcid,
  parentID: 'parent-$id',
);

void main() {
  test(
    'scans only the selected subtree and produces all cleanup groups',
    () async {
      final calls = <String?>[];
      final tree = <String?, List<CloudFile>>{
        'selected': [
          folder('movies', 'Movies'),
          folder('movies-copy', 'Movies 副本'),
          folder('empty', 'Empty'),
          file('one', 'one.mkv', gcid: 'same-content'),
        ],
        'movies': [file('two', 'renamed.mkv', gcid: 'same-content')],
        'movies-copy': [file('three', 'unique.mkv', gcid: 'unique')],
        'empty': [],
      };
      final progress = <WorkspaceScanProgress>[];

      final result =
          await WorkspaceScanner(
            loadChildren: (folderID) async {
              calls.add(folderID);
              return tree[folderID] ?? const [];
            },
          ).scan(
            rootFolderID: 'selected',
            rootPath: 'Library / Selected',
            onProgress: progress.add,
          );

      expect(
        calls,
        containsAll(<String?>['selected', 'movies', 'movies-copy', 'empty']),
      );
      expect(calls, isNot(contains(null)));
      expect(result.emptyFolders.map((item) => item.id), ['empty']);
      expect(result.duplicateFiles, hasLength(1));
      expect(
        result.duplicateFiles.single.map((item) => item.id),
        containsAll(['one', 'two']),
      );
      expect(result.similarFolders, hasLength(1));
      expect(
        result.similarFolders.single.map((item) => item.id),
        containsAll(['movies', 'movies-copy']),
      );
      expect(result.foldersScanned, 4);
      expect(result.filesScanned, 3);
      expect(progress.last.filesScanned, 3);
      expect(result.emptyFolders.single.cloudPath, '/Library/Selected/Empty');
    },
  );

  test('only direct empty folders are reported', () async {
      final tree = <String?, List<CloudFile>>{
        'root': [
          folder('parent', 'Parent'),
        ],
        'parent': [
          folder('child', 'Child'),
        ],
        'child': [],
      };

      final result = await WorkspaceScanner(
        loadChildren: (folderID) async => tree[folderID] ?? const [],
      ).scan(rootFolderID: 'root');

      expect(result.emptyFolders.map((f) => f.id), ['child']);
      expect(result.foldersScanned, 3);
    });

  test(
    'folder with only file-having sub-folders is excluded from empty',
    () async {
      // 'parent' has child 'sub' which has a file.
      // 'parent' has no direct files, but 'sub' has files.
      // 'parent' should NOT be empty (transitively has files).
      final tree = <String?, List<CloudFile>>{
        'root': [folder('parent', 'Parent')],
        'parent': [folder('sub', 'Sub')],
        'sub': [file('f1', 'doc.txt', gcid: 'g1')],
      };

      final result = await WorkspaceScanner(
        loadChildren: (folderID) async => tree[folderID] ?? const [],
      ).scan(rootFolderID: 'root');

      // 'parent' has a child ('sub') so it's not an empty candidate.
      // 'sub' has a file so it's not empty either.
      expect(result.emptyFolders, isEmpty);
      expect(result.foldersScanned, 3);
    },
  );

  test(
    'streaming onFilesBatch yields files in batches and produces correct result',
    () async {
      // Create enough files to trigger batching.
      final dirFiles = <CloudFile>[];
      for (var i = 0; i < 15; i++) {
        dirFiles.add(file('f$i', 'f$i.txt', gcid: i < 5 ? 'dup-group' : 'u$i'));
      }
      final tree = <String?, List<CloudFile>>{
        'root': [folder('dir', 'Dir')],
        'dir': dirFiles,
      };

      final batches = <List<CloudFile>>[];
      final result = await WorkspaceScanner(
        loadChildren: (folderID) async => tree[folderID] ?? const [],
      ).scan(
        rootFolderID: 'root',
        filesBatchSize: 10,
        onFilesBatch: batches.add,
      );

      // Should have been flushed in 2 batches (10 + 5).
      expect(batches.length, greaterThanOrEqualTo(1));
      final totalBatched = batches.fold(0, (sum, b) => sum + b.length);
      expect(totalBatched, 15);

      expect(result.duplicateFiles, hasLength(1));
      expect(result.duplicateFiles.single, hasLength(5));
      expect(result.foldersScanned, 2);
    },
  );

  test('empty folder is reported when cache has no children regardless of stale metadata', () async {
    // The cache says no children, and no verifyEmpty callback is provided.
    // Stale subFileCount metadata does NOT prevent the folder from being
    // reported as empty — that decision is delegated to the API via verifyEmpty.
    final tree = <String?, List<CloudFile>>{
      'root': [
        folder(
          'incomplete',
          'Incomplete snapshot',
          subFileCount: 4,
        ),
      ],
      'incomplete': [],
    };

    final result = await WorkspaceScanner(
      loadChildren: (folderID) async => tree[folderID] ?? const [],
    ).scan(rootFolderID: 'root');

    // Without verifyEmpty, the cache is trusted and folder is reported empty.
    expect(result.emptyFolders, hasLength(1));
    expect(result.emptyFolders.single.id, 'incomplete');
  });

  test('normalizes copy suffixes, punctuation and numbered suffixes', () {
    expect(normalizeWorkspaceFolderName('My.Movie 副本 2'), 'mymovie');
    expect(normalizeWorkspaceFolderName('My Movie (2)'), 'mymovie');
    expect(normalizeWorkspaceFolderName('MY-MOVIE_backup'), 'mymovie');
  });
}
