# Glassine — Handoff

_Last updated 2026-09-05. Repo: https://github.com/danepps/glassine (public
since v1.0.0, MIT; see "Signing,
notarization, updates")._

## What this is

Glassine is Dan Epps's from-scratch native macOS PDF reader, built because PDF
Expert got slow. Swift + AppKit + PDFKit. No Electron, no storyboards, no
Xcode project: a Swift Package plus `build.sh`, which assembles
`build/Glassine.app`. Deployment target macOS 14; developed and tested on
macOS 26 (Tahoe) with Swift 6.3 / Xcode 26.

**The app was called Folio through 1.1.0** and was renamed to Glassine on
2026-09-05, bundle id `com.epps.Folio` → `com.epps.Glassine`, GitHub repo
`danepps/pdfreader` → `danepps/glassine` (GitHub redirects the old name). Notes
below that describe past work say "Folio" where that is what happened; anything
naming a file, symbol, identifier or URL is current and says Glassine. The two
local checkouts keep their old directory names: `~/ClaudeCode/pdf` on the
MacBook and `~/ClaudeCode/pdfreader` on the Studio.

Dan's stated requirements, all met as of this handoff:

- Simple, really clean Mac interface, zippy.
- One window, tabs.
- Dark mode tied to system settings, and the **PDF content itself**
  white-on-black in dark mode (not just the chrome). Chrome should be pure
  black, not gray.
