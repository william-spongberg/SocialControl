// Tests for assets/js/lite_engine.js in jsdom.
//
// jsdom has no layout, so these check the engine's own behaviour: routing,
// history and click interception, text rules and the stylesheet it builds.
// Whether real Instagram markup matches the rules is checked on a device;
// see docs/RULES.md.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { describe, test } from 'node:test';
import { JSDOM } from 'jsdom';

const root = new URL('../../', import.meta.url);
const engineSource = readFileSync(new URL('assets/js/lite_engine.js', root), 'utf8');
const fixture = JSON.parse(
  readFileSync(new URL('test/fixtures/route_cases.json', root), 'utf8'),
);

const HOSTS = ['instagram.com', 'www.instagram.com'];
const ROUTES = [
  { id: 'reels', match: '^/reels(?:[/?]|$)', action: 'block', to: '/', label: 'Reels' },
  { id: 'home', match: '^/$', action: 'redirect', to: '/?variant=following', label: 'Home' },
];

// Loads a page and injects the engine the way the app does, with the
// navigation functions swapped for recorders.
function boot({
  url = 'https://www.instagram.com/direct/inbox/',
  body = '',
  config = {},
  bridge = true,
  beforeInject = () => {},
} = {}) {
  const dom = new JSDOM(`<!doctype html><html><head></head><body>${body}</body></html>`, {
    url,
    runScripts: 'outside-only',
    pretendToBeVisual: true,
  });
  const { window } = dom;
  const messages = [];
  const navigations = [];
  if (bridge) installBridge(window, messages);
  window.__testEnv = {
    assign: (to) => navigations.push(['assign', to]),
    replace: (to) => navigations.push(['replace', to]),
  };
  const page = { dom, window, document: window.document, messages, navigations };
  page.inject = (extra = {}) => {
    const input = { hosts: HOSTS, routes: [], hide: [], hideByText: [], prune: [], ...extra };
    window.eval(
      `(function () {\n${engineSource}\nliteEngine(${JSON.stringify(input)}, window.__testEnv);\n})();`,
    );
  };
  beforeInject(page);
  page.inject(config);
  page.engine = window.__liteEngine;
  return page;
}

function installBridge(window, messages) {
  window.flutter_inappwebview = {
    callHandler(name, message) {
      assert.equal(name, 'lite');
      messages.push({ ...message });
      return window.Promise.resolve();
    },
  };
}

// Lets MutationObserver callbacks, the animation frame they schedule and
// deferred redirects run.
async function settle(window) {
  for (let i = 0; i < 2; i++) {
    await new Promise((resolve) => window.requestAnimationFrame(() => resolve()));
  }
  await new Promise((resolve) => window.setTimeout(resolve, 0));
}

function hidden(window, element) {
  return window.getComputedStyle(element).display === 'none';
}

function click(window, element) {
  const event = new window.MouseEvent('click', { bubbles: true, cancelable: true, button: 0 });
  element.dispatchEvent(event);
  return event;
}

describe('route resolution', () => {
  // Shared with test/route_resolver_test.dart, so both sides agree.
  const { engine, document } = boot({
    config: { routes: fixture.routes, session: fixture.session },
  });
  for (const c of fixture.cases) {
    const signedIn = c.signedIn !== false;
    test(`resolves ${c.path}${signedIn ? '' : ' signed out'}`, () => {
      document.cookie = signedIn ? 'SID=1; path=/' : 'SID=; path=/; expires=Thu, 01 Jan 1970 00:00:00 GMT';
      assert.deepEqual({ ...engine.resolve(c.path) }, c.expect);
    });
  }
});

