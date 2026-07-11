import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ccpocket/models/session_ref.dart';
import 'package:ccpocket/features/split_pane/state/pane_node.dart';
import 'package:ccpocket/features/split_pane/state/pane_tree_cubit.dart';

SessionRef _ref(String s) => SessionRef(connectionId: 'c', sessionId: s);

void main() {
  group('PaneTreeCubit', () {
    test('starts as a single focused empty leaf', () {
      final c = PaneTreeCubit();
      expect(c.state.root, isA<LeafPane>());
      expect(c.state.root.leaves.length, 1);
      expect(c.state.focusedLeaf.session, isNull);
      expect(c.state.focusedId, c.state.root.id);
    });

    test('splitFocused wraps the pane and focuses the new empty one', () {
      final c = PaneTreeCubit(initialSession: _ref('s0'));
      final originalId = c.state.focusedId;

      c.splitFocused(SplitAxis.row);

      final root = c.state.root as SplitPane;
      expect(root.axis, SplitAxis.row);
      expect(root.children.length, 2);
      expect(root.weights, [0.5, 0.5]);
      // Original pane kept its session; new pane is empty and focused.
      final original = root.children[0] as LeafPane;
      final added = root.children[1] as LeafPane;
      expect(original.id, originalId);
      expect(original.session, _ref('s0'));
      expect(added.session, isNull);
      expect(c.state.focusedId, added.id);
    });

    test('nested split produces three leaves in order', () {
      final c = PaneTreeCubit();
      c.splitFocused(SplitAxis.row); // 2 leaves, focus on 2nd
      c.splitFocused(SplitAxis.column); // split the 2nd → 3 leaves

      final leaves = c.state.root.leaves;
      expect(leaves.length, 3);
      final root = c.state.root as SplitPane;
      expect(root.axis, SplitAxis.row);
      expect(root.children[0], isA<LeafPane>());
      expect(root.children[1], isA<SplitPane>());
      expect((root.children[1] as SplitPane).axis, SplitAxis.column);
    });

    test('consecutive same-axis splits keep all panes equal (1/n)', () {
      final c = PaneTreeCubit();
      c.splitFocused(SplitAxis.row); // 2
      c.splitFocused(SplitAxis.row); // 3
      c.splitFocused(SplitAxis.row); // 4

      final root = c.state.root as SplitPane;
      expect(root.children.length, 4);
      expect(root.children.every((n) => n is LeafPane), isTrue);
      for (final w in root.weights) {
        expect(w, closeTo(0.25, 1e-9));
      }
    });

    test('a perpendicular split nests instead of flattening', () {
      final c = PaneTreeCubit();
      c.splitFocused(SplitAxis.row); // row[A, B], focus B
      c.splitFocused(SplitAxis.column); // B → column[B, C]

      final root = c.state.root as SplitPane;
      expect(root.axis, SplitAxis.row);
      expect(root.children.length, 2);
      expect(root.children[1], isA<SplitPane>());
      expect((root.children[1] as SplitPane).axis, SplitAxis.column);
    });

    test('setSessionForFocused assigns to the focused pane only', () {
      final c = PaneTreeCubit();
      c.splitFocused(SplitAxis.row);
      final focused = c.state.focusedId;

      c.setSessionForFocused(_ref('hello'));

      final leaf = c.state.root.leaves.firstWhere((l) => l.id == focused);
      expect(leaf.session, _ref('hello'));
      // The other pane stays empty.
      expect(
        c.state.root.leaves.where((l) => l.session != null).length,
        1,
      );
    });

    test('focus moves to a valid pane and ignores unknown ids', () {
      final c = PaneTreeCubit();
      c.splitFocused(SplitAxis.row);
      final first = c.state.root.leaves.first.id;

      c.focus(first);
      expect(c.state.focusedId, first);

      c.focus('does-not-exist');
      expect(c.state.focusedId, first);
    });

    test('closeFocused collapses a 2-pane split back to a single leaf', () {
      final c = PaneTreeCubit(initialSession: _ref('keep'));
      c.splitFocused(SplitAxis.row); // focus on new empty pane
      final keptId = (c.state.root as SplitPane).children[0].id;

      c.closeFocused();

      expect(c.state.root, isA<LeafPane>());
      expect(c.state.root.id, keptId);
      expect((c.state.root as LeafPane).session, _ref('keep'));
      expect(c.state.focusedId, keptId);
    });

    test('closeFocused in a nested tree removes and collapses correctly', () {
      final c = PaneTreeCubit();
      c.splitFocused(SplitAxis.row); // leaves: [A, B], focus B
      c.splitFocused(SplitAxis.column); // B becomes split [B, C], focus C

      expect(c.state.root.leaves.length, 3);

      c.closeFocused(); // close C → inner split collapses to B

      final leaves = c.state.root.leaves;
      expect(leaves.length, 2);
      final root = c.state.root as SplitPane;
      expect(root.children.every((n) => n is LeafPane), isTrue);
      // Focus falls back to the neighbor (B).
      expect(leaves.map((l) => l.id), contains(c.state.focusedId));
    });

    test('last pane is never removed; its session is cleared instead', () {
      final c = PaneTreeCubit(initialSession: _ref('only'));
      expect(c.state.root.leaves.length, 1);

      c.closeFocused();

      expect(c.state.root.leaves.length, 1);
      expect((c.state.root as LeafPane).session, isNull);
    });

    test('resizeSplit normalizes weights', () {
      final c = PaneTreeCubit();
      c.splitFocused(SplitAxis.row);
      final splitId = c.state.root.id;

      c.resizeSplit(splitId, [3, 1]);

      final root = c.state.root as SplitPane;
      expect(root.weights[0], closeTo(0.75, 1e-9));
      expect(root.weights[1], closeTo(0.25, 1e-9));
    });

    test('resizeSplit ignores wrong arity or non-splits', () {
      final c = PaneTreeCubit();
      c.splitFocused(SplitAxis.row);
      final splitId = c.state.root.id;
      final before = c.state.root;

      c.resizeSplit(splitId, [1, 1, 1]); // wrong length
      c.resizeSplit('pane_0', [0.5, 0.5]); // not a split
      expect(c.state.root, before);
    });

    test('a split tree survives a JSON round-trip', () {
      final c = PaneTreeCubit();
      c.splitFocused(SplitAxis.row);
      c.splitFocused(SplitAxis.column);
      c.setSessionForFocused(_ref('deep'));

      final json = jsonDecode(jsonEncode(c.state.root.toJson()))
          as Map<String, dynamic>;
      final restored = PaneNode.fromJson(json);

      expect(restored, c.state.root); // deep == on the node tree
    });

    test('restored cubit continues the id sequence without collisions', () {
      final c = PaneTreeCubit();
      c.splitFocused(SplitAxis.row); // pane_0, pane_1, split pane_2

      final restored = PaneTreeCubit.restored(
        root: c.state.root,
        focusedId: c.state.focusedId,
      );
      restored.splitFocused(SplitAxis.row);
      restored.splitFocused(SplitAxis.column);

      final ids = restored.state.root.leaves.map((l) => l.id).toList();
      expect(ids.toSet().length, ids.length); // all unique
    });

    test('normalizeWeights falls back to equal on degenerate input', () {
      expect(normalizeWeights([0, 0]), [0.5, 0.5]);
      expect(normalizeWeights([-1, -1, -1]), [
        closeTo(1 / 3, 1e-9),
        closeTo(1 / 3, 1e-9),
        closeTo(1 / 3, 1e-9),
      ]);
    });
  });
}
