import 'package:flutter_test/flutter_test.dart';
import 'package:social_control/src/config.dart';

void main() {
  group('rulesUrlFor', () {
    test('names the site\'s file in the rules folder', () {
      for (final base in [
        'https://example.com/rules/',
        'https://example.com/rules',
      ]) {
        expect(
          rulesUrlFor('youtube', base: base).toString(),
          'https://example.com/rules/youtube.json',
          reason: base,
        );
      }
    });

    test('is null when the build has no rules URL', () {
      expect(rulesUrlFor('youtube', base: ''), isNull);
    });
  });
}
