# Filter rules

Instagram, YouTube, Reddit and TikTok change their web apps often, and filters
break when they do. This guide covers the rules format, how to check rules,
and how to ship a fix without an app release. For why the rules work this
way, see [DESIGN.md](DESIGN.md).

## Where rules live

- Each site has one file in `assets/rules/`, named after its platform:
  `instagram.json`, `youtube.json`, `reddit.json` and `tiktok.json`. They
  are bundled with the app, and they are also the files you publish.
- The published copies live in the folder the app is built with:
  `flutter run --dart-define=RULES_BASE_URL=https://.../assets/rules/`. The
  app downloads `<folder>/<platform>.json` for each site, such as
  `<folder>/tiktok.json`. A raw
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
| `platform` | `"instagram"`, `"youtube"`, `"reddit"` or `"tiktok"`, matching the file name. A download for another platform is rejected. |
| `revision` | Integer. Bump it on every published change. |
| `updated`, `notes` | For people; the app ignores them. |
| `startUrl` | Where the app opens (route rules still apply). |
| `hosts` | The site's own hosts. Filters apply here. |
| `allowedHosts` | Other hosts that may load in the app. Anything else opens in the browser. |
| `linkShims` | Outbound-link redirectors: `host`, the query `param` holding the real URL, and optionally a `path`, for sites that redirect from their own host (`www.youtube.com`, `/redirect`, `q`). |
| `appLinks` | Optional. Links into the site's own app that open a page of the site instead: `{ "match", "to" }`, where `match` is tested against the whole link and `to` is a path that can use `$1` to `$9` for its groups. The app drops every other app link. TikTok's search box hands the search to the TikTok app as `snssdk1233://search?keyword=...`, inside a redirector that `linkShims` unwraps; an app link sends it to `/search/user?q=$1`. |
| `userAgent` | `"browser"` (the default) or `"system"`. |
| `searchBoxes` | Optional. Search boxes that only search in the site's own app: `{ "input", "to", "paths"? }`. Pressing Enter in an element matching the CSS selector `input` goes to the page `to`, where `$1` is what was typed (trimmed and encoded for a URL); `to` can't use other groups. With `paths` (a regular expression like a route's `match`), only on those pages. Route rules apply to `to` as to any other page. Not a filter: it applies whatever features are on. TikTok's search box does nothing when you press Enter, so Enter goes to its account search, `/search/user?q=$1`. Apps before v0.4 ignore it. |
| `popstateNavigation` | `true` if the site's router renders the URL it finds on a popstate event (Instagram's and YouTube's do). The engine then navigates inside the page when it has no link to click, instead of loading the page in full. |
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

**`prune`**: `{ "path", "global"?, "paths"? }`

- Deletes data from the site's JSON (`JSON.parse` and `fetch` responses)
  before the page renders it, such as story ads injected into API
  responses.
- `path` is property names joined by dots. `[]` means every element of an
  array, and `[-]` removes the array elements in which the rest of the path
  leads to a value other than `null` or `false`:
  - `data.xdt_injected_story_units.ad_media_items` deletes that property.
  - `data.feed.edges.[-].node.ad` removes every edge whose node has an `ad`.
    Instagram's feed items have every slot (`media`, `ad`,
    `suggested_users`, ...) and set the unused ones to `null`, so a `null`
    doesn't count.
  - `itemList.[-].isAd` removes every item flagged as an ad. TikTok sends
    `isAd` with every video, `false` on all but the ads, so a `false`
    doesn't count either. Apps before v0.3 count `false`, so only use a
    `false` flag in a site that those apps don't have.
- With `"global": "name"`, the rule applies to the value a page script
  assigns to that global variable, instead of to JSON. YouTube embeds its
  player data on a full page load as `var ytInitialPlayerResponse = {...}`,
  which never goes through `JSON.parse`, so its ad rules come in both
  forms: `{ "path": "adPlacements" }` for data fetched while you browse,
  and `{ "path": "adPlacements", "global": "ytInitialPlayerResponse" }`
  for the first page.
