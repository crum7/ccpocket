import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../models/session_ref.dart';
import 'state/pane_node.dart';
import 'state/pane_tree_cubit.dart';
import 'widgets/pane_tree_view.dart';

/// Developer playground for the tmux-style split layout (design §3.3).
///
/// Reached from the Debug screen. Lets us validate the split/close/focus/resize
/// UX in isolation, with placeholder pane content, before wiring real
/// connection-scoped session screens into the production workspace (Phase 3).
class SplitPaneDebugScreen extends StatelessWidget {
  const SplitPaneDebugScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => PaneTreeCubit(),
      child: const _SplitPaneDebugBody(),
    );
  }
}

class _SplitPaneDebugBody extends StatelessWidget {
  const _SplitPaneDebugBody();

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<PaneTreeCubit>();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyD, meta: true): () =>
            cubit.splitFocused(SplitAxis.row),
        const SingleActivator(LogicalKeyboardKey.keyD, meta: true, shift: true):
            () => cubit.splitFocused(SplitAxis.column),
        const SingleActivator(LogicalKeyboardKey.keyW, meta: true): () =>
            cubit.closeFocused(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Split Pane (debug)'),
            actions: [
              IconButton(
                tooltip: 'Split vertical (⌘D)',
                icon: const Icon(Icons.splitscreen_outlined),
                onPressed: () => cubit.splitFocused(SplitAxis.row),
              ),
              IconButton(
                tooltip: 'Split horizontal (⌘⇧D)',
                icon: const Icon(Icons.horizontal_split_outlined),
                onPressed: () => cubit.splitFocused(SplitAxis.column),
              ),
              IconButton(
                tooltip: 'Close focused (⌘W)',
                icon: const Icon(Icons.close_fullscreen_outlined),
                onPressed: () => cubit.closeFocused(),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(8),
            child: BlocBuilder<PaneTreeCubit, PaneTreeState>(
              builder: (context, state) {
                return PaneTreeView(
                  root: state.root,
                  focusedId: state.focusedId,
                  onFocus: cubit.focus,
                  onResize: cubit.resizeSplit,
                  leafBuilder: (context, leaf, isFocused) =>
                      _PanePlaceholder(leaf: leaf, isFocused: isFocused),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Stand-in for a real session screen: shows the pane id / assigned session and
/// lets you assign or clear a demo session to feel the layout interactions.
class _PanePlaceholder extends StatelessWidget {
  final LeafPane leaf;
  final bool isFocused;

  const _PanePlaceholder({required this.leaf, required this.isFocused});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cubit = context.read<PaneTreeCubit>();
    return Container(
      margin: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isFocused ? scheme.primary : scheme.outlineVariant,
          width: isFocused ? 2 : 1,
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              leaf.id,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              leaf.session?.sessionId ?? '(empty)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () => cubit.setSession(
                    leaf.id,
                    SessionRef(connectionId: 'demo', sessionId: leaf.id),
                  ),
                  child: const Text('Assign'),
                ),
                if (leaf.session != null)
                  TextButton(
                    onPressed: () => cubit.setSession(leaf.id, null),
                    child: const Text('Clear'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
