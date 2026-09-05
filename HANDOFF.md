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
- Codex (GPT-5) reviewed the code 2026-09-04: `AI Memos/folio-code-review-2026-09-04-Codex-GPT-5.md`.
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

## Build, run, test

```sh
./build.sh --run           # release build + launch (run from repo root)
./build.sh --debug         # debug config
./build.sh --adhoc         # skip Developer ID signing (offline, no keychain)
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
- Test PDFs the agents used live in the session scratchpad and are gone;
  Dan has plenty in ~/Downloads (SCOTUS slip opinions are good: color,
  small caps, lots of matches).

## Architecture (Sources/Glassine)

| File | Role |
|---|---|
| `main.swift` | NSApplication bootstrap, sets `AppDelegate`. |
| `AppDelegate.swift` | Installs the menu, applies saved appearance override, shows Open panel on launch/no windows, appearance & invert menu actions. Owns the Sparkle `SPUStandardUpdaterController` (started eagerly, so the scheduled background check runs). |
| `MainMenu.swift` | Entire menu bar in code. Nil-target actions ride the responder chain (`zoomIn:`, `goToNextPage:` etc. are PDFView's). "Open Recent" is just a submenu with a `clearRecentDocuments:` item; AppKit fills it. "Check for Updates…" is the one item with an explicit target — Sparkle's updater controller isn't in the responder chain, so it's passed in from the app delegate. |
| `GlassineDocument.swift` | `NSDocument` (ObjC name `GlassineDocument`, referenced from Info.plist) wrapping `PDFDocument`. Two `Kind`s: a PDF is opened directly; a Markdown file is decoded and converted to HTML in `read`, then typeset asynchronously and installed through `.glassineDocumentDidReplacePDF`. Owns the `FileWatcher`, the re-render on a style/size/layout change, `applyOutline` (the synthesised Markdown table of contents), the word-count `markdownStats`, `isContinuousMarkdown`, and `exportAsPDF` (which typesets a second, paginated render when the reader is showing a continuous one). `PDFDocumentDelegate`: returns `ReaderPage` for pages, forwards find callbacks to the window controller via `FindSink`. |
| `MarkdownHTML.swift` | Markdown → HTML. Decode (UTF-8, UTF-16 by BOM), strip YAML front matter, `Markdown.Document` + `HTMLFormatter`, an `ImageInliner` rewriter that turns relative local images into `data:` URIs, a `HeadingAnchorer` rewriter that wraps each heading in an invisible `glassine-outline://` anchor and returns the heading list beside the HTML, a `TextCollector` walker behind the word count, and the stylesheet: a base layer of structure driven by CSS variables plus one style layer (six built-ins, or a custom file). Pure Swift, no AppKit, safe off-main. |
| `MarkdownRenderer.swift` | `@MainActor` singleton. One offscreen `WKWebView` in a never-shown borderless window; serial job queue (a newer job for the same document supersedes a queued one); prints to a temp PDF and hands back `(Data, PDFDocument)`. A `.continuous` job is measured with `scrollHeight` after it loads and printed onto one page as tall as its content. Tears the web view down 30 s after the last Markdown document closes. |
| `FileWatcher.swift` | vnode `DispatchSource` on the file *and* its parent directory, 250 ms debounce, `(inode, mtime, size)` gate, reopens the descriptor when the file is replaced or recreated. |
| `ReaderWindowController.swift` | Window, `NSSplitViewController` (sidebar + reader), unified toolbar, page indicator, search field + hit counter + previous/next match segmented control (⇧⌘G/⌘G equivalents), tabs, reading-position memory, black chrome in dark mode, window translucency and the backdrop blur. |
| `ReaderViewController.swift` | `ReaderPDFView` (PDFView subclass: arrow-key paging, per-page highlight bookkeeping), appearance routine that installs the inversion filters. |
| `SidebarViewController.swift` | Two panes behind a segmented control: `PDFThumbnailView` (mirrors the inversion filters) and an `NSOutlineView` table of contents driven from `PDFDocument.outlineRoot`, with `PDFOutline` objects as the items. Clicking a row navigates; `syncSelection()` follows the reading position. The outline is native text and is deliberately *not* filtered. |
| `ReaderPage.swift` | `PDFPage` subclass; draws dark-mode find highlights. |
| `Prefs.swift` | UserDefaults: invert toggle, dark-paper level, appearance override, per-file last position, Markdown style/layout/size, window opacity and blur. Also `MarkdownStyle`, which enumerates the six built-ins and the `.css` files in `~/Library/Application Support/Glassine/Styles` and reads a style's CSS. |

