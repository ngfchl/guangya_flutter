import 'package:dio/dio.dart';

import '../http_error.dart';
import '../../logging/app_logger.dart';

class AppLogInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
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
      '${_actionName(err.requestOptions.path)}失败（状态码 ${status ?? '-'}，原因：$detail）',
    );
    handler.next(err);
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
    if (path.contains('/auth/token')) return '刷新登录凭据';
    if (path.contains('/auth/')) return '登录认证';
    if (path.contains('/tmdb')) return '获取影视资料';
    return '云盘服务请求';
  }
}
