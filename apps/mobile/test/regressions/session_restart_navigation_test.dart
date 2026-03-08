import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol_finders/patrol_finders.dart';

import '../chat_screen/helpers/chat_test_helpers.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Phase 2: SessionListScreen filtering logic
  // ---------------------------------------------------------------------------

  group('SessionListScreen session_created filtering', () {
    /// The SessionListScreen listener should skip session_created messages
    /// that have sourceSessionId set (restart/rebuild messages handled by
    /// the active session screen).
    test('session_created with sourceSessionId should be skipped', () {
      const msg = SystemMessage(
        subtype: 'session_created',
        sessionId: 'new-session-id',
        provider: 'codex',
        projectPath: '/tmp/project',
        sourceSessionId: 'old-session-id',
      );

      // This is the condition in SessionListScreen:
      // if (msg.clearContext || msg.sourceSessionId != null) return;
      final shouldSkipNavigation =
          msg.clearContext || msg.sourceSessionId != null;
      expect(
        shouldSkipNavigation,
        isTrue,
        reason:
            'session_created with sourceSessionId should be skipped by SessionListScreen',
      );
    });

    test('session_created with clearContext should be skipped', () {
      const msg = SystemMessage(
        subtype: 'session_created',
        sessionId: 'new-session-id',
        provider: 'claude',
        projectPath: '/tmp/project',
        clearContext: true,
        sourceSessionId: 'old-session-id',
      );

      final shouldSkipNavigation =
          msg.clearContext || msg.sourceSessionId != null;
      expect(shouldSkipNavigation, isTrue);
    });

    test(
      'session_created without sourceSessionId or clearContext should navigate',
      () {
        const msg = SystemMessage(
          subtype: 'session_created',
          sessionId: 'new-session-id',
          provider: 'claude',
          projectPath: '/tmp/project',
        );

        final shouldSkipNavigation =
            msg.clearContext || msg.sourceSessionId != null;
        expect(
          shouldSkipNavigation,
          isFalse,
          reason:
              'Normal session_created should trigger navigation from SessionListScreen',
        );
      },
    );

    test('rewind session_created with sourceSessionId should be skipped', () {
      // Simulates the rewind case after bridge fix
      const msg = SystemMessage(
        subtype: 'session_created',
        sessionId: 'rewind-new-session',
        provider: 'claude',
        projectPath: '/tmp/project',
        sourceSessionId: 'original-session',
      );

      final shouldSkipNavigation =
          msg.clearContext || msg.sourceSessionId != null;
      expect(
        shouldSkipNavigation,
        isTrue,
        reason: 'Rewind session_created with sourceSessionId should be skipped',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Phase 3: ClaudeSessionScreen rewind session switch
  // ---------------------------------------------------------------------------

  group('ClaudeSessionScreen rewind session switch', () {
    late MockBridgeService bridge;

    setUp(() {
      bridge = MockBridgeService();
    });

    tearDown(() {
      bridge.dispose();
    });

    patrolWidgetTest(
      'switches to new session when rewind session_created arrives with sourceSessionId',
      ($) async {
        const originalSessionId = 'original-session';
        const newSessionId = 'rewind-new-session';

        await $.pumpWidget(
          await buildTestClaudeSessionScreen(
            bridge: bridge,
            sessionId: originalSessionId,
            projectPath: '/tmp/project',
          ),
        );
        await pumpN($.tester);

        // The cubit requests history on creation
        expect(bridge.lastRequestedSessionId, equals(originalSessionId));
        bridge.requestSessionHistoryCallCount = 0;

        // Now simulate a rewind session_created with sourceSessionId
        bridge.emitMessage(
          const SystemMessage(
            subtype: 'session_created',
            sessionId: newSessionId,
            provider: 'claude',
            projectPath: '/tmp/project',
            sourceSessionId: originalSessionId,
          ),
        );
        await pumpN($.tester, count: 10);

        // After the switch, a new cubit is created (via ValueKey rebuild)
        // which requests history for the new session
        expect(
          bridge.lastRequestedSessionId,
          equals(newSessionId),
          reason:
              'Should have requested history for the new session after rewind',
        );
      },
    );

    patrolWidgetTest(
      'does not switch when sourceSessionId does not match current session',
      ($) async {
        const mySessionId = 'my-session';

        await $.pumpWidget(
          await buildTestClaudeSessionScreen(
            bridge: bridge,
            sessionId: mySessionId,
            projectPath: '/tmp/project',
          ),
        );
        await pumpN($.tester);

        expect(bridge.lastRequestedSessionId, equals(mySessionId));
        bridge.requestSessionHistoryCallCount = 0;

        // Emit a session_created from a DIFFERENT source session
        bridge.emitMessage(
          const SystemMessage(
            subtype: 'session_created',
            sessionId: 'someone-elses-new-session',
            provider: 'claude',
            projectPath: '/tmp/project',
            sourceSessionId: 'someone-elses-old-session',
          ),
        );
        await pumpN($.tester, count: 10);

        // Should NOT have switched — no new history request
        expect(
          bridge.requestSessionHistoryCallCount,
          equals(0),
          reason: 'Should not switch to a session from a different source',
        );
      },
    );
  });
}
