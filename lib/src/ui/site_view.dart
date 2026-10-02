import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../rules/site_rules.dart';
import '../site.dart';
import '../webview/engine_config.dart';
import '../webview/url_policy.dart';
import '../webview/user_agent.dart';

/// Connects the shell's app bar to a [SiteView]: the bar shows this state,
/// and its buttons call these methods.
class SiteViewController extends ChangeNotifier {
  _SiteViewState? _view;
  Uri? _pendingUrl;
  int _progress = 100;

  /// How far the current page has loaded, from 0 to 100.
  int get progress => _progress;

  /// Goes back in the site's history. Returns false if there is no page to
  /// go back to.
  Future<bool> goBack() async => await _view?._goBack() ?? false;

  Future<void> reload() async => _view?._web?.reload();

  /// Opens [url] under the site's rules. Before the view exists, [url]
  /// becomes its first page.
  void open(Uri url) {
    final view = _view;
    if (view == null) {
      _pendingUrl = url;
    } else {
      view._open(url);
    }
  }

  /// Reads the engine's per-rule stats from the open page, or null if the
  /// engine isn't running there.
  Future<Map<String, dynamic>?> readDiagnostics() async =>
      _view?._readDiagnostics();

  /// Goes back to the site's start page, e.g. after logging out.
  Future<void> restart() async => _view?._restart();

  void _setProgress(int progress) {
    if (progress == _progress) return;
    _progress = progress;
    notifyListeners();
  }
}

/// One site's mobile website in a filtered WebView.
///
/// Filtering happens in two places that share the same rules: [UrlPolicy]
/// decides full page loads here, and the engine injected into the page
/// handles everything inside the site's single-page app.
class SiteView extends StatefulWidget {
  const SiteView({
    super.key,
    required this.site,
    required this.controller,
    required this.engineSource,
    required this.active,
    required this.openElsewhere,
    this.defaultUserAgent,
  });

  final Site site;
  final SiteViewController controller;
  final String engineSource;
  final String? defaultUserAgent;

  /// Whether the site is on screen. Only the site on screen shows notices,
  /// and a site that leaves the screen pauses its videos.
  final bool active;

  /// Offers another site in the app a link that this site's rules would
  /// open in the browser. Returns true if another site took it.
  final bool Function(Uri url) openElsewhere;

  @override
  State<SiteView> createState() => _SiteViewState();
}

class _SiteViewState extends State<SiteView> {
  static const _scriptGroup = 'lite';
  static const _handlerName = 'lite';

  late EngineConfig _config;
  late UrlPolicy _policy;

  /// The page the WebView opens on. Null while it is being decided, which
  /// means reading cookies to see whether the user is signed in, since some
  /// routes only apply signed out.
  Uri? _firstUrl;

  /// Whether the user was signed in when the app last looked at the cookie
  /// store, or null if it couldn't tell. The engine gets this with its
  /// config, since page scripts can't read HttpOnly session cookies.
  bool? _signedIn;
  final _guard = RedirectGuard();
  InAppWebViewController? _web;
  Uri? _queuedUrl;
  bool _inFullscreen = false;
  Key _webViewKey = UniqueKey();
  ({Uri url, String message})? _error;
  String? _lastNotice;
  DateTime _lastNoticeAt = DateTime(0);

  SiteRules get _rules => widget.site.rules.rules;

  @override
  void initState() {
    super.initState();
    widget.controller._view = this;
    _buildConfig();
    final pending = widget.controller._pendingUrl;
    widget.controller._pendingUrl = null;
    unawaited(_openStart(pending));
    widget.site.rules.addListener(_onConfigChanged);
    widget.site.settings.addListener(_onConfigChanged);
  }

