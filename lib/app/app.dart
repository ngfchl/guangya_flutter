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
      // 的 WidgetsApp 风格构建链会用自己的 MediaQuery（基于 PlatformDispatcher
      // 系统值）覆盖外层注入的 textScaler，导致套在外层的缩放无效。套在 home
      // 内部才能覆盖 ShadApp 自己注入的那个，缩放生效。
      //
      // **整体结构缩放**：textScaler 只缩字号，菜单栏宽度/标题栏高度/间距等固定
      // px 值不受影响。为了让低 PPI 大屏整体结构（不光字号）也缩小、显示更多内容，
      // 用 Transform.scale 把整个 View 按 _lowPpiScale 缩放，再用 OverflowBox
      // 放大布局空间让缩放后的内容撑满全屏（不留空白）。
      home: MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: _lowPpiTextScaler(context),
        ),
        child: _LowPpiScale(
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

  /// 低 PPI 大屏（TV/投影仪）的字号缩放系数。
  ///
  /// **触发条件**：`devicePixelRatio <= 2.0`（低 PPI 设备特征——TV/投影仪通常
  /// 1.0-2.0，手机/桌面 retina 通常 ≥ 2.5）。这一条件比固定宽度阈值更可靠：
  /// 1080p TV 物理宽 1080 < 1400 会被旧阈值漏掉，但它的 DPR 同样低，应触发缩放。
  ///
  /// **缩放系数**：按物理宽度线性缩小，1080→0.82、1920→0.78、2560→0.66、
  /// 3840→0.54。高 PPI 设备（DPR > 2.0）返回 1.0 不缩。
  TextScaler _lowPpiTextScaler(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    if (dpr > 2.0) return TextScaler.linear(1.0);
    final width = MediaQuery.sizeOf(context).width;
    // 1080→0.82, 1920→0.78, 2560→0.66, 3840→0.54
    final factor = (1.0 - (width - 1080) / 6000).clamp(0.54, 0.82);
    return TextScaler.linear(factor);
  }

  /// 整体结构缩放系数（与 [_lowPpiTextScaler] 同口径），用于 Transform.scale
  /// 缩整个 View。高 PPI 设备返回 1.0 不缩。
  ///
  /// 上一版上限 0.82 偏大，本版上限降到 0.72、下限降到 0.42、斜率加大，让 TV 端
  /// 整体结构明显缩小、单屏显示更多内容。
  double _lowPpiScale(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    if (dpr > 2.0) return 1.0;
    final width = MediaQuery.sizeOf(context).width;
    // 1080→0.72, 1920→0.66, 2560→0.54, 3840→0.42
    return (1.0 - (width - 1080) / 2300).clamp(0.42, 0.72);
  }
}

/// 用 Transform.scale 把子树整体缩放 [scale] 倍，同时用 OverflowBox 放大布局
/// 空间让缩放后的内容撑满父容器——避免缩放后右侧/底部留空白。
///
/// scale < 1 时，OverflowBox 给子树一个 `1/scale` 倍大的布局空间（例如 scale=0.78
/// 时给 1/0.78≈1.28 倍空间），子树按这个放大空间布局，再被 Transform.scale 缩回
/// 原尺寸，等效整体结构缩小、单屏显示更多内容。
class _LowPpiScale extends StatelessWidget {
  final Widget child;

  const _LowPpiScale({required this.child});

  @override
  Widget build(BuildContext context) {
    final appState = context.findAncestorStateOfType<_GuangyaAppState>();
    final scale = appState?._lowPpiScale(context) ?? 1.0;
    if (scale >= 1.0) return child;
    final size = MediaQuery.sizeOf(context);
    return OverflowBox(
      minWidth: size.width / scale,
      maxWidth: size.width / scale,
      minHeight: size.height / scale,
      maxHeight: size.height / scale,
      alignment: Alignment.topLeft,
      child: Transform.scale(
        scale: scale,
        alignment: Alignment.topLeft,
        child: child,
      ),
    );
  }
}
