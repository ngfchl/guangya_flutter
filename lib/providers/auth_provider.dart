import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/legacy.dart';
import '../core/logging/app_logger.dart';
import '../core/http/http_error.dart';
import '../core/storage/storage_manager.dart';
import '../core/utils/format_bytes.dart';
import '../api/guangya_api.dart';

class AuthState {
  final bool isSignedIn;
  final bool isLoading;
  final bool isRefreshing;
  final Map<String, dynamic>? userInfo;
  final String? errorMessage;
  final String phoneNumber;
  final String verificationCode;
  final String captchaToken;
  final String verificationID;
  final int codeCountdown;
  final String qrPayload;
  final String qrToken;
  final String qrStatus;

  const AuthState({
    this.isSignedIn = false,
    this.isLoading = true,
    this.isRefreshing = false,
    this.userInfo,
    this.errorMessage,
    this.phoneNumber = '+86 ',
    this.verificationCode = '',
    this.captchaToken = '',
    this.verificationID = '',
    this.codeCountdown = 0,
    this.qrPayload = '',
    this.qrToken = '',
    this.qrStatus = '等待生成二维码',
  });

  AuthState copyWith({
    bool? isSignedIn,
    bool? isLoading,
    bool? isRefreshing,
    Map<String, dynamic>? userInfo,
    bool clearUserInfo = false,
    String? errorMessage,
    bool clearError = false,
    String? phoneNumber,
    String? verificationCode,
    String? captchaToken,
    String? verificationID,
    int? codeCountdown,
    String? qrPayload,
    String? qrToken,
    String? qrStatus,
  }) {
    return AuthState(
      isSignedIn: isSignedIn ?? this.isSignedIn,
      isLoading: isLoading ?? this.isLoading,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      userInfo: clearUserInfo ? null : (userInfo ?? this.userInfo),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      phoneNumber: phoneNumber ?? this.phoneNumber,
      verificationCode: verificationCode ?? this.verificationCode,
      captchaToken: captchaToken ?? this.captchaToken,
      verificationID: verificationID ?? this.verificationID,
      codeCountdown: codeCountdown ?? this.codeCountdown,
      qrPayload: qrPayload ?? this.qrPayload,
      qrToken: qrToken ?? this.qrToken,
      qrStatus: qrStatus ?? this.qrStatus,
    );
  }

  // ── Derived getters ────────────────────────────────────────────

  String get userName =>
      _findStringDeep(userInfo, ['nickname', 'name', 'username']) ?? '光鸭用户';

  String get memberLevel =>
      _findStringDeep(userInfo, ['vipName', 'memberName', 'memberLevelName']) ??
      _memberLevelFromAssets;

  String get _memberLevelFromAssets {
    final svipStatus = _findInt64Deep(userInfo, ['svipStatus']) ?? 0;
    if (svipStatus > 0) return '超级会员';
    final vipStatus = _findInt64Deep(userInfo, ['vipStatus']) ?? 0;
    return vipStatus > 0 ? '会员' : '普通会员';
  }

  int? get capacity =>
      _findInt64Deep(userInfo, ['totalSpaceSize', 'capacity', 'totalCapacity']);
  int? get usedCapacity =>
      _findInt64Deep(userInfo, ['usedSpaceSize', 'usedCapacity', 'usedSpace']);

  String get capacityText {
    if (capacity == null) return '空间信息暂不可用';
    return '${FormatBytes.format(usedCapacity ?? 0)} / ${FormatBytes.format(capacity!)}';
  }

  // ── Static helpers ─────────────────────────────────────────────

  static String? _findStringDeep(
    Map<String, dynamic>? json,
    List<String> keys,
  ) {
    if (json == null) return null;
    for (final key in keys) {
      final v = json[key];
      if (v != null && v.toString().isNotEmpty) return v.toString();
    }
    for (final entry in json.entries) {
      if (entry.value is Map<String, dynamic>) {
        final found = _findStringDeep(
          entry.value as Map<String, dynamic>,
          keys,
        );
        if (found != null) return found;
      }
    }
    return null;
  }

