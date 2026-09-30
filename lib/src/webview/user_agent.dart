/// Turns a WebView user agent into the one the phone's own browser would
/// send, so the site serves its normal mobile web experience rather than
/// treating the app as an in-app browser.
///
/// Android WebView adds `; wv` and `Version/4.0`, which Chrome doesn't send.
/// iOS WKWebView omits the `Version/x.y` and `Safari/604.1` that Safari sends.
String browserUserAgent(String webViewUserAgent) {
  var ua = webViewUserAgent;
  if (ua.contains('; wv)')) {
    ua = ua
        .replaceFirst('; wv)', ')')
        .replaceFirst(RegExp(r'Version/\d+(\.\d+)* '), '');
  }
  final ios = RegExp(r'(?:iPhone|CPU) OS (\d+)_(\d+)').firstMatch(ua);
  if (ios != null && !ua.contains('Safari/') && ua.contains(' Mobile/')) {
    ua = ua.replaceFirst(
      ' Mobile/',
      ' Version/${ios.group(1)}.${ios.group(2)} Mobile/',
    );
    ua = '$ua Safari/604.1';
  }
  return ua;
}
