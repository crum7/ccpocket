import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:ccpocket/widgets/bubbles/error_bubble.dart';

Widget _wrapErrorBubble({required Widget child, required Locale locale}) {
  return MaterialApp(
    theme: AppTheme.darkTheme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: locale,
    home: Scaffold(body: child),
  );
}

void main() {
  group('ErrorBubble auth UI', () {
    testWidgets('shows simplified Japanese auth guidance', (tester) async {
      const message = ErrorMessage(
        message: 'Failed to authenticate. API Error: 401 terminated',
        errorCode: 'auth_api_error',
      );

      await tester.pumpWidget(
        _wrapErrorBubble(
          locale: const Locale('ja'),
          child: const ErrorBubble(message: message),
        ),
      );

      expect(find.text('Claude Codeの再ログインが必要です'), findsOneWidget);
      expect(
        find.text('BridgeマシンでClaude Codeを起動し、再ログインしてください。'),
        findsOneWidget,
      );
      expect(find.text('手順を見る'), findsOneWidget);
      expect(find.text('Open Settings'), findsNothing);
      expect(find.text('claude'), findsOneWidget);
      expect(find.text('/login'), findsOneWidget);
    });

    testWidgets('keeps non-auth error layout unchanged', (tester) async {
      const message = ErrorMessage(
        message: 'Project path not allowed',
        errorCode: 'path_not_allowed',
      );

      await tester.pumpWidget(
        _wrapErrorBubble(
          locale: const Locale('en'),
          child: const ErrorBubble(message: message),
        ),
      );

      expect(find.text('Path Not Allowed'), findsOneWidget);
      expect(find.text('Project path not allowed'), findsOneWidget);
      expect(find.text('View steps'), findsNothing);
    });
  });
}
