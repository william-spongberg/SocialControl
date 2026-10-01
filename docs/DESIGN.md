# SocialControl design

Status: MVP, Instagram, YouTube, Reddit and TikTok.

## Goal

Calmer social media. Keep what people use on purpose, and remove what is
built to keep them scrolling.

- **Instagram**: keep messages, stories, posts from people they follow,
  profiles they look up, and posting. Remove Reels, Explore, the algorithmic
  feed, suggested posts and ads.
- **YouTube**: keep subscriptions, search, channels, playlists and the
  library. Remove the recommended Home feed, Shorts, suggested videos and
  autoplay, Explore and Trending, and ads.
- **Reddit**: keep subreddits, posts and search. Remove the For You feed,
  Popular, All, News and Explore, promoted and recommended posts, and app
  promotion prompts.
- **TikTok**: keep the Following feed, videos people send you, profiles,
  account search, comments and the inbox. Remove For You, Discover,
  Explore, LIVE, hashtag and sound feeds, ads and app promotion prompts.

You sign in to each site before using it, so the app shows your own
accounts, never a site's public pages for visitors.

The hardest ongoing problem is keeping filters working as the sites change,
so filter rules are loaded from a remote file and fixes ship without an app
release.

## How it works

The app shows each site's mobile website in a WebView and filters it. There
is no backend, no private API and no reverse engineering: the app is a
browser with rules.

```
Flutter app
├── ShellScreen ──────────── site picker at launch, then the picked site
│   ├── SitePicker ───────── pick a site (lib/src/ui/site_picker.dart)
│   ├── slim bar ─────────── site switcher, reload, settings
│   └── SiteView (per site) ─ kept alive once opened (lib/src/ui/site_view.dart)
│       ├── UrlPolicy ─────── decides full page loads (lib/src/webview/url_policy.dart)
│       └── InAppWebView ──── each site's mobile website
│           └── lite_engine.js ─ injected at document start (assets/js/lite_engine.js)
├── SettingsScreen ────────── one site's filters, rule updates, diagnostics; log out
└── Site (per site) ───────── lib/src/site.dart
    ├── RulesRepository ───── bundled or downloaded rules (lib/src/rules/)
    └── SettingsStore ─────── the user's switches for that site
```

### Sites

`siteCatalog` in `lib/src/site.dart` lists the sites: a platform id, a name
and an icon. Everything else about a site is in its rules file,
`assets/rules/<platform>.json`: its hosts, start page and filters. Each site
has its own rules (downloaded and cached separately), its own switches, and
its own WebView. Adding a site means a catalog entry and a rules file; the
engine doesn't change unless the site needs a new kind of rule.

The app opens on the site picker every time it starts, so opening a site is
a choice. A site's WebView is created the first time it is picked and then
kept, hidden, while another site or the picker is on screen, so switching
doesn't reload anything. A site that leaves the screen pauses its videos.
The bar has no back button: the system back gesture goes back through the
site's pages, then to the picker, then out of the app. The title of the
slim bar switches between sites.

### Signing in

Signed out, every page goes to the site's sign-in page: Instagram's,
Reddit's and TikTok's login pages, and YouTube's You page, which says you
aren't signed in and has YouTube's Sign in button. The pages that signing in needs, such
as signing up and resetting a password, stay open. This is `signIn` in the
rules: it is always on and comes before the features' routes, so switching
a filter off can't get round it.

The rules name the cookies that mean you're signed in (`session`). The app
reads them from the WebView's cookie store before the first page load, for
each full page load, and after every page load and in-page navigation, so
signing in or out inside a site is noticed by the next navigation. It
passes the answer to the engine with its config, and the engine applies a
change to the open page straight away. The engine can't tell for itself:
page scripts can't read HttpOnly cookies, and all of Reddit's session
cookies are HttpOnly. Reddit also sets one of them, `token_v2`, for every
visitor. It is a JSON Web Token whose `sub` claim is `loid` until you sign
in, which the rules record (`anonymousTokens`), so a visitor doesn't count
as signed in.

