import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../models/messages.dart';
import 'tabs_state.dart';

/// Manages the list of open session tabs on macOS.
///
/// Index 0 is always the home (session list). Indices 1..N correspond to
/// [TabsState.tabs] entries (offset by one).
class TabsCubit extends Cubit<TabsState> {
  TabsCubit() : super(const TabsState(tabs: [], activeIndex: 0));

  int _seq = 0;

  /// Open a session as a new tab, or switch to the existing tab if the same
  /// session is already open.
  void openSession({
    required String sessionId,
    required TabProvider provider,
    String? projectPath,
    String? gitBranch,
    String? worktreePath,
    bool isPending = false,
    String? initialPermissionMode,
    String? initialSandboxMode,
    ValueNotifier<SystemMessage?>? pendingSessionCreated,
  }) {
    final existing = state.tabs.indexWhere(
      (t) => t.sessionId == sessionId && t.provider == provider,
    );
    if (existing >= 0) {
      emit(state.copyWith(activeIndex: existing + 1));
      return;
    }
    _seq++;
    final entry = TabEntry(
      id: 'tab_$_seq',
      sessionId: sessionId,
      provider: provider,
      projectPath: projectPath,
      gitBranch: gitBranch,
      worktreePath: worktreePath,
      isPending: isPending,
      initialPermissionMode: initialPermissionMode,
      initialSandboxMode: initialSandboxMode,
      pendingSessionCreated: pendingSessionCreated,
    );
    final newTabs = [...state.tabs, entry];
    emit(TabsState(tabs: newTabs, activeIndex: newTabs.length));
  }

  /// Close the tab at the given index in [TabsState.tabs] (NOT activeIndex).
  void closeTabAt(int idx) {
    if (idx < 0 || idx >= state.tabs.length) return;
    final newTabs = [...state.tabs]..removeAt(idx);
    var newActive = state.activeIndex;
    if (newActive == idx + 1) {
      // Closing active tab → fall back to the previous tab (or home).
      newActive = (newActive - 1).clamp(0, newTabs.length);
    } else if (newActive > idx + 1) {
      newActive = newActive - 1;
    }
    emit(TabsState(tabs: newTabs, activeIndex: newActive));
  }

  /// Close the currently active tab. Home cannot be closed.
  void closeActive() {
    if (state.activeIndex == 0) return;
    closeTabAt(state.activeIndex - 1);
  }

  /// Select the tab at the given activeIndex (0 = home, 1..N = tabs).
  void selectTab(int activeIndex) {
    final maxIdx = state.tabs.length;
    if (activeIndex < 0 || activeIndex > maxIdx) return;
    emit(state.copyWith(activeIndex: activeIndex));
  }

  void goHome() => selectTab(0);

  void nextTab() {
    final n = state.tabs.length;
    if (n == 0) return;
    var next = state.activeIndex + 1;
    if (next > n) next = 0;
    selectTab(next);
  }

  void prevTab() {
    final n = state.tabs.length;
    if (n == 0) return;
    var prev = state.activeIndex - 1;
    if (prev < 0) prev = n;
    selectTab(prev);
  }
}
