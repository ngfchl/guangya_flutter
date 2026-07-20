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
  final itemDelays = <String, Duration>{};
  final librarySaveDelays = <String, Duration>{};
  final List<Set<String>> deleteCalls = [];
  final deletedLibraries = <String>[];
  bool initialized = false;
  int removeFilesFromAllFoldersCalls = 0;
  int removeLiveFileIDsCalls = 0;

  _FakeMediaLibraryStore({
    required List<MediaLibraryDefinition> definitions,
    required List<MediaLibraryItem> records,
  }) : definitions = [...definitions],
       records = [...records];

  @override
  Future<void> initialize() async {
    initialized = true;
  }

  @override
  Future<bool> get isEmpty async => definitions.isEmpty;

  @override
  Future<List<MediaLibraryDefinition>> libraries() async => [...definitions];

  @override
  Future<void> saveLibraries(List<MediaLibraryDefinition> libraries) async {
    for (final library in libraries) {
      final delay = librarySaveDelays[library.id];
      if (delay != null) await Future<void>.delayed(delay);
      definitions.removeWhere((item) => item.id == library.id);
      definitions.add(library);
    }
  }

  @override
  Future<List<MediaLibraryItem>> items({String? libraryID}) async {
    final delay = libraryID == null ? null : itemDelays[libraryID];
    if (delay != null) await Future<void>.delayed(delay);
    return records
        .where((item) => libraryID == null || item.libraryID == libraryID)
        .toList(growable: false);
  }

  @override
  Future<void> deleteLibrary(String id) async {
    deletedLibraries.add(id);
    definitions.removeWhere((library) => library.id == id);
    records.removeWhere((item) => item.libraryID == id);
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

  test(
    'deleteLibrary removes its persisted definition and orphan history',
    () async {
      final onlyA = _item(_libraryA.id, 'only-a');
      final sharedA = _item(_libraryA.id, 'shared-file');
      final sharedB = _item(_libraryB.id, 'shared-file');
      final store = _FakeMediaLibraryStore(
        definitions: const [_libraryA, _libraryB],
        records: [onlyA, sharedA, sharedB],
      );
      final historyCalls = <Set<String>>[];
      final notifier = MediaLibraryNotifier(
        store: store,
        removeWatchHistory: (fileIDs) async => historyCalls.add({...fileIDs}),
      );
      addTearDown(notifier.dispose);

      await notifier.load();
      await notifier.deleteLibrary(_libraryA.id);

      expect(store.deletedLibraries, [_libraryA.id]);
      expect(store.definitions.map((library) => library.id), [_libraryB.id]);
      expect(store.records.map((item) => item.libraryID).toSet(), {
        _libraryB.id,
      });
      expect(historyCalls, [
        {'only-a'},
      ]);
      expect(notifier.state.selectedLibraryID, _libraryB.id);
    },
  );

  test(
    'latest media library selection wins when loads finish out of order',
    () async {
      final store = _FakeMediaLibraryStore(
        definitions: const [_libraryA, _libraryB],
        records: [_item(_libraryA.id, 'a'), _item(_libraryB.id, 'b')],
      );
      final notifier = MediaLibraryNotifier(store: store);
      addTearDown(notifier.dispose);
      await notifier.load();
      store.itemDelays[_libraryA.id] = const Duration(milliseconds: 30);

      final older = notifier.selectLibrary(_libraryA.id);
      final latest = notifier.selectLibrary(_libraryB.id);
      await Future.wait([older, latest]);

      expect(notifier.state.selectedLibraryID, _libraryB.id);
      expect(notifier.state.items.map((item) => item.id), ['b']);
    },
  );

  test('concurrent library updates preserve both latest definitions', () async {
    final store = _FakeMediaLibraryStore(
      definitions: const [_libraryA, _libraryB],
      records: const [],
    );
    store.librarySaveDelays[_libraryA.id] = const Duration(milliseconds: 30);
    final notifier = MediaLibraryNotifier(store: store);
    addTearDown(notifier.dispose);
    await notifier.load();

    final updateA = notifier.updateLibrary(
      _libraryA.copyWith(name: 'Updated A'),
    );
    final updateB = notifier.updateLibrary(
      _libraryB.copyWith(name: 'Updated B'),
    );
    await Future.wait([updateA, updateB]);

    expect(
      {
        for (final library in notifier.state.libraries)
          library.id: library.name,
      },
      {_libraryA.id: 'Updated A', _libraryB.id: 'Updated B'},
    );
  });

  test('deleting a background library preserves current selection', () async {
    final store = _FakeMediaLibraryStore(
      definitions: const [_libraryA, _libraryB],
      records: [_item(_libraryA.id, 'a'), _item(_libraryB.id, 'b')],
    );
    final notifier = MediaLibraryNotifier(store: store);
    addTearDown(notifier.dispose);
    await notifier.load();
    await notifier.selectLibrary(_libraryB.id);

    await notifier.deleteLibrary(_libraryA.id);

    expect(notifier.state.selectedLibraryID, _libraryB.id);
    expect(notifier.state.items.map((item) => item.id), ['b']);
  });

  test('editing a background library preserves current selection', () async {
    final store = _FakeMediaLibraryStore(
      definitions: const [_libraryA, _libraryB],
      records: [_item(_libraryA.id, 'a'), _item(_libraryB.id, 'b')],
    );
    final notifier = MediaLibraryNotifier(store: store);
    addTearDown(notifier.dispose);
    await notifier.load();

    await notifier.updateLibrary(_libraryB.copyWith(name: 'Updated B'));

    expect(notifier.state.selectedLibraryID, _libraryA.id);
    expect(notifier.state.items.map((item) => item.id), ['a']);
  });

  test('creating a library supersedes an older pending selection', () async {
    final store = _FakeMediaLibraryStore(
      definitions: const [_libraryA, _libraryB],
      records: [_item(_libraryA.id, 'a'), _item(_libraryB.id, 'b')],
    );
    store.itemDelays[_libraryB.id] = const Duration(milliseconds: 30);
    final notifier = MediaLibraryNotifier(store: store);
    addTearDown(notifier.dispose);
    await notifier.load();

    final olderSelection = notifier.selectLibrary(_libraryB.id);
    await notifier.createLibrary(
      name: 'Created',
      rootID: 'created-root',
      rootPath: '/Created',
    );
    final createdID = notifier.state.selectedLibraryID;
    await olderSelection;

    expect(createdID, isNotNull);
    expect(createdID, isNot(_libraryB.id));
    expect(notifier.state.selectedLibraryID, createdID);
    expect(notifier.state.items, isEmpty);
  });
}
