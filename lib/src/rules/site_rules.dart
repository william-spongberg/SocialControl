import 'dart:convert';

/// The rules format this build reads. A file with any other `schemaVersion`
/// is rejected, so an old app never misreads rules written for a newer one.
const int supportedSchemaVersion = 1;

final RegExp _featureId = RegExp(r'^[A-Za-z0-9_-]+$');
final RegExp _identifier = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');

/// Characters and functions that would let a style rule do more than style
/// the page: close its CSS rule, add another, or load a URL.
final RegExp _unsafeCss = RegExp(r'[{}<>@\\]|url\(|/\*', caseSensitive: false);
final RegExp _cssDeclaration = RegExp(
  r'^-?[a-z][a-z-]*\s*:\s*\S',
  caseSensitive: false,
);

/// A `$1`-style reference to a capture group in a route target.
final RegExp groupReference = RegExp(r'\$(\d)');

class RulesFormatException implements Exception {
  RulesFormatException(this.message);

  final String message;

  @override
  String toString() => 'Invalid rules: $message';
}

enum RouteAction { block, redirect }

/// How the WebView identifies itself.
enum UserAgentMode {
  /// Like the phone's own browser, without the WebView markers that sites use
  /// to push their app or change behaviour.
  browser,

  /// The WebView's default user agent.
  system,
}

/// Filter rules for one site, from `assets/rules/<platform>.json` or a
/// downloaded update.
///
/// Rules are data only: URL patterns, CSS selectors and text labels, applied
/// by the bundled engine in `assets/js/lite_engine.js`. See docs/RULES.md.
class SiteRules {
  SiteRules({
    required this.platform,
    required this.revision,
    required this.startUrl,
    required this.hosts,
    required this.allowedHosts,
    required this.linkShims,
    required this.userAgent,
    required this.features,
    this.updated,
    this.session,
    this.signIn,
    this.popstateNavigation = false,
  });

  factory SiteRules.parse(String source) {
    final Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException catch (e) {
      throw RulesFormatException('not valid JSON (${e.message})');
    }
    if (json is! Map<String, dynamic>) {
      throw RulesFormatException('expected a JSON object');
    }
    return SiteRules.fromJson(json);
  }

  factory SiteRules.fromJson(Map<String, dynamic> json) {
    final r = _Reader(json, '');
    final schemaVersion = r.integer('schemaVersion');
    if (schemaVersion != supportedSchemaVersion) {
      throw RulesFormatException(
        'schemaVersion $schemaVersion is not supported '
        '(this app reads $supportedSchemaVersion)',
      );
    }

    final hosts = r.strings('hosts').map((h) => h.toLowerCase()).toList();
    if (hosts.isEmpty) throw RulesFormatException('hosts: must not be empty');

    final startUrl = Uri.tryParse(r.string('startUrl'));
    if (startUrl == null ||
        startUrl.scheme != 'https' ||
        !hosts.contains(startUrl.host)) {
      throw RulesFormatException(
        'startUrl: must be an https URL on one of hosts',
      );
    }

    final revision = r.integer('revision');
    if (revision < 1) throw RulesFormatException('revision: must be 1 or more');

    final allowedHosts = r
        .strings('allowedHosts', required: false)
        .map((h) => h.toLowerCase())
        .toList();
    final sessionJson = r.optionalObject('session');
    final session = sessionJson == null
        ? null
        : Session._fromJson(_Reader(sessionJson, 'session.'));
    final signInJson = r.optionalObject('signIn');
    final signIn = signInJson == null
        ? null
        : SignIn._fromJson(_Reader(signInJson, 'signIn.'));
    if (signIn != null && session == null) {
      throw RulesFormatException('signIn: needs session');
    }

    final features = [
      for (final (i, f) in r.objects('features').indexed)
        Feature._fromJson(_Reader(f, 'features[$i].')),
    ];
    final ids = <String>{};
    for (final feature in features) {
      if (!ids.add(feature.id)) {
        throw RulesFormatException('features: duplicate id "${feature.id}"');
      }
      if (session == null && feature.routes.any((r) => r.signedOut)) {
        throw RulesFormatException(
          'features: "${feature.id}" has signedOut routes, which need session',
        );
      }
    }

    return SiteRules(
      platform: r.string('platform'),
      revision: revision,
      updated: r.optionalString('updated'),
      startUrl: startUrl,
      hosts: hosts,
      allowedHosts: allowedHosts,
      linkShims: [
        for (final (i, s) in r.objects('linkShims', required: false).indexed)
          LinkShim._fromJson(_Reader(s, 'linkShims[$i].')),
      ],
      userAgent: r.enumValue(
        'userAgent',
        UserAgentMode.values,
        fallback: UserAgentMode.browser,
      ),
      features: features,
      session: session,
      signIn: signIn,
      popstateNavigation: r.flag('popstateNavigation'),
    );
  }