describe('signed-out routes', () => {
  const routes = [
    { id: 'home', match: '^/$', action: 'redirect', to: '/feed/subscriptions', label: 'Home' },
    { id: 'signedOut', match: '^/feed/subscriptions$', action: 'redirect', to: '/feed/library', label: 'Subscriptions', signedOut: true },
  ];

  test('apply as soon as the site signs you out, without a reload', async () => {
    const page = boot({
      beforeInject: ({ document }) => { document.cookie = 'SAPISID=abc; path=/'; },
      config: { routes, session: ['SAPISID', '__Secure-3PAPISID'] },
    });
    const { window, document } = page;
    window.history.pushState({}, '', '/feed/subscriptions');
    assert.equal(window.location.pathname, '/feed/subscriptions');

    document.cookie = 'SAPISID=; path=/; expires=Thu, 01 Jan 1970 00:00:00 GMT';
    window.history.pushState({}, '', '/');
    await settle(window);
    assert.deepEqual(page.navigations, [['assign', '/feed/library']]);
  });

  test('never apply on a site without a session', () => {
    const page = boot({ config: { routes } });
    assert.equal(page.engine.resolve('/').path, '/feed/subscriptions');
  });

  test('follow the app\'s answer over the cookies the page can see', () => {
    // The app can read HttpOnly session cookies, which the page can't.
    const signedIn = boot({ config: { routes, session: ['reddit_session'], signedIn: true } });
    assert.equal(signedIn.engine.resolve('/feed/subscriptions').changed, false);

    const signedOut = boot({
      beforeInject: ({ document }) => { document.cookie = 'reddit_session=abc; path=/'; },
      config: { routes, session: ['reddit_session'], signedIn: false },
    });
    assert.equal(signedOut.engine.resolve('/feed/subscriptions').path, '/feed/library');
  });

  test('apply to the open page once the app finds you signed out', async () => {
    const config = { hosts: HOSTS, routes, session: ['reddit_session'], signedIn: true };
    const page = boot({ url: 'https://www.instagram.com/feed/subscriptions', config });
    assert.deepEqual(page.navigations, []);

    page.engine.update({ ...config, signedIn: false });
    await settle(page.window);
    assert.deepEqual(page.navigations, [['replace', '/feed/library']]);
  });
});

describe('hide rules', () => {
  test('hide matching elements before and after the page renders', async () => {
    const page = boot({
      body: '<nav><a id="home" href="/">Home</a><a id="reels" href="/reels/">Reels</a></nav>',
      config: { hide: [{ id: 'reels', selector: 'a[href^="/reels/"]', paths: null }] },
    });
    const { window, document } = page;
    assert.equal(hidden(window, document.getElementById('reels')), true);
    assert.equal(hidden(window, document.getElementById('home')), false);

    document.body.insertAdjacentHTML('beforeend', '<a id="late" href="/reels/C8/">Reel</a>');
    assert.equal(hidden(window, document.getElementById('late')), true);
  });

  test('apply path-scoped rules only on matching pages', async () => {
    const page = boot({
      body: '<a id="post" href="/p/C8xYz/">Post</a>',
      config: {
        hide: [{ id: 'grid', selector: 'a[href*="/p/"]', paths: '^/explore/search/?$' }],
      },
    });
    const { window, document } = page;
    const post = document.getElementById('post');
    assert.equal(hidden(window, post), false);

    window.history.pushState({}, '', '/explore/search/');
    assert.equal(document.documentElement.getAttribute('data-lite-active'), 'h0');
    assert.equal(hidden(window, post), true);

    window.history.pushState({}, '', '/direct/inbox/');
    assert.equal(document.documentElement.hasAttribute('data-lite-active'), false);
    assert.equal(hidden(window, post), false);
  });

  test('apply path-scoped rules when <html> only appears after injection', async () => {
    // Document-start scripts can run before <html> exists (Firefox does this,
    // and so may Android's fallback injection).
    let html;
    const page = boot({
      url: 'https://www.instagram.com/explore/search/',
      config: {
        hide: [{ id: 'grid', selector: 'a[href*="/p/"]', paths: '^/explore/search/?$' }],
      },
      beforeInject: ({ document }) => {
        html = document.documentElement;
        document.removeChild(html);
      },
    });
    const { window, document } = page;
    // Let load events pass first, so only the engine's MutationObserver can
    // notice the new <html>.
    while (document.readyState !== 'complete') {
      await new Promise((resolve) => window.setTimeout(resolve, 5));
    }
    document.appendChild(html);
    await settle(window);
    assert.equal(html.getAttribute('data-lite-active'), 'h0');
    document.body.insertAdjacentHTML('beforeend', '<a id="post" href="/p/C8xYz/">Post</a>');
    assert.equal(hidden(window, document.getElementById('post')), true);
  });

  test('collapse elements into empty boxes when a rule asks', () => {
    const page = boot({
      body:
        '<article id="ad" class="ad"><img id="media"><span>Shop now</span></article>' +
        '<article id="post"><span>Hello</span></article>',
      config: { hide: [{ id: 'ads', selector: 'article.ad', paths: null, collapse: true }] },
    });
    const { window, document } = page;
    const ad = document.getElementById('ad');
    // Still in the layout, so a feed can measure it, but empty and invisible.
    assert.equal(hidden(window, ad), false);
    assert.equal(window.getComputedStyle(ad).height, '0px');
    assert.equal(window.getComputedStyle(ad).visibility, 'hidden');
    assert.equal(hidden(window, document.getElementById('media')), true);
    assert.equal(hidden(window, document.getElementById('post')), false);
  });

  test('skip an invalid selector and keep the other rules', () => {
    const page = boot({
      body: '<p class="x" id="x">x</p>',
      config: {
        hide: [
          { id: 'bad', selector: 'a[href=', paths: null },
          { id: 'good', selector: '.x', paths: null },
        ],
      },
    });
    assert.equal(hidden(page.window, page.document.getElementById('x')), true);
    const stats = page.engine.stats();
    // Array.from copies out of jsdom's realm, so deepEqual compares values.
    assert.deepEqual(Array.from(stats.errors, (e) => e.id), ['bad']);
    assert.deepEqual(
      Array.from(stats.hide, (h) => ({ ...h })),
      [{ id: 'good', active: true, matches: 1 }],
    );
  });
});

