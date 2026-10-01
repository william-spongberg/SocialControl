import 'dart:convert';

import '../rules/route_resolver.dart';
import '../rules/site_rules.dart';

/// The rules of the enabled features, flattened into the form the page
/// engine (assets/js/lite_engine.js) and the app's navigation policy use.
class EngineConfig {
  EngineConfig._(this.routes, this._json);

  /// [signedIn] is whether the app found the user signed in, if it has
  /// looked. The engine can't tell when the session cookies are HttpOnly.
  factory EngineConfig.build(
    SiteRules rules,
    Set<String> enabledFeatures, {
    bool? signedIn,
  }) {
    final routes = <ActiveRoute>[];
    final hide = <Map<String, Object?>>[];
    final style = <Map<String, Object?>>[];
    final hideByText = <Map<String, Object?>>[];
    final prune = <Map<String, Object?>>[];
    final keep = <Map<String, Object?>>[];

    for (final feature in rules.features) {
      if (!enabledFeatures.contains(feature.id)) continue;
      for (final (i, r) in feature.routes.indexed) {
        routes.add(
          ActiveRoute(
            id: '${feature.id}/route$i',
            match: r.match,
            action: r.action,
            to: r.to,
            label: r.label ?? feature.title,
            signedOut: r.signedOut,
          ),
        );
      }
      for (final (i, h) in feature.hide.indexed) {
        hide.add({
          'id': '${feature.id}/hide$i',
          'selector': h.selector,
          'paths': h.paths,
          'collapse': h.collapse,
        });
      }
      for (final (i, r) in feature.style.indexed) {
        style.add({
          'id': '${feature.id}/style$i',
          'selector': r.selector,
          'css': r.css,
          'paths': r.paths,
        });
      }
      for (final (i, t) in feature.hideByText.indexed) {
        hideByText.add({
          'id': '${feature.id}/text$i',
          'container': t.container,
          'marker': t.marker,
          'text': t.text,
          'pattern': t.pattern,
          'paths': t.paths,
          'collapse': t.collapse,
        });
      }
      for (final (i, k) in feature.keep.indexed) {
        keep.add({
          'id': '${feature.id}/keep$i',
          'marker': k.marker,
          'paths': k.paths,
        });
      }
      for (final (i, p) in feature.prune.indexed) {
        prune.add({
          'id': '${feature.id}/prune$i',
          'path': p.path,
          'global': p.global,
        });
      }
    }

    return EngineConfig._(routes, {
      'hosts': rules.hosts,
      'popstateNavigation': rules.popstateNavigation,
      'session': rules.session?.cookies,
      'signedIn': signedIn,
      'routes': [for (final r in routes) r.toJson()],
      'hide': hide,
      'style': style,
      'hideByText': hideByText,
      'prune': prune,
      'keep': keep,
    });
  }

  final List<ActiveRoute> routes;
  final Map<String, Object?> _json;

  late final RouteResolver resolver = RouteResolver(routes);

  String get json => jsonEncode(_json);

  /// The document-start script: the engine source plus a call with this
  /// config. JSON is valid JavaScript, so it is embedded as a literal.
  String userScript(String engineSource) =>
      '(function () {\n$engineSource\nliteEngine($json);\n})();';

  /// Applies this config to the page that is already open.
  String get updateScript =>
      'window.__liteEngine && window.__liteEngine.update($json);';
}
