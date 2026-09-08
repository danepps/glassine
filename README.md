# Glassine

<https://github.com/danepps/glassine>

A small, fast, native macOS PDF reader that also opens Markdown. Swift + AppKit
+ PDFKit, no Electron, no storyboards; WebKit is used only offscreen, to typeset
Markdown into pages. Built because PDF Expert got slow.

Renamed from **Folio** at 1.1.0; the bundle identifier changed with it, so the
first launch carries your Folio settings, reading positions and custom Markdown
styles across, and an installed Folio has to be replaced by hand rather than
updated in place.

- **Dark mode that inverts the page.** Follows the system appearance; in dark
  mode the PDF content itself renders light-on-dark, not just the window chrome.
  Toggle with View ▸ Invert Page Colors in Dark Mode, or force Light/Dark under
  View ▸ Appearance.
  View ▸ Appearance also picks how dark the paper is — Black, Charcoal or Gray —
  and the window chrome follows the level you choose.
- **Adjustable window opacity, with a blurred backdrop.** Window ▸ Opacity
  fades the page from 100% down to 30% so you can read against what is behind
  it, and blurs whatever shows through the way Terminal does; ⌥⌘↑ / ⌥⌘↓ step it,
  and Window ▸ Blur Behind Window turns the blur off for a sharp backdrop.
- **Opens Markdown too.** A `.md` file is typeset into real pages and shown
  through the same reader, so tabs, dark mode, find, paging, and position memory
  all work on it. It re-renders within about half a second whenever the file
  changes on disk, keeping your place. The title bar shows its word count.
  Export the rendered pages with ⇧⌘E — always paginated, however
  you are reading it. Everything Markdown-specific lives in its own **Markdown**
  menu, between View and Go.
- **Footnotes and heading links.** `[^label]` references and their
  `[^label]: …` definitions are set as superscript markers and a notes section
  at the end, numbered by first use; clicking a marker jumps to the note and
  the note's ↩ jumps back. Headings get GitHub-style anchors, so a
  hand-written table of contents (`[Background](#background)`) is live in the
  rendered pages too.
- **Markdown styles.** Markdown ▸ Style offers six print-quality
  stylesheets — Manuscript (New York serif), Modern (SF, airy), GitHub,
  Antique (Baskerville, old-style numerals), Ink (small-caps heads, tight
  leading) and Academic (Times, indented paragraphs) — plus the body size, under
  Markdown ▸ Text Size (⌥⌘= / ⌥⌘− step through it).
  Drop a `.css` file into `~/Library/Application Support/Glassine/Styles`
  (Markdown ▸ Style ▸ Open Styles Folder…) and it joins the menu; it can
  set the stylesheet's variables (`--body-font`, `--line-height`, `--rule`, …)
  or override anything.
- **Pages or continuous.** Markdown ▸ Pages / Continuous: real Letter
  pages, or one uninterrupted column with no page breaks at all. Reading
  continuously, the toolbar's page counter becomes a progress percentage, and
  ⌥⌘G jumps to one.
- **One window, native tabs.** Every PDF opens as a tab (⇧⌘[ / ⇧⌘] switch, drag
  tabs out to split). ⌘T and the tab bar's "+" open a start tab: the new tab
  itself shows your recent files, and picking one fills that tab in place.
- **Opens to your recent files, not a file dialog.** With nothing on screen
  Glassine shows a Recents window (⇧⌘O any time), and a new tab shows the same
  picker: the last thirty files you read, with where you left off in each, a
  filter field, drag-and-drop, and "Open Other…" for everything else.
- **Zippy.** Renders through PDFKit, the same engine as Preview. Launches cold in
  well under a second.
- **Remembers where you were** in each file.
- Arrow keys always page: ↑/← previous, ↓/→ next, ⌘↑/⌘↓ first/last.
- **Sidebar with a table of contents.** ⌃⌘S shows it; ⌥⌘2 and ⌥⌘3 switch
  between page thumbnails and the document's chapters. Markdown gets an outline
  too, synthesised from its headings, and the current entry follows you.
