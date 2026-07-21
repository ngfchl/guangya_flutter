import 'dart:convert';
import 'dart:math';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../core/http/dio_client.dart';
import '../core/http/http.dart';
import '../core/logging/app_logger.dart';
import '../core/http/http_error.dart';
import '../core/config/app_config.dart';
import '../core/utils/json_deep.dart';

/// API client for Guangya Cloud Drive (光鸭云盘).
/// 基于 Dio 封装，参考 harvest_flutter 的 HTTP 架构。
class GuangyaAPI {
  String accessToken;
  String? refreshTokenValue;
  DateTime? tokenExpiresAt;
  final String deviceID;
  final Dio? _tmdbDio;
  final Duration _tmdbRetryBaseDelay;

  GuangyaAPI({
    this.accessToken = '',
    String? refreshToken,
    String? deviceID,
    Dio? tmdbDio,
    Duration tmdbRetryBaseDelay = const Duration(milliseconds: 300),
  }) : deviceID = deviceID ?? _generateDeviceID(),
       _tmdbDio = tmdbDio,
       _tmdbRetryBaseDelay = tmdbRetryBaseDelay;

  static String _generateDeviceID() {
    return 'flutter-${DateTime.now().millisecondsSinceEpoch}';
  }

  /// Update tokens from a JSON response.
  AuthTokens? updateTokens(Map<String, dynamic> value) {
    final access = JsonDeep.findString(value, ['access_token', 'accessToken']);
    if (access == null) return null;
    accessToken = access;
    refreshTokenValue =
        JsonDeep.findString(value, ['refresh_token', 'refreshToken']) ??
        refreshTokenValue;
    final expires = JsonDeep.findInt(value, ['expires_in', 'expiresIn']);
    if (expires != null) {
      tokenExpiresAt = DateTime.now().add(Duration(seconds: expires));
    }
    return AuthTokens(
      accessToken: access,
      refreshToken: refreshTokenValue,
      expiresIn: expires?.toDouble(),
    );
  }

  void clearTokens() {
    accessToken = '';
    refreshTokenValue = null;
    tokenExpiresAt = null;
  }

  // ── Authentication ──────────────────────────────────────────────────

  Future<Map<String, dynamic>> loginSMSInit(
    String phoneNumber, {
    String? captchaToken,
  }) async {
    final body = <String, dynamic>{
      'client_id': AppConfig.clientID,
      'action': 'POST:/v1/auth/verification',
      'device_id': deviceID,
      'meta': {'phone_number': phoneNumber},
    };
    if (captchaToken != null) body['captcha_token'] = captchaToken;
    return Http.accountRequest('/v1/shield/captcha/init', body: body);
  }

  Future<Map<String, dynamic>> loginSMSSend(
    String phoneNumber, {
    String captchaToken = '',
    String target = 'ANY',
  }) async {
    return Http.accountRequest(
      '/v1/auth/verification',
      body: {
        'phone_number': phoneNumber,
        'target': target,
        'client_id': AppConfig.clientID,
      },
      extraHeaders: {'x-captcha-token': captchaToken},
    );
  }

  Future<Map<String, dynamic>> loginSMSVerify(
    String verificationID,
    String verificationCode,
  ) async {
    return Http.accountRequest(
      '/v1/auth/verification/verify',
      body: {
        'verification_id': verificationID,
        'verification_code': verificationCode,
        'client_id': AppConfig.clientID,
      },
    );
  }

  Future<Map<String, dynamic>> loginSMSSignIn({
    required String code,
    required String verificationToken,
    required String username,
    required String captchaToken,
  }) async {
    final result = await Http.accountRequest(
      '/v1/auth/signin',
      body: {
        'verification_code': code,
        'verification_token': verificationToken,
        'username': username,
        'client_id': AppConfig.clientID,
      },
      extraHeaders: {'x-captcha-token': captchaToken},
    );
    updateTokens(result);
    return result;
  }

  Future<Map<String, dynamic>> loginQRInit() async {
    return Http.accountRequest(
      '/v1/auth/device/code',
      body: {'scope': 'user', 'client_id': AppConfig.clientID},
    );
  }

  Future<Map<String, dynamic>> loginQRPoll(String token) async {
    final result = await Http.accountRequest(
      '/v1/auth/token',
      body: {
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        'device_code': token,
        'client_id': AppConfig.clientID,
      },
    );
    updateTokens(result);
    return result;
  }

