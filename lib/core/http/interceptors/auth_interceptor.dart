import 'dart:async';
import 'package:dio/dio.dart';

import '../../logging/app_logger.dart';
import '../../config/app_config.dart';
import '../../storage/storage_manager.dart';
import '../http_error.dart';
import '../dio_client.dart';

/// 光鸭 OAuth token 刷新回调
typedef OnLogout = Future<void> Function();

class AuthInterceptor extends Interceptor {
  final OnLogout? onLogout;
  bool _isRefreshing = false;
  bool _logoutScheduled = false;
  final List<Completer<void>> _waitQueue = [];

  AuthInterceptor({this.onLogout});

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    applyNoToastHeader(options);

    // 免认证路径：登录、刷新等
    if (_isAuthExemptPath(options.path)) {
      return handler.next(options);
    }

    final token = StorageManager.get<String>(StorageKeys.accessToken);
    if (token != null && token.isNotEmpty) {
      _logoutScheduled = false;
      options.headers['authorization'] = 'Bearer $token';
      return handler.next(options);
    }

    // 无 token → 静默取消
    return handler.reject(_silentCancel(options));
  }

  bool _isAuthExemptPath(String path) {
    return path.contains('/auth/signin') ||
        path.contains('/auth/verification') ||
        path.contains('/auth/device/code') ||
        path.contains('/auth/token');
  }

  bool _isSilentCancel(DioException err) {
    return err.type == DioExceptionType.cancel &&
        err.error?.toString() == 'silent_auth_cancel';
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    if (_isSilentCancel(err)) {
      return handler.next(err);
    }

    final status = err.response?.statusCode;
    final alreadyLoggedOut = status == 401 && _isAlreadyLoggedOut;

    // 免认证路径的错误直接放行
    if (_isAuthExemptPath(err.requestOptions.path)) {
      return handler.next(err);
    }

    // 网络错误
    if (err.type == DioExceptionType.connectionError ||
        err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.sendTimeout ||
        err.type == DioExceptionType.receiveTimeout) {
      return handler.next(err);
    }

    // 非 401 → 直接传递
    if (status != 401) {
      return handler.next(err);
    }

    // 以下全部是 401 处理
    if (alreadyLoggedOut) {
      return handler.reject(_silentCancel(err.requestOptions));
    }

    // 刷新接口本身 401 → refresh token 也失效了
    if (err.requestOptions.path.contains('/auth/token') &&
        err.requestOptions.method == 'POST') {
      await _logout();
      return handler.reject(_silentCancel(err.requestOptions));
    }

    // 获取 refreshToken
    final refreshToken = StorageManager.get<String>(StorageKeys.refreshToken);

    // 没有 refreshToken → 静默登出
    if (refreshToken == null || refreshToken.isEmpty) {
      await _logout();
      return handler.reject(_silentCancel(err.requestOptions));
    }

    // 已经在刷新中 → 排队等待
    if (_isRefreshing) {
      final completer = Completer<void>();
      _waitQueue.add(completer);
      await completer.future;

      final newToken = StorageManager.get<String>(StorageKeys.accessToken);
      if (newToken == null || newToken.isEmpty) {
        return handler.reject(_silentCancel(err.requestOptions));
      }

      final request = err.requestOptions;
      request.headers['authorization'] = 'Bearer $newToken';

      try {
        final response = await DioClient.dio.fetch(request);
        return handler.resolve(response);
      } catch (e) {
        return handler.reject(_silentCancel(err.requestOptions));
      }
    }

    // 开始刷新
    _isRefreshing = true;
    AppLogger.info('Auth', '登录凭据已过期，正在刷新');

    try {
      final dio = Dio(
        BaseOptions(
          baseUrl: AppConfig.accountBase,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
        ),
      );

      final res = await dio.post(
        '/v1/auth/token',
        data: {
          'client_id': AppConfig.clientID,
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
        },
        options: Options(
          headers: {
            'Accept': 'application/json, text/plain, */*',
            'Content-Type': 'application/json',
            'Origin': 'https://www.guangyapan.com',
            'Referer': 'https://www.guangyapan.com/',
            'did': StorageManager.get<String>(StorageKeys.deviceID) ?? '',
            'dt': '4',
            'x-action': '401',
          },
        ),
      );

      AppLogger.info('Auth', '登录凭据刷新完成');

      final data = res.data;
      final newAccess = _findStringDeep(data, ['access_token', 'accessToken']);
      final newRefresh = _findStringDeep(data, [
        'refresh_token',
        'refreshToken',
      ]);

      if (newAccess == null) {
        throw Exception('刷新令牌返回数据无效');
      }

      // 保存新 token
      await StorageManager.set(StorageKeys.accessToken, newAccess);
      if (newRefresh != null) {
        await StorageManager.set(StorageKeys.refreshToken, newRefresh);
      }

      // 保存过期时间
      final expiresIn = data is Map ? data['expires_in'] : null;
      if (expiresIn != null) {
        final expiresAt =
            DateTime.now().millisecondsSinceEpoch +
            (expiresIn is int
                    ? expiresIn
                    : int.tryParse(expiresIn.toString()) ?? 3600) *
                1000;
        await StorageManager.set(StorageKeys.tokenExpiresAt, expiresAt);
      }

      // 唤醒排队的请求
      for (var c in _waitQueue) {
        c.complete();
      }
      _waitQueue.clear();

      // 用新 token 重试当前请求
      final request = err.requestOptions;
      request.headers['authorization'] = 'Bearer $newAccess';

      final response = await DioClient.dio.fetch(request);
      return handler.resolve(response);
    } catch (e) {
      AppLogger.warning('Auth', '登录凭据刷新失败，将退出当前账号');

      for (var c in _waitQueue) {
        c.complete();
      }
      _waitQueue.clear();

      await _logout();
      return handler.reject(_silentCancel(err.requestOptions));
    } finally {
      _isRefreshing = false;
    }
  }

  DioException _silentCancel(RequestOptions options) {
    return DioException(
      requestOptions: options,
      type: DioExceptionType.cancel,
      error: 'silent_auth_cancel',
    );
  }

  Future<void> _logout() async {
    if (_logoutScheduled) return;
    _logoutScheduled = true;

    AppLogger.info('Auth', '登录状态已失效，正在退出当前账号');
    await StorageManager.delete(StorageKeys.accessToken);
    await StorageManager.delete(StorageKeys.refreshToken);
    await StorageManager.delete(StorageKeys.tokenExpiresAt);

    final logout = onLogout;
    if (logout != null) {
      await logout();
    }
    _logoutScheduled = false;
  }

  bool get _isAlreadyLoggedOut {
    return StorageManager.get<String>(StorageKeys.accessToken) == null &&
        StorageManager.get<String>(StorageKeys.refreshToken) == null;
  }

  static String? _findStringDeep(dynamic value, List<String> keys) {
    if (value is Map) {
      for (final key in keys) {
        final v = value[key];
        if (v != null && v.toString().isNotEmpty) return v.toString();
      }
      for (final entry in value.entries) {
        if (entry.value is Map) {
          final found = _findStringDeep(entry.value, keys);
          if (found != null) return found;
        }
      }
    }
    return null;
  }
}
