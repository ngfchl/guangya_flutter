import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/core/http/http_error.dart';
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
}