  Future<Map<String, dynamic>> refreshAccessToken([String? token]) async {
    final t = token ?? refreshTokenValue;
    if (t == null) throw Exception('没有可用的刷新令牌');
    final result = await Http.accountRequest(
      '/v1/auth/token',
      body: {
        'client_id': AppConfig.clientID,
        'grant_type': 'refresh_token',
        'refresh_token': t,
      },
      extraHeaders: {'x-action': '401'},
    );
    updateTokens(result);
    return result;
  }

  Future<Map<String, dynamic>> userInfo() async {
    // The current account gateway exposes this REST resource as GET. Older
    // deployments accepted POST, so retain it as a compatibility fallback.
    try {
      return await Http.accountRequest(
        '/v1/user/me',
        method: 'GET',
        body: null,
        authenticated: true,
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status != 404 && status != 405 && status != 501) rethrow;
      AppLogger.warning('Auth', '账户资料 GET 接口不可用（$status），正在尝试兼容请求');
      return Http.accountRequest(
        '/v1/user/me',
        body: null,
        authenticated: true,
      );
    }
  }

  /// 云盘总容量、已用容量、会员与直链流量信息。
  Future<Map<String, dynamic>> cloudAssets() async {
    final response = await Http.apiRequest('/assets/v1/get_assets');
    final data = response['data'];
    return data is Map<String, dynamic>
        ? data
        : data is Map
        ? Map<String, dynamic>.from(data)
        : const {};
  }

  // ── Cloud downloads ────────────────────────────────────────────────

  Future<Map<String, dynamic>> cloudTaskList({
    int page = 0,
    int pageSize = 50,
    List<int> status = const [0, 1, 3, 4],
  }) async {
    return Http.apiRequest(
      '/nd.bizcloudcollection.s/v1/list_task',
      body: {'page': page, 'pageSize': pageSize, 'status': status},
    );
  }

  Future<Map<String, dynamic>> cloudResolveURL(String url) async {
    return Http.apiRequest(
      '/nd.bizcloudcollection.s/v1/resolve_res',
      body: {'url': url},
    );
  }

  Future<Map<String, dynamic>> cloudResolveTorrent(File torrentFile) async {
    final bytes = await torrentFile.readAsBytes();
    final formData = FormData.fromMap({
      'torrent': MultipartFile.fromBytes(bytes, filename: 'file.torrent'),
    });
    return Http.apiRequest(
      '/nd.bizcloudcollection.s/v1/resolve_torrent',
      body: formData,
    );
  }

  Future<Map<String, dynamic>> cloudCreateTask(
    String url, {
    String? parentID,
  }) async {
    return Http.apiRequest(
      '/nd.bizcloudcollection.s/v1/create_task',
      body: {'url': url, 'parentId': parentID ?? ''},
    );
  }

  Future<Map<String, dynamic>> taskStatus(String taskID) async {
    return Http.apiRequest(
      '/nd.bizuserres.s/v1/get_task_status',
      body: {'taskId': taskID},
    );
  }

  // ── File system ────────────────────────────────────────────────────

  Future<Map<String, dynamic>> fsFiles({
    String? parentID,
    int page = 0,
    int pageSize = 50,
    int orderBy = 0,
    int sortType = 0,
    List<int>? fileTypes,
    int? resType,
    int? dirType,
    bool needPlayRecord = false,
  }) async {
    final body = <String, dynamic>{
      'parentId': parentID ?? '',
      'page': page,
      'pageSize': pageSize,
      'orderBy': orderBy,
      'sortType': sortType,
    };
    if (fileTypes != null) body['fileTypes'] = fileTypes;
    if (resType != null) body['resType'] = resType;
    if (dirType != null) body['dirType'] = dirType;
    if (needPlayRecord) body['needPlayRecord'] = true;
    return Http.apiRequest('/userres/v1/file/get_file_list', body: body);
  }

  /// Searches the full cloud drive server-side instead of walking every folder.
  Future<Map<String, dynamic>> searchFiles(
    String name, {
    int page = 0,
    int pageSize = 100,
  }) {
    return Http.apiRequest(
      '/userres/v1/file/search_files',
      body: {'page': page, 'pageSize': pageSize, 'name': name},
    );
  }

