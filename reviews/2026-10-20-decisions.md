# Code review 2026-10-20 — items left for Dan to decide

_Companion to `2026-10-20-code-review.md`. These are the findings I verified
but deliberately did not change on `code-review-2026-10-20`, because each one
is a design or priority call rather than a bug with one right answer. For each:
what the code does today, why it matters, the options, the cost, and my
recommendation. Line numbers refer to the branch tip._

---

## 1. Automatic Reader Mode analyses every page before trimming any

**Today.** `ReaderModeController.prepare()` snapshots every page on the main
thread (`Sources/Glassine/ReaderModeController.swift:181-186`, which calls
`page.annotations` per page), then one detached task rasterises each page at up
to 1200 px and `ReaderContentBounds.detect` scans every pixel in a scalar
Swift loop (`ReaderContentBounds.swift:60-94`). `apply()` refuses to trim
anything until `contentBounds?.count == pdf.pageCount` (`:222`), so a 2,000-page
scan shows "Preparing…" for minutes with nothing trimmed.

**Why it matters.** Reader Mode is the feature for long reading sessions, and
long documents are exactly where it stalls. For the 20–300 page articles and
briefs Glassine mostly opens, it is fine today.

**Options.**
- *A. Progressive apply.* Analyse the visible pages and their neighbours
  first, apply as results arrive, and treat unanalysed pages as `nil` (the
  code already falls back to the full box for `nil`). Removes the
  all-or-nothing gate; the reader sees trimming within a second. Medium
  effort: the gate at `:222` and the ordering of `contentBounds` need a
  per-page "known / unknown" state, and `apply()` must be re-entrant.
- *B. Faster detection.* Lower the raster cap (300–400 px is enough to find a
  margin), or replace the per-pixel loop with vImage min/max per row and
  column. Low–medium effort, 5–10× faster, still sequential.
- *C. Parallel detection.* A `TaskGroup` over pages, bounded to core count.
  Low effort on top of A or B; CoreGraphics PDF drawing is thread-safe per
  `CGPDFPage`.
- *D. Leave it.* Document the limitation.

**Recommendation.** A plus B. B is cheap and makes everything else better;
A is what turns "unusable on a book" into "usable". C is a follow-on if A+B are
not enough. Worth doing before Reader Mode is promoted in release notes again.

## 2. `savedHighlights` walks every page's annotations on the main thread

**Today.** `GlassineDocument.savedHighlights` (`Sources/Glassine/PDFHighlights.swift:84-103`)
iterates all pages and reads `page.annotations`; results are cached per page
object, but the first pass is a full walk. It is called from
`HighlightsViewController.refresh()` during window construction
(`HighlightsViewController.swift:103`, `:110`) and from
`validateUserInterfaceItem` on every File-menu validation
(`GlassineDocument.swift`, the `exportHighlightsAsMarkdown` case).

**Why it matters.** On a 3,000-page scanned PDF, PDFKit materialises every
page's annotation array before the window appears, and again (cheaper, but
still O(pages)) each time a menu opens. For typical documents it is
imperceptible.

**Options.**
- *A. Lazy first pass.* Skip the sidebar's initial `refresh()` until the
  Highlights pane is actually shown or the document posts a highlight change.
  Low effort; the pane is hidden by default.
- *B. Cached flag for validation.* Keep a `hasHighlights: Bool?` on the
  document, computed once and invalidated in `setHighlights` /
  `removeHighlights` / revert, so menu validation never walks pages. Low
  effort.
- *C. Compute off-main.* Larger change; PDFKit annotation access off the main
  thread is a grey area. Not recommended.

**Recommendation.** A and B together, about an hour. No behaviour change
visible to the user, strictly a large-document win.

## 3. Sidebar outline sync rebuilds the whole row table every 50 ms

