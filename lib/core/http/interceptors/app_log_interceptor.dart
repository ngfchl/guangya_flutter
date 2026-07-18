import 'package:dio/dio.dart';

import '../../logging/app_logger.dart';

class AppLogInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    AppLogger.debug(
      'HTTP',
      '→ ${options.method} ${options.uri.path}${options.uri.hasQuery ? '?${options.uri.query}' : ''}',
    );
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    AppLogger.debug(
      'HTTP',
      '← ${response.statusCode ?? 0} ${response.requestOptions.method} ${response.requestOptions.uri.path}',
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    AppLogger.error(
      'HTTP',
      '${err.requestOptions.method} ${err.requestOptions.uri.path} 失败',
      error: err.message,
      stackTrace: err.stackTrace,
    );
    handler.next(err);
  }
}
