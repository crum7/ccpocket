import 'package:flutter_test/flutter_test.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/services/bridge_connection.dart';
import 'package:ccpocket/services/connection_manager.dart';

/// Lightweight fake that records calls without opening a real WebSocket.
class _FakeBridge extends BridgeService {
  int connectCalls = 0;
  String? lastConnectedUrl;
  bool disconnected = false;
  bool wasDisposed = false;

  @override
  void connect(String url) {
    connectCalls++;
    lastConnectedUrl = url;
  }

  @override
  void disconnect() {
    disconnected = true;
  }

  @override
  void dispose() {
    wasDisposed = true;
    super.dispose();
  }
}

void main() {
  group('ConnectionManager', () {
    test('withPrimary seeds an active primary connection', () {
      final primary = _FakeBridge();
      final m = ConnectionManager.withPrimary(
        primary,
        bridgeFactory: _FakeBridge.new,
      );

      expect(m.all.length, 1);
      expect(m.activeId, BridgeConnection.primaryId);
      expect(m.active!.bridge, same(primary));

      m.dispose();
    });

    test('connectUrl adds, connects, and activates a new connection', () {
      final m = ConnectionManager.withPrimary(
        _FakeBridge(),
        bridgeFactory: _FakeBridge.new,
      );

      final conn = m.connectUrl(id: 'm1', url: 'ws://host:1', label: 'M1');

      expect(m.all.length, 2);
      expect(m.activeId, 'm1');
      expect((conn.bridge as _FakeBridge).connectCalls, 1);
      expect((conn.bridge as _FakeBridge).lastConnectedUrl, 'ws://host:1');

      m.dispose();
    });

    test('connectUrl reuses an existing connection with the same id', () {
      final m = ConnectionManager.withPrimary(
        _FakeBridge(),
        bridgeFactory: _FakeBridge.new,
      );

      final a = m.connectUrl(id: 'm1', url: 'ws://host:1', label: 'M1');
      final b = m.connectUrl(id: 'm1', url: 'ws://host:2', label: 'M1');

      expect(identical(a, b), isTrue);
      expect(m.all.length, 2);
      expect((a.bridge as _FakeBridge).connectCalls, 2);

      m.dispose();
    });

    test('connectUrl with makeActive:false keeps the current active', () {
      final m = ConnectionManager.withPrimary(
        _FakeBridge(),
        bridgeFactory: _FakeBridge.new,
      );

      m.connectUrl(
        id: 'm1',
        url: 'ws://host:1',
        label: 'M1',
        makeActive: false,
      );

      expect(m.activeId, BridgeConnection.primaryId);
      m.dispose();
    });

    test('setActive switches the active connection', () {
      final m = ConnectionManager.withPrimary(
        _FakeBridge(),
        bridgeFactory: _FakeBridge.new,
      );
      m.connectUrl(id: 'm1', url: 'ws://host:1', label: 'M1');

      m.setActive(BridgeConnection.primaryId);

      expect(m.activeId, BridgeConnection.primaryId);
      m.dispose();
    });

    test('disconnect removes, disposes, and reassigns active', () {
      final m = ConnectionManager.withPrimary(
        _FakeBridge(),
        bridgeFactory: _FakeBridge.new,
      );
      final conn = m.connectUrl(id: 'm1', url: 'ws://host:1', label: 'M1');
      expect(m.activeId, 'm1');

      m.disconnect('m1');

      expect(m.has('m1'), isFalse);
      expect((conn.bridge as _FakeBridge).disconnected, isTrue);
      expect((conn.bridge as _FakeBridge).wasDisposed, isTrue);
      expect(m.activeId, BridgeConnection.primaryId);

      m.dispose();
    });

    test('per-connection cubits are lazy, cached, and disposed', () async {
      final conn = BridgeConnection(
        id: 'm1',
        label: 'M1',
        bridge: _FakeBridge(),
      );
      final sessions = conn.activeSessionsCubit;
      expect(sessions.state, isEmpty);
      // Same instance on second access (cached, not recreated).
      expect(identical(conn.activeSessionsCubit, sessions), isTrue);

      await conn.disposeCubits();
      expect(sessions.isClosed, isTrue);
    });

    test('disconnect disposes the connection cubits', () async {
      final m = ConnectionManager.withPrimary(
        _FakeBridge(),
        bridgeFactory: _FakeBridge.new,
      );
      final conn = m.connectUrl(id: 'm1', url: 'ws://h:1', label: 'M1');
      final sessions = conn.activeSessionsCubit; // force creation

      m.disconnect('m1');
      await Future<void>.delayed(Duration.zero); // let disposeCubits run

      expect(sessions.isClosed, isTrue);
    });

    test('connections stream emits the list on add and remove', () async {
      final m = ConnectionManager.withPrimary(
        _FakeBridge(),
        bridgeFactory: _FakeBridge.new,
      );
      final lengths = <int>[];
      final sub = m.connections.listen((list) => lengths.add(list.length));

      m.connectUrl(id: 'm1', url: 'ws://h:1', label: 'M1');
      m.disconnect('m1');
      await Future<void>.delayed(Duration.zero);

      expect(lengths, containsAllInOrder([2, 1]));

      await sub.cancel();
      m.dispose();
    });
  });
}
