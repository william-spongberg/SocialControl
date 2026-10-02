import 'package:flutter/material.dart';

import '../rules/rules_repository.dart';
import '../settings/settings_store.dart';
import '../site.dart';

/// One site's filter switches, rule updates and diagnostics, and logging
/// out of every site.
///
/// The filter list comes from the site's rules file, so a rules update can
/// add or reword filters without an app release.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.site,
    required this.readDiagnostics,
    required this.clearSiteData,
  });

  final Site site;

  /// Reads the engine's per-rule stats from the open page, or null if the
  /// engine isn't running there.
  final Future<Map<String, dynamic>?> Function() readDiagnostics;

  /// Logs out of every site in the app.
  final Future<void> Function() clearSiteData;

  RulesRepository get rules => site.rules;
  SettingsStore get settings => site.settings;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([rules, settings]),
      builder: (context, _) {
        final current = rules.rules;
        final canUpdate = rules.remoteUrl != null;
        return Scaffold(
          appBar: AppBar(title: Text('${site.info.name} settings')),
          body: ListView(
            children: [
              const _SectionHeader('Filters'),
              for (final feature in current.features)
                SwitchListTile(
                  title: Text(feature.title),
                  subtitle: feature.description.isEmpty
                      ? null
                      : Text(feature.description),
                  value: settings.isEnabled(feature),
                  onChanged: (enabled) => settings.setEnabled(feature, enabled),
                ),
              const Divider(),
              const _SectionHeader('Filter rules'),
              ListTile(
                leading: const Icon(Icons.rule),
                title: Text('Revision ${current.revision}'),
                subtitle: Text(_rulesSummary(context)),
              ),
              ListTile(
                leading: const Icon(Icons.sync),
                title: const Text('Check for rule updates'),
                subtitle: canUpdate
                    ? null
                    : const Text('This build has no rules URL'),
                enabled: canUpdate,
                onTap: () => _checkForUpdates(context),
              ),
              if (rules.source == RulesSource.downloaded)
                ListTile(
                  leading: const Icon(Icons.restore),
                  title: const Text('Use built-in rules'),
                  onTap: rules.useBundled,
                ),
              ListTile(
                leading: const Icon(Icons.troubleshoot),
                title: const Text('Rule diagnostics'),
                subtitle: const Text('What each rule matches on the open page'),
                onTap: () => _showDiagnostics(context),
              ),
              const Divider(),
              const _SectionHeader('All sites'),
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Log out and clear data'),
                subtitle: const Text(
                  'Logs out of every site in the app, and removes cookies, '
                  'site storage and cached pages',
                ),
                onTap: () => _confirmLogOut(context),
              ),
            ],
          ),
        );
      },
    );
  }

  String _rulesSummary(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final checked = rules.lastChecked;
    return [
      rules.source == RulesSource.bundled ? 'Built in' : 'Downloaded',
      if (checked != null)
        'checked ${localizations.formatShortDate(checked)} '
            '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(checked))}',
      if (rules.lastError != null) 'last check failed',
    ].join(' · ');
  }

  Future<void> _checkForUpdates(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final status = await rules.checkForUpdates(force: true);
    final text = switch (status) {
      RulesUpdateStatus.updated =>
        'Updated to revision ${rules.rules.revision}',
      RulesUpdateStatus.upToDate => 'Rules are up to date',
      RulesUpdateStatus.failed =>
        'Couldn\'t check for updates: ${rules.lastError}',
      RulesUpdateStatus.notConfigured => 'This build has no rules URL',
      RulesUpdateStatus.skipped => 'Checked recently',
    };
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _showDiagnostics(BuildContext context) async {
    final stats = await readDiagnostics();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _DiagnosticsDialog(stats: stats),
    );
  }

  Future<void> _confirmLogOut(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Log out of every site?'),
        content: const Text(
          'This clears cookies and site data for every site in the app, so '
          'you\'ll need to log in again. Your filter settings stay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await clearSiteData();
    if (context.mounted) Navigator.of(context).pop();
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// Lists each active rule with how many elements it matches on the open
/// page. A rule stuck at zero where it should match is the usual sign that
/// the site changed and the rule needs fixing.
class _DiagnosticsDialog extends StatelessWidget {
  const _DiagnosticsDialog({required this.stats});

  final Map<String, dynamic>? stats;

  @override
  Widget build(BuildContext context) {
    final stats = this.stats;
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Rule diagnostics'),
      content: SizedBox(
        width: double.maxFinite,
        child: stats == null
            ? const Text('The filter engine isn\'t running on the open page.')
            : ListView(
                shrinkWrap: true,
                children: [
                  Text(
                    'Page: ${stats['path']}',
                    style: theme.textTheme.bodySmall,
                  ),
                  for (final error in stats['errors'] as List)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '${error['id']}: ${error['error']}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  for (final rule in [
                    ...stats['hide'] as List,
                    ...stats['style'] as List? ?? const [],
                    ...stats['hideByText'] as List,
                    ...stats['prune'] as List? ?? const [],
                    ...stats['keep'] as List? ?? const [],
                    ...stats['searchBoxes'] as List? ?? const [],
                  ])
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('${rule['id']}'),
                      trailing: Text(
                        rule['active'] == true
                            ? '${rule['matches']} matched'
                            : 'not on this page',
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
