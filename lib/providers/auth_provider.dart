import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/legacy.dart';
import '../core/logging/app_logger.dart';
import '../core/http/http_error.dart';
import '../core/storage/storage_manager.dart';
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
    return '${_formatBytes(usedCapacity ?? 0)} / ${_formatBytes(capacity!)}';
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

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes < 1024 * 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes < 1024 * 1024 * 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024 * 1024)).toStringAsFixed(1)} TB';
    }
    return '${(bytes / (1024 * 1024 * 1024 * 1024 * 1024)).toStringAsFixed(1)} PB';
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
    if (cleanPhone.length < 8) {
      state = state.copyWith(errorMessage: '请输入有效的手机号');
      return;
    }

    try {
      final initResult = await _api.loginSMSInit(cleanPhone);
      final captcha = AuthState._findStringDeep(initResult, [
        'captcha_token',
        'captchaToken',
      ]);
      if (captcha == null) {
        if (AuthState._findStringDeep(initResult, ['url', 'verify_url']) !=
            null) {
          throw Exception('需要完成验证码验证后再发送短信');
        }
        throw Exception('获取验证码令牌失败');
      }
      state = state.copyWith(captchaToken: captcha);
      await _api.loginSMSSend(cleanPhone, captchaToken: captcha);
      _startCountdown();
    } catch (e) {
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
    try {
      final verifyResult = await _api.loginSMSVerify(
        state.verificationID,
        state.verificationCode,
      );
      final vToken = AuthState._findStringDeep(verifyResult, [
        'verification_token',
        'verificationToken',
      ]);
      final code = AuthState._findStringDeep(verifyResult, ['code']);
      if (vToken == null || code == null) throw Exception('验证码验证失败');

      await _api.loginSMSSignIn(
        code: code,
        verificationToken: vToken,
        username: state.phoneNumber.replaceAll(RegExp(r'[^\d]'), ''),
        captchaToken: state.captchaToken,
      );
      state = state.copyWith(isSignedIn: true);
      await _saveTokens();
      await loadAccount();
    } catch (e) {
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