### Rules are data; the engine is code

Each rules file lists **features**, the switches users see in Settings.
Each feature holds rules of these kinds:

- **routes**: URL patterns to block (with a notice) or redirect (silently).
  A target can reuse parts of the URL, so a YouTube Short (`/shorts/ID`)
  can open as a normal video (`/watch?v=ID`)
- **hide**: CSS selectors to hide, optionally only on some pages
- **hideByText**: hide the container around a label, such as "Sponsored",
  for things with no stable selector
- **prune**: delete data from the site's API responses before it renders,
  such as Instagram's injected story ads or YouTube's video ad placements.
  A prune rule can also target a global variable that a page script
  assigns its data to, as YouTube does with `ytInitialPlayerResponse` on a
  full page load
- **keep**: put back a tab bar on pages where the site drops it, as
  Instagram does in messages
- **style**: CSS declarations for layout fixes a hide rule can't make,
  checked so they can only style the page

`assets/js/lite_engine.js` is a generic engine that applies whatever rules it
is given. It ships inside the app and knows nothing about any one site.

The split exists because selectors break every few weeks. A fix is a new
rules file, published the same day. Apple's App Review Guideline 2.5.2 bars
apps from downloading code that changes their behaviour, but data such as
ad-blocker filter lists is fine. **Rules must never contain JavaScript.** A
fix that needs new behaviour means an engine change and an app release. See
[RULES.md](RULES.md).

### Enforcement layers

The sites are single-page apps: the page loads once, and navigation
happens through `history.pushState`. No single hook sees
everything, so filtering is layered:

| Layer | Where | Catches |
|---|---|---|
| CSS injected at document start | engine | tabs and links, before first paint (no flash) |
| Capture-phase click listener | engine | links to blocked pages, before the site's router sees the click |
| `pushState`/`replaceState` hooks, `popstate` listener | engine | navigation not started by a link, back/forward |
| MutationObserver | engine | text-labelled content as the feed streams in |
| `JSON.parse`/`Response.json` wrappers | engine | data injected into API responses (story ads, video ads, TikTok's For You videos after a shared one), before it renders |
| Setters on named globals | engine | data a page embeds as a script literal (`ytInitialPlayerResponse`) |
| `shouldOverrideUrlLoading` | app | full page loads, deep links, other sites, app links |

Route rules run in both Dart (`RouteResolver`) and JavaScript (`resolve` in
the engine). `test/fixtures/route_cases.json` runs against both, so they
can't drift apart.

On Instagram, hidden posts are collapsed, not removed. Instagram's feed is a
virtual list: it renders only the posts near the screen, stands in for the
rest with padding, and sizes each post by measuring from its top to the next
post's top. An element with `display: none` has no position (its top reads
as 0), so removing a post corrupts those sizes: the list stops rendering
posts where you are, which leaves a blank screen, and it jumps while
scrolling. Rules that hide whole posts set `collapse`, which leaves the post
as an empty box of zero height, and the list handles those. The engine hides
text-matched posts as soon as they are added, before the list measures them
in its next animation frame. It then fires a scroll event: the feed only
loads more posts when it sees one, and if a whole page of new posts is
hidden, the page may not grow enough to scroll, so the feed would stall.
YouTube's lists aren't virtual, so its rules hide items outright: with
Shorts hidden, search results still load more as you scroll.

Path-scoped hide rules are switched by a token list on `<html>`
(`data-lite-active`), so the stylesheet isn't rebuilt on every navigation.
The engine hides the page while a redirect is under way so blocked content
doesn't flash, and it stops redirecting if it detects a loop (more than 3
redirects in a row with no tap or key press in between).

### Rule updates

- Each site's rules update on their own. The bundled rules are always
  there. A download replaces them only if it validates, is for the same
  site, and has a higher `revision`.
- The last good download is cached. At launch the app checks for updates at
  most every 6 hours; Settings has a manual check and a "Use built-in rules"
  reset.
