import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/core/http/http_error.dart';
import 'package:guangya_flutter/models/cloud_file.dart';
import 'package:guangya_flutter/models/media_library.dart';
import 'package:guangya_flutter/providers/media_library_provider.dart';

void main() {
  group('isConfirmedCloudFileMissingError', () {
    test('accepts HTTP and business not-found statuses', () {
      expect(
        isConfirmedCloudFileMissingError(
          ApiException(status: 404, message: '请求失败'),
        ),
        isTrue,
      );
      expect(
        isConfirmedCloudFileMissingError(
          DioException(
            requestOptions: RequestOptions(path: '/file/detail'),
            response: Response<Map<String, dynamic>>(
              requestOptions: RequestOptions(path: '/file/detail'),
              statusCode: 200,
              data: const {'code': 410, 'message': 'gone'},
            ),
          ),
        ),
        isTrue,
      );
    });

    test('accepts explicit missing-resource messages', () {
      expect(
        isConfirmedCloudFileMissingError(
          ApiException(status: 500, message: '文件不存在或已被删除'),
        ),
        isTrue,
      );
      expect(
        isConfirmedCloudFileMissingError(StateError('file not found')),
        isTrue,
      );
    });

    test('keeps records for transient network failures', () {
      expect(
        isConfirmedCloudFileMissingError(
          DioException(
            requestOptions: RequestOptions(path: '/file/detail'),
            type: DioExceptionType.connectionTimeout,
            message: 'connection timed out',
          ),
        ),
        isFalse,
      );
    });
  });

  group('media parent metadata', () {
    const known = CloudFile(
      id: 'file-1',
      name: 'episode.mkv',
      isDirectory: false,
      cloudPath: '/shows/title/episode.mkv',
      fullParentIDs: '[root, library-1, parent-1]',
    );

    test('prefers a direct or cached parent ID', () {
      expect(
        mediaParentIDFromMetadata(
          known.copyWith(parentID: 'direct-parent'),
          cachedFile: known.copyWith(parentID: 'cached-parent'),
        ),
        'direct-parent',
      );
      expect(
        mediaParentIDFromMetadata(
          known.copyWith(parentID: ' '),
          cachedFile: known.copyWith(parentID: 'cached-parent'),
        ),
        'cached-parent',
      );
    });

    test('recovers the last usable full parent ID', () {
      expect(mediaParentIDFromMetadata(known), 'parent-1');
      expect(
        mediaParentIDFromMetadata(
          known.copyWith(fullParentIDs: 'root/library-1/file-1'),
        ),
        'library-1',
      );
    });

    test('media item serialization retains parent metadata', () {
      final item = MediaLibraryItem.fromFile('library-1', known);
      final restored = MediaLibraryItem.fromJson(item.toJson());

      expect(restored.file.parentID, known.parentID);
      expect(restored.file.fullParentIDs, known.fullParentIDs);
    });
  });

  group('media cloud-name compatibility', () {
    test('preserves every zero digit while removing unsafe characters', () {
      expect(
        safeMediaCloudName('再见爱人.2021.{TMDB-13099}.1080p'),
        '再见爱人.2021.{TMDB-13099}.1080p',
      );
      expect(safeMediaCloudName('标题:2020\u0000.mkv'), '标题 2020.mkv');
    });

    test('does not guess an ambiguous TMDB id with missing zero digits', () {
      expect(
        mediaTMDBIDFromPath('/再见爱人(2 21){TMDB-13 99}-1 8 p/file.mp4'),
        isNull,
      );
      expect(mediaTMDBIDFromPath('/再见爱人{TMDB-130099}/file.mp4'), 130099);
    });

    test('keeps a known full path when the cloud response only has a name', () {
      expect(
        recoverCloudFilePath(
          fileName: 'episode-renamed.mkv',
          candidatePath: 'episode-renamed.mkv',
          knownPath: '/电视剧/示例剧/episode-old.mkv',
        ),
        '/电视剧/示例剧/episode-renamed.mkv',
      );
      expect(
        recoverCloudFilePath(
          fileName: 'episode.mkv',
          candidatePath: '/电视剧/示例剧/episode.mkv',
          knownPath: 'episode.mkv',
        ),
        '/电视剧/示例剧/episode.mkv',
      );
      expect(
        recoverCloudFilePath(
          fileName: 'root-renamed.mkv',
          candidatePath: 'root-renamed.mkv',
          knownPath: '/old.mkv',
        ),
        '/root-renamed.mkv',
      );
      expect(
        recoverCloudFilePath(
          fileName: 'new.mkv',
          candidatePath: 'new.mkv',
          knownPath: r'A\B\old.mkv',
        ),
        'A/B/new.mkv',
      );
    });
  });
}
