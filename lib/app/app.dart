import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import '../providers/theme_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/file_provider.dart';
import '../providers/media_library_provider.dart';
import '../providers/scale_provider.dart';
import '../pages/login_page.dart';
import '../pages/workspace_page.dart';
import '../widgets/app_loading_indicator.dart';
import '../widgets/remote_control_handler.dart';
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
    final scale = ref.watch(scaleProvider);

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
      // MediaQuery 必须套在 ShadApp 的 home **内部**，而不是外层：ShadApp 内部
      // 的 WidgetsApp 岑格构建链会用自己的 MediaQuery（基于 PlatformDispatcher
      // 系统值）覆盖外层注入的 textScaler，导致套在外层的缩放无效。套在 home
      // 内部才能覆盖 ShadApp 自己注入的那个，缩放生效。
      //
      // **整体结构缩放**：textScaler 只缩字号，菜单栏宽度/标题栏高度/间距等固定
      // px 值不受影响。为了让整体结构（不光字号）也缩放，用 Transform.scale 把
      // 整个 View 按 scale 缩放，再用 OverflowBox 放大布局空间让缩放后的内容
      // 撑满全屏（不留空白）。
      //
      // scale 完全由用户在设置页「界面缩放」手动调节（0.5–1.5），同时作用于
      // 字号缩放与整体结构缩放，拖动即实时生效。
      home: MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
        ),
        child: _ScaleView(
          scale: scale,
          child: ShadToaster(
            child: RemoteControlHandler(
              child: auth.isLoading
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
            ),
          ),
        ),
      ),
    );
  }
}

/// 用 FittedBox 把子树整体缩放 [scale] 倍。
///
/// FittedBox(fit: BoxFit.scaleDown) 让子树按原始尺寸布局，再整体缩放
/// 到可用空间内——缩放后内容居中、不溢出、不错位，比 OverflowBox+
/// Transform.scale 的"放大布局空间再缩回"方式更稳，不会出现侧边栏
/// 标题错位等问题。
///
/// [scale] 完全由用户手动调节（设置页「界面缩放」，范围 0.5–1.5），拖动 Slider
/// 时 ref.watch(scaleProvider) 触发 rebuild，实时生效。
class _ScaleView extends StatelessWidget {
  final Widget child;
  final double scale;

  const _ScaleView({required this.child, required this.scale});

  @override
  Widget build(BuildContext context) {
    if (scale >= 1.0) return child;
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: MediaQuery.sizeOf(context).width / scale,
          height: MediaQuery.sizeOf(context).height / scale,
          child: child,
        ),
      ),
    );
  }
}