  static int? _findInt64Deep(Map<String, dynamic>? json, List<String> keys) {
    if (json == null) return null;
    for (final key in keys) {
      final v = json[key];
      if (v != null) return v is int ? v : int.tryParse(v.toString());
    }
    return null;
  }
}

class AuthNotifier extends StateNotifier<AuthState> {
  final GuangyaAPI _api = GuangyaAPI(
    deviceID: StorageManager.get<String>(StorageKeys.deviceID),
  );
  Timer? _qrPollingTimer;
  Timer? _countdownTimer;

  GuangyaAPI get api => _api;

  AuthNotifier() : super(const AuthState()) {
    _api.accessToken = '';
    tryRestoreSession();
  }

  Future<void> tryRestoreSession() async {
    final access = StorageManager.get<String>(StorageKeys.accessToken) ?? '';
    final refresh = StorageManager.get<String>(StorageKeys.refreshToken);

    _api.accessToken = access;
    _api.refreshTokenValue = refresh;

    if (access.isNotEmpty || refresh != null) {
      try {
        AppLogger.info('Auth', '正在恢复登录状态');
        await _api.refreshAccessToken();
        await _saveTokens();
        state = state.copyWith(isSignedIn: true);
        await loadAccount();
        AppLogger.info('Auth', '登录状态恢复完成');
      } catch (_) {
        AppLogger.warning('Auth', '登录状态恢复失败，已清除本地令牌');
        state = state.copyWith(isSignedIn: false);
        _api.clearTokens();
        await _clearTokens();
      }
    }
    state = state.copyWith(isLoading: false);
  }

