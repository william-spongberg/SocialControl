import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:social_control/src/rules/site_rules.dart';
import 'package:social_control/src/webview/engine_config.dart';

import 'helpers.dart';

void main() {
  final rules = SiteRules.parse(rulesJson());

  group('EngineConfig', () {
    test('includes only enabled features', () {
      final config = EngineConfig.build(rules, {'hideReels'});
      final json = jsonDecode(config.json) as Map<String, dynamic>;
      expect(
        [for (final r in json['routes'] as List) r['id']],
        ['hideReels/route0'],
      );
      expect(
        [for (final h in json['hide'] as List) h['id']],
        ['hideReels/hide0'],
      );
      expect(json['hideByText'], isEmpty);
      expect(json['hosts'], rules.hosts);
      expect(json['session'], isNull);
      expect(json['signedIn'], isNull);
      expect(json['popstateNavigation'], isFalse);
      expect(json['keep'], isEmpty);
    });

    test('puts the sign-in route first, and passes on the app\'s answer', () {
      final json = jsonDecode(rulesJson()) as Map<String, dynamic>
        ..['session'] = {
          'cookies': ['ds_user_id'],
        }
        ..['signIn'] = {'match': r'^/(?!accounts/)', 'to': '/accounts/login/'};
      final rules = SiteRules.fromJson(json);
      // With every feature off, sign-in still applies.
      final config = EngineConfig.build(rules, const {}, signedIn: false);
      final engine = jsonDecode(config.json) as Map<String, dynamic>;
      expect(engine['signedIn'], isFalse);
      expect(engine['routes'], [
        {
          'id': 'signIn',
          'match': r'^/(?!accounts/)',
          'action': 'redirect',
          'to': '/accounts/login/',
          'label': 'Sign in',
          'signedOut': true,
        },
      ]);
      expect(
        config.resolver.resolve('/reels/', signedIn: false).path,
        '/accounts/login/',
      );
      final features = EngineConfig.build(rules, {'hideReels'});
      expect(
        [for (final r in features.routes) r.id],
        ['signIn', 'hideReels/route0'],
      );
    });

    test('passes style rules through with ids', () {
      final rules = SiteRules.parse(
        rulesJson(
          features: [
            {
              'id': 'fix',
              'title': 'Fix',
              'enabledByDefault': true,
              'style': [
                {'selector': '.slot-open', 'css': 'transform: none'},
              ],
            },
          ],
        ),
      );
      final json =
          jsonDecode(EngineConfig.build(rules, {'fix'}).json)
              as Map<String, dynamic>;
      expect(json['style'], [
        {
          'id': 'fix/style0',
          'selector': '.slot-open',
          'css': 'transform: none',
          'paths': null,
        },
      ]);
    });

    test('passes keep rules and popstate navigation through', () {
      final json =
          jsonDecode(
                  rulesJson(
                    features: [
                      {
                        'id': 'tabs',
                        'title': 'Tab bar',
                        'enabledByDefault': true,
                        'keep': [
                          {'marker': 'a[href="/inbox/"]', 'paths': '^/inbox/'},
                        ],
                      },
                    ],
                  ),
                )
                as Map<String, dynamic>
            ..['popstateNavigation'] = true;
      final rules = SiteRules.fromJson(json);
      final on =
          jsonDecode(EngineConfig.build(rules, {'tabs'}).json)
              as Map<String, dynamic>;
      expect(on['popstateNavigation'], isTrue);
      expect(on['keep'], [
        {
          'id': 'tabs/keep0',
          'marker': 'a[href="/inbox/"]',
          'paths': '^/inbox/',
        },
      ]);
      final off =
          jsonDecode(EngineConfig.build(rules, const {}).json)
              as Map<String, dynamic>;
      expect(off['keep'], isEmpty);
    });

    test('passes search boxes through whatever features are on', () {
      final json = jsonDecode(rulesJson()) as Map<String, dynamic>
        ..['searchBoxes'] = [
          {
            'input': 'input[placeholder]',
            'to': r'/search/user?q=$1',
            'paths': '^/search',
          },
        ];
      final rules = SiteRules.fromJson(json);
      final engine =
          jsonDecode(EngineConfig.build(rules, const {}).json)
              as Map<String, dynamic>;
      expect(engine['searchBoxes'], [
        {
          'id': 'searchBox0',
          'input': 'input[placeholder]',
          'to': r'/search/user?q=$1',
          'paths': '^/search',
        },
      ]);
      final plain =
          jsonDecode(
                EngineConfig.build(SiteRules.parse(rulesJson()), const {}).json,
              )
              as Map<String, dynamic>;
      expect(plain['searchBoxes'], isEmpty);
    });

    test('passes the session and signed-out routes through', () {
      final json = jsonDecode(rulesJson()) as Map<String, dynamic>
        ..['session'] = {
          'cookies': ['SAPISID'],
        };
      ((json['features'] as List)[1]['routes'] as List).add({
        'match': r'^/feed/subscriptions$',
        'action': 'redirect',
        'to': '/feed/library',
        'signedOut': true,
      });
      final config =
          jsonDecode(
                EngineConfig.build(SiteRules.fromJson(json), {
                  'followingFeed',
                }).json,
              )
              as Map<String, dynamic>;
      expect(config['session'], ['SAPISID']);
      expect(
        [for (final r in config['routes'] as List) r['signedOut']],
        [false, true],
      );
    });

    test('passes collapse through on hide and text rules', () {
      final rules = SiteRules.parse(
        rulesJson(
          features: [
            {
              'id': 'ads',
              'title': 'Hide ads',
              'enabledByDefault': true,
              'hide': [
                {'selector': 'article:has(.ad)', 'collapse': true},
                {'selector': 'a.ad'},
              ],
              'hideByText': [
                {
                  'container': 'article',
                  'marker': 'span',
                  'text': ['Ad'],
                  'collapse': true,
                },
              ],
            },
          ],
        ),
      );
      final json =
          jsonDecode(EngineConfig.build(rules, {'ads'}).json)
              as Map<String, dynamic>;
      expect(
        [for (final h in json['hide'] as List) h['collapse']],
        [true, false],
      );
      expect((json['hideByText'] as List).single['collapse'], isTrue);
    });

    test('passes prune rules through with ids and pages', () {
      final rules = SiteRules.parse(
        rulesJson(
          features: [
            {
              'id': 'ads',
              'title': 'Hide ads',
              'enabledByDefault': true,
              'prune': [
                {'path': 'data.a.b'},
                {'path': 'adPlacements', 'global': 'ytInitialPlayerResponse'},
                {'path': 'itemList.[-].id', 'paths': '^/@[^/]*/video/'},
              ],
            },
          ],
        ),
      );
      final json =
          jsonDecode(EngineConfig.build(rules, {'ads'}).json)
              as Map<String, dynamic>;
      expect(json['prune'], [
        {'id': 'ads/prune0', 'path': 'data.a.b', 'global': null, 'paths': null},
        {
          'id': 'ads/prune1',
          'path': 'adPlacements',
          'global': 'ytInitialPlayerResponse',
          'paths': null,
        },
        {
          'id': 'ads/prune2',
          'path': 'itemList.[-].id',
          'global': null,
          'paths': '^/@[^/]*/video/',
        },
      ]);
      final off =
          jsonDecode(EngineConfig.build(rules, const {}).json)
              as Map<String, dynamic>;
      expect(off['prune'], isEmpty);
    });

    test('wraps the engine in a script that calls it with the config', () {
      final config = EngineConfig.build(rules, {'hideReels'});
      final script = config.userScript('function liteEngine(c) {}');
      expect(script, startsWith('(function () {\nfunction liteEngine(c) {}\n'));
      expect(script, endsWith('liteEngine(${config.json});\n})();'));
    });

    test('updates a running engine only if there is one', () {
      final config = EngineConfig.build(rules, const {});
      expect(
        config.updateScript,
        'window.__liteEngine && window.__liteEngine.update(${config.json});',
      );
    });
  });
}
