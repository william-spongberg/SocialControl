import 'package:flutter_test/flutter_test.dart';
import 'package:social_control/src/webview/user_agent.dart';

void main() {
  group('browserUserAgent', () {
    test('turns an Android WebView user agent into Chrome\'s', () {
      const webView =
          'Mozilla/5.0 (Linux; Android 15; Pixel 8 Build/AP4A.250105.002; wv) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
          'Chrome/140.0.7339.51 Mobile Safari/537.36';
      expect(
        browserUserAgent(webView),
        'Mozilla/5.0 (Linux; Android 15; Pixel 8 Build/AP4A.250105.002) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/140.0.7339.51 Mobile Safari/537.36',
      );
    });

    test('turns a WKWebView user agent into Safari\'s', () {
      const webView =
          'Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148';
      expect(
        browserUserAgent(webView),
        'Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 '
        'Mobile/15E148 Safari/604.1',
      );
    });

    test('leaves a browser user agent unchanged', () {
      const safari =
          'Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 '
          'Mobile/15E148 Safari/604.1';
      expect(browserUserAgent(safari), safari);
      expect(browserUserAgent(browserUserAgent(safari)), safari);
    });
  });
}
