# Code review — unreleased work since v1.7.0

_Reviewed 2026-09-14 by Claude (Fable 5.1). Scope: `origin/main` from the
v1.7.0 release record (`f05d035`) through `68b5e0b` "Fix Reader Mode review
findings" — highlight notes and Markdown export, the continuous-Markdown
sidebar and sidebar search field, Reader Mode, Dark Mode Brightness, and the
Recents-only New Tab routing. About 4,400 lines, half of them tests. The iOS
port and the earlier 1.x work were not re-reviewed._

**Overall:** this is careful work. The tricky parts — thread-local suppression
of the virtual art box during serialization, the deferred install for locked
PDFs, the generation tokens on every async hop, the annotation-transform cache
invalidation by bouncing the display box — all hold up on reading, and every
one of them has a regression test. I found no correctness bug that would lose
user data or crash. The findings below are ordered by how much I think they
matter; the first three are worth doing before release, the rest are
judgment calls.

Line numbers refer to the tree at `68b5e0b`.

---

## 1. Print… silently does nothing for a PDF that disallows printing

`Sources/Glassine/ReaderViewController.swift:513` and
`Sources/Glassine/GlassineDocument.swift:534`

`documentForPrinting()` returns `nil` when the PDF is locked or
`allowsPrinting` is false, and `printDocument` then just returns. The Print…
menu item is never validated against that, so ⌘P on a print-restricted PDF
is a dead key with no feedback. (Before this change `PDFView.print(with:)`
was equally silent, so this is not a regression, but the new code path makes
it easy to fix.)

Suggestion: in `GlassineDocument.validateUserInterfaceItem` (line 546) add

```swift
if item.action == #selector(NSDocument.printDocument(_:)) {
    return kind != .pdf || (pdf.map { !$0.isLocked && $0.allowsPrinting } ?? false)
}
```

or, if you would rather keep the item enabled, `NSSound.beep()` on the nil
path so the user learns something happened.

## 2. Reader Mode refits on every layout pass during a live window resize

`Sources/Glassine/ReaderModeController.swift:351` and
`Sources/Glassine/ReaderWindowController.swift:151`

`viewDidLayout` → `viewportDidChange()` → `changeLayout` → the
`preservePosition` closure, which calls `position.beginInstall()`, mutates the
scale, and queues a two-hop `aim` jump — on **every** layout pass whose width
moved more than half a point. During a drag-resize that is dozens of
install/aim cycles a second, each one bumping `jumpGeneration` and cancelling
the previous one's hops. It works (the handoff says the live check passed)
but it is doing far more than it needs to, and on a slow document each
cancelled `layoutDocumentView()` is wasted work that competes with the drag.

Suggestion: skip the refit while `window.inLiveResize` is true and do one
refit from `windowDidEndLiveResize`. Sidebar collapse/expand and split
changes still come through `viewDidLayout` as today.

## 3. `ReaderModeSettings.save` re-decodes every stored document on every slider tick

`Sources/Glassine/ReaderModeSettings.swift:80-115` and
`ReaderModeController.swift:70`

`update(_:)` saves the settings before the coalescing guard, on purpose, so
every continuous-slider tick calls `save(for:)`. `save` then walks the whole
`readerModeDocuments` dictionary — up to 500 entries — JSON-decoding each one
to drop invalid/default entries and build the age table, and writes the
dictionary back. With a full store that is 500 decodes plus a defaults write
per tick.

Suggestion: only do the prune/eviction pass when
`entries.count > maximumStoredDocuments` (the common case then costs one
encode and one defaults write), or run the prune once from `load` rather than
from `save`. Either keeps the "latest settings survive a window close"
property the comment is protecting.

## 4. `deleteHighlight` picks the row to reselect from `table.selectedRow`

`Sources/Glassine/HighlightsViewController.swift:143`

With multiple selection enabled, `selectedRow` is whichever row AppKit
considers the anchor, not necessarily the first selected. After deleting a
non-contiguous multi-selection, `min(row, highlights.count - 1)` can land on
an unrelated highlight. Use `table.selectedRowIndexes.first ?? 0` instead.
Cosmetic, but it is the kind of thing that feels "off" when you notice it.

## 5. Markdown escaping misses setext underlines and thematic breaks in notes

`Core/Sources/GlassineCore/HighlightMarkdown.swift:53`

Highlight text is whitespace-collapsed, so it is always one line and safe.
Notes keep their newlines and are emitted after `**Note:** ` without a
per-line prefix. A note whose second line is `---` (or `===`) turns the first
line into a setext heading; a line starting with four spaces becomes a code
block. `-` is not in the escape set, only `- ` at the line start.

Two ways to close it: (a) render the note as a blockquote too, prefixing each
line with `> ` — a thematic break inside a blockquote is still a break, but a
setext underline after a `> ` paragraph line is much rarer; or (b) in
`escape`, also backslash a line that consists solely of `-`, `=`, `*` or `_`
characters (with optional spaces) and strip leading runs of 4+ spaces. (b) is
three lines. Add a Core test for a note of `"Key point\n---"`.

While there: the escape set backslashes `#`, `_`, `~` and `|` mid-word, so an
exported quote reads `Section \#4` / `snake\_case` in the raw file. Every
renderer handles it, but if you ever hand these files to someone who reads
raw Markdown, restricting `#` to line-start and `_`/`*` to word boundaries
would make the output friendlier. Optional.

## 6. Notes sheet is presented from the sidebar view controller

`Sources/Glassine/HighlightsViewController.swift:165`

