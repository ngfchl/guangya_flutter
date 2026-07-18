import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import '../providers/theme_provider.dart';
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

  @override
  void initState() {
    super.initState();
    _tmdbApiKeyController.text =
        StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    _tmdbProxyHostController.text =
        StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '';
    _tmdbProxyPortController.text =
        StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '';
  }

  @override
  void dispose() {
    _tmdbApiKeyController.dispose();
    _tmdbProxyHostController.dispose();
    _tmdbProxyPortController.dispose();
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
          onPressed: () {
            _saveSettings();
            Navigator.of(context).pop();
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
              Text('外观',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: cs.foreground)),
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
                        child: const Row(children: [
                          Icon(Icons.light_mode_rounded, size: 14),
                          SizedBox(width: 8),
                          Text('浅色')
                        ])),
                    ShadOption(
                        value: 'dark',
                        child: const Row(children: [
                          Icon(Icons.dark_mode_rounded, size: 14),
                          SizedBox(width: 8),
                          Text('深色')
                        ])),
                    ShadOption(
                        value: 'system',
                        child: const Row(children: [
                          Icon(Icons.brightness_auto_rounded, size: 14),
                          SizedBox(width: 8),
                          Text('跟随系统')
                        ])),
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
              Text('TMDB 配置',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: cs.foreground)),
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
              const SizedBox(height: 16),
              const ShadSeparator.horizontal(),
              const SizedBox(height: 16),
              Text('关于',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: cs.foreground)),
              const SizedBox(height: 12),
              _SettingsRow(
                icon: Icons.cloud_rounded,
                label: '版本',
                child: Text('v1.0.0',
                    style: TextStyle(fontSize: 13, color: cs.mutedForeground)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _saveSettings() {
    StorageManager.set(
        StorageKeys.tmdbApiKey, _tmdbApiKeyController.text.trim());
    StorageManager.set(
        StorageKeys.tmdbProxyHost, _tmdbProxyHostController.text.trim());
    StorageManager.set(
        StorageKeys.tmdbProxyPort, _tmdbProxyPortController.text.trim());
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

  const _SettingsRow(
      {required this.icon, required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: cs.mutedForeground),
          const SizedBox(width: 12),
          Text(label,
              style: TextStyle(fontSize: 14, color: cs.foreground)),
          const Spacer(),
          child,
        ],
      ),
    );
  }
}