Support/: `Info.plist`, `Glassine.icon` (Icon Composer package, light+dark),
`Assets.car` (compiled from it), `Glassine.icns` (fallback). scripts/:
`make-icon.swift` renders both variants, `make-icon.sh` builds icns +
`.icon` + runs `actool`. The icon (2026-09-04, drawn by Codex) is a page with
a folded corner and four coloured margin tabs on a graphite tile; the dark
variant flips the page to black. `scripts/make-icon-concepts.swift` renders
the alternatives that were considered into `Support/IconConcepts/` (gitignored,
~57 MB).

The **Markdown document icon** (the Finder icon for a `.md` file) is separate:
`swift scripts/make-doc-icon.swift` writes the committed
`Support/MarkdownDocument.icns` (10 entries, 16–512 pt at 1× and 2×), which
`build.sh` copies into `Contents/Resources` and `Info.plist` names twice —
`CFBundleTypeIconFile` on the Markdown `CFBundleDocumentTypes` entry and
`UTTypeIconFile` on the imported UTI. It is a bare sheet with the app icon's
folded corner, slate rules and four coloured margin tabs, plus a bold M↓;
only the *light* variant is shipped, because Finder draws one document icon
whatever the appearance is. `scripts/make-doc-icon-concepts.swift` stays as the
exploratory script (six directions into `Support/IconConcepts/Doc/`). Each size
is drawn at its own resolution rather than downsampled, and 16 and 32 px are
hand-tuned in `tuning(for:)`: the sheet is zoomed to fill the tile, edges and
rules snap to whole pixels, the mark's stem is forced to 2 px (the
proportional 0.25 × height lands under a pixel and greys out), tab positions
come from one rounded pitch rather than four rounded positions, and at 16 px
the rules and the arrow are dropped — there is only room for the M.

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
  annotation's URL names *one* heading exactly; fragment links (`#some-heading`)
  would be ambiguous whenever two headings slugify the same, and WebKit does not
  emit annotations for same-page fragments anyway. `a.fh { color: inherit }`
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
- `annotationsChanged(on:)` alone does not drop an already-rendered tile;
  follow it with `layoutDocumentView()` + `needsDisplay`.
- `.PDFViewPageChanged` fires during initial layout reporting page 1, which
  clobbered the saved reading position. Position is read once in init and
  saving is gated until the restore has run.
- `sidebarItem.isCollapsed = true` doesn't survive `addTabbedWindow`;
  re-assert after tabbing and once in `windowDidBecomeKey`.
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
- Two files still say "Folio" on purpose: `appcast.xml` (Folio's frozen feed)
  and `AI Memos/folio-code-review-2026-09-04-Codex-GPT-5.md` (a dated record).

## Known quirks / candidates for next work

- No annotation/highlighting tools; no text-copy cleanup (line-break
  stripping); no per-document invert override (global toggle only).
- Photos/figures render as luminance-inverted in dark mode; a per-image
  "don't invert" would need per-tile work and likely isn't worth it. Images in
  a Markdown document invert the same way, for the same reason.
- **Markdown reload keeps the page number, not the paragraph.** Content
  inserted *above* the reading position shifts everything down, so the reader
  ends up slightly earlier in the text than before. Anchoring the restore to the
  nearest heading (or to a text snapshot) is the obvious next step.
- A Markdown reload that fails leaves the previous render on screen and waits
  for the next save -- the usual cause is a half-written file. Only a failure of
  the *first* render reports an error and closes the document.
- The renderer holds one WebContent process (60-120 MB) while any Markdown
  document is open and drops it ~30 s after the last one closes.
- **Switching Pages ↔ Continuous lands near the top of the document**, because
  the position is carried as a page index and a point and the two layouts share
  neither. Anchoring to the nearest heading would fix this and the reload case
  above at the same time.
- **In Continuous mode the Go ▸ page commands and arrow-key paging have nothing
  to act on** — there is one page, so ⌘↑/⌘↓ and Next/Previous Page do nothing.
  The page indicator is the exception: it shows a reading percentage, and
  ⌥⌘G scrolls to one. Paging by fraction (a "page" of the window's height per
  arrow press) is the obvious next step if the dead keys ever annoy.
- A custom Markdown style is trusted: it is the style layer, so it can override
  anything the base layer sets, including the geometry that makes continuous
  layout measurable. Only the CSP still applies.
