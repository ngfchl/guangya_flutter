import 'package:dio/dio.dart';

const String noToastHeader = 'NoToast';
const String suppressErrorToastExtra = 'suppressErrorToast';

bool suppressErrorToast(RequestOptions options) {
  return options.extra[suppressErrorToastExtra] == true;
}

void applyNoToastHeader(RequestOptions options) {
  String? matchedKey;
  Object? matchedValue;
  for (final entry in options.headers.entries) {
    if (entry.key.toLowerCase() == noToastHeader.toLowerCase()) {
      matchedKey = entry.key;
      matchedValue = entry.value;
      break;
    }
  }

  if (matchedKey == null) return;
  options.headers.remove(matchedKey);
  if (_isNoToastValue(matchedValue)) {
    options.extra[suppressErrorToastExtra] = true;
  }
}

bool _isNoToastValue(Object? value) {
  if (value == null) return true;
  final text = value.toString().trim().toLowerCase();
  return text.isEmpty || text == '1' || text == 'true' || text == 'yes';
}

/// Extracts a human-readable message from various response shapes
String? extractHttpMessage(dynamic value) {
  if (value == null) return null;
  if (value is String) return value.trim().isEmpty ? null : value.trim();
  if (value is Map) {
    for (final key in const ['message', 'msg', 'info', 'detail', 'error']) {
      final message = extractHttpMessage(value[key]);
      if (message != null) return message;
    }
    return extractHttpMessage(value['data']);
  }
  if (value is Iterable) {
    final messages = value
        .map(extractHttpMessage)
        .whereType<String>()
        .where((message) => message.trim().isNotEmpty)
        .toList();
    return messages.isEmpty ? null : messages.join('\n');
  }
  return null;
}

/// Build a user-friendly toast message from request context + detail
String requestToastMessage(RequestOptions options, String detail) {
  final endpoint = _describePath(options.path);
  final trimmed = detail.trim();
  if (trimmed.isEmpty) return endpoint;
  return '$endpoint：$trimmed';
}

String _describePath(String path) {
  if (path.contains('/auth')) return '认证接口';
  if (path.contains('/token')) return '令牌接口';
  if (path.contains('/file')) return '文件接口';
  if (path.contains('/share')) return '分享接口';
  if (path.contains('/res')) return '资源接口';
  if (path.contains('/task') || path.contains('/cloud')) return '云下载接口';
  return '接口请求';
}

/// Custom exception for API errors
class ApiException implements Exception {
  final int? status;
  final String message;

  ApiException({this.status, required this.message});

  @override
  String toString() => message;
}

class AuthTokens {
  final String accessToken;
  final String? refreshToken;
  final double? expiresIn;

  AuthTokens({
    required this.accessToken,
    this.refreshToken,
    this.expiresIn,
  });
}