**Today.** `SidebarViewController.syncSelection()`
(`Sources/Glassine/SidebarViewController.swift:308-341`) maps every row of the
outline view to an `OutlineEntry`, calling `OutlineSync.destination(of:)`,
`target.page` and `OutlineSync.ordinal(...)` per row, each time it runs. It runs
on the 50 ms scroll debounce (`ReaderWindowController.scrollGeometryChanged`)
and synchronously on every page change (`pageChanged()`), and the outline is
fully expanded at load.

**Why it matters.** With a few hundred bookmarks it is free. A reference work
with thousands of bookmarks and the Contents pane open pays it on every scroll
tick, and the duplicate call from `pageChanged()` is wasted work.

**Options.**
- *A. Cache ordinals per row.* Store `[OutlineSync.Ordinal?]` keyed by row,
  invalidate in `documentDidChange` and in the outline view's
  expand/collapse delegate callbacks. Low–medium effort.
- *B. Drop the direct `pageChanged()` call.* The debounced path already
  covers it. Trivial, but the test "Continuous Markdown sidebar" may depend
  on the synchronous update after a page jump; run it.
- *C. Leave it.*

**Recommendation.** A, with B only if the sidebar tests stay green. Low
priority unless you open large bookmarked PDFs with the Contents pane shown.

## 4. iOS tall-page crop measures text only

**Today.** When a continuous Markdown render exceeds CoreGraphics' 14,400 pt
page ceiling, iOS falls back to paginated sheets and crops the last sheet to
the lowest line of *text* plus 77 pt (`iOS/Sources/MarkdownRendererIOS.swift`,
`trimTrailingBlank`). Image pixels are not part of any `PDFSelection`, so a
document that ends with a diagram or photo below its last paragraph loses the
part of that image more than 77 pt below the text.

**Why it matters.** Only for continuous-layout Markdown longer than ~18
Letter pages *and* ending in an image. Rare, but silent and surprising when it
happens.

**Options.**
- *A. Ink bounds.* Render the last sheet to a small bitmap (the Reader Mode
  detector already has this code in `ReaderContentBounds`, but it lives in the
  Mac target) and crop to the ink. Medium effort; moving or duplicating the
  detector into Core.
- *B. Include image annotations' bounds.* Not available: WebKit's print path
  does not leave image annotations.
- *C. Be conservative.* If the page has any `PDFAnnotation` or the measured
  heading list says content continues past the text, keep the whole sheet.
  Low effort, but reintroduces the 12,000 pt blank tail the crop exists to
  remove, in those cases.
- *D. Leave it.*

**Recommendation.** D for now, A when Core gets a shared ink-bounds routine
(which Reader Mode on iOS would need anyway).

## 5. iOS Pages-layout exports carry "ghost" heading copies

**Today.** The keep-with-next CSS hack leaves a clipped copy of each
carried-over heading below the printable band on the page it left. The reader
filters those out of find results (`DocumentSession.isGhost`), but an exported
or printed PDF still contains them; Preview, Acrobat or a recipient's search
will see each such heading twice. The Mac does not have this problem because
`WKPrintingView` does not produce the ghosts.

**Options.**
- *A. Export without the hack.* Render exports with a stylesheet variant that
  drops the `margin-bottom: -72pt` carry-over, accepting an occasional heading
  orphaned at the bottom of a page in exports only. Low effort
  (`MarkdownStyling.paginated` already exists as a variant hook).
- *B. Strip post-render.* Remove text below the printable band from the PDF
  content stream. Not practical with PDFKit.
- *C. Leave it.*

**Recommendation.** A. Exports are for other people; a visible orphan heading
is an honest flaw, duplicated invisible text is a confusing one.

## 6. Recents resolution and the first-launch seed probe the file system on the main thread

**Today.** `RecentsModel.rows()` calls `Prefs.resolvedURL` per entry
(`Core/Sources/GlassineCore/RecentsModel.swift:31-40`), which does `fileExists`
and possibly bookmark resolution; it runs on every `reload()` of the Recents
window and start tab (`RecentsWindowController.swift:62`, `:75`;
`StartTabWindowController.swift:166`), i.e. each time either becomes key.
`Prefs.seedRecentDocumentsIfNeeded` (`Prefs.swift:375+`) probes up to 30 + 500
paths at first launch.

