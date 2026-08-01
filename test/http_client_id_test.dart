import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/core/config/app_config.dart';
import 'package:guangya_flutter/core/http/dio_client.dart';
import 'package:guangya_flutter/core/http/http.dart';

class _RecordingAdapter implements HttpClientAdapter {
  RequestOptions? lastRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    return ResponseBody.fromString(
      '{"code":200}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _RecordingAdapter adapter;

  setUp(() {
    adapter = _RecordingAdapter();
    DioClient.dio = Dio(BaseOptions(baseUrl: 'https://example.test'))
      ..httpClientAdapter = adapter;
  });

  test(
    'apiRequest injects clientId into map bodies at dispatch time',
    () async {
      await Http.apiRequest(
        '/move',
        body: {
          'fileIds': ['file-1'],
          'clientId': 'stale-value',
        },
      );

      expect(adapter.lastRequest?.data, {
        'fileIds': ['file-1'],
        'clientId': AppConfig.clientID,
      });
    },
  );

  test(
    'apiRequest creates a body containing clientId when body is null',
    () async {
      await Http.apiRequest('/clear');

      expect(adapter.lastRequest?.data, {'clientId': AppConfig.clientID});
    },
  );

  test(
    'apiRequest injects clientId into FormData without duplicates',
    () async {
      final body = FormData.fromMap({
        'file': MultipartFile.fromBytes([1, 2, 3], filename: 'test.bin'),
        'clientId': 'stale-value',
      });

      await Http.apiRequest('/upload', body: body);

      final clientIDFields = body.fields
          .where((field) => field.key == 'clientId')
          .toList();
      expect(clientIDFields, hasLength(1));
      expect(clientIDFields.single.value, AppConfig.clientID);
    },
  );
}
