import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../claude_session/claude_session_screen.dart';
import '../codex_session/codex_session_screen.dart';
import '../session_list/session_list_screen.dart';
import '../session_list/workspace_shell_screen.dart';
import 'tab_active_scope.dart';
import 'tabs_cubit.dart';
import 'tabs_state.dart';

/// Hosts the macOS tab system. On non-macOS platforms this is a thin
/// pass-through that renders [AdaptiveHomeScreen] (the upstream behaviour).
///
/// On macOS:
///   - Tab 0 is the simple session list (no workspace shell / no left pane).
///   - Tabs 1..N are open sessions kept alive via [IndexedStack] so their
///     state survives tab switches.
@RoutePage()
class MacTabsHostScreen extends StatelessWidget {
  const MacTabsHostScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) {
      return const AdaptiveHomeScreen();
    }
    return BlocBuilder<TabsCubit, TabsState>(
      builder: (context, state) {
        return Shortcuts(
          shortcuts: {
            const SingleActivator(LogicalKeyboardKey.keyW, meta: true):
                const _CloseTabIntent(),
            const SingleActivator(LogicalKeyboardKey.keyT, meta: true):
                const _GoHomeIntent(),
            const SingleActivator(
              LogicalKeyboardKey.bracketLeft,
              meta: true,
              shift: true,
            ): const _PrevTabIntent(),
            const SingleActivator(
              LogicalKeyboardKey.bracketRight,
              meta: true,
              shift: true,
            ): const _NextTabIntent(),
            const SingleActivator(LogicalKeyboardKey.digit1, meta: true):
                const _SelectTabIntent(1),
            const SingleActivator(LogicalKeyboardKey.digit2, meta: true):
                const _SelectTabIntent(2),
            const SingleActivator(LogicalKeyboardKey.digit3, meta: true):
                const _SelectTabIntent(3),
            const SingleActivator(LogicalKeyboardKey.digit4, meta: true):
                const _SelectTabIntent(4),
            const SingleActivator(LogicalKeyboardKey.digit5, meta: true):
                const _SelectTabIntent(5),
            const SingleActivator(LogicalKeyboardKey.digit6, meta: true):
                const _SelectTabIntent(6),
            const SingleActivator(LogicalKeyboardKey.digit7, meta: true):
                const _SelectTabIntent(7),
            const SingleActivator(LogicalKeyboardKey.digit8, meta: true):
                const _SelectTabIntent(8),
            const SingleActivator(LogicalKeyboardKey.digit9, meta: true):
                const _SelectTabIntent(9),
          },
          child: Actions(
            actions: {
              _CloseTabIntent: CallbackAction<_CloseTabIntent>(
                onInvoke: (_) {
                  context.read<TabsCubit>().closeActive();
                  return null;
                },
              ),
              _GoHomeIntent: CallbackAction<_GoHomeIntent>(
                onInvoke: (_) {
                  context.read<TabsCubit>().goHome();
                  return null;
                },
              ),
              _PrevTabIntent: CallbackAction<_PrevTabIntent>(
                onInvoke: (_) {
                  context.read<TabsCubit>().prevTab();
                  return null;
                },
              ),
              _NextTabIntent: CallbackAction<_NextTabIntent>(
                onInvoke: (_) {
                  context.read<TabsCubit>().nextTab();
                  return null;
                },
              ),
              _SelectTabIntent: CallbackAction<_SelectTabIntent>(
                onInvoke: (intent) {
                  context.read<TabsCubit>().selectTab(intent.activeIndex);
                  return null;
                },
              ),
            },
            child: Focus(
              autofocus: true,
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                child: Column(
                  children: [
                    _TabsBar(tabs: state.tabs, activeIndex: state.activeIndex),
                    Expanded(
                      child: IndexedStack(
                        index: state.activeIndex,
                        children: [
                          TabActiveScope(
                            isActive: state.activeIndex == 0,
                            child: const SessionListScreen(),
                          ),
                          for (var i = 0; i < state.tabs.length; i++)
                            KeyedSubtree(
                              key: ValueKey(state.tabs[i].id),
                              child: TabActiveScope(
                                isActive: state.activeIndex == i + 1,
                                child: _SessionTabContent(tab: state.tabs[i]),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SessionTabContent extends StatelessWidget {
  const _SessionTabContent({required this.tab});

  final TabEntry tab;

  @override
  Widget build(BuildContext context) {
    if (tab.provider == TabProvider.codex) {
      return CodexSessionScreen(
        sessionId: tab.sessionId,
        projectPath: tab.projectPath,
        gitBranch: tab.gitBranch,
        worktreePath: tab.worktreePath,
        isPending: tab.isPending,
        initialSandboxMode: tab.initialSandboxMode,
        initialPermissionMode: tab.initialPermissionMode,
        pendingSessionCreated: tab.pendingSessionCreated,
      );
    }
    return ClaudeSessionScreen(
      sessionId: tab.sessionId,
      projectPath: tab.projectPath,
      gitBranch: tab.gitBranch,
      worktreePath: tab.worktreePath,
      isPending: tab.isPending,
      initialPermissionMode: tab.initialPermissionMode,
      initialSandboxMode: tab.initialSandboxMode,
      pendingSessionCreated: tab.pendingSessionCreated,
    );
  }
}

class _TabsBar extends StatelessWidget {
  const _TabsBar({required this.tabs, required this.activeIndex});

  final List<TabEntry> tabs;
  final int activeIndex;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: cs.outlineVariant, width: 1)),
      ),
      child: Row(
        children: [
          // Reserve space for the macOS traffic-light buttons (red/yellow/green)
          // so they don't overlap the Home tab.
          const SizedBox(width: 78),
          _TabChip(
            label: 'Home',
            icon: Icons.home_outlined,
            active: activeIndex == 0,
            closable: false,
            onTap: () => context.read<TabsCubit>().goHome(),
            onClose: null,
          ),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: tabs.length,
              itemBuilder: (ctx, i) {
                final tab = tabs[i];
                return _TabChip(
                  label: tab.displayLabel,
                  icon: tab.provider == TabProvider.codex
                      ? Icons.terminal
                      : Icons.smart_toy_outlined,
                  active: activeIndex == i + 1,
                  closable: true,
                  onTap: () => context.read<TabsCubit>().selectTab(i + 1),
                  onClose: () => context.read<TabsCubit>().closeTabAt(i),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.label,
    required this.icon,
    required this.active,
    required this.closable,
    required this.onTap,
    required this.onClose,
  });

  final String label;
  final IconData icon;
  final bool active;
  final bool closable;
  final VoidCallback onTap;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = active ? cs.surface : Colors.transparent;
    final fg = active ? cs.onSurface : cs.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 200),
        decoration: BoxDecoration(
          color: bg,
          border: Border(
            right: BorderSide(color: cs.outlineVariant, width: 1),
            top: active
                ? BorderSide(color: cs.primary, width: 2)
                : BorderSide.none,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: fg,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            if (closable) ...[
              const SizedBox(width: 8),
              InkWell(
                onTap: onClose,
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(Icons.close, size: 14, color: fg),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CloseTabIntent extends Intent {
  const _CloseTabIntent();
}

class _GoHomeIntent extends Intent {
  const _GoHomeIntent();
}

class _PrevTabIntent extends Intent {
  const _PrevTabIntent();
}

class _NextTabIntent extends Intent {
  const _NextTabIntent();
}

class _SelectTabIntent extends Intent {
  const _SelectTabIntent(this.activeIndex);
  final int activeIndex;
}