  final String platform;

  /// Increases with every published change. The app keeps whichever of the
  /// bundled and downloaded rules has the higher revision.
  final int revision;
  final String? updated;
  final Uri startUrl;

  /// Hosts that serve the site itself. Filters and route rules apply here.
  final List<String> hosts;

  /// Other hosts allowed to load inside the app (login, account settings).
  /// Everything else opens in the system browser.
  final List<String> allowedHosts;

  /// Redirect services that wrap outbound links. The app unwraps them and
  /// opens the destination directly.
  final List<LinkShim> linkShims;
  final UserAgentMode userAgent;
  final List<Feature> features;

  /// How to tell whether the user is signed in, for sites with routes that
  /// only apply signed out.
  final Session? session;

  /// Where signed-out users are sent, so they sign in before using the site.
  final SignIn? signIn;

  /// Whether the site's router renders the URL it finds on a popstate event,
  /// so the engine can navigate inside the page by pushing a URL and firing
  /// one. Otherwise it loads the page in full when it has no link to click.
  final bool popstateNavigation;

  /// Whether the user is signed in, given the cookies set for the site, by
  /// name and value. Sites without a [session] count as signed in.
  bool isSignedIn(Map<String, String> cookies) =>
      session == null || session!.isSignedIn(cookies);

  bool isSiteHost(String host) => hosts.contains(host.toLowerCase());

  bool isAllowedHost(String host) => allowedHosts.contains(host.toLowerCase());
}

/// How to tell whether the user is signed in to a site: any of [cookies] is
/// set for its start URL, unless it is one of [anonymousTokens].
///
/// The app reads the WebView's cookie store, which includes HttpOnly cookies,
/// and passes its answer to the page engine, so the cookies can be ones page
/// scripts can't read.
class Session {
  Session({required this.cookies, this.anonymousTokens = const []});

  factory Session._fromJson(_Reader r) {
    final cookies = r.strings('cookies');
    if (cookies.isEmpty) {
      throw RulesFormatException('${r.path}cookies: must not be empty');
    }
    final anonymousTokens = [
      for (final (i, t)
          in r.objects('anonymousTokens', required: false).indexed)
        AnonymousToken._fromJson(_Reader(t, '${r.path}anonymousTokens[$i].')),
    ];
    for (final token in anonymousTokens) {
      if (!cookies.contains(token.cookie)) {
        throw RulesFormatException(
          '${r.path}anonymousTokens: "${token.cookie}" is not one of cookies',
        );
      }
    }
    return Session(cookies: cookies, anonymousTokens: anonymousTokens);
  }

  final List<String> cookies;

  /// Session cookies the site also sets for visitors who aren't signed in.
  final List<AnonymousToken> anonymousTokens;

  bool isSignedIn(Map<String, String> cookies) => this.cookies.any((name) {
    final value = cookies[name];
    return value != null &&
        !anonymousTokens.any((t) => t.cookie == name && t.matches(value));
  });
}

/// A session cookie holding a JSON Web Token that the site sets for every
/// visitor, signed in or not. The token is a visitor's while its payload's
/// [claim] is [value]: Reddit's `token_v2` has `"sub": "loid"` until you
/// sign in.
class AnonymousToken {
  AnonymousToken({
    required this.cookie,
    required this.claim,
    required this.value,
  });

  factory AnonymousToken._fromJson(_Reader r) => AnonymousToken(
    cookie: r.string('cookie'),
    claim: r.string('claim'),
    value: r.string('value'),
  );

