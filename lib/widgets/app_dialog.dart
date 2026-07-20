import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart' as shad;

Future<T?> showShadDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  String barrierLabel = '',
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  shad.ShadDialogVariant variant = shad.ShadDialogVariant.primary,
}) {
  return shad.showShadDialog<T>(
    context: context,
    builder: builder,
    barrierDismissible: barrierDismissible,
    barrierColor: Colors.transparent,
    barrierLabel: barrierLabel,
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    anchorPoint: anchorPoint,
    variant: variant,
    opaque: false,
  );
}

Future<T?> showShadSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  shad.ShadSheetSide? side,
  Color? backgroundColor,
  String barrierLabel = '',
  ShapeBorder? shape,
  bool useRootNavigator = false,
  bool isDismissible = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
}) {
  return shad.showShadSheet<T>(
    context: context,
    builder: builder,
    side: side,
    backgroundColor: backgroundColor,
    barrierLabel: barrierLabel,
    shape: shape,
    barrierColor: Colors.transparent,
    useRootNavigator: useRootNavigator,
    isDismissible: isDismissible,
    routeSettings: routeSettings,
    anchorPoint: anchorPoint,
  );
}
