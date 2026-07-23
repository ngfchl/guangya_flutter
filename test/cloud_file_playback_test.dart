import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/models/cloud_file.dart';
import 'package:guangya_flutter/widgets/file_preview_dialog.dart';

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

  test('audio is recognized from either type code or extension', () {
    const typedAudio = CloudFile(
      id: 'typed-audio',
      name: 'recording',
      isDirectory: false,
      fileType: 3,
    );
    const extensionAudio = CloudFile(
      id: 'extension-audio',
      name: 'track.FLAC',
      isDirectory: false,
    );
    const folder = CloudFile(
      id: 'folder',
      name: 'album.mp3',
      isDirectory: true,
    );

    expect(typedAudio.isAudio, isTrue);
    expect(extensionAudio.isAudio, isTrue);
    expect(extensionAudio.typeName, '音频');
    expect(extensionAudio.icon, 'music_note');
    expect(canPreviewCloudFile(extensionAudio), isTrue);
    expect(folder.isAudio, isFalse);
  });
}