- Find with a hit counter and green highlights (⌘F,
  ⌘G / ⇧⌘G), go to page (⌥⌘G), zoom (⌘= / ⌘- / ⌘0 fit / ⌘1 actual),
  back/forward (⌘[ / ⌘]), print, export as PDF (⇧⌘E).

## Build

Requires Xcode (or the command-line tools with a Swift 5.9+ toolchain) on
macOS 14 or later, Apple Silicon only (the build is arm64; a universal binary would need `lipo` in `build.sh`).

```sh
./build.sh          # builds build/Glassine.app
./build.sh --run    # builds and launches
./build.sh --debug  # debug configuration
```

Drag `build/Glassine.app` to `/Applications` if you want it in Launchpad, then
right-click a PDF ▸ Get Info ▸ Open With to make it the default. For Markdown
there is a menu item: Markdown ▸ Open Markdown Files with Glassine by Default.

Dependencies are Sparkle and [swift-markdown][], which is pinned by commit
because its own manifest depends on swift-cmark by branch and SwiftPM will not
accept a version range on top of that.

[swift-markdown]: https://github.com/swiftlang/swift-markdown

## Glassine for iPad and iPhone

The same reader, native, on iOS 18 and later: PDFs and Markdown memos, the page
content itself inverted in dark mode with the three Dark Paper tones, green find
boxes with a hit count, a table of contents, reading-position memory across
launches, a Recents launch screen, and Markdown typeset by WebKit into real PDF
pages in the six built-in styles plus any `.css` you drop into Files ▸ On My
iPad ▸ Glassine ▸ Styles. On iPad it is a split view with Recents, Thumbnails
and Contents panes and hardware-keyboard paging; on iPhone the same panes are a
sheet. It is **on TestFlight for now**, not the App Store. To build it from
source you need Xcode 26 and `xcodegen` (`brew install xcodegen`), then
`./build-ios.sh --sim "iPad Pro 11-inch (M5)" --run`; `./build-ios.sh --test`
runs the XCUITest suite, and `./build-ios.sh --device` builds for a paired
device. The portable half of the app lives in `Core/` (SwiftPM package
`GlassineCore`) and is shared with the Mac app; the iOS target is an XcodeGen
spec in `iOS/project.yml`, and `iOS/Glassine.xcodeproj` is generated, not
checked in.

## Layout

```
Package.swift                 Swift Package for the Mac app (depends on Core/)
Support/Info.plist            bundle metadata, PDF and Markdown document types
Support/Glassine.icon, .icns, Assets.car   app icon sources and compiled variants
build.sh                      assembles build/Glassine.app
release.sh                    cuts a Mac release and updates glassine-appcast.xml
glassine-appcast.xml          Sparkle feed (appcast.xml is Folio's, frozen)
build-ios.sh                  xcodegen + xcodebuild for the simulator or a device
release-ios.sh                archives, exports and uploads an iOS build to TestFlight
Core/                         GlassineCore: the logic both apps share, with its tests
  MarkdownHTML.swift          Markdown -> HTML + headings + the print stylesheet
  Prefs.swift                 UserDefaults-backed settings, recents and reading positions
  FileWatcher.swift           vnode watcher behind Markdown auto-refresh
  ReaderPage.swift            PDFPage subclass that draws dark-mode find highlights
  FindController.swift        the find state machine; FindHighlighter.swift its boxes
  OutlineSync.swift           which chapter the reader is in; HeadingLocator.swift the iOS outline
  ReadingPosition.swift, ReadingAnchor.swift, ReadingProgress.swift   where the reader is
  MarkdownDocumentModel.swift, MarkdownReloader.swift, RenderQueue.swift   the Markdown pipeline
  RecentsModel.swift          rows, filter and labels behind the Recents screens
Sources/Glassine/             the Mac app (AppKit)
  main.swift                  NSApplication bootstrap
  AppDelegate.swift           launch behavior, menu actions, Folio migration
  MainMenu.swift              menu bar, built in code
  GlassineDocument.swift      NSDocument wrapper around PDFDocument (PDF or Markdown)
  MarkdownRenderer.swift      offscreen WKWebView + NSPrintOperation that typesets HTML into a PDF
  RecentsViewController.swift   the recents picker: list, filter, drop target
  RecentsWindowController.swift the launch window around that picker
  StartTabWindowController.swift a new tab showing the picker until you pick
  ReaderWindowController.swift  window, toolbar, tabs, find, page field
  ReaderViewController.swift  the PDFView and dark-mode handling
  SidebarViewController.swift sidebar: page thumbnails and the outline pane
iOS/                          the iPad and iPhone app (SwiftUI + PDFKit)
  project.yml                 XcodeGen spec; Glassine.xcodeproj is generated
  Sources/                    app, reader, recents, panes, settings, the iOS Markdown renderer
  UITests/                    XCUITest suite
  Support/                    Info.plist, privacy manifest, launch-screen colour, the icon
```

