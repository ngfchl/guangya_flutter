import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

enum AppLoadingSize { inline, compact, regular, page }

class AppLoadingIndicator extends StatelessWidget {
  final double? value;
  final AppLoadingSize size;
  final String? label;
  final String? description;
  final Color? color;
  final Color? backgroundColor;
  final String? semanticsLabel;
  final String? semanticsValue;

  const AppLoadingIndicator({
    super.key,
    this.value,
    this.size = AppLoadingSize.regular,
    this.label,
    this.description,
    this.color,
    this.backgroundColor,
    this.semanticsLabel,
    this.semanticsValue,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final windowScale = viewportWidth < 600
        ? 0.88
        : viewportWidth < 1200
        ? 1.0
        : 1.12;
    final baseDimension = switch (size) {
      AppLoadingSize.inline => 15.0,
      AppLoadingSize.compact => 21.0,
      AppLoadingSize.regular => 31.0,
      AppLoadingSize.page => 42.0,
    };
    final baseStroke = switch (size) {
      AppLoadingSize.inline => 1.8,
      AppLoadingSize.compact => 2.2,
      AppLoadingSize.regular => 2.8,
      AppLoadingSize.page => 3.4,
    };
    final dimension = (baseDimension * windowScale).roundToDouble();
    final strokeWidth = (baseStroke * windowScale).clamp(1.5, 4.0);
    final normalizedValue = value?.clamp(0.0, 1.0);
    final effectiveValue = MediaQuery.disableAnimationsOf(context)
        ? (normalizedValue ?? 0.72)
        : normalizedValue;
    final indicator = SizedBox.square(
      dimension: dimension,
      child: CircularProgressIndicator(
        value: effectiveValue,
        strokeWidth: strokeWidth,
        strokeCap: StrokeCap.round,
        color: color ?? scheme.primary,
        backgroundColor:
            backgroundColor ??
            (normalizedValue == null
                ? null
                : scheme.mutedForeground.withValues(alpha: 0.18)),
      ),
    );
    final labelText = label?.trim();
    final descriptionText = description?.trim();
    final semantics = [
      semanticsLabel ?? labelText ?? '正在加载',
      if (descriptionText?.isNotEmpty == true) descriptionText!,
    ].join('，');

    return Semantics(
      label: semantics,
      value: semanticsValue,
      liveRegion: normalizedValue == null,
      excludeSemantics: true,
      child:
          labelText?.isNotEmpty != true && descriptionText?.isNotEmpty != true
          ? indicator
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                indicator,
                if (labelText?.isNotEmpty == true) ...[
                  SizedBox(height: size == AppLoadingSize.page ? 14 : 10),
                  Text(
                    labelText!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: viewportWidth < 600 ? 13 : 14,
                      fontWeight: FontWeight.w600,
                      color: scheme.foreground,
                    ),
                  ),
                ],
                if (descriptionText?.isNotEmpty == true) ...[
                  const SizedBox(height: 5),
                  Text(
                    descriptionText!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: viewportWidth < 600 ? 11 : 12,
                      color: scheme.mutedForeground,
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
