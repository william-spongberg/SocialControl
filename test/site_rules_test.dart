import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:social_control/src/rules/route_resolver.dart';
import 'package:social_control/src/rules/site_rules.dart';
import 'package:social_control/src/site.dart';
import 'package:social_control/src/webview/engine_config.dart';
import 'package:social_control/src/webview/url_policy.dart';

import 'helpers.dart';

Map<String, dynamic> _json({List<Map<String, Object?>>? features}) =>
    jsonDecode(rulesJson(features: features)) as Map<String, dynamic>;

Matcher _formatError(String fragment) => throwsA(
  isA<RulesFormatException>().having(
    (e) => e.message,
    'message',
    contains(fragment),
  ),
);

SiteRules _bundled(String platform) =>
    SiteRules.parse(File('assets/rules/$platform.json').readAsStringSync());

/// A resolver for the features that are on by default.
RouteResolver _defaults(SiteRules rules) => EngineConfig.build(rules, {
  for (final f in rules.features)
    if (f.enabledByDefault) f.id,
}).resolver;

void main() {
  for (final site in siteCatalog) {
    group('bundled ${site.platform} rules', () {
      final rules = SiteRules.parse(File(site.rulesAsset).readAsStringSync());

      test('parse, and are for this site', () {
        expect(rules.platform, site.platform);
        expect(rules.features, isNotEmpty);
      });

      test('never resolve to a path that is itself redirected', () {
        final all = EngineConfig.build(rules, {
          for (final f in rules.features) f.id,
        }).resolver;
        for (final feature in rules.features) {
          for (final route in feature.routes) {
            // Targets with capture groups get a sample value.
            final target = route.to.replaceAll(groupReference, 'x1');
            final end = all.resolve(target).path;
            expect(all.resolve(end).changed, isFalse, reason: route.to);
          }
        }
        final start = all.resolve(routePath(rules.startUrl)).path;
        expect(all.resolve(start).changed, isFalse);
      });
    });
  }

  test('every bundled site hides app prompts by default', () {
    for (final site in siteCatalog) {
      final rules = _bundled(site.platform);
      final prompts = rules.features.firstWhere(
        (feature) => feature.id == 'hideAppPrompts',
        orElse: () =>
            throw StateError('${site.platform} has no hideAppPrompts feature'),
      );
      expect(prompts.enabledByDefault, isTrue, reason: site.platform);
      expect(prompts.hide, isNotEmpty, reason: site.platform);
    }
  });

  group('bundled Instagram rules', () {
    final rules = _bundled('instagram');
    final resolver = _defaults(rules);

    test('block the Reels feed but open a single reel', () {
      expect(resolver.resolve('/reels/').blockedLabel, 'Reels');
      // A link into the feed at one reel opens that reel on its own.
      final single = resolver.resolve('/reels/C8xYz12AbC/');
      expect(single.path, '/reel/C8xYz12AbC/');
      expect(single.blockedLabel, isNull);
      expect(resolver.resolve('/reel/C8xYz12AbC/').changed, isFalse);
    });

    test('remove ads and suggestions from the feed data', () {
      const feed =
          'data.xdt_api__v1__feed__timeline__connection.edges.[-].node';
      final paths = {
        for (final f in rules.features)
          for (final p in f.prune) p.path,
      };
      for (final slot in [
        'ad',
        'ad4ad_in_webfeed',
        'suggested_users',
        'explore_story',
        'bloks_netego',
        'stories_netego',
      ]) {
        expect(paths, contains('$feed.$slot'));
      }
    });

    test('keep the tab bar in the inbox, not in conversations', () {
      final keep = rules.features
          .firstWhere((f) => f.id == 'tabBarInMessages')
          .keep
          .single;
      final paths = RegExp(keep.paths);
      expect(paths.hasMatch('/direct/inbox/'), isTrue);
      expect(paths.hasMatch('/direct/t/1234567890/'), isFalse);
      expect(rules.popstateNavigation, isTrue);
    });

    test('send Explore to search, and home to the Following feed', () {
      expect(resolver.resolve('/explore/').path, '/explore/search/');
      expect(resolver.resolve('/explore/tags/cats/').blockedLabel, isNotNull);
      expect(resolver.resolve('/', signedIn: true).path, '/?variant=following');
      expect(resolver.resolve('/', signedIn: false).path, '/accounts/login/');
      // Where Instagram lands after logging in.
      expect(
        resolver.resolve('/?deoia=1', signedIn: true).path,
        '/?variant=following',
      );
      expect(resolver.resolve('/?variant=favorites').changed, isFalse);
    });

    test('uses a page-readable cookie to identify signed-in users', () {
      expect(rules.session?.cookies, contains('ds_user_id'));
      expect(rules.isSignedIn({'ds_user_id'}), isTrue);
      expect(rules.isSignedIn(const {}), isFalse);
    });

    test('collapse whole posts instead of removing them', () {
      // Instagram's feed measures each post against the next one, and stops
      // rendering posts when one is removed. See HideRule.collapse.
      for (final feature in rules.features) {
        for (final t in feature.hideByText) {
          if (t.container == 'article') {
            expect(t.collapse, isTrue, reason: feature.id);
          }
        }
        for (final h in feature.hide) {
          if (h.selector.startsWith('article')) {
            expect(h.collapse, isTrue, reason: h.selector);
          }
        }
      }
    });

    test('leave messages, profiles and posts alone', () {
      for (final path in [
        '/direct/inbox/',
        '/direct/t/1234567890/',
        '/some.person/',
        '/p/C8xYz12AbC/',
        '/explore/search/',
        '/accounts/edit/',
      ]) {
        expect(resolver.resolve(path).changed, isFalse, reason: path);
      }
    });

    test('hide ads by several independent signals', () {
      final ads = rules.features.firstWhere((f) => f.id == 'hideSponsored');
      expect(ads.hide, isNotEmpty);
      expect([
        for (final p in ads.prune) p.path,
      ], contains('data.xdt_injected_story_units.ad_media_items'));
      final label = ads.hideByText.single;
      expect(label.text, contains('Sponsored'));
      final partnership = RegExp(label.pattern!);
      expect(partnership.hasMatch('Paid partnership with Brand Co'), isTrue);
      expect(partnership.hasMatch('Paid partnership'), isTrue);
      expect(partnership.hasMatch('Not a paid partnership'), isFalse);
    });

    test('hide posts from unfollowed accounts on the home feed only', () {
      final suggested = rules.features.firstWhere(
        (f) => f.id == 'hideSuggested',
      );
      final follow = suggested.hideByText.firstWhere(
        (t) => t.text.contains('Follow'),
      );
      final paths = RegExp(follow.paths!);
      expect(paths.hasMatch('/'), isTrue);
      expect(paths.hasMatch('/?variant=following'), isTrue);
      expect(paths.hasMatch('/p/C8xYz12AbC/'), isFalse);
      expect(paths.hasMatch('/someone/'), isFalse);
    });
  });

  group('bundled YouTube rules', () {
    final rules = _bundled('youtube');
    final resolver = _defaults(rules);

    test('send Home to Subscriptions', () {
      expect(resolver.resolve('/').path, '/feed/subscriptions');
      expect(resolver.resolve('/?app=m').path, '/feed/subscriptions');
      expect(resolver.resolve('/').blockedLabel, isNull);
    });

    test(
      'play a single Short as a normal video, and block the Shorts feed',
      () {
        final single = resolver.resolve('/shorts/aB3_x-9?feature=share');
        expect(single.path, '/watch?v=aB3_x-9');
        expect(single.blockedLabel, isNull);
        for (final path in ['/shorts', '/shorts/', '/shorts?x=1']) {
          final feed = resolver.resolve(path);
          expect(feed.path, '/feed/subscriptions', reason: path);
          expect(feed.blockedLabel, 'Shorts', reason: path);
        }
      },
    );

    test('send a channel\'s Shorts tab to its videos', () {
      expect(resolver.resolve('/@someone/shorts').path, '/@someone/videos');
      expect(
        resolver.resolve('/channel/UCabc/shorts/').path,
        '/channel/UCabc/videos',
      );
    });

    test('block Explore, Trending and hashtag feeds', () {
      for (final path in [
        '/feed/trending',
        '/feed/explore?bp=1',
        '/gaming',
        '/hashtag/cats',
      ]) {
        final resolution = resolver.resolve(path);
        expect(resolution.blockedLabel, isNotNull, reason: path);
        expect(resolution.path, '/feed/subscriptions', reason: path);
      }
    });

    test('leave videos, search, channels, the library and sign-in alone', () {
      for (final path in [
        '/watch?v=dQw4w9WgXcQ',
        '/watch?v=dQw4w9WgXcQ&list=WL&index=2',
        '/results?search_query=cats',
        '/feed/subscriptions',
        '/feed/channels',
        '/feed/library',
        '/feed/you',
        '/feed/history',
        '/playlist?list=WL',
        '/@someone',
        '/@someone/videos',
        '/channel/UCabc',
        '/signin?action_handle_signin=true',
      ]) {
        expect(resolver.resolve(path).changed, isFalse, reason: path);
      }
    });

    test('remove video ad data wherever the page gets it from', () {
      final ads = rules.features.firstWhere((f) => f.id == 'hideAds');
      final paths = {for (final p in ads.prune) '${p.global ?? ''}:${p.path}'};
      for (final field in ['adPlacements', 'playerAds', 'adSlots']) {
        expect(paths, contains(':$field'));
        expect(paths, contains(':playerResponse.$field'));
        expect(paths, contains('ytInitialPlayerResponse:$field'));
      }
    });

    test('keep every step of Google\'s sign-in inside the app', () {
      final rules = _bundled('youtube');
      final policy = UrlPolicy(rules, _defaults(rules));
      for (final url in [
        'https://accounts.google.com/v3/signin/identifier?service=youtube',
        'https://accounts.youtube.com/accounts/SetSID?continue=x',
        'https://www.youtube.com/signin?action_handle_signin=true',
      ]) {
        expect(
          policy.decide(Uri.parse(url), isMainFrame: true),
          isA<NavAllow>(),
          reason: url,
        );
      }
      // Country-specific hosts and lookalikes stay outside the app for now.
      for (final url in [
        'https://accounts.google.com.evil.example/',
        'https://accounts.google.co.xyz/',
        'https://evil.google.com.au/',
      ]) {
        expect(
          policy.decide(Uri.parse(url), isMainFrame: true),
          isA<NavOpenExternal>(),
          reason: url,
        );
      }
    });

    test(
      'send you to the sign-in page (You) instead of Subscriptions when signed out',
      () {
        final rules = _bundled('youtube');
        final resolver = _defaults(rules);
        expect(resolver.resolve('/', signedIn: false).path, '/feed/library');
        expect(
          resolver.resolve('/feed/subscriptions', signedIn: false).path,
          '/feed/library',
        );
        expect(resolver.resolve('/').path, '/feed/subscriptions');
        // Signed out, the rest of YouTube still works.
        for (final path in [
          '/watch?v=dQw4w9WgXcQ',
          '/results?search_query=x',
        ]) {
          expect(
            resolver.resolve(path, signedIn: false).changed,
            isFalse,
            reason: path,
          );
        }
        final policy = UrlPolicy(rules, resolver);
        expect(
          policy.startUrlFor(signedIn: false).toString(),
          'https://m.youtube.com/feed/library',
        );
      },
    );

    test('tell signed in from signed out by cookies page scripts can read', () {
      final rules = _bundled('youtube');
      // The cookies of a signed-out and a signed-in session on 2026-09-30.
      expect(rules.isSignedIn({'YSC', 'VISITOR_INFO1_LIVE', 'PREF'}), isFalse);
      expect(
        rules.isSignedIn({'YSC', 'SID', 'SAPISID', '__Secure-3PAPISID'}),
        isTrue,
      );
      // HttpOnly cookies such as LOGIN_INFO are invisible to the engine, so
      // they must not decide it on the app's side either.
      expect(rules.session!.cookies, isNot(contains('LOGIN_INFO')));
    });

    test(
      'undo the slide that keeps the title under the video after fullscreen',
      () {
        final related = rules.features.firstWhere((f) => f.id == 'hideRelated');
        final unslide = related.style.single;
        expect(unslide.selector, '.related-chips-slot-wrapper.slot-open');
        expect(unslide.css, 'transform: none');
      },
    );

    test('unwrap outbound links only on the redirect page', () {
      final shim = rules.linkShims.firstWhere(
        (s) => s.host == 'www.youtube.com',
      );
      expect(
        shim.matches(Uri.parse('https://www.youtube.com/redirect?q=x')),
        isTrue,
      );
      expect(
        shim.matches(Uri.parse('https://www.youtube.com/watch?v=x')),
        isFalse,
      );
    });
  });

  group('bundled Reddit rules', () {
    final rules = _bundled('reddit');
    final resolver = _defaults(rules);

    test('sends signed-out users to login before any content', () {
      expect(rules.session, isNotNull);
      expect(rules.isSignedIn(const {}), isFalse);
      expect(resolver.resolve('/', signedIn: false).path, '/login/');
      expect(
        resolver.resolve('/r/programming/', signedIn: false).path,
        '/login/',
      );
      expect(resolver.resolve('/login/', signedIn: false).changed, isFalse);
      expect(resolver.resolve('/', signedIn: true).changed, isFalse);
      expect(resolver.resolve('/login/').changed, isFalse);

      final policy = UrlPolicy(rules, resolver);
      expect(
        policy.decide(Uri.parse('https://www.reddit.com/'), isMainFrame: true),
        isA<NavAllow>(),
      );
      expect(
        policy.decide(
          Uri.parse('https://accounts.reddit.com/login/'),
          isMainFrame: true,
        ),
        isA<NavAllow>(),
      );
    });

    test('blocks discovery feeds but leaves subreddits and posts alone', () {
      for (final path in ['/r/popular/', '/r/all/', '/popular/']) {
        final resolution = resolver.resolve(path);
        expect(resolution.blockedLabel, 'Discovery feeds', reason: path);
        expect(resolution.path, '/', reason: path);
      }
      for (final path in ['/r/programming/', '/comments/abc/post-title/']) {
        expect(resolver.resolve(path).changed, isFalse, reason: path);
      }
    });

    test('hides the live app button and promotion popup', () {
      final prompts = rules.features.firstWhere(
        (feature) => feature.id == 'hideAppPrompts',
      );
      final selector = prompts.hide.single.selector;
      expect(selector, contains('#xpromo-small-header'));
      expect(selector, contains('#open-app-header-cta'));
      expect(selector, contains('div.configured-xpromo-bottom-sheet'));
    });
  });

  group('SiteRules.parse', () {
    test('reads a valid file', () {
      final rules = SiteRules.parse(rulesJson(revision: 7));
      expect(rules.revision, 7);
      expect(rules.isSiteHost('WWW.Instagram.com'), isTrue);
      expect(rules.isAllowedHost('accountscenter.instagram.com'), isTrue);
      expect(rules.linkShims.single.host, 'l.instagram.com');
      expect(rules.userAgent, UserAgentMode.browser);
      final reels = rules.features.first;
      expect(reels.routes.single.action, RouteAction.block);
      expect(reels.hide.single.selector, 'a[href^="/reels/"]');
    });

    test('rejects another schema version', () {
      expect(
        () => SiteRules.parse(rulesJson(schemaVersion: 2)),
        _formatError('schemaVersion 2 is not supported'),
      );
    });

    test('rejects text that is not JSON', () {
      expect(() => SiteRules.parse('<html>'), _formatError('not valid JSON'));
    });

    test('rejects an invalid pattern, naming where it is', () {
      final json = _json();
      ((json['features'] as List)[0]['routes'] as List)[0]['match'] = '([';
      expect(
        () => SiteRules.fromJson(json),
        _formatError('features[0].routes[0].match: invalid pattern'),
      );
    });

    test('rejects a route target that is not a path', () {
      final json = _json();
      ((json['features'] as List)[0]['routes'] as List)[0]['to'] =
          'https://example.com/';
      expect(() => SiteRules.fromJson(json), _formatError('must start with /'));
    });

    test('rejects an unknown route action', () {
      final json = _json();
      ((json['features'] as List)[0]['routes'] as List)[0]['action'] = 'hide';
      expect(() => SiteRules.fromJson(json), _formatError('expected one of'));
    });

    test('rejects duplicate feature ids', () {
      final json = _json();
      final features = json['features'] as List;
      features[1]['id'] = features[0]['id'];
      expect(() => SiteRules.fromJson(json), _formatError('duplicate id'));
    });

    test('rejects a start URL outside the site hosts', () {
      final json = _json()..['startUrl'] = 'https://example.com/';
      expect(() => SiteRules.fromJson(json), _formatError('startUrl'));
    });

    test('reads text rules with a pattern and prune rules', () {
      final rules = SiteRules.parse(
        rulesJson(
          features: [
            {
              'id': 'ads',
              'title': 'Hide ads',
              'enabledByDefault': true,
              'hideByText': [
                {'container': 'article', 'marker': 'span', 'pattern': '^Ad'},
              ],
              'prune': [
                {'path': 'data.feed.edges.[-].node.ad'},
              ],
            },
          ],
        ),
      );
      final ads = rules.features.single;
      expect(ads.hideByText.single.text, isEmpty);
      expect(ads.hideByText.single.pattern, '^Ad');
      expect(ads.prune.single.path, 'data.feed.edges.[-].node.ad');
    });

    test('reads collapse on hide and text rules, off by default', () {
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
      final ads = rules.features.single;
      expect([for (final h in ads.hide) h.collapse], [true, false]);
      expect(ads.hideByText.single.collapse, isTrue);
    });

    test('rejects a collapse that is not true or false', () {
      final json = _json();
      ((json['features'] as List)[0]['hide'] as List)[0]['collapse'] = 'yes';
      expect(
        () => SiteRules.fromJson(json),
        _formatError('features[0].hide[0].collapse: expected true or false'),
      );
    });

    test('rejects a text rule with neither text nor a pattern', () {
      final json = _json(
        features: [
          {
            'id': 'x',
            'title': 'X',
            'enabledByDefault': true,
            'hideByText': [
              {'container': 'article', 'marker': 'span'},
            ],
          },
        ],
      );
      expect(
        () => SiteRules.fromJson(json),
        _formatError('needs text or a pattern'),
      );
    });

    test('rejects prune paths that do not end in a property name', () {
      for (final path in ['data.items.[]', 'data..ad', 'items.[-]']) {
        final json = _json(
          features: [
            {
              'id': 'x',
              'title': 'X',
              'enabledByDefault': true,
              'prune': [
                {'path': path},
              ],
            },
          ],
        );
        expect(
          () => SiteRules.fromJson(json),
          _formatError('prune[0].path'),
          reason: path,
        );
      }
    });

    test('reads capture groups in route targets', () {
      final json = _json();
      final route = ((json['features'] as List)[0]['routes'] as List)[0];
      route['match'] = r'^/shorts/(\w+)';
      route['to'] = r'/watch?v=$1';
      expect(SiteRules.fromJson(json).features[0].routes[0].to, '/watch?v=\$1');
    });

    test('rejects a target that refers to a missing capture group', () {
      final json = _json();
      final route = ((json['features'] as List)[0]['routes'] as List)[0];
      route['match'] = r'^/shorts/(\w+)';
      route['to'] = r'/watch?v=$2';
      expect(
        () => SiteRules.fromJson(json),
        _formatError('features[0].routes[0].to: \$2 refers to a group'),
      );
    });

    test('reads prune rules for a page global, and checks the name', () {
      Map<String, dynamic> withGlobal(String global) => _json(
        features: [
          {
            'id': 'ads',
            'title': 'Hide ads',
            'enabledByDefault': true,
            'prune': [
              {'path': 'adPlacements', 'global': global},
            ],
          },
        ],
      );
      final rule = SiteRules.fromJson(
        withGlobal(r'yt$Initial_1'),
      ).features.single.prune.single;
      expect(rule.global, r'yt$Initial_1');
      expect(
        () => SiteRules.fromJson(withGlobal('window.x')),
        _formatError('prune[0].global'),
      );
    });

    test('reads link shims limited to a path', () {
      final json = _json()
        ..['linkShims'] = [
          {'host': 'www.youtube.com', 'path': '/redirect', 'param': 'q'},
        ];
      final shim = SiteRules.fromJson(json).linkShims.single;
      expect(shim.path, '/redirect');
      expect(
        shim.matches(Uri.parse('https://WWW.youtube.com/redirect?q=1')),
        isTrue,
      );
      expect(shim.matches(Uri.parse('https://www.youtube.com/?q=1')), isFalse);

      (json['linkShims'] as List)[0]['path'] = 'redirect';
      expect(() => SiteRules.fromJson(json), _formatError('path: must start'));
    });

    test('reads a session and routes that only apply signed out', () {
      final json = _json()
        ..['session'] = {
          'cookies': ['ds_user_id'],
        };
      ((json['features'] as List)[1]['routes'] as List).add({
        'match': r'^/\?variant=following$',
        'action': 'redirect',
        'to': '/accounts/login/',
        'signedOut': true,
      });
      final rules = SiteRules.fromJson(json);
      expect(rules.session!.cookies, ['ds_user_id']);
      expect(rules.isSignedIn({'ds_user_id'}), isTrue);
      expect(rules.isSignedIn({'csrftoken'}), isFalse);
      expect(rules.features[1].routes.last.signedOut, isTrue);
      expect(rules.features[1].routes.first.signedOut, isFalse);

      (json['session'] as Map)['cookies'] = <String>[];
      expect(
        () => SiteRules.fromJson(json),
        _formatError('session.cookies: must not be empty'),
      );
      json.remove('session');
      expect(
        () => SiteRules.fromJson(json),
        _formatError('signedOut routes, which need session'),
      );
      final plain = SiteRules.parse(rulesJson());
      expect(plain.session, isNull);
      expect(plain.isSignedIn(const {}), isTrue);
    });

    test('reads style rules and refuses CSS that could do more than style', () {
      Map<String, dynamic> withCss(String css) => _json(
        features: [
          {
            'id': 'fix',
            'title': 'Fix',
            'enabledByDefault': true,
            'style': [
              {'selector': '.slot-open', 'css': css, 'paths': '^/watch'},
            ],
          },
        ],
      );
      final rule = SiteRules.fromJson(
        withCss('transform: none; margin-top: 0 !important'),
      ).features.single.style.single;
      expect(rule.selector, '.slot-open');
      expect(rule.paths, '^/watch');
      for (final css in [
        'color: red } body { display: none',
        'background: url(https://x.example/a.png)',
        '@import "x"',
        'no colon here',
        ';',
      ]) {
        expect(
          () => SiteRules.fromJson(withCss(css)),
          _formatError('features[0].style[0].css'),
          reason: css,
        );
      }
    });

    test('reads keep rules and popstate navigation, both off by default', () {
      final json = _json(
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
      )..['popstateNavigation'] = true;
      final rules = SiteRules.fromJson(json);
      expect(rules.popstateNavigation, isTrue);
      final keep = rules.features.single.keep.single;
      expect(keep.marker, 'a[href="/inbox/"]');
      expect(keep.paths, '^/inbox/');

      ((json['features'] as List).single['keep'] as List).single.remove(
        'paths',
      );
      expect(
        () => SiteRules.fromJson(json),
        _formatError('features[0].keep[0].paths'),
      );
      final plain = SiteRules.parse(rulesJson());
      expect(plain.popstateNavigation, isFalse);
      expect(plain.features.first.keep, isEmpty);
    });

    test('ignores fields it does not know', () {
      final json = _json()..['somethingNew'] = {'a': 1};
      expect(SiteRules.fromJson(json).revision, 1);
    });
  });
}