**Why it matters.** A recent file on a disconnected network share or an
unmounted external drive stalls the UI for the OS timeout every time the
picker appears. (`.withoutMounting` is set on bookmark resolution, which
helps, but `fileExists` on an SMB path can still block.) The seed runs once.

**Options.**
- *A. Resolve off-main.* `rows()` becomes async (or takes a completion),
  resolves on a utility queue, and the view applies the rows when they
  arrive, showing the previous rows meanwhile. Medium effort; touches the Mac
  Recents controller, the start tab, and the iOS `RecentsList`.
- *B. Cache per entry.* Remember the last resolution result for a few
  seconds, so repeated key/resign cycles do not re-probe. Low effort, does
  not fix the first stall.
- *C. Leave it.*

**Recommendation.** A, when convenient. It only bites with network volumes,
but when it bites it looks like a hang.

## 7. The image inliner has no document-wide budget and no cache

**Today.** `ImageInliner` re-reads and base64-encodes every referenced image
(up to 8 MB each, no total cap) every time `body(fromMarkdown:)` runs, which is
every save of the file (`MarkdownHTML.swift`, `ImageInliner`).

**Why it matters.** An image-heavy memo (say, twenty 5 MB screenshots) builds a
~130 MB HTML string per keystroke-save and hands it to WebKit each time. Text
memos are unaffected.

**Options.**
- *A. Total budget.* Stop inlining past, say, 32 MB per document; later images
  keep their `src` and the CSP leaves them blank. Trivial.
- *B. Cache data URIs* keyed by `(path, mtime, size)` across reloads of the
  same document. Low–medium effort; the cache has to live with the document
  (`MarkdownDocumentModel.content`), not in the stateless `MarkdownHTML`.
- *C. Leave it.*

**Recommendation.** A now (one line), B if you ever notice save-to-render
latency on an image-heavy file.

## 8. Smaller items

- **Per-hit label churn.** `findControllerCountDidChange`
  (`ReaderWindowController.swift`) sets two labels and scans the toolbar for
  every match PDFKit reports. Coalescing onto the existing 150 ms highlight
  batch in `FindController` is a 10-line change. Low value unless searches
  with tens of thousands of hits feel sluggish.
- **iOS has no file presenter for PDFs**, so a Files-app rename of an open PDF
  is not followed (the Mac gets this from NSDocument). Mirror the Markdown
  presenter for PDFs: low effort, same pattern.
- **iOS `pollDownload` never times out** and never reads
  `.ubiquitousItemDownloadingErrorKey`; a failed iCloud download spins
  forever at "Downloading…". Add a deadline and surface the error: low effort.
- **`release-ios.sh` profile preflight matches by name only**
  (`release-ios.sh:176-177`). An expired profile or one for another team
  passes and the failure comes after the multi-minute archive. Decode the
  profile to a plist and check `ExpirationDate` and `TeamIdentifier`: low
  effort.
- **`KEY_ID` and `ISSUER_ID` are committed** (`release-ios.sh:40-41`) in a
  public repo. Not secrets without the `.p8`, but they are its companions.
  Reading them from a gitignored `~/.private_keys/glassine.env` narrows
  exposure at the cost of one more thing to set up on a second Mac.
- **`ReaderPage.matchInk`** is a `nonisolated(unsafe)` global that PDFKit's
  tile threads read; correct today only because iOS writes it once at launch.
  A `let` plus an iOS-side pre-filter parameter would remove the race surface.
- **`RecentsModel.dateText` ignores its `now:` parameter** for the
  today/yesterday branches, so the test cannot pin them. Pass `now` through to
  `Calendar.isDate(_:inSameDayAs:)`: trivial, test-only benefit.

---

## If you only do three

1. Reader Mode progressive apply plus a cheaper detector (item 1).
2. Lazy `savedHighlights` with a cached flag (item 2).
3. The image-inlining budget (item 7A), because it is one line.
