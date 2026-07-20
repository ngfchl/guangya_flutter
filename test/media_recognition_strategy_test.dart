import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/api/guangya_api.dart';
import 'package:guangya_flutter/models/cloud_file.dart';
import 'package:guangya_flutter/models/media_library.dart';
import 'package:guangya_flutter/providers/media_library_provider.dart';

class _RecognitionAPI extends GuangyaAPI {
  final calls = <({String query, String mediaKind, int? year})>[];

  @override
  Future<Map<String, dynamic>> tmdbSearch(
    String query, {
    required String apiKey,
    String mediaKind = 'auto',
    String proxyHost = '',
    String proxyPort = '',
    int? year,
  }) async {
    calls.add((query: query, mediaKind: mediaKind, year: year));
    if (query == '你好1983') {
      return {
        'results': [
          {
            'id': 280822,
            'media_type': 'tv',
            'name': '你好1983',
            'original_name': '你好1983',
            'first_air_date': '2026-03-17',
          },
        ],
      };
    }
    if (query == 'Project S01') {
      return {
        'results': [
          {
            'id': 999001,
            'media_type': 'tv',
            'name': 'Project S01',
            'original_name': 'Project S01',
            'first_air_date': '2026-01-01',
          },
        ],
      };
    }
    return const {'results': <Map<String, dynamic>>[]};
  }

  @override
  Future<Map<String, dynamic>> tmdbDetails(
    int id, {
    required String mediaKind,
    required String apiKey,
    String proxyHost = '',
    String proxyPort = '',
  }) async {
    if (id == 999001) {
      return {
        'id': id,
        'name': 'Project S01',
        'original_name': 'Project S01',
        'first_air_date': '2026-01-01',
      };
    }
    return {
      'id': id,
      'name': '你好1983',
      'original_name': '你好1983',
      'first_air_date': '2026-03-17',
    };
  }
}

void main() {
  test('TV recognition falls back from filename to the raw parent title', () async {
    final api = _RecognitionAPI();
    final notifier = MediaLibraryNotifier()..api = api;
    addTearDown(notifier.dispose);
    final item = MediaLibraryItem.fromFile(
      'library-1',
      const CloudFile(
        id: 'episode-1',
        name:
            'Dream.of.Golden.Years.S01E01.2026.2160p.WEB-DL.H265.DV.DDP5.1-BlackTV.mkv',
        isDirectory: false,
        cloudPath:
            '/电视剧/国产剧/你好1983/Dream.of.Golden.Years.S01E01.2026.2160p.WEB-DL.H265.DV.DDP5.1-BlackTV.mkv',
      ),
      directoryName: '你好1983',
    );

    final recognized = await notifier.recognizeMediaItemForTesting(
      item,
      apiKey: 'test-key',
    );

    expect(recognized.tmdbID, 280822);
    expect(recognized.title, '你好1983');
    expect(api.calls.take(3).toList(), [
      (query: 'Dream of Golden Years', mediaKind: 'tv', year: 2026),
      (query: 'Dream of Golden Years', mediaKind: 'tv', year: null),
      (query: '你好1983', mediaKind: 'tv', year: 2026),
    ]);
  });

  test('persisted TMDB details reject an extra-letter English title', () {
    final notifier = MediaLibraryNotifier();
    addTearDown(notifier.dispose);
    final item = MediaLibraryItem.fromFile(
      'library-1',
      const CloudFile(
        id: 'episode-24',
        name:
            'Everyone.Loves.Me.S01E24.1080p.Viu.WEB-DL.AAC2.0.H.264-BlackTV.mkv',
        isDirectory: false,
        cloudPath:
            '/电视剧/国产剧/Everyone Loves Me/Everyone.Loves.Me.S01E24.1080p.Viu.WEB-DL.AAC2.0.H.264-BlackTV.mkv',
      ),
      directoryName: 'Everyone Loves Me',
    );

    final valid = notifier.validatePersistedTMDBDetailsForTesting(item, const {
      'id': 210098,
      'name': 'Everyone Loves Mel',
      'original_name': 'Everyone Loves Mel',
      'first_air_date': '2000-01-01',
    }, TMDBMediaKind.tv);

    expect(valid, isFalse);
  });

  test(
    'recognition preserves a real title that itself ends with S01',
    () async {
      final api = _RecognitionAPI();
      final notifier = MediaLibraryNotifier()..api = api;
      addTearDown(notifier.dispose);
      final item = MediaLibraryItem.fromFile(
        'library-1',
        const CloudFile(
          id: 'project-s01-episode-1',
          name: 'Project.S01.S01E01.2026.1080p.WEB-DL.mkv',
          isDirectory: false,
          cloudPath:
              '/电视剧/Project S01/Project.S01.S01E01.2026.1080p.WEB-DL.mkv',
        ),
        directoryName: 'Project S01',
      );

      final recognized = await notifier.recognizeMediaItemForTesting(
        item,
        apiKey: 'test-key',
      );

      expect(recognized.tmdbID, 999001);
      expect(recognized.title, 'Project S01');
      expect(api.calls.first.query, 'Project S01');
    },
  );
}
