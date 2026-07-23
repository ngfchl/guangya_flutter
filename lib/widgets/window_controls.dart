import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// macOS-style traffic light window controls for Windows/Linux.
/// On macOS the system provides these natively, so this widget is hidden.
class WindowControls extends StatefulWidget {
  const WindowControls({super.key});

  @override
  State<WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends State<WindowControls> {
  bool _isMaximized = false;
  bool _isHovering = false;
  final _listener = _WinListener();

  @override
  void initState() {
    super.initState();
    _initState();
  }

  void _initState() async {
    _isMaximized = await windowManager.isMaximized();
    _listener._onMaximize = (max) {
      if (mounted && max != _isMaximized) {
        setState(() => _isMaximized = max);
      }
    };
    windowManager.addListener(_listener);
  }

  @override
  void dispose() {
    windowManager.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // On macOS, the system handles window controls natively.
    if (Platform.isMacOS) return const SizedBox.shrink();

    const double dotSize = 14;
    const double dotGap = 8;
    const double totalWidth = dotSize * 3 + dotGap * 2 + 4; // 4px extra padding

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: SizedBox(
        height: 28,
        width: totalWidth,
        child: Row(
          children: [
            // Close
            _TrafficDot(
              color: const Color(0xFFFF5F57),
              size: dotSize,
              hovered: _isHovering,
              icon: Icons.close_rounded,
              iconSize: 8,
              onTap: () => windowManager.close(),
            ),
            const SizedBox(width: dotGap),
            // Minimize
            _TrafficDot(
              color: const Color(0xFFFFBD2E),
              size: dotSize,
              hovered: _isHovering,
              icon: Icons.remove_rounded,
              iconSize: 10,
              onTap: () => windowManager.minimize(),
            ),
            const SizedBox(width: dotGap),
            // Maximize / Restore
            _TrafficDot(
              color: const Color(0xFF28C840),
              size: dotSize,
              hovered: _isHovering,
              icon: _isMaximized
                  ? Icons.filter_none_rounded
                  : Icons.maximize_rounded,
              iconSize: 8,
              onTap: () async {
                if (_isMaximized) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Minimal WindowListener to track maximize state.
class _WinListener extends WindowListener {
  void Function(bool isMaximized)? _onMaximize;

  @override
  void onWindowMaximize() {
    _onMaximize?.call(true);
  }

  @override
  void onWindowUnmaximize() {
    _onMaximize?.call(false);
  }
}

class _TrafficDot extends StatelessWidget {
  final Color color;
  final double size;
  final bool hovered;
  final IconData icon;
  final double iconSize;
  final VoidCallback onTap;

  const _TrafficDot({
    required this.color,
    required this.size,
    required this.hovered,
    required this.icon,
    required this.iconSize,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: color.computeLuminance() > 0.5
                ? Colors.black.withValues(alpha: 0.08)
                : Colors.white.withValues(alpha: 0.15),
            width: 0.5,
          ),
        ),
        child: Center(
          child: Icon(
            icon,
            size: iconSize,
            color: hovered
                ? Colors.black.withValues(alpha: 0.8)
                : Colors.transparent,
          ),
        ),
      ),
    );
  }
}
