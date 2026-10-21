# Code review — full codebase at v1.9.6

_Reviewed 2026-10-20 by Claude (Fable 5.1), with three parallel review agents
(macOS shell, GlassineCore, iOS + scripts) and an independent headless Codex
review (gpt-6-astra, read-only). Scope: everything at `3ce9f0b` — the macOS
app, the Core library, the iOS port, the build and release scripts, and both
test suites; about 16,000 lines. Every finding below was re-verified against
the code by the consolidating reviewer before anything was changed. Fixes are
on branch `code-review-2026-10-20`; line numbers refer to `3ce9f0b` unless a
fix is described._

**Overall.** The recent 1.9.x work (render recovery across sleep, the
RenderQueue watchdog, ordered reloads, the Finder-rename fix, accent-blind
search) holds up: all four reviews independently confirmed the generation
guards, the supersede-by-key queue, the file-presenter hop to main, the
highlight save-before-close, and the locked/signed-PDF gates. Nothing found
would lose a highlight or a saved position on the Mac. The two things worth
knowing about are (1) the "environmental" macOS test failures were a real
cross-suite race, now fixed, and (2) a Markdown file could make the offscreen
renderer fetch a remote URL, now blocked at two layers. The iOS port lags the
Mac on several guards the Mac already has; the ones that could show the wrong
document or lose a position are fixed, the rest are listed as recommendations.

---

## Fixed on the branch

### 1. The macOS test suite was racing itself (commit `22ad188`)

HANDOFF recorded four or five macOS tests failing on this machine with no
code change, a varying set, "probably environmental". They were not. Swift
Testing runs top-level suites concurrently and interleaves `@MainActor` tests
at every `await`. Most macOS suites swap the process-global `Prefs.defaults`
(`Core/Sources/GlassineCore/Prefs.swift:83`) for an isolated store and restore
it on exit, so `ReaderModeTests` — which never isolated — saved Reader Mode
settings into another suite's temporary store and read them back after it was
gone (`ReaderModeTests.swift:97`, `:141`). And every `Prefs` setter posts
`glassinePrefsChanged` to `NotificationCenter.default`, which re-rendered the
Markdown documents open in `MarkdownDocumentRefreshTests` and threw their
request counts off.

Fix: every macOS suite (and the former top-level `@Test` functions) is nested
in one `@Suite(.serialized) enum MacAppTests` via extensions, which Swift
Testing honours for sub-suites (verified with a scratch package). 93/93 pass,
repeatedly, in 28 s instead of a 4-failure run in 18 s. The diff is mostly
re-indentation; review it with whitespace hidden.

### 2. A Markdown file could navigate the hidden renderer to a remote URL (`79fe6dd`, `a0a8a4c`)

Found independently by the Core agent and Codex. Raw HTML passes through
swift-markdown's formatter verbatim (`MarkdownHTML.swift:224`; the formatter's
`visitHTMLBlock`/`visitInlineHTML` emit `rawHTML` unchanged). The CSP
(`default-src 'none'; img-src data:; style-src 'unsafe-inline'`) and the
disabled script engine stop subresource loads and scripts, but a
`<meta http-equiv="refresh" content="0;url=https://…">` is a *navigation*,
which no CSP directive governs, and neither platform's `WKNavigationDelegate`
implemented a policy decision. Opening an untrusted `.md` could therefore send
a request carrying the reader's IP to a URL of the author's choosing.

Fix, two layers:

- Core `Sanitiser` (`MarkdownHTML.swift`, new `MarkupRewriter`) cuts `<meta>`,
  `<link>`, `<base>`, `<script>`, `<iframe>`, `<object>`, `<embed>` out of every
  raw HTML node (none has a rendering purpose in a Markdown body; a block-level
  `<script>` goes with its contents). It also turns links to the private
  `glassine-outline://` scheme into plain text — `applyOutline` reads those
  annotations back (`MarkdownDocumentModel.swift:122-131`), so a forged one
  moved a real bookmark — and percent/entity-escapes the `"` that the
  formatter writes unescaped into `href`, `src`, `title` and the code-fence
  `class`, which truncated such links in the PDF.
