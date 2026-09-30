import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rules/site_rules.dart';

/// The user's filter choices for one site, keyed by feature id.
///
/// Only features the user has switched are stored. The rest follow the
/// rules' `enabledByDefault`, so a rules update can change a default for
/// anyone who hasn't picked one.
class SettingsStore extends ChangeNotifier {
  SettingsStore(this._prefs, this.platform);

  final SharedPreferences _prefs;

  /// The site these choices are for. Feature ids are only unique per site.
  final String platform;

  String _key(String featureId) => 'feature.$platform.$featureId';

  bool isEnabled(Feature feature) =>
      _prefs.getBool(_key(feature.id)) ?? feature.enabledByDefault;

  Set<String> enabledFeatures(SiteRules rules) => {
    for (final feature in rules.features)
      if (isEnabled(feature)) feature.id,
  };

  Future<void> setEnabled(Feature feature, bool enabled) async {
    await _prefs.setBool(_key(feature.id), enabled);
    notifyListeners();
  }
}
