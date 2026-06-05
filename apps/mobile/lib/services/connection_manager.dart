import 'dart:async';

import 'bridge_connection.dart';
import 'bridge_service.dart';
import '../models/machine.dart';

/// Owns the pool of live bridge connections (design §3.1).
///
/// Phase 2 foundation: the app still drives a single "active" connection that
/// the rest of the UI reads as the global [BridgeService] (unchanged behavior),
/// but the manager can hold additional connections alive at the same time. The
/// split-pane UI (Phase 3) will scope each pane to a connection via [byId].
///
/// Connections are kept alive once established (each [BridgeService] auto-
/// reconnects); a connection is only torn down on an explicit [disconnect]
/// (decision §6.1).
class ConnectionManager {
  /// Creates new bridge clients. Injectable so tests can supply fakes.
  final BridgeService Function() _bridgeFactory;

  final Map<String, BridgeConnection> _connections = {};
  String? _activeId;

  final StreamController<List<BridgeConnection>> _controller =
      StreamController<List<BridgeConnection>>.broadcast();

  ConnectionManager({BridgeService Function()? bridgeFactory})
    : _bridgeFactory = bridgeFactory ?? BridgeService.new;

  /// Seed the manager with the app's existing (primary) bridge so current
  /// behavior is preserved. The primary becomes the active connection.
  ConnectionManager.withPrimary(
    BridgeService primary, {
    String label = 'Primary',
    BridgeService Function()? bridgeFactory,
  }) : _bridgeFactory = bridgeFactory ?? BridgeService.new {
    final conn = BridgeConnection(
      id: BridgeConnection.primaryId,
      label: label,
      bridge: primary,
    );
    _connections[conn.id] = conn;
    _activeId = conn.id;
  }

  /// Broadcast of the current connection list (emits on add/remove/active swap).
  Stream<List<BridgeConnection>> get connections => _controller.stream;

  /// All live connections (insertion order).
  List<BridgeConnection> get all => List.unmodifiable(_connections.values);

  /// The currently active connection (what the single-pane UI reads), or null.
  BridgeConnection? get active =>
      _activeId == null ? null : _connections[_activeId];

  String? get activeId => _activeId;

  BridgeConnection? byId(String id) => _connections[id];

  bool has(String id) => _connections.containsKey(id);

  /// Connect to [machine], reusing an existing connection with the same id.
  /// The returned connection's bridge is (re)connected to the machine's URL.
  BridgeConnection connectMachine(Machine machine, {bool makeActive = true}) {
    return connectUrl(
      id: machine.uniqueKey,
      url: machine.wsUrl,
      label: machine.displayName,
      makeActive: makeActive,
    );
  }

  /// Connect to [url] under a stable [id]. Reuses the existing connection if
  /// present (calling [BridgeService.connect] again to (re)point it).
  BridgeConnection connectUrl({
    required String id,
    required String url,
    required String label,
    bool makeActive = true,
  }) {
    var conn = _connections[id];
    if (conn == null) {
      conn = BridgeConnection(id: id, label: label, bridge: _bridgeFactory());
      _connections[id] = conn;
    }
    conn.bridge.connect(url);
    if (makeActive) {
      _activeId = id;
    }
    _emit();
    return conn;
  }

  /// Make an already-present connection the active one. No-op if unknown.
  void setActive(String id) {
    if (!_connections.containsKey(id) || _activeId == id) return;
    _activeId = id;
    _emit();
  }

  /// Tear down and remove a connection. If it was active, the active pointer
  /// falls back to any remaining connection (or null).
  void disconnect(String id) {
    final conn = _connections.remove(id);
    if (conn == null) return;
    conn.bridge.disconnect();
    conn.bridge.dispose();
    if (_activeId == id) {
      _activeId = _connections.keys.isNotEmpty ? _connections.keys.first : null;
    }
    _emit();
  }

  void _emit() {
    if (!_controller.isClosed) _controller.add(all);
  }

  void dispose() {
    for (final conn in _connections.values) {
      conn.bridge.dispose();
    }
    _connections.clear();
    _activeId = null;
    _controller.close();
  }
}