- The rules folder is set at build time:
  `--dart-define=RULES_BASE_URL=...`. The app downloads
  `<folder>/<platform>.json` for each site.
- Settings is generated from the rules, so a rules update can add or reword
  a filter.
- `schemaVersion` guards the format: an app ignores a file in a format it
  doesn't know and keeps its current rules.

### Navigation and links

- A site's own hosts load in its WebView, along with the hosts its rules
  allow, such as Accounts Center and Facebook's login for Instagram,
  Google's sign-in pages for YouTube and Reddit, and Google's, Facebook's
  and Apple's for TikTok. A sign-in provider is only allowed for a site
  that uses it, so a link to Facebook in a Reddit post opens in the
  browser. Google's sign-in passes through the user's country
  domain; the app assumes Australia for now, so only
  `accounts.google.com.au` is listed.
- A link that asks for a new window (`target="_blank"`, as every outbound
  link on Reddit does) opens like any other link. A window that a page's
  script opens is a sign-in popup, such as Reddit's "Continue with
  Google". It opens over the site in a dialog and keeps its connection to
  the page that opened it, which signing in needs. It closes when it
  finishes or goes somewhere the app opens elsewhere.
- A link to another site in the app opens there: a YouTube link in an
  Instagram bio switches to the app's YouTube, not the YouTube app.
- Every other site opens in the system browser. Outbound-link redirectors
  (`l.instagram.com`, `youtube.com/redirect`) are unwrapped first, and so
  are TikTok's open-the-app redirectors (`app-va.tiktokv.com/redirect/`,
  `snssdk1233.onelink.me`), which leaves the app link inside.
- The policy sees every step of a redirect chain, not just where it starts:
  on Android, flutter_inappwebview cancels each main-frame navigation, asks
  the app, and restarts it if allowed. So a sign-in flow only completes if
  every host it passes through is allowed. When the app does send a
  redirect elsewhere, it ends the abandoned page load, which the WebView
  would otherwise leave spinning.
- When the engine redirects, it clicks a link to the target if the page has
  one, so the site's router navigates without a reload. Otherwise, for a
  site whose rules set `popstateNavigation` (Instagram), it pushes the URL
  and fires a popstate event, which that router renders just the same for the
  feed, search and the inbox. Other sites (YouTube)
  get a full page load.
- In the inbox, Instagram's mobile site removes its tab bar. A `keep` rule
  has the engine remember the fixed bar from the page before and show a
  copy of it there; the site's styles still apply to the copy, and the
  engine navigates for its links, in-page as above.
- `intent:`, `instagram:`, `vnd.youtube:` and `snssdk1233:` links are never
  followed: the app never sends you into an official app. Where the rules
  map an app link to a page of the site (`appLinks`), it opens that page
  instead. TikTok's mobile site can't search videos, and its search box
  hands every search to the TikTok app (`snssdk1233://search?keyword=...`),
  so the app shows the matching accounts (`/search/user?q=...`), the one
  search the mobile site has.

### Fullscreen video

Fullscreen uses the WebView's own fullscreen view, which flutter_inappwebview
lays over the whole app; back leaves it. The app turns the phone to
landscape for it, as the phone's own video apps do, unless the video is
taller than it is wide, and lets it turn back on the way out.

YouTube slides a video's details up into the header's space while
fullscreen (`slot-open`) and only slides them back as you scroll. With
suggestions hidden, the watch page is too short to scroll, so the title
stayed under the video afterwards; a `style` rule cancels the slide.

