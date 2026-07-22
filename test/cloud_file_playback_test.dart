import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/models/cloud_file.dart';

void main() {
  test('ISO remains a video resource but is not playable', () {
    const iso = CloudFile(
      id: 'iso',
      name: 'Movie.2026.ISO',
      isDirectory: false,
    );

    expect(iso.isVideo, isTrue);
    expect(iso.isIso, isTrue);
    expect(iso.isPlayableVideo, isFalse);
  });

  test('regular video remains playable', () {
    const video = CloudFile(
      id: 'video',
      name: 'Movie.2026.mkv',
      isDirectory: false,
    );

    expect(video.isIso, isFalse);
    expect(video.isPlayableVideo, isTrue);
  });
}
