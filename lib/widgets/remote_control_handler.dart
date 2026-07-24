import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Interface for widgets that can trigger a context menu via remote control.
abstract class ContextMenuTrigger {
  void showContextMenu();
}

/// Global remote control / keyboard handler for TV and desktop.
///
/// Handles:
/// - Arrow keys: navigate between focusable widgets
/// - Enter/OK: activate the focused widget
/// - Back/Escape: close dialogs or go back
/// - Menu key: context menu trigger
class RemoteControlHandler extends StatefulWidget {
  final Widget child;

  const RemoteControlHandler({super.key, required this.child});

  @override
  State<RemoteControlHandler> createState() => _RemoteControlHandlerState();
}

class _RemoteControlHandlerState extends State<RemoteControlHandler> {
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.escape) {
      _handleBack();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      Actions.invoke(context, const PreviousFocusIntent());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      Actions.invoke(context, const NextFocusIntent());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      Actions.invoke(
        context,
        const DirectionalFocusIntent(TraversalDirection.left),
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      Actions.invoke(
        context,
        const DirectionalFocusIntent(TraversalDirection.right),
      );
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.gameButtonA) {
      _activateFocused();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.gameButtonY) {
      _openContextMenu();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _activateFocused() {
    final node = FocusManager.instance.primaryFocus;
    if (node == null) return;
    final ctx = node.context;
    if (ctx == null) return;

    final intent = ActivateIntent();
    final action = Actions.maybeFind(ctx, intent: intent);
    if (action != null) {
      Actions.invoke(ctx, intent);
    }
  }

  void _handleBack() {
    final navigator = Navigator.of(context, rootNavigator: true);
    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  void _openContextMenu() {
    // Context menu is triggered by individual widgets.
    // This method serves as an entry point for future implementation.
    // Widgets that need context menu support should implement
    // ContextMenuTrigger and handle the menu key event directly.
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: widget.child,
    );
  }
}
