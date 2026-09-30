import 'package:flutter/material.dart';

import 'rules/rules_repository.dart';
import 'settings/settings_store.dart';

/// A site the app can show. Its filters are in `assets/rules/<platform>.json`.
class SiteInfo {
  const SiteInfo({
    required this.platform,
    required this.name,
    required this.icon,
  });

  /// Names the rules file, and matches the file's `platform` field.
  final String platform;
  final String name;
  final IconData icon;

  String get rulesAsset => 'assets/rules/$platform.json';
}

/// The sites in the app, in the order the site picker lists them.
const List<SiteInfo> siteCatalog = [
  SiteInfo(
    platform: 'instagram',
    name: 'Instagram',
    icon: Icons.photo_camera_outlined,
  ),
  SiteInfo(
    platform: 'youtube',
    name: 'YouTube',
    icon: Icons.smart_display_outlined,
  ),
  SiteInfo(platform: 'reddit', name: 'Reddit', icon: Icons.forum_outlined),
];

/// A site with its rules and the user's filter choices for it.
class Site {
  const Site({required this.info, required this.rules, required this.settings});

  final SiteInfo info;
  final RulesRepository rules;
  final SettingsStore settings;

  /// How many of the site's filters are on, and how many there are.
  ({int on, int total}) get filterCount {
    final features = rules.rules.features;
    return (
      on: features.where(settings.isEnabled).length,
      total: features.length,
    );
  }
}