describe('style rules', () => {
  test('override the page\'s own styles', () => {
    const page = boot({
      body:
        '<style>.wrapper.slot-open { transform: translateY(-48px); }</style>' +
        '<div id="open" class="wrapper slot-open"></div><div id="shut" class="wrapper"></div>',
      config: { style: [{ id: 'unslide', selector: '.wrapper.slot-open', css: 'transform: none; margin-top: 2px !important' }] },
    });
    const { window, document } = page;
    const open = window.getComputedStyle(document.getElementById('open'));
    assert.equal(open.transform, 'none');
    assert.equal(open.marginTop, '2px');
    assert.notEqual(window.getComputedStyle(document.getElementById('shut')).marginTop, '2px');
    assert.deepEqual(Array.from(page.engine.stats().style, (s) => ({ ...s })), [{ id: 'unslide', active: true, matches: 1 }]);
  });

  test('apply only on their pages when they have paths', () => {
    const page = boot({
      body: '<div id="box" class="box"></div>',
      config: { style: [{ id: 'watch', selector: '.box', css: 'margin-top: 3px', paths: '^/watch' }] },
    });
    const { window, document } = page;
    const margin = () => window.getComputedStyle(document.getElementById('box')).marginTop;
    assert.notEqual(margin(), '3px');
    window.history.pushState({}, '', '/watch?v=1');
    assert.equal(margin(), '3px');
  });

  test('refuse CSS that could break out of its rule or load something', () => {
    const bad = ['color: red } body { display: none', 'background: url(https://x.example/a.png)', '@import "x"', 'no colon'];
    const page = boot({
      config: { style: bad.map((css, i) => ({ id: 'bad' + i, selector: 'body', css })) },
    });
    assert.deepEqual(Array.from(page.engine.stats().errors, (e) => e.id), ['bad0', 'bad1', 'bad2', 'bad3']);
    assert.equal(page.engine.stats().style.length, 0);
  });
});

