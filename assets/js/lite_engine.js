// Lite engine: hides distracting parts of a site and blocks routes.
//
// The app injects this at document start, before any page script runs,
// wrapped by lib/src/webview/engine_config.dart as:
//
//   (function () { <this file> liteEngine(<config>); })();
//
// <config> is data compiled from assets/rules/*.json: URL patterns, CSS
// selectors and text labels. Keep site-specific knowledge in the rules, not
// here, so a fix for a site change can ship as a rules update without an app
// release. Rules must stay data: app stores reject apps that download code.
//
// Sites such as Instagram and YouTube are single-page apps: a page load
// happens once and navigation goes through history.pushState. The engine
// therefore works in layers:
//   1. CSS injected before first paint hides elements without a flash.
//   2. A capture-phase click listener stops links to blocked routes before
//      the site's router sees them.
//   3. pushState/replaceState/popstate hooks catch navigation that doesn't
//      come from a link.
//   4. A MutationObserver hides elements that can only be found by their
//      text (such as "Sponsored") as the page streams them in, before the
//      next frame, then fires a scroll event so the feed loads more.
//   5. JSON.parse and Response.json are wrapped, and globals that pages
//      assign their data to are trapped, so prune rules can delete data
//      (such as injected story ads) before the page renders it.
// Keep rules also put back a tab bar on pages where the site drops it.
// The app's shouldOverrideUrlLoading handles full page loads.
//
// `env` is only passed by tests, to observe full page navigations.
function liteEngine(input, env) {
  'use strict';

  if (window.top !== window) return;
  if (window.__liteEngine) {
    // Android re-runs document-start scripts at page finish when the WebView
    // lacks DOCUMENT_START_SCRIPT support, and the app re-injects on
    // settings changes. Either way, update the running engine.
    window.__liteEngine.update(input);
    return;
  }
  if ((input.hosts || []).indexOf(location.hostname) === -1) return;

  var nav = env || {
    assign: function (url) { location.assign(url); },
    replace: function (url) { location.replace(url); },
  };

  var HIDDEN = 'data-lite-hidden';
  var KEPT = 'data-lite-kept';
  var COLLAPSED = 'data-lite-collapsed';
  var ACTIVE = 'data-lite-active';
  var REDIRECTING = 'data-lite-redirecting';
  var MAX_HOPS = 5;
  var LOOP_KEY = 'lite.loop';
  var LOOP_WINDOW_MS = 5000;
  var LOOP_LIMIT = 3;
  var REDIRECT_TIMEOUT_MS = 1500;
  var MAX_LABEL_LENGTH = 80;

  var config = compile(input);
  var hookedGlobals = {};
  var keptTimer = 0;
  var sheet = null;
  var styleElement = null;
  var lastPath = null;
  var redirectingTimer = 0;
  var bridgeQueue = [];
  var loop = { count: 0, t: 0 };
  // Attributes the engine wants on <html>. Document-start scripts can run
  // before <html> exists, so they are applied whenever it is available.
  var rootState = { active: '', redirecting: false };

  // ---------------------------------------------------------------- config

  function compile(raw) {
    var errors = [];

    function regex(source, id) {
      if (source === undefined || source === null) return { ok: true, re: null };
      try {
        return { ok: true, re: new RegExp(source) };
      } catch (e) {
        errors.push({ id: id, error: 'Invalid pattern: ' + e.message });
        return { ok: false, re: null };
      }
    }

    function selector(source, id) {
      if (typeof source === 'string' && source.trim() && isValidSelector(source)) return true;
      errors.push({ id: id, error: 'Invalid or unsupported selector: ' + source });
      return false;
    }

    var routes = [];
    (raw.routes || []).forEach(function (r) {
      var match = regex(r.match, r.id);
      if (!match.ok || !match.re) return;
      routes.push({
        id: r.id,
        re: match.re,
        action: r.action,
        to: r.to,
        label: r.label || null,
        signedOut: r.signedOut === true,
      });
    });

    var hide = [];
    (raw.hide || []).forEach(function (h, index) {
      var paths = regex(h.paths, h.id);
      if (!paths.ok || !selector(h.selector, h.id)) return;
      hide.push({
        id: h.id,
        selector: h.selector,
        paths: paths.re,
        collapse: h.collapse === true,
        token: 'h' + index,
      });
    });

    var style = [];
    (raw.style || []).forEach(function (r, index) {
      var paths = regex(r.paths, r.id);
      if (!paths.ok || !selector(r.selector, r.id)) return;
      var declarations = cssDeclarations(r.css);
      if (!declarations) {
        errors.push({ id: r.id, error: 'Invalid CSS: ' + r.css });
        return;
      }
      style.push({ id: r.id, selector: r.selector, declarations: declarations, paths: paths.re, token: 's' + index });
    });

    var text = [];
    (raw.hideByText || []).forEach(function (t) {
      var paths = regex(t.paths, t.id);
      var pattern = regex(t.pattern, t.id);
      if (!paths.ok || !pattern.ok) return;
      if (!selector(t.container, t.id) || !selector(t.marker, t.id)) return;
      var labels = {};
      (t.text || []).forEach(function (label) { labels[normalizeText(label)] = true; });
      text.push({
        id: t.id,
        container: t.container,
        marker: t.marker,
        labels: labels,
        pattern: pattern.re,
        paths: paths.re,
        collapse: t.collapse === true,
      });
    });

    var prune = [];
    (raw.prune || []).forEach(function (r) {
      var paths = regex(r.paths, r.id);
      if (!paths.ok) return;
      prune.push({
        id: r.id,
        segments: String(r.path).split('.'),
        global: typeof r.global === 'string' && r.global ? r.global : null,
        paths: paths.re,
        removed: 0,
      });
    });

    var keep = [];
    (raw.keep || []).forEach(function (k) {
      var paths = regex(k.paths, k.id);
      if (!paths.ok || !paths.re || !selector(k.marker, k.id)) return;
      keep.push({ id: k.id, marker: k.marker, paths: paths.re, snapshot: null });
    });

    var session = Array.isArray(raw.session) && raw.session.length ? raw.session.slice() : null;
    return {
      hosts: raw.hosts || [],
      popstateNavigation: raw.popstateNavigation === true,
      session: session,
      signedIn: typeof raw.signedIn === 'boolean' ? raw.signedIn : null,
      keep: keep,
      routes: routes,
      hide: hide,
      style: style,
      text: text,
      prune: prune,
      errors: errors,
    };
  }

  function isValidSelector(source) {
    try {
      // Parses the selector without searching the page. Throws on invalid
      // syntax and on pseudo-classes the WebView doesn't support (e.g. :has
      // on old WebViews), so one bad rule never breaks the others.
      document.createDocumentFragment().querySelector(source);
      return true;
    } catch (e) {
      return false;
    }
  }

  // The declarations of a style rule, such as "transform: none", each to be
  // applied with !important. Null if they could do more than style the page
  // (load a URL) or break out of their rule; the app checks the same.
  function cssDeclarations(css) {
    if (typeof css !== 'string' || /[{}<>@\\]|url\(|\/\*/i.test(css)) return null;
    var declarations = css.split(';').map(function (d) {
      return d.trim().replace(/\s*!important$/i, '');
    }).filter(function (d) { return d; });
    var valid = declarations.length > 0 && declarations.every(function (d) {
      return /^-?[a-z][a-z-]*\s*:\s*\S/i.test(d);
    });
    return valid ? declarations : null;
  }

  function normalizeText(value) {
    return String(value).replace(/\s+/g, ' ').trim();
  }

  // ---------------------------------------------------------------- routes

  function currentPath() {
    return location.pathname + location.search;
  }

  function sameOriginPath(url) {
    try {
      var parsed = new URL(String(url), location.href);
      return parsed.origin === location.origin ? parsed.pathname + parsed.search : null;
    } catch (e) {
      return null;
    }
  }

  // Keep in sync with RouteResolver in lib/src/rules/route_resolver.dart.
  // test/fixtures/route_cases.json runs against both.
  function resolve(path) {
    var current = path;
    var changed = false;
    var blocked = null;
    var signedIn = isSignedIn();
    for (var hop = 0; hop < MAX_HOPS; hop++) {
      var rule = null;
      var target = null;
      for (var i = 0; i < config.routes.length; i++) {
        if (config.routes[i].signedOut && signedIn) continue;
        var match = config.routes[i].re.exec(current);
        if (match) {
          rule = config.routes[i];
          target = expand(rule.to, match);
          break;
        }
      }
      if (!rule || target === current) break;
      if (rule.action === 'block' && blocked === null) blocked = rule.label || 'Page';
      current = target;
      changed = true;
    }
    return { path: current, changed: changed, blocked: blocked };
  }

  // Whether the user is signed in. The app decides from the WebView's cookie
  // store, which also holds the HttpOnly cookies page scripts can't see
  // (Reddit's session is one), and sends the answer with the config, again
  // whenever it changes. Without it, any of the session cookies the rules
  // name being set in the page counts. Sites without a session count as
  // signed in.
  function isSignedIn() {
    if (!config.session) return true;
    if (config.signedIn !== null) return config.signedIn;
    var names = {};
    String(document.cookie).split(';').forEach(function (pair) {
      var name = pair.split('=')[0].trim();
      if (name) names[name] = true;
    });
    return config.session.some(function (name) { return names[name] === true; });
  }

  // Fills in $1 to $9 in a route target from the match. A group that didn't
  // take part in the match, or doesn't exist, becomes empty.
  function expand(target, match) {
    return target.replace(/\$(\d)/g, function (reference, group) {
      return match[group] === undefined ? '' : match[group];
    });
  }

  // Stops redirect loops, e.g. if the site starts sending a target page back
  // to a blocked one. A loop redirects again and again with nobody touching
  // the page, while in normal use a tap comes between redirects. So this
  // counts redirects in a row, and a real click or key press resets the
  // count. Stored in sessionStorage because a loop can span full page loads,
  // which restart the engine.
  function loopAllows() {
    var now = Date.now();
    var state = readLoop();
    var count = (now - state.t < LOOP_WINDOW_MS ? state.count : 0) + 1;
    writeLoop({ count: count, t: now });
    return count <= LOOP_LIMIT;
  }

  function onUserInput(event) {
    if (event.isTrusted && loop.count) writeLoop({ count: 0, t: 0 });
  }

  function readLoop() {
    try {
      var stored = JSON.parse(sessionStorage.getItem(LOOP_KEY));
      if (stored && typeof stored.count === 'number') loop = stored;
    } catch (e) {
      // Unavailable or unset: use the in-memory copy.
    }
    return loop;
  }

  function writeLoop(state) {
    loop = state;
    try {
      sessionStorage.setItem(LOOP_KEY, JSON.stringify(state));
    } catch (e) {
      // Storage unavailable; the in-memory copy still covers in-page loops.
    }
  }

  // Sends the page to res.path. Returns true if the caller must cancel the
  // navigation it was about to do.
  function redirect(res, from, options) {
    if (res.blocked) post({ type: 'blocked', label: res.blocked, path: from });
    if (!loopAllows()) {
      if (!res.blocked) return false; // A redirect that loops is let through.
      setRedirecting(true, 0); // A block that loops keeps the page hidden.
      post({ type: 'stuck', label: res.blocked, path: from });
      return true;
    }
    setRedirecting(true, REDIRECT_TIMEOUT_MS);
    if (options.defer) {
      setTimeout(function () { go(res.path, options.replace); }, 0);
    } else {
      go(res.path, options.replace);
    }
    return true;
  }

  function go(path, replace) {
    if (path === currentPath()) {
      setRedirecting(false);
      window.scrollTo(0, 0);
      return;
    }
    if (!replace) {
      // Clicking a matching link lets the site's router navigate without a
      // full reload. The click passes our own listener because path is
      // already resolved.
      var link = findLink(path);
      if (link) {
        link.click();
        return;
      }
    }
    // Some sites' routers render whatever URL a popstate event finds there
    // (Instagram's does), so the engine can navigate without a reload even
    // with no link to click. Not while the page is still loading, when the
    // router isn't running yet.
    if (config.popstateNavigation && document.readyState !== 'loading') {
      history[replace ? 'replaceState' : 'pushState'](null, '', path);
      window.dispatchEvent(new PopStateEvent('popstate', { state: null }));
      return;
    }
    if (replace) {
      nav.replace(path);
    } else {
      nav.assign(path);
    }
  }

  // A link to path that the site's own code handles: not one in a kept copy
  // (see keep rules), which the engine navigates for.
  function findLink(path) {
    var links = document.querySelectorAll('a[href]');
    for (var i = 0; i < links.length; i++) {
      if (links[i].getAttribute('href') === path && !links[i].closest('[' + KEPT + ']')) return links[i];
    }
    return null;
  }

  // While a redirect is under way the page is hidden, so a blocked page
  // doesn't flash up. The timeout shows it again if the redirect stalls.
  function setRedirecting(on, timeoutMs) {
    clearTimeout(redirectingTimer);
    rootState.redirecting = on;
    syncRoot();
    if (on && timeoutMs) {
      redirectingTimer = setTimeout(function () { setRedirecting(false); }, timeoutMs);
    }
  }

  function syncRoot() {
    var root = document.documentElement;
    if (!root) return;
    if (rootState.active) {
      if (root.getAttribute(ACTIVE) !== rootState.active) root.setAttribute(ACTIVE, rootState.active);
    } else if (root.hasAttribute(ACTIVE)) {
      root.removeAttribute(ACTIVE);
    }
    if (rootState.redirecting !== root.hasAttribute(REDIRECTING)) {
      if (rootState.redirecting) {
        root.setAttribute(REDIRECTING, '');
      } else {
        root.removeAttribute(REDIRECTING);
      }
    }
  }

  function onRoute() {
    var path = currentPath();
    if (path === lastPath) return;
    lastPath = path;
    setRedirecting(false);
    applyPathRules(path);
    refreshTextRules();
    refreshKept();
    post({ type: 'route', path: path });
  }

  function hookHistory() {
    ['pushState', 'replaceState'].forEach(function (name) {
      var original = History.prototype[name];
      History.prototype[name] = function (state, title, url) {
        if (url !== undefined && url !== null) {
          var target = sameOriginPath(url);
          if (target !== null && target !== currentPath()) {
            var res = resolve(target);
            // Deferred: we are inside the site's router here.
            if (res.changed && redirect(res, target, {
              replace: name === 'replaceState',
              defer: true,
            })) {
              return undefined;
            }
          }
        }
        var result = original.apply(this, arguments);
        onRoute();
        return result;
      };
    });
  }

  function onPopState(event) {
    var path = currentPath();
    var res = resolve(path);
    // Registered at document start, so this runs before the site's own
    // popstate listener and can keep it from rendering the blocked page.
    if (res.changed && redirect(res, path, { replace: true, defer: false })) {
      event.stopImmediatePropagation();
      return;
    }
    onRoute();
  }

  function onClick(event) {
    onUserInput(event);
    if (event.defaultPrevented || event.button !== 0) return;
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    var link = event.target && event.target.closest ? event.target.closest('a[href]') : null;
    if (!link) return;
    var href = link.getAttribute('href');
    if (href.charAt(0) === '#') return; // Same-page anchors don't navigate.
    var target = sameOriginPath(href);
    if (target === null) return;
    var res = resolve(target);
    if (res.changed && redirect(res, target, { replace: false, defer: true })) {
      event.preventDefault();
      event.stopImmediatePropagation();
      return;
    }
    // A link in a kept copy has none of the site's own handlers, so the
    // engine navigates for it, as the site's link would have.
    if (link.closest('[' + KEPT + ']')) {
      event.preventDefault();
      event.stopImmediatePropagation();
      setTimeout(function () { go(target, false); }, 0);
    }
  }

  // ---------------------------------------------------------------- styles

  function createSheet() {
    try {
      if ('adoptedStyleSheets' in document && typeof CSSStyleSheet === 'function') {
        // Constructed sheets need no DOM node, so they work before <head>
        // exists and the page can't remove them by rewriting the DOM.
        sheet = new CSSStyleSheet();
        sheet.replaceSync('');
        document.adoptedStyleSheets = document.adoptedStyleSheets.concat([sheet]);
        return;
      }
    } catch (e) {
      sheet = null;
    }
    styleElement = document.createElement('style');
    styleElement.setAttribute('data-lite', '');
    ensureStyles();
  }

  // A collapsed element stays in the layout as an empty box of zero height,
  // where display: none takes it out. Feeds that render only the posts near
  // the screen need this: Instagram's measures each post from its top to the
  // next post's top, and an element with display: none reports a top of 0,
  // which corrupts the feed's positions. It then stops rendering posts (the
  // screen goes blank) and jumps while scrolling.
  function collapseRules(target) {
    return [
      target + ' { height: 0 !important; min-height: 0 !important; margin: 0 !important;' +
        ' padding: 0 !important; border: 0 !important; flex: none !important;' +
        ' overflow: hidden !important; visibility: hidden !important; }',
      ':is(' + target + ') > * { display: none !important; }',
    ];
  }

  function cssText() {
    var rules = [
      '[' + HIDDEN + '] { display: none !important; }',
      'html[' + REDIRECTING + '] body { visibility: hidden !important; }',
    ].concat(collapseRules('[' + COLLAPSED + ']'));
    config.hide.forEach(function (h) {
      var target = scoped(h);
      if (h.collapse) {
        rules.push.apply(rules, collapseRules(target));
      } else {
        rules.push(target + ' { display: none !important; }');
      }
    });
    config.style.forEach(function (r) {
      rules.push(scoped(r) + ' { ' + r.declarations.map(function (d) { return d + ' !important'; }).join('; ') + '; }');
    });
    // One rule per line: the CSS parser drops an unsupported rule on its own
    // and keeps the rest.
    return rules.join('\n');
  }

  // The selector of a hide or style rule, limited to its pages if it has any.
  function scoped(rule) {
    return rule.paths ? 'html[' + ACTIVE + '~="' + rule.token + '"] :is(' + rule.selector + ')' : rule.selector;
  }

  function renderStyles() {
    if (sheet) {
      sheet.replaceSync(cssText());
    } else if (styleElement) {
      styleElement.textContent = cssText();
    }
  }

  // The site could replace adoptedStyleSheets or remove our <style> element.
  function ensureStyles() {
    if (sheet) {
      if (document.adoptedStyleSheets.indexOf(sheet) === -1) {
        document.adoptedStyleSheets = document.adoptedStyleSheets.concat([sheet]);
      }
    } else if (styleElement && !styleElement.isConnected) {
      var parent = document.head || document.documentElement;
      if (parent) parent.appendChild(styleElement);
    }
  }

  // Path-scoped hide rules are switched on through a token list on <html>,
  // which their CSS selectors check. This avoids rebuilding the stylesheet
  // on every navigation.
  function applyPathRules(path) {
    rootState.active = config.hide
      .concat(config.style)
      .filter(function (h) { return h.paths && h.paths.test(path); })
      .map(function (h) { return h.token; })
      .join(' ');
    syncRoot();
  }

  // ------------------------------------------------------------ text rules

  function activeTextRules() {
    var path = currentPath();
    return config.text.filter(function (t) { return !t.paths || t.paths.test(path); });
  }

  // Returns how many containers it hid.
  function scan(nodes) {
    var rules = activeTextRules();
    var count = 0;
    if (!rules.length) return count;
    nodes.forEach(function (node) {
      if (!node.isConnected) return;
      rules.forEach(function (rule) {
        if (node.matches(rule.marker) && check(node, rule)) count++;
        var candidates = node.querySelectorAll(rule.marker);
        for (var i = 0; i < candidates.length; i++) {
          if (check(candidates[i], rule)) count++;
        }
      });
    });
    return count;
  }

  // Returns true if it hid the element's container.
  function check(element, rule) {
    // Labels in server-rendered markup can carry far more whitespace than
    // text (Reddit's 7-letter "For You" tab has 83 characters), so the
    // limit applies once whitespace is collapsed. The looser check first
    // skips long text without the work of collapsing it.
    var text = element.textContent;
    if (!text || text.length > MAX_LABEL_LENGTH * 4) return false;
    text = normalizeText(text);
    if (text.length > MAX_LABEL_LENGTH) return false;
    if (!rule.labels[text] && !(rule.pattern && rule.pattern.test(text))) return false;
    var container = element.closest(rule.container);
    if (!container || container.hasAttribute(HIDDEN) || container.hasAttribute(COLLAPSED)) return false;
    container.setAttribute(markFor(rule), rule.id);
    return true;
  }

  // The attribute that hides a text rule's containers.
  function markFor(rule) {
    return rule.collapse ? COLLAPSED : HIDDEN;
  }

  // Re-applies text rules after a navigation or config change: shows what
  // no longer applies, then hides what now matches.
  function refreshTextRules() {
    var active = {};
    activeTextRules().forEach(function (t) { active[t.id] = markFor(t); });
    [HIDDEN, COLLAPSED].forEach(function (mark) {
      var marked = document.querySelectorAll('[' + mark + ']');
      for (var i = 0; i < marked.length; i++) {
        if (active[marked[i].getAttribute(mark)] !== mark) marked[i].removeAttribute(mark);
      }
    });
    if (document.body) scan([document.body]);
  }

  function observe() {
    new MutationObserver(function (records) {
      var nodes = [];
      for (var i = 0; i < records.length; i++) {
        var added = records[i].addedNodes;
        for (var j = 0; j < added.length; j++) {
          var node = added[j];
          if (node.nodeType === 1) {
            nodes.push(node);
          } else if (node.nodeType === 3 && node.parentElement) {
            nodes.push(node.parentElement);
          }
        }
      }
      // Scanned now, not in the next frame: feeds measure new posts in an
      // animation frame, and must find the hidden ones already collapsed.
      // A big batch is cheaper to handle as one pass over the page.
      if (nodes.length && scan(nodes.length > 300 && document.body ? [document.body] : nodes)) {
        // Feeds load more posts when they see a scroll. If every new post was
        // hidden, the page may not grow enough to scroll, or the user may
        // already be at the bottom, and the feed would stall. A scroll event,
        // as the browser fires it, makes the feed check again.
        document.dispatchEvent(new Event('scroll', { bubbles: true }));
      }
      scheduleKept();
      ensureStyles();
      syncRoot();
    }).observe(document, { childList: true, subtree: true });
  }

  // ------------------------------------------------------------ keep rules

  // Some sites drop their tab bar on some pages (Instagram does in messages).
  // A keep rule remembers the fixed-position bar around its marker while the
  // page shows it, and on the rule's pages, when the bar is gone, shows a
  // copy of it. The copy looks the same because the site's styles still
  // apply; the engine navigates for its links (see onClick).
  function refreshKept() {
    clearTimeout(keptTimer);
    keptTimer = 0;
    // Copies whose rule was switched off.
    var ids = config.keep.map(function (k) { return k.id; });
    var copies = document.querySelectorAll('[' + KEPT + ']');
    for (var i = 0; i < copies.length; i++) {
      if (ids.indexOf(copies[i].getAttribute(KEPT)) === -1) copies[i].parentNode.removeChild(copies[i]);
    }
    if (!config.keep.length) return;
    var path = currentPath();
    config.keep.forEach(function (rule) {
      var live = liveMarker(rule.marker);
      var bar = live ? fixedAncestor(live) : null;
      if (bar) rule.snapshot = bar.cloneNode(true);
      var copy = document.querySelector('[' + KEPT + '="' + rule.id + '"]');
      var wanted = !live && rule.snapshot !== null && rule.paths.test(path);
      if (wanted && !copy && document.body) {
        copy = rule.snapshot.cloneNode(true);
        copy.setAttribute(KEPT, rule.id);
        document.body.appendChild(copy);
      } else if (!wanted && copy) {
        copy.parentNode.removeChild(copy);
      }
    });
  }

  function scheduleKept() {
    if (config.keep.length && !keptTimer) keptTimer = setTimeout(refreshKept, 100);
  }

  function liveMarker(selector) {
    var found = document.querySelectorAll(selector);
    for (var i = 0; i < found.length; i++) {
      if (!found[i].closest('[' + KEPT + ']')) return found[i];
    }
    return null;
  }

  function fixedAncestor(element) {
    for (var node = element.parentElement; node && node !== document.body; node = node.parentElement) {
      if (getComputedStyle(node).position === 'fixed') return node;
    }
    return null;
  }

  // ------------------------------------------------------------ data rules

  // Prune rules delete data before the page renders it, e.g. the story ads
  // Instagram injects into its API responses. A path is property names
  // joined by dots, where `[]` means every element of an array and `[-]`
  // removes the array elements in which the rest of the path leads to a
  // value other than null or false:
  //   data.xdt_injected_story_units.ad_media_items
  //   data.feed.edges.[-].node.ad
  //   itemList.[-].isAd
  // A rule with `global` applies to the value a page assigns to that global
  // variable instead of to JSON, for data embedded in a script, such as
  // `var ytInitialPlayerResponse = {...}` on YouTube. A rule with `paths`
  // only applies while the page's path and query match, such as TikTok's
  // For You videos, which it loads after a video someone sends you.
  function hookJson() {
    var parse = JSON.parse;
    JSON.parse = function () {
      return pruneValue(parse.apply(this, arguments));
    };
    if (window.Response && Response.prototype.json) {
      var json = Response.prototype.json;
      Response.prototype.json = function () {
        return json.apply(this, arguments).then(pruneValue);
      };
    }
  }

  // Traps assignments to the globals that prune rules name. A `var`
  // declaration in a page script keeps an existing property and assigns
  // through its setter, so the page's data passes through pruneValue.
  function hookGlobals() {
    config.prune.forEach(function (rule) {
      var name = rule.global;
      if (!name || hookedGlobals[name]) return;
      hookedGlobals[name] = true;
      var value = pruneValue(window[name], name);
      try {
        Object.defineProperty(window, name, {
          configurable: true,
          enumerable: true,
          get: function () { return value; },
          set: function (next) { value = pruneValue(next, name); },
        });
      } catch (e) {
        // A global the page made unconfigurable; leave it alone.
      }
    });
  }

  // Applies the prune rules for `global`, or the JSON rules without it.
  function pruneValue(value, global) {
    if (value === null || typeof value !== 'object') return value;
    var target = global || null;
    var path = null;
    for (var i = 0; i < config.prune.length; i++) {
      var rule = config.prune[i];
      if (rule.global !== target) continue;
      if (rule.paths) {
        if (path === null) path = currentPath();
        if (!rule.paths.test(path)) continue;
      }
      try {
        rule.removed += pruneAt(value, rule.segments, 0);
      } catch (e) {
        // Never let a rule break the site's own parsing.
      }
    }
    return value;
  }

  // Returns how many properties or array elements were removed.
  function pruneAt(value, segments, index) {
    if (value === null || typeof value !== 'object') return 0;
    var segment = segments[index];
    var removed = 0;
    if (segment === '[]' || segment === '[-]') {
      if (!Array.isArray(value)) return 0;
      for (var i = value.length - 1; i >= 0; i--) {
        if (segment === '[]') {
          removed += pruneAt(value[i], segments, index + 1);
        } else if (pathExists(value[i], segments, index + 1)) {
          value.splice(i, 1);
          removed += 1;
        }
      }
      return removed;
    }
    if (!Object.prototype.hasOwnProperty.call(value, segment)) return 0;
    if (index === segments.length - 1) {
      delete value[segment];
      return 1;
    }
    return pruneAt(value[segment], segments, index + 1);
  }

  // Whether the rest of the path leads to a value. APIs often send every
  // field and set the unused ones to null, or a flag such as isAd to false
  // on every item but the ones it marks, so neither counts.
  function pathExists(value, segments, index) {
    if (index === segments.length) return value !== null && value !== undefined && value !== false;
    if (value === null || typeof value !== 'object') return false;
    var segment = segments[index];
    if (segment === '[]' || segment === '[-]') {
      return Array.isArray(value) && value.some(function (item) {
        return pathExists(item, segments, index + 1);
      });
    }
    return Object.prototype.hasOwnProperty.call(value, segment) &&
      pathExists(value[segment], segments, index + 1);
  }

  // ---------------------------------------------------------------- bridge

  function post(message) {
    var bridge = window.flutter_inappwebview;
    if (bridge && typeof bridge.callHandler === 'function') {
      try {
        var pending = bridge.callHandler('lite', message);
        if (pending && typeof pending.catch === 'function') pending.catch(function () {});
      } catch (e) {
        // The app went away; nothing to report to.
      }
      return;
    }
    bridgeQueue.push(message);
    if (bridgeQueue.length > 20) bridgeQueue.shift();
  }

  function flushBridge() {
    var queued = bridgeQueue.splice(0, bridgeQueue.length);
    queued.forEach(post);
  }

  // ------------------------------------------------------------------- api

  function update(raw) {
    var removed = {};
    var snapshots = {};
    config.prune.forEach(function (r) { removed[r.id] = r.removed; });
    config.keep.forEach(function (k) { snapshots[k.id] = k.snapshot; });
    config = compile(raw);
    config.prune.forEach(function (r) { r.removed = removed[r.id] || 0; });
    config.keep.forEach(function (k) { k.snapshot = snapshots[k.id] || null; });
    hookGlobals();
    renderStyles();
    lastPath = null;
    var path = currentPath();
    var res = resolve(path);
    if (res.changed && redirect(res, path, { replace: true, defer: true })) return;
    onRoute();
  }

  // Android's WebView can leave fullscreen without telling the page, which
  // then keeps its fullscreen element (such as YouTube's player) covering
  // everything. The app calls this once the WebView has left fullscreen.
  // Taking the element out of the document and putting it straight back
  // makes the page exit fullscreen (the spec treats removal as an exit). A
  // video inside stays loaded at the same point, though it may pause. A
  // resize event then makes the page lay itself out again. Returns whether
  // the page was stuck.
  function repairFullscreen() {
    var element = document.fullscreenElement || document.webkitFullscreenElement || null;
    if (element && element.parentNode) {
      var parent = element.parentNode;
      var next = element.nextSibling;
      parent.removeChild(element);
      parent.insertBefore(element, next);
    }
    window.dispatchEvent(new Event('resize'));
    return element !== null;
  }

  function stats() {
    var path = currentPath();
    return {
      path: path,
      errors: config.errors.slice(),
      hide: config.hide.map(function (h) {
        return {
          id: h.id,
          active: !h.paths || h.paths.test(path),
          matches: document.querySelectorAll(h.selector).length,
        };
      }),
      style: config.style.map(function (r) {
        return {
          id: r.id,
          active: !r.paths || r.paths.test(path),
          matches: document.querySelectorAll(r.selector).length,
        };
      }),
      hideByText: config.text.map(function (t) {
        return {
          id: t.id,
          active: !t.paths || t.paths.test(path),
          matches: document.querySelectorAll('[' + markFor(t) + '="' + t.id + '"]').length,
        };
      }),
      // Pruned counts are since the page loaded, not just this route.
      prune: config.prune.map(function (r) {
        return { id: r.id, active: !r.paths || r.paths.test(path), matches: r.removed };
      }),
      keep: config.keep.map(function (k) {
        return {
          id: k.id,
          active: k.paths.test(path),
          matches: document.querySelectorAll('[' + KEPT + '="' + k.id + '"]').length,
        };
      }),
    };
  }

  Object.defineProperty(window, '__liteEngine', {
    configurable: true,
    value: {
      update: update,
      stats: stats,
      repairFullscreen: repairFullscreen,
      resolve: function (path) { return resolve(String(path)); },
    },
  });

  // ----------------------------------------------------------------- start

  createSheet();
  renderStyles();
  hookJson();
  hookGlobals();
  hookHistory();
  window.addEventListener('popstate', onPopState, true);
  window.addEventListener('click', onClick, true);
  window.addEventListener('keydown', onUserInput, true);
  window.addEventListener('flutterInAppWebViewPlatformReady', flushBridge);
  document.addEventListener('DOMContentLoaded', function () {
    ensureStyles();
    syncRoot();
    refreshTextRules();
  });
  observe();

  readLoop();
  var startPath = currentPath();
  var start = resolve(startPath);
  if (start.changed && redirect(start, startPath, { replace: true, defer: false })) return;
  onRoute();
}
