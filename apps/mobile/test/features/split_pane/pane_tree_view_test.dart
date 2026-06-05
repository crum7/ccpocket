import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccpocket/features/split_pane/state/pane_node.dart';
import 'package:ccpocket/features/split_pane/widgets/pane_tree_view.dart';

Widget _host(PaneNode root, {required String focusedId, ValueChanged<String>? onFocus}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 400,
        height: 300,
        child: PaneTreeView(
          root: root,
          focusedId: focusedId,
          onFocus: onFocus ?? (_) {},
          onResize: (_, _) {},
          leafBuilder: (context, leaf, isFocused) =>
              Text('${leaf.id}${isFocused ? '*' : ''}'),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders a single leaf', (tester) async {
    await tester.pumpWidget(_host(const LeafPane(id: 'solo'), focusedId: 'solo'));
    expect(find.text('solo*'), findsOneWidget);
  });

  testWidgets('renders all leaves of a split and marks the focused one', (
    tester,
  ) async {
    final root = SplitPane(
      id: 's',
      axis: SplitAxis.row,
      children: const [LeafPane(id: 'a'), LeafPane(id: 'b')],
      weights: const [0.5, 0.5],
    );
    await tester.pumpWidget(_host(root, focusedId: 'a'));
    expect(find.text('a*'), findsOneWidget);
    expect(find.text('b'), findsOneWidget);
  });

  testWidgets('tapping a pane reports its id to onFocus', (tester) async {
    String? focused;
    final root = SplitPane(
      id: 's',
      axis: SplitAxis.row,
      children: const [LeafPane(id: 'a'), LeafPane(id: 'b')],
      weights: const [0.5, 0.5],
    );
    await tester.pumpWidget(
      _host(root, focusedId: 'a', onFocus: (id) => focused = id),
    );
    await tester.tap(find.text('b'));
    expect(focused, 'b');
  });

  testWidgets('renders nested splits (three leaves)', (tester) async {
    final root = SplitPane(
      id: 's0',
      axis: SplitAxis.row,
      children: [
        const LeafPane(id: 'a'),
        SplitPane(
          id: 's1',
          axis: SplitAxis.column,
          children: const [LeafPane(id: 'b'), LeafPane(id: 'c')],
          weights: const [0.5, 0.5],
        ),
      ],
      weights: const [0.5, 0.5],
    );
    await tester.pumpWidget(_host(root, focusedId: 'a'));
    expect(find.text('a*'), findsOneWidget);
    expect(find.text('b'), findsOneWidget);
    expect(find.text('c'), findsOneWidget);
  });
}
