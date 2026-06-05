import 'package:flutter/material.dart';

import '../state/pane_node.dart';

/// Builds the content of a single pane. [isFocused] lets callers highlight the
/// active pane.
typedef PaneLeafBuilder =
    Widget Function(BuildContext context, LeafPane leaf, bool isFocused);

/// Renders a [PaneNode] tree as nested [Row]/[Column]s with draggable dividers
/// (design §3.3). Pure presentation: all edits go back through callbacks.
class PaneTreeView extends StatelessWidget {
  final PaneNode root;
  final String focusedId;
  final PaneLeafBuilder leafBuilder;
  final ValueChanged<String> onFocus;
  final void Function(String splitId, List<double> weights) onResize;
  final double dividerThickness;

  const PaneTreeView({
    super.key,
    required this.root,
    required this.focusedId,
    required this.leafBuilder,
    required this.onFocus,
    required this.onResize,
    this.dividerThickness = 6,
  });

  @override
  Widget build(BuildContext context) => _build(context, root);

  Widget _build(BuildContext context, PaneNode node) {
    if (node is LeafPane) {
      final focused = node.id == focusedId;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onFocus(node.id),
        child: leafBuilder(context, node, focused),
      );
    }
    final split = node as SplitPane;
    final isRow = split.axis == SplitAxis.row;
    return LayoutBuilder(
      builder: (context, constraints) {
        final n = split.children.length;
        final totalDivider = dividerThickness * (n - 1);
        final extent =
            (isRow ? constraints.maxWidth : constraints.maxHeight) -
            totalDivider;
        final weights = normalizeWeights(split.weights);
        final children = <Widget>[];
        for (var i = 0; i < n; i++) {
          final size = (weights[i] * extent).clamp(0.0, double.infinity);
          children.add(
            SizedBox(
              width: isRow ? size : null,
              height: isRow ? null : size,
              child: _build(context, split.children[i]),
            ),
          );
          if (i < n - 1) {
            children.add(
              _PaneDivider(
                axis: split.axis,
                thickness: dividerThickness,
                onDrag: (delta) => _applyDrag(split, weights, i, delta, extent),
              ),
            );
          }
        }
        return isRow
            ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              );
      },
    );
  }

  void _applyDrag(
    SplitPane split,
    List<double> weights,
    int dividerIndex,
    double deltaPx,
    double extent,
  ) {
    if (extent <= 0) return;
    final deltaW = deltaPx / extent;
    const minW = 0.05;
    final a = weights[dividerIndex] + deltaW;
    final b = weights[dividerIndex + 1] - deltaW;
    if (a < minW || b < minW) return;
    final next = [...weights];
    next[dividerIndex] = a;
    next[dividerIndex + 1] = b;
    onResize(split.id, next);
  }
}

class _PaneDivider extends StatelessWidget {
  final SplitAxis axis;
  final double thickness;
  final ValueChanged<double> onDrag;

  const _PaneDivider({
    required this.axis,
    required this.thickness,
    required this.onDrag,
  });

  @override
  Widget build(BuildContext context) {
    final isRow = axis == SplitAxis.row;
    final color = Theme.of(context).colorScheme.outlineVariant;
    return MouseRegion(
      cursor: isRow
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: isRow ? (d) => onDrag(d.delta.dx) : null,
        onVerticalDragUpdate: isRow ? null : (d) => onDrag(d.delta.dy),
        child: Container(
          width: isRow ? thickness : null,
          height: isRow ? null : thickness,
          color: color,
          alignment: Alignment.center,
          child: Container(
            width: isRow ? 2 : 24,
            height: isRow ? 24 : 2,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ),
      ),
    );
  }
}