describe('text rules', () => {
  const ads = {
    id: 'ads',
    container: 'article',
    marker: 'span',
    text: ['Sponsored'],
    paths: null,
  };

  test('hide the container around an exact label, including streamed-in posts', async () => {
    const page = boot({
      body: '<article id="ad1"><header><span>Sponsored</span></header></article>',
      config: { hideByText: [ads] },
    });
    const { window, document } = page;
    assert.equal(hidden(window, document.getElementById('ad1')), true);

    document.body.insertAdjacentHTML(
      'beforeend',
      '<article id="ad2"><span><span>  Sponsored </span></span></article>' +
        '<article id="post"><span>Sponsored by nobody, just a caption</span></article>',
    );
    await settle(window);
    assert.equal(document.getElementById('ad2').getAttribute('data-lite-hidden'), 'ads');
    assert.equal(hidden(window, document.getElementById('post')), false);
    assert.equal(page.engine.stats().hideByText[0].matches, 2);
  });

  test('match a short label wrapped in a lot of whitespace, but not long text', () => {
    // Reddit's "For You" tab: 7 letters among 83 characters of markup.
    const padded = `\n${' '.repeat(40)}For You\n${' '.repeat(40)}`;
    const long = 'x'.repeat(100);
    const page = boot({
      body: `<button id="tab">${padded}</button><button id="long">${long}</button>`,
      config: {
        hideByText: [
          { id: 'tab', container: 'button', marker: 'button', text: ['For You', long] },
        ],
      },
    });
    const { window, document } = page;
    assert.equal(hidden(window, document.getElementById('tab')), true);
    assert.equal(hidden(window, document.getElementById('long')), false);
  });

  test('catch a label whose text arrives after its element', async () => {
    const page = boot({ body: '<article id="ad"><span id="label"></span></article>', config: { hideByText: [ads] } });
    const { window, document } = page;
    document.getElementById('label').textContent = 'Sponsored';
    await settle(window);
    assert.equal(hidden(window, document.getElementById('ad')), true);
  });

  test('collapse streamed-in posts before a feed measures them', async () => {
    const page = boot({ config: { hideByText: [{ ...ads, collapse: true }] } });
    const { window, document } = page;
    // Let load events pass first, so only the MutationObserver sees the post.
    await settle(window);
    // Instagram's feed measures new posts in an animation frame. This frame
    // is requested before the post arrives, so it runs before any frame the
    // engine could request.
    const measured = new Promise((resolve) => {
      window.requestAnimationFrame(() => {
        const ad = document.getElementById('ad');
        resolve({ mark: ad.getAttribute('data-lite-collapsed'), height: window.getComputedStyle(ad).height });
      });
    });
    document.body.insertAdjacentHTML('beforeend', '<article id="ad"><header><span>Sponsored</span></header></article>');
    assert.deepEqual(await measured, { mark: 'ads', height: '0px' });
    assert.equal(document.getElementById('ad').hasAttribute('data-lite-hidden'), false);
    assert.equal(page.engine.stats().hideByText[0].matches, 1);
  });

  test('fire a scroll event after hiding streamed-in posts, so the feed loads more', async () => {
    const page = boot({ config: { hideByText: [ads] } });
    const { window, document } = page;
    await settle(window);
    const scrolls = [];
    window.addEventListener('scroll', (event) => scrolls.push(event.target === document), true);

    document.body.insertAdjacentHTML('beforeend', '<article><span>Hello</span></article>');
    await settle(window);
    assert.deepEqual(scrolls, []);

    document.body.insertAdjacentHTML('beforeend', '<article><span>Sponsored</span></article>');
    await settle(window);
    assert.deepEqual(scrolls, [true]);
  });
});

describe('text rule patterns', () => {
  test('hide a container whose label matches a pattern', async () => {
    const page = boot({
      body:
        '<article id="paid"><span>Paid partnership with Brand Co</span></article>' +
        '<article id="post"><span>Our partnership with Brand Co was paid for</span></article>',
      config: {
        hideByText: [
          {
            id: 'paid',
            container: 'article',
            marker: 'span',
            text: [],
            pattern: '^Paid partnership(?: with .+)?$',
            paths: null,
          },
        ],
      },
    });
    const { window, document } = page;
    assert.equal(hidden(window, document.getElementById('paid')), true);
    assert.equal(hidden(window, document.getElementById('post')), false);
  });
});

