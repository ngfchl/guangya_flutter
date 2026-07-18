import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../config/app_config.dart';
import 'interceptors/auth_interceptor.dart';
import 'interceptors/response_interceptor.dart';

class DioClient {
  static late Dio dio;
  static late Dio accountDio;
  static AuthInterceptor? _authInterceptor;

  /// 初始化 DIO 客户端
  static void init({OnLogout? onLogout}) {
    _authInterceptor = AuthInterceptor(onLogout: onLogout);

    dio = _createDio(
      baseUrl: AppConfig.apiBase,
      interceptors: [
        _authInterceptor!,
        ResponseInterceptor(),
      ],
    );

    accountDio = _createDio(
      baseUrl: AppConfig.accountBase,
      interceptors: [
        ResponseInterceptor(),
      ],
    );
  }

  /// 更新 API baseUrl 并同步到 DioClient
  static void updateBaseUrl(String apiBase, {String? accountBase}) {
    dio.options.baseUrl = apiBase;
    if (accountBase != null) {
      accountDio.options.baseUrl = accountBase;
    }
  }

  /// 重新设置 onLogout 回调（例如切换 provider 时）
  static void setOnLogout(OnLogout? onLogout) {
    if (_authInterceptor != null) {
      _authInterceptor = AuthInterceptor(onLogout: onLogout);
      dio.interceptors.removeWhere((i) => i is AuthInterceptor);
      dio.interceptors.insert(0, _authInterceptor!);
    }
  }

  static Dio _createDio({
    required String baseUrl,
    required List<Interceptor> interceptors,
  }) {
    final dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 30),
        headers: {
          'Accept': 'application/json, text/plain, */*',
          'Content-Type': 'application/json',
          'Origin': 'https://www.guangyapan.com',
          'Referer': 'https://www.guangyapan.com/',
          'User-Agent':
              'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
        },
      ),
    );

    // Windows 下优化连接池
    if (Platform.isWindows) {
      (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
        final client = HttpClient();
        client.maxConnectionsPerHost = 10;
        client.idleTimeout = const Duration(seconds: 60);
        return client;
      };
    }

    dio.interceptors.addAll(interceptors);
    return dio;
  }
}