  final String cookie;
  final String claim;
  final String value;

  /// Whether [token] is a visitor's token. A cookie that isn't a JSON Web
  /// Token doesn't count as one, so a change in the site's tokens can't
  /// lock signed-in users out.
  bool matches(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return false;
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      return payload is Map && payload[claim] == value;
    } on FormatException {
      return false;
    }
  }
}

/// Sends signed-out users to the site's sign-in page: while the user is
/// signed out, every page whose path and query match [match] goes to [to].
/// [match] must leave out the pages that signing in needs, such as the
/// sign-in page itself, signing up and resetting a password.
///
/// Always on, and ahead of the features' routes, so a filter switched off
/// in Settings can't let a signed-out user through.
class SignIn {
  SignIn({required this.match, required this.to});

  factory SignIn._fromJson(_Reader r) {
    final match = r.pattern('match');
    final to = r.string('to');
    if (!to.startsWith('/')) {
      throw RulesFormatException('${r.path}to: must start with /');
    }
    if (RegExp(match).hasMatch(to)) {
      throw RulesFormatException('${r.path}match: must not match to');
    }
    return SignIn(match: match, to: to);
  }

  final String match;
  final String to;
}

/// A user-facing filter the user can switch on or off in Settings.
class Feature {
  Feature({
    required this.id,
    required this.title,
    required this.description,
    required this.enabledByDefault,
    this.routes = const [],
    this.hide = const [],
    this.style = const [],
    this.hideByText = const [],
    this.prune = const [],
    this.keep = const [],
  });

  factory Feature._fromJson(_Reader r) {
    final id = r.string('id');
    if (!_featureId.hasMatch(id)) {
      throw RulesFormatException(
        '${r.path}id: use only letters, digits, _ and -',
      );
    }
    return Feature(
      id: id,
      title: r.string('title'),
      description: r.optionalString('description') ?? '',
      enabledByDefault: r.boolean('enabledByDefault'),
      routes: [
        for (final (i, o) in r.objects('routes', required: false).indexed)
          RouteRule._fromJson(_Reader(o, '${r.path}routes[$i].')),
      ],
      hide: [
        for (final (i, o) in r.objects('hide', required: false).indexed)
          HideRule._fromJson(_Reader(o, '${r.path}hide[$i].')),
      ],
      style: [
        for (final (i, o) in r.objects('style', required: false).indexed)
          StyleRule._fromJson(_Reader(o, '${r.path}style[$i].')),
      ],
      hideByText: [
        for (final (i, o) in r.objects('hideByText', required: false).indexed)
          TextHideRule._fromJson(_Reader(o, '${r.path}hideByText[$i].')),
      ],
      prune: [
        for (final (i, o) in r.objects('prune', required: false).indexed)
          PruneRule._fromJson(_Reader(o, '${r.path}prune[$i].')),
      ],
      keep: [
        for (final (i, o) in r.objects('keep', required: false).indexed)
          KeepRule._fromJson(_Reader(o, '${r.path}keep[$i].')),
      ],
    );
  }

  final String id;
  final String title;
  final String description;
  final bool enabledByDefault;
  final List<RouteRule> routes;
  final List<HideRule> hide;
  final List<StyleRule> style;
  final List<TextHideRule> hideByText;
  final List<PruneRule> prune;
  final List<KeepRule> keep;
}

/// Sends navigation to a matching path somewhere else.
///
/// [match] is tested against the path plus query string, such as
/// `/explore/?x=1`. A `block` shows the user a notice; a `redirect` is
/// silent. [to] can use `$1` to `$9` for [match]'s capture groups, as in
/// `/shorts/(\w+)` → `/watch?v=$1`. With [signedOut], the rule only applies
/// while the user isn't signed in (see [SiteRules.session]).
class RouteRule {
  RouteRule({
    required this.match,
    required this.action,
    required this.to,
    this.label,
    this.signedOut = false,
  });

