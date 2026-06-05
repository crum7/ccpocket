import 'package:flutter/foundation.dart';

import '../../../models/session_ref.dart';

/// Direction of a split (kept independent of Flutter's `Axis` so the model
/// stays pure and unit-testable).
///
/// - [row]: children sit side by side (a vertical divider between them).
/// - [column]: children stack top to bottom (a horizontal divider).
enum SplitAxis { row, column }

/// A node in the recursive split-pane tree (design §3.3).
///
/// A [LeafPane] is one visible pane (hosting at most one session); a
/// [SplitPane] divides space among children. Trees are immutable — the
/// `PaneTreeCubit` produces a new tree for every edit.
@immutable
sealed class PaneNode {
  String get id;

  const PaneNode();

  /// All leaf panes under this node, left-to-right / top-to-bottom.
  List<LeafPane> get leaves;
}

/// A single pane. [session] is null when the pane is empty (shows a picker).
@immutable
class LeafPane extends PaneNode {
  @override
  final String id;
  final SessionRef? session;

  const LeafPane({required this.id, this.session});

  @override
  List<LeafPane> get leaves => [this];

  LeafPane withSession(SessionRef? session) =>
      LeafPane(id: id, session: session);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LeafPane && other.id == id && other.session == session;

  @override
  int get hashCode => Object.hash(id, session);

  @override
  String toString() => 'LeafPane($id, $session)';
}

/// A split holding two or more children with proportional [weights].
///
/// [weights] has the same length as [children] and sums to 1.0.
@immutable
class SplitPane extends PaneNode {
  @override
  final String id;
  final SplitAxis axis;
  final List<PaneNode> children;
  final List<double> weights;

  const SplitPane({
    required this.id,
    required this.axis,
    required this.children,
    required this.weights,
  }) : assert(children.length == weights.length),
       assert(children.length >= 2);

  @override
  List<LeafPane> get leaves => [for (final c in children) ...c.leaves];

  SplitPane copyWith({List<PaneNode>? children, List<double>? weights}) =>
      SplitPane(
        id: id,
        axis: axis,
        children: children ?? this.children,
        weights: weights ?? this.weights,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SplitPane &&
          other.id == id &&
          other.axis == axis &&
          listEquals(other.children, children) &&
          listEquals(other.weights, weights);

  @override
  int get hashCode =>
      Object.hash(id, axis, Object.hashAll(children), Object.hashAll(weights));

  @override
  String toString() => 'SplitPane($id, $axis, $children)';
}

/// Normalize [weights] so they sum to 1.0 (falls back to equal weights when
/// the input is degenerate).
List<double> normalizeWeights(List<double> weights) {
  final total = weights.fold<double>(0, (a, b) => a + (b > 0 ? b : 0));
  if (total <= 0) {
    final equal = 1.0 / weights.length;
    return List.filled(weights.length, equal);
  }
  return [for (final w in weights) (w > 0 ? w : 0) / total];
}