  @override
  void didUpdateWidget(SiteView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) unawaited(_pauseMedia());
  }

  @override
  void dispose() {
    widget.site.rules.removeListener(_onConfigChanged);
    widget.site.settings.removeListener(_onConfigChanged);
    if (widget.controller._view == this) widget.controller._view = null;
    super.dispose();
  }

  void _buildConfig() {
    _config = EngineConfig.build(
      _rules,
      widget.site.settings.enabledFeatures(_rules),
      signedIn: _signedIn,
    );
    _policy = UrlPolicy(_rules, _config.resolver);
  }

  Future<void> _onConfigChanged() => _applyConfig(updatePage: true);

  /// Rebuilds the engine's config. If it changed, later page loads get the
  /// new script, and with [updatePage] the open page updates in place.
  Future<void> _applyConfig({required bool updatePage}) async {
    final previous = _config.json;
    _buildConfig();
    final web = _web;
    if (web == null || _config.json == previous) return;
    await web.removeUserScriptsByGroupName(groupName: _scriptGroup);
    await web.addUserScript(userScript: _userScript());
    if (updatePage) await web.evaluateJavascript(source: _config.updateScript);
  }

  UserScript _userScript() => UserScript(
    groupName: _scriptGroup,
    source: _config.userScript(widget.engineSource),
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
    forMainFrameOnly: true,
    allowedOriginRules: {for (final host in _rules.hosts) 'https://$host'},
  );

  InAppWebViewSettings _webViewSettings({bool supportMultipleWindows = true}) {
    final defaultUserAgent = widget.defaultUserAgent;
    return InAppWebViewSettings(
      userAgent:
          _rules.userAgent == UserAgentMode.browser && defaultUserAgent != null
          ? browserUserAgent(defaultUserAgent)
          : null,
      // Older WebViews send the app's package name in this header, which
      // tells sites (and Google's sign-in page) that this is an embedded
      // browser. Newer ones only send it to origins listed here.
      requestedWithHeaderOriginAllowList: const {},
      useShouldOverrideUrlLoading: true,
      // Feed videos and stories play inline, as in the phone's browser.
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      allowsBackForwardNavigationGestures: true,
      // Debug builds can be inspected from chrome://inspect (Android) or
      // Safari's Develop menu (iOS) to work on rules. See docs/RULES.md.
      isInspectable: kDebugMode,
      supportMultipleWindows: supportMultipleWindows,
      javaScriptCanOpenWindowsAutomatically: supportMultipleWindows,
    );
  }

  // ------------------------------------------------------------ navigation

  /// A page asks for a new window. For a link that opens one
  /// (`target="_blank"`, as every outbound link on Reddit does), Android
  /// reports the link, which then opens here like any other. A window that
  /// a script opens has no URL yet: that is a sign-in popup, such as
  /// Reddit's "Continue with Google", which reports back to the page that
  /// opened it. It opens in a dialog over the site, which closes when the
  /// popup closes itself or goes somewhere the app opens elsewhere. TikTok
  /// also opens one to hand a search to its app; the rules map that to a
  /// page of the site, which opens here instead.
  Future<bool> _onCreateWindow(
    InAppWebViewController controller,
    CreateWindowAction action,
  ) async {
    if (!mounted) return false;
    final link = action.request.url;
    if (link != null &&
        !link.isScheme('about') &&
        !link.isScheme('javascript')) {
      unawaited(_followLink(controller, link));
      return false;
    }
    var open = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        void close() {
          if (!open) return;
          open = false;
          Navigator.of(dialogContext).pop();
        }

        return Dialog.fullscreen(
          child: SafeArea(
            child: Stack(
              children: [
                InAppWebView(
                  windowId: action.windowId,
                  initialSettings: _webViewSettings(
                    supportMultipleWindows: false,
                  ),
                  shouldOverrideUrlLoading: (popup, navigation) =>
                      _shouldOverrideUrlLoading(
                        popup,
                        navigation,
                        onLeave: close,
                      ),
                  onCloseWindow: (_) => close(),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton.filledTonal(
                    tooltip: 'Close sign-in',
                    onPressed: close,
                    icon: const Icon(Icons.close),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    // Also when the system back gesture closed it.
    open = false;
    return true;
  }

  /// Opens a link that asked for a new window in this view instead, where
  /// the policy sends it.
  Future<void> _followLink(InAppWebViewController controller, Uri url) async {
    final signedIn = await _refreshSignedIn();
    switch (_policy.decide(url, isMainFrame: true, signedIn: signedIn)) {
      case NavAllow():
        await controller.loadUrl(urlRequest: URLRequest(url: WebUri.uri(url)));
      case NavCancel():
        break;
      case NavOpenExternal(:final url):
        await _openExternally(url);
      case NavRedirect(:final url, :final blockedLabel):
        if (blockedLabel != null) _notify('$blockedLabel blocked');
        await controller.loadUrl(urlRequest: URLRequest(url: WebUri.uri(url)));
    }
  }

  /// [onLeave] is called when the navigation leaves this view for good: an
  /// app link, or a page that opens in the browser or in another site.
  Future<NavigationActionPolicy> _shouldOverrideUrlLoading(
    InAppWebViewController controller,
    NavigationAction action, {
    VoidCallback? onLeave,
  }) async {
    final url = action.request.url;
    // Frames are embedded content, not navigation the user sees.
    if (url == null || !action.isForMainFrame) {
      return NavigationActionPolicy.ALLOW;
    }

    final signedIn = await _refreshSignedIn();
    final decision = _policy.decide(url, isMainFrame: true, signedIn: signedIn);
    switch (decision) {
      case NavAllow():
        return NavigationActionPolicy.ALLOW;
      case NavCancel():
        _dropRedirect(controller, action);
        onLeave?.call();
        return NavigationActionPolicy.CANCEL;
      case NavOpenExternal(:final url):
        _dropRedirect(controller, action);
        unawaited(_openExternally(url));
        onLeave?.call();
        return NavigationActionPolicy.CANCEL;
      case NavRedirect(url: final target, :final blockedLabel):
        if (blockedLabel != null) _notify('$blockedLabel blocked');
        if (onLeave != null && _policy.handsOff(url, decision)) {
          // A window the page opened to hand off to the site's own app, as
          // TikTok's search does: the page the rules map that to opens in
          // the site instead.
          onLeave();
          _open(target);
          return NavigationActionPolicy.CANCEL;
        }
        if (!_guard.allow()) {
          // A redirect loop. Let a plain redirect through, but keep a block.
          return blockedLabel == null
              ? NavigationActionPolicy.ALLOW
              : NavigationActionPolicy.CANCEL;
        }
        unawaited(
          controller.loadUrl(urlRequest: URLRequest(url: WebUri.uri(target))),
        );
        return NavigationActionPolicy.CANCEL;
    }
  }

  /// Cancelling a server redirect abandons the page load it belongs to, and
  /// the WebView then never reports that load finished, so the progress bar
  /// would stay up forever. This ends the load and clears the bar. (Android
  /// asks about every step of a redirect chain, such as the hops Google's
  /// sign-in makes to set cookies.)
  void _dropRedirect(
    InAppWebViewController controller,
    NavigationAction action,
  ) {
    if (action.isRedirect != true) return;
    unawaited(controller.stopLoading());
    widget.controller._setProgress(100);
  }

  /// Where [url] should load under the site's rules. A block is reported
  /// once the frame is done, since this can run while building.
  Uri _target(Uri url) {
    final decision = _policy.decide(
      url,
      isMainFrame: true,
      signedIn: _signedIn ?? true,
    );
    if (decision is! NavRedirect) return url;
    final blockedLabel = decision.blockedLabel;
    if (blockedLabel != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _notify('$blockedLabel blocked'),
      );
    }
    return decision.url;
  }

  void _open(Uri url) {
    final target = _target(url);
    final web = _web;
    if (web == null) {
      _queuedUrl = target;
    } else {
      unawaited(web.loadUrl(urlRequest: URLRequest(url: WebUri.uri(target))));
    }
  }

  Future<void> _restart() async {
    final signedIn = await _refreshSignedIn();
    final url = _policy.startUrlFor(signedIn: signedIn);
    await _web?.loadUrl(urlRequest: URLRequest(url: WebUri.uri(url)));
  }

  /// Decides the first page, [url] or else the start page, then builds the
  /// WebView on it. Some routes only apply signed out, so this first looks
  /// at the cookie store.
  Future<void> _openStart([Uri? url]) async {
    final signedIn = await _refreshSignedIn();
    if (!mounted) return;
    setState(() {
      _firstUrl = url == null
          ? _policy.startUrlFor(signedIn: signedIn)
          : _target(url);
    });
  }

  /// Looks at the cookie store to see whether the user is signed in, and
  /// passes a change on to the engine: to later page loads, and with
  /// [updatePage] to the open page, which then applies or drops its
  /// signed-out routes straight away.
  Future<bool> _refreshSignedIn({bool updatePage = false}) async {
    final signedIn = await _readSignedIn();
    if (mounted && signedIn != _signedIn) {
      _signedIn = signedIn;
      await _applyConfig(updatePage: updatePage);
    }
    // If the app can't tell, the engine goes by the page's own cookies.
    return signedIn ?? true;
  }

  /// Whether the user is signed in to the site, going by the session cookies
  /// its rules name, or null if the cookies can't be read. Sites without any
  /// count as signed in. The cookie store also holds HttpOnly cookies, which
  /// page scripts can't see.
  Future<bool?> _readSignedIn() async {
    if (_rules.session == null) return true;
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri.uri(_rules.startUrl),
      );
      return _rules.isSignedIn({for (final c in cookies) c.name: '${c.value}'});
    } catch (e) {
      debugPrint('Could not read cookies: $e');
      return null;
    }
  }

  Future<void> _openExternally(Uri url) async {
    if (widget.openElsewhere(url)) return;
    var opened = false;
    try {
      opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    } on PlatformException catch (e) {
      debugPrint('Could not open $url: $e');
    }
    if (!opened) _notify('Couldn\'t open that link');
  }

  Future<bool> _goBack() async {
    final web = _web;
    if (web == null || !await web.canGoBack()) return false;
    await web.goBack();
    return true;
  }

  /// Fullscreen video plays in landscape, as in the phone's own video apps,
  /// unless the video is taller than it is wide.
  Future<void> _onEnterFullscreen() async {
    _inFullscreen = true;
    final portrait = await _web?.evaluateJavascript(
      source: """(function () {
        var element = document.fullscreenElement || document.webkitFullscreenElement;
        var video = element && (element.tagName === 'VIDEO' ? element : element.querySelector('video'));
        return !!video && video.videoHeight > video.videoWidth;
      })()""",
    );
    if (!_inFullscreen || !mounted || portrait == true) return;
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  /// Android's WebView can leave fullscreen without telling the page, which
  /// then keeps its video player covering everything (seen on YouTube). Once
  /// the exit has had time to reach the page, the engine checks for that and
  /// repairs the page, unless fullscreen has started again meanwhile.
  Future<void> _onExitFullscreen() async {
    _inFullscreen = false;
    await SystemChrome.setPreferredOrientations(const []);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (_inFullscreen || !mounted) return;
    await _web?.evaluateJavascript(
      source: 'window.__liteEngine && window.__liteEngine.repairFullscreen();',
    );
  }

  /// Off screen, the page keeps running, so a video would play on unseen.
  Future<void> _pauseMedia() async {
    await _web?.evaluateJavascript(
      source:
          "document.querySelectorAll('video, audio')"
          '.forEach(function (media) { media.pause(); });',
    );
  }

  // ------------------------------------------------------ engine messages

  void _onWebViewCreated(InAppWebViewController controller) {
    _web = controller;
    controller.addJavaScriptHandler(
      handlerName: _handlerName,
      callback: _onEngineMessage,
    );
    final queued = _queuedUrl;
    if (queued != null) {
      _queuedUrl = null;
      unawaited(
        controller.loadUrl(urlRequest: URLRequest(url: WebUri.uri(queued))),
      );
    }
  }

  Object? _onEngineMessage(JavaScriptHandlerFunctionData data) {
    // Only the site's own pages may talk to the app.
    if (!data.isMainFrame || !_rules.isSiteHost(data.origin.host)) return null;
    final message = data.args.isEmpty ? null : data.args.first;
    if (message is! Map) return null;
    final label = '${message['label']}';
    switch (message['type']) {
      case 'blocked':
        _notify('$label blocked');
      case 'stuck':
        _notify('$label is blocked. Go back to continue.');
    }
    return null;
  }

  /// Shows a short notice. Both the app and the engine may report the same
  /// block, so repeats within a few seconds are dropped.
  void _notify(String text) {
    final now = DateTime.now();
    if (!mounted || !widget.active) return;
    if (text == _lastNotice &&
        now.difference(_lastNoticeAt) < const Duration(seconds: 3)) {
      return;
    }
    _lastNotice = text;
    _lastNoticeAt = now;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
  }

  Future<Map<String, dynamic>?> _readDiagnostics() async {
    final result = await _web?.evaluateJavascript(
      source:
          'window.__liteEngine ? JSON.stringify(window.__liteEngine.stats()) : null',
    );
    return result is String ? jsonDecode(result) as Map<String, dynamic> : null;
  }

  // --------------------------------------------------------------- loading

  void _onReceivedError(
    InAppWebViewController controller,
    WebResourceRequest request,
    WebResourceError error,
  ) {
    if (request.isForMainFrame == false) return;
    // Cancelled loads include the ones the policy cancels on purpose.
    if (error.type == WebResourceErrorType.CANCELLED ||
        error.type ==
            WebResourceErrorType.FRAME_LOAD_INTERRUPTED_BY_POLICY_CHANGE) {
      return;
    }
    setState(() => _error = (url: request.url, message: error.description));
  }

  void _retry() {
    final error = _error;
    setState(() => _error = null);
    if (error != null) {
      _web?.loadUrl(urlRequest: URLRequest(url: WebUri.uri(error.url)));
    }
  }

  /// Sites like Instagram are heavy, and the system may kill the WebView's
  /// renderer under memory pressure. A fresh WebView reloads the start page.
  void _recreateWebView() {
    _web = null;
    widget.controller._setProgress(100);
    setState(() {
      _webViewKey = UniqueKey();
      _firstUrl = null;
      _error = null;
    });
    unawaited(_openStart());
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final firstUrl = _firstUrl;
    if (firstUrl == null) return const SizedBox.expand();
    final error = _error;
    return Stack(
      children: [
        InAppWebView(
          key: _webViewKey,
          initialUrlRequest: URLRequest(url: WebUri.uri(firstUrl)),
          initialSettings: _webViewSettings(),
          initialUserScripts: UnmodifiableListView([_userScript()]),
          onWebViewCreated: _onWebViewCreated,
          onCreateWindow: _onCreateWindow,
          shouldOverrideUrlLoading: _shouldOverrideUrlLoading,
          onLoadStart: (_, _) {
            if (_error != null) setState(() => _error = null);
          },
          // Signing in or out can happen inside a page, and an in-page
          // navigation never reaches shouldOverrideUrlLoading.
          onLoadStop: (_, _) => _refreshSignedIn(updatePage: true),
          onUpdateVisitedHistory: (_, _, _) =>
              _refreshSignedIn(updatePage: true),
          onProgressChanged: (_, progress) =>
              widget.controller._setProgress(progress),
          onReceivedError: _onReceivedError,
          onEnterFullscreen: (_) => _onEnterFullscreen(),
          onExitFullscreen: (_) => _onExitFullscreen(),
          onRenderProcessGone: (_, _) => _recreateWebView(),
          onWebContentProcessDidTerminate: (_) => _recreateWebView(),
        ),
        if (error != null)
          Positioned.fill(
            child: _ErrorView(
              title: 'Couldn\'t load ${widget.site.info.name}',
              message: error.message,
              onRetry: _retry,
            ),
          ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.title,
    required this.message,
    required this.onRetry,
  });

  final String title;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.wifi_off,
                size: 48,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ),
        ),
      ),
    );
  }
}