## How the dark-mode inversion works

The PDF view gets two Core Image filters on its layer: `CIColorInvert` followed
by a 180° `CIHueAdjust`. Together they flip luminance while preserving hue, so
white paper becomes black, black text becomes white, and blue links stay blue.
The GPU applies the filters at composite time, so there is no white flash while
tiles render, appearance changes are instant, and printing is untouched. The
thumbnail sidebar gets the same filters. Colors that must look right *after*
the filter (the page gutter, the green find highlights) are chosen pre-filter.

Find highlights in dark mode are drawn by `ReaderPage` (a `PDFPage` subclass)
with a `.screen` blend over each match, which recolors only the glyphs.

## How Markdown viewing works

A Markdown file is parsed with Apple's [swift-markdown][] and formatted to HTML,
then loaded into a `WKWebView` that lives in a window which is never shown. The
web view is printed to a temporary PDF with `NSPrintOperation`, and that
`PDFDocument` is handed to the normal reader. Nothing on screen is ever a web
view; WebKit is only the typesetter, and it is what gives us real page breaks,
selectable text, and clickable link annotations.

Two details matter. The print has to run through
`runModal(for:delegate:didRun:contextInfo:)` with `canSpawnSeparateThread` set:
WebKit computes its page range only on a secondary print thread, and
`NSPrintOperation.run()` never spawns one, which is the usual cause of blank
output. And margins come from `NSPrintInfo`, not from an `@page` rule, because
WebKit subtracts the print info's margins itself and setting both doubles them.

The stylesheet is two layers: a base layer of structure and CSS variables, and
a style layer that sets those variables — a built-in, or a `.css` file from
`~/Library/Application Support/Glassine/Styles` used verbatim. Colours are picked
for how they look *after* the dark-mode inversion filter, which is a luminance
flip performed in linear light: code and table-header panels are near-white so
they come back as dark grays, and the page background must be pure white,
because even a faintly tinted paper comes back as a visible coloured slab.

Continuous layout is the same pipeline with a different page: the loaded
document is measured with `scrollHeight` and printed onto a single page as tall
as its content, with zero margins and the inch of white space supplied by
`body { padding }`. It is still an ordinary `PDFDocument`, so find, the
outline, and position memory need to know nothing about it.

## Icon

Four fanned sheets of glassine, the front one ruled in coral, amber, mint and
blue: a near-white tile in light, a graphite one with the rims blooming in dark.
`Support/Glassine.icon` is an Icon Composer package with those two appearances,
compiled by `scripts/make-icon.sh` into `Support/Assets.car` (macOS 26 uses it
via `CFBundleIconName`). The same script renders `Support/Glassine.icns` as the
fallback for macOS 14 and 15, drawing every size at its own resolution rather
than downsampling 1024. `swift scripts/make-doc-icon.swift` builds
`Support/MarkdownDocument.icns`, the Finder document icon for `.md` files: one
sheet of the same family, coral-rimmed, with an M↓ over the four rules.

## License

MIT. See [LICENSE](LICENSE).