`editNote(for:)` calls `presentAsSheet(editor)` on `HighlightsViewController`,
whose view lives inside the collapsible split item. The PDF context menu
("Add Note…") routes here via `onEditHighlightNote`, so the sheet can be
requested while the sidebar is collapsed. A collapsed `NSSplitViewItem` keeps
its view in the hierarchy (hidden, zero width), so `view.window` is non-nil
and this should work — but I could not confirm the handoff's live check
covered the collapsed case. Worth one manual check: collapse the sidebar,
right-click a highlight, Add Note…. If it fails, present from
`ReaderWindowController.contentViewController` instead.

## 7. Smaller things

- **`ReaderPage.withOriginalBounds` is thread-dictionary based**
  (`Core/.../ReaderPage.swift:49`). Correct for the current callers, all of
  which serialize synchronously on the calling thread. If a future caller
  serializes on a background queue or via a PDFKit API that spawns its own
  workers (`PDFDocument.write(to:withOptions:)` does not, as far as I know,
  but `printOperation` does — which is exactly why `documentForPrinting`
  copies first), the guard will silently not apply. A one-line comment
  listing that constraint next to the function would save the next person a
  debugging session.
- **`documentForPrinting` copies the whole PDF for every ordinary print**
  (`GlassineDocument.swift:534`). Fine for articles; for a 300 MB scanned
  book this doubles memory for the duration of the print dialog. If it
  becomes a complaint, the alternative is to clear `readerContentBounds` and
  `findHighlights` on the live pages for the duration of the print instead of
  copying. Not worth doing pre-emptively.
- **`ReaderContentBounds.detect` pixel loop** (`ReaderContentBounds.swift:79`)
  scans all 1.44 M pixels even after the bounding box is known. Scanning rows
  top-down until the first ink row, bottom-up until the last, then only the
  columns inside those rows would cut the typical page to a fraction. Only
  matters on long documents; the scan is already off the main thread.
- **`HighlightMarkdown.render` assumes its input is sorted by page**
  (`HighlightMarkdown.swift:34`). It is, today — `savedHighlights` builds it
  page by page and the sidebar passes rows in table order. A `precondition`
  or a sort inside `render` would make the Core API self-sufficient.
- **`StartTabWindowController.presentFromCurrentContext`**
  (`StartTabWindowController.swift:24`) builds
  `[keyWindow, mainWindow] + orderedWindows` and takes the first that can
  host a tab. `orderedWindows` is front-to-back, so this is right; just
  noting that the array can contain the same window three times and
  `first(where:)` makes that harmless.
- **`DarkModeBrightnessMenuView`** re-reads the preference in
  `viewDidMoveToWindow`, which is the right hook for menu item views. Nothing
  wrong; I checked because custom menu views are a classic source of stale
  state.
- **Rotation mapping in `customBounds(in:rotation:)`**
  (`ReaderModeSettings.swift:131`) — I worked the 90/180/270 cases by hand
  and they are correct for PDF's clockwise `/Rotate`. Good that the tests
  cover it.

## 8. Things I looked for and did not find

- A path where the initial position restore is lost when Reader Mode's
  automatic scan finishes mid-restore. `targetForInstall(initial: false)`
  returns `lastInstallTarget` while `restoreFinished` is false, and
  `restoreIfNeeded` seeds `lastInstallTarget` with `saved` before the jump, so
  the reader-mode `aim` re-targets the same position. Fine.
- Any serialization path that bypasses `withOriginalBounds`. All three
  (`data(ofType:)`, the export fallback, the print copy) are guarded; the iOS
  app never sets `readerContentBounds`.
- Retain cycles in the new closures. Every `preservePosition`,
  `onPreparationChanged`, `onViewportSizeChange` and note-editor closure is
  `[weak self]`; the undo registration captures the annotation strongly,
  which matches the existing highlight undo pattern.
- A way for the Markdown export to include stale page identities after a
  revert. The snapshot is taken before the save panel opens, as the comment
  says.

## 9. Housekeeping

- `HANDOFF.md` is now long enough (2,400+ lines) that "State" reads
  newest-first for 1,000 lines before the reference material starts. Consider
  moving anything older than the last release into a `HANDOFF-archive.md`.
- The four unreleased feature blocks in the handoff each end with "no release
  was performed." Once this ships, collapse them into one 1.8.0 entry; the
  per-feature validation logs under `build/` are not in git anyway.
- Remote branches: eleven on GitHub as of this review, and only `main`
  matters. Eight are fully merged into `main` (`blur`, `glassine`,
  `icon-onionskin`, `icon-production`, `markdown`, `progress`, `recents`,
  `start-tab`). Two are unmerged 2026-09-05 icon-concept experiments from
  cloud sessions, superseded by the `icon-production` work that shipped:
  `claude/app-name-alternatives-51sx0s` (`0449851`, adds
  `scripts/make-glassine-icon-concepts.swift`) and
  `claude/icon-concepts-new-name-42nyuq` (`4cdee69`, extends
  `make-icon-concepts.swift`). A git bundle of all ten is at
  `build/pruned-branches-2026-09-14.bundle` on the Mac that ran this review
  (`build/` is gitignored); `git bundle unbundle` restores any of them. The
  deletion itself needs a human: run

  ```
  git push origin --delete blur glassine icon-onionskin icon-production markdown progress recents start-tab claude/app-name-alternatives-51sx0s claude/icon-concepts-new-name-42nyuq
  ```

## 10. Verification

Both suites were run on this machine against `68b5e0b` before writing this:
`swift test --package-path Core` — 145 tests in 17 suites passed;
root `swift test` — 70 tests in 10 suites passed.
