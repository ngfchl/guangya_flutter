import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/models/cloud_file.dart';
import 'package:guangya_flutter/widgets/media_player_dialog.dart';

CloudFile _file(String id, String name) =>
    CloudFile(id: id, name: name, isDirectory: false);

void main() {
  test('subtitle matching excludes subtitles from another episode', () {
    final video = _file('video', 'Example.Show.S01E02.1080p.mkv');
    final matches = matchingSubtitlesForPlayback(video, [
      _file('e1', 'Example.Show.S01E01.chs.ass'),
      _file('e2', 'Example.Show.S01E02.chs.ass'),
      _file('other', 'Other.Show.S01E02.srt'),
    ]);

    expect(matches.map((file) => file.id), ['e2']);
  });

  test('subtitle matching prefers Chinese tagged same-name subtitle', () {
    final video = _file('video', 'Example.Movie.2025.mkv');
    final matches = matchingSubtitlesForPlayback(video, [
      _file('plain', 'Example.Movie.2025.srt'),
      _file('zh', 'Example.Movie.2025.zh-CN.ass'),
      _file('unrelated', 'Another.Movie.2025.srt'),
    ]);

    expect(matches.map((file) => file.id), ['zh', 'plain']);
  });
}
