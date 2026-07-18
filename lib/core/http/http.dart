import 'dart:developer';

import 'package:dio/dio.dart';

import '../storage/storage_manager.dart';
import 'dio_client.dart';
import 'http_error.dart';
import 'interceptors/response_interceptor.dart';

/// 统一 HTTP 封装 — 光鸭云盘
class Http {
  /// 通用底层请求方法
  static Future<T> request<T>(
    String path, {
    String method = 'POST',
    Map<String, dynamic>? queryParameters,
    dynamic data,
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
    Options? options,
    bool useAccountDio = false,
    bool allowAnyCode = false,
  }) async {
    final client = useAccountDio ? DioClient.accountDio : DioClient.dio;

    final mergedOptions = (options ?? Options()).copyWith(
      method: method,
      headers: headers,
    );

    final stopwatch = Stopwatch()..start();
    final endpoint = useAccountDio ? 'account' : 'api';
    log('[HTTP:$endpoint] -> $method $path');

    try {
      final res = await client.request(
        path,
        data: data,
        queryParameters: queryParameters,
        cancelToken: cancelToken,
        options: mergedOptions,
      );
      stopwatch.stop();

      log(
        '[HTTP:$endpoint] <- $method $path status=${res.statusCode} '
        'elapsed=${stopwatch.elapsedMilliseconds}ms',
      );

      return res.data as T;
    } on DioException catch (e) {
      stopwatch.stop();
      final status = e.response?.statusCode;
      log(
        '[HTTP:$endpoint] !! $method $path status=${status ?? '-'} '
        'type=${e.type.name} elapsed=${stopwatch.elapsedMilliseconds}ms',
      );

      // 将业务错误信息包装为 ApiException
      final errorMsg = e.error is String ? (e.error as String) : '';
      if (errorMsg.isNotEmpty) {
        throw ApiException(status: status, message: errorMsg);
      }

      rethrow;
    } catch (e) {
      stopwatch.stop();
      log(
        '[HTTP:$endpoint] !! $method $path elapsed=${stopwatch.elapsedMilliseconds}ms',
      );
      rethrow;
    }
  }

  /// 光鸭 API 请求（带 token，code==200 为成功）
  static Future<Map<String, dynamic>> apiRequest(
    String path, {
    String method = 'POST',
    dynamic body,
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
    List<int> allowedCodes = const [],
  }) async {
    // 过期自动刷新
    _checkTokenExpiry();

    final mergedHeaders = <String, dynamic>{
      'traceparent': _generateTraceparent(),
      ...?headers,
    };

    final data = await request<Map<String, dynamic>>(
      path,
      method: method,
      data: body,
      headers: mergedHeaders,
      cancelToken: cancelToken,
      options: Options(extra: {ResponseInterceptor.skipCodeCheckKey: true}),
    );

    final code = _businessCode(data['code']);
    if (code == null ||
        code == 0 ||
        code == 200 ||
        allowedCodes.contains(code)) {
      return data;
    }

    throw ApiException(
      status: code,
      message: extractHttpMessage(data) ?? '请求失败 ($code)',
    );
  }

  /// 光鸭账号请求（account API 响应格式无 code 字段，跳过业务 code 检查）
  static Future<Map<String, dynamic>> accountRequest(
    String path, {
    String method = 'POST',
    Map<String, dynamic>? body,
    Map<String, dynamic>? extraHeaders,
    bool authenticated = false,
  }) async {
    final headers = <String, dynamic>{
      'did': _getDeviceID(),
      'dt': '4',
      ...?extraHeaders,
    };

    if (authenticated) {
      final token = StorageManager.get<String>(StorageKeys.accessToken);
      if (token != null && token.isNotEmpty) {
        headers['authorization'] = 'Bearer $token';
      }
    }

    final data = await request<Map<String, dynamic>>(
      path,
      method: method,
      data: body,
      headers: headers,
      useAccountDio: true,
      options: Options(extra: {ResponseInterceptor.skipCodeCheckKey: true}),
    );

    return data;
  }

  /// 公开请求（无 token，用于分享预览等）
  static Future<Map<String, dynamic>> publicRequest(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    return request<Map<String, dynamic>>(
      path,
      method: 'POST',
      data: body,
      headers: {'traceparent': _generateTraceparent()},
    );
  }

  // ── Token 过期检测 ─────────────────────────────────────────────

  static void _checkTokenExpiry() {
    final expiresAt = StorageManager.get<int>(StorageKeys.tokenExpiresAt);
    if (expiresAt == null) return;
    if (DateTime.now().millisecondsSinceEpoch > expiresAt) {
      log('[HTTP] token expired, will refresh on next 401');
    }
  }

  static String _getDeviceID() {
    return StorageManager.get<String>(StorageKeys.deviceID) ??
        'flutter-${DateTime.now().millisecondsSinceEpoch}';
  }

  // ── Helpers ─────────────────────────────────────────────────────

  static String _generateTraceparent() {
    final now = DateTime.now().microsecondsSinceEpoch;
    return '00-${now.toRadixString(16).padLeft(32, '0')}-${now.toRadixString(16).padLeft(16, '0')}-01';
  }

  static int? _businessCode(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    return int.tryParse(value.toString());
  }
}
