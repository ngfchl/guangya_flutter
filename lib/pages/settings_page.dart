import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide showShadDialog, showShadSheet;
import '../providers/theme_provider.dart';
import '../providers/media_library_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/file_provider.dart';
import '../providers/scale_provider.dart';
import '../widgets/app_log_dialog.dart';
import '../core/http/dio_client.dart';
import '../core/storage/storage_manager.dart';
import '../models/cloud_file.dart';
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
  final _globalScanMinimumSizeController = TextEditingController();
  final _transferConcurrencyController = TextEditingController();
  final _cacheTTLController = TextEditingController();
  final _cloudIndexConcurrencyController = TextEditingController();
  final _cloudIndexRefreshController = TextEditingController();
  final _pageSizeController = TextEditingController();
  final _mediaLibraryPageSizeController = TextEditingController();
  final _mediaHomePreviewCountController = TextEditingController();
  var _doubanAutoRecognitionEnabled = false;
  List<String> _globalScanExcludedFolders = [];
  List<String> _globalScanExcludedKeywords = [];

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
    _globalScanMinimumSizeController.text =
        StorageManager.get<String>(StorageKeys.globalMediaScanMinimumSizeMB) ??
        '500';
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
    final doubanEnabled = StorageManager.get<dynamic>(
      StorageKeys.doubanAutoRecognitionEnabled,
    );
    _doubanAutoRecognitionEnabled =
        doubanEnabled == true || doubanEnabled?.toString() == 'true';
    _globalScanExcludedFolders =
        StorageManager.get<List>(StorageKeys.globalScanExcludedFolders)
                ?.cast<String>() ??
            [];
    _globalScanExcludedKeywords =
        StorageManager.get<List>(StorageKeys.globalScanExcludedKeywords)
                ?.cast<String>() ??
            [];
  }

  @override
  void dispose() {
    _tmdbApiKeyController.dispose();
    _tmdbImageProxyController.dispose();
    _httpProxyHostController.dispose();
    _httpProxyPortController.dispose();
    _scanConcurrencyController.dispose();
    _globalScanMinimumSizeController.dispose();
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
      closeIcon: const SizedBox.shrink(),
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
                    _SettingsRow(
                      icon: Icons.zoom_in_rounded,
                      label: '界面缩放',
                      child: _buildScaleSlider(ref),
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
                      icon: Icons.video_file_rounded,
                      label: '全局刮削阈值 MB',
                      child: _numberInput(
                        _globalScanMinimumSizeController,
                        placeholder: '500',
                      ),
                    ),
                    _SettingsRow(
                      icon: Icons.folder_off_rounded,
                      label: '刮削排除文件夹',
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ShadBadge.outline(
                            child: Text('${_globalScanExcludedFolders.length} 个'),
                          ),
                          const SizedBox(width: 6),
                          ShadButton.ghost(
                            size: ShadButtonSize.sm,
                            onPressed: _showExcludedFoldersEditor,
                            leading: const Icon(Icons.edit_outlined, size: 16),
                          ),
                        ],
                      ),
                    ),
                    _SettingsRow(
                      icon: Icons.filter_list_off_rounded,
                      label: '刮削排除关键词',
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ShadBadge.outline(
                            child: Text('${_globalScanExcludedKeywords.length} 个'),
                          ),
                          const SizedBox(width: 6),
                          ShadButton.ghost(
                            size: ShadButtonSize.sm,
                            onPressed: _showExcludedKeywordsEditor,
                            leading: const Icon(Icons.edit_outlined, size: 16),
                          ),
                        ],
                      ),
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
                      child: SizedBox(
                        width: 124,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ShadButton.outline(
                              size: ShadButtonSize.sm,
                              onPressed: mediaState.isRefreshingCloudIndex
                                  ? null
                                  : () => unawaited(
                                      ref
                                          .read(
                                            mediaLibraryProvider.notifier,
                                          )
                                          .refreshGlobalCloudIndex(force: true),
                                    ),
                              leading: mediaState.isRefreshingCloudIndex
                                  ? AppLoadingIndicator(
                                      size: AppLoadingSize.inline,
                                      color: cs.primary,
                                      semanticsLabel: '正在刷新全盘文件索引',
                                    )
                                  : const Icon(
                                      Icons.refresh_rounded,
                                      size: 15,
                                    ),
                              child: Text(
                                mediaState.isRefreshingCloudIndex
                                    ? '刷新中'
                                    : '立即刷新',
                              ),
                            ),
                            const SizedBox(height: 6),
                            ShadButton.outline(
                              size: ShadButtonSize.sm,
                              onPressed: mediaState.isRefreshingCloudIndex
                                  ? null
                                  : () => unawaited(
                                      ref
                                          .read(
                                            mediaLibraryProvider.notifier,
                                          )
                                          .refreshGlobalCloudIndex(
                                            forceIncrementalCheck: true,
                                          ),
                                    ),
                              leading: const Icon(
                                Icons.sync_rounded,
                                size: 15,
                              ),
                              child: const Text('增量刷新'),
                            ),
                          ],
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
                    _SettingsRow(
                      icon: Icons.manage_search_rounded,
                      label: '豆瓣自动识别',
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: ShadSwitch(
                          value: _doubanAutoRecognitionEnabled,
                          label: const Text('启用'),
                          sublabel: const Text('TMDB 未命中或多候选时使用豆瓣辅助匹配'),
                          onChanged: (value) => setState(
                            () => _doubanAutoRecognitionEnabled = value,
                          ),
                        ),
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
                      icon: Icons.system_update_alt_rounded,
                      label: '应用更新',
                      child: ShadButton.outline(
                        size: ShadButtonSize.sm,
                        onPressed: () => showAppUpgradeDialog(context),
                        leading: const Icon(
                          Icons.system_update_alt_rounded,
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
  }) => _remoteInput(
    controller: controller,
    placeholder: Text(placeholder),
    keyboardType: TextInputType.text,
  );

  Widget _numberInput(
    TextEditingController controller, {
    String? placeholder,
  }) => _remoteInput(
    controller: controller,
    placeholder: placeholder == null ? null : Text(placeholder),
    keyboardType: TextInputType.number,
  );

  Widget _buildScaleSlider(WidgetRef ref) {
    final manualScale = ref.watch(scaleProvider);
    return Material(
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Slider(
                  min: 0.5,
                  max: 1.5,
                  value: manualScale,
                  label: '${(manualScale * 100).round()}%',
                  onChanged: (v) =>
                      ref.read(scaleProvider.notifier).setScale(v),
                ),
              ),
              SizedBox(
                width: 56,
                child: Text(
                  '${(manualScale * 100).round()}%',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 13,
                    color: ShadTheme.of(context).colorScheme.foreground,
                  ),
                ),
              ),
            ],
          ),
          Text(
            '调整整体界面缩放（50%–150%），拖动滑块实时调整。',
            style: TextStyle(
              fontSize: 11,
              color: ShadTheme.of(context).colorScheme.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }

  /// 媒体库首页预览数量这类数字输入框需要实时保存，走 [_remoteInput] 但
  /// 在 onChanged 里同步存储。
  Widget _remoteNumberInputWithSave(
    TextEditingController controller, {
    required String placeholder,
    required ValueChanged<String> onChanged,
  }) => _remoteInput(
    controller: controller,
    placeholder: Text(placeholder),
    keyboardType: TextInputType.number,
    onChanged: onChanged,
  );

  /// 遥控器适配的文本输入框。外层 [Focus] 提供选中态（聚焦时高亮），
  /// OK/Enter 切换编辑态：进入编辑时把焦点转给内部 EditableText 让光标
  /// 进入可输入，再按 Enter/返回退出编辑回到选中态。这避免了遥控器方向键
  /// 直接跳过输入框——外层 Focus 能被 _collectFocusableNodes 可靠收集。
  Widget _remoteInput({
    required TextEditingController controller,
    required Widget? placeholder,
    required TextInputType keyboardType,
    ValueChanged<String>? onChanged,
  }) {
    return _RemoteInput(
      controller: controller,
      placeholder: placeholder,
      keyboardType: keyboardType,
      onChanged: onChanged,
    );
  }

  Future<void> _saveSettings() async {
    final defaultFilePageSize = normalizeFilePageSize(
      _pageSizeController.text,
    );
    _pageSizeController.text = '$defaultFilePageSize';
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
        StorageKeys.doubanAutoRecognitionEnabled,
        _doubanAutoRecognitionEnabled,
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
        StorageKeys.globalMediaScanMinimumSizeMB,
        _globalScanMinimumSizeController.text.trim(),
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
        '$defaultFilePageSize',
      ),
      StorageManager.set(
        StorageKeys.mediaLibraryPageSize,
        _mediaLibraryPageSizeController.text.trim(),
      ),
      StorageManager.set(
        StorageKeys.mediaHomePreviewCount,
        _mediaHomePreviewCountController.text.trim(),
      ),
      StorageManager.set(
        StorageKeys.globalScanExcludedFolders,
        _globalScanExcludedFolders,
      ),
      StorageManager.set(
        StorageKeys.globalScanExcludedKeywords,
        _globalScanExcludedKeywords,
      ),
    ]);
    DioClient.updateNetworkProxy();
    ref.read(fileProvider.notifier).setPageSize(defaultFilePageSize);
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

  Future<void> _showExcludedFoldersEditor() async {
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => Consumer(
        builder: (ctx, ref, _) => _ExcludedFoldersTreeDialog(
          initiallySelected: _globalScanExcludedFolders.toSet(),
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() => _globalScanExcludedFolders = result.toList());
    }
  }

  Future<void> _showExcludedKeywordsEditor() async {
    final controller = TextEditingController();
    final result = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return ShadDialog(
            closeIcon: const SizedBox.shrink(),
            title: const Text('刮削排除关键词'),
            description: const Text('文件名或路径包含这些关键词的文件将被跳过，每行一个'),
            actions: [
              ShadButton.outline(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              ShadButton(
                onPressed: () => Navigator.of(ctx).pop(
                  controller.text
                      .split('\n')
                      .map((e) => e.trim())
                      .where((e) => e.isNotEmpty)
                      .toList(),
                ),
                child: const Text('确定'),
              ),
            ],
            child: Material(
              type: MaterialType.transparency,
              child: TextField(
                controller: controller
                  ..text = _globalScanExcludedKeywords.join('\n'),
                maxLines: 8,
                decoration: const InputDecoration(
                  hintText: 'BDMV\nVIDEO_TS\nexample_keyword',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          );
        },
      ),
    );
    if (result != null && mounted) {
      setState(() => _globalScanExcludedKeywords = result);
    }
  }

  String _themeModeToString(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return '浅色';
      case ThemeMode.dark:
        return '深色';
      case ThemeMode.system:
        return '跟随系统';
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

class _ExcludedFoldersTreeDialog extends ConsumerStatefulWidget {
  final Set<String> initiallySelected;

  const _ExcludedFoldersTreeDialog({required this.initiallySelected});

  @override
  ConsumerState<_ExcludedFoldersTreeDialog> createState() =>
      _ExcludedFoldersTreeDialogState();
}

class _ExcludedFoldersTreeDialogState
    extends ConsumerState<_ExcludedFoldersTreeDialog> {
  late final Set<String> _selected;
  bool _loading = true;
  String? _error;
  List<_FolderNode> _roots = [];

  @override
  void initState() {
    super.initState();
    _selected = Set<String>.from(widget.initiallySelected);
    _loadRootFolders();
  }

  Future<void> _loadRootFolders() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(authProvider.notifier).api;
      final response = await api.fsFiles(parentID: null, pageSize: 200);
      if (!mounted) return;
      final folders = _parseFolders(response);
      setState(() {
        _roots = folders.map((f) => _FolderNode(folder: f)).toList();
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<List<CloudFile>> _loadChildFolders(String parentID) async {
    final api = ref.read(authProvider.notifier).api;
    final response = await api.fsFiles(parentID: parentID, pageSize: 200);
    return _parseFolders(response);
  }

  List<CloudFile> _parseFolders(Map<String, dynamic> response) {
    final files = <CloudFile>{};
    void visit(dynamic value) {
      if (value is Map) {
        try {
          final file = CloudFile.fromJson(Map<String, dynamic>.from(value));
          if (file.isDirectory) files.add(file);
        } catch (_) {}
        for (final child in value.values) {
          visit(child);
        }
      } else if (value is Iterable && value is! String) {
        for (final child in value) {
          visit(child);
        }
      }
    }
    visit(response);
    return files.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  bool _allDescendantsSelected(_FolderNode node) {
    if (node.children.isEmpty) return _selected.contains(node.folder.id);
    return node.children.every(_allDescendantsSelected);
  }

  void _toggleNode(_FolderNode node) {
    final id = node.folder.id;
    if (_selected.contains(id)) {
      _selected.remove(id);
      for (final child in node.children) {
        _removeRecursive(child);
      }
    } else {
      _selected.add(id);
      for (final child in node.children) {
        _addRecursive(child);
      }
    }
    setState(() {});
  }

  void _removeRecursive(_FolderNode node) {
    _selected.remove(node.folder.id);
    for (final child in node.children) {
      _removeRecursive(child);
    }
  }

  void _addRecursive(_FolderNode node) {
    _selected.add(node.folder.id);
    for (final child in node.children) {
      _addRecursive(child);
    }
  }

  Future<void> _expandNode(_FolderNode node) async {
    if (node.children.isNotEmpty || node.loading) return;
    setState(() => node.loading = true);
    try {
      final children = await _loadChildFolders(node.folder.id);
      setState(() {
        node.children = children.map((f) => _FolderNode(folder: f)).toList();
        node.loading = false;
        node.expanded = true;
      });
    } catch (e) {
      setState(() => node.loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ShadDialog(
      closeIcon: const SizedBox.shrink(),
      title: const Text('刮削排除文件夹'),
      description: const Text('勾选需要在全局刮削时跳过的文件夹'),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ShadButton(
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('确定'),
        ),
      ],
      child: SizedBox(
        height: 400,
        width: 350,
        child: Material(
          type: MaterialType.transparency,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('加载失败：$_error',
                              style: TextStyle(color: cs.destructive)),
                          const SizedBox(height: 8),
                          ShadButton.outline(
                            onPressed: _loadRootFolders,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    )
                  : _roots.isEmpty
                      ? const Center(child: Text('没有可用的文件夹'))
                      : ListView.builder(
                          itemCount: _roots.length,
                          itemBuilder: (context, index) =>
                              _buildTreeTile(_roots[index], 0),
                        ),
        ),
      ),
    );
  }

  Widget _buildTreeTile(_FolderNode node, int depth) {
    final cs = ShadTheme.of(context).colorScheme;
    final checked = _allDescendantsSelected(node);
    // 始终允许展开文件夹（子文件夹可能尚未加载）
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.only(
              left: depth * 20.0, right: 8, top: 4, bottom: 4),
          child: Row(
            children: [
              // 展开/收起箭头（文件夹始终可展开）
              InkWell(
                onTap: () {
                  if (!node.expanded && node.children.isEmpty) {
                    _expandNode(node);
                  } else {
                    setState(() => node.expanded = !node.expanded);
                  }
                },
                child: node.loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(
                        node.expanded
                            ? Icons.keyboard_arrow_down_rounded
                            : Icons.keyboard_arrow_right_rounded,
                        size: 18,
                        color: cs.mutedForeground,
                      ),
              ),
              const SizedBox(width: 4),
              // 文件夹图标 + 名称（点击勾选/取消）
              Expanded(
                child: InkWell(
                  onTap: () => _toggleNode(node),
                  child: Row(
                    children: [
                      Icon(
                        checked ? Icons.folder_open : Icons.folder_outlined,
                        size: 18,
                        color: checked ? cs.primary : cs.mutedForeground,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          node.folder.name,
                          style: TextStyle(
                            fontSize: 13,
                            color: checked ? cs.primary : cs.foreground,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 勾选框（点击勾选/取消）
              InkWell(
                onTap: () => _toggleNode(node),
                child: Icon(
                  checked
                      ? Icons.check_box
                      : Icons.check_box_outline_blank,
                  size: 18,
                  color: checked ? cs.primary : cs.mutedForeground,
                ),
              ),
            ],
          ),
        ),
        if (node.expanded)
          for (final child in node.children)
            _buildTreeTile(child, depth + 1),
      ],
    );
  }
}

class _FolderNode {
  final CloudFile folder;
  List<_FolderNode> children;
  bool expanded;
  bool loading;

  _FolderNode({
    required this.folder,
    List<_FolderNode>? children,
    bool? expanded,
    bool? loading,
  })  : children = children ?? [],
        expanded = expanded ?? false,
        loading = loading ?? false;
}

/// 遥控器适配的文本输入框。
///
/// 交互模型（用 Stack 透明覆盖层隔离焦点）：
/// - 选中态：透明 [Focus] 层覆盖在 [TextField] 上拦截焦点，显示主题色高亮。
///   方向键跳进来、上下键切换到其他组件，不进入编辑态。
/// - OK/Enter：移除透明层，焦点转给 [TextField] 进入编辑态，光标进入可输入。
/// - 编辑态：再按 OK/Enter/返回键 → 退出编辑，透明层重新覆盖，回到选中态。
class _RemoteInput extends StatefulWidget {
  final TextEditingController controller;
  final Widget? placeholder;
  final TextInputType keyboardType;
  final ValueChanged<String>? onChanged;

  const _RemoteInput({
    required this.controller,
    required this.placeholder,
    required this.keyboardType,
    this.onChanged,
  });

  @override
  State<_RemoteInput> createState() => _RemoteInputState();
}

class _RemoteInputState extends State<_RemoteInput> {
  final _coverNode = FocusNode(debugLabel: 'RemoteInputCover');
  final _editingNode = FocusNode(debugLabel: 'RemoteInputEditing');
  bool _editing = false;

  @override
  void dispose() {
    _coverNode.dispose();
    _editingNode.dispose();
    super.dispose();
  }

  void _enterEditing() {
    setState(() => _editing = true);
    _editingNode.requestFocus();
  }

  void _exitEditing() {
    _editingNode.unfocus();
    setState(() => _editing = false);
    // 覆盖层 if(!_editing) 刚重建还没挂载时 _coverNode 没附载，
    // requestFocus 无效——延到下一帧覆盖层挂载后再聚，上键才能可靠跳走。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _coverNode.requestFocus();
    });
  }

  /// 选中态上下方向键自己处理跳到同 scope 前后可聚焦节点。
  void _moveToSibling({required TraversalDirection direction}) {
    final scope = _coverNode.nearestScope;
    final scopeCtx = scope?.context;
    if (scopeCtx == null) return;
    final nodes = <FocusNode>[];
    _collectFocusableNodes(scopeCtx, nodes);
    if (nodes.length < 2) return;
    final currentIndex = nodes.indexOf(_coverNode);
    if (currentIndex < 0) return;
    final targetIndex = direction == TraversalDirection.down
        ? currentIndex + 1
        : currentIndex - 1;
    if (targetIndex < 0 || targetIndex >= nodes.length) return;
    nodes[targetIndex].requestFocus();
  }

  void _collectFocusableNodes(BuildContext ctx, List<FocusNode> out) {
    final widget = ctx.widget;
    if (widget is FocusScope || widget is FocusTraversalGroup) {
      ctx.visitChildElements((child) {
        _collectFocusableNodes(child, out);
      });
      return;
    }
    if (widget is Focus && widget.focusNode != null) {
      out.add(widget.focusNode!);
      return;
    }
    ctx.visitChildElements((child) {
      _collectFocusableNodes(child, out);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return SizedBox(
      width: double.infinity,
      height: 36,
      child: Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            // 底层：TextField，编辑态时聚焦接收输入；选中态时不可聚焦。
            // 用 ListenableBuilder 监听 _coverNode 和 _editingNode 的焦点变化，
            // 确保只有当前聚焦的框才显示选中态高亮，不会所有框都高亮。
            ListenableBuilder(
              listenable: Listenable.merge([_coverNode, _editingNode]),
              builder: (context, _) {
                // 只要焦点还在本框（选中态聚在 _coverNode，编辑态聚在 _editingNode），
                // 选中态边框就一直保持主题色高亮，不依赖 _editing 标志。
                final active = _coverNode.hasFocus || _editingNode.hasFocus;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: active
                        ? Border.all(color: cs.primary, width: 2)
                        : Border.all(color: cs.input, width: 1),
                    color: active ? cs.primary.withValues(alpha: 0.12) : null,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                  alignment: Alignment.centerLeft,
                  child: TextField(
                    controller: widget.controller,
                    focusNode: _editingNode,
                    keyboardType: widget.keyboardType,
                    style: TextStyle(fontSize: 13, color: cs.foreground),
                    textAlignVertical: TextAlignVertical.center,
                    decoration: InputDecoration(
                      isCollapsed: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: widget.placeholder is Text
                          ? (widget.placeholder as Text).data
                          : null,
                      hintStyle:
                          TextStyle(color: cs.mutedForeground, fontSize: 13),
                    ),
                    onChanged: widget.onChanged,
                    onSubmitted: (_) => _exitEditing(),
                  ),
                );
              },
            ),
            // 顶层透明覆盖层：选中态时拦截焦点，编辑态时移除（ Positioned.fill 消失）
            if (!_editing)
              Positioned.fill(
                child: _RemoteInputCover(
                  child: Focus(
                    focusNode: _coverNode,
                    canRequestFocus: true,
                    descendantsAreFocusable: false,
                    descendantsAreTraversable: true,
                    onKeyEvent: (node, event) {
                      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                        return KeyEventResult.ignored;
                      }
                      final key = event.logicalKey;
                      // OK/Enter 进入编辑
                      if (key == LogicalKeyboardKey.enter ||
                          key == LogicalKeyboardKey.select ||
                          key == LogicalKeyboardKey.gameButtonA) {
                        _enterEditing();
                        return KeyEventResult.handled;
                      }
                      // 上下方向键切换到其他组件
                      if (key == LogicalKeyboardKey.arrowUp ||
                          key == LogicalKeyboardKey.arrowDown) {
                        _moveToSibling(
                          direction: key == LogicalKeyboardKey.arrowUp
                              ? TraversalDirection.up
                              : TraversalDirection.down,
                        );
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        // 鼠标/触摸点击只聚焦显示选中态，不自动进入编辑态。
                        // 编辑态仅由 Enter 键触发（见上 onKeyEvent）。
                        if (!_coverNode.hasFocus) _coverNode.requestFocus();
                      },
                      child: const SizedBox(width: double.infinity, height: 36),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 选中态覆盖层的标识 widget。`RemoteControlHandler` 检测到当前焦点在它
/// 范围内时放行方向键，让覆盖层自己的 `onKeyEvent` 处理上下键切换——
/// 否则外层 `RemoteControlHandler` 先拦方向键走 `_moveDirection`，覆盖层
/// 收不到事件，上键跳不走且可能误触发编辑态。
class _RemoteInputCover extends StatelessWidget {
  final Widget child;

  const _RemoteInputCover({required this.child});

  @override
  Widget build(BuildContext context) => child;
}