describe('prune rules', () => {
  const storyAds = { id: 'ads', path: 'data.xdt_injected_story_units.ad_media_items' };

  test('remove data from JSON the page parses', () => {
    const page = boot({ config: { prune: [storyAds] } });
    const value = page.window.JSON.parse(
      '{"data":{"xdt_injected_story_units":{"ad_media_items":[{"id":1}],"x":1},"reels":[1]}}',
    );
    assert.deepEqual(JSON.parse(JSON.stringify(value)), {
      data: { xdt_injected_story_units: { x: 1 }, reels: [1] },
    });
    assert.deepEqual(Array.from(page.engine.stats().prune, (p) => ({ ...p })), [
      { id: 'ads', active: true, matches: 1 },
    ]);
  });

  test('remove array elements that contain a path, or a property from each element', () => {
    const page = boot({
      config: {
        prune: [
          { id: 'feedAds', path: 'data.feed.edges.[-].node.ad' },
          { id: 'tracking', path: 'items.[].tracking' },
        ],
      },
    });
    const feed = page.window.JSON.parse(
      '{"data":{"feed":{"edges":[{"node":{"id":1}},{"node":{"ad":{"id":2}}},{"node":{"id":3}}]}}}',
    );
    assert.deepEqual(Array.from(feed.data.feed.edges, (e) => e.node.id), [1, 3]);
    const items = page.window.JSON.parse('{"items":[{"id":1,"tracking":"a"},{"id":2}]}');
    assert.deepEqual(JSON.parse(JSON.stringify(items)), { items: [{ id: 1 }, { id: 2 }] });
  });

  test('keep array elements whose path leads to null', () => {
    // Instagram's feed items carry every kind of slot, set to null if unused.
    const page = boot({ config: { prune: [{ id: 'feedAds', path: 'edges.[-].node.ad' }] } });
    const feed = page.window.JSON.parse(
      '{"edges":[{"node":{"ad":null,"media":{"id":1}}},{"node":{"ad":{"id":2},"media":null}},{"node":{"media":{"id":3}}}]}',
    );
    assert.deepEqual(Array.from(feed.edges, (e) => e.node.media && e.node.media.id), [1, 3]);
  });

  test('apply a rule with paths only on the pages it names', () => {
    // TikTok fills a video's page with For You videos after it.
    const page = boot({
      url: 'https://www.instagram.com/@someone/video/1',
      config: { prune: [{ id: 'forYou', path: 'itemList.[-].id', paths: '^/@[^/?]*/video/' }] },
    });
    const { window } = page;
    const list = '{"itemList":[{"id":"1"},{"id":"2"}],"hasMore":true}';
    assert.equal(window.JSON.parse(list).itemList.length, 0);
    window.history.pushState(null, '', '/following');
    assert.equal(window.JSON.parse(list).itemList.length, 2);
    assert.deepEqual(Array.from(page.engine.stats().prune, (p) => ({ ...p })), [
      { id: 'forYou', active: false, matches: 2 },
    ]);
  });

  test('leave parsing otherwise unchanged', () => {
    const page = boot({ config: { prune: [storyAds] } });
    const { window } = page;
    assert.equal(window.JSON.parse('42'), 42);
    assert.equal(window.JSON.parse('null'), null);
    assert.equal(window.JSON.parse('{"a":2}', (key, v) => (key === 'a' ? v * 10 : v)).a, 20);
    assert.throws(() => window.JSON.parse('{bad'), (e) => e.name === 'SyntaxError');
  });

  test('remove data a page script assigns to a global', () => {
    const page = boot({
      config: {
        prune: [{ id: 'videoAds', path: 'adPlacements', global: 'ytInitialPlayerResponse' }],
      },
    });
    const { window } = page;
    // How YouTube embeds its player data on a full page load.
    window.eval(
      'var ytInitialPlayerResponse = null;' +
        'var ytInitialPlayerResponse = {"adPlacements":[{"id":1}],"videoDetails":{"videoId":"x"}};',
    );
    assert.deepEqual(JSON.parse(JSON.stringify(window.ytInitialPlayerResponse)), {
      videoDetails: { videoId: 'x' },
    });
    assert.equal(page.engine.stats().prune[0].matches, 1);
    // A rule for a global leaves JSON alone.
    assert.equal(window.JSON.parse('{"adPlacements":[1]}').adPlacements.length, 1);
  });

  test('leave a global to JSON-only rules', () => {
    const page = boot({ config: { prune: [{ id: 'videoAds', path: 'adPlacements' }] } });
    page.window.eval('var ytInitialPlayerResponse = {"adPlacements":[1]};');
    assert.equal(page.window.ytInitialPlayerResponse.adPlacements.length, 1);
  });

  test('trap a global that a config update adds', () => {
    const page = boot();
    page.engine.update({
      hosts: HOSTS,
      routes: [],
      hide: [],
      hideByText: [],
      prune: [{ id: 'videoAds', path: 'adPlacements', global: 'ytInitialPlayerResponse' }],
    });
    page.window.eval('var ytInitialPlayerResponse = {"adPlacements":[1],"a":1};');
    assert.deepEqual(Object.keys(page.window.ytInitialPlayerResponse), ['a']);
  });

  test('stop pruning when the rule is switched off', () => {
    const page = boot({ config: { prune: [storyAds] } });
    page.engine.update({ hosts: HOSTS, routes: [], hide: [], hideByText: [], prune: [] });
    const value = page.window.JSON.parse('{"data":{"xdt_injected_story_units":{"ad_media_items":[]}}}');
    assert.equal(Array.isArray(value.data.xdt_injected_story_units.ad_media_items), true);
  });
});

