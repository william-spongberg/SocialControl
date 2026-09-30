import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'site_rules.dart';

enum RulesSource { bundled, downloaded }

enum RulesUpdateStatus {
  updated,
  upToDate,

  /// Skipped because the last check was recent.
  skipped,

  /// This build has no rules URL.
  notConfigured,
  failed,
}

/// Provides one site's current rules: the bundled copy, or a newer
/// downloaded one.
///
/// Downloads are validated before use and kept only if their revision is
/// higher, so a bad or stale file on the server never replaces working
/// rules.
class RulesRepository extends ChangeNotifier {
  RulesRepository({
    required SharedPreferences prefs,
    required Future<String> Function() loadBundled,
    required this.remoteUrl,
    http.Client? client,
    DateTime Function()? clock,
    this.checkInterval = const Duration(hours: 6),
  }) : _prefs = prefs,
       _loadBundled = loadBundled,
       _client = client ?? http.Client(),
       _clock = clock ?? DateTime.now;

  static const _timeout = Duration(seconds: 15);

  final SharedPreferences _prefs;
  final Future<String> Function() _loadBundled;
  final http.Client _client;
  final DateTime Function() _clock;

  /// Where updates come from. Null disables updates.
  final Uri? remoteUrl;
  final Duration checkInterval;

  late SiteRules _bundled;
  late SiteRules _rules;
  RulesSource _source = RulesSource.bundled;
  String? _lastError;

  // Per site, so each site's download is kept separately. The platform
  // comes from the bundled rules, which load first.
  String get _cacheKey => 'rules.${_bundled.platform}.cache';
  String get _lastCheckedKey => 'rules.${_bundled.platform}.lastChecked';

  SiteRules get rules => _rules;
  RulesSource get source => _source;

  /// Why the last update check failed, if it did.
  String? get lastError => _lastError;

  DateTime? get lastChecked {
    final millis = _prefs.getInt(_lastCheckedKey);
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  /// Loads the bundled rules and any cached download. Throws only if the
  /// bundled rules are invalid, which the tests guard against.
  Future<void> load() async {
    _bundled = SiteRules.parse(await _loadBundled());
    _rules = _bundled;
    _source = RulesSource.bundled;

    final cached = _prefs.getString(_cacheKey);
    if (cached == null) return;
    try {
      final rules = SiteRules.parse(cached);
      if (_accepts(rules)) {
        _rules = rules;
        _source = RulesSource.downloaded;
      }
    } on RulesFormatException catch (e) {
      // Written by an older app version, or with a schema this build
      // doesn't read. The bundled rules are the fallback.
      debugPrint('Ignoring cached rules: $e');
      await _prefs.remove(_cacheKey);
    }
  }

  /// Downloads the rules and switches to them if they are newer.
  ///
  /// Checks at most once per [checkInterval] unless [force] is set.
  Future<RulesUpdateStatus> checkForUpdates({bool force = false}) async {
    final url = remoteUrl;
    if (url == null) return RulesUpdateStatus.notConfigured;
    final last = lastChecked;
    if (!force && last != null && _clock().difference(last) < checkInterval) {
      return RulesUpdateStatus.skipped;
    }

    try {
      final response = await _client
          .get(
            url,
            headers: const {
              'Accept': 'application/json',
              'Cache-Control': 'no-cache',
            },
          )
          .timeout(_timeout);
      if (response.statusCode != 200) {
        throw http.ClientException('HTTP ${response.statusCode}', url);
      }
      // Decode as UTF-8 whatever the server claims; rules contain non-ASCII
      // labels such as "Sponsorisé".
      final body = utf8.decode(response.bodyBytes);
      final rules = SiteRules.parse(body);
      if (rules.platform != _bundled.platform) {
        throw RulesFormatException(
          'rules are for ${rules.platform}, not ${_bundled.platform}',
        );
      }

      await _prefs.setInt(_lastCheckedKey, _clock().millisecondsSinceEpoch);
      _lastError = null;
      if (rules.revision <= _rules.revision) {
        notifyListeners();
        return RulesUpdateStatus.upToDate;
      }
      await _prefs.setString(_cacheKey, body);
      _rules = rules;
      _source = RulesSource.downloaded;
      notifyListeners();
      return RulesUpdateStatus.updated;
    } on Exception catch (e) {
      // Covers network errors, timeouts and invalid rules.
      _lastError = e.toString();
      notifyListeners();
      return RulesUpdateStatus.failed;
    }
  }

  /// Drops downloaded rules and goes back to the bundled ones.
  Future<void> useBundled() async {
    await _prefs.remove(_cacheKey);
    await _prefs.remove(_lastCheckedKey);
    _rules = _bundled;
    _source = RulesSource.bundled;
    notifyListeners();
  }

  /// A download is only worth using if it beats the bundled rules. An app
  /// update can ship bundled rules newer than the cache.
  bool _accepts(SiteRules rules) =>
      rules.platform == _bundled.platform && rules.revision > _bundled.revision;
}
