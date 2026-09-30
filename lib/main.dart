import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/app.dart';
import 'src/config.dart';
import 'src/rules/rules_repository.dart';
import 'src/settings/settings_store.dart';
import 'src/site.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final sites = [
    for (final info in siteCatalog)
      Site(
        info: info,
        rules: RulesRepository(
          prefs: prefs,
          loadBundled: () => rootBundle.loadString(info.rulesAsset),
          remoteUrl: rulesUrlFor(info.platform),
        ),
        settings: SettingsStore(prefs, info.platform),
      ),
  ];
  await Future.wait([for (final site in sites) site.rules.load()]);

  runApp(
    SocialControlApp(
      sites: sites,
      engineSource: await rootBundle.loadString(engineAsset),
      defaultUserAgent: await _defaultUserAgent(),
    ),
  );

  for (final site in sites) {
    unawaited(site.rules.checkForUpdates());
  }
}

Future<String?> _defaultUserAgent() async {
  try {
    return await InAppWebViewController.getDefaultUserAgent();
  } catch (e) {
    // Unsupported on this platform; the WebView keeps its own user agent.
    debugPrint('No default user agent: $e');
    return null;
  }
}
