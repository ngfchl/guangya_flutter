import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import '../providers/theme_provider.dart';
import '../providers/media_library_provider.dart';
import '../core/storage/storage_manager.dart';

class SettingsDialog extends ConsumerStatefulWidget {
  const SettingsDialog({super.key});

  @override
  ConsumerState<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends ConsumerState<SettingsDialog> {
  final _tmdbApiKeyController = TextEditingController();
  final _tmdbProxyHostController = TextEditingController();
  final _tmdbProxyPortController = TextEditingController();
  final _tmdbImageProxyController = TextEditingController();
  final _httpProxyHostController = TextEditingController();
  final _httpProxyPortController = TextEditingController();
  final _scanConcurrencyController = TextEditingController();
  final _transferConcurrencyController = TextEditingController();
  final _cacheTTLController = TextEditingController();
  final _cloudIndexRefreshController = TextEditingController();
  final _pageSizeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tmdbApiKeyController.text =
        StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    _tmdbProxyHostController.text =
        StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '';
    _tmdbProxyPortController.text =
        StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '';
    _tmdbImageProxyController.text =
        StorageManager.get<String>(StorageKeys.tmdbImageProxy) ??
        'https://wsrv.nl';
    _httpProxyHostController.text =
        StorageManager.get<String>(StorageKeys.httpProxyHost) ?? '';
    _httpProxyPortController.text =
        StorageManager.get<String>(StorageKeys.httpProxyPort) ?? '';
    _scanConcurrencyController.text =
        StorageManager.get<String>(StorageKeys.mediaScanConcurrency) ?? '3';
    _transferConcurrencyController.text =
        StorageManager.get<String>(StorageKeys.fastTransferConcurrency) ?? '3';
    _cacheTTLController.text =
        StorageManager.get<String>(StorageKeys.fileCacheTTLMinutes) ?? '3';
    _cloudIndexRefreshController.text =
        StorageManager.get<String>(StorageKeys.cloudIndexRefreshMinutes) ??
        '30';
    _pageSizeController.text =
        StorageManager.get<String>(StorageKeys.defaultFilePageSize) ?? '50';
  }

