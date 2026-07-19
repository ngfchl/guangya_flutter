import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import '../providers/theme_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/file_provider.dart';
import '../providers/media_library_provider.dart';
import '../pages/login_page.dart';
import '../pages/workspace_page.dart';
import '../widgets/app_loading_indicator.dart';
import 'app_theme.dart';

class GuangyaApp extends ConsumerStatefulWidget {
  const GuangyaApp({super.key});

  @override
  ConsumerState<GuangyaApp> createState() => _GuangyaAppState();
}

class _GuangyaAppState extends ConsumerState<GuangyaApp> {
  var _sessionInitialized = false;

  @override
  Widget build(BuildContext context) {
    final themeState = ref.watch(themeProvider);
    final auth = ref.watch(authProvider);

    if (!auth.isSignedIn) {
      _sessionInitialized = false;
    } else if (!_sessionInitialized) {
      _sessionInitialized = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !ref.read(authProvider).isSignedIn) return;
        final fp = ref.read(fileProvider.notifier);
        fp.api = ref.read(authProvider.notifier).api;
        final media = ref.read(mediaLibraryProvider.notifier);
        media.api = ref.read(authProvider.notifier).api;
        media.load();
        final fileState = ref.read(fileProvider);
        if (fileState.files.isEmpty && !fileState.isLoading) {
          fp.loadFiles();
        }
      });
    }

    return ShadApp(
      title: '小黄鸭',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: themeState.themeMode,
      home: auth.isLoading
          ? const Scaffold(
              body: Center(
                child: AppLoadingIndicator(
                  size: AppLoadingSize.page,
                  label: '正在准备光鸭',
                  description: '正在检查登录状态与本地配置',
                ),
              ),
            )
          : auth.isSignedIn
          ? const WorkspacePage()
          : const LoginPage(),
    );
  }
}
