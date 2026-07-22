import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:install_plugin_v3/install_plugin_v3.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide showShadDialog, showShadSheet;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/logging/app_logger.dart';
import '../core/storage/storage_manager.dart';
import '../core/utils/fetch_faster_github_proxy.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_loading_indicator.dart';

const _githubRepo = 'ngfchl/guangya_flutter';
const _githubApiLatest =
    'https://api.github.com/repos/$_githubRepo/releases/latest';
const _githubApiReleases = 'https://api.github.com/repos/$_githubRepo/releases';
const _githubReleasesPage = 'https://github.com/$_githubRepo/releases';
const _upgradeIgnoreVersionKey = 'app_upgrade_ignore_version';
const _upgradeUseGithubProxyKey = 'app_upgrade_use_github_proxy';
const _upgradeGithubProxyKey = 'app_upgrade_github_proxy';
const _upgradeGithubProxyResultsKey = 'app_upgrade_github_proxy_results';

Future<void> showAppUpgradeDialog(BuildContext context) => showShadDialog<void>(
  context: context,
  builder: (_) => const AppUpgradePage(),
);

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

class AppUpdateInfo {
  final String version;
  final String tagName;
  final String body;
  final DateTime? publishedAt;
  final List<AppUpdateAsset> assets;

  const AppUpdateInfo({
    required this.version,
    required this.tagName,
    required this.body,
    this.publishedAt,
    this.assets = const [],
  });

  factory AppUpdateInfo.fromGitHubJson(Map<String, dynamic> json) {
    final tagName = (json['tag_name'] ?? '').toString();
    final version = tagName.replaceFirst(RegExp(r'^v'), '');
    final publishedAt = json['published_at'] != null
        ? DateTime.tryParse(json['published_at'].toString())
        : null;
    final assets = <AppUpdateAsset>[];
    if (json['assets'] is List) {
      for (final item in json['assets']) {
        if (item is! Map) continue;
        final name = (item['name'] ?? '').toString();
        final url = (item['browser_download_url'] ?? '').toString();
        final size = item['size'] is int ? item['size'] as int : 0;
        if (name.isNotEmpty && url.isNotEmpty) {
          assets.add(AppUpdateAsset(name: name, url: url, size: size));
        }
      }
    }
    return AppUpdateInfo(
      version: version,
      tagName: tagName,
      body: (json['body'] ?? '').toString(),
      publishedAt: publishedAt,
      assets: assets,
    );
  }

  bool get isEmpty => version.isEmpty;
}

class AppUpdateAsset {
  final String name;
  final String url;
  final int size;

  const AppUpdateAsset({
    required this.name,
    required this.url,
    required this.size,
  });