describe('navigation', () => {
  test('redirects a blocked page on load, before it renders', () => {
    const page = boot({ url: 'https://www.instagram.com/reels/', config: { routes: ROUTES } });
    assert.deepEqual(page.navigations, [['replace', '/?variant=following']]);
    assert.deepEqual(page.messages[0], { type: 'blocked', label: 'Reels', path: '/reels/' });
    assert.equal(page.document.documentElement.hasAttribute('data-lite-redirecting'), true);
  });

  test('swallows pushState to a blocked page and navigates elsewhere', async () => {
    const page = boot({ config: { routes: ROUTES } });
    const { window } = page;
    window.history.pushState({}, '', '/reels/C8xYz/');
    assert.equal(window.location.pathname, '/direct/inbox/');
    assert.equal(page.document.documentElement.hasAttribute('data-lite-redirecting'), true);

    await settle(window);
    assert.deepEqual(page.navigations, [['assign', '/?variant=following']]);
    assert.deepEqual(
      page.messages.filter((m) => m.type === 'blocked'),
      [{ type: 'blocked', label: 'Reels', path: '/reels/C8xYz/' }],
    );
  });

  test('uses a link on the page for in-app navigation when there is one', async () => {
    const page = boot({
      body: '<a id="following" href="/?variant=following">Following</a>',
      config: { routes: ROUTES },
    });
    const { window, document } = page;
    const siteClicks = [];
    document.getElementById('following').addEventListener('click', (event) => {
      event.preventDefault(); // What a single-page app's router does.
      siteClicks.push(event.target.id);
    });
    window.history.pushState({}, '', '/reels/');
    await settle(window);
    assert.deepEqual(siteClicks, ['following']);
    assert.deepEqual(page.navigations, []);
  });

  test('lets allowed history changes through and reports the route', () => {
    const page = boot({ config: { routes: ROUTES } });
    page.window.history.pushState({ a: 1 }, '', '/someone/');
    assert.equal(page.window.location.pathname, '/someone/');
    assert.deepEqual(page.window.history.state, { a: 1 });
    assert.deepEqual(page.messages.at(-1), { type: 'route', path: '/someone/' });
  });

  test('stops clicks on links to blocked pages before the site sees them', async () => {
    const page = boot({
      body: '<a id="reels" href="/reels/"><svg><path id="icon"></path></svg></a><a id="profile" href="/someone/">Profile</a>',
      config: { routes: ROUTES },
    });
    const { window, document } = page;
    const siteClicks = [];
    document.addEventListener('click', (event) => {
      siteClicks.push(event.target.id);
      event.preventDefault();
    });

    const blocked = click(window, document.getElementById('icon'));
    assert.equal(blocked.defaultPrevented, true);
    const allowed = click(window, document.getElementById('profile'));
    assert.deepEqual(siteClicks, ['profile']);
    assert.equal(allowed.defaultPrevented, true); // By the site's handler.

    await settle(window);
    assert.deepEqual(page.navigations, [['assign', '/?variant=following']]);
  });

  test('leaves same-page anchor links alone', () => {
    // Even on a page that would itself redirect.
    const page = boot({ url: 'https://www.instagram.com/', body: '<a id="menu" href="#">More</a>' });
    page.engine.update({ hosts: HOSTS, routes: ROUTES, hide: [], hideByText: [] });
    const event = click(page.window, page.document.getElementById('menu'));
    assert.equal(event.defaultPrevented, false);
  });

  test('handles back and forward to a blocked page before the site does', () => {
    const page = boot({ config: { routes: ROUTES } });
    const { dom, window } = page;
    const sitePops = [];
    window.addEventListener('popstate', () => sitePops.push(window.location.pathname));

    dom.reconfigure({ url: 'https://www.instagram.com/reels/' });
    window.dispatchEvent(new window.PopStateEvent('popstate', { state: null }));
    assert.deepEqual(sitePops, []);
    assert.deepEqual(page.navigations, [['replace', '/?variant=following']]);

    dom.reconfigure({ url: 'https://www.instagram.com/someone/' });
    window.dispatchEvent(new window.PopStateEvent('popstate', { state: null }));
    assert.deepEqual(sitePops, ['/someone/']);
  });

  test('gives up on a redirect loop and keeps the blocked page hidden', async () => {
    const page = boot({ config: { routes: ROUTES } });
    const { window } = page;
    for (let i = 0; i < 4; i++) window.history.pushState({}, '', '/reels/');
    await settle(window);
    assert.equal(page.navigations.length, 3);
    assert.deepEqual(page.messages.at(-1), { type: 'stuck', label: 'Reels', path: '/reels/' });
    assert.equal(page.document.documentElement.hasAttribute('data-lite-redirecting'), true);
  });
});