  Future<void> loadAccount() async {
    AppLogger.info('Auth', '正在获取账户资料与云盘空间信息');
    final userInfoFuture = _api.userInfo();
    final assetsFuture = _api.cloudAssets();
    try {
      final userInfo = await userInfoFuture;
      Map<String, dynamic> assets = const {};
      try {
        assets = await assetsFuture;
      } catch (_) {
        AppLogger.warning('Auth', '云盘空间信息暂时不可用');
      }
      state = state.copyWith(userInfo: {...userInfo, 'assets': assets});
      AppLogger.info('Auth', '账户资料与云盘空间信息获取完成');
    } on DioException catch (error) {
      await assetsFuture.catchError((_) => <String, dynamic>{});
      final status = error.response?.statusCode;
      if (status == 404 || status == 501) {
        AppLogger.warning('Auth', '账户信息接口暂不可用 ($status)，已保留登录态');
        return;
      }
      final message = error.response?.data is Map
          ? extractHttpMessage(error.response?.data) ?? error.type.name
          : error.type.name;
      AppLogger.error('Auth', '加载账户信息失败', error: message);
      state = state.copyWith(errorMessage: message);
    } catch (e) {
      AppLogger.error('Auth', '加载账户信息失败', error: e);
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  // ── SMS Login ─────────────────────────────────────────────────────

  void updatePhoneNumber(String value) {
    state = state.copyWith(phoneNumber: value);
  }

  void updateVerificationCode(String value) {
    state = state.copyWith(verificationCode: value);
  }

  Future<void> sendVerificationCode() async {
    state = state.copyWith(clearError: true);
    final cleanPhone = state.phoneNumber.replaceAll(RegExp(r'[^\d]'), '');
    AppLogger.info('SMS', '发送验证码 — 原始手机号: ${state.phoneNumber}, 清洗后: $cleanPhone');
    if (cleanPhone.length < 8) {
      state = state.copyWith(errorMessage: '请输入有效的手机号');
      return;
    }

    try {
      // Step 1: 初始化验证码（获取 captcha_token）
      AppLogger.info('SMS', '[Step 1] loginSMSInit 请求中…');
      final initResult = await _api.loginSMSInit(cleanPhone);
      AppLogger.info('SMS', '[Step 1] loginSMSInit 响应: $initResult');
      final captcha = AuthState._findStringDeep(initResult, [
        'captcha_token',
        'captchaToken',
      ]);
      if (captcha == null) {
        final verifyUrl = AuthState._findStringDeep(initResult, [
          'url',
          'verify_url',
        ]);
        if (verifyUrl != null) {
          AppLogger.warning('SMS', '[Step 1] 需要完成验证码验证: $verifyUrl');
          throw Exception('需要完成验证码验证后再发送短信');
        }
        AppLogger.error('SMS', '[Step 1] 响应中未找到 captcha_token', error: initResult);
        throw Exception('获取验证码令牌失败');
      }
      AppLogger.info('SMS', '[Step 1] captcha_token: ${captcha.substring(0, captcha.length > 20 ? 20 : captcha.length)}…');
      state = state.copyWith(captchaToken: captcha);

      // Step 2: 发送短信验证码
      AppLogger.info('SMS', '[Step 2] loginSMSSend 请求中… phone=$cleanPhone');
      final sendResult = await _api.loginSMSSend(
        cleanPhone,
        captchaToken: captcha,
      );
      AppLogger.info('SMS', '[Step 2] loginSMSSend 响应: $sendResult');

      // Step 3: 提取 verification_id
      final vID = AuthState._findStringDeep(sendResult, [
        'verification_id',
        'verificationId',
        'id',
      ]);
      if (vID != null && vID.isNotEmpty) {
        AppLogger.info('SMS', '[Step 3] verification_id: $vID');
        state = state.copyWith(verificationID: vID);
      } else {
        AppLogger.error('SMS', '[Step 3] 响应中未找到 verification_id', error: sendResult);
        throw Exception('获取 verification_id 失败，请重试');
      }
      _startCountdown();
      AppLogger.info('SMS', '验证码发送成功，开始倒计时');
    } on ApiException catch (e) {
      AppLogger.error('SMS', '发送验证码失败 (API)', error: '${e.status} ${e.message}');
      state = state.copyWith(errorMessage: e.message);
    } catch (e) {
      AppLogger.error('SMS', '发送验证码失败', error: e);
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  void _startCountdown() {
    state = state.copyWith(codeCountdown: 60);
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final next = state.codeCountdown - 1;
      if (next <= 0) {
        timer.cancel();
        state = state.copyWith(codeCountdown: 0);
      } else {
        state = state.copyWith(codeCountdown: next);
      }
    });
  }

  Future<void> verifySMSCode() async {
    state = state.copyWith(clearError: true);
    AppLogger.info('SMS', '验证登录 — verificationID: ${state.verificationID.isEmpty ? "(空)" : state.verificationID}, code: ${state.verificationCode}, captchaToken: ${state.captchaToken.isEmpty ? "(空)" : "${state.captchaToken.substring(0, state.captchaToken.length > 15 ? 15 : state.captchaToken.length)}…"}');
    if (state.verificationID.isEmpty) {
      state = state.copyWith(errorMessage: '请先发送验证码');
      return;
    }
    if (state.verificationCode.trim().isEmpty) {
      state = state.copyWith(errorMessage: '请输入验证码');
      return;
    }
    try {
      // Step 4: 验证短信验证码
      AppLogger.info('SMS', '[Step 4] loginSMSVerify 请求中… verificationID=${state.verificationID}, code=${state.verificationCode}');
      final verifyResult = await _api.loginSMSVerify(
        state.verificationID,
        state.verificationCode,
      );
      AppLogger.info('SMS', '[Step 4] loginSMSVerify 响应: $verifyResult');
      final vToken = AuthState._findStringDeep(verifyResult, [
        'verification_token',
        'verificationToken',
      ]);
      if (vToken == null) {
        AppLogger.error('SMS', '[Step 4] 响应中未找到 verification_token', error: verifyResult);
        throw Exception('验证码验证失败：服务端未返回 verification_token');
      }
      AppLogger.info('SMS', '[Step 4] verification_token: ${vToken.substring(0, vToken.length > 20 ? 20 : vToken.length)}…');

      // Step 5: 使用验证令牌登录
      final username = state.phoneNumber.trim();
      final signinCode = state.verificationCode.trim();
      AppLogger.info('SMS', '[Step 5] loginSMSSignIn 请求中… code=$signinCode, username=$username');
      final signinResult = await _api.loginSMSSignIn(
        code: signinCode,
        verificationToken: vToken,
        username: username,
        captchaToken: state.captchaToken,
      );
      AppLogger.info('SMS', '[Step 5] loginSMSSignIn 响应: hasAccessToken=${signinResult.containsKey("access_token") || signinResult.containsKey("accessToken")}');

      // Step 6: 登录成功
      state = state.copyWith(isSignedIn: true);
      await _saveTokens();
      AppLogger.info('SMS', '[Step 6] 登录成功，正在加载账户信息…');
      await loadAccount();
      AppLogger.info('SMS', '[Step 6] 登录流程完成');
    } on ApiException catch (e) {
      AppLogger.error('SMS', '验证登录失败 (API ${e.status})', error: e.message);
      state = state.copyWith(errorMessage: e.message);
    } catch (e) {
      AppLogger.error('SMS', '验证登录失败', error: e);
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  // ── QR Login ──────────────────────────────────────────────────────

  Future<void> initQRLogin() async {
    state = state.copyWith(clearError: true);
    try {
      final result = await _api.loginQRInit();
      final token =
          AuthState._findStringDeep(result, ['device_code', 'deviceCode']) ??
          '';
      final payload =
          AuthState._findStringDeep(result, [
            'verification_uri_complete',
            'verificationUriComplete',
            'qr_url',
            'qrUrl',
            'url',
            'verification_uri',
            'verificationUri',
            'qrcode',
            'qrCode',
            'code',
            'qr_payload',
            'qrPayload',
          ]) ??
          token;
      state = state.copyWith(
        qrPayload: payload,
        qrToken: token,
        qrStatus: '请使用光鸭APP扫描二维码',
      );
      _startQRPolling();
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  void _startQRPolling() {
    _qrPollingTimer?.cancel();
    _qrPollingTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (state.qrToken.isEmpty) {
        timer.cancel();
        return;
      }
      try {
        final result = await _api.loginQRPoll(state.qrToken);
        final accessToken = AuthState._findStringDeep(result, [
          'access_token',
          'accessToken',
        ]);
        if (accessToken != null) {
          timer.cancel();
          state = state.copyWith(isSignedIn: true);
          await _saveTokens();
          await loadAccount();
        } else {
          final error = AuthState._findStringDeep(result, ['error']);
          String? newStatus;
          if (error == 'slow_down') {
            newStatus = '轮询过快，请稍候';
          } else if (error == 'authorization_pending') {
            newStatus = '等待扫码确认…';
          }
          if (newStatus != null) {
            state = state.copyWith(qrStatus: newStatus);
          }
        }
      } catch (_) {
        // Continue polling on transient errors
      }
    });
  }

  // ── Sign out ──────────────────────────────────────────────────────

  Future<void> signOut() async {
    _api.clearTokens();
    await _clearTokens();
    _qrPollingTimer?.cancel();
    _countdownTimer?.cancel();
    state = const AuthState(isLoading: false);
  }

  // ── Token persistence ─────────────────────────────────────────────

  Future<void> _saveTokens() async {
    await StorageManager.set(StorageKeys.accessToken, _api.accessToken);
    if (_api.refreshTokenValue != null) {
      await StorageManager.set(
        StorageKeys.refreshToken,
        _api.refreshTokenValue!,
      );
    }
    if (_api.tokenExpiresAt != null) {
      await StorageManager.set(
        StorageKeys.tokenExpiresAt,
        _api.tokenExpiresAt!.millisecondsSinceEpoch,
      );
    }
    await StorageManager.set(StorageKeys.deviceID, _api.deviceID);
  }

  Future<void> _clearTokens() async {
    await StorageManager.delete(StorageKeys.accessToken);
    await StorageManager.delete(StorageKeys.refreshToken);
  }

  @override
  void dispose() {
    _qrPollingTimer?.cancel();
    _countdownTimer?.cancel();
    super.dispose();
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>(
  (ref) => AuthNotifier(),
);
