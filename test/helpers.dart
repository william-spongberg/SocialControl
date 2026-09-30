import 'dart:convert';

/// A small valid rules file, with fields overridable per test.
String rulesJson({
  int revision = 1,
  String platform = 'instagram',
  int schemaVersion = 1,
  List<Map<String, Object?>>? features,
}) {
  return jsonEncode({
    'schemaVersion': schemaVersion,
    'platform': platform,
    'revision': revision,
    'startUrl': 'https://www.instagram.com/',
    'hosts': ['instagram.com', 'www.instagram.com'],
    'allowedHosts': ['accountscenter.instagram.com'],
    'linkShims': [
      {'host': 'l.instagram.com', 'param': 'u'},
    ],
    'features':
        features ??
        [
          {
            'id': 'hideReels',
            'title': 'Hide Reels',
            'enabledByDefault': true,
            'routes': [
              {
                'match': r'^/reels(?:[/?]|$)',
                'action': 'block',
                'to': '/',
                'label': 'Reels',
              },
            ],
            'hide': [
              {'selector': 'a[href^="/reels/"]'},
            ],
          },
          {
            'id': 'followingFeed',
            'title': 'Following feed',
            'enabledByDefault': true,
            'routes': [
              {
                'match': r'^/$',
                'action': 'redirect',
                'to': '/?variant=following',
              },
            ],
          },
        ],
  });
}
