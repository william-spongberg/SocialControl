/// Build-time settings.
library;

const String appName = 'SocialControl';

/// Where rule updates are downloaded from: a folder URL holding one rules
/// file per site, named as in assets/rules/ (instagram.json, youtube.json).
/// Empty disables downloads, so the app uses its bundled rules until the
/// next release. Set it when building:
///
///     flutter run --dart-define=RULES_BASE_URL=https://example.com/rules/
///
/// Point it at a copy of assets/rules/ that you can update without a
/// release, such as a raw GitHub URL. See docs/RULES.md.
const String rulesBaseUrl = String.fromEnvironment('RULES_BASE_URL');

const String engineAsset = 'assets/js/lite_engine.js';

/// The published rules file for [platform], or null if this build has no
/// rules URL.
Uri? rulesUrlFor(String platform, {String base = rulesBaseUrl}) {
  if (base.isEmpty) return null;
  final folder = base.endsWith('/') ? base : '$base/';
  return Uri.parse(folder).resolve('$platform.json');
}
