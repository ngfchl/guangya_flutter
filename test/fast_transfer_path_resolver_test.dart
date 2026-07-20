import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/models/cloud_file.dart';
import 'package:guangya_flutter/models/fast_transfer.dart';
import 'package:guangya_flutter/utils/fast_transfer_path_resolver.dart';

FastTransferEntry _entry(String path) => FastTransferEntry.create(
  path: path,
  size: 1,
  gcid: '0123456789ABCDEF0123456789ABCDEF01234567',
);

void main() {
  test('reuses an existing directory without creating it', () async {
    var createCalls = 0;
    final resolver = FastTransferPathResolver(
      listDirectory: (_) async => const [
        CloudFile(id: 'movies', name: 'Movies', isDirectory: true),
      ],
      createDirectory: (_, _) async {
        createCalls += 1;
        return 'created';
      },
    );

    final target = await resolver.resolve(
      _entry('Movies/example.mkv'),
      rootID: null,
      createDirectories: true,
    );

    expect(target, 'movies');
    expect(createCalls, 0);
  });

  test('concurrent paths probe and create each directory once', () async {
    var listCalls = 0;
    var createCalls = 0;
    final resolver = FastTransferPathResolver(
      listDirectory: (_) async {
        listCalls += 1;
        return const [];
      },
      createDirectory: (_, _) async {
        createCalls += 1;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return 'movies';
      },
    );

    final targets = await Future.wait([
      resolver.resolve(
        _entry('Movies/a.mkv'),
        rootID: null,
        createDirectories: true,
      ),
      resolver.resolve(
        _entry('Movies/b.mkv'),
        rootID: null,
        createDirectories: true,
      ),
    ]);

    expect(targets, ['movies', 'movies']);
    expect(listCalls, 1);
    expect(createCalls, 1);
  });

  test('rejects a directory path occupied by a file', () async {
    final resolver = FastTransferPathResolver(
      listDirectory: (_) async => const [
        CloudFile(id: 'file', name: 'Movies', isDirectory: false),
      ],
      createDirectory: (_, _) async => 'created',
    );

    await expectLater(
      resolver.resolve(
        _entry('Movies/example.mkv'),
        rootID: null,
        createDirectories: true,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('reuses a directory created externally during a create race', () async {
    var listCalls = 0;
    final resolver = FastTransferPathResolver(
      listDirectory: (_) async {
        listCalls += 1;
        return listCalls == 1
            ? const []
            : const [
                CloudFile(id: 'movies', name: 'Movies', isDirectory: true),
              ];
      },
      createDirectory: (_, _) async => throw StateError('already exists'),
    );

    final target = await resolver.resolve(
      _entry('Movies/example.mkv'),
      rootID: null,
      createDirectories: true,
    );

    expect(target, 'movies');
    expect(listCalls, 2);
  });
}
