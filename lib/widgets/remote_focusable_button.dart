import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Isolates a popover/dropdown from the page focus tree and moves focus to its
/// first actionable child when it appears.
///
/// This is intended for custom [Overlay] menus. Without a local focus scope,
/// the remote keeps moving through the page behind the open menu because the
/// trigger retains focus.
class RemoteFocusMenu extends StatefulWidget {
  final Widget child;
  final bool autofocusFirst;

  const RemoteFocusMenu({
    super.key,
    required this.child,
    this.autofocusFirst = true,
  });

  @override
  State<RemoteFocusMenu> createState() => _RemoteFocusMenuState();
}

class _RemoteFocusMenuState extends State<RemoteFocusMenu> {
  late final FocusScopeNode _scopeNode = FocusScopeNode(
    debugLabel: 'remote-popover-menu',
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
    directionalTraversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
  );
  FocusNode? _previousFocus;

  @override
  void initState() {
    super.initState();
    _previousFocus = FocusManager.instance.primaryFocus;
    if (widget.autofocusFirst) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusFirst());
    }
  }

  void _focusFirst() {
    if (!mounted) return;
    // _scopeNode.traversalDescendants only includes nodes whose
    // descendantsAreTraversable is true. RemoteFocusableButton sets it false
    // (its own Focus node should be the leaf), so the option nodes are absent
    // from that list and _focusFirst would find nothing — the popover opens
    // with focus still on the trigger, making the remote's arrow keys a no-op
    // inside the menu. Walk the scope's context ourselves and focus the first
    // canRequestFocus Focus node we find.
    final ctx = _scopeNode.context;
    if (ctx == null) return;
    final nodes = <FocusNode>[];
    _collectFocusableNodes(ctx, nodes);
    for (final node in nodes) {
      if (node.canRequestFocus) {
        node.requestFocus();
        return;
      }
    }
  }

  /// Depth-first walk collecting Focus nodes attached to [Focus] widgets.
  /// Penetrates [FocusScope] / [FocusTraversalGroup] container widgets so
  /// popover options nested under this menu's FocusScope wrapper are found.
  void _collectFocusableNodes(BuildContext ctx, List<FocusNode> out) {
    final widget = ctx.widget;
    if (widget is FocusScope || widget is FocusTraversalGroup) {
      ctx.visitChildElements((child) {
        _collectFocusableNodes(child, out);
      });
      return;
    }
    if (widget is Focus && widget.focusNode != null) {
      out.add(widget.focusNode!);
      return;
    }
    ctx.visitChildElements((child) {
      _collectFocusableNodes(child, out);
    });
  }

  @override
  void dispose() {
    final previousFocus = _previousFocus;
    if (previousFocus != null && previousFocus.canRequestFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (previousFocus.canRequestFocus) previousFocus.requestFocus();
      });
    }
    _scopeNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: FocusScope.withExternalFocusNode(
        focusScopeNode: _scopeNode,
        child: widget.child,
      ),
    );
  }
}

/// A tappable wrapper that is fully controllable by remote / keyboard.
///
/// Many custom clickables in the app use raw [InkWell] / [GestureDetector],
/// which do not register an Enter / Space / Select key handler. When such a
/// widget receives focus (e.g. via the remote's directional keys), pressing
/// the remote's OK button does nothing.
///
/// This widget wraps the child in a [Focus] with [CallbackShortcuts] that
/// map Enter, NumpadEnter, Space, GameButtonA and Select to [onTap], so the
/// remote's OK button activates the focused widget.
///
/// Use it around any custom clickable that should respond to the remote.
class RemoteFocusableButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final bool autofocus;
  final bool enabled;
  final FocusNode? focusNode;

  const RemoteFocusableButton({
    super.key,
    required this.child,
    required this.onTap,
    this.autofocus = false,
    this.enabled = true,
    this.focusNode,
  });

  @override
  State<RemoteFocusableButton> createState() => _RemoteFocusableButtonState();
}

class _RemoteFocusableButtonState extends State<RemoteFocusableButton> {
  FocusNode? _internalFocusNode;
  bool _focused = false;

  FocusNode get _focusNode =>
      widget.focusNode ??
      (_internalFocusNode ??= FocusNode(debugLabel: 'remote-button'));

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.gameButtonA) {
      widget.onTap?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _internalFocusNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      canRequestFocus: widget.enabled && widget.onTap != null,
      descendantsAreFocusable: false,
      descendantsAreTraversable: false,
      onKeyEvent: _handleKeyEvent,
      onFocusChange: (focused) {
        if (_focused != focused) setState(() => _focused = focused);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        foregroundDecoration: _focused
            ? BoxDecoration(
                border: Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(8),
              )
            : null,
        child: widget.child,
      ),
    );
  }
}
