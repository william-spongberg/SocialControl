import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_control/src/rules/rules_repository.dart';
import 'package:social_control/src/settings/settings_store.dart';
import 'package:social_control/src/site.dart';
import 'package:social_control/src/ui/site_picker.dart';

import 'helpers.dart';

void main() {
  testWidgets('SitePicker lists the sites and opens the one tapped', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final sites = <Site>[];
    for (final info in siteCatalog) {
      final rules = RulesRepository(
        prefs: prefs,
        loadBundled: () async => rulesJson(platform: info.platform),
        remoteUrl: null,
      );
      await rules.load();
      sites.add(
        Site(
          info: info,
          rules: rules,
          settings: SettingsStore(prefs, info.platform),
        ),
      );
    }
    final picked = <int>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SitePicker(sites: sites, onPick: picked.add),
        ),
      ),
    );

    expect(find.text('Instagram'), findsOneWidget);
    expect(find.text('YouTube'), findsOneWidget);
    expect(find.text('Reddit'), findsOneWidget);
    expect(find.text('TikTok'), findsOneWidget);
    // The helper rules have two filters, both on by default.
    expect(find.text('2 of 2 filters on'), findsNWidgets(4));

    await tester.tap(find.text('YouTube'));
    expect(picked, [1]);
  });
}
