import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../models/session_ref.dart';
import 'pane_node.dart';

/// State of one workspace layout: the split tree plus the focused pane
/// (design §3.3). One of these per macOS tab (decision §6.2).
@immutable
class PaneTreeState {
  final PaneNode root;
  final String focusedId;

  const PaneTreeState({required this.root, required this.focusedId});

  /// The currently focused leaf (always present — [focusedId] is kept valid).
  LeafPane get focusedLeaf =>
      root.leaves.firstWhere((l) => l.id == focusedId, orElse: () {
        final first = root.leaves.first;
        return first;
      });

  PaneTreeState copyWith({PaneNode? root, String? focusedId}) => PaneTreeState(
    root: root ?? this.root,
    focusedId: focusedId ?? this.focusedId,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PaneTreeState &&
          other.root == root &&
          other.focusedId == focusedId;

  @override
  int get hashCode => Object.hash(root, focusedId);
}

/// Manages a recursive split-pane layout: split/close/focus/resize and
/// assigning a [SessionRef] to a pane. Pure tree transforms — no widgets.
class PaneTreeCubit extends Cubit<PaneTreeState> {
  int _seq;

  PaneTreeCubit({SessionRef? initialSession})
    : _seq = 1,
      super(
        PaneTreeState(
          root: LeafPane(id: 'pane_0', session: initialSession),
          focusedId: 'pane_0',
        ),
      );

  String _nextId() => 'pane_${_seq++}';

  /// Split the focused pane along [axis], creating a new empty pane that
  /// becomes focused. The existing pane keeps its session.
  ///
  /// When the focused pane already sits in a split of the same [axis], the new
  /// pane is inserted as a sibling and all of them are rebalanced to equal
  /// sizes (so 3 panes become 1/3 each, 4 become 1/4, …). Only a split in a
  /// different direction nests.
  void splitFocused(SplitAxis axis) {
    final target = state.focusedId;
    final existing = _findLeaf(state.root, target);
    if (existing == null) return;

    final newLeaf = LeafPane(id: _nextId());
    final parent = _findParentSplit(state.root, target);

    if (parent != null && parent.axis == axis) {
      // Same direction → add a sibling and split the space evenly.
      final index = parent.children.indexWhere((c) => c.id == target);
      final children = [...parent.children]..insert(index + 1, newLeaf);
      final equal = List.filled(children.length, 1.0 / children.length);
      emit(
        PaneTreeState(
          root: _replace(
            state.root,
            parent.id,
            parent.copyWith(children: children, weights: equal),
          ),
          focusedId: newLeaf.id,
        ),
      );
      return;
    }

    // Root leaf, or a perpendicular split → wrap into a new even 2-way split.
    final split = SplitPane(
      id: _nextId(),
      axis: axis,
      children: [existing, newLeaf],
      weights: const [0.5, 0.5],
    );
    emit(
      PaneTreeState(
        root: _replace(state.root, target, split),
        focusedId: newLeaf.id,
      ),
    );
  }

  /// Close the focused pane. Collapses a split that drops to one child. The
  /// last remaining pane is never removed — its session is cleared instead.
  void closeFocused() {
    final leaves = state.root.leaves;
    if (leaves.length <= 1) {
      // Nothing to close; just empty the sole pane.
      final only = leaves.first;
      if (only.session == null) return;
      emit(state.copyWith(root: _replace(state.root, only.id, only.withSession(null))));
      return;
    }

    final removedIndex = leaves.indexWhere((l) => l.id == state.focusedId);
    final newRoot = _removeLeaf(state.root, state.focusedId);
    if (newRoot == null) return; // focused leaf not found

    final newLeaves = newRoot.leaves;
    final focusIdx = removedIndex < 0
        ? 0
        : math.min(removedIndex, newLeaves.length - 1);
    emit(PaneTreeState(root: newRoot, focusedId: newLeaves[focusIdx].id));
  }

  /// Assign (or clear) the session shown in the focused pane.
  void setSessionForFocused(SessionRef? session) =>
      setSession(state.focusedId, session);

  /// Assign (or clear) the session shown in pane [paneId].
  void setSession(String paneId, SessionRef? session) {
    final leaf = _findLeaf(state.root, paneId);
    if (leaf == null) return;
    emit(state.copyWith(root: _replace(state.root, paneId, leaf.withSession(session))));
  }

  /// Move focus to pane [paneId] (no-op if it isn't a leaf).
  void focus(String paneId) {
    if (paneId == state.focusedId) return;
    if (_findLeaf(state.root, paneId) == null) return;
    emit(state.copyWith(focusedId: paneId));
  }

  /// Update the proportional [weights] of the split [splitId] (normalized).
  void resizeSplit(String splitId, List<double> weights) {
    final node = _findNode(state.root, splitId);
    if (node is! SplitPane || node.children.length != weights.length) return;
    emit(
      state.copyWith(
        root: _replace(
          state.root,
          splitId,
          node.copyWith(weights: normalizeWeights(weights)),
        ),
      ),
    );
  }

  // --- pure tree helpers -----------------------------------------------------

  static LeafPane? _findLeaf(PaneNode node, String id) {
    final found = _findNode(node, id);
    return found is LeafPane ? found : null;
  }

  static PaneNode? _findNode(PaneNode node, String id) {
    if (node.id == id) return node;
    if (node is SplitPane) {
      for (final c in node.children) {
        final r = _findNode(c, id);
        if (r != null) return r;
      }
    }
    return null;
  }

  /// The split that directly contains [childId], or null if [childId] is the
  /// root (has no parent).
  static SplitPane? _findParentSplit(PaneNode node, String childId) {
    if (node is SplitPane) {
      for (final c in node.children) {
        if (c.id == childId) return node;
        final found = _findParentSplit(c, childId);
        if (found != null) return found;
      }
    }
    return null;
  }

  static PaneNode _replace(PaneNode node, String targetId, PaneNode replacement) {
    if (node.id == targetId) return replacement;
    if (node is SplitPane) {
      return node.copyWith(
        children: [for (final c in node.children) _replace(c, targetId, replacement)],
      );
    }
    return node;
  }

  /// Remove the leaf [leafId]; collapse any split left with a single child.
  /// Returns null only if the whole tree would become empty.
  static PaneNode? _removeLeaf(PaneNode node, String leafId) {
    if (node is LeafPane) return node.id == leafId ? null : node;
    final split = node as SplitPane;
    final children = <PaneNode>[];
    final weights = <double>[];
    for (var i = 0; i < split.children.length; i++) {
      final replaced = _removeLeaf(split.children[i], leafId);
      if (replaced == null) continue;
      children.add(replaced);
      weights.add(split.weights[i]);
    }
    if (children.isEmpty) return null;
    if (children.length == 1) return children.first; // collapse
    return split.copyWith(children: children, weights: normalizeWeights(weights));
  }
}