- Arrow keys always move by page (↑/← prev, ↓/→ next; ⌘↑/⌘↓ first/last).
- Search shows a hit count; matches are bright green (#5CF25C-ish), current
  match underlined.
- Dark-mode variant of the app icon.

## State

- `main` has the scaffold, the full UI, and (2026-09-04) window sizing,
  Developer ID signing/notarization, and Sparkle. Clean release build, zero
  warnings. Runtime-tested: open/tabs, dark inversion, black chrome, green
  highlights, hit counter, arrow paging, position memory, no crashes.
- Window sizing (2026-09-04): installing the split view controller as
  `contentViewController` shrinks the window to its fitting size (320×0), so
  the frame is set *after* that in `sizeWindowInitially`. A saved frame is
  vetted before restore (an early build autosaved the collapsed one) and
  `setFrameAutosaveName` is called last because it restores too. First launch
  centres on the widest landscape display. No `preferredContentSize`: the
  window snaps back to it and that broke macOS window tiling.
- Markdown viewing landed 2026-09-04 (see "How Markdown viewing works" in
  README.md and the design decisions below): `.md` files are typeset offscreen
  by WebKit into a real `PDFDocument`, auto-refresh on disk changes, Export as
  PDF (⇧⌘E), a default-app menu item, and View ▸ Markdown typeface/size.
  Runtime-verified: render fidelity (headings, nested and task lists, tables,
  code blocks, blockquote, inlined local image, blocked remote image, link
  annotations, New York body + SF Mono code, 1 in margins), auto-refresh across
  append / atomic rename / truncate-rewrite / delete-and-recreate with the page
  kept, refresh while a find is active, the typeface and size menu, export of
  both a Markdown and a PDF document, tabs, and the default-app checkmark.
  Not verified by machine: the dark-mode *look* of a rendered memo (the pipeline
  is unaffected, but the colours want a human eye).
- Outline sidebar landed 2026-09-04: a second sidebar pane listing the
  document's chapters, from `PDFDocument.outlineRoot` for a real PDF and
  synthesised from the headings for Markdown. View ▸ Thumbnails (⌥⌘2) /
  Table of Contents (⌥⌘3), remembered in `Prefs.sidebarMode`. Runtime-verified:
  the tree and its nesting for both kinds, an h1→h3 jump, a heading that wraps
  onto two lines yielding one entry, clicking a row navigating, the selection
  following the reading position, the outline refreshing on a file change, and
  an exported Markdown PDF carrying the bookmarks with no `glassine-outline` links
  left. Dark mode checked by screenshot.
- Window opacity landed 2026-09-04, and blur behind it the same day:
  `Prefs.windowOpacity` (0.3–1.0, default 1) below 1 makes the window
  non-opaque with a clear background, fades the *content* view instead of the
  window, and blurs the desktop showing through
  (`CGSSetWindowBackgroundBlurRadius`, radius 24); `Prefs.windowBlur` (default
  true) turns just the blur off, as View ▸ Blur Behind Window, which is checked
  and disabled at 100%. At exactly 1 the window goes back to opaque with the
  chrome's own background and content alpha 1. All of it is one
  `applyWindowAppearance` — chrome and translucency share the window background
  colour — applied at init, from `showWindow`, and on `.glassinePrefsChanged` so
  tabs (separate windows) follow. View ▸ Window Opacity
  is a menu item with a custom view (`OpacityMenuItemView` in `MainMenu.swift`:
  caption, 150 pt continuous slider, live monospaced-digit percentage), plus
  Increase/Decrease Opacity at ⌥⌘↑ / ⌥⌘↓, which step by 0.1 and disable at the
  ends. The row re-reads the pref in `viewDidMoveToWindow`, because a menu
  builds a fresh window each time it opens and the shortcuts can have moved the
  value behind its back. The stored value is rounded to two decimals, or
  repeated ⌥⌘↑ lands on 0.9999… and Increase Opacity never greys out.
  Runtime-verified: dragging the slider to 30% and back, the live percentage,
  the ⌥⌘↑/⌥⌘↓ steps, and both tabs of a two-tab window going translucent
  together. The menu bar follows the *system* appearance, not the app's, so the
  dark-menu look could not be forced from `Prefs.appearance`; the row uses
  `.labelColor` throughout and was checked in a light menu. Blur runtime-verified
  against a Finder window in icon view behind the reader: blurred at 60% in
  forced dark and forced light, sharp with the item unchecked, blurred again on
  re-check, a second tab translucent and blurred too, find highlights and the hit
  count readable through it, and no residual blur or visible difference from the
  old build back at 100%.
- Page-field editing feedback landed 2026-09-04: `PageIndicatorContainer` gets a
  1.5 pt `controlAccentColor` ring (cornerRadius 6) while the field is being
  edited, the field's accent wash went 0.12 → 0.18, and the placeholder reads
  "1–N" so an emptied field still states the range. The ring's `CGColor` is
  pinned to the container's appearance and re-applied from
  `viewDidChangeEffectiveAppearance`. Runtime-verified in light and dark: the
  ring on click, the placeholder on an emptied field, Escape returning to
  "N of M" without navigating, a typed number + Return navigating, and clicking
  elsewhere ending the edit.
- The reported "page field is in edit mode after a Markdown reload" **did not
  reproduce** (2026-09-04), on either the current build or one with the guards
  stripped out: append to an open `.md` from another app, switch back, and the
  capsule is still the plain label. Two guards went in anyway and are cheap:
  `pageField.refusesFirstResponder` is true except between `beginPageEdit` and
  `endPageEdit`, so the key-view loop can never land in it; and `finishInstall`
  re-asserts `makeFirstResponder(pdfView)` when a document swap has left the
  window itself as first responder. If it ever comes back, that is where to look.
- Markdown styles, continuous layout and word count landed 2026-09-04.
  View ▸ Markdown is now Pages/Continuous, a Style submenu (six built-ins, the
  `.css` files in `~/Library/Application Support/Glassine/Styles`, and "Open
  Styles Folder…"), and the size list; `MarkdownTypeface` is gone, replaced by
  `Prefs.markdownStyle` (a string id). The window subtitle reads
  "6,433 words". Runtime-verified in the built app: every preset
  applied from the menu and checkmarked; a `.css` file appearing in the Style
  menu while the app ran, applying when picked, and disappearing again when
  deleted; Continuous rendering a 22-page memo as one 612 × 13,757 pt page with
  the page indicator showing reading progress as a percentage and going back to
  "N of M" (correctly sized) on the way back to Pages; the outline sidebar listing and
  navigating that single page, with the selection following the reading
  position; ⇧⌘E from a continuous document exporting 22 Letter pages with the
  bookmarks and no `glassine-outline` links; the subtitle updating on a save. The
  presets were also judged from the PDFs themselves, light and with the
  inversion filter applied — see the pitfalls below for what that changed.
  Not verified: nothing known.
- v1.0.0 and v1.0.1 released 2026-09-04 (public repo, MIT). The Sparkle
  path is proven: the installed 1.0.0 in /Applications picked up 1.0.1 and
  installed it on quit (automatic updates were on, so the download was
  silent; a manual "Check for Updates…" shows the standard Sparkle panel).
- Codex (GPT-5) reviewed the code 2026-09-04: `AI Memos/folio-code-review-2026-09-04-Codex-GPT-5.md`
  (`AI Memos/` is gitignored since 2026-09-06 — local notes, not synced).
  Acted on the same day: find-replacement race (state machine, below),
  release.sh preflights, full Edit menu, per-view CIFilter instances, LRU
  eviction of saved positions, build.sh rejects unknown flags, match
  buttons enable on the first hit. Deferred, in rough priority: a test
  target + CI, Swift 6 strict-concurrency cleanup (`@MainActor` on UI
  owners, the PDFKit delegate boundary), incremental highlight geometry
  during a search (each batch currently rebuilds all line rects), keying
  saved positions by file identity rather than path, App Sandbox.
- Not runtime-verified: dark mode at the very last page of a document (the
  bottom-band fix was checked mid-document); the light-mode icon variant
  (would have required toggling Dan's system appearance); Page Up/Down and
  Space paging (left to PDFView's defaults, code-checked only).
- Reading-progress indicator landed 2026-09-05 (branch `progress`): the
  subtitle dropped the reading-time estimate and is now just "24,341 words"
  (`MarkdownStats.minutes` is gone), and a continuous Markdown document keeps
  its page-indicator capsule, which reads "53%" instead of "1 of 1".
  `setPageIndicatorVisible` and the `pageIndicatorSlot` machinery are gone with
  it — nothing removes a toolbar item any more — and Go ▸ Go to Page… is
  enabled in this mode, where it takes 0–100 and scrolls to that fraction.
  Runtime-verified in the built app on a 65-page memo: 0% at the top, 13% after
  eight page-downs, 100% at the foot, ⌥⌘G to 50 landing mid-document and
  reading "50%", Escape cancelling without moving, View ▸ Markdown ▸ Pages
  swapping the capsule to "1 of 65" and Continuous swapping it back with no
  relaunch, a PDF opened in a second tab still reading "1 of 224" with ⌥⌘G
  going to page 42, find jumping to a match and the percentage following it,
  the TOC sidebar listing and tracking, and the subtitle re-counting on a save.
- **Renamed Folio → Glassine 2026-09-05** on branch `glassine`, uncommitted:
  bundle id, product, `Sources/Glassine`, `GlassineDocument`, the
  `glassine-outline://` anchor scheme, the notification names, the toolbar and
  tab identifiers, `~/Library/Application Support/Glassine/Styles`, the icon
  package and its compiled `Assets.car`, and the feed (below). Version stays
  1.1.0 / build 4; the first Glassine release is 1.2.0 and Dan cuts it.
  Runtime-verified on the ad-hoc build: menu bar and About panel, the Folio
  preference migration, find, the TOC sidebar, the Markdown style menu, the
  synthesised outline through the renamed scheme, and Export as PDF.
- **Dark Paper landed 2026-09-05**: `Prefs.darkPaper` (`DarkPaper` — `black` 0
  default, `charcoal` 1, `gray` 2) picks how dark the inverted page reads, as
  three radio items after a separator in View ▸ Appearance. Above Black the
  filter chain gains a `CIColorMatrix` stage and the window chrome takes the
  same grey (design bullet below). Runtime-verified on the ad-hoc build in
  forced dark, PDF and Markdown in two tabs, sidebar thumbnails and a live find
  in frame at every level: paper and chrome measure identically (Charcoal
  28/255, Gray 43/255, Black 0), thumbnails follow, find highlights stay green
  (mean of the green-dominant pixels rgb(40,165,25) at Black →
  rgb(59,151,40) at Gray), the page-break gutter stays visible (paper→gutter
  0→24, 28→38, 43→50) and the three items grey out when Invert Page Colors is
  off. Black is unchanged: a same-state screenshot diff against the pre-change
  build differs only in the toolbar's glass tint, by at most 3/255.
- **New icon family landed 2026-09-05** on branch `icon-production`: Palette
  Rules L4/D5 for the app, a matching single-sheet Markdown document icon, and
  an `.icns` whose every size is drawn at its own resolution (see "Icon"
  below). Runtime-verified on the ad-hoc build: the light artwork in the Dock
  and the About panel with the system in light, the dark artwork in both with
  the system in dark, and every size 512 → 16 judged off a family board.

- **Recents launch window landed 2026-09-05** on branch `recents`: the app no
  longer opens an Open panel when it has nothing to show. `Prefs.recentDocuments`
  (30 entries of path + bookmark + date + page count, most recent first) is
  written from `GlassineDocument.read`, and `RecentsWindowController` lists it.
  It appears at launch, when the last reader window closes, and at ⇧⌘O (File ▸
  Recents…); it hides whenever a reader window is shown or becomes key. ⌘O and
  Open Recent are unchanged. Runtime-verified on the ad-hoc build: the window at
  launch with the list (tilde-abbreviated folders, "p. 1 of 211", "Today, 14:36",
  the Markdown document icon for `.md`); the filter narrowing seven rows to two
  on "mcken", reached with ⌘F; Tab back to the table and Return opening the
  selected row with the Recents window going away; ⇧⌘O bringing it back over a
  document and Escape dismissing it; ⌘W on the last document bringing it back;
  Escape with no document leaving it up; a deleted file's row dimmed and reading
  "Not found", Return on it opening nothing, Delete removing it from the stored
  list; "Open Other…" raising the standard Open panel; the dark-mode look, which
  needs nothing of its own (`NSApp.appearance` is app-wide); quitting with the
  window up and relaunching showing it again; a Finder open of a PDF with the app
  quit going straight to the reader with no Recents flash (screenshot at 0.9 s);
  the model itself (`defaults read com.epps.Glassine recentDocuments` after four
  opens: right order, dates, page counts for the PDFs and none for the Markdown
  file); and a renamed file's bookmark resolving to its new path, with the entry
  rewritten in defaults on the next launch. **Not verified: a real drag onto the
  window** — a drag cannot be driven from System Events; the code registers the
  content view for `.fileURL` and filters with `GlassineDocument.canOpen`.
  The screen locked for part of the session, which blanks `screencapture` and
  empties the System Events window list; `CGWindowListCopyWindowInfo` keeps
  working through a lock and is how the window-presence checks were made.
- **Start tabs landed 2026-09-05** on branch `start-tab`: ⌘T and the tab bar's
  "+" no longer raise an Open panel. They add a `StartTabWindowController` — a
  reader-group window titled "Recents" whose content is the same picker the
  launch window shows — beside the current tab, and picking a document there
  fills that tab in place (design bullet below). The picker came out of
  `RecentsWindowController` into `RecentsViewController`, which both hosts use;
  the launch window is unchanged to the eye. Runtime-verified on the ad-hoc
  build, two documents open in one group: ⌘T giving a "Recents" tab with the
  same title-bar and tab-bar height as the document tab, the picker on the
  reader's black; a double-clicked row replacing that tab, in place, with the
  first tab untouched; the "+" button doing the same; picking a document that is
  already open selecting its tab and dropping the start tab; ⌘F reaching the
  filter and narrowing the list; "Open Other…" from a start tab opening a
  Markdown file into that tab's place; ⌘W closing a start tab like any tab; a
  start tab as the last window *not* drawing the launch Recents window over
  itself, and ⌘W on it bringing that window back exactly once; the same for
  closing the last document tab; and the light (`appearance -int 1`) and dark
  (`-int 2`) looks. **Not verified: a real drag onto a start tab** — still not
  drivable from System Events; it is the same `RecentsDropView` the launch
  window uses, wired to the same `onOpen`.
- **GlassineCore extracted 2026-09-05** on branch `ios` (Phase 1 of the iOS plan):
  the portable half of the app moved into a second SwiftPM package, `Core/`,
  product `GlassineCore`, platforms macOS 14 and iOS 18, depending only on
  swift-markdown at the same pinned revision. It is a separate package directory
  rather than a second target so Sparkle's macOS-only xcframework can never enter
  an iOS build graph; the root manifest now takes `.package(path: "Core")` and has
  dropped its own swift-markdown dependency, `Package.resolved` is unchanged, and
  `build.sh` needed no edit because a local path dependency is source-only.
  Thirteen files went across — `MarkdownHTML`, `Prefs`, `DarkPaper`, `FileWatcher`,
  `ReaderPage` whole, and `FindController`, `FindHighlighter`, `OutlineSync`,
  `ReadingPosition`, `ReadingProgress`, `MarkdownDocumentModel`, `RenderQueue` and
  `RecentsModel` carved out of the window controller, the sidebar, the renderer,
  the document and the recents picker — and Core builds warning-free under
  `-strict-concurrency=complete`, which the app itself still does not. The Mac
  keeps everything that touches AppKit: `AppearanceMode.nsAppearance` and the
  `Prefs.applyAppearanceOverride` closure the app delegate installs (Core's
  `appearance` setter calls it where the `NSApp.appearance` line used to sit),
  `seedRecentDocumentsIfNeeded` as an extension on Prefs, and the whole
  `NSPrintOperation` half of the renderer as `WebKitHTMLPrinter`, which is now the
  one primitive `RenderQueue` drives. One branch came alive in the move:
  `FindController.reset(for:)` cancels a find still running on the *outgoing*
  document, which the old code's `old !== replacement` check never did because
  `install` sets `pdf` before posting the notification; it only fires when a
  Markdown file is saved mid-search, and that path was not re-exercised. The repo
  also got its first tests: 44 Swift Testing cases in `Core/Tests`, all passing
  under `swift test --package-path Core`. Runtime-verified on the ad-hoc build,
  pid-isolated: opening a 211-page PDF, ⌘T giving a Recents start tab and ⌘W
  closing it, dark inversion, Charcoal Paper from the menu with the chrome
  following the paper, find with "1 of 97" and ⌘G stepping to "3 of 97", Escape
  clearing the counter, the boxes *and* PDFKit's own current selection in light
  mode as well as dark, the TOC sidebar selecting "CPO REPORT…" at page 3 and
  scrolling itself to "X. Conclusion" at page 120, ↓↓ paging 1 → 3, page 40
  surviving a quit and reopen, a Markdown memo rendering with its "2,297 words"
  subtitle, a style change to Ink re-rendering in place, an append refreshing to
  "2,314 words" with the page kept, ⇧⌘E exporting eight pages with twenty correct
  bookmarks and no `glassine-outline` links left, and the Recents window returning
  on ⌘W of the last document. **The proof it looks the same is a screenshot
  diff**: eight same-state captures (PDF at page 3, a live find, the TOC sidebar, a
  Markdown memo — each in forced dark and forced light) from the pre-change build
  and from the new one are **byte-identical, worst channel delta 0**. Not
  verified: continuous Markdown layout, opacity and blur, Sparkle (ad-hoc builds
  only), and a Markdown save landing while a find is running.
- **Seven bugs from the Codex macOS review fixed 2026-09-06** on branch `ios`,
  (`AI Memos/macos-bug-report-2026-09-06-Codex.md`, local only). Core grew two files and the tests went 44
  → 62. `FindController` stopped accepting stale state three ways: an edit made
  while a cancelled search is winding down now *replaces* the queued query
  instead of falling through to `beginFind("")` and leaving the old one to start
  from the end callback (clearing the field used to restart the search the reader
  had just cleared); the 0.5 s fallback timer carries a token, so one armed for
  an earlier cancellation cannot fire into a later wait or past a `reset(for:)`;
  and both callbacks are now checked against `document`, with `FindSink` gaining
  `findDidEnd(in:)` (protocol-extension default forwarding to `findDidEnd()`, so
  the iOS shell needed no change) and `documentDidEndDocumentFind` passing
  `notification.object`. `MarkdownReloader` gives reloads a generation, because
  two saves in quick succession are two conversions racing on a concurrent queue
  and the content hash cannot tell a stale revision from a new one — the loser
  used to win and then start a render with a *newer* generation, defeating the
  render guard too. `startRender` no longer takes `initial:`: it derives it from
  `pdf == nil`, so a save or style change that supersedes the opening render is
  itself the first successful install and restores the saved position (measured:
  a style change pressed 0.245 s into a 60× memo whose render was still running
  at 14.4 s restored page 8 exactly, where it used to land on page 0). Reading
  position now survives a re-render as a `ReadingAnchor` — outline row, its
  label, and the reader's depth below it, resolved in the new outline by row then
  by nearest matching label, aimed through the same `ReadingPosition.aim` path —
  with `OutlineSync.depth(of:in:)`/`ordinal(atDepth:in:)` as the arithmetic that
  makes two paginations comparable. Continuous Markdown prints paginated:
  `pdfDataForExport`'s retypesetting step came out as
  `GlassineDocument.paginatedDocumentForOutput`, which print now shares
  (`printOperation(for:scalingMode:.pageScaleNone,autoRotate:)` as a sheet);
  measured headlessly, the on-screen tall page prints as **one** 612 × 792 sheet
  with no extractable text, the paginated render as **22**. The outline sidebar
  follows scrolling, not just page changes: `scrollGeometryChanged` coalesces
  `syncSelection()` onto the same 50 ms debounce for every document. And the
  arrows scroll a viewport at a time when the document is one page taller than
  the window, by moving the clip view directly — `PDFView` wraps a *private*
  scroll view, so `scrollPageDown(_:)` sent to it walks up the responder chain
  past the window instead of down into the scroller. Runtime-verified
  pid-isolated, with **Dan's screen locked the whole time**, through
  `CGEvent.postToPid` (plain and ⌘ keys still reach the first responder), AX
  presses of explicit-target menu items, and `Prefs.lastPositions` read out of
  `defaults` as the instrument: Pages page 8 → Continuous lands 15.7 % down a
  34,952 pt page (page 8 of ~54) and back to page 8 / y 400.08, a round trip
  lossless to 0.08 pt; an append below a reader keeps page 8 / y 400.05 exactly
  and ~17 pages inserted above move them to page 25 at the same offset into the
  same section; six ↓ in a continuous memo move 369.4 pt each (one screen less
  24 pt of overlap) and ⌘↓/⌘↑ clamp at the ends with no overshoot; a PDF still
  pages ↓/↑/←, ⌘↑ to page 0, ⌘↓ to page 29 of 30. **Not verified: BUG-006 at
  runtime** (View ▸ Table of Contents is a nil-target responder-chain item and
  will not fire with no key window), the print *panel* itself, a first render
  that fails, find + ⌘G + Escape, Export as PDF, and the dark-mode screenshots —
  a locked screen blanks `screencapture` and, newly learned, degrades the whole
  AX window tree to the bare application element. **Re-verified 2026-09-06
  morning, screen unlocked, app deliberately never activated** (Dan was working):
  BUG-006 passes on both kinds of document — eight viewport scrolls through a
  continuous memo walked the sidebar selection through eight headings while the
  capsule rose 4 % → 30 % with no jump back, and on page 28 of a 211-page PDF
  with three outline entries the selection moved `g.` → `i.` → `1.` with the
  readout fixed at "28 of 211"; find "court" → "1 of 97" → ⌘G ⌘G "3 of 97" →
  Escape blanks the counter and the green pixel count goes to **0** in light and
  dark; a save landing while a find is live re-runs it ("1 of 3216", no stale
  count) and the reader holds its 25 % across appends; Export as PDF from a
  continuous memo writes 56 Letter pages, 120 outline entries, 0
  `glassine-outline` annotations; the four dark screenshots are in the scratchpad
  (Gray paper). Still not seen: **the print panel itself** — with the app
  inactive every nil-target menu item (`Print…`, `Export…`, `Find…`, `Table of
  Contents`, `Close`, `New Tab`) reports `AXEnabled = false` because validation
  needs `NSApp.keyWindow`, and invoking `printDocument:` directly makes a panel
  that vanishes; the printed *content* is the same paginated document Export
  produces. And a failing first render is not provokable: the CSP forbids every
  remote sub-resource, so nothing can trip the 10 s watchdog. One observation for
  the quirks list: a find for "the" (4,176 matches) on a 56-page memo held the
  app at 100 % CPU and up to **4.8 GB RSS for ~60 s** and lost the reader's
  place (25 % → 0 %), without crashing and with a correct count.
- **The iOS PDF reader landed 2026-09-06** on branch `ios` (Phase 2 of the iOS
  plan), and Spike A's throwaway went with it. `iOS/Sources/` is eleven files: a
  SwiftUI shell (`GlassineApp`, `RootView`, `ReaderView`, `RecentsList`,
  `ThumbnailsPane`, `ContentsPane`, `SettingsView`, `PrefsModel`, `ReaderTheme`)
  around two UIKit/PDFKit pieces (`ReaderPDFView`, and `DocumentSession`, which
  owns the URL and its security scope, the coordinated read, the `PDFDocument`,
  and Core's `FindController`, `ReadingPosition` and `OutlineSync`) — see
  "Architecture (iOS/Sources)" under "iOS". `iOS/project.yml` now takes `../Core`
  as a local package and carries a `GlassineUITests` XCUITest target;
  `build-ios.sh` gained `--test`; `iOS/Support/Info.plist` declares PDF and the
  imported `net.daringfireball.markdown` type (both `LSHandlerRank` Alternate),
  `LSSupportsOpeningDocumentsInPlace`, `UIFileSharingEnabled` and
  `UISupportsDocumentBrowser` NO — Glassine has its own Recents screen — and
  deliberately has **no** `UISceneConfigurations`, because SwiftUI's `WindowGroup`
  installs its own scene delegate and naming one there displaces it. **Core
  changed in exactly two places**: `SidebarMode` gained `.recents` (the iPad
  sidebar puts the recents picker beside Thumbnails and Contents, where the Mac
  has a start tab; the Mac's control only ever writes 0 or 1, so nothing there
  notices), and `ReaderPage.matchInk` became a `public static var` so the iOS app
  can overwrite the Mac's linear-light-calibrated green with an sRGB one at
  launch. **The dark-mode look is measurably the same product**: against Spike A's
  probe PDF on the iPad Pro 13-inch simulator, paper, ink, the blue link, the
  R/G/B squares, the gradient and the eight-step grey ramp come back **identical
  to Spike A at all three Dark Paper levels** (paper 0/28/43, ink 255/237/230,
  link 107,183,255 → 122,177,255), and the page-break gutter is visible at last —
  a 0.94 pre-filter grey instead of the Mac's 0.997 gives 15/40/54 against paper
  0/28/43, where 0.997 gave 1/29/44. The find ink was re-derived from scratch,
  because the iOS chain is an sRGB complement plus a 180° hue rotation and for a
  pure-green pre-filter `(0, k, 0)` it collapses to
  `(255 − 1.43k, 255 − 0.43k, 255 − 1.43k)`: #5CF25C is **unreachable** (running
  it backwards puts two rows of the matrix at 306 and they clip), and `k = 114`
  is the closest point on the line — measured **92,206,92** for the current-match
  outline (the target's red and blue exactly), 32,72,32 for the 35 %-alpha box
  and 198,238,198 for the glyphs inside it, which is the Mac's dark-box /
  bright-outline / pale-glyph picture. Light mode is untouched: the ramp reads
  back the literal values in the PDF and a match is PDFKit's own
  `highlightedSelections` in systemGreen at 184,235,197. Both simulator builds
  are warning-free under Swift 6 with strict concurrency `complete`, and **eleven
  XCUITests pass on both the iPad Pro 13-inch and the iPhone 17 Pro**: the page
  capsule taking 12 and landing on "12 of 211", find showing "1 of 97" and ›
  stepping to "2 of 97" and Done clearing it, the Contents pane navigating, the
  thumbnail strip drawing eight pages and one of them being tapped, a
  quit-and-relaunch finding the file in Recents and reopening it **at page 12**,
  swipe-to-delete, ↓ on a hardware keyboard turning a page, Settings switching
  to Charcoal Paper without a relaunch, "Open in New Window", and the system
  document picker both appearing and opening the file it lists. Two iOS-only
  behaviours had to be written rather than ported: **`PDFView.currentDestination
  .point.y` comes back near the *bottom* of the visible area on iOS** (macOS puts
  it a gutter above the *top*), so a reader parked at the top of page 12 stored
  y = 4.9 out of 792 and every reopen drifted forward exactly one page —
  `DocumentSession` saves `pdfView.convert(.zero, to: page)` instead, and the
  round trip now closes; and the go-to-page control is an `.alert` with a text
  field, because a SwiftUI popover presented from a toolbar item swallows its own
  buttons (tapping Done dismissed it with the action never running). The rest of
  what bit is in the iOS gotchas below. Not verified: a real drag, a real pinch,
  text selection under the filter, Print and Share sheets, an undownloaded iCloud
  file, a share-sheet hand-off from another app (so `onOpenURL` itself), two
  scenes genuinely side by side, and the app on hardware — it **built, signed and
  installed** on Dan's iPhone 16 Pro with `CODE_SIGN_IDENTITY="Apple Development"
  DEVELOPMENT_TEAM=82H77TF7AH -allowProvisioningUpdates`, but `devicectl …
  process launch` was refused with `FBSOpenApplicationErrorDomain error 7 …
  Locked`.
- **iOS Markdown landed 2026-09-06** on branch `ios` (Phase 3 of the iOS plan).
  A `.md` file now opens on iPad and iPhone and is typeset by WebKit into a real
  `PDFDocument`, so the inversion, find, the outline, position memory and
  printing all work without knowing the difference — the same bargain the Mac
  makes. `iOS/Sources/MarkdownRendererIOS.swift` is the iOS `HTMLPrinter` for
  Core's `RenderQueue`: one hidden `WKWebView` in the key window at alpha 0, with
  every `WKNavigation` identity check, the process-terminate restart and the
  `reprint` retry the Mac's `WebKitHTMLPrinter` has, pressing the loaded page
  three different ways — `UIPrintPageRenderer` + `viewPrintFormatter()` on
  612 × 792 paper (measured at 468 × 1.25 = 585 CSS px, printed at 0.8 pt per px)
  for Pages, `createPDF` at 1:1 on a `612 × ceil(scrollHeight)` view for a
  continuous document, and `UIPrintPageRenderer` again on 612 × 14,400 paper with
  zero margins past CoreGraphics' page ceiling, where `createPDF` silently tiles
  and slices lines in half. Measured: the memo is 8 × 612 × 792 or one
  612 × 8,264 page; the six-part memo is 48 Letter pages or **three** 14,400 pt
  sheets with **zero duplicated characters at either seam** and the last one
  *cropped* to the 1,755 pt it drew, because `UIPrintPageRenderer` has no
  short-last-page option and 12,722 pt of blank reads as a broken document. Only
  the `createPDF` route keeps the `glassine-outline://` link annotations, so the
  other two recover the outline by **measure-then-snap**, which is
  `GlassineCore.HeadingLocator`: `a.fh` rects measured in `.defaultClient` give
  order and a starting page, `PDFDocument.findString` resolves each title
  exactly, hits outside the 72…720 pt printable band are discarded because the
  print path leaves a *clipped ghost* of every carried-over heading in the margin
  below, and a title that cannot be found is **interpolated between its located
  neighbours** rather than left to the raw prediction — which the iPhone 16 Pro
  proved necessary by putting three bookmarks behind the ones before them where
  the simulator had rounded the right way. `beginFindString` reports those
  ghosts too (proved directly against the render), so `DocumentSession` is now
  the find sink and drops any selection lying wholly below the band before the
  counter sees it. `DocumentSession` also grew the whole `.markdown` branch:
  "reload #0" with the reader shown over an empty, already-inverted gutter,
  `initial` derived from `document == nil`, a `MarkdownReloader` behind a
  `FileWatcher` *and* an `NSFilePresenter`, a `ReadingAnchor` captured before
  every re-render, the word-count subtitle, `isContinuousMarkdown` with a "53%"
  capsule that Go to Position sets from 0–100, viewport arrows on a single tall
  page, Export as PDF through a paginated re-render under `<key>.export`, and
  printing that uses the same. **Core changed in five places, four of them
  behind `#if canImport(UIKit)`**: `HeadingLocator` is new; `OutlineSync.
  currentOrdinal` and `ReadingPosition` stopped asking `currentDestination` where
  the reader is on iOS, because there it answers with the *bottom* of the
  visible area (and `currentPage` answers with the wrong page at a break) —
  measured, an append to an open memo used to walk the reader from §7 to §9, and
  now leaves the passage on screen; and `ReadingAnchor`'s clamp gained 24 pt of
  clearance instead of 1, because one point is inside `go(to:)`'s landing error
  (this one touches the Mac too, by 23 pt, only when a section got shorter). The
  tests went 62 → **80**. Runtime-verified: **18 XCUITests pass on both the iPad
  Pro 11-inch and the iPhone 17 Pro** — the word-count subtitle and "1 of 8",
  Continuous reading 0% then 13% after one ↓ then 50% from Go to Position with
  the Contents selection following the scroll on a single tall page, Manuscript
  → Ink re-rendering and landing on the same outline row, Contents navigation,
  find, Export raising the picker, and the Style list carrying the six built-ins
  plus a `Sepia.css` dropped into `Documents/Styles`. Auto-refresh was driven
  from the Mac side of the container: an append took the subtitle 2,297 → 2,439
  words and the document 8 → 9 pages in **81 ms** with the capsule still on page
  5 and the same passage on screen, and ~2,700 words inserted *above* the reader
  moved them 5 → 9 of 13 pages with the same heading still at the top of the
  view. Warm reloads of the six-part memo take **402 ms** paginated and
  **441 ms** continuous. Dark mode was measured rather than admired: paper 0 at
  Black and 43 at Gray as on the Mac, but **the stylesheet's near-white panels do
  not survive the port** — iOS's sRGB complement is exactly `255 − v`, so
  `#FAFAFA` lands 5 levels above a Black page and `#F5F5F5` lands 10, where the
  Mac's linear-light flip makes them plainly dark greys; what carries a code
  block or a table on iOS is its border, 19 levels above paper, which reads as an
  outlined box rather than a filled panel (Phase 4 gives iOS its own panel
  values). **And the app finally ran on Dan's iPhone 16 Pro**: signed with
  `CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=82H77TF7AH
  -allowProvisioningUpdates`, installed and launched with `devicectl` (unlocked
  this time), and the render it produced — pulled back with `devicectl device
  copy from --domain-type appDataContainer` — is 8 × 612 × 792 pages with New
  York and SF Mono embedded, 19 outline entries and 16/16 headings on the page
  `findString` puts them on, structurally identical to the simulator's.
  `devicectl` has no screenshot subcommand, so there is no picture of it. Not
  verified: the Mac app at runtime after the anchor-clearance change, the
  `NSFilePresenter` half of auto-refresh in isolation, `FileWatcher`'s directory
  source against a security-scoped URL, text selection and pinch under the
  filter, the Print sheet, an undownloaded iCloud `.md`, and a first render that
  fails.
- **The View menu was split three ways (2026-09-06)**, on a beta tester's note
  that display, window translucency and a Markdown submenu all shared one menu,
  with page zoom sitting next to Markdown type size. View kept the panes, the
  four zoom items, Appearance ▸ and Invert, and Enter Full Screen; it stayed
  titled "View" because AppKit hangs Show Tab Bar / Show All Tabs off that
  title. The opacity slider row, Blur Behind Window and Increase/Decrease Opacity
  moved to the top of the Window menu, above a separator and the standard items,
  and the Window menu stayed `NSApp.windowsMenu`, so AppKit still appends its
  own window-management items and the open-window list underneath. A new
  top-level **Markdown** menu between View and Go took Pages/Continuous, the
  rebuilt-on-open Style submenu, a new Text Size submenu holding the four sizes,
  new Larger/Smaller Text items (⌥⌘= / ⌥⌘−, stepping `Prefs.markdownFontSizes`
  and disabled at either end), a second copy of Export as PDF… (the same
  nil-target `GlassineDocument.exportAsPDF`, so File's copy validates
  identically), and the default-app item lifted out of the app menu and renamed
  "Open Markdown Files with Glassine by Default". The Markdown preference items
  are still enabled with a PDF in front — a preference set over a PDF applies to
  the next Markdown file, and disabling them would hide the feature. README's
  menu paths were updated to match. Verified pid-isolated through the
  accessibility API without activating the app: the eight menus in order, every
  title, key equivalent and enabled state in View/Markdown/Window against both a
  PDF and a Markdown document, AXPresses of Continuous, 13 pt (page count
  9 → 10, a real re-render), Larger Text refusing to fire at 13 pt, and Decrease
  Opacity taking `windowOpacity` to 0.9; a `.css` dropped into the Styles folder
  mid-run still appeared in Markdown ▸ Style on the next read. Not exercised:
  `OpacityMenuItemView.viewDidMoveToWindow` in its new menu (it only fires when
  the menu opens, which would have activated the app); the slider row was shown
  live through its AX value instead.
- **iOS polish and the TestFlight script landed 2026-09-06** on branch `ios`
  (Phases 4 and 5 of the iOS plan). The visible change is the Markdown
  stylesheet: `MarkdownHTML.page` gained a defaulted-nil **`platformCSS`** third
  layer, emitted after the style layer because the six built-ins and a user's
  own `.css` share one slot and every built-in sets `--code-bg` itself, and the
  iOS renderer passes `ReaderTheme.markdownPlatformCSS` through it. That exists
  because the two platforms invert in different colour spaces and one set of
  values has to serve both appearances: run through `linearLight`, the Mac's
  `#FAFAFA` code panel comes back **59** levels above a Black page and
  `#F5F5F5` **83**, where iOS's `.contrast(-1)` is exactly `255 − v` and lands
  them at 5 and 10. Matching 59 would need a pre-filter `#C4C4C4`, a grey slab
  in light mode, so the values were picked by screenshot at Black, Charcoal and
  Gray and against white: **`--code-bg #E0E0E0`, `--th-bg #DADADA`,
  `--code-border` and `--rule` `#BFBFBF`**, measured on the iPad at **31 / 37
  above a Black page, 53 / 58 at Charcoal, 66 / 70 at Gray**, and 224 / 218
  against white. The export and the print sheet take the same layer, so what is
  on screen is what comes out. The Mac's HTML is byte-for-byte unchanged and a
  Core test pins the SHA-256 of `page()` over all six styles and both layouts to
  prove it. The chrome was then labelled for VoiceOver — the capsule speaks
  "Page / 4 of 30" and "Reading position / 53 percent" with the changing half in
  the **value**, because VoiceOver re-announces a value and not a label; the
  counter says "3 of 12 matches"; a Recents row is one element reading
  "report.pdf, PDF, ~/Documents · p. 12 of 211, Today, 10:18" instead of four
  separate stops — and three new tests run `performAccessibilityAudit()` over
  the reader, Recents and Settings. The audit's nine findings were triaged with
  its own attached screenshots: PDFKit line boxes, the keyboard's QuickType row,
  a UIKit-clamped navigation title, system semantic colours, and the content
  behind an iPad form sheet are all exempt with reasons in the code; **`Text
  clipped` is a false positive for any SwiftUI `Text` sized to its own width,
  but it pointed at two real squeezes** — the Recents filename was getting 77 pt
  so a date could have 70, and the find field 140 pt of a 390 pt row — both
  fixed with `.layoutPriority(1)`. On the **iPhone 17e at Accessibility XL the
  find bar genuinely broke** — the counter cut to "1 of…" and "Done" wrapped
  onto two lines — so it now becomes two rows when
  `dynamicTypeSize.isAccessibilitySize`. Also new: a `UILaunchScreen` that is
  just the reader's paper (a one-colour-set `Assets.xcassets`, white light /
  black dark, which compiles into the same `Assets.car` as the `.icon` package
  without disturbing it), a `PrivacyInfo.xcprivacy` declaring **UserDefaults
  `CA92.1`** and **file timestamps `C617.1` + `3B52.1`** and nothing else —
  grepped, including the swift-markdown checkout — and
  `ITSAppUsesNonExemptEncryption` false so every TestFlight build skips the
  compliance prompt. **`release-ios.sh` is written** — see "Releasing to
  TestFlight (iOS)" below. `--check` was exercised (it correctly refuses the
  `ios` branch and the dirty tree, and reports the other nine as ok);
  `--no-upload` was run and **archived successfully but could not export**:
  Apple returned `403 FORBIDDEN_ERROR … "You haven't been given access to
  cloud-managed distribution certificates"` and `No profiles for
  'com.epps.Glassine' were found`. The archive is otherwise exactly right —
  7.0 MB, team 82H77TF7AH, the `.car` and `PrivacyInfo.xcprivacy` inside, no
  Sparkle and no `Frameworks/` at all, `CFBundleShortVersionString 1.0.0`,
  `CFBundleVersion 2`, `ITSAppUsesNonExemptEncryption false` — but it is signed
  **Apple Development**, because export is where App Store re-signing happens.
  **Nothing was uploaded and no tag was created.** Runtime-verified: **25
  XCUITests pass on the iPad Pro 11-inch, the iPhone 17 Pro and the iPhone
  17e**, zero Swift warnings on all three, **82 Core tests**, and
  `./build.sh --adhoc` clean after a forced recompile. Not verified: the `.ipa`
  and everything downstream of the export, the publish half of the script
  (running it would create a tag), the dark/tinted/clear Home Screen icon
  variants (the simulator's SpringBoard shows light artwork even for Apple's own
  apps under `simctl ui appearance dark`), VoiceOver by ear, and anything on
  hardware.
- **The first hardware session on an iPad ran 2026-09-06** — Dan's iPad Pro
  11-inch (3rd generation, iPad13,4, iPadOS 26.6 build 23G71) — and it got as
  far as proving the app and the Markdown pipeline, but **not the XCUITests**.
  The build is the ordinary Debug one aimed at the device
  (`-destination 'platform=iOS,id=<devicectl identifier>'`) into its own
  `iOS/DerivedData-device` so the simulator's tree is left alone, with
  `-allowProvisioningUpdates -allowProvisioningDeviceRegistration` and the App
  Store Connect key (`-authenticationKeyPath ~/.private_keys/AuthKey_9D6LK6456Y.p8
  -authenticationKeyID 9D6LK6456Y -authenticationKeyIssuerID 69a6de82-…`): it
  succeeded with **zero Swift warnings** (the one `warning:` in the log is
  `appintentsmetadataprocessor` noting no AppIntents dependency), signed **Apple
  Development: Daniel Epps (A5EC7N7296)**, team 82H77TF7AH, into "iOS Team
  Provisioning Profile: com.epps.Glassine" — **the iPad registered without a
  fight**, four devices in the profile with its UDID
  `00008103-000449393EBB001E` among them. `xcrun devicectl device install app`
  worked with the device **locked**; only launching needs it unlocked. Fixtures
  went into the app's container one file at a time with `xcrun devicectl device
  copy to --device <id> --source <abs path> --destination Documents/<name>
  --domain-type appDataContainer --domain-identifier com.epps.Glassine`, and
  **`copy to` creates missing intermediate directories itself** — `Documents/
  Styles/Sepia.css` landed although the app had never launched and `Styles` did
  not exist, so the first-launch dance the simulator needs is unnecessary here;
  `devicectl device info files … --subdirectory Documents` listed all nine
  entries. **The Markdown pipeline is the same product on hardware**: launched
  with `process launch --terminate-existing com.epps.Glassine -- -open memo.md`
  (the `--` still required), the `Documents/last-render.pdf` pulled back with
  `copy from` is **8 pages of exactly 612 × 792 with 19 outline entries** and
  2,202 extractable words — the simulator's and the iPhone 16 Pro's numbers to
  the page. **The XCUITest suite never started.** The runner builds, signs
  ("iOS Team Provisioning Profile: *"), installs and launches, then dies after a
  clean 60.0 s: `Failed to initialize for UI testing: … Code=1000 "Timed out
  while enabling automation mode."`, recorded as a **System Failure with 0 tests
  run**, twice, identically, with `devicectl device info lockState` reporting
  `passcodeRequired: false` and the app in the foreground both times. That is
  not a test failure and not a signing failure — it is the device-side **Settings
  ▸ Developer ▸ Enable UI Automation** toggle, which is off by default on a
  device that has never been driven by XCUITest and cannot be set from the Mac.
  Two lock lessons worth keeping: `FBSOpenApplicationErrorDomain error 7 …
  Locked` is what an auto-locked iPad gives you (it locked during the four
  minutes of build and install), and a 15–20 minute suite wants **Auto-Lock
  ▸ Never** for the duration. Not verified: **all 25 XCUITests on hardware** and
  everything they would have shown — no screenshots, no iPad screen dimensions,
  no landscape or find-bar or Contents or Settings picture, no hardware-vs-
  simulator timings; and still, as before, touch by hand (tap, drag, pinch,
  text selection under the filter), iCloud files, dark mode judged by eye, and
  the Share and Print sheets.
- **A second window became a menu item on 2026-09-06**, because Dan's hand
  testing on the iPad turned up the one thing the port had no answer for:
  "there's no way to open a new doc without closing the existing one". The
  sidebar's Recents pane opens *in place of* what is on screen, and the only
  route to a second scene was "Open in New Window" inside a long-press context
  menu — the Mac's ⌘T with nothing discoverable in front of it. So the reader's
  ellipsis menu now carries **New Window** (`plus.rectangle.on.rectangle`, ⌘N,
  its own group above Print), shown only where
  `UIApplication.supportsMultipleScenes` is true so an iPhone — one scene, one
  window — never sees an item that would do nothing; `ReaderPDFView` carries the
  matching `UIKeyCommand`, routed through `ReaderCommand.newWindow` like ⌘F and
  ⌥⌘G, so ⌘N works with the menu shut; and every Recents row has a **leading
  swipe** to the same action, tinted blue, absent from the dimmed "Not found"
  row (which keeps its trailing Remove, the one thing it is still for). The
  context-menu item stays.
  **`RootView.newWindow()` activates a scene with an *empty* activity of the
  app's own type**, which `DocumentSession.url(from:)` reads as nothing, so the
  new scene's `session` stays nil and it opens on the Recents picker — the iOS
  start tab. The empty activity is not decoration: activating with
  `userActivity: nil`, and with `activateSceneSession(for:)` (the iOS 17
  spelling of the same call), *did* create the scene but left it in the
  **background** — `connectedScenes` went one → two with states foregroundActive
  and background, and that scene's window carried no content at all in the
  accessibility tree — where with the activity it attaches and its `RootView`
  appears with no document. `options` stays nil for the same kind of reason: a
  `requestingScene`, or a `UIWindowSceneProminentPlacement`, moved the whole app
  into iPadOS 26's **windowed** presentation, the reader becoming a floating
  window with a close button and a "21 Hidden Windows" banner, which is not
  something a menu item should do to a reader. Verified: **26 XCUITests pass on
  the iPad Pro 13-inch (M5) simulator** (25 + the new
  `testNewWindowFromMoreMenu`, which skips on iPhone through
  `UIDevice.current.userInterfaceIdiom` and asserts what is observable — the
  item is in the menu, and the document that was open is still open, at the same
  page, afterwards), zero Swift warnings there and on the `iPhone 17 Pro` build,
  `./build.sh --adhoc` still clean, and the open menu photographed on the
  simulator: New Window in its own group over Print/Share, then Settings/Close.
  The 13-inch simulator was **erased and re-seeded** at the end of that work —
  the placement experiment had left it in windowed mode with 21 stray scene
  sessions — so its container is new and the fixtures were copied in again.
  Not verified: **that the new scene comes to the front**. The iPadOS 26
  simulator leaves it behind the reader, so nothing visibly happens there and
  XCUITest can see neither the new window's Recents list nor its "Open Other…"
  button; the existing "Open in New Window" behaves the same way, so this is the
  shell, not the call. Also unverified: ⌘N from a hardware keyboard, the leading
  swipe by finger, and every bit of it on Dan's iPad.

- **The XCUITests ran on the iPad (2026-09-06 evening): 26 of 26 passed in
  381 s**, on Dan's iPad Pro 11-inch (3rd generation, iPadOS 26.6), with the
  New Window test among them — the run compiled whatever was on disk, which by
  then included the menu item. Getting the runner to start took two things, not
  one: **Settings ▸ Developer ▸ UI Automation ▸ Enable UI Automation** on, *and
  a restart of the iPad* — with the toggle on and the device unlocked the
  runner still died after its 60 s "Timed out while enabling automation mode",
  and only after the reboot (which asks for the passcode before the Mac's
  developer services reconnect; `devicectl` shows the device as `connecting`
  until then and `lockState` errors with "capability not supported") did the
  first test start. Auto-Lock at Never for the duration. The recipe is the
  simulator's `xcodebuild test` line with `-destination 'platform=iOS,id=<devicectl
  identifier>'`, `-derivedDataPath iOS/DerivedData-device`, the
  `TEST_RUNNER_GLASSINE_DOC`/`_MD` settings, and `-allowProvisioningUpdates`
  with the API key so the runner app can be signed; the result bundle's
  screenshots (`xcrun xcresulttool export attachments`) are **1668 × 2388**,
  the 11-inch panel at 2×. **The run also produced a crash report that no test
  noticed**: an `.ips` attachment timestamped at the end of
  `testHardwareKeyboard`, `EXC_BAD_ACCESS … stack guard region` on the main
  thread, with the stack a repeating cycle of `-[PDFView goToNextPage:]` →
  `@objc ReaderPDFView.nextPage()` → `goToNextPage:` → … — **on iPadOS 26.6
  PDFKit's `goToNextPage:` sends the view a selector named `nextPage`**, which
  the runtime resolved to our private `@objc nextPage()` handler, which called
  `goToNextPage:` again, forever. The iOS 26.5 simulator's PDFKit does not do
  this, which is why 26 green simulator runs never saw it, and the test passed
  because its assertions had run before the app fell over. Fixed by renaming
  every `@objc` key-command handler in `ReaderPDFView` with a `command…`
  prefix (`commandNextPage` and so on; the comment above them says why a
  private `@objc` name is not private at all). Verified on the iPad: after the
  rename, `testHardwareKeyboard` and `testNewWindowFromMoreMenu` passed there
  and the result bundle carried **no** `.ips` at all, where the full run's had
  one; the simulator build is warning-free. The same hand session found a
  second thing the simulator could not: **New Window opened a second window
  that showed report.pdf again instead of Recents.** That was the DEBUG
  `-open report.pdf` launch argument the app had been started with —
  `openLaunchArgumentIfNeeded()` runs from every scene's `onAppear` with
  `session == nil`, and the argument sits in NSArgumentDomain for the life of
  the process — so it now fires once per process (`launchArgumentConsumed`).
  A TestFlight build has no such hook and was never affected. Not verified:
  whether `previousPage`, `firstPage` or `lastPage` collided too (renamed on
  the same principle without waiting to find out); ⌘N from a hardware
  keyboard; and New Window showing Recents on the iPad after the fix (Dan was
  asked to try it from a clean launch).
- **The title bar carried no colour at reduced opacity, and now it does
  (2026-09-06).** Dan's screenshot of a dark reader at reduced opacity over a
  Terminal showed the toolbar band razor-sharp — the window behind it reading
  straight through while the page below was blurred — and macOS 26's glass
  capsules (sidebar toggle, the page capsule, the search field, the find
  chevrons) drawing notched grey outlines around that sharp edge. Cause:
  `WindowChrome.apply` fades only the *content* view, so the band above it had
  alpha 0; a band with no colour of its own is also nothing for
  `CGSSetWindowBackgroundBlurRadius` — which weights the blur by the window's
  own alpha — to blur behind, so the band never got the blur the page did. The
  fix is `TitlebarBackdrop`: a layer-backed plate painted the page's own colour
  (black, or the Dark Paper lift, in dark mode; in light mode `.white`, the
  paper, not `.windowBackgroundColor`) at the content view's alpha, inserted
  into the window's theme frame *below* the title-bar container so the toolbar,
  the title and the tab bar still draw on top of it, sized from
  `contentView.frame.maxY` to the top of the theme frame and re-laid-out from
  the content view's `frameDidChange` so it grows when the tab bar appears. It
  hangs off the window as an associated object and is removed the moment opacity
  is back to 1. Light mode now also gets `titlebarAppearsTransparent` while
  translucent, or its own opaque material stands as a hard seam over a
  see-through page. Measured pid-isolated over a high-contrast test card ordered
  *below* the reader window, with the app never activated (ScreenCaptureKit
  composites the window over what is behind it with everything in front of it
  excluded, so nothing on Dan's screen had to be raised): dark at 60 %, band vs
  page across the seam **78.4 vs 78.8** of 255, where the old build read 150–240
  vs 78.8; light at 60 %, **231.6 vs 231.8**, where the old build's opaque title
  bar read 253 vs 236.5; dark at 30 %, 146.4 vs 145.7; Gray Paper at 60 %, 113.0
  vs 109.3. In every one of them the card's sharp text is gone from the band and
  the same blur runs through the toolbar as through the page, and the capsules
  read as glass instead of notched outlines. At 100 % the old build and the new
  one are **byte-identical, worst channel delta 0** (window-only captures,
  1264 × 824, dark and light). The faint 1 pt line AppKit draws at the content
  edge is unchanged and pre-existing (value 24 on black at 100 %). Not verified:
  the plate being *removed* on the way back to 100 % (⌥⌘↑ needs a key window and
  the app was deliberately never activated, so only the launch-at-100 % path was
  measured); the start tab's own window (⌘T likewise). And one thing the plate
  cannot reach: the tab bar draws a ~54 % black scrim over whatever is behind it
  inside the window, so with the plate there the tab strip reads about half the
  band's tone (37 vs 78 at 60 %, 60 vs 130 at 30 %) — a flat band in the right
  colour family rather than the sharp desktop it used to be, but not the page's
  tone.
- **Markdown footnotes landed 2026-09-07.** `[^label]` references and
  `[^label]: note` definitions — the Pandoc/GitHub/Obsidian extension — now
  render as superscript markers and a notes section. cmark-gfm has the
  extension but swift-markdown never sets `CMARK_OPT_FOOTNOTES` and has no node
  types for it, so `Core/Sources/GlassineCore/MarkdownFootnotes.swift` does it
  in two passes of Glassine's own. **Definitions come out of the raw text
  before the parse** (`MarkdownFootnotes.extract`, called from
  `MarkdownHTML.body` between `stripFrontMatter` and `Document(parsing:)`):
  they have to, because `[^1]: https://example.com` is a *link reference
  definition* to cmark, which would turn every `[^1]` in the file into a link
  to that URL. The line pass tracks ``` / ~~~ fences, takes four-space and tab
  continuations, lazy continuations and blank-line-then-indented second
  paragraphs, and leaves a blank line where each block was. **References are
  rewritten in the parsed tree** (`MarkdownFootnotes.Referencer`), on `Text`
  nodes only, which is what keeps `[^x]` inside a code span, a fenced block or
  a link destination literal without a single special case; because a
  `MarkupRewriter` maps one node to one node, the splice happens a level up in
  `defaultVisit`, where the parent rebuilds its children. The marker is
  `InlineHTML`, so `HTMLFormatter` passes it through raw and the word count
  does not see it. The notes are appended as
  `<section class="footnotes">` after the body, each note parsed and formatted
  as its own document (so emphasis, links and code work in a note) with the
  back-link tucked inside its last `<p>`. Numbering is by **first reference**,
  not definition order; repeated references share a number and get
  `fnref-<slug>-2`, `-3` ids; **an unreferenced definition is dropped
  silently**, as Pandoc and GitHub drop it; the word count adds the notes'
  words. Five rules went into `baseStyle` (`sup.fnref`, the `section.footnotes`
  block, `a.fnback`), so **the `MarkdownHTMLSnapshotTests` digests were
  re-recorded** — pages `eff7ffeb…`, continuous `4104dabf…`.
- **Same-document heading links landed with them (2026-09-07).** Every heading
  now carries a GitHub-style `id` (lower-cased, punctuation dropped, spaces to
  hyphens, repeats numbered `slug-1`, `slug-2`), computed in `HeadingAnchorer`
  alongside the outline index so the two can never drift. A hand-written table
  of contents — `[Background](#background)` — is therefore live in the rendered
  PDF. Nothing rewrites the links themselves.
- **Both of those ride on plain `#fragment` links, because WebKit's print path
  turns them into real internal `GoTo` destinations.** The old note under
  "Design decisions" said WebKit emits no annotations for same-page fragments;
  that is wrong and was corrected here. Probed 2026-09-07 with an offscreen
  `WKWebView` + `NSPrintOperation` at the app's own print settings: an
  `<a href="#fn-a">` came back as a `Link` annotation whose action is a
  `PDFActionGoTo` with an XYZ destination at the target element, **across pages
  and in the one-tall-page continuous layout too** (a five-page paginated
  render pointed from page 0 to page 4 and back). So there is no private-scheme
  machinery for footnotes or heading links, no new annotation pass beside
  `applyOutline`, and no change to either renderer. End-to-end on the sample:
  13 `GoTo` annotations, 0 private-scheme annotations left after
  `applyOutline`. The one wart is a fragment that matches nothing
  (`[x](#no-such-heading)`): it stays a `file://…#no-such-heading` URL
  annotation, which is exactly what every fragment link did before this change.
- Runtime-verified 2026-09-07 for both: the real `MarkdownHTML` pipeline into
  the Mac's print settings, pages rasterised and read back — superscript
  markers in the prose, a rule and an ordered list of notes at the end, the
  multi-paragraph note's back-link on its last line, code spans and a fenced
  block untouched, note 4 flowing onto page 2 — plus the app itself opening the
  sample in a pid-isolated instance without a crash. **Not verified: the
  on-screen look in the reader window.** The screen was locked
  (`CGSSessionScreenIsLocked=Yes`), which blanks `screencapture`; the PDF the
  reader displays was inspected directly instead.
- **iOS follow-up:** footnote and heading links work on iOS only in the
  `createPDF` (continuous, under 14,400 pt) path, which keeps annotations.
  Every `UIPrintPageRenderer` output has no link annotations at all — the same
  reason headings there are located by measure-then-snap — so in the paginated
  path the markers render but do not jump. Nothing is left dirty; there is just
  nothing to click. Fixing it means synthesising the link annotations from a
  JavaScript measurement the way `HeadingLocator` does.

- **1.5.1 release changes (Codex, 2026-09-09).** Includes the existing
  PDF copy cleanup / Copy Without Cleanup, conditional search controls and
  match-count priority, and Recents page-coloured backing described below.
  The final chrome implementation supersedes the earlier private-titlebar
  plate attempts: `WindowChromeContentController` owns a full-size content
  host with a public `.behindWindow` `NSVisualEffectView` and a separate
  title-band backing. The document stays below `contentLayoutGuide`, keeping
  uninverted PDF pixels out of the toolbar's sampling region. Removed CGS
  background blur, associated-object plates, and private titlebar traversal.
  Opacity still fades the document; blur uses the system material, so the
  tint can differ from 1.5.0. No iOS release is included.
  Validation: root `swift test` passes the new native AppKit regression test
  across three tabs, both appearances, four opacities, blur on/off, resizing,
  and tab detachment; Core passes all 133 tests in 14 suites. Release build
  and ad-hoc signature verification passed. A separately identified app
  instance visibly opened a synthetic Markdown document, created a Recents
  tab, switched tabs, displayed 25 search results, removed count/navigation
  controls on clear, and displayed the reader correctly in light/dark mode.
  **Limit:** the intermittent black/magenta hover failure was not reproduced
  in this run, and long-duration hover stability remains unconfirmed. The
  release notes describe the rendering change as addressing the issue, not
  as a demonstrated cure. The original user session was left running.

- **Text-copy cleanup landed 2026-09-09.** ⌘C on a PDF selection now re-flows
  the text: lines within a paragraph joined by a space, line-end hyphens
  closed up where they are syllable breaks, paragraphs separated by one return.
  Edit ▸ Copy Without Cleanup (⌥⌘C) is PDFKit's raw copy. The logic is
  `CopyCleanup` in Core (`text(for: PDFSelection)`, `text(lines:)`,
  `text(_ raw:)`; 31 tests in `CopyCleanupTests`), geometry-driven from
  `selectionsByLine()`: same-baseline fragments are merged first (PDFKit cuts
  a line at every font change, so a superscript footnote marker arrives as its
  own "line"), lines are clustered into columns per page (a split needs a
  3 × line-height jump in left edge *and* clearance past the running
  cluster's right edge), margins are the 25th/75th percentiles so a running
  head or watermark cannot poison them, and a paragraph break falls where a
  line steps in by more than 0.8 line heights relative to the previous line,
  where a short line ending in terminal punctuation leaves room for the next
  line's first word, where the baseline step exceeds 1.6 line heights, around
  a centred line whose indent changes, before a list marker (hand-parsed;
  `v.` excluded so a wrapped case name is not roman numeral five), or across
  an empty line. Hyphens: uppercase or digit on either side keeps it; a soft
  hyphen is always dropped; otherwise the platform spell checker decides
  (`NSSpellChecker` / `UITextChecker` via an `isWord` hook) — joined form is a
  word → drop; both halves are words → keep ("well-known"); neither → drop
  ("certiorari"). Verified on real documents through Core (no GUI): a Harvard
  Law Review Foreword page came out one line per body paragraph with heading
  and footnotes separate; a two-column *AJPS* article joined across the column
  break with its block quote intact; a 1980 JSTOR scan closed up
  "protec-tion", "un-derstanding", "law-yers". Known misses: a bold heading
  at the top of a column with no air above it glues to the previous paragraph;
  a select-all still carries running heads and folios as paragraphs and can
  append a sideways "Downloaded from" watermark; footnote numbers stay glued
  ("appointees.26") and a URL wrapped without a hyphen gains a space. Mac
  detail: `PDFView` implements `validateMenuItem:` only in Objective-C, so
  `ReaderPDFView` forwards everything but `copyRaw:` to PDFView's own IMP;
  PDFView answers YES for `copy:` with no selection, so Copy was always
  enabled and Copy Without Cleanup is the stricter of the two. iOS gets the
  same `copy(_:)` override (simulator build clean; not run on a device).
  **Not verified: the actual pasteboard write in the running app** — the
  harness cannot press a nil-target menu item without a key window.
- **Two follow-ups to the tab-strip fix, 2026-09-09.** (1) *Hovered tab
  flashed black.* Parking the plate inside the title-bar container put it
  directly behind the tab bar, where macOS 26's glass tab-hover highlight
  samples it; a view with `alphaValue < 1` cannot be sampled through (the
  highlight falls back to a solid fill — black here, magenta in the
  2026-09-08 note), so `TitlebarBackdrop.paint` now bakes the opacity into the
  layer's background colour (`color.withAlphaComponent(alpha)`) and keeps the
  view at `alphaValue = 1`. The band looks identical (colour at `alpha` over
  the blurred backdrop either way). This likely also closes the older
  magenta-pill item. Not machine-verifiable (hover needs a real pointer / key
  window); Dan to confirm on screen. (2) *Empty match-count capsule always
  showed.* The `.searchCount` and `.searchNav` items are dropped from
  `toolbarDefaultItemIdentifiers` (kept in `allowed`) and inserted after the
  search field only while a search is returning a count, via
  `setSearchResultsVisible(_:)` driven from `findControllerCountDidChange`
  (non-empty `countText`) and removed on `findControllerDidClear`. Verified
  read-only on a pid-isolated instance: idle toolbar = Sidebar + page
  indicator + search field only (no count); typing "court" inserts
  "Matches 1 of 1802" and the Previous/Next control; both carry
  `.user`/`.standard` priority from Part B so the count still survives a
  narrowing window during an active search. The clear-path removal (inverse of
  the verified insert) could not be scripted (the driver could not reach the
  field's cancel button); Dan to confirm the capsule vanishes when the search
  is cleared.
- **Tab strip went dark on hover -- root cause and fix, 2026-09-09 evening.**
  Follow-up (1) above had the mechanism backwards, and the change that
  followed it (a `findTabBar` exclusion in `TitlebarBackdrop.relayout` that
  raised the plate's bottom edge to the *top* of the tab strip, so the plate
  never sat behind the tab bar) is what Dan's "tabs flash black on mouseover"
  screenshot shows: strip mid-grey with *light* text, hovered tab darker. The
  tab bar's material and its hover highlight are within-window backdrops --
  they sample the window's own pixels behind them. With the plate behind the
  strip they sample white-at-0.88 and look normal; with the strip uncovered
  they sample the window's clear background, i.e. transparent black, so the
  strip reads as a dark scrim and the hover pass goes near-black. Measured on
  a pid-isolated two-tab repro at 0.88/light/blur (Alpha-tab region, 0-255):
  plate behind strip 234 idle / 228 hovered; strip uncovered 169 idle / 96
  hovered; no plate at all 169 / 96 (same thing). A 45-frame burst through the
  hover-in with the plate behind the strip shows 229 -> 218 and no transient.
  Fix: the exclusion is gone (the plate fills the whole container again) and
  `paint` bakes the opacity into the layer colour with `alphaValue = 1` (both
  forms sampled fine; the baked one is kept as the simpler layer). Verified
  light 0.88 hover, dark 0.88 hover, light 0.6 idle. Not re-verified: the
  original "flashed black" report against the plate-in-container build, which
  could not be reproduced here in either alpha form -- if it recurs, note the
  preceding action, since the 2026-09-08 magenta pill was stateful. Repro kit
  (pointer glide + activation, burst capture, isolated bundle with env-var
  pref overrides) in `AI Memos/hover-harness-2026-09-09/`. Tests must be run
  with the env overrides: `defaults write` into the isolated bundle's domain
  was silently ignored (the app came up at 100 %), which is why the first
  round of trials here showed nothing.
- **Hover follow-up, same evening, still open: the stateful black/magenta
  glass failure.** After relaunching on the fixed build Dan still reported
  "black flashing" on hover and then a magenta tab (the 2026-09-08 pill,
  back). Established since: (1) the *steady* hovered-tab look at 0.88 -- a
  flat grey capsule, no sheen (`AI Memos/hover-harness-2026-09-09/
  hover-100-vs-88.png`) -- is **identical at 100 % opacity**, so that slab is
  macOS 26's normal hover highlight, not ours. (2) The black/magenta is a
  separate, stateful failure of the hover glass in Dan's long-running process:
  three recordings of his real window (per-window capture, then screen-region
  capture at 30 fps, then a frame-accurate ScreenCaptureKit stream,
  `sck.swift`, gated to blocks the Glassine window actually owns) never caught
  it, partly because Dan hovered outside the capture windows, and a 12-round
  churn-then-hover loop on a fresh pid-isolated instance (`churn2.sh`: blur
  off/on, opacity steps, tab switches, resizes, new tabs, dark/light, then a
  hover capture checked for dark or magenta blocks) never provoked it either.
  (3) The plate survives tab switches (a 1 s per-window state log:
  `host=NSTitlebarContainerView sameContainer=true` before and after AX tab
  presses), so "container rebuilt, plate gone" is not the mechanism in a
  fresh instance. Best remaining suspect is the private CGS background blur:
  a within-window backdrop (the hover glass) in a window that also carries
  `CGSSetWindowBackgroundBlurRadius` is the classic recipe for solid magenta
  /black backdrops, it matches "never at 100 %", and the 2026-09-08 pill
  cleared on a blur toggle. **Next:** Dan runs a while with Window ▸ Blur
  Behind Window off; if the failure never recurs, replace the CGS blur with a
  public `.behindWindow` NSVisualEffectView backdrop (design change: system
  material tint instead of our own, page alpha stays), or default blur off.
  Not tried: reproducing with sleep/wake, display change, or long uptime.
- **Search: a click into the document jumped back to the first match (Dan,
  2026-09-09 evening; fixed).** `NSSearchField` with `sendsWholeSearchString =
  false` sends its action on every edit *and again when editing ends* -- a
  click into the page ends it -- with the unchanged text, and `searchChanged`
  called `startFind` unconditionally, which shows match 0 on the first hit.
  `FindController.search(_:)` is now the field's entry point: trims, compares
  with the effective current query (`pendingQuery` while a cancellation is
  pending, else `lastQuery`) and does nothing when equal; anything else goes
  to `startFind`. Return in the field, ⌘G, the cancel button and the
  empty-field reset are untouched (they never went through `searchChanged`).
  Test: "The field's action with an unchanged query does not restart the
  search". iOS's search bar path was not changed (it does not re-send on end
  of editing the same way; not verified on device). Installed to
  /Applications/Glassine.app along with the tab-strip fix; nothing committed.
- **Tab strip fix landed 2026-09-09 (second attempt; the first was reverted).**
  Root cause, bisected on a real multi-tab repro: the translucency plate
  (`TitlebarBackdrop`) sat in the window's theme frame as a *sibling* of
  `NSTitlebarContainerView`. On a tab-selection hand-off AppKit tears that
  container down and rebuilds it, and a foreign theme-frame sibling breaks the
  rebuild — the container returns without its `NSTabBar`, the 88 pt band stays
  reserved but empty, and `tabGroup.isTabBarVisible` still reads true, so
  nothing repairs it. Shipped 1.5.0 hit this **20 of 20** opens in a 4-tab
  saved-state restore at 0.88/blur/light; that is Dan's original "tabs vanish
  when I open a PDF / use search", worse than intermittent once several tabs
  are open. **The first fix attempt made it permanent** by re-running
  `WindowChrome.apply` (hence the plate insert) across the whole group on many
  new events, so the insert kept coinciding with hand-offs; it was reverted
  the same day (regressed code saved at `AI Memos/chrome-debug-harness-
  2026-09-09/tab-strip-fix-REGRESSED.patch`). **The fix that landed** is small
  and different: park the plate as the *backmost child inside* the title-bar
  container (fallback to the theme frame if the container class stops
  resolving), so it rides along when AppKit rebuilds the container and never
  touches the subview list AppKit reshuffles. Two hunks in
  `ReaderWindowController.swift` (`TitlebarBackdrop.relayout` fills its
  superview when parked in the container; `applyTitlebarBackdrop` hosts it in
  the container), no group-reapply, no delegate handlers, no repair scaffold.
  Verified on the same repro that broke 20/20: **0 of 32** opens broke, across
  restore, a 1→2→3→0 tab-selection hand-off, and resize; container and tab bar
  present throughout; at opacity 1.0 the plate is absent and tabs are fine. The
  band paint is unchanged by construction (same `paint(.white, 0.88)` call,
  plate fills the full 88 pt band backmost behind toolbar/title/tabbar).
  Reaches into a private AppKit view (adds a child to `NSTitlebarContainerView`)
  — same risk class as the existing close-button walk it reuses; falls back if
  the class stops resolving. **Not verified: a live band-luma pixel capture**
  (the pid-isolated test window was occluded; capturing it would disturb Dan's
  foreground) and **the on-screen look in Dan's own session** — he should eye
  the band at 0.88 on relaunch. Hit-count half (Part B) below is unaffected and
  also shipped. The reverted first-attempt write-up follows, kept for context.

- **Tab strip and hit count, 2026-09-09.** Dan: the tab strip vanishes "in
  some instances when I open a new PDF, and particularly when I use the search
  function" (documents stay open, only the strip goes), and the "N of M" hit
  count drops out as the window narrows. Diagnosed first, on the unfixed 1.5.0
  code, with a theme-frame dump (`AI Memos/chrome-debug-harness-2026-09-09/`,
  local only: the `GLASSINE_DEBUG_CHROME` patch, the pid-targeted AX/CGEvent
  driver, the width-sweep and tab-churn scripts) run pid-isolated with the app
  never activated, ~465 samples at 0.88 and 1.0. **The `TitlebarBackdrop`
  plate is not the cause**: the theme frame's order was `[content, plate,
  NSTitlebarContainerView]` in every sample, and the tab bar lives *inside*
  that container (`NSTabBar < NSView < NSTitlebarAccessoryClipView < NSView <
  NSTitlebarView < NSTitlebarContainerView`), so the plate cannot get above
  it. What the dump did catch, at 1.0 as well as 0.88: on every change of the
  group's selected window AppKit removes the `NSTabBar` accessory from the
  outgoing window and re-adds it to the incoming one, and between those steps
  `tabGroup.windows.count > 1`, `isTabBarVisible == true`, the band is still
  reserved at full height and **no tab-bar view exists in the selected
  window's theme frame** — Dan's symptom exactly, if the re-add is ever
  dropped. In the harness it always recovered within one 0.25 s sample; the
  stuck state itself was not reproduced (no key window — see the caveat).
  Fix, three layers in `WindowChrome`: (1) `apply` is change-guarded —
  `titlebarAppearsTransparent`, `titlebarSeparatorStyle`, `isOpaque`,
  `backgroundColor`, the content alpha and the CGS blur radius (cached per
  window) are written only when they differ, because each of those setters
  re-lays out the very container the hand-off runs through, and `apply` now
  runs on far more events; (2) `reapply(group:)` runs it for every window in
  the tab group from `showWindow`, `StartTabWindowController.present`,
  `windowDidBecomeMain`, `windowDidResize` (outside live resize),
  `windowDidEndLiveResize`, the full-screen transitions, and one turn after
  `beginSearchInteraction`/`endSearchInteraction`; the plate keeps its
  measured place below the container with a per-pass index check instead of
  the one-time install, and `TitlebarBackdrop` no longer stacks a superview
  observer per re-add; (3) `repairTabBar`, 0.4 s after becomeMain / showWindow
  / a search interaction (longer than the measured hand-off): toggles the bar
  back if `isTabBarVisible` is false with >1 tabs, and otherwise walks the
  title-bar container for an `NSTabBar`-named view (self-validating: the
  repair is inert until the walk has found that class once in this process,
  so a renamed private class cannot make it misfire), forcing a layout pass
  and, failing that, a hide/show toggle; one attempt per window per 2 s, each
  logged as `Glassine: tab bar …` via `NSLog`. **The log line is the
  instrument**: nothing has yet proved the repair fires on the real stuck
  state, so if the strip still goes missing, `log show --predicate
  'eventMessage CONTAINS "Glassine: tab bar"'` says whether the repair ran and
  whether it helped. Hit count: the `.searchCount` item is now
  `visibilityPriority = .user` and the prev/next chevrons `.standard`
  (equal-priority items are evicted from the trailing end, and a view-based
  item in the overflow menu shows only its label, "Matches"). Verified on the
  fixed build, pid-isolated, dark, 0.88 + blur and 1.0: strip present after
  three successive opens, a live find with ⌘G-equivalent steps and Escape,
  480 pt idle and with the field expanded, ⌘T-equivalent start tab and its
  replacement; the count `1 of 1955` visible at 960/800/700/600/520/480 pt
  where the old build lost it below 800 (only the page indicator and the
  chevrons overflow now; the sidebar toggle overflows below 700); the band at
  0.88 measured luma-identical to the pre-fix capture (9.8 % vs 9.8 %); 40 AX
  tab switches at 960 and 480 pt with zero repair log lines. **Not verified:
  the `windowDidBecomeMain` path** — the app was never key (Dan at the
  keyboard), so only the `showWindow` and search-interaction triggers ran;
  the light appearance (Dan's `appearance` is 0 = System and
  `AppleInterfaceStyle` is unset, so he is actually in light mode); the
  magenta hover pill (no real pointer). Two things the fix does not touch,
  both AppKit's own: **with many tabs in a narrow window `NSTabButton`s get
  squeezed to zero width and alpha 0** — at 480 pt with 10 tabs six rendered
  as blank slots, and with 5 tabs one did — which reads as "tabs disappeared"
  and may be part of what Dan sees; and the translucent Recents start tab
  (below). The test instance overwrote `NSWindow Frame ReaderWindow` in
  `com.epps.Glassine`; it was restored by hand.

## Build, run, test

```sh
./build.sh --run           # release build + launch (run from repo root)
./build.sh --debug         # debug config
./build.sh --adhoc         # skip Developer ID signing (offline, no keychain)
swift test --package-path Core   # the GlassineCore unit tests (Swift Testing)
./scripts/make-icon.sh     # regenerate app icon assets
swift scripts/make-doc-icon.swift   # regenerate the Markdown document icon
./release.sh 1.0.1         # cut a release (see "Signing, notarization, updates")
```

- Repo lives at `~/ClaudeCode/pdf` on the MacBook and `~/ClaudeCode/pdfreader` on the Studio; both directory names predate the rename and were left alone. Use absolute paths from whichever root you're in.
- Always run the `.app`, never the bare binary: NSDocument needs Info.plist.
- Dependencies are Sparkle and swift-markdown; the latter is pinned by commit
  (currently `27b7fc1a`) because its manifest depends on swift-cmark by branch.
  It is source-only Swift + C and links statically, so `build.sh` needs no
  change for it.
- Force dark/light without touching system settings:
  `defaults write com.epps.Glassine appearance -int 2` (0 system, 1 light,
  2 dark), relaunch, then set back to 0.
- `screencapture -x /abs/path.png` works on this machine for visual checks;
  crop with `sips -c`. GUI keystroke automation via System Events is flaky
  (keystrokes can land in other apps); guard on Glassine being frontmost.
- **A second copy of the app can be run alongside an already-running one** with
  `open -n -a build/Glassine.app <file>` — worth knowing when another session
  has left a Glassine running and quitting it would trample their work. Both are
  called "Glassine", so drive yours by pid: `AXUIElementCreateApplication(pid)`
  for the window list and frames, `NSRunningApplication(processIdentifier:)`
  `.activate()` before any click (the frontmost app's window is the one a
  CGEvent click lands in), and `CGEvent.postToPid` for key equivalents, which
  goes into one process's queue rather than the HID tap. Screenshots still come
  off the screen, so activate first and the right window is on top.
  `postToPid` does *not* get past a locked screen: nothing becomes key there, so
  ⌘T lands nowhere.
- A locked screen blanks `screencapture` **and** empties System Events' window
  list, but `CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
  kCGNullWindowID)` keeps reporting every window's title, bounds and
  `kCGWindowIsOnscreen` right through it. That is enough to check which windows
  an action put on screen without a single pixel, and it is how the Recents
  work was verified while the Mac sat locked. Two cautions: while locked the
  bounds come back scaled (0.9× here) and nothing ever becomes *key*, so
  anything riding on `windowDidBecomeKey` will not fire.
- Test PDFs the agents used live in the session scratchpad and are gone;
  Dan has plenty in ~/Downloads (SCOTUS slip opinions are good: color,
  small caps, lots of matches).

## Architecture (Sources/Glassine)

| File | Role |
|---|---|
| `main.swift` | NSApplication bootstrap, sets `AppDelegate`. |
| `AppDelegate.swift` | Installs the menu, applies saved appearance override, shows the Recents window on launch/no windows (and hides it when a reader window becomes key), appearance & invert menu actions. Owns the Sparkle `SPUStandardUpdaterController` (started eagerly, so the scheduled background check runs). |
| `MainMenu.swift` | Entire menu bar in code: Glassine, File, Edit, View, Markdown, Go, Window, Help. Nil-target actions ride the responder chain (`zoomIn:`, `goToNextPage:` etc. are PDFView's) and disable themselves when nothing implements them. View is display only (panes, zoom, Appearance ▸, invert, full screen) and must keep its title — AppKit appends the tab-bar items to the menu called "View". **Markdown** is its own top-level menu (2026-09-06): layout, the Style submenu (rebuilt on every open via `markdownStyleMenuIdentifier` + the app delegate's `menuNeedsUpdate`, so a `.css` dropped into the Styles folder shows up without a relaunch), Text Size ▸ plus ⌥⌘=/⌥⌘− Larger/Smaller Text, a second Export as PDF… and the LaunchServices default-app item. **Window** carries the translucency block at the top — the `OpacityMenuItemView` slider row, Blur, ⌥⌘↑/⌥⌘↓ — above the standard items, and is still `NSApp.windowsMenu`, so AppKit fills in the window list below. "Open Recent" is just a submenu with a `clearRecentDocuments:` item; AppKit fills it. "Check for Updates…" is passed the Sparkle updater as an explicit target — it isn't in the responder chain — and the app-delegate items (appearance, opacity, Markdown preferences) are targeted explicitly for the same reason. |
| `GlassineDocument.swift` | `NSDocument` (ObjC name `GlassineDocument`, referenced from Info.plist) wrapping a `PDFDocument`. Two `Kind`s: a PDF is opened directly; a Markdown file is decoded and converted by `GlassineCore.MarkdownDocumentModel.content(of:url:)` in `read`, then typeset asynchronously and installed through `.glassineDocumentDidReplacePDF` (declared here). Owns the `FileWatcher`, the re-render on a style/size/layout change, the word count, `isContinuousMarkdown`, and `exportAsPDF` (which typesets a second, paginated render when the reader is showing a continuous one). The outline comes from `MarkdownDocumentModel.applyOutline`. `PDFDocumentDelegate`: returns `ReaderPage` for pages, forwards find callbacks to the window's `FindController` via `FindSink`. |
| `MarkdownRenderer.swift` | The Mac's `HTMLPrinter`. `WebKitHTMLPrinter` holds one offscreen `WKWebView` in a never-shown borderless window, measures a continuous job with `scrollHeight`, and prints through `NSPrintOperation.runModal(for:delegate:didRun:)` with `canSpawnSeparateThread` — every identity check and the `nonisolated` didRun hop intact. `MarkdownRenderer.shared` is a shell that hands it to `GlassineCore.RenderQueue`, which owns the queue, superseding, the watchdog, the retry and the idle teardown. |
| `RecentsViewController.swift` | The recents picker itself, hosted by the launch window and by every start tab. Rows, the filename filter and the two secondary labels come from `GlassineCore.RecentsModel`; this file keeps the `NSTableView`, the filter field (⌘F, via the same `focusSearch:` selector the reader uses), Return/double-click to open, Delete or "Remove from List" to forget a row, file URLs dropped anywhere on it, `drawsListBackground: false` for a start tab, and `RecentsTableView` (Return/Delete/Escape), `RecentsDropView` and `RecentRowView`. It opens nothing itself: `onOpen`, `onOpenOther` and `onCancel` leave that to the host. |
| `RecentsWindowController.swift` | The launch window: a shared, non-tabbed 680×520 window around a `RecentsViewController`. Opening a document hides it; Escape leaves (a beep if there is no document to go back to). |
| `StartTabWindowController.swift` | A new tab with nothing in it yet. A reader-group window (same `tabbingIdentifier`, `.preferred` tabbing, unified toolbar with its own identifier and nothing in it but a flexible space) titled "Recents", holding a `RecentsViewController`. `present(besides:)` is what ⌘T and the "+" button call. Picking, dropping or "Open Other…" replaces it in place. |
| `ReaderWindowController.swift` | Window, `NSSplitViewController` (sidebar + reader), unified toolbar, page indicator, search field + hit counter + previous/next segmented control (⇧⌘G/⌘G equivalents), tabs, black chrome in dark mode, window translucency and the backdrop blur. The find state machine and the reading-position memory are `GlassineCore.FindController` (this class is its `FindControllerDelegate`) and `GlassineCore.ReadingPosition`; the progress fraction is `GlassineCore.ReadingProgress`. |
| `ReaderViewController.swift` | `ReaderPDFView` (PDFView subclass: arrow-key paging, hosting a `GlassineCore.FindHighlighter`), and the appearance routine that builds and installs the inversion filters (`makeDarkFilters` and `linearLight` stay here; the `DarkPaper` levels they read are Core's). |
| `SidebarViewController.swift` | Two panes behind a segmented control: `PDFThumbnailView` (mirrors the inversion filters) and an `NSOutlineView` table of contents driven from `PDFDocument.outlineRoot`. Clicking a row navigates; `syncSelection()` maps the view's own rows onto `GlassineCore.OutlineSync` and asks it which entry has started. The outline is native text and is deliberately *not* filtered. |

**Architecture (Core/Sources/GlassineCore)** — the package both apps consume;
nothing in it imports AppKit or UIKit. Tests live in
`Core/Tests/GlassineCoreTests` (Swift Testing, `swift test --package-path Core`):
44 cases over the Markdown pipeline, every preference key and the LRU, the find
state machine against a real in-memory PDF, the outline rule, the progress
arithmetic, the recents model, and both paths through `applyOutline`.

| File | Role |
|---|---|
| `MarkdownHTML.swift` | Markdown → HTML, and the types around it: `MarkdownLayout`, `MarkdownStyle` (the six built-ins plus the `.css` files in `Prefs.stylesDirectory`), `MarkdownStyling`, `MarkdownStats`, `MarkdownHeading`. Decode (UTF-8, UTF-16 by BOM), front-matter strip, `Markdown.Document` + `HTMLFormatter`, the `ImageInliner` (relative local images → `data:` URIs) and `HeadingAnchorer` (invisible `glassine-outline://` anchor per heading, returning the heading list beside the HTML) rewriters, the word-count walker, and the two-layer stylesheet. Pure Swift, safe off-main. |
| `Prefs.swift` | UserDefaults, against an injectable `Prefs.defaults`: invert toggle, dark-paper level, appearance override, per-file last position with its 500-entry LRU, Markdown style/layout/size, window opacity and blur, and the 30-entry `recentDocuments` list with its bookmarks. `stylesDirectory` and `applyAppearanceOverride` are the two hooks each app sets at launch. |
| `DarkPaper.swift` | The three paper levels and their `lift`/`top`, written as screen sRGB — the one place to re-tune them — with the conversion each platform owes them. |
| `FileWatcher.swift` | vnode `DispatchSource` on the file *and* its parent directory, 250 ms debounce, `(inode, mtime, size)` gate, reopens the descriptor when the file is replaced or recreated. |
| `ReaderPage.swift` | `PDFPage` subclass; draws the dark-mode find highlights. State lives in an ObjC associated object, never a Swift stored property. |
| `FindController.swift` | Incremental find over a `PDFDocument` and the state machine that makes replacing a running search safe: cancel, drop the stragglers, start the replacement from the old search's end callback or a 0.5 s fallback. Batches highlights at 150 ms, owns `matchIndex`, the wrap in `step(by:query:)` and the exact count strings. Talks to the view through `FindControllerDelegate`; receives PDFKit's callbacks as a `FindSink`. Three identities keep the machine honest (2026-09-06): an edit during a pending cancellation replaces the queued query (empty string included) rather than starting a second one; the fallback timer carries a token so an earlier cancellation's timer cannot fire into a later wait; and both callbacks are checked against `document`, which is what `FindSink.findDidEnd(in:)` exists for — its protocol-extension default forwards to the plain `findDidEnd()`, so a platform shell with nothing better to pass needs no change. |
| `MarkdownReloader.swift` | Generations for Markdown reloads. `reloadFromDisk` converts on a concurrent queue, so two saves race and the content hash cannot tell the loser from a new revision; each reload is stamped and a completion whose stamp is stale is dropped. `invalidate()` retires everything in flight (close, and a file that moved). The read is a `package` seam taking a `Delivery` box, so tests deliver out of order without touching the disk. |
| `ReadingAnchor.swift` | Where the reader is, said in the text's terms rather than the pagination's: outline row, its label, and the depth below it. Survives a re-typesetting that moved every page break, and Pages ↔ Continuous, which page-and-point cannot. Resolves by row, then by nearest matching label, with 24 pt of clearance above the next heading; `OutlineSync.depth(of:in:)` / `ordinal(atDepth:in:)` are the arithmetic underneath. |
| `HeadingLocator.swift` | Measure-then-snap for a render with no link annotations (iOS's print paths): `MeasuredHeading`, a `Geometry` (sheet height, margin, the 0.8 pt-per-CSS-px shrink), `predict`, `isInBand` (the clipped-ghost rule), `snap` via `findString`, `interpolate` (fill the headings `findString` cannot place from their located neighbours, then make the sequence monotonic) and `located`, which hands `applyOutline` its `located:` map. macOS never calls it. Note also that `OutlineSync.currentOrdinal` and `ReadingPosition.current(of:)` carry an `#if canImport(UIKit)` branch: on iOS `PDFView.currentDestination` answers with the bottom of the visible area and `currentPage` with the wrong page at a break, so they read `pdfView.convert(.zero, to: pdfView.page(for: .zero, nearest: true))` there; the macOS branch is unchanged. |
| `FindHighlighter.swift` | Flattens the matches into per-line rectangles keyed by page, pushes them into the `ReaderPage`s and invalidates the tiles. The only platform difference is `setNeedsDisplay()` vs `needsDisplay = true`. |
| `OutlineSync.swift` | "Which chapter am I in?": a comparable `Ordinal` with the cropBox clamp, the current position of a `PDFView`, a pre-order flattening of a `PDFOutline`, and `index(atOrBefore:)`. |
| `ReadingPosition.swift` | What is saved and when: the position read once at init, the `restoreStarted`/`restoreFinished` gates, the two-pass `go(to:)` with its single retry, `targetForInstall(initial:)` and `lastInstallTarget`. |
| `ReadingProgress.swift` | The continuous-Markdown fraction and its inverse, as pure geometry. |
| `MarkdownDocumentModel.swift` | `MarkdownContent` (html, headings, stats, hash) and the two functions that make it — one synchronous for a concurrent `read`, one off-main for a reload — plus `applyOutline`, which builds the bookmark tree either by scanning and removing the `glassine-outline://` link annotations (macOS) or from a pre-located heading map (iOS). Also `RenderedMarkdown` and the `MarkdownTypesetter` protocol. |
| `RenderQueue.swift` | `MarkdownRenderError`, the `HTMLPrinter` primitive, and the platform-independent render pipeline: one job at a time, supersede by key, a 10 s watchdog that abandons a stuck load, one retry of an empty document after 0.2 s, and a 30 s idle teardown. |
| `RecentsModel.swift` | `RecentRow`, the rows built from `Prefs.recentDocuments` through `Prefs.resolvedURL`, the filename filter, and the folder/page and relative-date strings. |

Support/: `Info.plist`, `Glassine.icon` (Icon Composer package, light+dark),
`Assets.car` (compiled from it), `Glassine.icns` (fallback). scripts/:
`make-icon.swift` renders the artwork, `make-icon.sh` builds icns +
`.icon` + runs `actool`. `scripts/make-icon-concepts.swift` renders
the alternatives that were considered into `Support/IconConcepts/` (gitignored,
~57 MB) and stays as the exploratory record.

**The icon (2026-09-05) is Palette Rules**, round four of the concepts script,
tuned through rounds five and six: four fanned leaves of glassine, each
composited the way the app composites its own translucent window — the blurred
backdrop of everything drawn so far, plus a milky tint, a sheen along the top
edge — with a coloured rim per leaf and four coloured rules (coral, amber, mint,
blue: the same accents the Folio margin tabs used) on the front leaf. Dan chose
**L4 "Near white"** for light and **D5 "Neon Rules"** for dark. It replaced the
Folio-era page-with-margin-tabs icon.

The two appearances are not the same picture on different tiles, and that is
deliberate. On L4's near-white tile (#FBFBFA → #E3E6EA) the fan has almost no
tone to sit against, so the *rims* do the separating: crisp coloured strokes
over a tight, weak soft shadow (blur 11, alpha 0.42 — a wide bloom on a pale
tile reads as a smear), a deepened leaf shadow, and the front leaf's tint raised
to 0.92 so its page still reads as white paper. On D5's graphite tile the rims
bloom instead (blur 20, alpha 0.65) and the sheen runs at 50%, with the leaves
taken correspondingly closer to opaque — the soft light across a dark leaf is
half the top-edge gradient and half the type on the leaves *underneath* glowing
up through the blurred backdrop, and only a less transparent sheet shuts that
off (`dimmed` in both scripts).

**Every `.icns` size is drawn at its own resolution**, the way
`make-doc-icon.swift` does, rather than downsampled from 1024: `make-icon.swift
--size N` plus a `tuning(for:)` table, and `make-icon.sh` renders 16/32/64/128/
256/512/1024 and copies them into the iconset. Below 128 px the rims and rules
are sub-pixel — a 9 pt rim is 0.28 px at 32 — so they are floored at a whole
pixel and the four rules given their own 3 px pitch at 2 px tall; the leaf rects
are snapped to whole pixels; the top leaf is *straightened* (angle 0) at 16 and
32, because a 7° rotation turns a 2 px rule into two grey rows; the fan drops to
three leaves at 32 and two at 16; and the fan is zoomed (1.16 at 32, 1.42 at 16)
because the legacy grid's margin is a luxury at that size. The rim is a
double-width stroke clipped to the leaf at those sizes, so it lies wholly inside
the pixel-snapped edge instead of straddling it. What did not survive 16 px:
the tile all but disappears (the fan fills it), the fan is a one-pixel sliver of
colour at the edges, and the four rules end up equal-width because they are
trimmed to clear the rim — the icon reads as a rimmed card with four coloured
bars, which is the identity and all there is room for.

The **Icon Composer package's structure is unchanged** — same `icon.json`, same
two layer names, same `opacity-specializations` — so macOS 26's tinted and clear
appearances keep working; only the two 1024 PNGs were swapped.

The **Markdown document icon** (the Finder icon for a `.md` file) is separate:
`swift scripts/make-doc-icon.swift` writes the committed
`Support/MarkdownDocument.icns` (10 entries, 16–512 pt at 1× and 2×), which
`build.sh` copies into `Contents/Resources` and `Info.plist` names twice —
`CFBundleTypeIconFile` on the Markdown `CFBundleDocumentTypes` entry and
`UTTypeIconFile` on the imported UTI. Since 2026-09-05 it matches the new app
icon: one sheet of the same family, the same folded corner, a coral rim, the
four coloured rules, and a bold slate M↓ above them. The margin tabs went with
the app icon's, and the sheet moved to the middle of the canvas now that nothing
sits beside it. Only the *light* variant is shipped, because Finder draws one
document icon whatever the appearance is.
`scripts/make-doc-icon-concepts.swift` stays as the exploratory script (six
directions into `Support/IconConcepts/Doc/`). Each size is drawn at its own
resolution rather than downsampled, and 16 and 32 px are hand-tuned in
`tuning(for:)`: the sheet is zoomed to fill the tile, edges and rules snap to
whole pixels, the rim is a double-width stroke clipped to the sheet so a 1 px
rim lands on the pixel rather than straddling the edge, the rules come from one
rounded pitch at 2 px tall rather than four rounded positions, the mark's stem
is forced to 2 px (the proportional 0.25 × height lands under a pixel and greys
out), and at 16 px the rules and the arrow are dropped and the M moves back to
the middle of the sheet — there is only room for the M, and the coral rim is
left to carry the family's colour.

Two gotchas. **LaunchServices caches document icons**, so a rebuild changes
nothing until the bundle is re-registered
(`…/LaunchServices.framework/Support/lsregister -f build/Glassine.app`) and Finder
is restarted (`killall Finder`); and the icon is taken from whichever bundle
LaunchServices resolves as the *handler* for `net.daringfireball.markdown`,
which with a copy in `/Applications` is the installed app, not `build/`.
**Finder icon view shows a QuickLook text preview for `.md`, not the document
icon** (icon previews are on by default), so the icon shows up in list and
column view, Open/Save panels and the Dock — which is why the 16 and 32 px
tiles are the ones worth tuning.

## Design decisions and why

- **Inversion is a layer filter, not page drawing.** `pdfView.contentFilters
  = [CIColorInvert, CIHueAdjust(π)]` (same on the thumbnail view). Invert +
  180° hue = luminance flip with hue preserved, so links stay blue. The GPU
  applies it at composite time: no white flash while tiles render (PDFKit
  paints a white placeholder that page-level inversion can't touch), instant
  appearance switches, printing unaffected. The first attempt (a
  `.difference` fill inside `PDFPage.draw`) had the flash; it's in the
  scaffold commit if ever needed.
- **Consequence: pre-filter colors.** Anything inside the filtered view must
  be chosen for how it looks *after* the filter. Gutter is white 0.997
  pre-filter (CIColorInvert works in linear light, so 0.89 came out
  mid-gray). Green highlight ink is `(0, 0.77, 0)` pre-filter, calibrated by
  pixel-sampling screenshots to ~#69E170 on screen; the analytic value
  clips. Formula: same chroma, luminance 1−Y.
- **Dark Paper is one more filter stage, and the chrome follows it.** Above
  `DarkPaper.black` the chain gets a third filter, `CIColorMatrix`, that
  compresses the inverted image into `[lift, top]`: paper (inverted black)
  rises to `lift`, ink (inverted white) falls to `top`, alpha untouched.
  Charcoal is 0.11/0.93, Gray 0.17/0.90, both written as *screen* values in
  `DarkPaper.lift` / `.top` — the one place to re-tune them — and converted to
  linear light where the filters actually work. `applyWindowAppearance` paints
  the dark window background with the same `lift`, so the title bar and tab bar
  sit on exactly the page's tone (measured identical). `black` adds no filter
  and keeps `.black` chrome, so the default look is the old one byte for byte.
  The gutter needs no per-level tweak: it is a fixed pre-filter white and the
  matrix carries it along, staying a few levels above paper at each setting.
  Find highlights need none either — the matrix compresses toward `top`, so the
  green loses a little saturation but stays plainly green.
- **No `.fullSizeContentView`.** macOS 26 Liquid Glass toolbar/tab bar tint
  from the content beneath them and they sample the PDF view's *pre-filter*
  colors, so with content under the toolbar the chrome went light gray and a
  cloudy gradient (scroll edge effect) appeared. Content now stops below the
  toolbar. In dark mode the window also gets `titlebarAppearsTransparent`,
  `backgroundColor = .black`, `titlebarSeparatorStyle = .none` to make the
  chrome solid black.
- **Translucency is content alpha plus a backdrop blur, not `alphaValue`.**
  `window.alphaValue` fades the window *and* leaves everything behind it
  perfectly sharp, which is not what Terminal-style translucency looks like. So
  below 100% the window goes `isOpaque = false` with a clear background and the
  alpha lands on `contentViewController.view` instead; the window's own pixels
  are then transparent, which is the precondition for blurring behind it. The
  blur is the same CoreGraphics SPI Terminal and iTerm use,
  `CGSSetWindowBackgroundBlurRadius(CGSMainConnectionID(), windowNumber, 24)`,
  with both symbols resolved through `dlsym(RTLD_DEFAULT, …)` at first use, so a
  macOS that withdraws them costs the blur and not the app. It works on macOS
  26, including for tabbed windows. The public fallback (an
  `NSVisualEffectView` with `blendingMode = .behindWindow` as the window's
  bottom-most view) was therefore never needed, and would have meant
  re-parenting the split view controller's view — which is what gives the
  sidebar its full-height layout — so it stayed unwritten.
- **The title bar gets a plate of its own, in the theme frame.** Content alpha
  leaves the band above the content view at alpha 0, which is why a translucent
  window used to show the desktop through its toolbar razor-sharp while the page
  was blurred. `WindowChrome` inserts a `TitlebarBackdrop` — the page's colour at
  the page's alpha — into `window.contentView!.superview!` (the `NSThemeFrame`),
  `positioned: .below` the title-bar container, so the toolbar's glass capsules,
  the title and the tab bar still draw over it. That is a dependency on a private
  view hierarchy and is written to survive its going away: the container is found
  as the ancestor of `standardWindowButton(.closeButton)` that the theme frame
  owns directly, and if that lookup ever returns nil the plate is added with
  `relativeTo: nil`, which puts it at the very back — still covering the band
  (nothing else paints there) and still under the content view. This is *not*
  `.fullSizeContentView` returning: content still stops below the toolbar, for
  the reason in the decision above. In translucent mode light windows get
  `titlebarAppearsTransparent` too, so the plate is what colours the band in both
  appearances; opaque windows are untouched, and the plate is removed at 100 %.
- **`pageShadowsEnabled = false` when inverted.** Inverted drop shadows
  showed as bright halos and a light band at the bottom of the view.
- **Find highlights in dark mode are custom-drawn** in `ReaderPage.draw`: a
  translucent box (pre-filter green `(0, 0.77, 0)` at 0.35 alpha, which the
  filter turns into a dark-green box with pale-green glyphs), rect inset 1pt
  vertically so neighbouring ascenders/descenders aren't covered; the current
  match adds a 1.5pt solid outline *inside* its rect. An outline drawn
  *outside* the rect produced dark streaks across adjacent lines. An earlier
  version recoloured the glyphs with `.screen` blend plus an underline; Dan
  asked for boxes (2026-09-04). Light mode uses native
  `highlightedSelections` in systemGreen.
- **Native `NSWindow` tabbing** (`tabbingMode = .preferred`, identifier
  `GlassineReader`, explicit `addTabbedWindow` in `showWindow`) rather than a
  custom tab bar. `newWindowForTab:` in the responder chain gives the "+"
  button and ⌘T.
- **Page indicator** is one attributed label ("4 of 30") that swaps to an
  editable field on click/⌥⌘G. Two-control versions were never centered.
- **In continuous Markdown the same capsule shows reading progress**, "53%",
  because "1 of 1" says nothing about a 65-page document laid out as one page.
  The fraction is scroll geometry, not PDF coordinates: the PDFView's document
  view and the clip view that frames it give `clip.bounds.minY /
  (documentView.bounds.height - clip.bounds.height)`, i.e. how far the *top* of
  the visible area has travelled through the scrollable range, so it reads 0 at
  the top and 100 with the bottom of the page at the bottom of the window (a
  page shorter than the view is all on screen and reads 100). Going the other
  way — `currentDestination` plus `bounds(for: .cropBox)` — means undoing
  PDFKit's bottom-up coordinates and the gutter offset that already trips up
  `syncSelection`, for the same number. Movement is reported by the clip view's
  `NSView.boundsDidChangeNotification` (with `postsBoundsChangedNotifications`
  set on it) because a continuous document scrolls without ever changing page,
  so `.PDFViewPageChanged` never fires; `.PDFViewScaleChanged` covers zooming,
  which changes how much fits on screen. The notification arrives every frame
  of a scroll, so the label is rebuilt on a 50 ms debounce. The clip view is
  re-resolved after every install: PDFKit builds a fresh document view per
  document. Editing the capsule in this mode takes 0–100 and scrolls the clip
  view directly.
- **Replacing a search while one is running** goes through a small state
  machine in `ReaderWindowController.startFind`: PDFKit's find callbacks
  carry no query identity and arrive asynchronously, so the old search is
  cancelled, `awaitingCancelledFindEnd` drops its stragglers, and the new
  query starts from the old search's end callback (or a 0.5s fallback
  timer). Without this a stale match or end could land in the new results.
- **Markdown is rendered to a real PDF, not shown in a web view.** Every
  reader feature -- tabs, the dark-mode inversion filter, arrow-key paging, the
  "N of M" indicator, find with hit counts and green boxes, position memory,
  printing -- already works on a `PDFDocument`, and a paginated memo is what Dan
  wants to read. So Markdown becomes HTML and HTML becomes pages; nothing on
  screen is ever a web view.
- **WebKit typesets it, offscreen.** swift-markdown ships an `HTMLFormatter`, so
  there is no HTML emitter to write; CSS gives reliable tables, code blocks and
  `break-inside: avoid`; and WebKit emits real link annotations. The native
  alternative (a ~500-line AST-to-`NSAttributedString` renderer around
  `NSTextTable`, whose printing is the least reliable part of TextKit, with no
  keep-with-next in TextKit 1) is the documented fallback if the print path ever
  breaks. It was not needed: the WebKit path worked first try on macOS 26.
- **The print path is thread-shaped, and that dictates the API.**
  `WKPrintingView` computes page ranges synchronously only on a secondary print
  thread; on the main thread it returns an open-ended range and never finishes,
  which is the cause of every "WKWebView prints a blank page" report.
  `NSPrintOperation.run()` never spawns that thread. **`runModal(for:delegate:
  didRun:contextInfo:)` with `canSpawnSeparateThread = true` does**, even with
  both panels hidden. The exact sequence that works is in
  `MarkdownRenderer.printLoadedPage()`.
- **Margins come from `NSPrintInfo`, never from `@page`.** WebKit subtracts the
  print info's margins itself; setting both doubles them. The stylesheet has no
  page geometry at all.
- **The Markdown stylesheet is written for life after the inversion filter.**
  Same arithmetic as the gutter: the filter is a luminance flip, so code-block
  and table-header backgrounds are near-whites (`#FAFAFA`, `#F5F5F5`) that come
  out as dark grays. A `#F2F2F2`-class gray would invert to mid gray and look
  muddy. Link blue is `#0B57D0`, whose hue survives the 180° rotation.
  **The page background is the exception: it must be pure `#FFFFFF`.**
  `CIColorInvert` works in linear light, so the flip magnifies anything that is
  not white — Antique's first draft used a `#FFFDF8` paper and the whole text
  block came back as a brown slab on the black gutter. Panels (code, table
  headers) *want* to be visible after the flip; the paper does not. `--paper`
  is still a variable so a custom style can tint it, with that consequence.
- **The stylesheet is two layers: base + style.** The base layer carries the
  page structure, the list/checkbox/table/code mechanics, `a.fh`, the
  keep-with-next hack, and a dozen CSS variables (`--body-font`,
  `--heading-font`, `--mono-font`, `--body-size`, `--line-height`,
  `--paragraph-gap`, `--text`, `--muted`, `--rule`, `--code-bg`,
  `--code-border`, `--th-bg`, `--link`, `--paper`). A style layer follows it
  and usually does nothing but set those variables: that is all six built-ins
  are, and a `.css` file in `~/Library/Application Support/Glassine/Styles` is
  dropped in as that layer verbatim, so it can set the variables or override
  any rule. Size stays a separate preference because it is the one thing a
  reader changes without changing the look.
- **Continuous layout is one very tall page through the same print path.**
  Nothing else in the app has to learn a new mode: it is still a `PDFDocument`,
  so find, the outline, position memory and the inversion filter work
  unchanged, and `displayMode = .singlePageContinuous` with `autoScales` fits
  it to the window's width exactly as it fits a Letter page. The renderer
  measures `document.documentElement.scrollHeight` after the load (an
  evaluation in `.defaultClient` runs even though content JavaScript is off)
  and prints onto `612 × (height + 2)` with all four margins zero; in this mode
  the stylesheet supplies the inch of white space as `body { padding: 72pt }`,
  which is inside `scrollHeight`, and drops the keep-with-next and
  `break-inside` rules because nothing breaks. Verified to 40,958 pt (64 Letter
  pages) with no CoreGraphics or PDFKit complaint and no clipping.
- **Export is always paginated.** A 40-inch page is a way to read on screen,
  not a file to hand someone or print, so `exportAsPDF` typesets a second,
  paginated render under its own renderer key (`<key>.export`, so the
  document's own render is not superseded) and applies the same outline.
- **Images are inlined as data URIs, everything else is blocked.** The page is
  loaded from a string, so relative image paths would not resolve anyway; the
  rewriter base64s local images under the document's own folder (8 MB cap) and
  the CSP (`default-src 'none'; img-src data:; style-src 'unsafe-inline'`) makes
  sure a render can never touch the network or run script.
- **Auto-refresh is a vnode watcher, not `NSFilePresenter`.**
  `presentedItemDidChange` only fires for writers that go through
  `NSFileCoordinator`, which editors and AI CLIs are not. The watcher also
  watches the parent directory, because an atomic "write a temp file and rename
  it into place" save leaves the original vnode untouched and shows up only as a
  directory write. `presentedItemDidChange` is still overridden, but only to
  poke the same debounce.
- **The first Markdown render is "reload #0".** Typesetting takes ~0.3-0.7 s, so
  `read(from:)` only decodes and converts; the window opens with an empty
  PDFView (the gutter is already inverted to near-black in dark mode, so there
  is no white flash) and fills through exactly the same `installDocument` path a
  file-change reload uses. Blocking `read` on a semaphore or a nested run loop
  was rejected: deadlock risk for no visible gain.
- **The Markdown outline is synthesised from link annotations.** WebKit's print
  path emits no PDF outline, but it does emit a link annotation for every
  `<a href>`, so `MarkdownHTML`'s `HeadingAnchorer` rewriter wraps each
  heading's content in `<a class="fh" href="glassine-outline://<n>">` and records
  `(level, plainText, n)` in the same pass, which is what keeps the numbering
  and the list from drifting apart. After the render, `GlassineDocument.applyOutline`
  walks every page's annotations, keys them by the integer in the URL, keeps the
  topmost hit per heading (a heading that wraps yields one annotation per line),
  removes them all, and builds the `PDFOutline` tree with a level stack. An
  annotation's URL names *one* heading exactly, which a fragment link
  (`#some-heading`) could not: two headings that slugify the same are
  indistinguishable, and the outline has to tell them apart. (This note used to
  add that WebKit emits no annotations for same-page fragments. **That is
  wrong** — measured 2026-09-07, it emits a link annotation carrying a real
  `PDFActionGoTo`, which is exactly what footnote markers and heading links now
  ride on; see the 2026-09-07 entries in State. The outline keeps its own
  scheme for the naming reason above.) `a.fh { color: inherit }`
  comes after the `a { color: #0B57D0 }` rule so the anchor is invisible.
- **Export re-serialises Markdown.** `pdfDataForExport` hands back
  `pdf.dataRepresentation()` rather than the raw print bytes, because those
  still carry the `glassine-outline://` links and none of the bookmarks; the
  re-serialised file keeps the outline and drops the annotations. A `.pdf`
  document is still exported byte-identical from the original file.
- **swift-markdown is pinned by `revision:`.** Its manifest depends on
  swift-cmark by *branch*, and SwiftPM refuses a version range on top of that.
  `Package.resolved` records both.
- **Hit counter** is a separate toolbar item after the search field,
  centered, `visibilityPriority = .high`; search field 180pt so nothing
  overflows at the default width. The previous/next segmented control sits
  after it (also `.high`), disabled until a search has matches.
- **Two Sparkle feeds, because the bundle id changed.** `appcast.xml` stays
  frozen as Folio's final feed and `glassine-appcast.xml` is Glassine's; the
  reasoning is under "Two feeds, and why" below, and it is the one thing in this
  repo where duplicating a file is deliberate.
- **The Recents list is Glassine's own, not the system's.**
  `NSDocumentController.recentDocumentURLs` is ten items long, carries no dates,
  and is emptied outright when macOS is set to keep no recent items — on this
  Mac it is empty, which is exactly the case a launch window must not fall over
  on. `Prefs.recentDocuments` therefore keeps thirty entries with a date, the
  page count at the time of opening (so a row can say "p. 12 of 30" without
  reopening the file), and a security-scope-free **bookmark**, which is what
  still finds a file after a rename or a move; the entry's path is rewritten
  from the bookmark when the row is built, so a moved file reads as itself
  rather than "Not found". The seed runs once, from the system list *and* from
  the paths in `lastPositions` — the latter is Glassine's own record of what has
  been read, complete with timestamps, and on a Mac with recent items off it is
  the only source there is. Seeded entries deliberately get **no** bookmark:
  making one reads the file, and doing that for thirty files during launch draws
  a privacy prompt for every protected folder they sit in (observed: a Desktop
  prompt on the first run) before the reader has asked for anything. An entry
  earns its bookmark the first time it is really opened.
- **A start tab is replaced in place by the document window, not filled in.**
  Nothing loads a document *into* a start tab: the tab is a window, and the
  document gets a window of its own. What makes it read as "this tab became the
  document" is the order of two things that already existed.
  `ReaderWindowController.showWindow` adopts the frontmost visible reader-group
  window as its tab host and inserts itself `.above` it — and the frontmost
  reader-group window is the start tab the reader just picked in, so the
  document lands immediately to its right. The start tab then closes itself from
  `openDocument`'s completion handler, i.e. only once the document window is on
  screen, so the group never momentarily collapses and the surviving tabs never
  shuffle. Net effect: same position, other tabs untouched. A document that is
  already open needs no special case — `openDocument` selects its existing tab
  and calls back the same way, and the start tab closes behind it. A failed open
  returns early and leaves the start tab exactly as it was. The one thing this
  costs is "Open Other…": `NSDocumentController.openDocument(_:)` runs the panel
  and opens the file with no callback at all, so a start tab uses
  `beginOpenPanel(completionHandler:)` and opens the result itself.
- **A start tab is a reader-group window on purpose.** Same `tabbingIdentifier`,
  so `ReaderWindowController.anyWindowIsOpen`, the app delegate's
  `isReaderWindow` check and the launch-window timing all count it without
  knowing it exists: the launch Recents window does not appear behind a start
  tab, and closing the last start tab brings it back like closing the last
  document. It carries a toolbar with nothing in it but a flexible space purely
  so the title bar keeps the reader's height — an untoolbared window in the same
  tab group is a shorter title bar and a jump when switching tabs — and its
  toolbar identifier is per-window for the reason below.
- **The launch check is deferred, not immediate.** A file double-clicked in the
  Finder arrives as its own Apple Event that can be delivered either side of
  `applicationDidFinishLaunching`, and macOS window restoration reopens the last
  session's documents later still. So `applicationShouldOpenUntitledFile` is
  false and the decision is taken 0.2 s into the first runloop, by which time
  whatever was going to open has a window: `ReaderWindowController.anyWindowIsOpen`
  answers it, and the Recents window is never ordered in only to be hidden
  again. The same trick, one runloop turn, covers the close side — the closing
  window is still on screen inside `willCloseNotification`, and closing one tab
  of a multi-tab window closes a window too.
- **The Folio settings are copied, not moved.** A new bundle id means a new
  defaults domain and a new Application Support folder, so `FolioMigration` in
  `AppDelegate.swift` runs once in `applicationWillFinishLaunching` — before
  anything reads a preference, and so before a window can restore a frame — and
  copies a named list of keys (`invertInDarkMode`, `appearance`,
  `lastPositions`, the four Markdown keys, `sidebarMode`, `windowOpacity`,
  `windowBlur`, `NSWindow Frame ReaderWindow`) out of `com.epps.Folio`, plus the
  `Styles` folder if Glassine has none yet, then sets `migratedFromFolio`. The
  list is explicit rather than a whole-domain copy so that Sparkle's `SU*` keys
  stay behind: they record an update history against a feed Glassine does not
  read. Nothing is deleted from the Folio side, so an installed Folio keeps
  working and the migration is safe to re-run against a wiped Glassine domain.

## iOS (in progress, branch `ios`)

Dan decided on 2026-09-05 to bring Glassine to iPad and iPhone: iPad first with
iPhone supported, TestFlight now and the App Store later, PDF **and** Markdown in
the first version, one repo with the portable logic in a shared package. The
plan with phases and exit criteria is
`~/.claude/plans/write-up-a-plan-sorted-lemur.md`; all five phases — scaffold
and spikes, `Core/`, the PDF reader, Markdown, polish and `release-ios.sh` —
landed on 2026-09-05/06 (see "State"). What remains is Dan's: the App Store
Connect steps under "Releasing to TestFlight (iOS)", the first upload, and the
merge of `ios` into `main`. Still
needed from Dan before Phase 5: an App Store Connect record for the iOS
`com.epps.Glassine`, an App Store Connect API key, and an iPad paired once with
`devicectl` — **the iPad is now paired and was used**: on 2026-09-06 the app
built, signed, installed and ran on Dan's iPad Pro 11-inch, and only the
XCUITest suite is still blocked there, on the device's own **Settings ▸
Developer ▸ Enable UI Automation** toggle (see "State").

Layout: `Core/` is a SwiftPM package `GlassineCore` (macOS 14 / iOS 18,
swift-markdown only — kept out of the root manifest so Sparkle, a macOS-only
binary, never enters an iOS build graph) that the Mac executable and the iOS app
both depend on; `iOS/project.yml` is an XcodeGen spec (the generated
`iOS/Glassine.xcodeproj` and `iOS/DerivedData` are gitignored) for one iOS 18 app
target, bundle id `com.epps.Glassine`, Swift 6 with strict concurrency
`complete`; the iOS app is a SwiftUI shell around UIKit/PDFKit views (a
necessity, not a taste — see Spike A).

```sh
./build-ios.sh                                  # xcodegen + xcodebuild for the iPad Pro 13-inch (M5) simulator
./build-ios.sh --run --screenshot /abs/shot.png # install, launch, screenshot after 2 s
./build-ios.sh --sim "iPhone 17 Pro" --dark --run -- -open memo.pdf   # DEBUG: open a file from the app's Documents
./build-ios.sh --test                           # the GlassineUITests XCUITest suite on the chosen simulator
./build-ios.sh --device                         # generic iOS device (builds and installs; launch needs the phone unlocked)
```

Unknown flags exit 2. Everything after `--` reaches the app as launch arguments.
Test files go into the app's Documents (`xcrun simctl get_app_container <udid>
com.epps.Glassine data`), and **that container moves on every `simctl install`**
— re-resolve the path after each build; the DEBUG `-open` hook takes a bare file
name and resolves it against `Documents/` itself for that reason.

**Architecture (iOS/Sources)** — SwiftUI shell, UIKit/PDFKit where PDFKit needs
it; it consumes `GlassineCore` and nothing under `Sources/Glassine`.

| File | Role |
|---|---|
| `GlassineApp.swift` | `@main App`, one `WindowGroup`. `AppLaunch.configure()` creates `Documents/Styles` and points `Prefs.stylesDirectory` at it (so it shows in Files), installs the iOS find ink into `ReaderPage.matchInk`, and installs `AppearanceBridge` as `Prefs.applyAppearanceOverride` — `overrideUserInterfaceStyle` on every connected scene's windows, which is the iOS `NSApp.appearance`. |
| `ReaderTheme.swift` | Every number about the inversion: the Dark Paper `contrast`/`brightness` conversion, the 0.94 pre-filter gutter, the re-derived find ink with the arithmetic behind it, the chrome colour, and `PageInversion` — the modifier the reader and the thumbnail strip share, written without a conditional so switching appearance cannot rebuild the `PDFView`. Also `MainBox`, the weak `@unchecked Sendable` box that gets a `@MainActor` object across the `@Sendable` closures NotificationCenter, KVO and GCD insist on. |
| `PrefsModel.swift` | `@Observable` mirror of the four preferences the reader reacts to, refreshed from `.glassinePrefsChanged`. Writes go through `Prefs`, never to the mirror. |
| `DocumentSession.swift` | One document for one scene: URL + security scope held for the session, the coordinated read, the iCloud download wait, the `PDFDocument`, `FindController` (this class is its delegate), `ReadingPosition` plus the iOS-specific position *save*, the outline entries and current selection, the page readout, the go-to-page dialog's state, and a `kind` with `.markdown` reserved. `PDFDocumentBridge` is the `PDFDocumentDelegate`: `ReaderPage.self` for pages, PDFKit's find callbacks hopped to the main actor. |
| `RootView.swift` | The scene. `NavigationSplitView` on iPad with a Recents/Thumbnails/Contents picker over the pane; a `NavigationStack` with the panes as a detented sheet on iPhone. Opening (`onOpenURL`, `onContinueUserActivity`, the document picker, the DEBUG `-open` argument), closing, and "Open in New Window" through `requestSceneSessionActivation`. |
| `RecentsList.swift` | `RecentsModel.rows()` as a `List` with `.searchable`, a context menu, swipe-to-remove trailing, a leading swipe to New Window (iPad only, and never on a missing row), a drop destination, and a dimmed "Not found" row that opens nothing. Plus `DocumentPicker`, the `asCopy: false` document-picker wrapper behind "Open Other…". |
| `ReaderView.swift` | The chrome: title (with Phase 3's subtitle slot), the page capsule and its Go to Page alert, the search button, the ellipsis menu (panes on iPhone, New Window above Print wherever `supportsMultipleScenes` is true, Print, Share, Settings, Close), and the bottom find bar with its counter and chevrons. Only the page goes inside `pageInversion`. |
| `ReaderPDFView.swift` | `PDFView` subclass hosting `FindHighlighter`, exposing PDFKit's inner `UIScrollView`, and carrying the key commands (←/↑/→/↓, ⌘↑/⌘↓, ⌘F, ⌘G, ⇧⌘G, ⌥⌘G, Escape, ⌘+/⌘−/⌘0). Plus the representable that configures it and sets the pre-filter background. |
| `ThumbnailsPane.swift` | `PDFThumbnailView` bound to the reader's `PDFView`, under the same inversion chain so thumbnails match the pages. |
| `ContentsPane.swift` | `List` over `OutlineSync.entries(of:in:)`, indented by depth, the entry the reader is inside highlighted and scrolled to. Native text, deliberately unfiltered. |
| `SettingsView.swift` | Sheet: Appearance, Invert Page Colors, Dark Paper (disabled when invert is off), and the Markdown section Phase 3 fills. |
| `MarkdownRendererIOS.swift` | The iOS `HTMLPrinter`, and the outline step around it. `UIKitHTMLPrinter` holds one hidden `WKWebView` in the key window (alpha 0, behind everything, `allowsContentJavaScript = false`, `shouldPrintBackgrounds = true`, `suppressesIncrementalRendering`), measures `scrollHeight` and every `a.fh` anchor in `.defaultClient`, and presses the page one of three ways: `UIPrintPageRenderer` + `viewPrintFormatter()` with `paperRect`/`printableRect` set by KVC for Pages, `createPDF` for a continuous document that fits CoreGraphics' 14,400 pt page, and `UIPrintPageRenderer` again on 612 × 14,400 paper with zero margins past it (last page's crop box trimmed). Every `WKNavigation` identity check, the process-terminate restart, `teardown()` and `reprint()` are the Mac's. `MarkdownRendererIOS.shared` hands it to `GlassineCore.RenderQueue` and, unlike the Mac's, applies the outline itself, because only the `createPDF` route leaves link annotations to read. |
| `ExportPicker.swift` | `ExportFile` (an `Identifiable` URL, because `.sheet(item:)` is what presents it) and `ExportPicker`, the `UIDocumentPickerViewController(forExporting:)` wrapper behind Export as PDF. |
| `UITests/GlassineUITests.swift` | XCUITest over everything that needs a finger — 18 tests, PDF and Markdown, with `launchMarkdown` pinning layout and clearing the saved position through NSArgumentDomain. Pinned to Swift 5 language mode: `expectation(for:evaluatedWith:)` sends the non-Sendable `XCTestCase` and cannot compile in Swift 6. |

iOS gotchas (2026-09-06), each proved by an observation in the Phase 2 report:
a conditional inside a `ViewModifier` gives the wrapped representable a new
identity and rebuilds the `PDFView` (switching to dark mid-session moved page 1
to page 2), so `PageInversion` always applies all four modifiers with identity
values and uses `.contrast(-1)` as the complement; `CGColor(red:green:blue:alpha:)`
is not sRGB (an asked-for 98/255 green landed as 114/255), so `ReaderTheme`
names `CGColorSpace.sRGB`; PDFKit ignores navigation until it has laid out, and
a restore with nothing to restore completes synchronously inside `makeUIView`;
only one `.alert` per view presents; SwiftUI drops `accessibilityIdentifier` on
an alert's text field and buttons (the test commits with Return); the
`PDFThumbnailView` never surfaces as an `XCUIElement` (its SwiftUI container
does); opening a document collapses the iPad sidebar; `PDFView.enableDataDetectors`
is deprecated on iOS 18 in favour of a `PDFDocument` property the SDK lacks, so
it is set through KVC; Swift 6 forbids capturing a `@MainActor` object in
NotificationCenter/KVO/GCD closures (`MainBox` + `assumeIsolated`) and
invalidating a `Timer` from a main-actor `deinit` (the iCloud wait is a
self-rescheduling `asyncAfter`); and `xcodebuild` refuses an existing
`-resultBundlePath`, so `--test` removes it first. From Phase 3: `xcrun simctl
spawn <udid> defaults write com.epps.Glassine …` does not reliably reach the
app (cfprefsd keeps the app's cached values and overwrites the file — a
`darkPaper 0` write was ignored), so pin preferences for a test or a screenshot
through launch arguments, which land in NSArgumentDomain and shadow everything
(`-darkPaper 0 -markdownLayout 1 -markdownStyle manuscript -lastPositions '{}'`);
a `.md` reopened at a saved position is not on page 1, which is why the tests
clear `lastPositions`; `sips --cropOffset` does not crop where it says (a
CGImage `cropping(to:)` helper does); the iPhone's panes sheet covers the
toolbar, so a test dismisses it before reaching the ellipsis menu;
`ScrollViewReader.scrollTo` in `onChange` alone leaves the iPhone's Contents
sheet at the top (it needs `onAppear` too); the export picker has a Save button
and, on iPhone, no Cancel at all; and `devicectl` has no screenshot subcommand,
but `device copy to`/`copy from --domain-type appDataContainer` reach the app's
Documents folder and are the better instrument.
Simulator builds pass `CODE_SIGNING_ALLOWED=NO`; `xcbeautify` is not installed
here, so the output goes through a grep. `xcrun simctl io <udid> screenshot`
writes an sRGB 8-bit PNG at native scale (2064 × 2752 on the 13-inch iPad), so
pixel measurements compare directly with the Mac's. Two scaffold gotchas:
**XcodeGen's `info:` key *writes* the plist it names** (it reduced the
hand-written `iOS/Support/Info.plist` to a stub), so the spec has no `info:` key
and uses `INFOPLIST_FILE` + `GENERATE_INFOPLIST_FILE: NO`; and the Mac's Icon
Composer package works on iOS straight from XcodeGen — `iOS/Support/Glassine.icon`
listed as a resource with `ASSETCATALOG_COMPILER_APPICON_NAME = Glassine` compiles
to `Assets.car` with `CFBundleIconName` set — once `icon.json`'s
`supported-platforms.squares` says `["iOS", "macOS"]` rather than `["macOS"]`.

**Spike A (2026-09-05): the dark-mode inversion does not port as written, and
the replacement is a SwiftUI modifier chain.** `pdfView.layer.filters =
[CIColorInvert, CIHueAdjust(π)]` is accepted on iOS, reads back, and does
*nothing* — measured on the iPad Pro 13-inch simulator: paper 255, ink 0, blue
`#0B57D0` unchanged, no warning. The route that works is
`.colorInvert().hueRotation(.degrees(180))` on the `UIViewRepresentable`, gated
on `colorScheme == .dark`, with Dark Paper as `.contrast(c).brightness(b)`.
Measured against a purpose-built probe PDF: paper 255→0, ink →255, the blue link
`11,87,208` → `107,183,255` (still blue), red/green/blue squares each keeping
their hue, a brown→sky-blue gradient flipping luminance without becoming its
complement. The two blend-mode routes — a white overlay `CALayer` with
`compositingFilter = "differenceBlendMode"`, and a `.difference` white fill in a
`PDFPage` subclass — measured byte-identical to each other and destroy hue (the
link comes out orange `244,168,47`); neither can take a hue stage, so they are
out. **Dark Paper needs no linear-light conversion on iOS**: SwiftUI's contrast
and brightness work on the same sRGB screen values `DarkPaper.lift`/`.top`
store, so `c = top − lift` and `b = lift − 0.5(1 − c)` — Charcoal 0.82/0.02,
Gray 0.73/0.035 — measured paper 28 and 43, ink 237 and 230, first try, the
Mac's numbers exactly. Also verified under the filter: `.PDFViewPageChanged` and
`.PDFViewScaleChanged` fire; `scaleFactor = 2.0` renders crisp (composite-time
pass, PDFKit still rasterises at the new scale); twelve `go(to:)` jumps through
a 60-page document, recorded and cut into 227 frames, showed **no white
placeholder tile** (peak all-white coverage 0.551 %, constant, the probe's own
black swatch) where the `PDFPage.draw` route peaked at 64.4 % — a whole
un-inverted page mid-jump, the Mac's original flash; host CPU during a 5 s
programmatic sweep was 278.8 % filtered against 273.6 % unfiltered, 0.3–0.5 % at
rest. **Two consequences for Phase 2.** The iOS filters run in *sRGB*, not
linear light (the grey ramp came back as the exact complement, 36→219), so every
pre-filter colour the Mac calibrated must be re-derived rather than copied: the
0.997 gutter separates by 24 levels on the Mac and by **one** on iOS (1/0 Black,
29/28 Charcoal, 44/43 Gray) and wants a pre-filter grey near 0.94 (15/0, 40/28,
54/43); the green find ink and the stylesheet's near-white panels are in the
same boat. And `.colorInvert()` has no UIKit equivalent, so the reader must be
SwiftUI-hosted for the filter to exist. Not verified: anything touch-driven
(`simctl` cannot tap, drag or pinch), device builds, GPU cost on hardware, text
selection and find highlights under the filter, the icon on a Home Screen. The
spike is `iOS/Sources/Spike/SpikeInvertView.swift` plus `iOS/SpikeAssets/`,
reached with `-spike invert -route 1|2|3|4 -paper black|charcoal|gray`, and is
deleted in Phase 2.

**Spike B (2026-09-05): iOS typesets Markdown through two different WebKit
primitives, one per layout.** `NSPrintOperation` does not exist there, so both
candidates ran on the iPad Pro 11-inch simulator against the same HTML
`MarkdownHTML.page` emits on the Mac (the spike lives in the session scratchpad,
`spikeB/`, and nothing of it is in the repo). **Pages** is `UIPrintPageRenderer`
+ `WKWebView.viewPrintFormatter()`, with `paperRect` (612×792) and
`printableRect` (inset 72) set by KVC because they have no setters,
`perPageContentInsets = .zero`, drawn into `UIGraphicsBeginPDFContextToData`:
exact 612×792 pages, selectable text, New York and SF Mono embedded and subset,
`#FAFAFA`/`#F5F5F5` panels printed (`preferences.shouldPrintBackgrounds` exists
on iOS and is required), the keep-with-next hack intact (a 15-heading stress
fixture stranded nothing), and **no annotations at all** — the Mac's
outline-from-link-annotations trick is dead on this path. **WebKit's 1.25
minimum shrink applies on iOS too, but against the printable width:** content
lays out at 468 × 1.25 = 585 CSS px and prints at 0.8 pt per px (CSS `11pt`
body measures 11.73 pt in the output); the web view's frame does not change the
print (468 → 585 changed no page count), only what JavaScript measures, so lay
the measuring view out at 585. **Continuous** is `createPDF(configuration:)` at
1:1 — no shrink, so the measurement must *not* be divided by 1.25 — on a web
view sized `612 × ceil(scrollHeight)`; it keeps every `glassine-outline://` link
annotation, so `applyOutline` works unchanged there, **but CoreGraphics caps a
page at 14,400 pt and `createPDF` silently tiles past it**: a 48,866 pt document
came back as three 14,400 pt pages plus a 5,666 pt remainder, the seams cutting
lines of text in half and duplicating ~90 characters across each. So Continuous
on iOS uses `createPDF` up to 14,400 pt and beyond that falls back to
`UIPrintPageRenderer` with 612 × 14,400 paper and zero margins (real page breaks,
no sliced lines, annotation-free like Pages). Outline-by-measurement for the
annotation-free paths works but drifts: `evaluateJavaScript(…, in:
.defaultClient)` runs with content JavaScript off and the `default-src 'none'`
CSP, and `a.fh` rects × 0.8 place the first headings exactly and then run
monotonically ahead as page-break slack accumulates (−108 pt by page 8 of a
memo; a 50-page document needs a best-fit slope of 0.81–0.88 to stay within
~100 pt). The intended shape is therefore **measure, then snap**: the
measurement gives order and a starting page, `PDFDocument.findString(title)`
resolves each heading exactly (19/19 and 114/120 located; choose the hit nearest
the prediction among duplicates), the prediction alone is the fallback, and two
rules apply — discard hits outside the 72…720 pt printable band, because **the
print path leaves a clipped ghost copy of every carried-over heading in the
bottom margin of the page it left** (invisible in the render, present in
`page.string` and in `findString`; 69 duplicated characters at one seam — a
find on iOS must filter these too), and clamp a negative measured `top` to 0
(the first `h1` measures −1.0 px). Warm simulator renders: 315 / 368 / 547 ms
for 4 / 8 / 48 pages paginated, 304 / 349 / 426 ms continuous; a cold WebContent
process doubles the first one. Not verified on hardware: the build signed and
installed on the iPhone 16 Pro with `CODE_SIGN_IDENTITY="Apple Development"
DEVELOPMENT_TEAM=82H77TF7AH -allowProvisioningUpdates`, but the launch was
refused with `FBSOpenApplicationErrorDomain error 7 … Locked` (the phone was
locked; `devicectl … process launch` also needs a `--` before the app's own
arguments). Also unverified: images through the print formatter, memory on very
long documents, the four other built-in styles and custom CSS, the near-white
panels after the sRGB inversion, and whether the Mac's `NSPrintOperation` path
leaves the same ghost text.

## Signing, notarization, updates

Glassine ships signed, notarized, and self-updating via **Sparkle 2** (SwiftPM
dependency, currently 2.9.6).

- `./build.sh` signs with **Developer ID Application: Daniel Epps
  (82H77TF7AH)**, hardened runtime, secure timestamp, and ends with
  `codesign --verify --deep --strict`.
- `./build.sh --adhoc` signs ad-hoc instead: no certificate, no network. This
  is the flag for day-to-day work; everything below is only needed to ship.
- `./build.sh --notarize` additionally zips, submits with `xcrun notarytool
  --keychain-profile notary --wait`, staples, and runs `spctl`. Takes a few
  minutes. Without it `spctl` reports "Unnotarized Developer ID", which is
  expected on a plain build.

**Three secrets, held only in the login keychains of both Macs** (the Studio
throughout; the M2 MacBook Pro since 2026-09-05, when the EdDSA key was
imported — see "Signing on both Macs"): the
Developer ID Application certificate + private key, the `notary` notarytool
credential profile, and the Sparkle **EdDSA private key** (account `ed25519`,
created by Sparkle's `generate_keys`). The matching public key is checked into
`Support/Info.plist` as `SUPublicEDKey`
(`xkEJ4pttphM6v/lHQQ4mbSe9JHQZFe1eOefG26iqyWU=`) and must never be
regenerated — doing so orphans every already-installed copy. The rename did not
touch it: Glassine signs with the same key Folio did.

**Feed URL:** `https://raw.githubusercontent.com/danepps/glassine/main/glassine-appcast.xml`
(`SUFeedURL`). `glassine-appcast.xml` lives at the repo root and is generated,
not hand-written — its entries carry EdDSA signatures that any manual edit
breaks. It sits beside `appcast.xml`, which is Folio's frozen feed and is not
Glassine's; see "Two feeds" below.
**The GitHub repo must be public**: the feed points at release *assets*
(`https://github.com/danepps/glassine/releases/download/v<version>/…`), and
GitHub release assets on a private repo need an auth token Sparkle won't send.

**`./release.sh <version> [notes]`** does the whole release: refuses to run off
`main` or with a dirty tree, sets `CFBundleShortVersionString` and bumps
`CFBundleVersion` (an integer, monotonic — it's what Sparkle actually compares),
runs `build.sh --notarize`, writes `build/releases/Glassine-<version>.zip`, stages
that zip beside a copy of the live `glassine-appcast.xml` and runs Sparkle's
`generate_appcast -o` over the staging directory so new entries merge into the
old ones, copies the feed back, then commits, tags `v<version>`, pushes the tag,
runs `gh release create` (so the asset exists), and only then pushes `main`
(which is what makes the feed live). Preflight refuses a dirty tree, a
`main` that differs from `origin/main`, an existing tag, a version not newer
than the current one, or missing `gh`/certificate/notary credentials. If it
fails after the tag push, the recovery commands are in a comment above the
publish step (delete the tag locally and remotely, delete the GitHub release
if it exists, `reset --hard origin/main`, rerun). Don't hand-run the pieces;
the appcast signature and the download URL prefix have to agree with the tag.
The `-o` flag is what keeps it writing `glassine-appcast.xml` rather than
`generate_appcast`'s default `appcast.xml`, which would clobber Folio's feed.

### Two feeds, and why

`appcast.xml` is **Folio's, frozen at 1.1.0**. Every installed Folio polls
`raw.githubusercontent.com/danepps/pdfreader/main/appcast.xml`, which GitHub
still redirects into this repo after the repo rename, so that file has to keep
existing and keep saying 1.1.0. Glassine has a different bundle identifier, and
Sparkle would happily install a "1.2.0" over a Folio that is a different app
with a different preferences domain — the update would look like an upgrade and
would silently be a swap. So Glassine gets its own file,
`glassine-appcast.xml`, and the two never merge. Neither is signed differently:
the EdDSA key is shared, so a stale Folio would accept a Glassine build if it
were ever offered one. It must not be. Practical consequence: the copies of
Folio already in `/Applications` are replaced by hand, once, and never update
again. Do not add an entry to `appcast.xml` and do not point `release.sh` at it.

### Signing on both Macs

Status 2026-09-04: the MacBook (repo at `~/ClaudeCode/pdf`) has the Developer
ID certificate and the `notary` profile and notarizes fine, but **not** the
Sparkle EdDSA key, so `release.sh` stops in preflight there. A release attempt
that day ran all the way through notarization before `generate_appcast` found
the key missing; preflight now checks for it first. To finish the setup, do
step 5 below the next time both machines are at hand. The key cannot be
regenerated (see above), and iCloud Keychain does not sync it — it is a plain
login-keychain item — so it has to be exported and imported by hand, once.
Steps 1–4 are kept for setting up any further machine.

1. `git pull`; Xcode 26 / Swift 6.3 installed; `gh auth status` shows you
   logged in. **`./build.sh --adhoc` needs none of steps 2–5** — that's the
   normal development path and it works out of the box.
2. **Developer ID certificate.** On *this* Mac: Keychain Access → My
   Certificates → "Developer ID Application: Daniel Epps (82H77TF7AH)" →
   right-click → Export as `.p12` with a password. AirDrop it; don't email it.
   On the MacBook double-click the `.p12` to import into the login keychain,
   then confirm: `security find-identity -v -p codesigning` must list exactly
   that identity as valid.
3. **If step 2 reports "0 valid identities"**, Apple's current intermediates
   are missing (this Mac was missing them too until Xcode installed them).
   Download and double-click
   <https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer> and
   <https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer>, then
   re-run the `find-identity` check.
4. **Notarization profile.** Create an app-specific password at
   account.apple.com → Sign-In and Security, then:
   `xcrun notarytool store-credentials notary --apple-id dsepps@gmail.com --team-id 82H77TF7AH --password <app-specific password>`.
   Pass `--password` inline: the interactive prompt does not work from the
   Claude Code `!` shell. Afterwards scrub it from history with
   `LC_ALL=C sed -i '' '/notarytool store-credentials/d' ~/.zsh_history`.
   Verify: `xcrun notarytool history --keychain-profile notary`.
5. **Sparkle EdDSA key.** The artifact path only exists after a first
   `./build.sh` has resolved the package. On this Mac:
   `~/ClaudeCode/pdfreader/.build/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/glassine_eddsa_key`.
   Transfer privately, then on the MacBook:
   `~/ClaudeCode/pdf/.build/artifacts/sparkle/Sparkle/bin/generate_keys -f ~/glassine_eddsa_key`
   and delete the file on both machines. Do **not** run bare `generate_keys`
   there — it would mint a second key that no shipped app trusts.
6. **End to end:** `./build.sh --notarize` should finish with `accepted` and
   `source=Notarized Developer ID`.

## Releasing to TestFlight (iOS)

The iOS app ships through **TestFlight**, not Sparkle and not the App Store.
There is no appcast on this side: App Store Connect is the feed, and
`release-ios.sh` touches neither `glassine-appcast.xml` nor `appcast.xml`.

**Two secrets and one profile, none in the repo.** The **App Store Connect
API key** `~/.private_keys/AuthKey_9D6LK6456Y.p8` (Key ID `9D6LK6456Y`, Issuer
ID `69a6de82-678e-47e3-e053-5b8c7c11a4d1`) — `~/.private_keys/` is where
`xcodebuild` looks for it, and it must be copied between Macs privately, by
hand, exactly like the Sparkle EdDSA key (Apple offers the download once). The
**Apple Distribution certificate** in the login keychain, which comes with
being signed into the Apple ID in Xcode ▸ Settings ▸ Accounts. And the **App
Store provisioning profile "Glassine iOS App Store"** in
`~/Library/Developer/Xcode/UserData/Provisioning Profiles/` (not a secret —
re-downloadable from developer.apple.com ▸ Profiles — but it has to be there).
Never commit the `.p8`, never paste it, never email it.

**The export signs manually, and this is not a preference.** Automatic export
signing insists on Apple's *cloud-managed* distribution certificates, and this
account has no access to them: `xcodebuild -exportArchive` with
`signingStyle automatic` returned `403 FORBIDDEN_ERROR … "You haven't been
given access to cloud-managed distribution certificates"` and `No profiles for
'com.epps.Glassine' were found`, on 2026-09-06 *with* a valid Apple Distribution
certificate sitting in the keychain — the local certificate is simply never
consulted on that path. So both `iOS/ExportOptions.plist` and
`iOS/ExportOptions-local.plist` say `signingStyle manual`,
`signingCertificate Apple Distribution`, and map `com.epps.Glassine` to the
profile by name. The profile was created through the App Store Connect API
(`POST /v1/profiles`, type `IOS_APP_STORE`, against the bundle id record
`NZ66J6WZ9H` and the distribution certificate whose serial matches the local
one, `VC9K4W38AZ`; there are two distribution certificates in the portal and
only one has a private key here) and its `profileContent` written straight into
Xcode's profiles folder — the portal's Profiles page would have done the same
by hand. The archive step still uses automatic signing (Apple Development, via
`-allowProvisioningUpdates`); the export re-signs. The App Store Connect side
is done: app record **"Glassine Reader"** (app id `6809165710`, SKU
`glassine-ios`), TestFlight internal group **"Internal"** with access to all
builds and Dan as its tester — so an uploaded build is installable from the
TestFlight app as soon as processing finishes, with no review of any kind. Dan's
decision (2026-09-06): TestFlight only, **no App Store review submission** yet;
nothing in the script submits one.

**`./release-ios.sh <version> [--check] [--no-upload]`** does the release:
twelve preflights (on `main`, clean tree, in sync with `origin/main`, version
newer than `MARKETING_VERSION`, tag `ios-v<version>` free locally and remotely,
`xcodegen`, `xcodebuild`, an Apple identity, an **Apple Distribution**
certificate, the **App Store profile** installed, the API key, `gh`), then it
sets `MARKETING_VERSION` and bumps
`CURRENT_PROJECT_VERSION` in `iOS/project.yml` — the source of truth; the plist
they end up in is generated — runs `xcodegen generate`, `xcodebuild archive`
into `build/ios/Glassine-<version>.xcarchive` and `xcodebuild -exportArchive`
with `iOS/ExportOptions.plist`, which uploads. Then it commits the bump, tags
`ios-v<version>` (deliberately not the Mac's `v<version>`), pushes the tag,
`gh release create`s it, and pushes `main`.

**`--check` stops after the preflight and reports every check.** It never
builds, tags or uploads. It exists because of 9.9.9: there is no such thing as
a dry run with a real-looking version. **`--no-upload`** archives and exports a
local `.ipa` into `build/ios/` with `iOS/ExportOptions-local.plist` — the same
signing, `destination export` instead of `upload` — skips the git checks so it
can run on a working branch, and restores `iOS/project.yml` on the way out.

**Recovery.** The upload happens *before* the tag, deliberately, so a failure in
the publish steps never leaves a tag pointing at nothing. If it fails after the
tag push: `git tag -d ios-v<version>`, `git push origin
:refs/tags/ios-v<version>`, `gh release delete ios-v<version> --yes` if it got
created, `git reset --hard origin/main` — then rerun with the **next** version,
not the same one. The build number is spent either way and App Store Connect
will not take it twice; the uploaded build stays in TestFlight, so expire it
there if it should not go out.

**Setting up a second Mac.** `git pull`; Xcode 26 and `brew install xcodegen`;
signed into the Apple ID in Xcode ▸ Settings ▸ Accounts (which is what puts the
Apple Distribution certificate in the login keychain — check with `security
find-identity -v -p codesigning` — and if the Apple Distribution certificate is
missing there, it has to be *exported from this Mac's keychain with its private
key* and imported, because the portal's copy is public-key only); `gh auth
status` green; the `.p8` copied to `~/.private_keys/` privately, by hand; and
the "Glassine iOS App Store" profile downloaded from developer.apple.com ▸
Profiles into `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`.
`./build-ios.sh` needs none of it. `./release-ios.sh <version> --check` is the
one-command way to find out whether a machine is ready.

**The rehearsal export passed on 2026-09-06 afternoon**, after the switch to
manual signing: `Glassine.ipa` (6.9 MB) whose app `codesign -dv` reports
`Apple Distribution: Daniel Epps (82H77TF7AH)`, embedded profile "Glassine iOS
App Store", `get-task-allow` false, `beta-reports-active` true, no
`ProvisionedDevices`, `ITSAppUsesNonExemptEncryption` false. (It carried
0.1.0 build 1 because the archive and export were run as the script's two
`xcodebuild` steps by hand, without the version bump; the auto-mode classifier
had refused to run `release-ios.sh --no-upload` itself, while `--check` runs
fine.) `--check` then reported every check ok except "on main" and "clean
tree". The first real upload is `./release-ios.sh 1.0.0` from a clean `main`.

## Website and domains

The product page is https://www.danepps.com/glassine, part of Dan's Next.js
site (private repo `danepps/website`, cloned at `~/ClaudeCode/website`,
Vercel project `website`; pushing `main` deploys production, pushing a branch
makes a preview). The page lives in `app/glassine/`; its Download button is
`https://github.com/danepps/glassine/releases/latest/download/Glassine.zip`,
which works because `release.sh` uploads an unversioned `Glassine.zip` next to
the versioned one on every release — keep that in place. `glassineapp.com`
(DNS at Squarespace, A @ 76.76.21.21 / CNAME www → cname.vercel-dns.com) is
attached to the same Vercel project and redirected to the page by a host rule
in the site's `next.config.ts`; the canonical URL stays on danepps.com.

## Gotchas learned the hard way

- **`release.sh <fake version>` is not a dry run.** With all three secrets
  present it publishes: on 2026-09-05 a "preflight test" with 9.9.9 produced a
  real tag, GitHub release, appcast entry and release commit, which then had
  to be deleted, reverted and pushed within minutes (no installed copy had
  checked the feed in between). Use `./release.sh --check`, which stops after
  preflight and exits 0, for that purpose; it exists because of this.
- **Toolbars that share an identifier are one toolbar.** AppKit synchronises
  every `NSToolbar` created with the same identifier: `removeItem(at:)` on one
  window removed the page indicator from every reader window, and every window
  opened afterwards inherited the stripped set, so the page number "never came
  back" once a continuous Markdown document had hidden it. Each window now gets
  `GlassineReaderToolbar.<UUID>`; nothing autosaves the configuration, so the
  identifier is otherwise unused. Since 2026-09-05 nothing removes the item at
  all — a continuous document shows a percentage in the same capsule — so the
  per-window identifier is belt and braces. Keep it: any future item that comes
  and goes would hit exactly this again.
- **`contentViewController =` resizes the window to the view's fitting size**,
  the same trap `sizeWindowInitially` documents for the reader's split view. The
  Recents window moved from `contentView` to a content view *controller* when
  the picker was extracted, and had to restate `setContentSize` afterwards — and
  before `center()` and `setFrameAutosaveName`, or it would autosave the
  collapsed frame.
- **Anything opaque inside a window whose background is the reader's black shows
  up as a slab.** A start tab's window background is painted by
  `WindowChrome.apply` like a reader window's, and the picker sits straight on
  it, so its scroll view and table have to stop drawing their own
  `controlBackgroundColor` (`drawsListBackground: false`) or the list is a dark
  grey rectangle inside black chrome with black margins around it. The launch
  window is a plain window and keeps the default.
- **A locked screen breaks notarization, and only notarization.** `notarytool`
  keeps its `notary` profile in the data-protection keychain, which locks with
  the screen; the Developer ID identity and the Sparkle key live in the login
  keychain and stay readable. So a release driven remotely (Remote Control,
  SSH) on a Mac sitting at the lock screen fails preflight with "notarytool
  profile 'notary' missing or invalid" even though nothing is missing, and
  `store-credentials` fails the same way. Check
  `CGSSessionScreenIsLocked` in `ioreg -n Root -d1`/`python -c` before
  concluding the credential is gone; unlock via Screen Sharing and rerun.
  (2026-09-04, Mac Studio.) The same lock also blanks `screencapture`, which is
  why agent-driven UI verification stalls until someone unlocks.
- **A layer filter's numbers are linear light, and Core Animation ignores half
  of `CIColorMatrix`.** Two traps, both silent, hit while adding Dark Paper.
  Setting the lift on `inputAVector` (mathematically the premultiply-safe way to
  add a constant: bias × alpha) does *nothing* through
  `contentFilters` — CA honours `inputBiasVector` and the R/G/B vectors and
  drops the colour channels of the alpha vector. And the values land in linear
  light, like the 0.997 gutter: a bias of 0.11 came out as 93/255 on screen,
  not 28. `ReaderViewController.linearLight` converts, and the levels are
  written as the greys you want to see. There is no console warning for either;
  the page simply does not change. A 300×300 borderless window with a white and
  a black patch, `contentFilters` set, then `screencapture -l` and sample the
  two patches, settles this kind of question in a minute
  (`darkpaper-filtertest.swift` pattern).
- **Never add Swift stored properties to a `PDFPage` subclass.** PDFKit
  allocates pages through a private initializer that skips Swift ivar
  setup; the property reads as garbage on the tile thread and crashes
  (`EXC_BAD_ACCESS` in `draw`). `ReaderPage` keeps state in an ObjC
  associated object holding an immutable box.
- **The backdrop blur is addressed by `windowNumber`, not by the NSWindow.** A
  window that has never been ordered in has none, and a reader window joins its
  tab group inside `showWindow`, so `applyWindowAppearance` runs again there
  rather than only at init. The blur also has to be cleared explicitly (radius
  0) when opacity returns to 1: nothing about an opaque window undoes it.
  Alpha on the content view wants `wantsLayer` too, or AppKit has nothing to
  composite through.
- **Ending a find has to drop `pdfView.currentSelection` too, and the search
  field's x is not the problem.** The cancel button *does* send the field's
  action (and Escape reaches `control(_:textView:doCommandBy:)`), so
  `startFind("")` runs and the counter, the match list, the highlight arrays and
  the prev/next control all reset. What nothing cleared was PDFKit's own current
  selection: in light mode `showMatch` marks the current match with
  `setCurrentSelection`, and that green wash stayed on the page after the query
  stopped matching, and survived the x, Escape and a Markdown reload. It shows up
  worst in the sequence that was reported (2026-09-05) — search something, refine
  the query until it matches nothing, hit the x — because the counter then says
  "No matches" over a page that is still highlighted. Dark mode never showed it:
  the inverted path sets the current selection to nil and draws its own boxes.
  `startFind` and `installDocument` now clear it. Two theories checked and
  discarded on the way: `NSSearchToolbarItem` never collapses in this toolbar
  (the field stays expanded even at `contentMinSize`), and
  `searchFieldDidEndSearching(_:)` is deliberately still not implemented — it was
  not needed, and it would also fire when the field merely ends its search
  interaction, which could wipe a search the reader is still stepping with ⌘G.
- **`setFrameAutosaveName` saves the current frame the moment you call it**, so
  a window centred *after* it has already stored its bottom-left starting frame,
  and every launch from then on restores that. The Recents window centres before
  naming the autosave (which is also the order `sizeWindowInitially` uses for
  the reader, for the same reason). Once a bad frame is stored there is no way
  back from inside the app short of vetting the saved string, which is what
  `ReaderWindowController.hasUsableSavedFrame` exists to do.
- **macOS window restoration reopens the last session's documents**, and it does
  so *after* `applicationDidFinishLaunching`. That is why testing anything about
  the launch window means quitting with no document open — otherwise the app
  comes back with the previous session's tabs and (correctly) shows no Recents
  window at all. It also means the recents list gains an entry per restored
  document, since restoration goes through `read(from:ofType:)` like any open.
- `annotationsChanged(on:)` alone does not drop an already-rendered tile;
  follow it with `layoutDocumentView()` + `needsDisplay`.
- `.PDFViewPageChanged` fires during initial layout reporting page 1, which
  clobbered the saved reading position. Position is read once in init and
  saving is gated until the restore has run.
- `sidebarItem.isCollapsed = true` doesn't survive `addTabbedWindow`;
  re-assert after tabbing and once in `windowDidBecomeKey`.
- **The app icon's light/dark variant follows the *system* appearance, not
  `Prefs.appearance`.** Forcing the app dark with `defaults write … appearance
  -int 2` blackens the chrome and leaves the Dock tile and the About panel on
  the light artwork; the dark variant only appears with the system itself in
  dark mode. And the variant that does appear is **cached per bundle
  identifier**, so with an older copy in `/Applications` the About panel can
  show *its* artwork for a build out of `build/` — `killall Dock` cleared it
  (2026-09-05); the About panel's image is also fixed at launch, so relaunch
  after switching appearance.
- `actool` compiling a `.icon` package is undocumented by Apple (works via
  `man actool` + experiment). `actool` writes `Assets.car` even on error, so
  `make-icon.sh` greps its output for `error:` before installing. Valid
  `appearance` values in `icon.json` are only `light`, `dark`, `tinted`.
- No public scroll-edge-effect API on `NSScrollView` in the 26.0 SDK.
- **`swift build` embeds nothing.** Xcode copies a SwiftPM binary target's
  framework into the bundle; `swift build` only links against it. So the
  target carries an explicit `-rpath @executable_path/../Frameworks` in
  `linkerSettings`, and `build.sh` `ditto`s `Sparkle.framework` out of
  `.build/artifacts/*/Sparkle/Sparkle.xcframework/macos-*/` into
  `Contents/Frameworks`. Without both halves the app dies at launch in dyld.
- **Sparkle.framework has to be signed inside out, before the app.** It is a
  bundle of bundles (`Autoupdate`, `Updater.app`, `XPCServices/*.xpc` under
  `Versions/B`); signing only the outer app leaves them with Sparkle's own
  signature and `codesign --verify --deep --strict` fails. Order and flags in
  `build.sh` follow <https://sparkle-project.org/documentation/sandboxing/>,
  including `--preserve-metadata=entitlements` on `Downloader.xpc`. Sparkle
  explicitly warns *against* `--deep` when signing the app itself.
- `swift build` produces an **arm64-only** binary, so `generate_appcast`
  stamps items with `<sparkle:hardwareRequirements>arm64</…>` and Intel Macs
  will never be offered the update. Fine today; would need a lipo'd universal
  binary in `build.sh` to change.
- **`NSPrintOperation` calls its `didRun` delegate on the print thread**, not
  the main thread -- that is the flip side of `canSpawnSeparateThread`. Doing
  anything AppKit there (installing the document into a `PDFView`, in our case)
  throws `Modifications to the layout engine must not be performed from a
  background thread`. `MarkdownRenderer.printOperationDidRun` is `nonisolated`
  and does nothing but hop to main.
- **Never mutate `NSPrintInfo.shared`.** It is the user's Print… panel state;
  the renderer builds a fresh `NSPrintInfo(dictionary: [:])` every time.
- **WebKit navigation callbacks need identity too**, for the same reason the
  print operation does. Starting the next job's `loadHTMLString` cancels the
  previous job's navigation, whose `didFailProvisionalNavigation` then arrives
  and would fail the job that displaced it. `activeNavigation` holds the
  `WKNavigation` we are waiting for and all three delegate callbacks compare
  against it; the watchdog also tears the web view down before finishing, so a
  stuck load is abandoned rather than inherited.
- **A `deinit` that calls a `queue.sync` teardown can deadlock.** The last
  reference to a `FileWatcher` can be released from inside one of its own queue
  blocks (they take a temporary strong `self`), and `queue.sync` onto the serial
  queue you are already running on hangs forever. `FileWatcher.deinit` cancels
  the sources and the pending work item directly; nothing else can reach them by
  then. `stop()` keeps the `sync` for the explicit call path.
- **Set the `PDFDocumentDelegate` before anything touches a page.** PDFKit calls
  `classForPage` lazily, and a page vended before the delegate is in place is a
  plain `PDFPage` forever -- it can never draw dark-mode find highlights. In
  `GlassineDocument.install` the delegate assignment comes first.
- **`restoreFinished` must go false across a document swap.** Assigning a new
  document makes `PDFView` lay out and report page 1, and the position saver
  would write that over the place the reader was.
- **A burst of saves can land a second render while the first install's
  two-pass jump is still in flight**, and the live `currentDestination` is
  meaningless at that moment. `lastInstallTarget` is what the next install aims
  at while `restoreFinished` is false; without it, forty rapid appends walked
  the reader from page 4 to page 9.
- **`pdfView.currentDestination.point.y` sits *above* the top of the page**, by
  roughly the gutter's height, so comparing it raw against an outline
  destination at the page top never matches and the sidebar highlighted the
  previous chapter (or nothing at all on page 1). `syncSelection` clamps every y
  it compares to `page.bounds(for: .cropBox).maxY`, which also tames the huge
  "unspecified" coordinates real PDF destinations often carry.
- **swift-markdown's `HTMLFormatter` wraps every list item's text in a `<p>`,**
  even in a tight list, so list spacing has to be taken off `li > p` and a task
  item's text pulled back beside its checkbox with
  `input[type="checkbox"] + p { display: inline }`.
- **WebKit ignores `break-after: avoid` when the next block is itself
  unbreakable**, which strands headings at the foot of a page. The fix in the
  stylesheet is the old keep-with-next hack: an invisible 72 pt `::after` on
  every heading, cancelled by an equal negative margin, so the heading box
  cannot fit in the last inch of a page and carries over with its content.
- **WebKit lays a printed page out 25% wider than the paper and scales the
  result down** (WebCore's minimum shrink factor). So a `scrollHeight` measured
  in a 612 pt-wide web view is *not* the printed height: it wraps at the wrong
  width and is in the wrong unit, and the first continuous page came out 22,251
  pt tall for 13,740 pt of content — two-thirds of it blank. The renderer sets
  the web view to `612 × 1.25` for a continuous job and divides the measurement
  by the same factor; the result now lands within about 10 pt over 13,000. The
  same factor is why a CSS `72pt` padding prints as ≈77 pt: CSS pt survive the
  round trip multiplied by 4/3 × 0.8.
- **`evaluateJavaScript(_:in:in: .defaultClient)` runs even with
  `allowsContentJavaScript = false`** and a CSP of `default-src 'none'`. Those
  stop the *page's* scripts; the app's own evaluation in the client world is
  unaffected, which is what makes the continuous measurement possible.
- **A page background never reaches the print margins.** `background` on
  `body` (or on `html`) paints only the printable area, so in Pages mode a
  tinted paper shows up as a slab inset by the one-inch margin rather than
  covering the sheet. Combined with the linear-light inversion, that is why
  `--paper` stays `#FFFFFF`. In Continuous mode the margins are zero and the
  background does cover everything.
- **Run the new build once (or `lsregister -f`) so LaunchServices learns the
  Markdown type.** `UTImportedTypeDeclarations` only takes effect after the
  bundle has been registered; `mdls -name kMDItemContentType foo.md` should then
  say `net.daringfireball.markdown`.
- **The default-app checkmark compares bundle identifiers, not paths.**
  LaunchServices resolves `com.epps.Glassine` to whichever copy it likes -- setting
  the default from `build/Glassine.app` reported `/Applications/Glassine.app` back --
  so a path comparison would show the item unchecked right after checking it.
- XML comments cannot contain `--`. The hand-written `appcast.xml` skeleton
  tripped `generate_appcast`'s parser on exactly that.
- **Option-modified key equivalents do not survive a synthesized `CGEvent`, and a
  save panel ignores a synthesized Return.** ⌘F, Escape, ⌘G, ⌘T, ⌘W and plain
  typing all arrive through `CGEvent.postToPid` as documented above, but ⌥⌘G and
  ⌥⌘3 land nowhere, and neither `postToPid` Return nor a `postToPid` click will
  press an `NSSavePanel`'s Save button. The accessibility API does both:
  `AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute)`, walk the titles and
  `AXUIElementPerformAction(item, kAXPressAction)` for a menu item; a
  breadth-first search for an `AXButton` with the right title for the panel.
  Sheets are not in `AXWindows` — they hang under their parent window, which is
  why the search has to start at the application element. (2026-09-05.)
- **Capture a window by its `CGWindowID`, not its rectangle.**
  `screencapture -x -o -l<id>` (the id from `kCGWindowNumber` in
  `CGWindowListCopyWindowInfo`) captures the window's own pixels, so another
  app's window lying over it cannot get into the shot and the app does not have
  to win the activation race. It is what made a byte-identical screenshot diff
  possible on a Mac someone else was using.
- **A locked screen degrades the whole accessibility tree, not just
  screenshots.** With `CGSSessionScreenIsLocked` set, `kAXWindows`,
  `kAXMainWindow` and `kAXFocusedUIElement` all come back as the bare application
  element, no window ever becomes key, and nil-target responder-chain menu items
  (Table of Contents, Print…, Export, ⌘F) do not fire. What still works:
  `CGEvent.postToPid` for plain and ⌘ keys (they reach the first responder), AX
  presses of menu items with an explicit target (View ▸ Markdown ▸ …), and
  reading `Prefs.lastPositions` out of `defaults` after a quit as the instrument.
  That is how the 2026-09-06 bug fixes were verified overnight. (2026-09-06.)
- **An *inactive* app is almost as limiting as a locked screen.** While another
  app is frontmost, `NSApp.keyWindow` is nil, so menu validation disables every
  nil-target responder-chain item (`Print…`, `Export…`, `Find…`, `Find Next`,
  `Table of Contents`, `Close`, `New Tab`); an `AXPress` or key equivalent on
  them does nothing, and forcing `makeKeyWindow` from lldb does not help.
  Explicit-target items stay enabled, `postToPid` keys reach the first
  responder, and the non-menu routes carry the rest: the toolbar `Sidebar`
  button and the `Thumbnails`/`Table of Contents` radio buttons, `kAXFocused` on
  the search field, the `Next match` button, and setting an `AXScrollBar`'s
  `AXValue` to scroll within a page. This is how the morning-after checks were
  run without stealing Dan's focus. (2026-09-06.)
- **Adding a file to `Core/` does not make the root package rebuild it.** SwiftPM
  caches the build plan and only re-plans when a manifest's *contents* change, so
  a new Core file leaves the root build linking the previous
  `GlassineCore.swiftmodule` and reporting "cannot find type … in scope"
  indefinitely; `touch Core/Package.swift` does not help. `rm -f .build/debug.yaml
  .build/release.yaml` before `build.sh` is the fix. (2026-09-06.)

## Working conventions for this repo

- Dan wants Fable to **plan and review, and delegate implementation to Opus
  subagents** to conserve his usage. Spawn `general-purpose` agents with
  `model: "opus"` and a file-by-file spec; queue follow-ups with SendMessage.
  This includes Explore/Plan research agents: pass `model: "opus"` on every
  Agent call (agents inherit Fable otherwise). Confirmed 2026-09-04:
  "definitely keep fable for big picture thinking."
- **Never `cd` in Bash**; absolute paths only (his permission rules depend on
  it). Scratch files go in the session scratchpad, not the repo.
- Commit identity is the global git config on both Macs, `Dan Epps
  <dse@danepps.com>` (set 2026-09-05; no repo-local override). Earlier commits
  carry dsepps@gmail.com, which now maps to the danepps GitHub account too.
  Commit/push only when he asks; he has asked for pushes here.
- The app was "Folio" (bundle id `com.epps.Folio`) until Dan renamed it to
  Glassine on 2026-09-05. A further rename is a case-sensitive find-and-replace
  over `Sources/`, `Support/Info.plist`, `build.sh`, `release.sh` and
  `Package.swift`, plus `scripts/make-icon.sh` (which names the `.icon` package
  and regenerates `Assets.car`), the feed file, and a migration like
  `FolioMigration` — the bundle id is what makes it a new app to macOS.
- One tracked file still says "Folio" on purpose: `appcast.xml` (Folio's frozen
  feed). `AI Memos/` (dated AI reviews and bug reports) is gitignored and lives
  only on the Mac that wrote it.

## Known quirks / candidates for next work

- No annotation/highlighting tools (text-copy cleanup landed 2026-09-09);
  no per-document invert override (global toggle only).
- **A find with thousands of matches is expensive** (2026-09-06): "the" over a
  56-page memo, 4,176 hits, held the app at 100 % CPU and up to 4.8 GB RSS for
  about a minute and dropped the reader from 25 % to the top, with a correct
  count and no crash. Two causes are known: each 150 ms highlight batch
  rebuilds every match's line rects from scratch (the Codex review's deferred
  item), and `showMatch(0)` on the first hit still scrolls unless
  `suppressFirstScroll` was asked for. Incremental rect geometry and a cap on
  live highlighting above some match count are the obvious fixes.
- Photos/figures render as luminance-inverted in dark mode; a per-image
  "don't invert" would need per-tile work and likely isn't worth it. Images in
  a Markdown document invert the same way, for the same reason.
- **A re-render holds the reader by heading, not by page** (2026-09-06).
  `ReadingAnchor` records the outline row the reader is under, its label, and
  their depth below it in points; after the replacement installs it finds that
  heading again — same row if the label still matches, else the nearest row
  with that label — and re-applies the depth beneath it, clamped to the next
  heading. So a reload with text inserted above moves the reader down with the
  text, an append below leaves them exactly where they were, and Pages ↔
  Continuous keeps the passage (measured: page 8 of 54 → 15.7 % of a 34,952 pt
  page → back to page 8, y 400.08). It needs an outline: a memo with no
  headings, or a reader above the first one, still falls back to the page and
  point, and so does a heading whose text was edited away.
- A Markdown reload that fails leaves the previous render on screen and waits
  for the next save -- the usual cause is a half-written file. Only a failure of
  the *first* render reports an error and closes the document.
- The renderer holds one WebContent process (60-120 MB) while any Markdown
  document is open and drops it ~30 s after the last one closes.
- **In Continuous mode the Go ▸ page menu commands have nothing to act on** —
  there is one page, so Next/Previous Page from the menu do nothing. The arrow
  keys are no longer dead (2026-09-06): when the document is a single page
  taller than the window they move the clip view a viewport at a time (less
  24 pt of overlap), ⌘↑/⌘↓ go to the ends, and the page indicator shows a
  reading percentage that ⌥⌘G can set.
- A custom Markdown style is trusted: it is the style layer, so it can override
  anything the base layer sets, including the geometry that makes continuous
  layout measurable. Only the CSP still applies.
- **TO FIX NEXT (Dan, 2026-09-06 night): the Recents start tab is not
  translucent, it is transparent.** His screenshot (`AI Memos/
  translucent-recents-tab-2026-09-06.png`, local only) shows a Recents tab at
  reduced opacity in dark mode with the Passwords app's lock screen showing
  through it **sharp** — no backdrop blur anywhere in the list area — and every
  row label drawn with a dark outlined, embossed look. Same family as the
  title-bar band fixed in 1.4.1, one level down: the start tab's content view
  is faded to `Prefs.windowOpacity`, but the Recents list (`RecentsViewController`
  in a `StartTabWindowController`) paints no background of its own, so the
  window's pixels there have alpha ≈ 0, `CGSSetWindowBackgroundBlurRadius`
  (weighted by alpha) skips them, and the labels are antialiased onto a clear
  layer with nothing behind — which is where the halo comes from (AppKit's
  font smoothing needs an opaque backing; the row text looks stroked without
  it). Fix shape: give the start tab's content the same page-coloured backing
  the reader has (paper at full alpha *inside* the faded content view — black,
  the Dark Paper lift, or white in light mode), so the window's alpha is
  uniform and the blur and the text both behave, and check the sidebar's
  Recents pane and the standalone Recents window (`RecentsWindowController`,
  which never calls `WindowChrome.apply` at all) for the same hole. Verify at
  0.6 and 0.3 over something with sharp text behind, pid-isolated, both
  appearances, and re-check the tab-bar strip while there. Not started.
- **Magenta pill on a hovered background tab, macOS 26.6.2 (Dan, 2026-09-08
  night; not fixed, cause not pinned).** Screenshot `AI Memos/
  magenta-tab-hover-2026-09-08.png` (local only): a dark reader at 85 % opacity
  with blur on, two tabs; hovering the *inactive* tab (a PDF with a long,
  truncated title, `… — Class 5 — Mootness & Ripeness (clean).pdf`) painted a
  solid #FF00FF rounded rectangle, tab-height, from roughly the tab's midpoint
  to its right edge, with the hover close button and the left half of the title
  still drawn normally. Never on the selected tab. Solid magenta is what
  CoreAnimation draws for a glass/backdrop layer that cannot sample, so the
  suspect is the Liquid Glass hover highlight AppKit puts on background tabs
  in macOS 26. Established: a `CGWindowListCopyWindowInfo` poll over the title
  band found no other window (no tooltip, no overlay) — it is drawn inside the
  window; it vanished at 100 % opacity, and vanished at 85 % with Blur Behind
  Window off, **but stayed gone once blur was turned back on**, so the two
  toggles most likely cleared a stale state through `WindowChrome.apply`
  (isOpaque, backgroundColor, content alpha, the `TitlebarBackdrop` re-paint,
  the CGS blur radius) rather than proving that the blur causes it. Nothing
  in Glassine draws magenta. Unknown and needed to reproduce: what put the tab
  bar into that state — the PDF tab opened into an already-translucent window,
  an opacity change with two tabs open, a tab drag, sleep/wake, or the window
  restored at launch. If it recurs, note the preceding action; a cheap
  mitigation to try first is re-running `WindowChrome.apply` on
  `NSWindow.didBecomeMain`/tab selection change for every window in the tab
  group, since a re-apply clears it. Not verified: whether it also appears at
  85 % with blur *off* from a cold launch (the blur-off test ran after the
  opacity round trip). **Follow-up 2026-09-09:** the group-wide re-apply on
  `didBecomeMain`/selection change suggested above is now in (`WindowChrome.
  reapply(group:)`, see the 2026-09-09 State entry), so if the pill was a
  stale-state artefact it should now clear on the next tab switch. Still not
  reproduced: the harness cannot hover a background tab without moving the
  real pointer.