  String get formattedSize {
    if (size <= 0) return '';
    if (size >= 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (size >= 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (size >= 1024) {
      return '${(size / 1024).toStringAsFixed(0)} KB';
    }
    return '$size B';
  }
}

class AppUpgradeStatus {
  final String currentVersion;
  final AppUpdateInfo latest;
  final bool hasNewVersion;
  final bool ignored;
  final String macosArch;

  const AppUpgradeStatus({
    required this.currentVersion,
    required this.latest,
    required this.hasNewVersion,
    required this.ignored,
    required this.macosArch,
  });

  bool get shouldPrompt => hasNewVersion && !ignored;
}

// ---------------------------------------------------------------------------
// Version comparison
// ---------------------------------------------------------------------------

int compareAppVersions(String a, String b) {
  List<int> parts(String value) => value
      .replaceFirst(RegExp(r'^[vV]'), '')
      .split('+')
      .first
      .split('.')
      .map((part) => int.tryParse(RegExp(r'^\d+').stringMatch(part) ?? '') ?? 0)
      .toList();
  final partsA = parts(a);
  final partsB = parts(b);
  final length = partsA.length > partsB.length ? partsA.length : partsB.length;
  for (var i = 0; i < length; i++) {
    final va = i < partsA.length ? partsA[i] : 0;
    final vb = i < partsB.length ? partsB[i] : 0;
    if (va != vb) return va.compareTo(vb);
  }
  return 0;
}

String _formatCurrentVersion(PackageInfo info) {
  final build = info.buildNumber.isNotEmpty ? '+${info.buildNumber}' : '';
  return '${info.version}$build';
}

Future<String> _detectCurrentMacosArch() async {
  if (kIsWeb || !Platform.isMacOS) return 'x86_64';
  try {
    final arch = (await DeviceInfoPlugin().macOsInfo).arch.toLowerCase();
    if (arch.contains('arm64') || arch.contains('aarch64')) return 'arm64';
  } catch (error) {
    AppLogger.warning('Upgrade', '识别 macOS 架构失败：$error');
  }
  return 'x86_64';
}

bool _matchesPlatformAsset(AppUpdateAsset asset, {required String macosArch}) {
  final text = '${asset.name} ${asset.url}'.toLowerCase();
  bool any(Iterable<String> values) => values.any(text.contains);
  final windows = any(['windows', '.exe', '.msi', 'setup']);
  final macos = any(['macos', 'mac-os', 'mac_os', '.pkg', '.dmg']);
  final linux = any(['linux', '.appimage', '.deb', '.rpm']);
  final android = any(['android', '.apk']);
  final ios = any(['ios', '.ipa']);
  if (Platform.isWindows) {
    return windows && !macos && !linux && !android && !ios;
  }
  if (Platform.isMacOS) {
    if (!macos || windows || linux || android || ios) return false;
    final arm64 = any(['arm64', 'aarch64']);
    final x64 = any(['x86_64', 'x64', 'amd64']);
    return macosArch == 'arm64'
        ? arm64 || (!arm64 && !x64)
        : x64 || (!arm64 && !x64);
  }
  if (Platform.isLinux) return linux && !windows && !macos && !android && !ios;
  if (Platform.isAndroid) {
    return android && !windows && !macos && !linux && !ios;
  }
  if (Platform.isIOS) return ios && !windows && !macos && !linux && !android;
  return false;
}

AppUpdateAsset? _preferredAssetForPlatform(
  AppUpdateInfo info, {
  required String macosArch,
}) {
  final current = info.assets
      .where((asset) => _matchesPlatformAsset(asset, macosArch: macosArch))
      .toList();
  if (current.isEmpty) return null;
  final priorities = Platform.isAndroid
      ? const ['.apk']
      : Platform.isWindows
      ? const ['setup.exe', '.exe', '.msi', '.zip']
      : Platform.isMacOS
      ? const ['.pkg', '.dmg', '.zip']
      : Platform.isIOS
      ? const ['.ipa']
      : const ['.appimage', '.deb', '.rpm', '.tar.gz', '.zip'];
  for (final pattern in priorities) {
    for (final asset in current) {
      if (asset.name.toLowerCase().contains(pattern)) return asset;
    }
  }
  return current.first;
}

final appUpgradeStatusProvider = FutureProvider<AppUpgradeStatus>((ref) async {
  final packageInfo = await PackageInfo.fromPlatform();
  final currentVersion = _formatCurrentVersion(packageInfo);
  final response = await _createDio().get<Map<String, dynamic>>(
    _githubApiLatest,
  );
  final latest = AppUpdateInfo.fromGitHubJson(response.data ?? {});
  final ignored =
      StorageManager.get<String>(_upgradeIgnoreVersionKey)?.trim() ==
      latest.version.trim();
  final arch = await _detectCurrentMacosArch();
  final hasAsset = _preferredAssetForPlatform(latest, macosArch: arch) != null;
  return AppUpgradeStatus(
    currentVersion: currentVersion,
    latest: latest,
    hasNewVersion:
        latest.version.isNotEmpty &&
        compareAppVersions(latest.version, currentVersion) > 0 &&
        hasAsset,
    ignored: ignored,
    macosArch: arch,
  );
});

// ---------------------------------------------------------------------------
// Proxy helpers
// ---------------------------------------------------------------------------

Dio _createDio() {
  final options = BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    headers: {
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'guangya-flutter-updater',
    },
  );
  final dio = Dio(options);
  final proxyHost = StorageManager.networkProxyHost;
  final proxyPort = StorageManager.networkProxyPort;
  if (proxyHost.isNotEmpty && proxyPort.isNotEmpty) {
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 15)
          ..badCertificateCallback = (certificate, host, port) => true;
        client.findProxy = (_) => 'PROXY $proxyHost:$proxyPort';
        return client;
      },
    );
  }
  return dio;
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

