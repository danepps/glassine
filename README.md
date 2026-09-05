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
- **Adjustable window opacity, with a blurred backdrop.** View ▸ Window Opacity
  fades the page from 100% down to 30% so you can read against what is behind
  it, and blurs whatever shows through the way Terminal does; ⌥⌘↑ / ⌥⌘↓ step it,
  and View ▸ Blur Behind Window turns the blur off for a sharp backdrop.
- **Opens Markdown too.** A `.md` file is typeset into real pages and shown
  through the same reader, so tabs, dark mode, find, paging, and position memory
  all work on it. It re-renders within about half a second whenever the file
  changes on disk, keeping your place. The title bar shows its word count.
  Export the rendered pages with ⇧⌘E — always paginated, however
  you are reading it.
- **Markdown styles.** View ▸ Markdown ▸ Style offers six print-quality
  stylesheets — Manuscript (New York serif), Modern (SF, airy), GitHub,
  Antique (Baskerville, old-style numerals), Ink (small-caps heads, tight
  leading) and Academic (Times, indented paragraphs) — plus the body size.
  Drop a `.css` file into `~/Library/Application Support/Glassine/Styles`
  (View ▸ Markdown ▸ Style ▸ Open Styles Folder…) and it joins the menu; it can
  set the stylesheet's variables (`--body-font`, `--line-height`, `--rule`, …)
  or override anything.
- **Pages or continuous.** View ▸ Markdown ▸ Pages / Continuous: real Letter
  pages, or one uninterrupted column with no page breaks at all. Reading
  continuously, the toolbar's page counter becomes a progress percentage, and
  ⌥⌘G jumps to one.
- **One window, native tabs.** Every PDF opens as a tab (⌘T opens another,
  ⇧⌘[ / ⇧⌘] switch, drag tabs out to split).
- **Opens to your recent files, not a file dialog.** With nothing on screen
  Glassine shows a Recents window (⇧⌘O any time): the last thirty files you
  read, with where you left off in each, a filter field, drag-and-drop, and
  "Open Other…" for everything else.
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
there is a menu item: Glassine ▸ Use Glassine to Open Markdown Files.

Dependencies are Sparkle and [swift-markdown][], which is pinned by commit
because its own manifest depends on swift-cmark by branch and SwiftPM will not
accept a version range on top of that.

[swift-markdown]: https://github.com/swiftlang/swift-markdown

## Layout

```
Package.swift                 Swift Package (single executable target)
Support/Info.plist            bundle metadata, PDF document type
Support/Glassine.icon, .icns, Assets.car   app icon sources and compiled variants
build.sh                      assembles the .app bundle
release.sh                    cuts a release and updates glassine-appcast.xml
glassine-appcast.xml          Sparkle feed (appcast.xml is Folio's, frozen)
Sources/Glassine/
  main.swift                  NSApplication bootstrap
  AppDelegate.swift           launch behavior, appearance menu actions, Folio migration
  MainMenu.swift              menu bar, built in code
  GlassineDocument.swift      NSDocument wrapper around PDFDocument (PDF or Markdown)
  MarkdownHTML.swift          Markdown -> HTML + headings + the print stylesheet
  MarkdownRenderer.swift      offscreen WKWebView that typesets HTML into a PDF
  FileWatcher.swift           vnode watcher behind Markdown auto-refresh
  RecentsWindowController.swift the launch window: the files you have been in
  ReaderWindowController.swift  window, toolbar, tabs, find, page field
  ReaderViewController.swift  the PDFView and dark-mode handling
  SidebarViewController.swift sidebar: page thumbnails and the outline pane
  ReaderPage.swift            PDFPage subclass that draws dark-mode find highlights
  Prefs.swift                 UserDefaults-backed settings and reading positions
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