describe('in-page navigation', () => {
  // A router like Instagram's: it renders whatever URL a popstate finds.
  function watchRouter(window) {
    const rendered = [];
    window.addEventListener('popstate', () => rendered.push(window.location.pathname + window.location.search));
    return rendered;
  }

  test('pushes the URL and fires popstate when there is no link to click', async () => {
    const page = boot({
      body: '<a id="home" href="/">Home</a>',
      config: { routes: ROUTES, popstateNavigation: true },
    });
    const { window, document } = page;
    const rendered = watchRouter(window);
    click(window, document.getElementById('home'));
    await settle(window);
    assert.equal(window.location.pathname + window.location.search, '/?variant=following');
    assert.deepEqual(rendered, ['/?variant=following']);
    assert.deepEqual(page.navigations, []);
  });

  test('turns back to a blocked page into a replace, still without a reload', async () => {
    const page = boot({ config: { routes: ROUTES, popstateNavigation: true } });
    const { dom, window } = page;
    await settle(window); // The router only runs once the page has loaded.
    const rendered = watchRouter(window);
    dom.reconfigure({ url: 'https://www.instagram.com/reels/' });
    window.dispatchEvent(new window.PopStateEvent('popstate', { state: null }));
    assert.deepEqual(rendered, ['/?variant=following']);
    assert.deepEqual(page.navigations, []);
  });

  test('still loads a blocked page\'s replacement in full while the page loads', () => {
    const page = boot({ url: 'https://www.instagram.com/reels/', config: { routes: ROUTES, popstateNavigation: true } });
    assert.deepEqual(page.navigations, [['replace', '/?variant=following']]);
  });

  test('loads the page in full for a site without it', async () => {
    const page = boot({ body: '<a id="home" href="/">Home</a>', config: { routes: ROUTES } });
    click(page.window, page.document.getElementById('home'));
    await settle(page.window);
    assert.deepEqual(page.navigations, [['assign', '/?variant=following']]);
  });
});

describe('keep rules', () => {
  const keep = [{ id: 'tabs', marker: 'a[href="/direct/inbox/"]', paths: '^/direct/inbox/' }];
  const bar =
    '<div id="bar" style="position: fixed; bottom: 0"><div>' +
    '<a href="/">Home</a><a href="/direct/inbox/">Messages</a><a href="/someone/">Profile</a>' +
    '</div></div><main id="main"></main>';
  const copyOf = (document) => document.querySelector('[data-lite-kept="tabs"]');
  const wait = (window, ms) => new Promise((resolve) => window.setTimeout(resolve, ms));

  // What Instagram does when you open messages: route there, drop the bar.
  async function openMessages(page) {
    page.window.history.pushState({}, '', '/direct/inbox/');
    page.document.getElementById('bar').remove();
    await wait(page.window, 150);
  }

  test('show a copy of the fixed bar on pages that drop it', async () => {
    const page = boot({ body: bar, config: { keep, routes: ROUTES } });
    assert.equal(copyOf(page.document), null);
    await openMessages(page);
    const copy = copyOf(page.document);
    assert.notEqual(copy, null);
    assert.equal(copy.parentElement, page.document.body);
    assert.equal(copy.style.position, 'fixed');
    assert.equal(copy.querySelectorAll('a[href]').length, 3);
    assert.equal(page.engine.stats().keep[0].matches, 1);
  });

  test('navigate for the copy\'s links, then drop the copy', async () => {
    const page = boot({ body: bar, config: { keep, routes: ROUTES, popstateNavigation: true } });
    const { window, document } = page;
    await openMessages(page);
    const rendered = [];
    window.addEventListener('popstate', () => rendered.push(window.location.pathname));
    const event = click(window, copyOf(document).querySelector('a[href="/someone/"]'));
    assert.equal(event.defaultPrevented, true);
    await settle(window);
    assert.deepEqual(rendered, ['/someone/']);
    assert.equal(copyOf(document), null);
  });

  test('leave other pages alone, and remove the copy when switched off', async () => {
    const page = boot({ body: bar, config: { keep, routes: ROUTES } });
    page.window.history.pushState({}, '', '/explore/search/');
    page.document.getElementById('bar').remove();
    await wait(page.window, 150);
    assert.equal(copyOf(page.document), null);

    page.window.history.pushState({}, '', '/direct/inbox/');
    await wait(page.window, 150);
    assert.notEqual(copyOf(page.document), null);
    page.engine.update({ hosts: HOSTS, routes: [], hide: [], hideByText: [], prune: [], keep: [] });
    assert.equal(copyOf(page.document), null);
  });
});

