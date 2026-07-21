import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/models/cloud_file.dart';
import 'package:guangya_flutter/models/media_library.dart';
import 'package:guangya_flutter/utils/media_artwork.dart';

void main() {
  test('keeps external artwork URLs and expands protocol-relative URLs', () {
    expect(
      mediaArtworkDirectURL(
        'https://img.example.com/poster.webp',
        size: 'w342',
      ),
      'https://img.example.com/poster.webp',
    );
    expect(
      mediaArtworkDirectURL('//img.example.com/poster.webp', size: 'w342'),
      'https://img.example.com/poster.webp',
    );
  });

  test('builds TMDB artwork URLs for relative paths', () {
    expect(
      mediaArtworkDirectURL('/poster.jpg', size: 'w342'),
      'https://image.tmdb.org/t/p/w342/poster.jpg',
    );
  });

  test('extracts nested Douban poster fields', () {
    expect(
      doubanPosterPath({
        'cover_url': {'large': '//img.example.com/douban.webp'},
      }),
      '//img.example.com/douban.webp',
    );
  });

  test('uses the poster as backdrop fallback for Douban-only media', () {
    final item = MediaLibraryItem(
      libraryID: 'library',
      file: const CloudFile(id: 'file', name: 'movie.mkv', isDirectory: false),
      doubanID: '1295644',
      title: '这个杀手不太冷',
      originalTitle: 'Léon',
      mediaKind: TMDBMediaKind.movie,
      posterPath: 'https://img.example.com/poster.webp',
      updatedAt: DateTime(2026),
    );

    expect(mediaBackdropPath(item), 'https://img.example.com/poster.webp');
  });
}
