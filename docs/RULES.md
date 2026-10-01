# Filter rules

Instagram, YouTube and Reddit change their web apps often, and filters break when
they do. This guide covers the rules format, how to check rules on a device,
and how to ship a fix without an app release. For why the rules work this
way, see [DESIGN.md](DESIGN.md).

## Where rules live

- Each site has one file in `assets/rules/`, named after its platform:
  `instagram.json`, `youtube.json` and `reddit.json`. They are bundled with
  the app, and they are also the files you publish.
- The published copies live in the folder the app is built with:
  `flutter run --dart-define=RULES_BASE_URL=https://.../assets/rules/`. The
  app downloads `<folder>/instagram.json`, `<folder>/youtube.json` and
  `<folder>/reddit.json`. A raw
  GitHub URL for the `assets/rules/` folder works. Without `RULES_BASE_URL`
  the app only uses its bundled rules.
- For each site, the app uses whichever of the bundled and published copies
  has the higher `revision`. Sites update independently.
- A new site also needs an entry in `siteCatalog` (`lib/src/site.dart`),
  which gives its name and icon.

## Format (schemaVersion 1)

Top level:

| Field | Meaning |
|---|---|
| `schemaVersion` | Format version. Apps ignore files with a version they don't know. |
| `platform` | `"instagram"`, `"youtube"` or `"reddit"`, matching the file name. A download for another platform is rejected. |
| `revision` | Integer. Bump it on every published change. |
| `updated`, `notes` | For people; the app ignores them. |
| `startUrl` | Where the app opens (route rules still apply). |
| `hosts` | The site's own hosts. Filters apply here. |
| `allowedHosts` | Other hosts that may load in the app. Anything else opens in the browser. |
| `linkShims` | Outbound-link redirectors: `host`, the query `param` holding the real URL, and optionally a `path`, for sites that redirect from their own host (`www.youtube.com`, `/redirect`, `q`). |
| `userAgent` | `"browser"` (the default) or `"system"`. |
| `popstateNavigation` | `true` if the site's router renders the URL it finds on a popstate event (Instagram's does). The engine then navigates inside the page when it has no link to click, instead of loading the page in full. |
| `session` | Optional `{ "cookies", "anonymousTokens"? }`: cookies the site sets while you're signed in. The user counts as signed out when none is set. The app reads them from the WebView's cookie store, HttpOnly ones included, and tells the page engine. `anonymousTokens` lists session cookies that the site sets for every visitor, as JSON Web Tokens: `{ "cookie", "claim", "value" }` means that cookie doesn't count while its token's `claim` is `value`. Reddit's `token_v2` has `"sub": "loid"` until you sign in. Needed by `signIn` and by routes marked `signedOut`. |
| `signIn` | Optional `{ "match", "to" }`: while you're signed out, every page whose path and query match `match` goes to the sign-in page `to`. Leave out the pages that signing in needs, such as signing up and resetting a password; `match` can't match `to`. Always on, and ahead of the features' routes, so switching a filter off can't skip it. Needs `session`. |
| `features` | The switches in Settings, in display order. |