- Both printers (`WebKitHTMLPrinter`, `UIKitHTMLPrinter`) implement
  `decidePolicyFor` and allow exactly one navigation per job: the
  `loadHTMLString` they started. Everything else is cancelled before a request
  is made.

Four new Core tests cover the sanitiser. The navigation policy itself has no
automated test (it needs a live WKWebView, which the suite keeps behind an
environment flag); it was reviewed, not exercised.

### 3. Symlink escape from the image folder (`79fe6dd`, Codex)

`ImageInliner` compared standardized paths (`MarkdownHTML.swift:393-397`), so
`![x](link.png)` where `link.png` is a symlink to a file anywhere the app can
read — or `up/secret.png` through a symlinked directory — passed the prefix
check and was base64-embedded into the render and any export. Both sides now
resolve symlinks. New test with a file link and a directory link.

### 4. Core correctness (`79fe6dd`)

- **CRLF files** (Core agent, high confidence). The front-matter and footnote
  passes split on `"\n"` only (`MarkdownFootnotes.swift:132-134`, `:188-193`;
  `MarkdownHTML.swift:236`): a Windows-saved file had a `---\r` fence that was
  not a fence, a `\r` line that was not blank, a code fence that never closed,
  and a footnote definition that lazily swallowed every paragraph after it.
  Line endings are normalised once at the top of `body(fromMarkdown:)`. Test.
- **Footnote back-link** spliced into the *last* `</p>` anywhere in the note
  (`MarkdownFootnotes.swift:353`), landing ahead of a trailing code block or
  list; now only a trailing paragraph gets it. Test.
- **Footnote slug de-duplication** (`:211`) did not re-check the suffixed
  slug; `[^a-b-3]`, `[^a.b]`, `[^a-b]` produced a duplicate `id`. Test.
- **`CopyCleanup`** rebuilt the whole accumulated string for every joined line
  (`CopyCleanup.swift:72`, `:101`, `:480-501`): quadratic on Select All → Copy
  of a long document. Joins are in place now; the 31 existing tests pass.
- **`HeadingLocator`** ran a whole-document `findString` per heading
  (`:140`, `:231`); repeated titles are looked up once.
- **`RecentsModel.detailText`** replaced the home path anywhere in the folder
  string (`:56-57`), so `/Volumes/Backup/Users/dan/x` read `/Volumes/Backup~/x`.
  Prefix only now. Test.
- **`FindController.step`** restarted a search still in progress when ⌘G or
  Return arrived before the first hit (`FindController.swift:290-302`); on a
  large PDF repeated presses meant it never finished. A running search is now
  left alone. Test.

### 5. macOS shell (`a0a8a4c`)

- **Reader Mode transactions re-ran the search and cleared the selection**
  (macOS agent, medium/high). `readerMode.preservePosition`'s completion
  called `finishInstall()` (`ReaderWindowController.swift:151-163`,
  `:1252-1268`), written for document replacement, which ends in
  `startFind(query, suppressFirstScroll: true)` → `findControllerDidClear` →
  `setCurrentSelection(nil)`. `changeLayout` runs on every `viewDidLayout`
  whose width moved >0.5 pt, on zoom-to-fit, and on every highlight edit, so a
  live resize with a query active cancelled and restarted the find dozens of
  times a second and dropped the text selection. `finishInstall(rerunFind:)`
  re-applies the still-valid highlights when only the geometry changed.
- **Page capsule after unlock.** `indicatorWidth(for:)` was fixed at build from
  a locked PDF's page count of 0 (`:446-459`) and `documentDidUnlock`
  (`:1047-1053`) never re-sized it, so "Page 123 of 456" drew past the capsule.
- **Return in the search field** restarted the search unconditionally
  (`:973-976`), including a full re-scan after "No matches"; it now goes
  through `step` like ⌘G.
