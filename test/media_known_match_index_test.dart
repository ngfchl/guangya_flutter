import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/models/cloud_file.dart';
import 'package:guangya_flutter/models/media_library.dart';
import 'package:guangya_flutter/utils/media_known_match_index.dart';

void main() {
  MediaLibraryItem item(int id, {String year = '2003'}) {
    return MediaLibraryItem(
      libraryID: 'library',
      file: CloudFile(id: '$id', name: '$id.mkv', isDirectory: false),
      tmdbID: id,
      title: '倚天屠龙记',
      originalTitle: '倚天屠龙记',
      mediaKind: TMDBMediaKind.tv,
      releaseDate: '$year-01-01',
      updatedAt: DateTime(2026),
    );
  }

  test('reuses one exact known TV identity', () {
    final index = MediaKnownMatchIndex([item(31952)]);

    expect(
      index.resolve(title: '倚天屠龙记', mediaKind: TMDBMediaKind.tv)?.tmdbID,
      31952,
    );
  });

  test('does not reuse a known identity from another year', () {
    final index = MediaKnownMatchIndex([item(31952)]);

    expect(
      index.resolve(title: '倚天屠龙记', mediaKind: TMDBMediaKind.tv, year: 2001),
      isNull,
    );
  });

  test('does not reuse an ambiguous exact title', () {
    final index = MediaKnownMatchIndex([
      item(31952),
      item(99999, year: '2019'),
    ]);

    expect(index.resolve(title: '倚天屠龙记', mediaKind: TMDBMediaKind.tv), isNull);
  });
}
