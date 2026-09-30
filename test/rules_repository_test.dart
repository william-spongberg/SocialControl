import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:social_control/src/rules/rules_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

final _url = Uri.parse('https://rules.example.com/instagram.json');

void main() {
  late DateTime now;
  late int requests;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    now = DateTime(2026, 9, 30, 12);
    requests = 0;
  });

  Future<RulesRepository> repository({
    int bundledRevision = 1,
    http.Response Function()? respond,
    Uri? remoteUrl,
  }) async {
    final repo = RulesRepository(
      prefs: await SharedPreferences.getInstance(),
      loadBundled: () async => rulesJson(revision: bundledRevision),
      remoteUrl: remoteUrl ?? _url,
      clock: () => now,
      client: MockClient((request) async {
        requests++;
        return (respond ?? () => http.Response('', 404))();
      }),
    );
    await repo.load();
    return repo;
  }

  // No charset, so package:http itself would decode the body as Latin-1.
  http.Response ok(String body) => http.Response.bytes(
    utf8.encode(body),
    200,
    headers: {'content-type': 'application/json'},
  );

  test('starts with the bundled rules', () async {
    final repo = await repository();
    expect(repo.rules.revision, 1);
    expect(repo.source, RulesSource.bundled);
  });

  test('switches to newer rules and keeps them for next launch', () async {
    final repo = await repository(respond: () => ok(rulesJson(revision: 2)));
    var notified = 0;
    repo.addListener(() => notified++);

    expect(await repo.checkForUpdates(), RulesUpdateStatus.updated);
    expect(repo.rules.revision, 2);
    expect(repo.source, RulesSource.downloaded);
    expect(notified, 1);

    final relaunched = await repository();
    expect(relaunched.rules.revision, 2);
    expect(relaunched.source, RulesSource.downloaded);
  });

  test('keeps current rules when the download is not newer', () async {
    final repo = await repository(respond: () => ok(rulesJson(revision: 1)));
    expect(await repo.checkForUpdates(), RulesUpdateStatus.upToDate);
    expect(repo.source, RulesSource.bundled);
  });

  test('prefers bundled rules newer than the cached download', () async {
    await (await repository(
      respond: () => ok(rulesJson(revision: 2)),
    )).checkForUpdates();

    final afterAppUpdate = await repository(bundledRevision: 3);
    expect(afterAppUpdate.rules.revision, 3);
    expect(afterAppUpdate.source, RulesSource.bundled);
  });

  test('rejects invalid rules and keeps working ones', () async {
    final repo = await repository(
      respond: () => ok(rulesJson(revision: 5, schemaVersion: 99)),
    );
    expect(await repo.checkForUpdates(), RulesUpdateStatus.failed);
    expect(repo.rules.revision, 1);
    expect(repo.lastError, contains('schemaVersion 99'));
  });

  test('rejects rules for another site', () async {
    final repo = await repository(
      respond: () => ok(rulesJson(revision: 5, platform: 'youtube')),
    );
    expect(await repo.checkForUpdates(), RulesUpdateStatus.failed);
    expect(repo.lastError, contains('youtube'));
  });

  test('reports HTTP errors', () async {
    final repo = await repository(respond: () => http.Response('nope', 500));
    expect(await repo.checkForUpdates(), RulesUpdateStatus.failed);
    expect(repo.lastError, contains('HTTP 500'));
  });

  test('decodes UTF-8 whatever the server says', () async {
    final body = rulesJson(
      revision: 2,
      features: [
        {
          'id': 'ads',
          'title': 'Hide ads',
          'enabledByDefault': true,
          'hideByText': [
            {
              'container': 'article',
              'marker': 'span',
              'text': ['Sponsorisé'],
            },
          ],
        },
      ],
    );
    final repo = await repository(respond: () => ok(body));
    expect(await repo.checkForUpdates(), RulesUpdateStatus.updated);
    expect(repo.rules.features.single.hideByText.single.text, ['Sponsorisé']);
  });

  test('checks at most once per interval unless forced', () async {
    final repo = await repository(respond: () => ok(rulesJson(revision: 1)));
    expect(await repo.checkForUpdates(), RulesUpdateStatus.upToDate);
    now = now.add(const Duration(hours: 1));
    expect(await repo.checkForUpdates(), RulesUpdateStatus.skipped);
    expect(await repo.checkForUpdates(force: true), RulesUpdateStatus.upToDate);
    now = now.add(const Duration(hours: 7));
    expect(await repo.checkForUpdates(), RulesUpdateStatus.upToDate);
    expect(requests, 3);
  });

  test('does nothing without a rules URL', () async {
    final repo = RulesRepository(
      prefs: await SharedPreferences.getInstance(),
      loadBundled: () async => rulesJson(),
      remoteUrl: null,
    );
    await repo.load();
    expect(
      await repo.checkForUpdates(force: true),
      RulesUpdateStatus.notConfigured,
    );
  });

  test('drops an unreadable cache', () async {
    SharedPreferences.setMockInitialValues({
      'rules.instagram.cache': '{"broken": true}',
    });
    final repo = await repository();
    expect(repo.source, RulesSource.bundled);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('rules.instagram.cache'), isNull);
  });

  test('keeps each site\'s download separately', () async {
    await (await repository(
      respond: () => ok(rulesJson(revision: 2)),
    )).checkForUpdates();

    final other = RulesRepository(
      prefs: await SharedPreferences.getInstance(),
      loadBundled: () async => rulesJson(platform: 'youtube'),
      remoteUrl: _url,
      clock: () => now,
      client: MockClient((_) async => http.Response('', 404)),
    );
    await other.load();
    expect(other.source, RulesSource.bundled);
    expect(other.lastChecked, isNull);
    expect((await repository()).rules.revision, 2);
  });

  test('can go back to the bundled rules', () async {
    final repo = await repository(respond: () => ok(rulesJson(revision: 2)));
    await repo.checkForUpdates();
    await repo.useBundled();
    expect(repo.rules.revision, 1);
    expect(repo.source, RulesSource.bundled);
    expect((await repository()).source, RulesSource.bundled);
  });
}