A feature has an `id` (letters, digits, `_` and `-`; this is where the
user's choice is stored, so never rename one), a `title`, a `description`,
`enabledByDefault`, and any of these rule lists:

**`routes`**: `{ "match", "action", "to", "label"? }`

- `match` is a regular expression tested against the path plus query, such as
  `/explore/?hl=en` (no host, no `#fragment`). Anchor it with `^`.
- `action` is `block` (the user sees "*label* blocked") or `redirect`
  (silent).
- `to` is a path. It is resolved again, so `/reels/` → `/` → `/?variant=following`
  works. The first matching rule wins, and chains stop after 5 hops.
- With `"signedOut": true`, the rule only applies while the user is signed
  out (see `session`). The app checks after every page load and in-page
  navigation, and the engine applies a change to the open page. To send
  every signed-out page to the sign-in page, use `signIn` instead.
- `to` can use `$1` to `$9` for `match`'s capture groups:
  `"match": "^/shorts/([A-Za-z0-9_-]+)"` with `"to": "/watch?v=$1"` sends a
  Short to the normal video page. A group that didn't take part in the
  match becomes empty. A reference to a group that `match` doesn't have is
  rejected.
- `label` defaults to the feature's title.

**`hide`**: `{ "selector", "paths"?, "collapse"? }`

- Hides everything matching the CSS `selector`.
- With `paths` (a regular expression like `match`), it only applies on those
  pages.
- With `"collapse": true`, the element stays in the page as an empty box of
  zero height instead of being removed. Use it for every rule that hides a
  whole post in a feed. Instagram's feed renders only the posts near the
  screen, and measures each post from its top to the next post's top. A post
  removed with `display: none` reports a top of 0, which corrupts those
  measurements: the feed stops rendering posts (the screen goes blank) and
  jumps while scrolling. Leave it off for tabs, links and grid tiles, where
  an empty box could leave a gap.

**`hideByText`**: `{ "container", "marker", "text"?: [...], "pattern"?, "paths"?, "collapse"? }`

- Hides the nearest `container` around any `marker` element whose entire
  text (whitespace collapsed and trimmed) is one of `text` or matches the
  regular expression `pattern`. For example: an `article` containing a `span`
  that reads exactly "Sponsored", or matches `^Paid partnership(?: with .+)?$`.
- It needs `text`, `pattern` or both.
- Labels are localised, so list each language you want to cover.
- `collapse` works as it does for `hide`. Set it when the container is a
  post.

**`prune`**: `{ "path" }`

- Deletes data from the site's JSON (`JSON.parse` and `fetch` responses)
  before the page renders it, such as story ads injected into API
  responses.
- `path` is property names joined by dots. `[]` means every element of an
  array, and `[-]` removes the array elements in which the rest of the path
  leads to a value other than `null`:
  - `data.xdt_injected_story_units.ad_media_items` deletes that property.
  - `data.feed.edges.[-].node.ad` removes every edge whose node has an `ad`.
    Instagram's feed items have every slot (`media`, `ad`,
    `suggested_users`, ...) and set the unused ones to `null`, so a `null`
    doesn't count.
- With `"global": "name"`, the rule applies to the value a page script
  assigns to that global variable, instead of to JSON. YouTube embeds its
  player data on a full page load as `var ytInitialPlayerResponse = {...}`,
  which never goes through `JSON.parse`, so its ad rules come in both
  forms: `{ "path": "adPlacements" }` for data fetched while you browse,
  and `{ "path": "adPlacements", "global": "ytInitialPlayerResponse" }`
  for the first page.
- To find paths, open the Network panel in the inspector (see below), find
  the response carrying the unwanted item, and note the property path. The
  uBlock Origin and AdGuard filter lists are also good sources (their
  `json-prune` and `set` rules use the same idea).

**`style`**: `{ "selector", "css", "paths"? }`

- Applies CSS declarations, such as `transform: none`, to everything
  matching `selector`, each with `!important`, for layout fixes a hide rule
  can't make. `paths` works as it does for `hide`.
