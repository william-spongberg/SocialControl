import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../site.dart';
import 'settings_screen.dart';
import 'site_picker.dart';
import 'site_view.dart';

/// The app's main page. It opens on the site picker; a picked site shows
/// under a slim bar with a site switcher, reload and settings.
///
/// A site's WebView stays open once the user has visited it, so switching
/// sites, or going back to the picker, doesn't reload the page. Back from a
/// site's first page returns to the picker.
class ShellScreen extends StatefulWidget {
  const ShellScreen({
    super.key,
    required this.sites,
    required this.engineSource,
    this.defaultUserAgent,
  });

  final List<Site> sites;
  final String engineSource;
  final String? defaultUserAgent;

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> {
  late final List<SiteViewController> _controllers = [
    for (final _ in widget.sites) SiteViewController(),
  ];

  /// The sites whose WebView exists.
  final Set<int> _opened = {};

  /// The site on screen, or null for the picker.
  int? _current;

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _open(int index, {Uri? url}) {
    if (url != null) _controllers[index].open(url);
    setState(() {
      _opened.add(index);
      _current = index;
    });
  }

  /// Opens a link to another site in the app there, rather than in that
  /// site's official app.
  bool _openElsewhere(Uri url) {
    final index = widget.sites.indexWhere(
      (site) => site.rules.rules.isSiteHost(url.host),
    );
    if (index == -1 || index == _current) return false;
    _open(index, url: url);
    return true;
  }

  Future<void> _back() async {
    final current = _current;
    if (current == null) {
      await SystemNavigator.pop();
    } else if (!await _controllers[current].goBack() && mounted) {
      setState(() => _current = null);
    }
  }

  void _openSettings(int index) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          site: widget.sites[index],
          readDiagnostics: _controllers[index].readDiagnostics,
          clearSiteData: _clearSiteData,
        ),
      ),
    );
  }

  /// Logs out of every site by clearing cookies, site storage and the cache.
  /// The app's WebViews share these, and logins span several domains (a
  /// YouTube login lives on google.com too), so it clears everything.
  Future<void> _clearSiteData() async {
    await CookieManager.instance().deleteAllCookies();
    final storage = WebStorageManager.instance();
    if (defaultTargetPlatform == TargetPlatform.android) {
      await storage.deleteAllData();
    } else {
      await storage.removeDataModifiedSince(
        dataTypes: WebsiteDataType.ALL,
        date: DateTime.fromMillisecondsSinceEpoch(0),
      );
    }
    await InAppWebViewController.clearAllCache();
    await Future.wait([for (final i in _opened) _controllers[i].restart()]);
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: current == null
            ? null
            : _SiteBar(
                sites: widget.sites,
                current: current,
                controller: _controllers[current],
                onSwitch: _open,
                onSettings: () => _openSettings(current),
              ),
        body: SafeArea(
          top: current == null,
          child: IndexedStack(
            index: current == null ? 0 : current + 1,
            children: [
              SitePicker(sites: widget.sites, onPick: _open),
              for (final (i, site) in widget.sites.indexed)
                _opened.contains(i)
                    ? SiteView(
                        key: ValueKey(site.info.platform),
                        site: site,
                        controller: _controllers[i],
                        engineSource: widget.engineSource,
                        defaultUserAgent: widget.defaultUserAgent,
                        active: i == current,
                        openElsewhere: _openElsewhere,
                      )
                    : const SizedBox.shrink(),
            ],
          ),
        ),
      ),
    );
  }
}

/// The bar above a site: the site switcher, reload and settings, with a thin
/// progress line along the bottom. Back is the system's back gesture.
class _SiteBar extends StatelessWidget implements PreferredSizeWidget {
  const _SiteBar({
    required this.sites,
    required this.current,
    required this.controller,
    required this.onSwitch,
    required this.onSettings,
  });

  static const _height = 48.0;
  static const _progressHeight = 2.0;

  final List<Site> sites;
  final int current;
  final SiteViewController controller;
  final ValueChanged<int> onSwitch;
  final VoidCallback onSettings;

  @override
  Size get preferredSize => const Size.fromHeight(_height + _progressHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final site = sites[current].info;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => AppBar(
        toolbarHeight: _height,
        automaticallyImplyLeading: false,
        titleSpacing: 8,
        title: PopupMenuButton<int>(
          tooltip: 'Switch site',
          initialValue: current,
          onSelected: onSwitch,
          itemBuilder: (_) => [
            for (final (i, other) in sites.indexed)
              PopupMenuItem(
                value: i,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(other.info.icon),
                  title: Text(other.info.name),
                ),
              ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(site.icon, size: 20),
                const SizedBox(width: 8),
                Text(site.name, style: theme.textTheme.titleMedium),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: controller.reload,
          ),
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Filters and settings',
            onPressed: onSettings,
          ),
        ],
        bottom: PreferredSize(
          // Always there, so the page doesn't shift when loading ends.
          preferredSize: const Size.fromHeight(_progressHeight),
          child: controller.progress < 100
              ? LinearProgressIndicator(
                  value: controller.progress / 100,
                  minHeight: _progressHeight,
                )
              : const SizedBox(height: _progressHeight),
        ),
      ),
    );
  }
}
