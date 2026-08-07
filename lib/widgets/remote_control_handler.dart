import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Interface for widgets that can trigger a context menu via remote control.
///
/// Widgets that want the remote's Menu key to open their context menu should
/// implement this and expose [showContextMenu]. The global handler will call
/// it when the focused widget (or an ancestor) implements this interface.
abstract class ContextMenuTrigger {
  void showContextMenu();
}

/// A named focus region used by TV-style layouts.
///
/// Directional focus is kept inside the region. When focus reaches the left or
/// right edge, [RemoteControlHandler] moves to the configured adjacent region
/// and restores that region's most recently focused child.
class RemoteFocusRegion extends StatefulWidget {
  final String id;
  final String? leftRegionId;
  final String? rightRegionId;
  final bool autofocus;
  final Widget child;

  const RemoteFocusRegion({
    super.key,
    required this.id,
    this.leftRegionId,
    this.rightRegionId,
    this.autofocus = false,
    required this.child,
  });

  @override
  State<RemoteFocusRegion> createState() => _RemoteFocusRegionState();
}

class _RemoteFocusRegionState extends State<RemoteFocusRegion> {
  late final FocusScopeNode scopeNode = FocusScopeNode(
    debugLabel: 'remote-region-${widget.id}',
    traversalEdgeBehavior: TraversalEdgeBehavior.stop,
    directionalTraversalEdgeBehavior: TraversalEdgeBehavior.stop,
  );
  _RemoteControlHandlerState? _handler;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final handler = context
        .findAncestorStateOfType<_RemoteControlHandlerState>();
    if (!identical(handler, _handler)) {
      _handler?._unregisterRegion(widget.id, this);
      _handler = handler?.._registerRegion(widget.id, this);
    }
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scopeNode.focusedChild == null) requestRememberedFocus();
      });
    }
  }

  @override
  void didUpdateWidget(covariant RemoteFocusRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      _handler?._unregisterRegion(oldWidget.id, this);
      _handler?._registerRegion(widget.id, this);
    }
  }

  bool move(TraversalDirection direction) {
    final focused =
        scopeNode.focusedChild ?? FocusManager.instance.primaryFocus;
    if (focused == null || !focused.hasFocus) return false;
    return focused.focusInDirection(direction);
  }

  bool requestRememberedFocus() {
    final remembered = scopeNode.focusedChild;
    if (remembered != null && remembered.canRequestFocus) {
      remembered.requestFocus();
      return true;
    }
    for (final node in scopeNode.traversalDescendants) {
      if (node.canRequestFocus && !node.skipTraversal) {
        node.requestFocus();
        return true;
      }
    }
    return false;
  }

  String? adjacentRegionId(TraversalDirection direction) => switch (direction) {
    TraversalDirection.left => widget.leftRegionId,
    TraversalDirection.right => widget.rightRegionId,
    _ => null,
  };

  @override
  void dispose() {
    _handler?._unregisterRegion(widget.id, this);
    scopeNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: FocusScope.withExternalFocusNode(
        focusScopeNode: scopeNode,
        autofocus: widget.autofocus,
        child: widget.child,
      ),
    );
  }
}

/// Global remote control / keyboard handler for TV and desktop.
///
/// Covers **all** remote keys:
///
/// | Key | Behavior |
/// |----|----------|
/// | ↑ / ↓ | Navigate the list **inside** the current region (sidebar or content) |
/// | ← / → | Cross between the sidebar region and the content region |
/// | Enter / OK (Select / GameButtonA) | Activate the focused widget. `enter`/`space` are left to shadcn_ui's own CallbackShortcuts; `select`/`gameButtonA` are synthesized here as a fallback because ShadButton does not bind them |
/// | Back / Escape | Close the top-most overlay (popover/dialog/sheet) first; if none, pop the current route |
/// | Menu / GameButtonY | Trigger the focused widget's context menu via [ContextMenuTrigger] |
/// | Digits 1-9 | Jump focus to the Nth item in the current region's focusable list |
/// | Volume / Play control | Not handled — left to the system / player |
///
/// Critical design constraints (do not regress):
///   1. The ancestor [Focus] must NOT steal the primary focus (`autofocus: false`,
///      `canRequestFocus: false`). If it did, children would never become the
///      primary focus and their own Enter handlers (CallbackShortcuts /
///      onKeyEvent) would never fire — every button's OK press became a no-op
///      app-wide.
///   2. An ancestor can never *push* a key down to a descendant; the only way
///      a focused child receives Enter is for Flutter to deliver it to the
///      primary-focus node directly. So for `enter`/`space` we return
///      `ignored` and let the child handle it. We only synthesize activation
///      for `select`/`gameButtonA` (which ShadButton does not bind) and only
///      when no descendant consumed the key.
class RemoteControlHandler extends StatefulWidget {
  final Widget child;

