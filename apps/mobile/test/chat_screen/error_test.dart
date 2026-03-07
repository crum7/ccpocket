import 'package:ccpocket/features/chat_session/widgets/chat_input_with_overlays.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol_finders/patrol_finders.dart';

import 'helpers/chat_test_helpers.dart';

void main() {
  late MockBridgeService bridge;

  setUp(() {
    bridge = MockBridgeService();
  });

  tearDown(() {
    bridge.dispose();
  });

  group('Error display', () {
    patrolWidgetTest('I1: ErrorMessage displays in chat', ($) async {
      await $.pumpWidget(await buildTestChatScreen(bridge: bridge));
      await pumpN($.tester);

      await emitAndPump($.tester, bridge, [
        const StatusMessage(status: ProcessStatus.running),
        const ErrorMessage(message: 'Something went wrong'),
      ]);
      await pumpN($.tester);

      expect($('Something went wrong'), findsOneWidget);
    });

    patrolWidgetTest('I2: After error, idle restores input', ($) async {
      await $.pumpWidget(await buildTestChatScreen(bridge: bridge));
      await pumpN($.tester);

      await emitAndPump($.tester, bridge, [
        const StatusMessage(status: ProcessStatus.running),
        const ErrorMessage(message: 'An error occurred'),
        const StatusMessage(status: ProcessStatus.idle),
      ]);
      await pumpN($.tester);

      expect($(ChatInputWithOverlays), findsOneWidget);
    });
  });

  group('Structured error display with errorCode', () {
    patrolWidgetTest('I3: auth error shows title and hint', ($) async {
      await $.pumpWidget(await buildTestChatScreen(bridge: bridge));
      await pumpN($.tester);

      await emitAndPump($.tester, bridge, [
        const StatusMessage(status: ProcessStatus.running),
        const ErrorMessage(
          message:
              '⚠ Claude Code authentication required\n\nClaude is not logged in.',
          errorCode: 'auth_login_required',
        ),
      ]);
      await pumpN($.tester);

      // Title should be shown
      expect($('Authentication Error'), findsOneWidget);
      // Hint text should mention claude auth login
      expect(
        $('Run "claude auth login" on the Bridge machine'),
        findsOneWidget,
      );
    });

    patrolWidgetTest('I4: token expired error shows expired hint', ($) async {
      await $.pumpWidget(await buildTestChatScreen(bridge: bridge));
      await pumpN($.tester);

      await emitAndPump($.tester, bridge, [
        const StatusMessage(status: ProcessStatus.running),
        const ErrorMessage(
          message:
              '⚠ Claude Code session expired\n\nYour login session has expired.',
          errorCode: 'auth_token_expired',
        ),
      ]);
      await pumpN($.tester);

      expect($('Authentication Error'), findsOneWidget);
      expect(
        $('Run "claude auth login" on the Bridge machine'),
        findsOneWidget,
      );
    });

    patrolWidgetTest('I5: path_not_allowed error shows path hint', ($) async {
      await $.pumpWidget(await buildTestChatScreen(bridge: bridge));
      await pumpN($.tester);

      await emitAndPump($.tester, bridge, [
        const StatusMessage(status: ProcessStatus.running),
        const ErrorMessage(
          message:
              '⚠ Project path not allowed\n\n"/foo/bar" is not in the allowed directories.',
          errorCode: 'path_not_allowed',
        ),
      ]);
      await pumpN($.tester);

      expect($('Path Not Allowed'), findsOneWidget);
      expect(
        $('Update BRIDGE_ALLOWED_DIRS on the Bridge server'),
        findsOneWidget,
      );
    });

    patrolWidgetTest(
      'I6: error without errorCode shows plain message (backward compat)',
      ($) async {
        await $.pumpWidget(await buildTestChatScreen(bridge: bridge));
        await pumpN($.tester);

        await emitAndPump($.tester, bridge, [
          const StatusMessage(status: ProcessStatus.running),
          const ErrorMessage(message: 'Generic error from old bridge'),
        ]);
        await pumpN($.tester);

        // Message should be shown
        expect($('Generic error from old bridge'), findsOneWidget);
        // No structured title should appear
        expect($('Authentication Error'), findsNothing);
        expect($('Path Not Allowed'), findsNothing);
      },
    );
  });
}
