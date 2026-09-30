import 'package:flutter/material.dart';

import 'config.dart';
import 'site.dart';
import 'ui/shell_screen.dart';

class SocialControlApp extends StatelessWidget {
  const SocialControlApp({
    super.key,
    required this.sites,
    required this.engineSource,
    this.defaultUserAgent,
  });

  final List<Site> sites;
  final String engineSource;
  final String? defaultUserAgent;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: ShellScreen(
        sites: sites,
        engineSource: engineSource,
        defaultUserAgent: defaultUserAgent,
      ),
    );
  }

  static ThemeData _theme(Brightness brightness) => ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF2E7D6B),
      brightness: brightness,
    ),
  );
}