- With `paths` (a regular expression like a route's `match`), the rule only
  applies while the page's path and query match it. A TikTok video's own
  page fills the rest of its feed with For You videos, so `itemList.[-].id`
  with `"paths": "^/@[^/?]*/(?:video|photo)/"` empties those lists there
  and nowhere else. Apps before v0.3 ignore `paths` and apply the rule
  everywhere.
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
`tab-title`), over its class names. TikTok marks its elements with
`data-e2e` attributes for its own tests (`[data-e2e="header-foryou"]`,
`[data-e2e="discover-icon"]`); use those. Where an element has none, a
`:has()` around one, or a readable class that isn't generated
(`div.matrix-smart-wrapper`, TikTok's open-the-app component), is next
best. In order of preference:

1. **hrefs**: `a[href^="/reels/"]`. URL structure changes least.
2. **Roles and structure**: `article`, `[role="dialog"]`, `:has()`.
   For example, `div:has(a[href="/reels/"]):not(:has(a:not([href="/reels/"])))`
   matches the wrappers around the Reels link that hold no other link.
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

### Checking rules on a computer

The sites' mobile pages also run in desktop Firefox, signed in, with the
engine injected as the app injects it. Give a Firefox profile a phone's
user agent (`general.useragent.override`) and sign in to the sites in a
normal window: Google refuses to sign in a browser that automation
drives. Then start Firefox with that profile from puppeteer-core, over
WebDriver BiDi, and add the app's document-start script to each page
before it loads (`EngineConfig.build(rules, features, signedIn:
...).userScript(engine)`, from a Dart script). Read the session cookies
from the browser to choose `signedIn`, as the app reads its cookie store.

This checks rules and everything the engine does. The app's own part,
which links load where (`UrlPolicy`), can be checked by running it in
plain Dart over the URLs the browser visited; Firefox's history has every
step of a sign-in. TikTok asks a driven browser to drag a slider to solve
a puzzle now and then, quietly drops follows it makes (the follow
request comes back empty), and after a lot of browsing refuses to list
a profile's videos (HTTP 429).

The Flutter web build can't do this: it shows each site in a frame, which
all four sites refuse (`X-Frame-Options`), and it can't inject the engine
into another site's frame.

### Instagram checklist (revision 6)

Checked on a computer (see above). Signed out, Instagram and a profile
someone links to open on the login page, and Forgot password and Create
new account work. Signed in, Home opens `/?variant=following`, also from
`/?deoia=1` and from other feeds such as `/?variant=home`, and shows only
accounts you follow, with no stories; scrolling far down fast keeps posts
on screen. The Reels tab is gone with no gap in the tab bar, `/reels/`
goes Home with "Reels blocked", and `/reels/<code>/` opens that reel on
its own. Home and Explore change page without reloading; Explore opens
search at `/explore/search/` with no grid, and searching for a person
opens their profile. A hashtag is blocked. The inbox has the tab bar
below its last conversation, its tabs work, and a conversation has none.
Paid partnerships are hidden; ads (labelled "Ad") and suggested posts and
accounts appear in the algorithmic feed only, where the rules' signals
match them. A post from an account you don't follow opens, links in a
bio open in the browser (a YouTube link in the app's YouTube), and no
"Use the app" bar or other app prompt shows. Still to check on a device:

- [ ] Scrolling far down Home, fast, keeps showing posts with no jumping
      back. (Desktop Firefox jumps back now and then with or without the
      filters, so only a device shows this.)
- [ ] A reel someone sends you in messages opens on its own.
- [ ] No ads between stories. When an ad would have appeared, Rule
      diagnostics shows a match for one of the `hideSponsored` rules.
- [ ] Posting works: new post → pick a photo → share. Also with the
      camera: new post → Camera → take a photo, and it opens in
      Instagram's editor (needs a full rebuild).

### YouTube checklist (revision 5)

Checked on a computer. Signed out, YouTube and a video someone links to
open on the You page ("You're not signed in", with a Sign in button).
Signed in, it opens on Subscriptions, and the YouTube logo goes there
without reloading the page; the bottom bar has only Subscriptions and
You, also when YouTube draws its fallback bar. Subscriptions shows no
Shorts, as shelves or single videos, and a Short opens as a normal
video. A video shows its title, description and comments with no
recommendations, and when it ends there's no grid of suggestions or "Up
next" countdown, and nothing else starts. Its ad data is removed (Rule
diagnostics shows the `hideAds` prune rules matching). Search works,
with no Shorts and no ads (YouTube showed this account none), links in a
description open in the browser, and in fullscreen there's no "More
videos" button. In a playlist, Next plays its next video. Still to
check on a device:

- [x] Signing in works: Google accepted the password and 2-Step
  Verification in the app, and YouTube was signed in.
- [ ] The trip back after signing in stays in the app. If any step opens
      the browser instead, find its host (`adb logcat -d | grep
      'act=android.intent.action.VIEW'` shows it) and add it to
      `allowedHosts`.
- [ ] Signing out from YouTube's own menu lands on the You page. If
      signed in still sends you to the You page, the `session` cookies are
      wrong: check which cookies m.youtube.com has in the inspector's
      Application panel.
- [ ] No ads before or during videos.
- [ ] Fullscreen turns the phone to landscape (a portrait video stays
      portrait), and leaving it turns back and puts the video back above
      its title (see "Fullscreen video" in DESIGN.md).
- [ ] Playlists and Watch later play in order, moving on to the next
      video when one ends.
- [ ] Switching to Instagram pauses a playing video.

### Reddit checklist (revision 6)

Checked on a computer. Signed out, Reddit and a subreddit someone links
to open on the login page, and Sign Up and Forgot password open their
forms. Signing in with "Continue with Google" passed only through
allowed hosts, and a signed-in `token_v2` has `sub` set to `user`, so the
session check holds. Home opens on Following (`/?feed=following`) with
posts from your communities and no For You tab; Popular, All, News and
Explore are blocked, and the side menu lists none of them, nor "Games on
Reddit"; a subreddit and a post open. Promoted posts are hidden in feeds
and between comments, and recommended posts in feeds. The "View in
Reddit App" sheet is hidden, and the page still scrolls and takes taps.
Links in posts go to the browser (a YouTube link to the app's YouTube).
Still to check on a device:

- [ ] "Continue with Google" opens Google's sign-in over Reddit. Signing
      in there closes it and signs you in to Reddit. If a step opens the
      browser instead, add its host to `allowedHosts`, as for YouTube.
- [ ] Signed in, Reddit stays signed in after restarting the app. If it
      sends you to the login page while you're signed in, the `session`
      check is wrong: in the inspector's Application panel, decode the
      middle part of the `token_v2` cookie's value (base64) and fix
      `anonymousTokens` to match.
- [ ] A link in a post opens in the browser, with no window left over
      Reddit.
- [x] The top-right `Open App` button is hidden.
- [x] The "Get the best of Reddit in the app" bottom sheet is hidden.

### TikTok checklist (revision 2)

Checked on a computer. Signed out, TikTok and a profile someone links to
open on the login page, and "Use phone / email / username" and Sign up
work. Signing in with "Continue with Google" passed only through allowed
hosts, and `sessionid` and `sid_tt` appear once you sign in. Home opens
Following, with no For You tab at the top or in the side menu and no
Discover tab; a shared video plays on its own and swiping goes nowhere.
Search shows your recent searches and suggestions as you type, and
Enter, a suggestion or the Search button shows matching accounts (the
app's part, closing the window TikTok opens for its app, was checked
against the app's policy in plain Dart). For You, a hashtag, a sound,
LIVE and Discover show "For You blocked", "Hashtag feeds blocked",
"Sound feeds blocked", "LIVE blocked" and "Discover blocked". Comments
open, the inbox shows notifications, and no open-the-app buttons,
pop-ups or the dark backdrop of a hidden one show. Still to check on a
device:

- [ ] "Continue with Google" opens Google's sign-in over TikTok, and
      signing in there closes it and signs you in to TikTok.
- [ ] Following an account sticks, and Following then shows its videos,
      which play. (From the computer, TikTok accepts the follow request
      but drops it: its answer is empty, and the account isn't followed
      after a reload.)
- [ ] A TikTok share link (`vm.tiktok.com/...`) in another site opens in
      the app's TikTok, plays on its own, and swiping up shows nothing
      more.
- [ ] Typing a name in search and pressing Enter, or tapping a
      suggestion or Search, shows matching accounts, and never opens the
      TikTok app, the Play Store or a window over TikTok (needs a full
      rebuild).
- [ ] No ads. When an ad would have appeared, Rule diagnostics shows a
      match for `hideAds/prune0`.
- [ ] If TikTok asks you to drag a slider to fit a puzzle, solving it
      works in the app.

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