- Only declarations: `css` may not contain `{`, `}`, `<`, `>`, `@`, `\`,
  `url(` or comments, so a rule can't add other CSS or load anything. An
  app rejects a file with such a rule.
- YouTube uses it to cancel a slide that fullscreen leaves on a video's
  details, which YouTube only undoes when you scroll.

**`keep`**: `{ "marker", "paths" }`

- Puts back a tab bar on pages where the site drops it. While a page shows
  an element matching the CSS selector `marker`, the engine remembers the
  fixed-position bar around it. On pages matching `paths`, when the marker
  is gone, it shows a copy of that bar. The site's styles still apply to
  the copy, and the engine navigates for its links.
- Instagram uses it for the inbox, with the Messages tab link as the
  marker.

Any rule can have a `note`. The app ignores it. Say where the signal came
from, and include `unverified` for a rule that hasn't been checked against a
logged-in session yet.

### Writing selectors that last

Instagram's class names (`x1lliihq`, `_aagw`) are generated and change with
every build. Never use them. YouTube's mobile site is built from custom
elements whose names are stable (`ytm-video-with-context-renderer`,
`ytm-shorts-lockup-view-model`, `ytm-pivot-bar-item-renderer`); prefer
those, and its few meaningful attributes (`section-identifier`,
`tab-title`), over its class names. In order of preference:

1. **hrefs**: `a[href^="/reels/"]`. URL structure changes least.
2. **Roles and structure**: `article`, `[role="dialog"]`, `:has()`.
   For example, `div:has(> a[href="/reels/"]):not(:has(> :not(a[href="/reels/"])))`
   matches a wrapper whose only children are the Reels link.
3. **Text**, via `hideByText`, when nothing else identifies the element.
4. **Data**, via `prune`, for things injected from API responses (story ads).

For ads and suggestions, use several independent signals, so one site
change doesn't let everything through. "Hide ads", for example, uses the
link to Facebook's ad information page, the outbound call-to-action link, the
localised "Sponsored" label and the story-ad data path. Community filter
lists (the AdGuard and uBlock Origin lists, EasyList) track these signals on
the live site; search them for `instagram.com##`, `m.youtube.com##` and
`youtube.com##+js(`.

`aria-label` values are localised, so they only work for one language.
`:has()` needs Android WebView 105+ or iOS 15.4+. If a device doesn't support
a selector, the engine skips that rule and reports it in diagnostics; the
other rules still apply.

## Checking rules on a device

1. Run a debug build: `flutter run`. Debug builds allow the WebView to be
   inspected.
2. Open the inspector:
   - **Android**: in desktop Chrome, open `chrome://inspect`, then inspect
     the WebView.
   - **iOS**: turn on Web Inspector on the device (Settings → Safari →
     Advanced). Then in desktop Safari, open Develop → your device.
3. Open the site in the app first; each site has its own WebView. In the
   page's console:
   - `__liteEngine.stats()` lists each rule with its match count on this page.
   - `__liteEngine.resolve('/reels/')` shows where a path goes.
   - `document.querySelectorAll('a[href="/reels/"]')` tests a selector.
4. Without a computer, use **Settings → Rule diagnostics** while the site
   is open. A rule stuck at 0 matches where it should match is the usual
   sign of breakage.

Much of YouTube works logged out, so its rules can also be checked in a
desktop browser: set a mobile user agent (Chrome's device toolbar does
this), open `m.youtube.com`, and try selectors in the console.

Reddit's app-promotion rules were checked on mobile web; the remaining
Reddit selectors are unverified.

### Instagram checklist (revision 1)

Signed out, check:

- [ ] Instagram opens on its login page, and so does any other Instagram
      page, such as a profile someone links to. Sign up and Forgot
      password still work.

Log in with a username and password, then check:

- [ ] Home opens `/?variant=following` and shows only accounts you follow,
      also right after logging in.
- [ ] Scrolling far down Home, fast, keeps showing posts: no blank screen,
      and no jumping back.
- [ ] The Reels tab is gone, and the tab bar has no gap.
- [ ] Visiting `/reels/` goes to Home and shows "Reels blocked".
- [ ] A reel someone sends you in messages opens, and so does a
      `/reels/<code>/` link, as that reel on its own (`/reel/<code>/`).
- [ ] Tapping Home or Explore changes page without reloading it.
- [ ] The inbox has the tab bar at the bottom, and its tabs work. A
      conversation doesn't.
- [ ] The Explore tab opens search at `/explore/search/`: a search box and no
      grid. Searching for a person and opening their profile works.
- [ ] A hashtag page (`/explore/tags/...`) is blocked.
- [ ] Stories are absent from the Following feed.
- [ ] No ads in the feed or between stories. When an ad would have appeared,
      Rule diagnostics shows a match for one of the `hideSponsored` rules.
- [ ] No "Suggested for you" posts or account boxes, on Home or on profiles.
- [ ] A post someone sends you from an account you don't follow still opens.
- [ ] Posting works: new post → pick a photo → share. Also with the
      camera: new post → Camera → take a photo, and it opens in
      Instagram's editor (needs a full rebuild).
- [ ] A link in someone's bio opens in the browser.
- [ ] No "Open in app" prompts.

If `/explore/search/` isn't a real page on mobile web, change the
`hideExplore` redirect to go to a search page that exists.

### YouTube checklist (revision 1)

Checked logged out in headless Firefox: the Home and Shorts tabs, Shorts in
search and on channels, related videos, comments, the
Open App button, and the Home, Shorts, channel Shorts and Trending routes.
Still to check on a device:

- [x] Signing in works: Google accepted the password and 2-Step
  Verification in the app, and YouTube was signed in.
- [ ] The trip back after signing in stays in the app. If any step opens
      the browser instead, find its host (`adb logcat -d | grep
      'act=android.intent.action.VIEW'` shows it) and add it to
      `allowedHosts`.
- [ ] Signed out, YouTube opens on the You page ("You're not signed in",
      with a Sign in button), and so does every other page, such as a
      video someone links to.
- [ ] Signed in, it opens on Subscriptions, and so does tapping the YouTube
      logo. Signing out from YouTube's own menu lands on the You page. If
      signed in still sends you to the You page, the `session` cookies are
      wrong: check which cookies m.youtube.com has in the inspector's
      Application panel.
- [ ] The bottom bar has no Home or Shorts tab, and Subscriptions and You
      still work.
- [ ] No Shorts in the Subscriptions feed, whether as a shelf or as single
      videos. If some show, inspect them and extend the `hideShorts` rules.
- [ ] A Short someone sends you opens as a normal video.
- [ ] Watching a video shows its title, description and comments, but no
      recommendations underneath.
- [ ] When a video ends, no grid of suggestions or "Up next" countdown, and
      the next video doesn't start.
- [ ] No ads before or during videos. When one would have played, Rule
      diagnostics shows a match for one of the `hideAds` prune rules.
- [ ] No ads in search results or under the video.
- [ ] Fullscreen turns the phone to landscape (a portrait video stays
      portrait), and leaving it turns back and puts the video back above
      its title (see "Fullscreen video" in DESIGN.md).
- [ ] Playlists and Watch later play in order.
- [ ] A link in a video description opens in the browser.
- [ ] A YouTube link in Instagram (a bio, a message) opens in the app's
      YouTube, not the YouTube app.
- [ ] Switching to Instagram pauses a playing video.

### Reddit checklist (revision 5)

- [ ] Signed out, Reddit opens on its login page, and so does any other
      Reddit page. Sign up and Forgot password still work.
- [ ] "Continue with Google" opens Google's sign-in over Reddit. Signing
      in there closes it and signs you in to Reddit. If a step opens the
      browser instead, add its host to `allowedHosts`, as for YouTube.
- [ ] Signed in, Reddit stays signed in, across pages and after
      restarting the app. If it sends you to the login page while you're
      signed in, the `session` check is wrong: in the inspector's
      Application panel, decode the middle part of the `token_v2`
      cookie's value (base64) and fix `anonymousTokens` to match.
- [ ] Home shows posts from communities you've joined, with no For You
      tab.
- [ ] A link in a post opens in the browser, with no window left over
      Reddit.
- [x] The top-right `Open App` button is hidden.
- [x] The "Get the best of Reddit in the app" bottom sheet is hidden.
- [ ] Popular and All are blocked, while a subreddit and direct post open.
- [ ] Promoted and recommended posts are absent from feeds.

## Fixing a broken rule

1. Reproduce the problem, inspect the element, and find a stable hook (see
   above).
2. Edit the site's file in `assets/rules/`. Bump `revision` and set
   `updated`.
3. Run the tests. They validate the file and check the core routes:

   ```sh
   flutter test
   (cd test/js && npm install && npm test)
   ```
4. Try it on a device: a hot restart of a debug build picks up the bundled
   file. If the phone has a downloaded copy with a higher revision, that copy
   wins; use **Settings → Use built-in rules** for that site.
5. Publish: put the file in the `RULES_BASE_URL` folder, for example by
   pushing to the branch that URL points at. Apps pick it up within 6 hours,
   or right away with **Settings → Check for rule updates**.

## What rules can't do

Rules are data: patterns, selectors and labels. Never add JavaScript or any
other code to them. App stores reject apps that download code, and the
engine won't run it. If a fix needs new behaviour, such as a new kind of
rule:

1. Change `assets/js/lite_engine.js`.
2. Mirror any route logic in `lib/src/rules/route_resolver.dart`, and add
   cases to `test/fixtures/route_cases.json`.
3. Ship an app update.

Bump `schemaVersion` only for changes that older apps would misread. They
will ignore the new file and keep working with their current rules.