  @override
  void dispose() {
    _tmdbApiKeyController.dispose();
    _tmdbProxyHostController.dispose();
    _tmdbProxyPortController.dispose();
    _tmdbImageProxyController.dispose();
    _httpProxyHostController.dispose();
    _httpProxyPortController.dispose();
    _scanConcurrencyController.dispose();
    _transferConcurrencyController.dispose();
    _cacheTTLController.dispose();
    _cloudIndexRefreshController.dispose();
    _pageSizeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final themeState = ref.watch(themeProvider);

    return ShadDialog(
      title: const Text('设置'),
      description: const Padding(
        padding: EdgeInsets.only(bottom: 8),
        child: Text('自定义应用外观和行为'),
      ),
      actions: [
        ShadButton(
          child: const Text('完成'),
          onPressed: () async {
            await _saveSettings();
            if (context.mounted) Navigator.of(context).pop();
          },
        ),
      ],
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '外观',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: cs.foreground,
                ),
              ),
              const SizedBox(height: 12),
              _SettingsRow(
                icon: Icons.light_mode_rounded,
                label: '主题模式',
                child: ShadSelect<String>(
                  initialValue: _themeModeToString(themeState.themeMode),
                  minWidth: 160,
                  placeholder: const Text('选择主题'),
                  options: [
                    ShadOption(
                      value: 'light',
                      child: const Row(
                        children: [
                          Icon(Icons.light_mode_rounded, size: 14),
                          SizedBox(width: 8),
                          Text('浅色'),
                        ],
                      ),
                    ),
                    ShadOption(
                      value: 'dark',
                      child: const Row(
                        children: [
                          Icon(Icons.dark_mode_rounded, size: 14),
                          SizedBox(width: 8),
                          Text('深色'),
                        ],
                      ),
                    ),
                    ShadOption(
                      value: 'system',
                      child: const Row(
                        children: [
                          Icon(Icons.brightness_auto_rounded, size: 14),
                          SizedBox(width: 8),
                          Text('跟随系统'),
                        ],
                      ),
                    ),
                  ],
                  selectedOptionBuilder: (ctx, value) =>
                      Text(_themeModeToString(_stringToThemeMode(value))),
                  onChanged: (value) {
                    if (value != null) {
                      ref
                          .read(themeProvider.notifier)
                          .setThemeMode(_stringToThemeMode(value));
                    }
                  },
                ),
              ),
              const SizedBox(height: 16),
              const ShadSeparator.horizontal(),
              const SizedBox(height: 16),
              Text(
                '网络与任务',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: cs.foreground,
                ),
              ),
              const SizedBox(height: 12),
              _SettingsRow(
                icon: Icons.http_rounded,
                label: 'HTTP 代理地址',
                child: SizedBox(
                  width: 200,
                  child: ShadInput(
                    controller: _httpProxyHostController,
                    placeholder: const Text('例: 127.0.0.1'),
                  ),
                ),
              ),
              _SettingsRow(
                icon: Icons.numbers_rounded,
                label: 'HTTP 代理端口',
                child: SizedBox(
                  width: 200,
                  child: ShadInput(
                    controller: _httpProxyPortController,
                    placeholder: const Text('例: 7890'),
                  ),
                ),
              ),
              _SettingsRow(
                icon: Icons.memory_rounded,
                label: '媒体扫描并发',
                child: SizedBox(
                  width: 100,
                  child: ShadInput(
                    controller: _scanConcurrencyController,
                    keyboardType: TextInputType.number,
                  ),
                ),
              ),
              _SettingsRow(
                icon: Icons.bolt_rounded,
                label: '秒传并发',
                child: SizedBox(
                  width: 100,
                  child: ShadInput(
                    controller: _transferConcurrencyController,
                    keyboardType: TextInputType.number,
                  ),
                ),
              ),
              _SettingsRow(
                icon: Icons.cached_rounded,
                label: '文件缓存分钟',
                child: SizedBox(
                  width: 100,
                  child: ShadInput(
                    controller: _cacheTTLController,
                    keyboardType: TextInputType.number,
                  ),
                ),
              ),
              _SettingsRow(
                icon: Icons.cloud_sync_rounded,
                label: '全盘索引刷新分钟',
                child: SizedBox(
                  width: 100,
                  child: ShadInput(
                    controller: _cloudIndexRefreshController,
                    keyboardType: TextInputType.number,
                  ),
                ),
              ),
              _SettingsRow(
                icon: Icons.format_list_numbered_rounded,
                label: '默认分页大小',
                child: SizedBox(
                  width: 100,
                  child: ShadInput(
                    controller: _pageSizeController,
                    keyboardType: TextInputType.number,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const ShadSeparator.horizontal(),
              const SizedBox(height: 16),
              Text(
                'TMDB 配置',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: cs.foreground,
                ),
              ),
              const SizedBox(height: 12),
              _SettingsRow(
                icon: Icons.key_rounded,
                label: 'API Key',
                child: SizedBox(
                  width: 200,
                  child: ShadInput(
                    controller: _tmdbApiKeyController,
                    placeholder: const Text('输入 TMDB API Key'),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _SettingsRow(
                icon: Icons.dns_rounded,
                label: '代理地址',
                child: SizedBox(
                  width: 200,
                  child: ShadInput(
                    controller: _tmdbProxyHostController,
                    placeholder: const Text('例: 127.0.0.1'),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _SettingsRow(
                icon: Icons.numbers_rounded,
                label: '代理端口',
                child: SizedBox(
                  width: 200,
                  child: ShadInput(
                    controller: _tmdbProxyPortController,
                    placeholder: const Text('例: 7890'),
                  ),
                ),
              ),
              _SettingsRow(
                icon: Icons.image_rounded,
                label: '图片加速代理',
                child: SizedBox(
                  width: 200,
                  child: ShadInput(
                    controller: _tmdbImageProxyController,
                    placeholder: const Text('https://wsrv.nl（留空直连）'),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const ShadSeparator.horizontal(),
              const SizedBox(height: 16),
              Text(
                '关于',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: cs.foreground,
                ),
              ),
              const SizedBox(height: 12),
              _SettingsRow(
                icon: Icons.cloud_rounded,
                label: '版本',
                child: Text(
                  'v1.0.0',
                  style: TextStyle(fontSize: 13, color: cs.mutedForeground),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _saveSettings() async {
    StorageManager.set(
      StorageKeys.tmdbApiKey,
      _tmdbApiKeyController.text.trim(),
    );
    StorageManager.set(
      StorageKeys.tmdbProxyHost,
      _tmdbProxyHostController.text.trim(),
    );
    StorageManager.set(
      StorageKeys.tmdbProxyPort,
      _tmdbProxyPortController.text.trim(),
    );
    StorageManager.set(
      StorageKeys.tmdbImageProxy,
      _tmdbImageProxyController.text.trim(),
    );
    StorageManager.set(
      StorageKeys.httpProxyHost,
      _httpProxyHostController.text.trim(),
    );
    StorageManager.set(
      StorageKeys.httpProxyPort,
      _httpProxyPortController.text.trim(),
    );
    StorageManager.set(
      StorageKeys.mediaScanConcurrency,
      _scanConcurrencyController.text.trim(),
    );
    StorageManager.set(
      StorageKeys.fastTransferConcurrency,
      _transferConcurrencyController.text.trim(),
    );
    StorageManager.set(
      StorageKeys.fileCacheTTLMinutes,
      _cacheTTLController.text.trim(),
    );
    await StorageManager.set(
      StorageKeys.cloudIndexRefreshMinutes,
      _cloudIndexRefreshController.text.trim(),
    );
    ref.read(mediaLibraryProvider.notifier).updateCloudIndexRefreshSchedule();
    StorageManager.set(
      StorageKeys.defaultFilePageSize,
      _pageSizeController.text.trim(),
    );
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

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: cs.mutedForeground),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(fontSize: 14, color: cs.foreground)),
          const Spacer(),
          child,
        ],
      ),
    );
  }
}
