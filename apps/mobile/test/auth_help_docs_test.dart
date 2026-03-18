import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('auth troubleshooting docs', () {
    test('Japanese markdown exists with localized guidance', () {
      final file = File('assets/docs/auth-troubleshooting.ja.md');

      expect(file.existsSync(), isTrue);
      final content = file.readAsStringSync();
      expect(content, contains('おすすめの対処'));
      expect(content, contains('`claude`'));
      expect(content, contains('`/login`'));
    });

    test('English markdown exists with localized guidance', () {
      final file = File('assets/docs/auth-troubleshooting.en.md');

      expect(file.existsSync(), isTrue);
      final content = file.readAsStringSync();
      expect(content, contains('Recommended Fix'));
      expect(content, contains('`claude`'));
      expect(content, contains('`/login`'));
    });
  });
}
