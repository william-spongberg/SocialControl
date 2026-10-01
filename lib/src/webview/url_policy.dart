import '../rules/route_resolver.dart';
import '../rules/site_rules.dart';

/// What to do with a navigation the WebView is about to make.
sealed class NavDecision {
  const NavDecision();
}

class NavAllow extends NavDecision {
  const NavAllow();
}

/// Drop the navigation. Used for app links such as `intent:` and
/// `instagram:`, which would open the official app, unless the rules map
/// them to a page of the site.
class NavCancel extends NavDecision {
  const NavCancel();
}

/// Open [url] in the system browser (or the app that handles it).
class NavOpenExternal extends NavDecision {
  const NavOpenExternal(this.url);

  final Uri url;
}

/// Load [url] instead. [blockedLabel] is set when a block rule caused it.
class NavRedirect extends NavDecision {
  const NavRedirect(this.url, {this.blockedLabel});

  final Uri url;
  final String? blockedLabel;
}

/// Decides full page loads. In-page navigation is handled by the engine,
/// which applies the same route rules.
class UrlPolicy {
  UrlPolicy(this.rules, this.resolver);

  final SiteRules rules;
  final RouteResolver resolver;

  static const _passThroughSchemes = {'about', 'data', 'blob', 'javascript'};
  static const _externalSchemes = {'mailto', 'tel', 'sms'};

  /// Where the app opens: the rules' start URL after route rules, so the
  /// first load already lands on e.g. the Following feed.
  Uri get startUrl => startUrlFor(signedIn: true);

  /// [startUrl] for a user who is or isn't signed in, since some routes only
  /// apply signed out.
  Uri startUrlFor({required bool signedIn}) =>
      _resolved(rules.startUrl, signedIn).$1;

  NavDecision decide(
    Uri url, {
    required bool isMainFrame,
    bool signedIn = true,
  }) {
    // Frames are embedded content, not navigation the user sees.
    if (!isMainFrame) return const NavAllow();

    final scheme = url.scheme.toLowerCase();
    if (_passThroughSchemes.contains(scheme)) return const NavAllow();
    if (_externalSchemes.contains(scheme)) return NavOpenExternal(url);
    if (scheme != 'http' && scheme != 'https') return _appLink(url, signedIn);

    for (final shim in rules.linkShims) {
      if (!shim.matches(url)) continue;
      final target = Uri.tryParse(url.queryParameters[shim.param] ?? '');
      if (target == null || !target.hasScheme) return NavOpenExternal(url);
      return switch (decide(target, isMainFrame: true, signedIn: signedIn)) {
        NavAllow() => NavRedirect(target),
        final decision => decision,
      };
    }

    if (rules.isSiteHost(url.host)) {
      final (resolved, blockedLabel) = _resolved(url, signedIn);
      if (resolved == url) return const NavAllow();
      return NavRedirect(resolved, blockedLabel: blockedLabel);
    }
    if (rules.isAllowedHost(url.host)) return const NavAllow();
    return NavOpenExternal(url);
  }

  /// An app link opens the page of the site that the rules map it to, and is
  /// otherwise dropped: the app never opens the site's own app.
  NavDecision _appLink(Uri url, bool signedIn) {
    for (final link in rules.appLinks) {
      final path = link.pathFor(url);
      if (path == null) continue;
      final page = rules.startUrl.resolve(path);
      return switch (decide(page, isMainFrame: true, signedIn: signedIn)) {
        NavAllow() => NavRedirect(page),
        final decision => decision,
      };
    }
    return const NavCancel();
  }

  (Uri, String?) _resolved(Uri url, bool signedIn) {
    final resolution = resolver.resolve(routePath(url), signedIn: signedIn);
    if (!resolution.changed) return (url, null);
    return (url.resolve(resolution.path), resolution.blockedLabel);
  }
}

/// Stops redirect loops on full page loads, e.g. if the site starts sending a
/// target page back to a blocked one. Counts redirects that follow each other
/// within [window]. The engine does the same for in-page navigation, where it
/// can also tell a loop from a user tapping around.
class RedirectGuard {
  RedirectGuard({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  static const window = Duration(seconds: 5);
  static const limit = 3;

  final DateTime Function() _clock;
  DateTime? _last;
  int _count = 0;

  /// Records a redirect and returns whether to go ahead with it.
  bool allow() {
    final now = _clock();
    final last = _last;
    _count = last != null && now.difference(last) < window ? _count + 1 : 1;
    _last = now;
    return _count <= limit;
  }
}
