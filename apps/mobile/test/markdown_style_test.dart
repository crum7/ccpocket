import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ccpocket/theme/app_theme.dart';
import 'package:ccpocket/theme/markdown_style.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('highlightToTextSpans', () {
    testWidgets(
      'falls back safely when TypeScript syntax highlighting throws',
      (tester) async {
        await initializeMarkdownSyntaxHighlight();

        final source = '''
/**
 * Formats a value for display.
 */
export const formatValue = (value: string): string => value.trim();
''';

        late List<TextSpan> spans;

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.lightTheme,
            home: Builder(
              builder: (context) {
                spans = highlightToTextSpans(
                  context: context,
                  source: source,
                  baseStyle: const TextStyle(),
                  language: 'typescript',
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        );

        expect(tester.takeException(), isNull);
        expect(_flattenText(spans), source);
      },
    );
  });
}

String _flattenText(List<TextSpan> spans) {
  final buffer = StringBuffer();

  void visit(TextSpan span) {
    if (span.text != null) {
      buffer.write(span.text);
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      if (child is TextSpan) {
        visit(child);
      }
    }
  }

  for (final span in spans) {
    visit(span);
  }

  return buffer.toString();
}
