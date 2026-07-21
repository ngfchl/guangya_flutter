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

  test('search matches TMDB, IMDb and Douban IDs', () {
    final item = MediaLibraryItem(
      libraryID: 'library',
      file: const CloudFile(id: 'file', name: 'movie.mkv', isDirectory: false),
      tmdbID: 12345,
      doubanID: '34912345',
      imdbID: 'tt7654321',
      title: '电影',
      originalTitle: 'Movie',
      updatedAt: DateTime(2026),
    );
    expect(item.matchesSearch('12345'), isTrue);
    expect(item.matchesSearch('tmdb:12345'), isTrue);
    expect(item.matchesSearch('IMDB:TT7654321'), isTrue);
    expect(item.matchesSearch('豆瓣：34912345'), isTrue);
    expect(item.matchesSearch('douban:7654321'), isFalse);
    expect(item.matchesSearch('tt0000000'), isFalse);
  });
}
