import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/models/cloud_file.dart';
import 'package:guangya_flutter/models/media_library.dart';
import 'package:guangya_flutter/providers/media_library_provider.dart';

void main() {
  const file = CloudFile(
    id: 'file-1',
    name: 'Example.2024.mkv',
    isDirectory: false,
  );
  final unmatched = MediaLibraryItem.fromFile('library-1', file);
  final matched = unmatched.copyWith(
    tmdbID: 123,
    mediaKind: TMDBMediaKind.movie,
  );

  test('only force-all mode refreshes the file index', () {
    expect(MediaLibraryScanMode.unrecognizedOnly.refreshesFileIndex, isFalse);
    expect(MediaLibraryScanMode.forceAll.refreshesFileIndex, isTrue);
  });

  test('unrecognized-only scan skips an existing matched resource', () {
    expect(
      shouldRecognizeMediaScanItem(
        mode: MediaLibraryScanMode.unrecognizedOnly,
        existing: matched,
        sameCloudResource: true,
      ),
      isFalse,
    );
  });

  test('unrecognized-only scan recognizes an existing unmatched resource', () {
    expect(
      shouldRecognizeMediaScanItem(
        mode: MediaLibraryScanMode.unrecognizedOnly,
        existing: unmatched,
        sameCloudResource: true,
      ),
      isTrue,
    );
  });

  test('force-all scan recognizes an existing matched resource again', () {
    expect(
      shouldRecognizeMediaScanItem(
        mode: MediaLibraryScanMode.forceAll,
        existing: matched,
        sameCloudResource: true,
      ),
      isTrue,
    );
  });
}