  const RemoteControlHandler({super.key, required this.child});

  @override
  State<RemoteControlHandler> createState() => _RemoteControlHandlerState();
}

class _RemoteControlHandlerState extends State<RemoteControlHandler> {
  final _focusNode = FocusNode(debugLabel: 'RemoteControlHandler');
  final _regions = <String, _RemoteFocusRegionState>{};

  void _registerRegion(String id, _RemoteFocusRegionState region) {
    _regions[id] = region;
  }

  void _unregisterRegion(String id, _RemoteFocusRegionState region) {
    if (identical(_regions[id], region)) _regions.remove(id);
  }

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
    final editingText = _isEditingText();

    // Back / Escape: if a ShadPopover (e.g. ShadSelect dropdown) is open, defer
    // to its own escape CallbackShortcuts (a descendant focus) by returning
    // `ignored` — the popover hides itself and the key never reaches the
    // navigator, so the enclosing dialog is NOT popped first. Only when no
    // popover is open do we pop the route (handles modal routes / ShadDialog /
    // ShadSheet, which are themselves routes and have no popover-style child
    // escape binding to wait for).
    if (key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.escape) {
      if (_hasOpenPopover()) {
        return KeyEventResult.ignored;
      }
      _handleBack();
      return KeyEventResult.handled;
    }

