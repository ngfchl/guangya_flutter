import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:install_plugin_v3/install_plugin_v3.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide showShadDialog, showShadSheet;
import 'package:url_launcher/url_launcher.dart';

import '../core/logging/app_logger.dart';
import '../core/storage/storage_manager.dart';
import '../core/utils/fetch_faster_github_proxy.dart';
import '../widgets/app_loading_indicator.dart';

const _githubRepo = 'ngfchl/guangya_flutter';
const _githubApiLatest =
    'https://api.github.com/repos/$_githubRepo/releases/latest';
const _githubApiReleases = 'https://api.github.com/repos/$_githubRepo/releases';
const _githubReleasesPage = 'https://github.com/$_githubRepo/releases';
const _upgradeIgnoreVersionKey = 'app_upgrade_ignore_version';

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

// ---------------------------------------------------------------------------
// Version comparison
// ---------------------------------------------------------------------------

int _compareVersions(String a, String b) {
  final partsA = a.split('.').map(int.tryParse).whereType<int>().toList();
  final partsB = b.split('.').map(int.tryParse).whereType<int>().toList();
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
          ..badCertificateCallback = (_, __, ___) => true;
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

  GithubProxyResponse? _githubProxy;
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
    final info = await PackageInfo.fromPlatform();
    _currentVersion = _formatCurrentVersion(info);
    final ignored = StorageManager.get<String>(_upgradeIgnoreVersionKey) ?? '';
    _ignoredLatest = ignored == _latest?.version;
    _refreshUi();
    await _checkLatest(silent: true);
  }

  void _refreshUi() {
    if (mounted) setState(() {});
  }

  bool get _hasNewVersion {
    final latest = _latest?.version.trim();
    if (latest == null || latest.isEmpty || _currentVersion == null)
      return false;
    return _compareVersions(latest, _currentVersion!) > 0;
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
    } catch (e) {
      _error = '检查更新失败：${_friendlyError(e)}';
      AppLogger.error('检查更新失败', e.toString());
    } finally {
      _loadingLatest = false;
      _refreshUi();
      if (!silent && mounted) {
        if (_error != null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(_error!)));
        } else if (!_hasNewVersion) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('当前已是最新版本')));
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
    if (info.assets.isEmpty) return null;
    final candidates = <String>[];
    if (Platform.isMacOS) {
      candidates.addAll(['.dmg', '.tar.gz', '.zip']);
      // detect arch
      final arch = Platform.version.contains('arm64') ? 'arm64' : 'x64';
      candidates.insert(0, arch);
    } else if (Platform.isWindows) {
      candidates.addAll(['.exe', '.msi', '.zip']);
    } else if (Platform.isLinux) {
      candidates.addAll(['.AppImage', '.deb', '.tar.gz', '.zip']);
    } else if (Platform.isAndroid) {
      candidates.addAll(['.apk']);
    }
    // match by priority
    for (final pattern in candidates) {
      for (final asset in info.assets) {
        if (asset.name.toLowerCase().contains(pattern.toLowerCase())) {
          return asset;
        }
      }
    }
    return info.assets.first;
  }

  Future<void> _downloadAsset(
    AppUpdateInfo info, [
    AppUpdateAsset? asset,
  ]) async {
    asset ??= _preferredAsset(info);
    if (asset == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('没有找到适合当前平台的安装包')));
      }
      return;
    }
    if (_downloading) return;
    _cancelToken = CancelToken();
    _downloading = true;
    _progress = 0;
    _activeDownloadPath = null;
    _refreshUi();
    try {
      final dir = await getTemporaryDirectory();
      final savePath = p.join(dir.path, asset.name);
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
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('下载完成：${asset.name}')));
      }
      await _openInstaller(savePath);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        await _deleteFile(_activeDownloadPath);
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('已取消下载')));
        }
      } else {
        AppLogger.error('下载失败', e.toString());
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('下载失败：${_friendlyError(e)}')));
        }
      }
    } catch (e) {
      AppLogger.error('下载失败', e.toString());
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('下载失败：${_friendlyError(e)}')));
      }
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

  Future<String> _acceleratedDownloadUrl(String url) async {
    if (!isGithubDownloadUrl(url)) return url;
    final proxy = await (_githubProxyRequest ??= _findGithubProxy());
    if (proxy == null) return url;
    return buildGithubProxyUrl(proxy.url, url);
  }

  Future<GithubProxyResponse?> _findGithubProxy() async {
    if (_githubProxy != null) return _githubProxy;
    try {
      final result = await fetchFasterGithubProxy(dio: _createDio());
      if (result.success) _githubProxy = result.data;
      return _githubProxy;
    } catch (error, stackTrace) {
      AppLogger.warning('Upgrade', 'GitHub 加速测速失败，使用原始下载地址：$error');
      AppLogger.debug('Upgrade', '$stackTrace');
      return null;
    }
  }

  Future<void> _openInstaller(String path) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isWindows) {
        await Process.start(path, const []);
      } else if (Platform.isAndroid) {
        final result = await InstallPlugin.installApk(path);
        if (result is Map && result['isSuccess'] == true) return;
        throw Exception(
          result is Map
              ? (result['errorMessage']?.toString() ?? '安装失败')
              : '安装失败',
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('安装包已保存到：$path')));
        }
      }
    } catch (e) {
      AppLogger.warning('打开安装包失败', '$e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已保存到：$path')));
      }
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('应用更新'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Current version + check button
          _buildVersionCard(cs),
          const SizedBox(height: 16),
          // Latest version
          if (_loadingLatest && _latest == null)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: AppLoadingIndicator(size: AppLoadingSize.inline),
              ),
            )
          else if (_error != null && _latest == null)
            _buildErrorCard(cs)
          else if (_latest != null) ...[
            _buildLatestCard(cs),
            const SizedBox(height: 16),
          ],
          // Download progress
          if (_downloading) ...[
            _buildProgressCard(cs),
            const SizedBox(height: 16),
          ],
          // Versions list
          _buildVersionsSection(cs),
        ],
      ),
    );
  }

  Widget _buildVersionCard(cs) {
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

  Widget _buildErrorCard(cs) {
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

  Widget _buildLatestCard(cs) {
    final latest = _latest!;
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
            if (latest.assets.isNotEmpty) ...[
              Text(
                '安装包',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.foreground,
                ),
              ),
              const SizedBox(height: 8),
              for (final asset in latest.assets)
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

  Widget _buildProgressCard(cs) {
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

  Widget _buildVersionsSection(cs) {
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

  Widget _buildVersionItem(AppUpdateInfo version, cs) {
    final published = version.publishedAt != null
        ? '${version.publishedAt!.year}-${version.publishedAt!.month.toString().padLeft(2, '0')}-${version.publishedAt!.day.toString().padLeft(2, '0')}'
        : '';
    final isCurrent =
        _currentVersion != null &&
        _compareVersions(version.version, _currentVersion!) == 0;
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
            if (version.assets.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final asset in version.assets.take(5))
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
