import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide showShadDialog, showShadSheet;
import '../providers/theme_provider.dart';
import '../providers/media_library_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/file_provider.dart';
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