describe('fullscreen repair', () => {
  // jsdom has no Fullscreen API, so these stand in the stuck state: the page
  // still reports a fullscreen element after the WebView has left fullscreen.
  function stuckOn(window, element) {
    Object.defineProperty(window.document, 'fullscreenElement', {
      configurable: true,
      get: () => (element.isConnected ? element : null),
    });
  }

  test('takes a stuck fullscreen element out and puts it back in place', () => {
    const page = boot({
      body: '<div id="before"></div><div id="player"><video id="video"></video></div><div id="after"></div>',
    });
    const { window, document } = page;
    const player = document.getElementById('player');
    const video = document.getElementById('video');
    stuckOn(window, player);
    const removals = [];
    new window.MutationObserver((records) => {
      for (const r of records) for (const n of r.removedNodes) removals.push(n.id);
    }).observe(document.body, { childList: true });
    let resized = 0;
    window.addEventListener('resize', () => resized++);

    // The removal is what ends fullscreen for the page; jsdom can't show that,
    // so check the element really left the document and came back.
    assert.equal(page.engine.repairFullscreen(), true);
    assert.equal(player.previousElementSibling.id, 'before');
    assert.equal(player.nextElementSibling.id, 'after');
    assert.equal(player.firstElementChild, video);
    assert.equal(resized, 1);
    return Promise.resolve().then(() => assert.deepEqual(removals, ['player']));
  });

  test('only fires a resize when the page is not stuck', () => {
    const page = boot({ body: '<div id="player"></div>' });
    let resized = 0;
    page.window.addEventListener('resize', () => resized++);
    assert.equal(page.engine.repairFullscreen(), false);
    assert.equal(resized, 1);
  });
});

describe('lifecycle', () => {
  test('applies a new config to the open page', async () => {
    const page = boot({
      body: '<a id="reels" href="/reels/">Reels</a><article id="ad"><span>Sponsored</span></article>',
      config: {
        hide: [{ id: 'reels', selector: 'a[href^="/reels/"]', paths: null }],
        hideByText: [{ id: 'ads', container: 'article', marker: 'span', text: ['Sponsored'], paths: null }],
      },
    });
    const { window, document } = page;
    assert.equal(hidden(window, document.getElementById('reels')), true);
    assert.equal(hidden(window, document.getElementById('ad')), true);

    page.engine.update({ hosts: HOSTS, routes: [], hide: [], hideByText: [] });
    assert.equal(hidden(window, document.getElementById('reels')), false);
    assert.equal(document.getElementById('ad').hasAttribute('data-lite-hidden'), false);
  });

  test('switches a text rule between collapsing and hiding, and off', () => {
    const rule = { id: 'ads', container: 'article', marker: 'span', text: ['Sponsored'], paths: null, collapse: true };
    const page = boot({
      body: '<article id="ad"><span>Sponsored</span></article>',
      config: { hideByText: [rule] },
    });
    const ad = page.document.getElementById('ad');
    assert.equal(ad.getAttribute('data-lite-collapsed'), 'ads');

    page.engine.update({ hosts: HOSTS, routes: [], hide: [], hideByText: [{ ...rule, collapse: false }] });
    assert.equal(ad.hasAttribute('data-lite-collapsed'), false);
    assert.equal(ad.getAttribute('data-lite-hidden'), 'ads');

    page.engine.update({ hosts: HOSTS, routes: [], hide: [], hideByText: [] });
    assert.equal(ad.hasAttribute('data-lite-hidden'), false);
  });

  test('redirects away when a new config blocks the open page', async () => {
    const page = boot({ url: 'https://www.instagram.com/reels/' });
    assert.deepEqual(page.navigations, []);
    page.engine.update({ hosts: HOSTS, routes: ROUTES, hide: [], hideByText: [] });
    await settle(page.window);
    assert.deepEqual(page.navigations, [['replace', '/?variant=following']]);
  });

  test('updates the running engine when injected again', () => {
    const page = boot({ body: '<a id="x" class="x">x</a>' });
    page.inject({ hide: [{ id: 'x', selector: '.x', paths: null }] });
    assert.equal(page.window.__liteEngine, page.engine);
    assert.equal(hidden(page.window, page.document.getElementById('x')), true);

    page.messages.length = 0;
    page.window.history.pushState({}, '', '/someone/');
    assert.deepEqual(page.messages, [{ type: 'route', path: '/someone/' }]);
  });

  test('does nothing on other sites', () => {
    const page = boot({ url: 'https://example.com/' });
    assert.equal(page.window.__liteEngine, undefined);
  });

  test('queues messages until the app bridge is ready', () => {
    const page = boot({ bridge: false });
    const messages = [];
    installBridge(page.window, messages);
    page.window.dispatchEvent(new page.window.Event('flutterInAppWebViewPlatformReady'));
    assert.deepEqual(messages, [{ type: 'route', path: '/direct/inbox/' }]);
  });
});
