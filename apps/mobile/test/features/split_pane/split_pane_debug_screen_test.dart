import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccpocket/features/split_pane/split_pane_debug_screen.dart';

Future<void> _cmd(WidgetTester tester, LogicalKeyboardKey key,
    {bool shift = false}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
  await tester.pump();
}

void main() {
  testWidgets('⌘D splits the focused pane (keyboard shortcut works by default)',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SplitPaneDebugScreen()));
    await tester.pumpAndSettle();
    expect(find.text('(empty)'), findsOneWidget);

    await _cmd(tester, LogicalKeyboardKey.keyD);

    expect(find.text('(empty)'), findsNWidgets(2));
  });

  testWidgets('⌘⇧D splits and ⌘W closes', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SplitPaneDebugScreen()));
    await tester.pumpAndSettle();

    await _cmd(tester, LogicalKeyboardKey.keyD, shift: true);
    expect(find.text('(empty)'), findsNWidgets(2));

    await _cmd(tester, LogicalKeyboardKey.keyW);
    expect(find.text('(empty)'), findsOneWidget);
  });
}
