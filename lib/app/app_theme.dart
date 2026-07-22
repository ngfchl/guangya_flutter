import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const _dismissibleToastTheme = ShadToastTheme(
  showCloseIconOnlyWhenHovered: false,
  closeIconPosition: ShadPosition(top: 8, right: 8),
);

// Light theme
final lightTheme = ShadThemeData(
  primaryToastTheme: _dismissibleToastTheme,
  destructiveToastTheme: _dismissibleToastTheme,
  colorScheme: const ShadOrangeColorScheme.light(
    background: Color(0xFFFFFFFF),
    foreground: Color(0xFF0F172A),
    card: Color(0xFFFFFFFF),
    cardForeground: Color(0xFF0F172A),
    popover: Color(0xFFFFFFFF),
    popoverForeground: Color(0xFF0F172A),
    primary: Color(0xFFF97316),
    primaryForeground: Color(0xFFFFFFFF),
    secondary: Color(0xFFF1F5F9),
    secondaryForeground: Color(0xFF0F172A),
    muted: Color(0xFFF1F5F9),
    mutedForeground: Color(0xFF64748B),
    accent: Color(0xFFF1F5F9),
    accentForeground: Color(0xFF0F172A),
    destructive: Color(0xFFEF4444),
    destructiveForeground: Color(0xFFFFFFFF),
    border: Color(0xFFE2E8F0),
    input: Color(0xFFE2E8F0),
    ring: Color(0xFFF97316),
    selection: Color(0xFFFB923C),
  ),
);

// Dark theme
final darkTheme = ShadThemeData(
  primaryToastTheme: _dismissibleToastTheme,
  destructiveToastTheme: _dismissibleToastTheme,
  colorScheme: const ShadOrangeColorScheme.dark(
    background: Color(0xFF0F172A),
    foreground: Color(0xFFF8FAFC),
    card: Color(0xFF1E293B),
    cardForeground: Color(0xFFF8FAFC),
    popover: Color(0xFF1E293B),
    popoverForeground: Color(0xFFF8FAFC),
    primary: Color(0xFFF97316),
    primaryForeground: Color(0xFFFFFFFF),
    secondary: Color(0xFF1E293B),
    secondaryForeground: Color(0xFFF8FAFC),
    muted: Color(0xFF1E293B),
    mutedForeground: Color(0xFF94A3B8),
    accent: Color(0xFF1E293B),
    accentForeground: Color(0xFFF8FAFC),
    destructive: Color(0xFFEF4444),
    destructiveForeground: Color(0xFFFFFFFF),
    border: Color(0xFF334155),
    input: Color(0xFF334155),
    ring: Color(0xFFF97316),
    selection: Color(0xFFFB923C),
  ),
);

class GlassCard extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsets? padding;

  const GlassCard({
    super.key,
    required this.child,
    this.borderRadius = 24,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: padding ?? const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: cs.card.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(color: cs.border, width: 1),
          ),
          child: child,
        ),
      ),
    );
  }
}

class OS26Surface extends StatelessWidget {
  final Widget child;

  const OS26Surface({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(color: cs.background),
      child: child,
    );
  }
}

class OS26Glass extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;
  final double opacity;
  final Border? border;
  final bool applyBlur;

  const OS26Glass({
    super.key,
    required this.child,
    this.padding,
    this.radius = 18,
    this.opacity = 0.48,
    this.border,
    this.applyBlur = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final surface = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: cs.card.withValues(alpha: opacity.clamp(0.0, 1.0)),
        borderRadius: BorderRadius.circular(radius),
        border: border ?? Border.all(color: cs.border, width: 1),
      ),
      child: child,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: applyBlur
          ? BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
              child: surface,
            )
          : surface,
    );
  }
}