  Future<Map<String, dynamic>> fsCreateDir(
    String name, {
    String? parentID,
    bool failIfNameExist = false,
  }) async {
    final body = <String, dynamic>{'dirName': name, 'parentId': parentID ?? ''};
    if (failIfNameExist) body['failIfNameExist'] = true;
    return Http.apiRequest(
      '/nd.bizuserres.s/v1/file/create_dir',
      body: body,
      allowedCodes: failIfNameExist ? [159] : [],
    );
  }

  Future<Map<String, dynamic>> fsCopy(
    List<String> fileIDs, {
    String? parentID,
  }) async {
    return Http.apiRequest(
      '/nd.bizuserres.s/v1/file/copy_file',
      body: {'fileIds': fileIDs, 'parentId': parentID ?? ''},
    );
  }

  Future<Map<String, dynamic>> fsMove(
    List<String> fileIDs, {
    String? parentID,
  }) async {
    return Http.apiRequest(
      '/nd.bizuserres.s/v1/file/move_file',
      body: {'fileIds': fileIDs, 'parentId': parentID ?? ''},
    );
  }

  Future<Map<String, dynamic>> fsDelete(List<String> fileIDs) async {
    return Http.apiRequest(
      '/nd.bizuserres.s/v1/file/delete_file',
      body: {'fileIds': fileIDs},
    );
  }

  Future<Map<String, dynamic>> fsRecycle(List<String> fileIDs) async {
    return Http.apiRequest(
      '/nd.bizuserres.s/v1/file/recycle_file',
      body: {'fileIds': fileIDs},
    );
  }

  Future<Map<String, dynamic>> fsClearRecycleBin() async {
    return Http.apiRequest('/nd.bizuserres.s/v1/file/clear_recycle_bin');
  }

  Future<Map<String, dynamic>> fsRename(String fileID, String newName) async {
    return Http.apiRequest(
      '/nd.bizuserres.s/v1/file/rename',
      body: {'fileId': fileID, 'newName': newName},
    );
  }

  Future<Map<String, dynamic>> fsDetail(String fileID) async {
    return Http.apiRequest(
      '/nd.bizuserres.s/v1/file/get_file_detail',
      body: {'fileId': fileID},
    );
  }

  Future<Map<String, dynamic>> fsImageList() async {
    return fsFiles(
      parentID: '*',
      orderBy: 3,
      sortType: 1,
      fileTypes: [1],
      resType: 1,
    );
  }

  Future<Map<String, dynamic>> fsVideoList() async {
    return fsFiles(
      parentID: '*',
      orderBy: 3,
      sortType: 1,
      fileTypes: [2],
      resType: 1,
    );
  }

  Future<Map<String, dynamic>> fsAudioList() async {
    return fsFiles(
      parentID: '*',
      orderBy: 3,
      sortType: 1,
      fileTypes: [3],
      resType: 1,
      needPlayRecord: true,
    );
  }

  Future<Map<String, dynamic>> fsDocumentList() async {
    return fsFiles(
      parentID: '*',
      orderBy: 3,
      sortType: 1,
      fileTypes: [4],
      resType: 1,
    );
  }

  Future<Map<String, dynamic>> fsRecycleFiles() async {
    return fsFiles(orderBy: 10, dirType: 4);
  }

  Future<Map<String, dynamic>> downloadURL(String fileID) async {
    return Http.apiRequest(
      '/nd.bizuserres.s/v1/get_res_download_url',
      body: {'fileId': fileID},
    );
  }

  Future<Map<String, dynamic>> vodDownloadURL(
    String fileID,
    String gcid,
  ) async {
    return Http.apiRequest(
      '/userres/v1/file/get_vod_download_url',
      body: {'fileId': fileID, 'gcid': gcid},
    );
  }

  Future<Map<String, dynamic>> recentViewed({
    int pageSize = 100,
    String cursor = '',
  }) async {
    return Http.apiRequest(
      '/userres/v1/get_user_action',
      body: {'cursor': cursor, 'pageSize': pageSize},
    );
  }

  Future<Map<String, dynamic>> recentRestored({int pageSize = 100}) async {
    return Http.apiRequest(
      '/userres/v1/get_restore_list',
      body: {'pageSize': pageSize, 'orderBy': 2, 'sortType': 1},
    );
  }

