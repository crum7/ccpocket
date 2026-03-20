import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:ccpocket/widgets/bubbles/system_chip.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.darkTheme,
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('renders non-session-created system messages even with model set', (
    tester,
  ) async {
    const message = SystemMessage(
      subtype: 'supported_commands',
      provider: 'codex',
      model: 'gpt-5.4',
    );

    await tester.pumpWidget(_wrap(const SystemChip(message: message)));

    expect(find.text('System: supported_commands'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
