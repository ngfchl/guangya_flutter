import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/core/utils/workspace_scanner.dart';
import 'package:guangya_flutter/models/cloud_file.dart';

CloudFile folder(String id, String name) =>
    CloudFile(id: id, name: name, isDirectory: true, parentID: 'parent-$id');

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

  test('normalizes copy suffixes, punctuation and numbered suffixes', () {
    expect(normalizeWorkspaceFolderName('My.Movie 副本 2'), 'mymovie');
    expect(normalizeWorkspaceFolderName('My Movie (2)'), 'mymovie');
    expect(normalizeWorkspaceFolderName('MY-MOVIE_backup'), 'mymovie');
  });

  test('extracts and deduplicates cloud files from nested API responses', () {
    final response = <String, dynamic>{
      'data': {
        'list': [
          {'id': '1', 'name': 'A', 'isDir': 1},
          {'id': '1', 'name': 'A', 'isDir': 1},
          {'id': '2', 'name': 'B.mkv', 'isDir': 0, 'gcid': 'hash'},
        ],
      },
    };

    final files = extractWorkspaceCloudFiles(response);

    expect(files.map((item) => item.id), ['1', '2']);
  });
}
