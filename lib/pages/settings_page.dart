import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide showShadDialog, showShadSheet;
import '../providers/theme_provider.dart';
import '../providers/media_library_provider.dart';
import '../widgets/app_log_dialog.dart';
import '../core/http/dio_client.dart';
import '../core/storage/storage_manager.dart';
import '../pages/app_upgrade_page.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_loading_indicator.dart';

class SettingsDialog extends ConsumerStatefulWidget {
  const SettingsDialog({super.key});

  @override
  ConsumerState<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends ConsumerState<SettingsDialog> {
  var _saving = false;
  final _tmdbApiKeyController = TextEditingController();
  final _tmdbImageProxyController = TextEditingController();
  final _httpProxyHostController = TextEditingController();
  final _httpProxyPortController = TextEditingController();
  final _scanConcurrencyController = TextEditingController();
  final _transferConcurrencyController = TextEditingController();
  final _cacheTTLController = TextEditingController();
  final _cloudIndexConcurrencyController = TextEditingController();
  final _cloudIndexRefreshController = TextEditingController();
  final _pageSizeController = TextEditingController();
  final _mediaLibraryPageSizeController = TextEditingController();
  final _mediaHomePreviewCountController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tmdbApiKeyController.text =
        StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    _tmdbImageProxyController.text =
        StorageManager.get<String>(StorageKeys.tmdbImageProxy) ??
        'https://wsrv.nl';
    _httpProxyHostController.text = StorageManager.networkProxyHost;
    _httpProxyPortController.text = StorageManager.networkProxyPort;
    _scanConcurrencyController.text =
        StorageManager.get<String>(StorageKeys.mediaScanConcurrency) ?? '3';
    _transferConcurrencyController.text =
        StorageManager.get<String>(StorageKeys.fastTransferConcurrency) ?? '3';
    _cacheTTLController.text =
        StorageManager.get<String>(StorageKeys.fileCacheTTLMinutes) ?? '3';
    _cloudIndexConcurrencyController.text =
        StorageManager.get<String>(StorageKeys.cloudIndexConcurrency) ?? '6';
    _cloudIndexRefreshController.text =
        StorageManager.get<String>(StorageKeys.cloudIndexRefreshMinutes) ??
        '30';
    _pageSizeController.text =
        StorageManager.get<String>(StorageKeys.defaultFilePageSize) ?? '50';
    _mediaLibraryPageSizeController.text =
        StorageManager.get<String>(StorageKeys.mediaLibraryPageSize) ?? '100';
    _mediaHomePreviewCountController.text =
        StorageManager.get<String>(StorageKeys.mediaHomePreviewCount) ?? '15';
  }

