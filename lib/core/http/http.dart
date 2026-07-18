import 'dart:io';
import 'dart:math';

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

    try {
      final res = await client.request(
        path,
        data: data,
        queryParameters: queryParameters,
        cancelToken: cancelToken,
        options: mergedOptions,
      );
      return res.data as T;
    } on DioException catch (e) {
      // 将业务错误信息包装为 ApiException
      final status = e.response?.statusCode;
      final errorMsg = e.error is String ? (e.error as String) : '';
      if (errorMsg.isNotEmpty) {
        throw ApiException(status: status, message: errorMsg);
      }

      rethrow;
    } catch (e) {
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
      ..._accountHeaders(),
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
    if (DateTime.now().millisecondsSinceEpoch > expiresAt) {}
  }

  static String _getDeviceID() {
    return StorageManager.get<String>(StorageKeys.deviceID) ??
        'flutter-${DateTime.now().millisecondsSinceEpoch}';
  }

  /// 账号网关会校验网页客户端的设备标识；与源客户端保持一致。
  static Map<String, String> _accountHeaders() {
    final deviceID = _getDeviceID();
    return {
      'x-client-id': 'aMe-8VSlkrbQXpUR',
      'x-client-version': '0.0.1',
      'x-device-id': deviceID,
      'x-device-model': 'chrome%2F150.0.0.0',
      'x-device-name': 'PC-Chrome',
      'x-device-sign': 'wdi10.$deviceID${_randomHex(16)}',
      'x-net-work-type': 'NONE',
      'x-os-version': _webPlatformName(),
      'x-platform-version': '1',
      'x-protocol-version': '301',
      'x-provider-name': 'NONE',
      'x-sdk-version': '9.0.2',
    };
  }

  static String _webPlatformName() {
    if (Platform.isMacOS) return 'MacIntel';
    if (Platform.isWindows) return 'Win32';
    if (Platform.isLinux) return 'Linux x86_64';
    if (Platform.isIOS) return 'iPhone';
    if (Platform.isAndroid) return 'Linux armv8l';
    return Platform.operatingSystem;
  }

  static String _randomHex(int bytes) {
    final random = Random.secure();
    return List.generate(
      bytes,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
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
