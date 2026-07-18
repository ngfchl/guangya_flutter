import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import '../providers/theme_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/file_provider.dart';
import '../providers/media_library_provider.dart';
import '../pages/login_page.dart';
import '../pages/workspace_page.dart';
import 'app_theme.dart';

class GuangyaApp extends ConsumerWidget {
  const GuangyaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeState = ref.watch(themeProvider);
    final auth = ref.watch(authProvider);

    // Auto-load files when signed in
    if (auth.isSignedIn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final fp = ref.read(fileProvider.notifier);
        fp.api = ref.read(authProvider.notifier).api;
        ref.read(mediaLibraryProvider.notifier).api = ref
            .read(authProvider.notifier)
            .api;
        final fileState = ref.read(fileProvider);
        if (fileState.files.isEmpty && !fileState.isLoading) {
          fp.loadFiles();
        }
      });
    }

    return ShadApp(
      title: '光鸭云盘',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: themeState.themeMode,
      home: auth.isLoading
          ? const Scaffold(
              body: Center(child: SizedBox(width: 220, child: ShadProgress())),
            )
          : auth.isSignedIn
          ? const WorkspacePage()
          : const LoginPage(),
    );
  }
}
