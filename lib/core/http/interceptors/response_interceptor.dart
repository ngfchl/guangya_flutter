import 'dart:convert';
import 'package:dio/dio.dart';

import '../http_error.dart';

class ResponseInterceptor extends Interceptor {
  /// Extra key: true = account API (skip business code check)
  static const String skipCodeCheckKey = 'skipBusinessCodeCheck';

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final data = response.data;

    // 流式响应直接放行
    if (data is ResponseBody) {
      return handler.next(response);
    }

    // 尝试解析 JSON
    if (data is String) {
      try {
        response.data = jsonDecode(data);
      } catch (_) {
        // non-JSON response, pass through
      }
    }

    final body = response.data;

    if (body is! Map) {
      return handler.next(response);
    }

    // Account API 跳过业务 code 检查（响应格式是 {data: {...}}，没有 code 字段）
    final skipCodeCheck =
        response.requestOptions.extra[skipCodeCheckKey] == true ||
        response.requestOptions.headers['x-skip-code-check'] == true;

    if (skipCodeCheck) {
      return handler.next(response);
    }

    // 业务 API：检查 code 字段
    final code = parseBusinessCode(body['code']);
    final message = extractHttpMessage(body);

    // code == 0/200 视为成功。不同网关返回的业务成功码不完全一致。
    if (code == null || code == 0 || code == 200) {
      if (message != null && message.isNotEmpty) {
        response.extra['success_message'] = message;
      }
      return handler.next(response);
    }

    // 其他 code 视为业务错误
    final errorMsg = message ?? _defaultErrorMessage(code);
    return handler.reject(
      DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
        error: errorMsg,
      ),
    );
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.type == DioExceptionType.cancel) {
      return handler.next(err);
    }

    return handler.next(err);
  }

  static String? _defaultErrorMessage(dynamic code) {
    if (code == 400) return '请求参数错误';
    if (code == 401) return '未授权，请重新登录';
    if (code == 403) return '没有权限执行此操作';
    if (code == 404) return '接口不存在';
    if (code == 500) return '服务器内部错误';
    return '请求失败 ($code)';
  }
}