    // All four directions first move spatially inside the current region.
    // Left/right cross regions only when the focused child is at an edge.
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveDirection(TraversalDirection.up);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveDirection(TraversalDirection.down);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (editingText) return KeyEventResult.ignored;
      _moveDirection(TraversalDirection.left);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      if (editingText) return KeyEventResult.ignored;
      _moveDirection(TraversalDirection.right);
      return KeyEventResult.handled;
    }

    // OK / Select / GameButtonA: synthesize activation for shadcn_ui widgets
    // (ShadButton / ShadIconButton / ShadOption) which only bind `enter` and
    // `space` via CallbackShortcuts and do NOT match the remote's `select` /
    // `gameButtonA`. Plain `enter` / `space` are left alone — those widgets
    // already handle them and synthesizing here would double-trigger.
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.gameButtonA) {
      if (_activateNearestShadButton()) {
        return KeyEventResult.handled;
      }
      if (_activateNearestShadOption()) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // Menu / GameButtonY: trigger the focused widget's context menu.
    if (key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.gameButtonY) {
      if (_triggerContextMenu()) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // Digits 1-9: jump focus to the Nth focusable in the current region.
    final digit = _digitFromKey(key);
    if (digit != null && !editingText) {
      _jumpToNthInCurrentScope(digit);
      return KeyEventResult.handled;
    }

    // Volume / Play control and anything else: not handled.
    return KeyEventResult.ignored;
  }

  /// Map a numeric logical key to its digit (1-9), or null if not a digit.
  int? _digitFromKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.digit1 || key == LogicalKeyboardKey.numpad1)
      return 1;
    if (key == LogicalKeyboardKey.digit2 || key == LogicalKeyboardKey.numpad2)
      return 2;
    if (key == LogicalKeyboardKey.digit3 || key == LogicalKeyboardKey.numpad3)
      return 3;
    if (key == LogicalKeyboardKey.digit4 || key == LogicalKeyboardKey.numpad4)
      return 4;
    if (key == LogicalKeyboardKey.digit5 || key == LogicalKeyboardKey.numpad5)
      return 5;
    if (key == LogicalKeyboardKey.digit6 || key == LogicalKeyboardKey.numpad6)
      return 6;
    if (key == LogicalKeyboardKey.digit7 || key == LogicalKeyboardKey.numpad7)
      return 7;
    if (key == LogicalKeyboardKey.digit8 || key == LogicalKeyboardKey.numpad8)
      return 8;
    if (key == LogicalKeyboardKey.digit9 || key == LogicalKeyboardKey.numpad9)
      return 9;
    return null;
  }

  /// Walk up from the current primary focus to the nearest [ShadButton] and
  /// invoke its `onPressed`. Returns true when a button was activated.
  ///
  /// This is the remote-control fallback for the `select` / `gameButtonA`
  /// keys, which shadcn_ui's CallbackShortcuts do not bind. `enter` / `space`
  /// are already handled by ShadButton itself and are intentionally not
  /// synthesized here to avoid double-triggering.
  bool _activateNearestShadButton() {
    final primary = FocusManager.instance.primaryFocus;
    final ctx = primary?.context;
    if (ctx == null) return false;
    final button = ctx.findAncestorWidgetOfExactType<ShadButton>();
    if (button == null) return false;
    final onPressed = button.onPressed;
    if (onPressed == null) return false;
    onPressed();
    return true;
  }

  /// Walk up from the current primary focus to the nearest [ShadOption] and
  /// select it in the enclosing [ShadSelect]. Returns true when an option was
  /// selected.
  ///
  /// shadcn_ui's [ShadOption] only binds `enter` via CallbackShortcuts
  /// (select.dart:1438) — it does NOT match the remote's `select` /
  /// `gameButtonA` keys, so those keys become a no-op when an option is
  /// focused. We synthesize selection by walking up to the nearest
  /// [ShadOption] widget, reading its `value`, and calling
  /// `ShadSelectState.select` on the enclosing select — the exact same thing
  /// [ShadOption]'s own Enter handler and onTap do.
  bool _activateNearestShadOption() {
    final primary = FocusManager.instance.primaryFocus;
    final ctx = primary?.context;
    if (ctx == null) return false;
    final option = ctx.findAncestorWidgetOfExactType<ShadOption<dynamic>>();
    if (option == null) return false;
    // Find the enclosing ShadSelect's state via InheritedWidget lookup, then
    // call select with the option's value — mirrors ShadOption's own Enter
    // handler (select.dart:1438-1440).
    final selectState = ctx.findAncestorStateOfType<ShadSelectState<dynamic>>();
    if (selectState == null) return false;
    selectState.select(option.value);
    return true;
  }

  void _moveDirection(TraversalDirection direction) {
    final primary = FocusManager.instance.primaryFocus;
    final primaryContext = primary?.context;
    if (primary == null || primaryContext == null) return;

    final region = primaryContext
        .findAncestorStateOfType<_RemoteFocusRegionState>();
    if (region == null) {
      // Dialogs, selects and popovers are intentionally outside the workspace
      // regions. ShadPopover's open state keeps focus on a skipTraversal node,
      // so Flutter's default focusInDirection can't see the option Focus nodes
      // (descendantsAreTraversable:false under RemoteFocusableButton). Collect
      // the focusable nodes in the enclosing scope ourselves and pick the
      // next one in the requested direction — this is what makes the remote's
      // arrow keys move between popover options.
      if (_moveWithinPopoverScope(primary, direction)) return;
      primary.focusInDirection(direction);
      return;
    }

    if (region.move(direction)) return;
    final targetId = region.adjacentRegionId(direction);
    if (targetId == null) return;
    _regions[targetId]?.requestRememberedFocus();
  }

  /// Walk the enclosing [FocusScope] of [primary] and move focus to the next
  /// option in [direction]. Returns true when focus actually moved.
  ///
  /// This is the popover fallback: ShadPopover opens with focus on a
  /// skipTraversal container node, and the option buttons are
  /// RemoteFocusableButtons whose Focus nodes have descendantsAreTraversable
  /// false. Flutter's focusInDirection therefore finds nothing. We collect the
  /// option Focus nodes via [_collectFocusableNodes] (which only descends into
  /// Focus widgets and stops at the first one per branch) and pick the nearest
  /// next/previous one for vertical directions, or the first one for lateral
  /// directions.
  bool _moveWithinPopoverScope(FocusNode primary, TraversalDirection direction) {
    final scope = primary.nearestScope;
    final scopeCtx = scope?.context;
    if (scopeCtx == null) return false;
    final nodes = <FocusNode>[];
    _collectFocusableNodes(scopeCtx, nodes);
    if (nodes.length < 2) return false;
    final currentIndex = nodes.indexOf(primary);
    if (currentIndex < 0) return false;
    // Vertical lists (the common popover layout): next/previous by index.
    // Horizontal is rare for popovers but handle it symmetrically.
    int targetIndex;
    switch (direction) {
      case TraversalDirection.down:
      case TraversalDirection.right:
        targetIndex = currentIndex + 1;
        break;
      case TraversalDirection.up:
      case TraversalDirection.left:
        targetIndex = currentIndex - 1;
        break;
      default:
        return false;
    }
    if (targetIndex < 0 || targetIndex >= nodes.length) return false;
    nodes[targetIndex].requestFocus();
    return true;
  }

  /// Jump focus to the Nth (1-based) focusable widget in the current region.
  ///
  /// Enumerates the current [FocusScope]'s first-level focusable children in
  /// tree order and requests focus on the Nth. If fewer than N exist, focuses
  /// the last. This is a pragmatic traversal that covers the common sidebar
  /// / content list layouts; widgets using custom focus ordering can opt out
  /// by handling the digit keys themselves.
  void _jumpToNthInCurrentScope(int n) {
    final primary = FocusManager.instance.primaryFocus;
    final scope = primary?.nearestScope;
    final scopeCtx = scope?.context;
    if (scopeCtx == null) return;
    final nodes = <FocusNode>[];
    _collectFocusableNodes(scopeCtx, nodes);
    if (nodes.isEmpty) return;
    final idx = (n - 1).clamp(0, nodes.length - 1);
    nodes[idx].requestFocus();
  }

  /// Depth-first walk of [ctx]'s subtree collecting [FocusNode]s attached to
  /// [Focus] widgets (the focusable widgets). Stops descending into a branch
  /// once a focus node is found so we don't double-count nested focuses.
  ///
  /// Important: `FocusScope` / `FocusTraversalGroup` container widgets inject
  /// their own FocusNode that is NOT a leaf focusable — we must descend through
  /// them (the `FocusScope` / `FocusTraversalGroup` widget check below) rather
  /// than stopping at the container, otherwise popover options nested inside a
  /// `RemoteFocusMenu`'s FocusTraversalGroup+FocusScope wrapper are never
  /// collected and the remote's arrow keys can't move between them.
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

  /// Whether a [ShadPopover] is currently open anywhere under this handler.
  ///
  /// Used by the Escape / Back handler to decide whether to defer to the
  /// popover's own escape binding (return `ignored`) or to pop the route. We
  /// detect an open popover by walking the element tree for a [ShadPopover]
  /// widget whose `controller.isOpen` is true. Reading the controller off the
  /// **widget** (not the private State) is reliable across shadcn_ui versions.
  bool _hasOpenPopover() {
    var found = false;
    void visit(Element element) {
      if (found) return;
      final widget = element.widget;
      if (widget is ShadPopover && widget.controller?.isOpen == true) {
        found = true;
        return;
      }
      element.visitChildren(visit);
    }

    visit(context as Element);
    return found;
  }

  /// Trigger the focused widget's context menu via [ContextMenuTrigger].
  ///
  /// Walks up from the current primary focus to find the nearest StatefulWidget
  /// whose State implements [ContextMenuTrigger], and calls [showContextMenu].
  bool _triggerContextMenu() {
    final primary = FocusManager.instance.primaryFocus;
    final ctx = primary?.context;
    if (ctx == null) return false;
    var found = false;
    ctx.visitAncestorElements((e) {
      if (e is StatefulElement && e.state is ContextMenuTrigger) {
        (e.state as ContextMenuTrigger).showContextMenu();
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  bool _isEditingText() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    if (context.widget is EditableText) return true;
    return context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _handleBack() {
    final navigator = Navigator.of(context, rootNavigator: true);
    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      // Critical: do NOT autofocus. If this ancestor held the primary focus,
      // children would never become the primary focus and their own Enter
      // handlers (CallbackShortcuts / onKeyEvent) would never fire — every
      // button's OK press became a no-op app-wide.
      autofocus: false,
      // An ancestor focus only needs to *observe* key events bubbling up; it
      // should not itself be a focusable target.
      canRequestFocus: false,
      onKeyEvent: _handleKeyEvent,
      child: widget.child,
    );
  }
}
