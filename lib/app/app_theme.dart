import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Light theme
final lightTheme = ShadThemeData(
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
    final isDark = theme.brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: padding ?? const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark
                ? theme.colorScheme.card.withValues(alpha: 0.72)
                : Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: isDark
                  ? theme.colorScheme.border.withValues(alpha: 0.82)
                  : Colors.white.withValues(alpha: 0.2),
              width: 1,
            ),
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
    final isDark = ShadTheme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [Color(0xFF0B1220), Color(0xFF111827), Color(0xFF20151A)]
              : const [Color(0xFFE9F6F5), Color(0xFFF6FAF6), Color(0xFFF9E6D4)],
        ),
      ),
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

  const OS26Glass({
    super.key,
    required this.child,
    this.padding,
    this.radius = 18,
    this.opacity = 0.48,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: isDark
                ? theme.colorScheme.card.withValues(alpha: opacity + 0.18)
                : Colors.white.withValues(alpha: opacity),
            borderRadius: BorderRadius.circular(radius),
            border:
                border ??
                Border.all(
                  color: isDark
                      ? theme.colorScheme.border.withValues(alpha: 0.9)
                      : Colors.white.withValues(alpha: 0.58),
                  width: 1,
                ),
          ),
          child: child,
        ),
      ),
    );
  }
}
