import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:social_control/src/rules/route_resolver.dart';
import 'package:social_control/src/rules/site_rules.dart';

void main() {
  group('RouteResolver', () {
    // Shared with test/js/lite_engine.test.mjs.
    final fixture =
        jsonDecode(File('test/fixtures/route_cases.json').readAsStringSync())
            as Map<String, dynamic>;
    final resolver = RouteResolver([
      for (final r in fixture['routes'] as List)
        ActiveRoute(
          id: r['id'] as String,
          match: r['match'] as String,
          action: RouteAction.values.byName(r['action'] as String),
          to: r['to'] as String,
          label: r['label'] as String,
          signedOut: r['signedOut'] as bool? ?? false,
        ),
    ]);

    for (final c in fixture['cases'] as List) {
      final path = c['path'] as String;
      final signedIn = c['signedIn'] as bool? ?? true;
      final expected = c['expect'] as Map<String, dynamic>;
      test('resolves $path${signedIn ? '' : ' signed out'}', () {
        final resolution = resolver.resolve(path, signedIn: signedIn);
        expect(resolution.path, expected['path']);
        expect(resolution.changed, expected['changed']);
        expect(resolution.blockedLabel, expected['blocked']);
      });
    }
  });

  group('routePath', () {
    test('uses path and query, and ignores the fragment', () {
      expect(
        routePath(Uri.parse('https://www.instagram.com/explore/?a=1#x')),
        '/explore/?a=1',
      );
    });

    test('treats an empty path as /', () {
      expect(routePath(Uri.parse('https://www.instagram.com')), '/');
    });
  });
}