  @override
  void dispose() {
    _tmdbApiKeyController.dispose();
    _tmdbImageProxyController.dispose();
    _httpProxyHostController.dispose();
    _httpProxyPortController.dispose();
    _scanConcurrencyController.dispose();
    _transferConcurrencyController.dispose();
    _cacheTTLController.dispose();
    _cloudIndexConcurrencyController.dispose();
    _cloudIndexRefreshController.dispose();
    _pageSizeController.dispose();
    _mediaLibraryPageSizeController.dispose();
    _mediaHomePreviewCountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final themeState = ref.watch(themeProvider);
    final mediaState = ref.watch(mediaLibraryProvider);
    final compact = MediaQuery.sizeOf(context).width < 760;

    return ShadDialog(
      title: Row(
        children: [
          Icon(Icons.settings_outlined, size: 19, color: cs.primary),
          const SizedBox(width: 10),
          const Text('设置'),
        ],
      ),
      description: const Text('应用外观、网络任务与影视资料'),
      actions: [
        ShadButton.outline(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ShadButton(
          onPressed: _saving ? null : _saveAndClose,
          leading: _saving
              ? AppLoadingIndicator(
                  size: AppLoadingSize.inline,
                  color: cs.primaryForeground,
                  semanticsLabel: '正在保存设置',
                )
              : const Icon(Icons.check_rounded, size: 16),
          child: Text(_saving ? '正在保存' : '保存设置'),
        ),
      ],
      child: SizedBox(
        width: compact ? MediaQuery.sizeOf(context).width - 32 : 900,
        height: (MediaQuery.sizeOf(context).height - 180).clamp(360.0, 620.0),
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(top: 4, bottom: 12),
          child: Column(
            children: [
              _SettingsSection(
                icon: Icons.palette_outlined,
                title: '外观与浏览',
                child: Column(
                  children: [
                    _SettingsRow(
                      icon: Icons.light_mode_rounded,
                      label: '主题模式',
                      child: ShadSelect<String>(
                        initialValue: _themeModeToString(themeState.themeMode),
                        minWidth: 180,
                        placeholder: const Text('选择主题'),
                        selectedOptionBuilder: (context, value) =>
                            Text(_themeModeToString(_stringToThemeMode(value))),
                        options: const [
                          ShadOption(value: 'light', child: Text('浅色')),
                          ShadOption(value: 'dark', child: Text('深色')),
                          ShadOption(value: 'system', child: Text('跟随系统')),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            ref
                                .read(themeProvider.notifier)
                                .setThemeMode(_stringToThemeMode(value));
                          }
                        },
                      ),
                    ),
                    _SettingsRow(
                      icon: Icons.format_list_numbered_rounded,
                      label: '文件列表分页大小',
                      child: _numberInput(_pageSizeController),
                    ),
                    _SettingsRow(
                      icon: Icons.video_library_outlined,
                      label: '媒体库分页大小',
                      child: _numberInput(_mediaLibraryPageSizeController),
                    ),
                    _SettingsRow(
                      icon: Icons.home_outlined,
                      label: '首页每库预览数量',
                      child: _numberInput(_mediaHomePreviewCountController),
                    ),
                  ],
                ),
              ),
              _SettingsSection(
                icon: Icons.http_rounded,
                title: '网络代理',
                child: Column(
                  children: [
                    _SettingsRow(
                      icon: Icons.lan_outlined,
                      label: '代理地址',
                      child: _textInput(
                        _httpProxyHostController,
                        placeholder: '127.0.0.1',
                      ),
                    ),
                    _SettingsRow(
                      icon: Icons.tag_rounded,
                      label: '代理端口',
                      child: _numberInput(
                        _httpProxyPortController,
                        placeholder: '7890',
                      ),
                    ),
                  ],
                ),
              ),
              _SettingsSection(
                icon: Icons.bolt_outlined,
                title: '任务与缓存',
                child: Column(
                  children: [
                    _SettingsRow(
                      icon: Icons.memory_rounded,
                      label: '媒体扫描并发',
                      child: _numberInput(_scanConcurrencyController),
                    ),
                    _SettingsRow(
                      icon: Icons.bolt_rounded,
                      label: '秒传并发',
                      child: _numberInput(_transferConcurrencyController),
                    ),
                    _SettingsRow(
                      icon: Icons.cached_rounded,
                      label: '文件缓存分钟',
                      child: _numberInput(_cacheTTLController),
                    ),
                    _SettingsRow(
                      icon: Icons.cloud_sync_rounded,
                      label: '全盘索引并发',
                      child: _numberInput(_cloudIndexConcurrencyController),
                    ),
                    _SettingsRow(
                      icon: Icons.schedule_rounded,
                      label: '全盘索引间隔',
                      child: _numberInput(_cloudIndexRefreshController),
                    ),
                    _SettingsRow(
                      icon: Icons.refresh_rounded,
                      label: '全盘文件索引',
                      child: ShadButton.outline(
                        size: ShadButtonSize.sm,
                        onPressed: mediaState.isRefreshingCloudIndex
                            ? null
                            : () => unawaited(
                                ref
                                    .read(mediaLibraryProvider.notifier)
                                    .refreshGlobalCloudIndex(force: true),
                              ),
                        leading: mediaState.isRefreshingCloudIndex
                            ? AppLoadingIndicator(
                                size: AppLoadingSize.inline,
                                color: cs.primary,
                                semanticsLabel: '正在刷新全盘文件索引',
                              )
                            : const Icon(Icons.refresh_rounded, size: 15),
                        child: Text(
                          mediaState.isRefreshingCloudIndex ? '刷新中' : '立即刷新',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _SettingsSection(
                icon: Icons.movie_filter_outlined,
                title: 'TMDB',
                child: Column(
                  children: [
                    _SettingsRow(
                      icon: Icons.key_rounded,
                      label: 'API Key',
                      child: _textInput(
                        _tmdbApiKeyController,
                        placeholder: '输入 TMDB API Key',
                      ),
                    ),
                    _SettingsRow(
                      icon: Icons.image_outlined,
                      label: '图片加速地址',
                      child: _textInput(
                        _tmdbImageProxyController,
                        placeholder: 'https://wsrv.nl',
                      ),
                    ),
                  ],
                ),
              ),
              _SettingsSection(
                icon: Icons.sticky_note_2_outlined,
                title: '运行诊断',
                child: _SettingsRow(
                  icon: Icons.subject_rounded,
                  label: '运行日志',
                  child: ShadButton.outline(
                    size: ShadButtonSize.sm,
                    onPressed: () => showShadDialog(
                      context: context,
                      builder: (_) => const AppLogDialog(),
                    ),
                    leading: const Icon(Icons.open_in_new_rounded, size: 15),
                    child: const Text('查看日志'),
                  ),
                ),
              ),
              _SettingsSection(
                icon: Icons.info_outline_rounded,
                title: '应用信息',
                child: Column(
                  children: [
                    _SettingsRow(
                      icon: Icons.cloud_outlined,
                      label: '版本',
                      child: FutureBuilder<PackageInfo>(
                        future: PackageInfo.fromPlatform(),
                        builder: (ctx, snap) {
                          final v = snap.hasData
                              ? 'v${snap.data!.version}'
                              : 'v-';
                          return Text(
                            v,
                            style: TextStyle(
                              fontSize: 13,
                              color: cs.mutedForeground,
                            ),
                          );
                        },
                      ),
                    ),
                    _SettingsRow(
                      icon: Icons.system_update_rounded,
                      label: '应用更新',
                      child: ShadButton.outline(
                        size: ShadButtonSize.sm,
                        onPressed: () => showAppUpgradeDialog(context),
                        leading: const Icon(
                          Icons.system_update_rounded,
                          size: 15,
                        ),
                        child: const Text('检查更新'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _textInput(
    TextEditingController controller, {
    required String placeholder,
  }) => SizedBox(
    width: double.infinity,
    child: ShadInput(controller: controller, placeholder: Text(placeholder)),
  );

  Widget _numberInput(
    TextEditingController controller, {
    String? placeholder,
  }) => SizedBox(
    width: double.infinity,
    child: ShadInput(
      controller: controller,
      placeholder: placeholder == null ? null : Text(placeholder),
      keyboardType: TextInputType.number,
    ),
  );

  Future<void> _saveSettings() async {
    await Future.wait([
      StorageManager.set(
        StorageKeys.tmdbApiKey,
        _tmdbApiKeyController.text.trim(),
      ),
      StorageManager.set(
        StorageKeys.tmdbImageProxy,
        _tmdbImageProxyController.text.trim(),
      ),
      StorageManager.set(
        StorageKeys.httpProxyHost,
        _httpProxyHostController.text.trim(),
      ),
      StorageManager.set(
        StorageKeys.httpProxyPort,
        _httpProxyPortController.text.trim(),
      ),
      StorageManager.delete(StorageKeys.tmdbProxyHost),
      StorageManager.delete(StorageKeys.tmdbProxyPort),
      StorageManager.set(
        StorageKeys.mediaScanConcurrency,
        _scanConcurrencyController.text.trim(),
      ),
      StorageManager.set(
        StorageKeys.fastTransferConcurrency,
        _transferConcurrencyController.text.trim(),
      ),
      StorageManager.set(
        StorageKeys.fileCacheTTLMinutes,
        _cacheTTLController.text.trim(),
      ),
      StorageManager.set(
        StorageKeys.cloudIndexConcurrency,
        _cloudIndexConcurrencyController.text.trim(),
      ),
      StorageManager.set(
        StorageKeys.cloudIndexRefreshMinutes,
        _cloudIndexRefreshController.text.trim(),
      ),
      StorageManager.set(
        StorageKeys.defaultFilePageSize,
        _pageSizeController.text.trim(),
      ),
      StorageManager.set(
        StorageKeys.mediaLibraryPageSize,
        _mediaLibraryPageSizeController.text.trim(),
      ),
      StorageManager.set(
        StorageKeys.mediaHomePreviewCount,
        _mediaHomePreviewCountController.text.trim(),
      ),
    ]);
    DioClient.updateNetworkProxy();
    ref.read(mediaLibraryProvider.notifier).updateCloudIndexRefreshSchedule();
  }

  Future<void> _saveAndClose() async {
    setState(() => _saving = true);
    try {
      await _saveSettings();
      if (!mounted) return;
      ShadToaster.maybeOf(context)?.show(
        const ShadToast(
          title: Text('设置已保存'),
          description: Text('新的配置已应用到后续任务。'),
          showCloseIconOnlyWhenHovered: false,
        ),
      );
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      ShadToaster.maybeOf(context)?.show(
        ShadToast.destructive(
          title: const Text('保存设置失败'),
          description: Text(error.toString()),
          showCloseIconOnlyWhenHovered: false,
        ),
      );
      setState(() => _saving = false);
    }
  }

  String _themeModeToString(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }

  ThemeMode _stringToThemeMode(String value) {
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
}

class _SettingsSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;

  const _SettingsSection({
    required this.icon,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.muted.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.11),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(icon, size: 16, color: cs.primary),
              ),
              const SizedBox(width: 10),
              Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: cs.foreground,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const ShadSeparator.horizontal(),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget child;

  const _SettingsRow({
    required this.icon,
    required this.label,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final labelWidget = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: cs.mutedForeground),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(fontSize: 13, color: cs.foreground)),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          labelWidget,
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, child: child),
        ],
      ),
    );
  }
}
