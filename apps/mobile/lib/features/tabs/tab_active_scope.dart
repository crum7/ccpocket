import 'package:flutter/widgets.dart';

/// Marks whether the surrounding subtree belongs to the currently active
/// macOS tab.
///
/// Inactive tabs in [IndexedStack] stay mounted, so their cubits keep
/// receiving bridge stream events. Without help, every assistant
/// `stream_delta` from a background session would still trigger a UI
/// rebuild for that hidden tab — multiplying perf cost by N tabs.
///
/// Reading [TabActiveScope.of] in a `build` method opts that widget into
/// rebuilding when its tab becomes active again, at which point any
/// children that consult the value rebuild once with the latest cubit
/// state. Combine with `BlocBuilder.buildWhen` to skip work in between.
class TabActiveScope extends InheritedWidget {
  const TabActiveScope({
    super.key,
    required this.isActive,
    required super.child,
  });

  final bool isActive;

  /// Returns the nearest [isActive] flag in the tree. Defaults to `true`
  /// when no scope is present (e.g. mobile, where there are no tabs at
  /// all and every screen is "active" by definition).
  static bool of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<TabActiveScope>();
    return scope?.isActive ?? true;
  }

  @override
  bool updateShouldNotify(TabActiveScope oldWidget) =>
      oldWidget.isActive != isActive;
}
