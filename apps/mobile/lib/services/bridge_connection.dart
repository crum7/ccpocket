import 'bridge_service.dart';

/// One live connection to a single bridge server.
///
/// Wraps a dedicated [BridgeService] (its own WebSocket) together with a stable
/// [id] and a display [label]. Multiple [BridgeConnection]s can be alive at the
/// same time, owned by `ConnectionManager`. Because each has its own socket,
/// session events never cross-mix between connections.
///
/// Per-connection derived cubits (FileList / Gallery / ActiveSessions …) are
/// introduced when the split-pane UI scopes them per pane (design §3.1, Phase 3).
/// For now a connection is just (id, label, bridge).
class BridgeConnection {
  /// Stable connection id. For machine-backed connections this is the machine's
  /// `uniqueKey` (host:port); the app's initial connection uses [primaryId].
  final String id;

  /// Human-readable label for pickers/headers (machine display name or URL).
  final String label;

  /// This connection's dedicated bridge client.
  final BridgeService bridge;

  BridgeConnection({
    required this.id,
    required this.label,
    required this.bridge,
  });

  /// The id used for the app's initial/primary connection (the existing global
  /// [BridgeService]) before any explicit machine is chosen.
  static const String primaryId = 'primary';
}
