import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:social_control/src/rules/rules_repository.dart';
import 'package:social_control/src/rules/site_rules.dart';
import 'package:social_control/src/settings/settings_store.dart';
import 'package:social_control/src/site.dart';
import 'package:social_control/src/ui/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

void main() {
  late SharedPreferences prefs;
  final rules = SiteRules.parse(rulesJson());
  Feature feature(String id) => rules.features.firstWhere((f) => f.id == id);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  group('SettingsStore', () {
    test('follows the rules\' defaults until the user chooses', () async {
      final settings = SettingsStore(prefs, 'instagram');
      expect(settings.enabledFeatures(rules), {'hideReels', 'followingFeed'});

      await settings.setEnabled(feature('hideReels'), false);
      expect(settings.enabledFeatures(rules), {'followingFeed'});
      expect(
        SettingsStore(prefs, 'instagram').isEnabled(feature('hideReels')),
        isFalse,
      );
    });

    test('keeps each site\'s choices separately', () async {
      await SettingsStore(
        prefs,
        'instagram',
      ).setEnabled(feature('hideReels'), false);
      expect(
        SettingsStore(prefs, 'youtube').isEnabled(feature('hideReels')),
        isTrue,
      );
    });

    test('notifies listeners of changes', () async {
      final settings = SettingsStore(prefs, 'instagram');
      var notified = 0;
      settings.addListener(() => notified++);
      await settings.setEnabled(feature('hideReels'), false);
      expect(notified, 1);
    });
  });

  testWidgets('SettingsScreen lists filters from the rules and toggles them', (
    tester,
  ) async {
    final repo = RulesRepository(
      prefs: prefs,
      loadBundled: () async => rulesJson(),
      remoteUrl: null,
    );
    await repo.load();
    final settings = SettingsStore(prefs, 'instagram');

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          site: Site(info: siteCatalog.first, rules: repo, settings: settings),
          readDiagnostics: () async => null,
          clearSiteData: () async {},
        ),
      ),
    );

    expect(find.text('Instagram settings'), findsOneWidget);
    expect(find.text('Hide Reels'), findsOneWidget);
    expect(find.text('This build has no rules URL'), findsOneWidget);
  });
}