  factory RouteRule._fromJson(_Reader r) {
    final match = r.pattern('match');
    final to = r.string('to');
    if (!to.startsWith('/')) {
      throw RulesFormatException('${r.path}to: must start with /');
    }
    // The empty alternative always matches, which reveals the group count.
    final groups = RegExp('(?:$match)|').firstMatch('')!.groupCount;
    for (final reference in groupReference.allMatches(to)) {
      if (int.parse(reference[1]!) > groups) {
        throw RulesFormatException(
          '${r.path}to: ${reference[0]} refers to a group that match '
          'doesn\'t have',
        );
      }
    }
    return RouteRule(
      match: match,
      action: r.enumValue('action', RouteAction.values),
      to: to,
      label: r.optionalString('label'),
      signedOut: r.flag('signedOut'),
    );
  }

  final String match;
  final RouteAction action;
  final String to;
  final String? label;
  final bool signedOut;
}

/// Hides every element matching [selector]. With [paths], only on pages whose
/// path and query match that pattern.
class HideRule {
  HideRule({required this.selector, this.paths, this.collapse = false});

  factory HideRule._fromJson(_Reader r) => HideRule(
    selector: r.string('selector'),
    paths: r.optionalPattern('paths'),
    collapse: r.flag('collapse'),
  );

  final String selector;
  final String? paths;

  /// Leaves the element in the page as an empty box of zero height instead
  /// of removing it. Posts in a feed need this: the feed measures each post
  /// against the next one, and a removed post breaks its scrolling.
  final bool collapse;
}

/// Applies CSS declarations such as `transform: none` to every element
/// matching [selector], each with `!important`; with [paths], only on those
/// pages. For layout fixes a hide rule can't make. The declarations can only
/// style: nothing that could close the rule or load a URL.
class StyleRule {
  StyleRule({required this.selector, required this.css, this.paths});

  factory StyleRule._fromJson(_Reader r) {
    final css = r.string('css');
    final declarations = [
      for (final d in css.split(';'))
        if (d.trim().isNotEmpty) d.trim(),
    ];
    if (_unsafeCss.hasMatch(css) ||
        declarations.isEmpty ||
        !declarations.every(_cssDeclaration.hasMatch)) {
      throw RulesFormatException(
        '${r.path}css: use declarations such as "transform: none"',
      );
    }
    return StyleRule(
      selector: r.string('selector'),
      css: css,
      paths: r.optionalPattern('paths'),
    );
  }

  final String selector;
  final String css;
  final String? paths;
}

/// Hides the nearest [container] around a [marker] element whose whole text
/// is one of [text] or matches [pattern], for things with no stable selector
/// (such as the "Sponsored" label on ads).
class TextHideRule {
  TextHideRule({
    required this.container,
    required this.marker,
    this.text = const [],
    this.pattern,
    this.paths,
    this.collapse = false,
  });

  factory TextHideRule._fromJson(_Reader r) {
    final text = r.strings('text', required: false);
    final pattern = r.optionalPattern('pattern');
    if (text.isEmpty && pattern == null) {
      throw RulesFormatException('${r.path}text: needs text or a pattern');
    }
    return TextHideRule(
      container: r.string('container'),
      marker: r.string('marker'),
      text: text,
      pattern: pattern,
      paths: r.optionalPattern('paths'),
      collapse: r.flag('collapse'),
    );
  }

  final String container;
  final String marker;
  final List<String> text;

  /// Tested against the marker's text with whitespace collapsed and trimmed.
  final String? pattern;
  final String? paths;

  /// Collapses the container instead of removing it, as [HideRule.collapse].
  final bool collapse;
}

/// Deletes data from the site's JSON before the page renders it, such as
/// story ads injected into API responses.
///
/// [path] is property names joined by dots. `[]` means every element of an
/// array, and `[-]` removes the array elements in which the rest of the path
/// exists: `data.feed.edges.[-].node.ad` drops every ad edge.
///
/// With [global], the rule applies to the value the page assigns to that
/// global variable instead of to JSON, for data a page embeds as a script
/// (such as YouTube's `ytInitialPlayerResponse`).
class PruneRule {
  PruneRule({required this.path, this.global});

