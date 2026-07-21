import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/models/cloud_file.dart';
import 'package:guangya_flutter/models/media_library.dart';

void main() {
  test('copyWith can clear individual metadata sources', () {
    final item = MediaLibraryItem(
      libraryID: 'library',
      file: const CloudFile(id: 'file', name: 'movie.mkv', isDirectory: false),
      tmdbID: 1,
      doubanID: '2',
      imdbID: 'tt0000001',
      title: 'Movie',
      originalTitle: 'Movie',
      mediaKind: TMDBMediaKind.movie,
      collectionID: 3,
      collectionName: 'Collection',
      updatedAt: DateTime(2026),
    );

    final cleared = item.copyWith(
      clearTMDBID: true,
      clearDoubanID: true,
      clearImdbID: true,
      clearCollectionID: true,
      clearCollectionName: true,
    );

    expect(cleared.tmdbID, isNull);
    expect(cleared.doubanID, isNull);
    expect(cleared.imdbID, isNull);
    expect(cleared.collectionID, isNull);
    expect(cleared.collectionName, isNull);
  });
}
