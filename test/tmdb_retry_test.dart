import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/api/guangya_api.dart';
import 'package:guangya_flutter/core/http/http_error.dart';

class _FlakyTMDBInterceptor extends Interceptor {
  final int failuresBeforeSuccess;
  final DioExceptionType failureType;
  int attempts = 0;

  _FlakyTMDBInterceptor({
    required this.failuresBeforeSuccess,
    this.failureType = DioExceptionType.connectionTimeout,
  });

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    attempts++;
    if (attempts <= failuresBeforeSuccess) {
      handler.reject(DioException(requestOptions: options, type: failureType));
      return;
    }
    handler.resolve(
      Response<Map<String, dynamic>>(
        requestOptions: options,
        statusCode: 200,
        data: const {'results': <Map<String, dynamic>>[]},
      ),
    );
  }
}

void main() {
  test(
    'TMDB retries recoverable network failures up to three attempts',
    () async {
      final interceptor = _FlakyTMDBInterceptor(failuresBeforeSuccess: 2);
      final dio = Dio()..interceptors.add(interceptor);
      final api = GuangyaAPI(tmdbDio: dio, tmdbRetryBaseDelay: Duration.zero);

      final result = await api.tmdbSearch('Belle', apiKey: 'test-key');

      expect(result['results'], isEmpty);
      expect(interceptor.attempts, 3);
    },
  );

  test('TMDB does not retry non-network response failures', () async {
    final interceptor = _FlakyTMDBInterceptor(
      failuresBeforeSuccess: 1,
      failureType: DioExceptionType.badResponse,
    );
    final dio = Dio()..interceptors.add(interceptor);
    final api = GuangyaAPI(tmdbDio: dio, tmdbRetryBaseDelay: Duration.zero);

    await expectLater(
      api.tmdbSearch('Belle', apiKey: 'test-key'),
      throwsA(isA<DioException>()),
    );
    expect(interceptor.attempts, 1);
  });

  test('only intermediate retryable failures suppress their error log', () {
    final intermediate = RequestOptions(
      path: '/3/search/movie',
      extra: const {tmdbRetryAttemptExtra: 1, tmdbRetryMaxAttemptsExtra: 3},
    );
    final finalAttempt = RequestOptions(
      path: '/3/search/movie',
      extra: const {tmdbRetryAttemptExtra: 3, tmdbRetryMaxAttemptsExtra: 3},
    );

    expect(
      suppressIntermediateTMDBRetryLog(
        DioException(
          requestOptions: intermediate,
          type: DioExceptionType.connectionTimeout,
        ),
      ),
      isTrue,
    );
    expect(
      suppressIntermediateTMDBRetryLog(
        DioException(
          requestOptions: finalAttempt,
          type: DioExceptionType.connectionTimeout,
        ),
      ),
      isFalse,
    );
    expect(
      suppressIntermediateTMDBRetryLog(
        DioException(
          requestOptions: intermediate,
          type: DioExceptionType.badResponse,
        ),
      ),
      isFalse,
    );
  });
}
