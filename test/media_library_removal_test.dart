import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/core/storage/media_library_store.dart';
import 'package:guangya_flutter/models/cloud_file.dart';
import 'package:guangya_flutter/models/media_library.dart';
import 'package:guangya_flutter/providers/media_library_provider.dart';

const _libraryA = MediaLibraryDefinition(
  id: 'library-a',
  name: 'Library A',
  sources: [
    MediaLibrarySource(
      id: 'library-a-source',
      rootID: 'root-a',
      path: '/Library A',
    ),
  ],
);

const _libraryB = MediaLibraryDefinition(
  id: 'library-b',
  name: 'Library B',
  sources: [
    MediaLibrarySource(
      id: 'library-b-source',
      rootID: 'root-b',
      path: '/Library B',
    ),
  ],
);

MediaLibraryItem _item(String libraryID, String fileID) {
  return MediaLibraryItem.fromFile(
    libraryID,
    CloudFile(
      id: fileID,
      name: '$fileID.2024.mkv',
      isDirectory: false,
      gcid: 'gcid-$fileID',
      cloudPath: '/$libraryID/$fileID.2024.mkv',
      fileType: 2,
    ),
  );
}

class _FakeMediaLibraryStore extends MediaLibraryStore {
  final List<MediaLibraryDefinition> definitions;
  final List<MediaLibraryItem> records;
  final List<Set<String>> deleteCalls = [];
  bool initialized = false;
  int removeFilesFromAllFoldersCalls = 0;
  int removeLiveFileIDsCalls = 0;

  _FakeMediaLibraryStore({
    required this.definitions,
    required List<MediaLibraryItem> records,
  }) : records = [...records];

  @override
  Future<void> initialize() async {
    initialized = true;
  }

  @override
  Future<bool> get isEmpty async => definitions.isEmpty;

  @override
  Future<List<MediaLibraryDefinition>> libraries() async => [...definitions];

  @override
  Future<List<MediaLibraryItem>> items({String? libraryID}) async {
    return records
        .where((item) => libraryID == null || item.libraryID == libraryID)
        .toList(growable: false);
  }

  @override
  Future<int> deleteItems(Iterable<MediaLibraryItem> items) async {
    final keys = {for (final item in items) '${item.libraryID}:${item.id}'};
    deleteCalls.add(keys);
    final before = records.length;
    records.removeWhere(
      (item) => keys.contains('${item.libraryID}:${item.id}'),
    );
    return before - records.length;
  }

  @override
  Future<void> removeFilesFromAllFolders(Iterable<String> fileIDs) async {
    removeFilesFromAllFoldersCalls += 1;
  }

  @override
  Future<void> removeLiveFileIDs(Iterable<String> values) async {
    removeLiveFileIDsCalls += 1;
  }
}

void main() {
  group('MediaLibraryNotifier.removeMediaRecords', () {
    test(
      'deletes only the requested composite key and preserves shared history',
      () async {
        final sharedA = _item(_libraryA.id, 'shared-file');
        final sharedB = _item(_libraryB.id, 'shared-file');
        final retainedA = _item(_libraryA.id, 'retained-a');
        final retainedB = _item(_libraryB.id, 'retained-b');
        final store = _FakeMediaLibraryStore(
          definitions: const [_libraryA, _libraryB],
          records: [sharedA, retainedA, sharedB, retainedB],
        );
        final removedHistoryIDs = <String>{};
        final notifier = MediaLibraryNotifier(
          store: store,
          removeWatchHistory: (fileIDs) async {
            removedHistoryIDs.addAll(fileIDs);
          },
        );
        addTearDown(notifier.dispose);

        await notifier.load();
        final removed = await notifier.removeMediaRecords([sharedA]);

        expect(store.initialized, isTrue);
        expect(removed, 1);
        expect(store.deleteCalls, [
          const {'library-a:shared-file'},
        ]);
        expect(store.removeFilesFromAllFoldersCalls, 0);
        expect(store.removeLiveFileIDsCalls, 0);
        expect(
          store.records.map((item) => '${item.libraryID}:${item.id}'),
          containsAll(<String>[
            'library-a:retained-a',
            'library-b:shared-file',
            'library-b:retained-b',
          ]),
        );
        expect(removedHistoryIDs, isEmpty);
        expect(notifier.state.items.map((item) => item.id), ['retained-a']);
        expect(
          notifier.state.allItems
              .map((item) => '${item.libraryID}:${item.id}')
              .toSet(),
          {
            'library-a:retained-a',
            'library-b:shared-file',
            'library-b:retained-b',
          },
        );
        expect(notifier.state.statusMessage, '已从影视库移除 1 条记录，云盘文件未删除');
      },
    );

    test('removes history only after the file ID becomes orphaned', () async {
      final sharedA = _item(_libraryA.id, 'shared-file');
      final sharedB = _item(_libraryB.id, 'shared-file');
      final retainedA = _item(_libraryA.id, 'retained-a');
      final store = _FakeMediaLibraryStore(
        definitions: const [_libraryA, _libraryB],
        records: [sharedA, retainedA, sharedB],
      );
      final historyCalls = <Set<String>>[];
      final notifier = MediaLibraryNotifier(
        store: store,
        removeWatchHistory: (fileIDs) async {
          historyCalls.add({...fileIDs});
        },
      );
      addTearDown(notifier.dispose);

      await notifier.load();
      final removed = await notifier.removeMediaRecords([sharedA, sharedB]);

      expect(removed, 2);
      expect(store.deleteCalls, [
        const {'library-a:shared-file', 'library-b:shared-file'},
      ]);
      expect(store.removeFilesFromAllFoldersCalls, 0);
      expect(store.removeLiveFileIDsCalls, 0);
      expect(historyCalls, [
        const {'shared-file'},
      ]);
      expect(notifier.state.items.map((item) => item.id), ['retained-a']);
      expect(
        notifier.state.allItems
            .map((item) => '${item.libraryID}:${item.id}')
            .toList(),
        ['library-a:retained-a'],
      );
      expect(notifier.state.statusMessage, '已从影视库移除 2 条记录，云盘文件未删除');
    });
  });
}