  factory PruneRule._fromJson(_Reader r) {
    final path = r.string('path');
    final segments = path.split('.');
    if (segments.any((s) => s.isEmpty) ||
        segments.last == '[]' ||
        segments.last == '[-]') {
      throw RulesFormatException(
        '${r.path}path: use property names joined by dots, ending in a name',
      );
    }
    final global = r.optionalString('global');
    if (global != null && !_identifier.hasMatch(global)) {
      throw RulesFormatException(
        '${r.path}global: must be a JavaScript variable name',
      );
    }
    return PruneRule(path: path, global: global);
  }

  final String path;
  final String? global;
}

/// Puts back a site's tab bar on pages where the site drops it, such as
/// Instagram's in messages. While a page shows an element matching [marker],
/// the engine remembers the fixed-position bar around it; on pages whose path
/// and query match [paths], if the marker is gone, it shows a copy of that
/// bar, whose links it navigates for.
class KeepRule {
  KeepRule({required this.marker, required this.paths});

  factory KeepRule._fromJson(_Reader r) =>
      KeepRule(marker: r.string('marker'), paths: r.pattern('paths'));

  final String marker;
  final String paths;
}

/// An outbound-link redirector such as `l.instagram.com/?u=<destination>`.
///
/// With [path], only that path on [host] is a redirector, for sites that
/// redirect from their own host, such as `www.youtube.com/redirect?q=`.
class LinkShim {
  LinkShim({required this.host, required this.param, this.path});

  factory LinkShim._fromJson(_Reader r) {
    final path = r.optionalString('path');
    if (path != null && !path.startsWith('/')) {
      throw RulesFormatException('${r.path}path: must start with /');
    }
    return LinkShim(
      host: r.string('host').toLowerCase(),
      param: r.string('param'),
      path: path,
    );
  }

  final String host;
  final String param;
  final String? path;

  bool matches(Uri url) =>
      url.host.toLowerCase() == host && (path == null || url.path == path);
}

/// Reads typed fields and reports errors with the field's path.
class _Reader {
  _Reader(this._json, this.path);

  final Map<String, dynamic> _json;
  final String path;

  Never _fail(String key, String problem) =>
      throw RulesFormatException('$path$key: $problem');

  String string(String key) {
    final value = _json[key];
    if (value is String && value.trim().isNotEmpty) return value;
    _fail(key, 'expected a non-empty string');
  }

  String? optionalString(String key) => _json[key] == null ? null : string(key);

  int integer(String key) {
    final value = _json[key];
    if (value is int) return value;
    _fail(key, 'expected an integer');
  }

  bool boolean(String key) {
    final value = _json[key];
    if (value is bool) return value;
    _fail(key, 'expected true or false');
  }

  /// An optional boolean, false when missing.
  bool flag(String key) => _json[key] != null && boolean(key);

  List<String> strings(String key, {bool required = true}) {
    final value = _json[key];
    if (value == null && !required) return const [];
    if (value is List && value.every((e) => e is String && e.isNotEmpty)) {
      return value.cast<String>();
    }
    _fail(key, 'expected a list of non-empty strings');
  }

  Map<String, dynamic>? optionalObject(String key) {
    final value = _json[key];
    if (value == null) return null;
    if (value is Map<String, dynamic>) return value;
    _fail(key, 'expected an object');
  }

  List<Map<String, dynamic>> objects(String key, {bool required = true}) {
    final value = _json[key];
    if (value == null && !required) return const [];
    if (value is List && value.every((e) => e is Map<String, dynamic>)) {
      return value.cast<Map<String, dynamic>>();
    }
    _fail(key, 'expected a list of objects');
  }

  T enumValue<T extends Enum>(String key, List<T> values, {T? fallback}) {
    final value = _json[key];
    if (value == null && fallback != null) return fallback;
    for (final v in values) {
      if (v.name == value) return v;
    }
    _fail(key, 'expected one of ${values.map((v) => v.name).join(', ')}');
  }

  /// A regular expression source. Dart and JavaScript share the ECMAScript
  /// syntax, so a pattern that compiles here also runs in the engine.
  String pattern(String key) {
    final source = string(key);
    try {
      RegExp(source);
    } on FormatException catch (e) {
      _fail(key, 'invalid pattern (${e.message})');
    }
    return source;
  }

  String? optionalPattern(String key) =>
      _json[key] == null ? null : pattern(key);
}
