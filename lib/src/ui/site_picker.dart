import 'package:flutter/material.dart';

import '../config.dart';
import '../site.dart';

/// Where the app starts: the user picks which site to open.
class SitePicker extends StatelessWidget {
  const SitePicker({super.key, required this.sites, required this.onPick});

  final List<Site> sites;

  /// Called with the index of the picked site in [sites].
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      // The cards count the filters that are on.
      listenable: Listenable.merge([
        for (final site in sites) ...[site.rules, site.settings],
      ]),
      builder: (context, _) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                appName,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'What would you like to open?',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 32),
              for (final (i, site) in sites.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _SiteCard(site: site, onTap: () => onPick(i)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SiteCard extends StatelessWidget {
  const _SiteCard({required this.site, required this.onTap});

  final Site site;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = site.filterCount;
    return Card.filled(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        leading: Icon(
          site.info.icon,
          size: 32,
          color: theme.colorScheme.primary,
        ),
        title: Text(site.info.name, style: theme.textTheme.titleLarge),
        subtitle: Text('${count.on} of ${count.total} filters on'),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
