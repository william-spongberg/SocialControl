import 'site_rules.dart';

/// A route rule from an enabled feature, ready to match.
class ActiveRoute {
  ActiveRoute({
    required this.id,
    required this.match,
    required this.action,
    required this.to,
    required this.label,
    this.signedOut = false,
  }) : _pattern = RegExp(match);

  final String id;
  final String match;
  final RouteAction action;

  /// The target path. `$1` to `$9` stand for [match]'s capture groups.
  final String to;

  /// Shown when the route is blocked, e.g. "Reels blocked".
  final String label;

  /// Whether the route only applies while the user isn't signed in.
  final bool signedOut;
  final RegExp _pattern;

  /// Where this route sends [path], or null if it doesn't match. A group
  /// that didn't take part in the match, or doesn't exist, becomes empty.
  String? targetFor(String path) {
    final match = _pattern.firstMatch(path);
    if (match == null) return null;
    return to.replaceAllMapped(groupReference, (reference) {
      final group = int.parse(reference[1]!);
      return group <= match.groupCount ? match.group(group) ?? '' : '';
    });
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'match': match,
    'action': action.name,
    'to': to,
    'label': label,
    'signedOut': signedOut,
  };
}

class Resolution {
  const Resolution(this.path, {this.changed = false, this.blockedLabel});

  /// Where navigation should end up.
  final String path;

  /// Whether [path] differs from the requested path.
  final bool changed;

  /// Set if a block rule was hit on the way.
  final String? blockedLabel;
}

/// Decides where a path navigates to under the active route rules.
///
/// Keep in sync with `resolve` in assets/js/lite_engine.js: the app uses this
/// for full page loads and the engine for in-page navigation, so both must
/// agree. test/fixtures/route_cases.json runs against both.
class RouteResolver {
  RouteResolver(this.routes);

  /// Follows at most this many rules, so a cycle in the rules can't hang.
  static const maxHops = 5;

  final List<ActiveRoute> routes;

  /// Where [path] ends up. Routes marked signedOut only apply when
  /// [signedIn] is false.
  Resolution resolve(String path, {bool signedIn = true}) {
    var current = path;
    var changed = false;
    String? blockedLabel;
    for (var hop = 0; hop < maxHops; hop++) {
      ActiveRoute? rule;
      String? target;
      for (final route in routes) {
        if (route.signedOut && signedIn) continue;
        target = route.targetFor(current);
        if (target != null) {
          rule = route;
          break;
        }
      }
      if (rule == null || target == null || target == current) break;
      if (rule.action == RouteAction.block) blockedLabel ??= rule.label;
      current = target;
      changed = true;
    }
    return Resolution(current, changed: changed, blockedLabel: blockedLabel);
  }
}

/// The path and query of [uri] as route rules see it: `/explore/?q=1`.
String routePath(Uri uri) {
  final path = uri.path.isEmpty ? '/' : uri.path;
  return uri.hasQuery ? '$path?${uri.query}' : path;
}