- **Deleting a highlight navigated the reader** to the row that took its
  place: `selectRowIndexes` ran outside the `syncing` guard
  (`HighlightsViewController.swift:140-149`) → `onSelect` → `go(to:)`.
- **`presentedItemDidChange`** read the main-actor-owned `watcher` reference
  on NSDocument's presenter queue (`GlassineDocument.swift:344-350`; Codex,
  high). It now hops to main like `presentedItemDidMove` already did.
- **A move could discard the latest revision** (Codex, high). The move handler
  invalidated the in-flight reload and `FileWatcher.retarget` took the
  destination's current bytes as its baseline (`:352-361`,
  `FileWatcher.swift:75-87`), so a revision saved just before the move was
  never rendered until the next edit. The existing test waited 400 ms before
  writing, which is why it never saw this. The document now re-reads once from
  the new URL (the content hash gate makes an unchanged file free; a closed
  document, which has no watcher, does not). New test "A revision saved just
  before a move is shown after it" failed before the fix and passes after.
- **Quit flag set too late** (macOS agent, low). `isTerminating` was set in
  `applicationWillTerminate` (`AppDelegate.swift:74-76`), but
  `reviewUnsavedDocuments` → `closeAllDocuments` closes a document with pending
  highlight edits asynchronously, after its window has gone — exactly when the
  deferred `showRecentsIfNoDocuments` (`:116-124`) would bring the Recents
  window up mid-quit. `GlassineDocumentController` now sets the flag when the
  review begins and clears it if the review is cancelled, through a small relay
  object (AppKit's three-argument callback needs the IMP called directly).

### 6. iOS port (see the iOS commit)

- **Printer generation stamps** (iOS agent and Codex, both high).
  `UIKitHTMLPrinter` guarded every async hop only on `pendingCompletion != nil`
  (`MarkdownRendererIOS.swift:252`, `:274-288`, `:369-377`, `:388`), which is
  non-nil again the moment the *next* job starts. After a watchdog teardown and
  retry, a stale measurement could press the new attempt's half-loaded page,
  and a late `createPDF` result from the dropped view could be delivered to the
  new job — a different document's, since the printer is a process-wide
  singleton. Ported the Mac's `generation` stamp to `print`, `reprint`,
  `teardown`, the WebContent restart and every callback, plus the
  `webView === self.webView` identity checks the Mac's delegate has.
- **`DocumentSession.close()`** did not bump `renderGeneration` or let go of
  `pdfView` (`DocumentSession.swift:320-342`), and `RootView` hands the next
  session the *same* `ReaderPDFView` (`RootView.swift:180-183`,
  `ReaderPDFView.swift:251-254`), so correctness depended on the old session
  deallocating before its render finished. `close()` now retires the render
  and drops the view, position, anchor and find sink.
- **Scene disconnect leaked the file presenter and prefs observer**
  (`:198-203`, `:517`, `:547`): a closed iPad window never calls `close()`, and
  `NSFileCoordinator` retains its presenters. `deinit` now removes both (both
  calls are thread-safe). `RootView` also saves the reading position on
  `scenePhase == .background`, which is per scene where the app-wide
  background notification is not — and a continuous Markdown document never
  changes page, so it saved nowhere else.
- **Size-class change lost the live position**: `attach` swapped `pdfView`
  without saving (`:656-663`) and `installInView` then restored the last
  *saved* one (`:687-702`). `attach` saves first now.
- **Files-app rename or move was not followed** (iOS agent high, Codex
  high): `MarkdownFilePresenter` had no `presentedItemDidMove`, `url` was
  immutable, nothing called `FileWatcher.retarget` (`:974-989`), so
  auto-refresh died for the session and the position was keyed under a dead
  path. The presenter now forwards moves; the session retargets the watcher,
  updates its title and Recents row, re-saves the position under the new path
  and re-reads the file once.
- **Recents could not reopen external files** (iOS agent, Codex). `Prefs.
  resolvedURL` checked `fileExists` on the bare path and returned a
  `URL(fileURLWithPath:)` with no scope (`Prefs.swift:433-457`); on iOS a file
  in iCloud Drive or another provider fails that check and, when it did
  resolve, the standardized copy lost the scope `DocumentSession` has to
  start. On iOS the bookmark is now resolved first, existence is checked inside
  its scope, and the resolved URL itself is returned. (macOS behaviour is
  unchanged.)
- **Unlocking a PDF never enabled position saves** (Codex, high). The only
  `restoreIfNeeded` call was at install (`:702`), which returns early for a
  locked document, so after the user typed the password nothing restored and
  `restoreFinished` kept every later save blocked. The session now observes
  `PDFDocumentDidUnlock` and does what the Mac's `documentDidUnlock` does.
- **A failed iOS refresh could not retry identical bytes** (Codex, high): the
  Mac's `renderNeedsRetry` state was missing (`:528`). Ported.
- **Export of a continuous document used the preference, not the installed
  layout** (Codex, high; `:570-572`): switching Continuous → Pages and
  exporting before the re-render landed shipped the tall page. Now
  `isContinuousMarkdown`, as on the Mac.
- **Outline applied before the page-class delegate** (Codex, high):
  `applyOutline` touched pages before the session set `delegate = bridge`
  (`MarkdownRendererIOS.swift:452-455` vs `DocumentSession.swift:427`), so
  heading pages were plain `PDFPage`s that cannot draw dark-mode find
  highlights. The renderer now takes a `prepare` hook that installs the
  delegate first.
- **Background suspension**: the iOS queue had none of the Mac's
  sleep/background `setSuspended` wiring (`:427-435`); a render in flight at
  background came back as a watchdog timeout. Wired to
  `didEnterBackground`/`willEnterForeground`.
- **KVC into private setters** (`:345-346`) now checks `responds(to:)` and
  falls back to `perPageContentInsets`, so an SDK that drops them degrades
  instead of raising an uncatchable `NSUnknownKeyException` on every render.
- The offscreen web view is remade when its host window has gone away.

### 7. Scripts

- `release.sh` bumped `Info.plist` before the build with no revert
  (`:109-115`); a failed build or notarization left a dirty tree the next
  run's preflight refused. A trap restores the plist until the release commit.
- `release-ios.sh` installed its `project.yml` restore trap only under
  `--no-upload` (`:218-223`); in upload mode an archive failure left the spec
  edited. The trap is armed in every mode and disarmed after the upload.
- `release-ios.sh` created ordinary GitHub releases (`:308-311`), which could
  become "Latest" and break `…/releases/latest/download/Glassine.zip`, the Mac
  app's stable download URL (Codex). Now `--latest=false`.
- `build.sh --notarize` never read the notarization verdict (`:113-116`); an
  `Invalid` only surfaced as stapler's "no ticket" after the zip was deleted.
  The status is parsed and Apple's log fetched on anything but `Accepted`.
- `make-icon.sh`: under `set -e` a non-zero `actool` exit inside the
  `ACTOOL_LOG=$(…)` assignment killed the script before the log was printed
  (`:131-142`).
- `release-ios.sh:117` under-counted dirty paths by one (`wc -l` on
  `printf '%s'`); `xcodegen` is found with `command -v` before falling back to
  the Apple-Silicon Homebrew path.

---

## Verified but not changed (recommendations)

Ordered by how much they are likely to matter.

1. **Automatic Reader Mode analysis is sequential over every page** before
   anything is applied (`ReaderModeController.swift:190-203`, `:222`;
   `ReaderContentBounds.swift:79-94` scans 1.44 M pixels per page in a scalar
   loop). A 2,000-page book shows "Preparing…" for minutes. Analyse visible
   pages first and apply progressively (unanalysed pages already fall back to
   the full box), bound concurrency with a `TaskGroup`, and lower the
   detection raster or use vImage.
2. **`savedHighlights` walks every page's annotations on the main thread** at
   window construction (`HighlightsViewController.swift:103`, `:110`) and on
   every File-menu validation (`GlassineDocument.swift:574`). Cache a
   `hasHighlights` flag on the document and defer the first table refresh
   until the pane is shown.
3. **Sidebar outline sync rebuilds the whole row table every 50 ms** while
   scrolling (`SidebarViewController.swift:308-341`); cache ordinals per
   visible row and drop the duplicate synchronous call in `pageChanged()`.
4. **iOS tall-page crop uses text bounds only** (`MarkdownRendererIOS.swift:
   499-517`): a document past the 14,400 pt ceiling whose last sheet ends in an
   image loses the part of the image below the last text line plus 77 pt.
   Needs an ink-bounds measure; left alone rather than guessed at.
5. **iOS Pages-layout export carries the "ghost" heading copies** the
   keep-with-next hack leaves below the printable band (`DocumentSession.swift:
   132-135`); the reader filters them from find but a recipient's Preview will
   see them in search. Render exports without the carry-over, or strip the
   ghost text post-render.
6. **`Prefs.resolvedURL` and the recents seed probe the file system on the
   main thread** (`RecentsModel.swift:31-40`, `AppDelegate.swift:374-382`) on
   every Recents/start-tab appearance; a recent file on a disconnected share
   stalls the UI. Resolve off-main and apply rows on completion.
7. **`ImageInliner` re-reads and re-encodes every image on every save**
   with no document-wide budget (`MarkdownHTML.swift:393-409`); an image-heavy
   memo can produce a multi-hundred-MB HTML string per keystroke-save. A
   `(path, mtime, size)` cache and a total budget.
8. **`findControllerCountDidChange` sets two labels per hit**
   (`ReaderWindowController.swift:927-943`); coalesce onto the 150 ms batch.
9. **iOS has no file presenter for PDFs** and `pollDownload` never times out
   or reads the iCloud error key (`DocumentSession.swift:234-243`).
10. **`release-ios.sh` profile check matches by name only** (`:472-477`); an
    expired profile passes preflight and fails after the multi-minute archive.
11. **`KEY_ID` / `ISSUER_ID` are committed** to a public repo
    (`release-ios.sh:40-41`). Not secrets without the `.p8`, but they are its
    two companion identifiers; sourcing them from `~/.private_keys/` would
    narrow exposure.
12. `ReaderPage.matchInk` is a `nonisolated(unsafe)` global read on PDFKit's
    tile threads, correct only by the "iOS writes it once at launch"
    discipline. `RecentsModel.dateText` ignores its `now:` parameter for the
    today/yesterday branches, so the test cannot pin them.

## Checked and found correct

Across the four reviews, specifically verified: render generation guards on
every async hop and `RenderQueue`'s supersede/watchdog/retry/suspend logic;
overlapping sleep reasons; ordered reloads; highlight save before close and
the Don't Save path; encrypted/signed PDF editing and printing gates; original
bounds for output; transactional recents updates; incremental find
highlighting and its batch cap; the CSP for what a CSP can do; heading and
footnote ids cannot carry `"<>&`; the image inliner's `../` traversal guard
and 8 MB cap; the content hash gate uses the full `Data` hash; `applyOutline`,
`OutlineSync`, `ReadingAnchor`, `ReadingProgress` bounds and division guards;
every `NotificationCenter` observer removed in `deinit`; all stored closures
capture weakly; the codesign order and flags, Sparkle key preflight, and the
release ordering (tag → release asset → push main); the two appcasts
(`glassine-appcast.xml` is live, `appcast.xml` is Folio's frozen feed by
design).

## Testing

- Core: 169 tests pass (161 before; 8 new).
- macOS: 94 tests pass (93 before; 1 new), serialized, three consecutive runs.
- iOS: compiled for a generic iOS device (no signing); not run on a device or
  simulator — none is installed on this Mac. The iOS changes are the ones most
  worth a TestFlight pass: open, rename in Files, lock/unlock, background,
  export after a layout change.
- Not covered by automated tests: the WebKit navigation policy on either
  platform (needs a live web view), the quit-review flag, and the iOS fixes.
