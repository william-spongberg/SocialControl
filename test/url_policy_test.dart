import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:social_control/src/rules/site_rules.dart';
import 'package:social_control/src/webview/engine_config.dart';
import 'package:social_control/src/webview/url_policy.dart';

import 'helpers.dart';

void main() {
  final rules = SiteRules.parse(rulesJson());
  final policy = UrlPolicy(
    rules,
    EngineConfig.build(rules, {'hideReels', 'followingFeed'}).resolver,
  );

  NavDecision decide(String url, {bool isMainFrame = true}) =>
      policy.decide(Uri.parse(url), isMainFrame: isMainFrame);

  group('UrlPolicy', () {
    test('allows ordinary Instagram pages', () {
      expect(
        decide('https://www.instagram.com/direct/inbox/'),
        isA<NavAllow>(),
      );
    });

    test('redirects a blocked page and names the block', () {
      final decision = decide('https://www.instagram.com/reels/C8xYz/');
      expect(decision, isA<NavRedirect>());
      decision as NavRedirect;
      expect(
        decision.url.toString(),
        'https://www.instagram.com/?variant=following',
      );
      expect(decision.blockedLabel, 'Reels');
    });

    test('redirects silently for redirect rules', () {
      final decision = decide('https://www.instagram.com/') as NavRedirect;
      expect(decision.url.query, 'variant=following');
      expect(decision.blockedLabel, isNull);
    });

    test('starts on the resolved start page', () {
      expect(
        policy.startUrl.toString(),
        'https://www.instagram.com/?variant=following',
      );
    });

    test('applies signed-out routes only when signed out', () {
      final json = jsonDecode(rulesJson()) as Map<String, dynamic>
        ..['session'] = {
          'cookies': ['ds_user_id'],
        };
      ((json['features'] as List)[1]['routes'] as List).add({
        'match': r'^/\?variant=following$',
        'action': 'redirect',
        'to': '/accounts/login/',
        'signedOut': true,
      });
      final sessionRules = SiteRules.fromJson(json);
      final sessionPolicy = UrlPolicy(
        sessionRules,
        EngineConfig.build(sessionRules, {'followingFeed'}).resolver,
      );
      expect(
        sessionPolicy.startUrlFor(signedIn: false).toString(),
        'https://www.instagram.com/accounts/login/',
      );
      expect(
        sessionPolicy.startUrl.toString(),
        'https://www.instagram.com/?variant=following',
      );
      final home = Uri.parse('https://www.instagram.com/');
      expect(
        (sessionPolicy.decide(home, isMainFrame: true, signedIn: false)
                as NavRedirect)
            .url
            .path,
        '/accounts/login/',
      );
      expect(
        (sessionPolicy.decide(home, isMainFrame: true) as NavRedirect)
            .url
            .query,
        'variant=following',
      );
    });

    test('leaves frames alone', () {
      expect(
        decide('https://www.instagram.com/reels/', isMainFrame: false),
        isA<NavAllow>(),
      );
    });

    test('never opens the native app', () {
      expect(
        decide('intent://instagram.com/#Intent;scheme=https;end'),
        isA<NavCancel>(),
      );
      expect(decide('instagram://user?username=someone'), isA<NavCancel>());
    });

    test('opens other sites and mail links outside the app', () {
      final other = decide('https://example.com/article');
      expect(other, isA<NavOpenExternal>());
      expect((other as NavOpenExternal).url.host, 'example.com');
      expect(decide('mailto:hi@example.com'), isA<NavOpenExternal>());
    });

    test('keeps only the hosts the rules allow inside the app', () {
      expect(decide('https://accountscenter.instagram.com/'), isA<NavAllow>());
      // Sign-in providers load in the app only for sites whose rules list
      // them.
      for (final url in [
        'https://accounts.google.com/',
        'https://appleid.apple.com/auth/authorize',
        'https://www.facebook.com/dialog/oauth',
      ]) {
        expect(decide(url), isA<NavOpenExternal>(), reason: url);
      }
    });

    test('unwraps link shims before deciding', () {
      final external = decide(
        'https://l.instagram.com/?u=https%3A%2F%2Fexample.com%2Fpage&e=abc',
      );
      expect(
        (external as NavOpenExternal).url.toString(),
        'https://example.com/page',
      );

      final internal = decide(
        'https://l.instagram.com/?u=https%3A%2F%2Fwww.instagram.com%2Fsomeone%2F',
      );
      expect((internal as NavRedirect).url.path, '/someone/');

      final blocked = decide(
        'https://l.instagram.com/?u=https%3A%2F%2Fwww.instagram.com%2Freels%2F',
      );
      expect((blocked as NavRedirect).blockedLabel, 'Reels');
    });

    test('unwraps a shim limited to a path only on that path', () {
      final json = jsonDecode(rulesJson()) as Map<String, dynamic>
        ..['hosts'] = ['www.instagram.com', 'www.youtube.com']
        ..['linkShims'] = [
          {'host': 'www.youtube.com', 'path': '/redirect', 'param': 'q'},
        ];
      final rules = SiteRules.fromJson(json);
      final policy = UrlPolicy(rules, EngineConfig.build(rules, {}).resolver);
      final shimmed = policy.decide(
        Uri.parse(
          'https://www.youtube.com/redirect?event=x&q=https%3A%2F%2Fexample.com%2F',
        ),
        isMainFrame: true,
      );
      expect((shimmed as NavOpenExternal).url.host, 'example.com');
      expect(
        policy.decide(
          Uri.parse('https://www.youtube.com/watch?v=x&q=https%3A%2F%2Fa.b'),
          isMainFrame: true,
        ),
        isA<NavAllow>(),
      );
    });

    test('opens a shim without a destination outside the app', () {
      expect(decide('https://l.instagram.com/?x=1'), isA<NavOpenExternal>());
    });

    test('allows about:blank and data URLs', () {
      expect(decide('about:blank'), isA<NavAllow>());
      expect(decide('data:text/html,hi'), isA<NavAllow>());
    });
  });

  group('RedirectGuard', () {
    test('stops the fourth redirect in a row', () {
      var now = DateTime(2026, 1, 1);
      final guard = RedirectGuard(clock: () => now);
      final allowed = <bool>[];
      for (var i = 0; i < 4; i++) {
        allowed.add(guard.allow());
        now = now.add(const Duration(seconds: 1));
      }
      expect(allowed, [true, true, true, false]);
    });

    test('starts counting again after a quiet spell', () {
      var now = DateTime(2026, 1, 1);
      final guard = RedirectGuard(clock: () => now);
      for (var i = 0; i < 3; i++) {
        guard.allow();
      }
      now = now.add(RedirectGuard.window);
      expect(guard.allow(), isTrue);
    });
  });
}
