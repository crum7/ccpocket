import 'package:flutter/foundation.dart';

import '../../models/messages.dart';

/// Which provider a tab is hosting.
enum TabProvider { claude, codex }

/// One open session tab in the macOS tab bar.
@immutable
class TabEntry {
  const TabEntry({
    required this.id,
    required this.sessionId,
    required this.provider,
    this.projectPath,
    this.gitBranch,
    this.worktreePath,
    this.isPending = false,
    this.initialPermissionMode,
    this.initialSandboxMode,
    this.pendingSessionCreated,
  });

  /// Stable per-tab id used as a Widget key so the session screen state
  /// survives across tab switches.
  final String id;
  final String sessionId;
  final TabProvider provider;
  final String? projectPath;
  final String? gitBranch;
  final String? worktreePath;
  final bool isPending;
  final String? initialPermissionMode;
  final String? initialSandboxMode;
  final ValueNotifier<SystemMessage?>? pendingSessionCreated;

  /// Short label shown in the tab strip.
  String get displayLabel {
    final path = projectPath;
    if (path != null && path.isNotEmpty) {
      final segments = path.split('/').where((s) => s.isNotEmpty).toList();
      if (segments.isNotEmpty) return segments.last;
    }
    if (sessionId.length > 8) return sessionId.substring(0, 8);
    return sessionId;
  }
}

@immutable
class TabsState {
  const TabsState({required this.tabs, required this.activeIndex});

  /// Open session tabs (excluding the home tab).
  final List<TabEntry> tabs;

  /// 0 = home (session list), 1..N = tabs[index - 1].
  final int activeIndex;

  TabsState copyWith({List<TabEntry>? tabs, int? activeIndex}) {
    return TabsState(
      tabs: tabs ?? this.tabs,
      activeIndex: activeIndex ?? this.activeIndex,
    );
  }
}
