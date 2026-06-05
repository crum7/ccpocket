import 'package:flutter/foundation.dart';

/// Identifies a session across multiple simultaneously-connected bridges.
///
/// Historically a session was identified by [sessionId] alone, which is fine
/// while the app talks to a single bridge. With multiple connections (one per
/// machine) the same `sessionId` could exist on different bridges, so a session
/// must be qualified by the connection it belongs to.
///
/// See `docs/multi-bridge-split-panes-design.md` (§3.2).
@immutable
class SessionRef {
  /// The owning connection's id (see `ConnectionManager`). Stable per machine.
  final String connectionId;

  /// The bridge-side session id, unique within [connectionId].
  final String sessionId;

  const SessionRef({required this.connectionId, required this.sessionId});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionRef &&
          other.connectionId == connectionId &&
          other.sessionId == sessionId;

  @override
  int get hashCode => Object.hash(connectionId, sessionId);

  @override
  String toString() => 'SessionRef($connectionId/$sessionId)';
}
