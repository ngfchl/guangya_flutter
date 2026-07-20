import 'package:dio/dio.dart';

import '../http_error.dart';
import '../../logging/app_logger.dart';

class AppLogInterceptor extends Interceptor {
  static const _requestIDKey = 'guangya.log.request_id';
  static const _requestStartedAtKey = 'guangya.log.started_at';
  static int _requestSequence = 0;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final requestID = (++_requestSequence).toString().padLeft(6, '0');
    options.extra[_requestIDKey] = requestID;
    options.extra[_requestStartedAtKey] = DateTime.now().microsecondsSinceEpoch;
    AppLogger.debug('HTTP', '${_requestLabel(options)} 开始');
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final options = response.requestOptions;
    final elapsed = _elapsed(options);
    final message =
        '${_requestLabel(options)} 完成（状态码 ${response.statusCode ?? '-'}，耗时 ${elapsed}ms）';
    if (elapsed >= 5000) {
      AppLogger.warning('HTTP', '慢请求：$message');
    } else {
      AppLogger.debug('HTTP', message);
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final status = err.response?.statusCode;
    final serverMessage = err.response?.data is Map
        ? extractHttpMessage(err.response?.data)
        : null;
    final detail = serverMessage?.trim().isNotEmpty == true
        ? serverMessage!
        : (err.error?.toString().trim().isNotEmpty == true
              ? err.error.toString()
              : err.type.name);
    AppLogger.error(
      'HTTP',
      '${_requestLabel(err.requestOptions)} 失败（状态码 ${status ?? '-'}，'
          '耗时 ${_elapsed(err.requestOptions)}ms，类型 ${err.type.name}，原因：$detail）',
    );
    handler.next(err);
  }

  static String _requestLabel(RequestOptions options) {
    final requestID = options.extra[_requestIDKey]?.toString() ?? '未编号';
    final uri = options.uri;
    final endpoint = uri.host.isEmpty
        ? uri.path
        : '${uri.host}${uri.hasPort ? ':${uri.port}' : ''}${uri.path}';
    return '[请求 $requestID] ${_actionName(uri.path)} '
        '${options.method.toUpperCase()} $endpoint';
  }

  static int _elapsed(RequestOptions options) {
    final startedAt = options.extra[_requestStartedAtKey];
    if (startedAt is! int) return 0;
    return ((DateTime.now().microsecondsSinceEpoch - startedAt) / 1000).round();
  }

  static String _actionName(String path) {
    if (path.contains('/v1/user/me')) return '获取账户资料';
    if (path.contains('/assets/v1/get_assets')) return '获取云盘空间信息';
    if (path.contains('/search_files')) return '搜索云盘文件';
    if (path.contains('/get_file_list')) return '读取文件列表';
    if (path.contains('/get_file_detail')) return '读取文件详情';
    if (path.contains('/create_dir')) return '新建文件夹';
    if (path.contains('/move_file')) return '移动文件';
    if (path.contains('/copy_file')) return '复制文件';
    if (path.contains('/rename')) return '重命名文件';
    if (path.contains('/recycle_file')) return '移入回收站';
    if (path.contains('/delete_file')) return '删除文件';
    if (path.contains('/get_task_status')) return '获取云盘任务状态';
    if (path.contains('/list_task')) return '读取云盘任务';
    if (path.contains('/resolve_res')) return '解析云盘资源';
    if (path.contains('/resolve_torrent')) return '解析种子文件';
    if (path.contains('/create_task')) return '创建云盘任务';
    if (path.contains('/auth/token')) return '刷新登录凭据';
    if (path.contains('/auth/')) return '登录认证';
    if (path.contains('/tmdb')) return '获取影视资料';
    return '云盘服务请求';
  }
}