class AppUpgradePage extends ConsumerStatefulWidget {
  const AppUpgradePage({super.key});

  @override
  ConsumerState<AppUpgradePage> createState() => _AppUpgradePageState();
}

class _AppUpgradePageState extends ConsumerState<AppUpgradePage> {
  AppUpdateInfo? _latest;
  List<AppUpdateInfo> _versions = [];
  bool _loadingLatest = false;
  bool _loadingVersions = false;
  bool _downloading = false;
  double _progress = 0;
  String? _error;
  CancelToken? _cancelToken;
  String? _activeDownloadPath;
  String? _currentVersion;
  bool _ignoredLatest = false;
  String _macosArch = 'x86_64';
  int _dialogTab = 0;
  bool _useGithubProxy = true;
  bool _testingGithubProxy = false;

  GithubProxyResponse? _githubProxy;
  List<GithubProxyResponse> _githubProxyResults = const [];
  Future<GithubProxyResponse?>? _githubProxyRequest;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    _useGithubProxy =
        StorageManager.get<bool>(_upgradeUseGithubProxyKey) ?? true;
    final savedProxy = StorageManager.get<dynamic>(_upgradeGithubProxyKey);
    if (savedProxy is Map) {
      _githubProxy = GithubProxyResponse.fromJson(
        Map<String, dynamic>.from(savedProxy),
      );
    }
    final savedResults = StorageManager.get<dynamic>(
      _upgradeGithubProxyResultsKey,
    );
    if (savedResults is List) {
      _githubProxyResults =
          savedResults
              .whereType<Map>()
              .map(
                (item) => GithubProxyResponse.fromJson(
                  Map<String, dynamic>.from(item),
                ),
              )
              .where((item) => item.available && item.url.isNotEmpty)
              .toList()
            ..sort((a, b) => a.time.compareTo(b.time));
    }
    _loadingLatest = true;
    _refreshUi();
    try {
      final status = await ref.read(appUpgradeStatusProvider.future);
      _currentVersion = status.currentVersion;
      _latest = status.latest;
      _ignoredLatest = status.ignored;
      _macosArch = status.macosArch;
    } catch (error) {
      _error = '检查更新失败：${_friendlyError(error)}';
      AppLogger.error('检查更新失败', error.toString());
    } finally {
      _loadingLatest = false;
      _refreshUi();
    }
  }

  void _refreshUi() {
    if (mounted) setState(() {});
  }

  bool get _hasNewVersion {
    final latest = _latest?.version.trim();
    if (latest == null || latest.isEmpty || _currentVersion == null) {
      return false;
    }
    return compareAppVersions(latest, _currentVersion!) > 0 &&
        _latest != null &&
        _preferredAsset(_latest!) != null;
  }

  // ---- GitHub API ----

  Future<void> _checkLatest({bool silent = false}) async {
    _loadingLatest = true;
    _error = null;
    _refreshUi();
    try {
      final dio = _createDio();
      final response = await dio.get<Map<String, dynamic>>(_githubApiLatest);
      _latest = AppUpdateInfo.fromGitHubJson(response.data ?? {});
      final ignored =
          StorageManager.get<String>(_upgradeIgnoreVersionKey) ?? '';
      _ignoredLatest = ignored == _latest?.version;
      ref.invalidate(appUpgradeStatusProvider);
    } catch (e) {
      _error = '检查更新失败：${_friendlyError(e)}';
      AppLogger.error('检查更新失败', e.toString());
    } finally {
      _loadingLatest = false;
      _refreshUi();
      if (!silent && mounted) {
        if (_error != null) {
          _showUpgradeMessage(_error!, destructive: true);
        } else if (!_hasNewVersion) {
          _showUpgradeMessage('当前已是最新版本');
        }
      }
    }
  }

  Future<void> _loadVersions() async {
    _loadingVersions = true;
    _error = null;
    _refreshUi();
    try {
      final dio = _createDio();
      final response = await dio.get<List>(_githubApiReleases);
      _versions = (response.data ?? [])
          .whereType<Map<String, dynamic>>()
          .map(AppUpdateInfo.fromGitHubJson)
          .toList();
    } catch (e) {
      _error = '获取版本列表失败：${_friendlyError(e)}';
      AppLogger.error('获取版本列表失败', e.toString());
    } finally {
      _loadingVersions = false;
      _refreshUi();
    }
  }

  // ---- Download ----

  AppUpdateAsset? _preferredAsset(AppUpdateInfo info) {
    return _preferredAssetForPlatform(info, macosArch: _macosArch);
  }

  Future<void> _downloadAsset(
    AppUpdateInfo info, [
    AppUpdateAsset? asset,
  ]) async {
    asset ??= _preferredAsset(info);
    if (asset == null) {
      _showUpgradeMessage('没有找到适合当前平台的安装包', destructive: true);
      return;
    }
    if (_downloading) return;
    _cancelToken = CancelToken();
    _downloading = true;
    _progress = 0;
    _activeDownloadPath = null;
    _refreshUi();
    try {
      final savePath = await _prepareInstallerPath(asset.name);
      if (savePath == null) return;
      _activeDownloadPath = savePath;
      final dio = _createDio();
      final downloadUrl = await _acceleratedDownloadUrl(asset.url);
      await dio.download(
        downloadUrl,
        savePath,
        cancelToken: _cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            _progress = (received / total).clamp(0.0, 1.0);
            _refreshUi();
          }
        },
      );
      await _handleDownloadedInstaller(savePath, asset.name);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        await _deleteFile(_activeDownloadPath);
        _showUpgradeMessage('已取消下载');
      } else {
        AppLogger.error('下载失败', e.toString());
        _showUpgradeMessage('下载失败：${_friendlyError(e)}', destructive: true);
      }
    } catch (e) {
      AppLogger.error('下载失败', e.toString());
      _showUpgradeMessage('下载失败：${_friendlyError(e)}', destructive: true);
    } finally {
      _downloading = false;
      _progress = 0;
      _cancelToken = null;
      _activeDownloadPath = null;
      _refreshUi();
    }
  }

  void _cancelDownload() {
    _cancelToken?.cancel('user cancelled');
  }

  Future<String?> _prepareInstallerPath(String fileName) async {
    if (Platform.isLinux) {
      return FilePicker.saveFile(
        dialogTitle: '保存安装包',
        fileName: fileName,
        type: FileType.any,
        bytes: Uint8List(0),
      );
    }
    final temporaryDirectory = await getTemporaryDirectory();
    final packageDirectory = Directory(
      p.join(temporaryDirectory.path, 'guangya_app_upgrade'),
    );
    await packageDirectory.create(recursive: true);
    return p.join(packageDirectory.path, fileName);
  }

  Future<void> _handleDownloadedInstaller(String path, String fileName) async {
    if (Platform.isMacOS || Platform.isWindows) {
      _showUpgradeMessage('安装包已下载，正在启动安装器');
      await _openInstaller(path);
    } else if (Platform.isAndroid) {
      _showUpgradeMessage('安装包已下载，正在打开安装器');
      await _installAndroidApk(path);
    } else if (Platform.isIOS) {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)], text: 'APP 安装包：$fileName'),
      );
    } else {
      _showUpgradeMessage('安装包已保存到：$path');
    }
  }

  Future<void> _installAndroidApk(String path) async {
    final result = await InstallPlugin.installApk(path);
    if (result is Map && result['isSuccess'] == true) {
      _showUpgradeMessage('安装完成');
      return;
    }
    final message = result is Map ? result['errorMessage']?.toString() : null;
    _showUpgradeMessage(
      message?.trim().isNotEmpty == true ? message!.trim() : '安装失败',
      destructive: true,
    );
  }

  void _showUpgradeMessage(String message, {bool destructive = false}) {
    if (!mounted) return;
    final toast = destructive
        ? ShadToast.destructive(title: Text(message))
        : ShadToast(title: Text(message));
    ShadToaster.maybeOf(context)?.show(toast);
  }

  Future<String> _acceleratedDownloadUrl(String url) async {
    if (!_useGithubProxy || !isGithubDownloadUrl(url)) return url;
    final proxy = await (_githubProxyRequest ??= _findGithubProxy());
    if (proxy == null) return url;
    return buildGithubProxyUrl(proxy.url, url);
  }

  Future<GithubProxyResponse?> _findGithubProxy() async {
    if (_githubProxy != null) return _githubProxy;
    try {
      final result = await fetchFasterGithubProxy(dio: _createDio());
      _githubProxyResults =
          result.results
              .where((item) => item.available && item.url.isNotEmpty)
              .toList()
            ..sort((a, b) => a.time.compareTo(b.time));
      if (_githubProxyResults.length > 10) {
        _githubProxyResults = _githubProxyResults.take(10).toList();
      }
      await StorageManager.set(
        _upgradeGithubProxyResultsKey,
        _githubProxyResults.map((item) => item.toJson()).toList(),
      );
      if (result.success) {
        _githubProxy = result.data;
        if (_githubProxy != null) {
          await StorageManager.set(
            _upgradeGithubProxyKey,
            _githubProxy!.toJson(),
          );
        }
      }
      return _githubProxy;
    } catch (error, stackTrace) {
      AppLogger.warning('Upgrade', 'GitHub 加速测速失败，使用原始下载地址：$error');
      AppLogger.debug('Upgrade', '$stackTrace');
      return null;
    }
  }

  Future<void> _setUseGithubProxy(bool value) async {
    _useGithubProxy = value;
    await StorageManager.set(_upgradeUseGithubProxyKey, value);
    _refreshUi();
    if (value && _githubProxy == null) await _testGithubProxy();
  }

  Future<void> _testGithubProxy() async {
    if (_testingGithubProxy) return;
    _testingGithubProxy = true;
    _githubProxy = null;
    _githubProxyRequest = null;
    _refreshUi();
    await _findGithubProxy();
    _testingGithubProxy = false;
    _refreshUi();
  }

  Future<void> _selectGithubProxy(String url) async {
    GithubProxyResponse? selected;
    for (final item in _githubProxyResults) {
      if (item.url == url) {
        selected = item;
        break;
      }
    }
    if (selected == null) return;
    _githubProxy = selected;
    _githubProxyRequest = Future.value(selected);
    await StorageManager.set(_upgradeGithubProxyKey, selected.toJson());
    _refreshUi();
  }

  Future<void> _openInstaller(String path) async {
    try {
      if (Platform.isMacOS) {
        final opened = await launchUrl(
          Uri.file(path),
          mode: LaunchMode.externalApplication,
        );
        if (!opened) {
          final result = await Process.run('/usr/bin/open', [path]);
          if (result.exitCode != 0) {
            throw ProcessException(
              '/usr/bin/open',
              [path],
              result.stderr.toString().trim(),
              result.exitCode,
            );
          }
        }
      } else if (Platform.isWindows) {
        await Process.start(path, const []);
      } else {
        _showUpgradeMessage('安装包已保存到：$path');
      }
    } catch (e) {
      AppLogger.warning('打开安装包失败', '$e');
      _showUpgradeMessage('无法自动打开，安装包已保存到：$path', destructive: true);
    }
  }

  Future<void> _deleteFile(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  // ---- Ignore ----

  Future<void> _toggleIgnore() async {
    if (_latest == null) return;
    if (_ignoredLatest) {
      await StorageManager.delete(_upgradeIgnoreVersionKey);
      _ignoredLatest = false;
    } else {
      await StorageManager.set(_upgradeIgnoreVersionKey, _latest!.version);
      _ignoredLatest = true;
    }
    ref.invalidate(appUpgradeStatusProvider);
    _refreshUi();
  }

  // ---- Helpers ----

  String _friendlyError(Object error) {
    final text = error.toString();
    if (text.contains('SocketException')) return '网络连接失败，请检查网络或代理设置';
    if (text.contains('Connection timed out') || text.contains('timeout')) {
      return '连接超时，可能需要配置代理';
    }
    if (text.contains('HandshakeException')) return 'SSL 握手失败';
    if (text.contains('403')) return 'GitHub API 限流，请稍后再试或配置代理';
    // strip Dio prefix
    return text
        .replaceFirst(RegExp(r'^DioException \[[^\]]+\]:\s*'), '')
        .replaceFirst(RegExp(r'^Exception:\s*'), '');
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final compact = size.width < 600;
    final dialogWidth = compact ? size.width - 32 : 620.0;
    final dialogHeight = (size.height * (compact ? 0.68 : 0.72)).clamp(
      380.0,
      640.0,
    );
    return ShadDialog(
      title: Row(
        children: [
          Icon(
            _hasNewVersion
                ? Icons.system_update_alt_rounded
                : Icons.verified_rounded,
            size: 20,
            color: _hasNewVersion ? cs.primary : const Color(0xFF22A559),
          ),
          const SizedBox(width: 8),
          Text(_hasNewVersion ? '发现新版本' : '应用更新'),
        ],
      ),
      description: Text(
        _hasNewVersion
            ? '当前 v${_currentVersion ?? '-'}，可更新至 v${_latest?.version ?? '-'}'
            : '当前版本 v${_currentVersion ?? '-'}',
      ),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 0, label: Text('最新版本')),
                ButtonSegment(value: 1, label: Text('历史版本')),
              ],
              selected: {_dialogTab},
              onSelectionChanged: (value) {
                setState(() => _dialogTab = value.first);
                if (_dialogTab == 1 && _versions.isEmpty) {
                  unawaited(_loadVersions());
                }
              },
            ),
            const SizedBox(height: 10),
            Expanded(
              child: IndexedStack(
                index: _dialogTab,
                children: [
                  ListView(
                    padding: EdgeInsets.only(right: compact ? 0 : 4),
                    children: [
                      _buildVersionCard(cs),
                      const SizedBox(height: 10),
                      if (_loadingLatest && _latest == null)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(
                            child: AppLoadingIndicator(
                              size: AppLoadingSize.inline,
                            ),
                          ),
                        )
                      else if (_error != null && _latest == null)
                        _buildErrorCard(cs)
                      else if (_latest != null)
                        _buildLatestCard(cs),
                      const SizedBox(height: 10),
                      _buildProxyOptions(cs),
                      if (_downloading) ...[
                        const SizedBox(height: 10),
                        _buildProgressCard(cs),
                      ],
                    ],
                  ),
                  ListView(
                    padding: EdgeInsets.only(right: compact ? 0 : 4),
                    children: [_buildVersionsSection(cs)],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProxyOptions(ShadColorScheme cs) {
    final proxy = _githubProxy;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ShadCheckbox(
                  value: _useGithubProxy,
                  onChanged: _setUseGithubProxy,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'GitHub 下载加速',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: cs.foreground,
                        ),
                      ),
                      Text(
                        !_useGithubProxy
                            ? '使用 GitHub 原始下载地址'
                            : _testingGithubProxy
                            ? '正在测速可用节点'
                            : proxy == null
                            ? '下载时自动选择最快节点'
                            : '${Uri.tryParse(proxy.url)?.host ?? proxy.url} · ${proxy.time} ms',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_useGithubProxy)
                  ShadButton.outline(
                    size: ShadButtonSize.sm,
                    onPressed: _testingGithubProxy ? null : _testGithubProxy,
                    leading: _testingGithubProxy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded, size: 15),
                    child: Text(_testingGithubProxy ? '测速中' : '测速'),
                  ),
              ],
            ),
            if (_useGithubProxy && _githubProxyResults.isNotEmpty) ...[
              const SizedBox(height: 10),
              ShadSelect<String>(
                key: ValueKey(proxy?.url),
                initialValue: proxy?.url,
                minWidth: 240,
                maxHeight: 360,
                placeholder: const Text('选择 GitHub 加速节点'),
                selectedOptionBuilder: (context, value) {
                  final selected = _githubProxyResults.firstWhere(
                    (item) => item.url == value,
                    orElse: () => _githubProxyResults.first,
                  );
                  return Row(
                    children: [
                      const Icon(Icons.speed_rounded, size: 15),
                      const SizedBox(width: 8),
                      Text('${selected.time} ms'),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          selected.url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  );
                },
                options: [
                  for (
                    var index = 0;
                    index < _githubProxyResults.length;
                    index++
                  )
                    ShadOption(
                      value: _githubProxyResults[index].url,
                      child: Row(
                        children: [
                          Icon(
                            proxy?.url == _githubProxyResults[index].url
                                ? Icons.check_rounded
                                : index == 0
                                ? Icons.bolt_rounded
                                : Icons.public_rounded,
                            size: 16,
                            color: index == 0 ? cs.primary : cs.mutedForeground,
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 64,
                            child: Text(
                              '${_githubProxyResults[index].time} ms',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: index == 0 ? cs.primary : cs.foreground,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              _githubProxyResults[index].url,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (index == 0)
                            Text(
                              '最快',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: cs.primary,
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) unawaited(_selectGithubProxy(value));
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildVersionCard(ShadColorScheme cs) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              _hasNewVersion
                  ? Icons.system_update_rounded
                  : Icons.check_circle_rounded,
              color: _hasNewVersion ? cs.primary : cs.muted,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '当前版本',
                    style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                  ),
                  Text(
                    'v${_currentVersion ?? '-'}',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: cs.foreground,
                    ),
                  ),
                ],
              ),
            ),
            if (_hasNewVersion)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '有新版本',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cs.primary,
                  ),
                ),
              ),
            const SizedBox(width: 8),
            ShadButton.outline(
              size: ShadButtonSize.sm,
              onPressed: _loadingLatest ? null : () => _checkLatest(),
              child: _loadingLatest
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('检查更新'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorCard(ShadColorScheme cs) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: cs.destructive, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _error!,
                style: TextStyle(fontSize: 13, color: cs.destructive),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLatestCard(ShadColorScheme cs) {
    final latest = _latest!;
    final platformAssets = latest.assets
        .where((asset) => _matchesPlatformAsset(asset, macosArch: _macosArch))
        .toList();
    final published = latest.publishedAt != null
        ? '${latest.publishedAt!.year}-${latest.publishedAt!.month.toString().padLeft(2, '0')}-${latest.publishedAt!.day.toString().padLeft(2, '0')}'
        : '';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  latest.tagName.isNotEmpty ? latest.tagName : '最新版本',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: cs.foreground,
                  ),
                ),
                if (published.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    published,
                    style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                  ),
                ],
                const Spacer(),
                if (_hasNewVersion)
                  ShadButton(
                    size: ShadButtonSize.sm,
                    onPressed: () => _downloadAsset(latest),
                    child: const Text('下载更新'),
                  ),
                if (_ignoredLatest) ...[
                  const SizedBox(width: 8),
                  Text(
                    '已忽略',
                    style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            // Changelog
            if (latest.body.isNotEmpty) ...[
              Text(
                '更新日志',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.foreground,
                ),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: Markdown(
                  data: latest.body,
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  styleSheet: MarkdownStyleSheet(
                    p: TextStyle(fontSize: 13, color: cs.foreground),
                    h1: TextStyle(fontSize: 18, color: cs.foreground),
                    h2: TextStyle(fontSize: 16, color: cs.foreground),
                    h3: TextStyle(fontSize: 14, color: cs.foreground),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            // Assets
            if (platformAssets.isNotEmpty) ...[
              Text(
                '安装包',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.foreground,
                ),
              ),
              const SizedBox(height: 8),
              for (final asset in platformAssets)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Icon(
                        Icons.insert_drive_file_rounded,
                        size: 16,
                        color: cs.mutedForeground,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          asset.name,
                          style: TextStyle(fontSize: 13, color: cs.foreground),
                        ),
                      ),
                      if (asset.formattedSize.isNotEmpty)
                        Text(
                          asset.formattedSize,
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.mutedForeground,
                          ),
                        ),
                      const SizedBox(width: 8),
                      ShadButton.ghost(
                        size: ShadButtonSize.sm,
                        onPressed: () => _downloadAsset(latest, asset),
                        child: const Text('下载'),
                      ),
                    ],
                  ),
                ),
            ],
            // Ignore toggle
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  _ignoredLatest
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                  size: 16,
                  color: cs.mutedForeground,
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: _toggleIgnore,
                  child: Text(
                    _ignoredLatest ? '取消忽略此版本' : '忽略此版本',
                    style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressCard(ShadColorScheme cs) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    value: _progress > 0 ? _progress : null,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _progress > 0
                        ? '下载中 ${(_progress * 100).toStringAsFixed(0)}%'
                        : '正在下载…',
                    style: TextStyle(fontSize: 13, color: cs.foreground),
                  ),
                ),
                ShadButton.ghost(
                  size: ShadButtonSize.sm,
                  onPressed: _cancelDownload,
                  child: const Text('取消'),
                ),
              ],
            ),
            if (_progress > 0) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: _progress,
                borderRadius: BorderRadius.circular(4),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildVersionsSection(ShadColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '历史版本',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: cs.foreground,
              ),
            ),
            const Spacer(),
            ShadButton.outline(
              size: ShadButtonSize.sm,
              onPressed: _loadingVersions ? null : _loadVersions,
              child: _loadingVersions
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('加载'),
            ),
            const SizedBox(width: 8),
            ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: () => launchUrl(Uri.parse(_githubReleasesPage)),
              child: const Text('在浏览器中查看'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_loadingVersions && _versions.isEmpty)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: AppLoadingIndicator(size: AppLoadingSize.inline),
            ),
          )
        else if (_versions.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  '点击"加载"查看历史版本',
                  style: TextStyle(fontSize: 13, color: cs.mutedForeground),
                ),
              ),
            ),
          )
        else
          for (final version in versions) _buildVersionItem(version, cs),
      ],
    );
  }

  Widget _buildVersionItem(AppUpdateInfo version, ShadColorScheme cs) {
    final published = version.publishedAt != null
        ? '${version.publishedAt!.year}-${version.publishedAt!.month.toString().padLeft(2, '0')}-${version.publishedAt!.day.toString().padLeft(2, '0')}'
        : '';
    final isCurrent =
        _currentVersion != null &&
        compareAppVersions(version.version, _currentVersion!) == 0;
    final platformAssets = version.assets
        .where((asset) => _matchesPlatformAsset(asset, macosArch: _macosArch))
        .toList();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  version.tagName.isNotEmpty
                      ? version.tagName
                      : 'v${version.version}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.foreground,
                  ),
                ),
                if (isCurrent) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '当前',
                      style: TextStyle(fontSize: 10, color: cs.primary),
                    ),
                  ),
                ],
                if (published.isNotEmpty) ...[
                  const Spacer(),
                  Text(
                    published,
                    style: TextStyle(fontSize: 11, color: cs.mutedForeground),
                  ),
                ],
              ],
            ),
            if (version.body.isNotEmpty) ...[
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: Markdown(
                  data: version.body,
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  styleSheet: MarkdownStyleSheet(
                    p: TextStyle(fontSize: 12, color: cs.foreground),
                  ),
                ),
              ),
            ],
            if (platformAssets.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final asset in platformAssets.take(5))
                    ActionChip(
                      label: Text(
                        '${asset.name} (${asset.formattedSize})',
                        style: const TextStyle(fontSize: 11),
                      ),
                      onPressed: () => _downloadAsset(version, asset),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  // Expose sorted versions
  List<AppUpdateInfo> get versions => _versions;
}