Android's WebView sometimes leaves
fullscreen without telling the page: the page keeps its fullscreen element
(YouTube's player) pinned over everything, `document.exitFullscreen()` never
answers, and a resize doesn't help. So half a second
after the WebView reports leaving fullscreen, the app asks the engine to
check. If the page is still fullscreen, the engine takes the fullscreen
element out of the document and puts it straight back, which the spec
treats as an exit, and fires a resize so the page lays itself out again.
YouTube is back to normal within a moment, with the video still at the
same point, though it may pause. An iframe inside such an element would
reload, which no current site needs.

### Security

- The JavaScript bridge only accepts messages from the site's main frame
  (the origin is checked in Dart).
- The engine runs only on hosts listed in the rules, and only in the main
  frame.
- Rules are validated before use: patterns must compile, targets must be
  paths, and actions must be known. An invalid download is rejected.
- Not yet done: signed rules, so a compromised rules host couldn't push bad
  rules. Today it could hide page elements, change redirects or delete JSON
  data, but not run code.
- Logging out clears cookies, storage and the cache for every site. The
  WebViews share one cookie store, and a YouTube login also lives on
  google.com, so clearing one site alone is not reliable.

## Decisions

**flutter_inappwebview, not webview_flutter.** It provides document-start
user scripts (Android `addDocumentStartJavaScript`, iOS `WKUserScript`),
native file upload for posting, history-change callbacks and renderer-crash
recovery. We use the 6.2.0 beta: 6.1.5, the last stable release,
references `proguard-android.txt`, which AGP 9 rejects, and Flutter 3.47
refuses AGP below 8.11.1. If the beta causes trouble, the fallback is 6.1.5
with AGP pinned to 8.11.x, which Flutter builds with a deprecation warning.
The beta no longer declares the FileProvider it hands the camera when a
file input (Instagram's new post) takes a photo, so the app's manifest
declares it; without it, the photo never reaches the page.

**Keep each site's own navigation.** The app removes tabs (Reels; Home and
Shorts on YouTube) and redirects pages, then adds a slim bar with a site
switcher, reload and settings. A fully custom navigation bar would lose
posting: Instagram's "new post" button opens a file picker, and browsers
only allow that from a real tap inside the page.

**A picker at launch, sites kept alive.** The picker makes opening a site a
decision rather than a reflex. Keeping each opened WebView (in an
`IndexedStack`) costs memory, but switching back to a site keeps your place.
The site switcher lives in the bar's title because the sites already have
their own tab bar at the bottom, and a second one would take space from the
page.

**The Following feed as Home; Subscriptions as Home.** `/?variant=following`
is Instagram's own chronological feed of accounts you follow,
`/feed/subscriptions` is YouTube's, `/?feed=following` opens Reddit's
Home on its Following tab, and `/following` is TikTok's. Redirecting to
them is a stable URL hook, which is more robust than hiding suggestions
item by item. Hiding Reddit's recommended posts inside its For You feed
was tried first: with most posts hidden, the page stays short, Reddit's
load-more trigger stays in view and never fires again, and the feed stops
after two pages.

**TikTok's mobile site.** TikTok marks its elements with `data-e2e`
attributes for its own tests, which outlast its generated class names, so
rules target those. A video's own page plays the video first in a
swipeable feed and fills the rest from For You, so on video pages a prune
rule limited to those pages (`paths`) empties the item lists the page
gets; the video itself comes from a different request and plays on its
own.

**YouTube's mobile site.** `m.youtube.com` is built from custom elements
(`ytm-video-with-context-renderer`, `ytm-shorts-lockup-view-model`) whose
names stay stable across releases, unlike its class names, so rules target
those. Video ads are removed from the player data (the same approach as
uBlock Origin), since hiding elements can't stop an ad from playing.

**Browser-like user agent.** The WebView markers (`; wv`, `Version/4.0` on
Android; missing `Safari/` on iOS) are removed, so sites serve their normal
mobile site instead of in-app-browser behaviour, and Google's sign-in page
is less likely to refuse the app. Rules can switch this off remotely
(`"userAgent": "system"`).

**No pull-to-refresh.** It fights with scrollable areas such as message
threads. The bar has a reload button instead.

## Known limitations

- **Google could start refusing YouTube sign-in.** It blocks sign-in from
  some embedded browsers ("This browser or app may not be secure"), but it
  accepted a password and a 2-Step Verification prompt in the
  app (Android WebView 154), and YouTube was signed in afterwards, even
  though the WebView names itself "Android WebView" in its client hints.
  That first sign-in's trip back hopped through Google's country domain
  (`accounts.google.com.au`), which the rules didn't list yet, so that one
  step went to the browser; the rules now list it. The WebView presents
  itself as Chrome (no `; wv` marker), doesn't
  send the `X-Requested-With` header that names the app, and keeps every
  sign-in step inside the app, since the system browser's cookies never
  reach the WebView.
- **Australia only, for now.** Google's sign-in hops through the user's
  country domain, and the rules only list Australia's. Signing in from
  another country sends that step to the browser, and the sign-in can't
  finish in the app.
- **TikTok's mobile site is a cut-down TikTok.** It has no messages (the
  Inbox shows notifications), no posting (its middle button only opens
  the app, so the app hides it) and no video search: search finds
  accounts. TikTok sometimes asks you to drag a slider to fit a puzzle
  before it shows videos.
