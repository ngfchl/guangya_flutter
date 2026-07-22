import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/providers/file_provider.dart';

void main() {
  test('external player lookup excludes apps nested in the current bundle', () {
    final result = preferredExternalPlayerApplicationPath(const [
      '/tmp/guangya.app/Contents/Resources/IINA.app',
      '/Applications/IINA.app',
    ], currentExecutable: '/tmp/guangya.app/Contents/MacOS/guangya');

    expect(result, '/Applications/IINA.app');
  });

  test('external player lookup returns null for only nested app copies', () {
    final result = preferredExternalPlayerApplicationPath(const [
      '/tmp/guangya.app/Contents/Resources/IINA.app',
    ], currentExecutable: '/tmp/guangya.app/Contents/MacOS/guangya');

    expect(result, isNull);
  });

  test('VLC URL includes the encoded media URL', () {
    const player = ExternalPlayer(
      'VLC',
      'vlc-x-callback',
      launchMode: ExternalPlayerLaunchMode.urlScheme,
      urlScheme: 'vlc-x-callback',
    );

    expect(
      externalPlayerURL(
        player,
        Uri.parse('https://example.com/a b.mp4?x=1'),
      ).toString(),
      'vlc-x-callback://x-callback-url/stream?url=https%3A%2F%2Fexample.com%2Fa%2520b.mp4%3Fx%3D1',
    );
  });

  test('nPlayer URL uses its protocol-prefixed HTTP scheme', () {
    const player = ExternalPlayer(
      'nPlayer',
      'nplayer',
      launchMode: ExternalPlayerLaunchMode.urlScheme,
      urlScheme: 'nplayer-https',
    );

    expect(
      externalPlayerURL(player, Uri.parse('https://example.com/video.mp4')),
      Uri.parse('nplayer-https://example.com/video.mp4'),
    );
  });

  test('executable lookup selects the first existing candidate', () {
    final result = firstExistingExecutablePath(const [
      null,
      '',
      r'C:\\missing.exe',
      r'C:\\VLC\\vlc.exe',
    ], (path) => path.endsWith(r'VLC\\vlc.exe'));

    expect(result, r'C:\\VLC\\vlc.exe');
  });
}