  // ── Shares ─────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> shareCreate(
    List<String> fileIDs, {
    required String title,
    int validateDuration = 0,
    int shareType = 1,
    String code = '',
    bool autoFillCode = true,
    String trafficLimit = '0',
    int maxRestoreCount = 0,
    int downloadType = 1,
  }) async {
    return Http.apiRequest(
      '/nd.bizuserres.s/v1/share_file',
      body: {
        'fileIds': fileIDs,
        'title': title,
        'validateDuration': validateDuration,
        'shareType': shareType,
        'code': code,
        'autoFillCode': autoFillCode,
        'trafficLimit': trafficLimit,
        'maxRestoreCount': maxRestoreCount,
        'downloadType': downloadType,
      },
    );
  }

  Future<Map<String, dynamic>> shareUserList({
    int page = 0,
    int pageSize = 50,
  }) async {
    return Http.apiRequest(
      '/nd.bizuserres.s/v1/get_share_list',
      body: {'page': page, 'pageSize': pageSize, 'orderType': 1, 'sortType': 1},
    );
  }

  Future<Map<String, dynamic>> shareDelete(List<String> ids) async {
    return Http.apiRequest(
      '/nd.bizuserres.s/v1/delete_share',
      body: {'ids': ids},
    );
  }

  Future<Map<String, dynamic>> shareUpdate(
    String shareID, {
    required String title,
    int validateDuration = 0,
    int shareType = 1,
    String code = '',
    bool autoFillCode = true,
    String trafficLimit = '0',
    int maxRestoreCount = 0,
    int downloadType = 1,
  }) async {
    return Http.apiRequest(
      '/nd.bizuserres.s/v1/update_share',
      body: {
        'id': shareID,
        'title': title,
        'validateDuration': validateDuration,
        'shareType': shareType,
        'code': code,
        'autoFillCode': autoFillCode,
        'trafficLimit': trafficLimit,
        'maxRestoreCount': maxRestoreCount,
        'downloadType': downloadType,
      },
    );
  }

  Future<Map<String, dynamic>> shareRestore(
    String accessToken,
    List<String> fileIDs, {
    String parentID = '',
  }) async {
    return Http.apiRequest(
      '/nd.bizuserres.s/v1/restore_share',
      body: {
        'accessToken': accessToken,
        'fileIds': fileIDs,
        'parentId': parentID,
      },
    );
  }

  Future<Map<String, dynamic>> shareDownloadURL(
    String fileID,
    String accessToken,
  ) async {
    return Http.apiRequest(
      '/nd.bizuserres.s/v1/get_share_download_url',
      body: {'fileId': fileID, 'accessToken': accessToken},
    );
  }

  Future<Map<String, dynamic>> shareFilesSize(
    String accessToken,
    List<String> fileIDs, {
    bool download = true,
  }) async {
    return Http.apiRequest(
      '/nd.bizuserres.s/v1/get_share_files_size',
      body: {
        'accessToken': accessToken,
        'fileIds': fileIDs,
        'download': download,
      },
    );
  }

  Future<Map<String, dynamic>> shareFilesList(
    String accessToken, {
    String parentID = '',
    int page = 1,
    int pageSize = 50,
    int orderBy = 0,
    int sortType = 0,
  }) async {
    return Http.publicRequest(
      '/nd.bizuserres.s/v1/get_share_page_files_list',
      body: {
        'accessToken': accessToken,
        'parentId': parentID,
        'page': page,
        'pageSize': pageSize,
        'orderBy': orderBy,
        'sortType': sortType,
      },
    );
  }

  Future<Map<String, dynamic>> shareSummary(String shareID) async {
    return Http.publicRequest(
      '/nd.bizuserres.s/v1/get_share_summary',
      body: {'shareId': shareID},
    );
  }

  Future<Map<String, dynamic>> shareAccessToken(
    String shareID,
    String code,
  ) async {
    return Http.publicRequest(
      '/nd.bizuserres.s/v1/get_share_access_token',
      body: {'shareId': shareID, 'code': code},
    );
  }

  // ── Upload ─────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> uploadToken({
    required String name,
    required int fileSize,
    String? parentID,
    String? md5,
  }) async {
    final res = <String, dynamic>{'fileSize': fileSize};
    if (md5 != null) res['md5'] = _base64MD5(md5);
    return Http.apiRequest(
      '/nd.bizuserres.s/v1/get_res_center_token',
      body: {
        'capacity': 2,
        'name': name,
        'res': res,
        'parentId': parentID ?? '',
      },
      allowedCodes: const [156],
    );
  }

  Future<Map<String, dynamic>> flashTransferToken({
    required String name,
    required int fileSize,
    String? parentID,
    required String md5,
  }) async {
    final normalizedMD5 = md5.trim().toLowerCase();
    return Http.apiRequest(
      '/nd.bizuserres.s/v1/get_res_center_token',
      body: {
        'capacity': 1,
        'name': name,
        'res': {'md5': normalizedMD5, 'fileSize': fileSize},
        'parentId': parentID ?? '',
      },
      allowedCodes: const [156],
    );
  }

  Future<Map<String, dynamic>> flashTransferGCIDToken({
    required String name,
    required int fileSize,
    String? parentID,
    required String gcid,
  }) async {
    final normalizedGCID = gcid.trim().toUpperCase();
    return Http.apiRequest(
      '/nd.bizuserres.s/v1/get_res_center_token',
      body: {
        'capacity': 1,
        'name': name,
        'res': {'gcid': normalizedGCID, 'fileSize': fileSize},
        'parentId': parentID ?? '',
      },
      allowedCodes: const [156],
    );
  }

  Future<Map<String, dynamic>> deleteUploadTask(List<String> taskIDs) async {
    return Http.apiRequest(
      '/nd.bizuserres.s/v1/file/delete_upload_task',
      body: {'taskIds': taskIDs},
    );
  }

  Future<Map<String, dynamic>> checkCanFlashUpload(
    String taskID,
    String gcid,
  ) async {
    return Http.apiRequest(
      '/nd.bizuserres.s/v1/check_can_flash_upload',
      body: {'taskId': taskID, 'gcid': gcid},
    );
  }

  Future<Map<String, dynamic>> uploadInfo(String taskID) async {
    return Http.apiRequest(
      '/nd.bizuserres.s/v1/file/get_info_by_task_id',
      body: {'taskId': taskID},
      allowedCodes: const [145, 146, 155, 163],
    );
  }

  Future<Map<String, dynamic>> fileUpload(
    File file, {
    String? parentID,
    String contentType = 'application/octet-stream',
    int chunkSize = 5 * 1024 * 1024,
    void Function(int sent, int total)? onProgress,
    void Function()? onProcessing,
    CancelToken? cancelToken,
  }) async {
    final name = file.uri.pathSegments.isEmpty
        ? file.path.split(Platform.pathSeparator).last
        : Uri.decodeComponent(file.uri.pathSegments.last);
    final size = await file.length();
    onProgress?.call(0, size);

    Map<String, dynamic> token;
    if (size < 1024 * 1024) {
      final bytes = await file.readAsBytes();
      final md5Base64 = base64Encode(md5.convert(bytes).bytes);
      token = await uploadToken(
        name: name,
        fileSize: size,
        parentID: parentID,
        md5: md5Base64,
      );
      final taskID = JsonDeep.findString(token, ['taskId', 'task_id']);
      if (taskID == null) {
        onProgress?.call(size, size);
        return token;
      }
      onProgress?.call(size, size);
      onProcessing?.call();
      return _waitForUploadCompletion(taskID, cancelToken: cancelToken);
    }

    token = await uploadToken(name: name, fileSize: size, parentID: parentID);
    final taskID = JsonDeep.findString(token, ['taskId', 'task_id']);
    if (taskID == null) throw Exception('响应缺少字段：taskId');

    final gcid = await _calculateFileGCID(file, size);
    final canFlash = await checkCanFlashUpload(taskID, gcid);
    if (JsonDeep.findBool(canFlash, ['canFlashUpload', 'can_flash_upload']) ==
        true) {
      onProgress?.call(size, size);
      onProcessing?.call();
      return _waitForUploadCompletion(taskID, cancelToken: cancelToken);
    }

    final tokenData = JsonDeep.findMap(token, ['data']) ?? token;
    await _cdnUploadFile(
      file,
      fileSize: size,
      tokenData: tokenData,
      contentType: contentType,
      chunkSize: chunkSize,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
    onProgress?.call(size, size);
    onProcessing?.call();
    return _waitForUploadCompletion(taskID, cancelToken: cancelToken);
  }

  Future<Map<String, dynamic>> _waitForUploadCompletion(
    String taskID, {
    CancelToken? cancelToken,
  }) async {
    const maxAttempts = 90; // 180s max wait (90 x 2s)
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (cancelToken?.isCancelled == true) {
        throw Exception('上传已取消');
      }
      try {
        final result = await uploadInfo(taskID);
        final message = extractHttpMessage(result)?.toLowerCase() ?? '';
        if (!_isUploadProcessingMessage(message)) return result;
      } on ApiException catch (error) {
        if (!_isUploadProcessingMessage(error.message.toLowerCase())) rethrow;
      }
      if (attempt + 1 < maxAttempts) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    throw Exception('云端处理上传文件超时（已等待180秒）');
  }

  bool _isUploadProcessingMessage(String message) {
    return message.contains('文件上传中') ||
        message.contains('上传处理中') ||
        message.contains('正在上传') ||
        message.contains('processing') ||
        message.contains('pending') ||
        message.contains('等待处理') ||
        message.contains('正在处理') ||
        message.contains('file is being processed');
  }

  Future<String> _cdnUploadFile(
    File file, {
    required int fileSize,
    required Map<String, dynamic> tokenData,
    required String contentType,
    required int chunkSize,
    void Function(int sent, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final creds =
        JsonDeep.findMap(tokenData, ['creds']) ?? const <String, dynamic>{};
    final accessKeyID = JsonDeep.findString(creds, [
      'accessKeyID',
      'accessKeyId',
    ]);
    final secret = JsonDeep.findString(creds, ['secretAccessKey']);
    final sessionToken = JsonDeep.findString(creds, ['sessionToken']);
    final endpoint = JsonDeep.findString(tokenData, [
      'fullEndPoint',
      'fullEndpoint',
    ]);
    final bucket = JsonDeep.findString(tokenData, ['bucketName']);
    final objectPath = JsonDeep.findString(tokenData, ['objectPath']);
    if (accessKeyID == null ||
        secret == null ||
        sessionToken == null ||
        endpoint == null ||
        bucket == null ||
        objectPath == null) {
      throw Exception('响应缺少字段：OSS token data');
    }

    final objectURL = '$endpoint/$objectPath';
    final init = await _ossRequest(
      method: 'POST',
      url: objectURL,
      bucket: bucket,
      objectKey: objectPath,
      accessKeyID: accessKeyID,
      secret: secret,
      sessionToken: sessionToken,
      subResources: {'uploads': ''},
      cancelToken: cancelToken,
    );
    final uploadID = _xmlValue(init.body, 'UploadId');
    if (uploadID == null) throw Exception('响应缺少字段：UploadId');

    final parts = <MapEntry<int, String>>[];
    final input = await file.open();
    try {
      var offset = 0;
      var number = 1;
      while (offset < fileSize) {
        if (cancelToken?.isCancelled == true) {
          throw Exception('上传已取消');
        }
        final chunk = await input.read(min(chunkSize, fileSize - offset));
        if (chunk.isEmpty) throw Exception('读取上传文件失败：文件提前结束');
        final contentMD5 = base64Encode(md5.convert(chunk).bytes);
        final response = await _ossRequest(
          method: 'PUT',
          url: objectURL,
          bucket: bucket,
          objectKey: objectPath,
          accessKeyID: accessKeyID,
          secret: secret,
          sessionToken: sessionToken,
          content: chunk,
          contentType: 'application/octet-stream',
          contentMD5: contentMD5,
          subResources: {'partNumber': '$number', 'uploadId': uploadID},
          cancelToken: cancelToken,
        );
        parts.add(
          MapEntry(number, response.headers['etag']?.replaceAll('"', '') ?? ''),
        );
        offset += chunk.length;
        onProgress?.call(offset, fileSize);
        number += 1;
      }
    } finally {
      await input.close();
    }

    final xml =
        '<?xml version="1.0" encoding="UTF-8"?><CompleteMultipartUpload>${parts.map((part) => '<Part><PartNumber>${part.key}</PartNumber><ETag>"${part.value}"</ETag></Part>').join()}</CompleteMultipartUpload>';
    final xmlBytes = utf8.encode(xml);
    final result = await _ossRequest(
      method: 'POST',
      url: objectURL,
      bucket: bucket,
      objectKey: objectPath,
      accessKeyID: accessKeyID,
      secret: secret,
      sessionToken: sessionToken,
      content: xmlBytes,
      contentType: 'application/xml',
      contentMD5: base64Encode(md5.convert(xmlBytes).bytes),
      subResources: {'uploadId': uploadID},
      cancelToken: cancelToken,
    );
    return _xmlValue(result.body, 'ETag') ?? '';
  }

  Future<({String body, Map<String, String> headers})> _ossRequest({
    required String method,
    required String url,
    required String bucket,
    required String objectKey,
    required String accessKeyID,
    required String secret,
    required String sessionToken,
    List<int> content = const [],
    String contentType = '',
    String contentMD5 = '',
    Map<String, String> subResources = const {},
    CancelToken? cancelToken,
  }) async {
    final date = HttpDate.format(DateTime.now().toUtc());
    final canonicalResource =
        '/$bucket/$objectKey${_subResourceQuery(subResources)}';
    final canonical = [
      method.toUpperCase(),
      contentMD5,
      contentType,
      date,
      'x-oss-date:$date',
      'x-oss-security-token:${sessionToken.trim()}',
      canonicalResource,
    ].join('\n');
    final signature = base64Encode(
      Hmac(sha1, utf8.encode(secret)).convert(utf8.encode(canonical)).bytes,
    );
    final uri = Uri.parse('$url${_subResourceQuery(subResources)}');
    final response = await Dio().requestUri<List<int>>(
      uri,
      data: content.isEmpty ? null : Stream.fromIterable([content]),
      options: Options(
        method: method,
        responseType: ResponseType.bytes,
        headers: {
          'Authorization': 'OSS $accessKeyID:$signature',
          'x-oss-date': date,
          'x-oss-security-token': sessionToken,
          if (contentType.isNotEmpty) 'Content-Type': contentType,
          if (contentMD5.isNotEmpty) 'Content-MD5': contentMD5,
          if (content.isNotEmpty) 'Content-Length': content.length,
        },
      ),
      cancelToken: cancelToken,
    );
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw Exception('OSS 请求失败 ($status)');
    }
    return (
      body: utf8.decode(response.data ?? const [], allowMalformed: true),
      headers: response.headers.map.map(
        (key, value) => MapEntry(key.toLowerCase(), value.join(',')),
      ),
    );
  }

  // ── TMDB ───────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> tmdbSearch(
    String query, {
    required String apiKey,
    String mediaKind = 'auto',
    String proxyHost = '',
    String proxyPort = '',
    int? year,
  }) async {
    final endpoint = mediaKind == 'movie'
        ? 'movie'
        : (mediaKind == 'tv' ? 'tv' : 'multi');
    final params = {
      'api_key': apiKey,
      'query': query,
      'language': 'zh-CN',
      'region': 'CN',
      'include_adult': 'false',
    };
    if (year != null) {
      if (mediaKind == 'movie') {
        params['primary_release_year'] = year.toString();
      } else if (mediaKind == 'tv') {
        params['first_air_date_year'] = year.toString();
      }
    }
    final uri = Uri.https('api.themoviedb.org', '/3/search/$endpoint', params);
    return _tmdbRequest(uri, proxyHost: proxyHost, proxyPort: proxyPort);
  }

  Future<Map<String, dynamic>> tmdbDetails(
    int id, {
    required String mediaKind,
    required String apiKey,
    String proxyHost = '',
    String proxyPort = '',
  }) async {
    final endpoint = mediaKind == 'tv' ? 'tv' : 'movie';
    final params = {
      'api_key': apiKey,
      'language': 'zh-CN',
      'append_to_response':
          'credits,images,external_ids,translations,alternative_titles',
      'include_image_language': 'zh-CN,zh,null,en',
    };
    final uri = Uri.https('api.themoviedb.org', '/3/$endpoint/$id', params);
    return _tmdbRequest(uri, proxyHost: proxyHost, proxyPort: proxyPort);
  }

  Future<Map<String, dynamic>> tmdbEpisodeDetails(
    int seriesID, {
    required int season,
    required int episode,
    required String apiKey,
    String proxyHost = '',
    String proxyPort = '',
  }) async {
    final params = {
      'api_key': apiKey,
      'language': 'zh-CN',
      'append_to_response': 'credits,images,translations',
      'include_image_language': 'zh-CN,zh,null,en',
    };
    final uri = Uri.https(
      'api.themoviedb.org',
      '/3/tv/$seriesID/season/$season/episode/$episode',
      params,
    );
    return _tmdbRequest(uri, proxyHost: proxyHost, proxyPort: proxyPort);
  }

  // ── HTTP helpers ───────────────────────────────────────────────────

  Future<Map<String, dynamic>> _tmdbRequest(
    Uri url, {
    String proxyHost = '',
    String proxyPort = '',
  }) async {
    const maxAttempts = 3;
    final dio = _tmdbDio ?? DioClient.dio;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final response = await dio.getUri(
          url,
          options: Options(
            headers: {'Accept': 'application/json'},
            extra: {
              tmdbRetryAttemptExtra: attempt,
              tmdbRetryMaxAttemptsExtra: maxAttempts,
            },
          ),
        );
        final statusCode = response.statusCode ?? 0;
        if (statusCode < 200 || statusCode >= 300) {
          throw Exception('TMDB 请求失败');
        }
        return Map<String, dynamic>.from(response.data as Map);
      } catch (error) {
        if (attempt >= maxAttempts || !isRetryableNetworkError(error)) {
          rethrow;
        }
        await Future<void>.delayed(_tmdbRetryBaseDelay * attempt);
      }
    }
    throw StateError('TMDB 请求重试流程异常');
  }

  // ── Helpers ───────────────────────────────────────────────────────

  static String _subResourceQuery(Map<String, String> values) {
    if (values.isEmpty) return '';
    final keys = values.keys.toList()..sort();
    return '?${keys.map((key) {
      final value = values[key] ?? '';
      return value.isEmpty ? key : '$key=$value';
    }).join('&')}';
  }

  static String? _xmlValue(String xml, String tag) {
    final match = RegExp('<$tag>(.*?)</$tag>').firstMatch(xml);
    return match?.group(1);
  }

  static String _base64MD5(String value) {
    final normalized = value.trim();
    if (!RegExp(r'^[A-Fa-f0-9]{32}$').hasMatch(normalized)) {
      return normalized;
    }
    final bytes = <int>[];
    for (var i = 0; i < normalized.length; i += 2) {
      bytes.add(int.parse(normalized.substring(i, i + 2), radix: 16));
    }
    return base64Encode(bytes);
  }

  static Future<String> _calculateFileGCID(File file, int length) async {
    final chunkSize = length <= 0x8000000
        ? 262144
        : length <= 0x10000000
        ? 524288
        : length <= 0x20000000
        ? 1048576
        : 2097152;
    final hashes = <int>[];
    final input = await file.open();
    try {
      var offset = 0;
      while (offset < length) {
        final chunk = await input.read(min(chunkSize, length - offset));
        if (chunk.isEmpty) throw Exception('读取上传文件失败：文件提前结束');
        hashes.addAll(sha1.convert(chunk).bytes);
        offset += chunk.length;
      }
    } finally {
      await input.close();
    }
    return sha1
        .convert(hashes)
        .bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join();
  }

  // ── Douban (Frodo API) ────────────────────────────────────────────

  Future<Map<String, dynamic>> doubanSearch(
    String query, {
    int count = 20,
  }) async {
    final params = {
      'q': query,
      'count': count.toString(),
      'apikey': '0ac44ae016490db2204ce0a042db2916',
    };
    final uri = Uri.https('frodo.douban.com', '/api/v2/search/movie', params);
    const maxAttempts = 2;
    // Douban Frodo API does not need the app's auth token.
    // Create a clean Dio instance without interceptors.
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      ),
    );
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final response = await dio.getUri(
          uri,
          options: Options(
            headers: {
              'Accept': 'application/json',
              'Referer':
                  'https://servicewechat.com/wx2f9b06c1de1ccfca/91/page-frame.html',
              'User-Agent': 'MicroMessenger/',
            },
          ),
        );
        final statusCode = response.statusCode ?? 0;
        if (statusCode < 200 || statusCode >= 300) {
          throw Exception('Douban 请求失败 ($statusCode)');
        }
        return Map<String, dynamic>.from(response.data as Map);
      } catch (error) {
        if (attempt >= maxAttempts || !isRetryableNetworkError(error)) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 800 * attempt));
      }
    }
    throw StateError('Douban 请求重试流程异常');
  }

  void dispose() {
    // DioClient 的 Dio 实例是静态的，不需要手动关闭
  }
}