- **Single sign-on leaves the app.** A work account that signs in through
  another company's login page (Google Workspace with Okta or Microsoft,
  say) redirects to a host the rules don't list, which opens in the
  browser, so that sign-in can't finish in the app.
- **YouTube ads are best effort.** The ad data is removed from the player
  and videos still play (checked on logged-out mobile web in headless
  Firefox), but YouTube changes its ad delivery often, and ads
  stitched into the video stream itself can't be removed this way.
- **YouTube Home reloads the page.** YouTube's logo and Home tab aren't
  links, so going Home is a full page load of Subscriptions.
- **Unverified rules.** Every site's rules have been checked signed in on a
  computer (see "Checking rules on a computer" in RULES.md), but not all
  of them on a phone, and rules marked `unverified` haven't been seen
  working anywhere yet (see the checklists in RULES.md). TikTok's
  Following feed hasn't been seen with videos: TikTok dropped the follows
  made from the test browser.
- **The inbox's tab bar is a copy.** It is taken from the page before, so
  it shows what that page showed (such as the profile picture), and it may
  cover the bottom of the inbox list. Checked on a device only in parts:
  that Instagram drops the bar and that in-page navigation works.
- **No push notifications.** Web push doesn't work in WebViews.
- **Background audio.** A site pauses its videos when you switch away in the
  app, but not when you leave the app.
- **Facebook login.** "Continue with Facebook" is likely to fail because
  Facebook blocks logins from embedded browsers. Log in with a username and
  password.
- **Mobile web gaps.** Some features exist only in the native app.
- **Stories row.** The Following feed has no row of story circles. With
  the Following feed off, the main feed shows one, even with "Block
  stories" on, though stories don't open.
- **Some hidden posts still load.** Ads and suggestions in Instagram's feed
  are removed from its data before they render (`prune`), but posts hidden
  by their label or a Follow button are hidden after Instagram sends them.
  A feed where most posts are hidden that way (such as the algorithmic one)
  runs out of loaded posts sooner, and at the end of what has loaded, the
  page can jump back by about the height of a post.
- **Localised labels.** Text rules match exact labels ("Sponsored"). The
  rules list a few languages.

## Testing

- `flutter test`: rules parsing and validation (including every bundled
  file), the shared route fixture, URL policy, engine config, rule updates
  (download, rejection, throttling, per-site cache), the settings screen and
  the site picker.
- `cd test/js && npm install && npm test`: the engine in jsdom. Covers the
  shared route fixture (including capture groups), hide and text rules,
  click, history and back/forward interception, the loop guard, pruning
  JSON and page globals, live config updates and the bridge queue.
- Not automated: the real sites. Use the device checklists in RULES.md. The
  YouTube rules were also checked on logged-out `m.youtube.com` in headless
  Firefox with a mobile user agent: the engine and rules
  together redirected Home, Shorts and Trending, hid the Home and Shorts
  tabs, Shorts in search and on channels, related videos and comments,
  removed autoplay, end-screen and ad data, and kept videos playing and
  search results loading as you scroll.
- All four sites were checked signed in, in Firefox on a computer with the
  engine injected (see "Checking rules on a computer" in RULES.md); the
  checklists there say what that covered.

## Roadmap

