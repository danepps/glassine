# Glassine code review — 2026-11-24

Reviewed `main` at [`10a00da12031b5050989d1cb1ccbd8e218c96c10`](https://github.com/danepps/glassine/tree/10a00da12031b5050989d1cb1ccbd8e218c96c10) (macOS v1.11.1). This is a findings-only review; no application code was changed.

## Assessment and limits

There are actionable lifecycle, input-validation, export, and Markdown-parsing defects below. **This review does not establish which defect caused the reported crashes.** No current crash report, triggering document, platform, or installed version was supplied. In particular, the invalid-preferences trap requires an invalid saved value; it is not evidence that ordinary scrolling produces that value.

This was a repository-wide static review of the macOS app, shared Core, iOS app, Quick Look, packaging/release scripts, and relevant existing tests and historical reviews. The investigation emphasized PDF lifetime, asynchronous callbacks, cancellation, file coordination, rendering, highlights and saves, search, selection, document replacement, and close/unlock behavior. It also covered preferences, recents, Markdown conversion, outline/position logic, export/print, and window/tab ownership.

The execution environment was Linux, with neither Swift nor Xcode. `swift test --package-path Core` failed with `swift: command not found`; neither the Core nor the app/UI tests ran. Core itself imports PDFKit and CoreGraphics, so installing Linux Swift alone would not enable those suites. All native reproductions below are **proposed regression tests, not tests run in this review**. “Source-confirmed” means the erroneous state transition or operation follows from the source; it does not mean an end-to-end crash was reproduced.

Severity: P1 = high-impact hang requiring prompt attention; P2 = correctness or lifecycle bug to fix. The coordination finding's native manifestation remains to be reproduced. Line links throughout are pinned to the reviewed commit.

## Findings

### F1 — [P2] Invalid saved positions can trap while opening a document or populating Recents

**Location:** [`Prefs.swift:313–316`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/Prefs.swift#L313). **Platforms:** macOS and iOS. **Evidence:** source-confirmed trapping conversion.

`lastPosition(for:)` checks the stored array's type and length, then converts `raw[0]` with `Int(raw[0])`. A finite out-of-range value such as `1e30`, NaN, or infinity traps in Swift; it does not return nil. This runs during reader construction and through `RecentsModel.detailText`, so one bad preference entry can also crash the picker before the user opens that file. The position's x/y coordinates are likewise accepted without finite-value checks and later passed to PDFKit.

**Regression:** use an isolated `UserDefaults` suite, assign it to `Prefs.defaults`, and set `lastPositions` to `[url.path: [1e30, 0.0, 0.0]]`. Call `Prefs.lastPosition(for: url)` in a subprocess: the current conversion traps. After fixing, test out-of-range, nonfinite, negative, fractional, truncated-array, and valid legacy entries, expecting invalid entries to return nil. Do not modify the user's real defaults to test this.

**Fix:** decode defensively, using a failable conversion such as `Int(exactly:)`, requiring a nonnegative index and finite coordinates. Reject the individual entry rather than the entire position table. Keep the existing document-page-count checks at restoration. There is no evidence here that the app's normal position writer generates an out-of-range page number.

### F2 — [P1] iOS coordinates reads synchronously on the same queue needed by file presenters

**Locations:** [`DocumentSession.swift:302–315`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/DocumentSession.swift#L302), [`434–441`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/DocumentSession.swift#L434), and [`1146–1149`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/DocumentSession.swift#L1146). **Evidence:** blocking operations and queue ownership confirmed in source; the deadlock schedule needs a native test.

`DocumentSession` is main-actor isolated. Both opening paths call synchronous `NSFileCoordinator.coordinate` there, while every `DocumentFilePresenter` uses `OperationQueue.main`. The app supports multiple scenes showing the same file. An external coordinated writer/mover can be waiting for a presenter callback on main when another scene starts a coordinated read. That read blocks main waiting for the writer, and the writer cannot finish until main services the presenter. This is a circular wait, not merely expensive PDF rendering. Even without that interleaving, a slow file provider blocks the entire UI during the read; iOS may eventually terminate an unresponsive app.

**Regression:** on iPad/simulator, keep a file open in scene A, coordinate a write/move from a worker or companion process, and open the same file in scene B while the presenter callback is pending. Use barriers and a test-process timeout rather than hoping to hit the race with repeated taps. Capture a hang sample showing main inside coordination and the writer awaiting presentation work. Also test a deliberately delayed provider read and require UI responsiveness.

**Fix:** perform coordinated reading and Markdown conversion on a worker, carry owned bytes/value results back to main, and install only if the session's open generation is still current. Keep security-scoped access alive until work finishes. Alternatively, move presenter operations to a dedicated serial queue with properly synchronized URL state and asynchronous delivery to main; do not leave the same queue both blocking on coordination and required to unblock it.

### F3 — [P2] Closing a search does not cancel the query waiting behind it

**Location:** [`FindController.swift:199–203`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/FindController.swift#L199), with the pending-query timer at [`171–196`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/FindController.swift#L171). **Platforms:** both. **Evidence:** source-confirmed state-machine defect; resulting native crash not demonstrated.

Both close handlers use `cancelIfFinding()`. That method cancels PDFKit's current work but does not clear `pendingQuery`, retire `cancellationToken`, clear `isAwaitingCancelledFindEnd`, or prevent subsequent result delivery. If query A has been cancelled to queue B, closing leaves B eligible to start from either A's end callback or the 0.5-second fallback. This occurs if the controller and document survive close long enough for delivery; weak captures only help after deallocation. On macOS the view has already had its document detached in `windowWillClose`, so this also permits find/UI callbacks after teardown.

**Deterministic regression using the existing `ProbeDocument` test helper:**

```swift
let document = makeProbeDocument()
let controller = FindController(document: document)
controller.startFind("alpha")
controller.startFind("beta")
controller.cancelIfFinding()             // the close path
controller.findDidEnd(in: document)      // cancelled alpha finishes
#expect(document.started == ["alpha"])  // current code also starts beta
```

Add a separate test with no end callback and wait beyond the fallback; it must also leave only `alpha` started. Test that late hits cannot navigate or update a closed view.

**Fix:** provide a terminal stop/reset operation that clears pending work and invalidates timers **before** calling PDFKit cancellation, detaches the searched document/delegate as appropriate, and ignores late results. Use it on close. `reset(for: nil)` supplies much of the needed behavior, but review reentrant cancellation delivery when deciding the order.

### F4 — [P2] A closed Mac Markdown document still reacts to typography preferences

**Location:** [`GlassineDocument.swift:414–445`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Sources/Glassine/GlassineDocument.swift#L414). **Evidence:** source-confirmed, conditional on the document remaining retained after close.

`close()` invalidates the current render generation and stops reloads, but leaves the preferences observer registered until `deinit`. `prefsChanged()` has no closed-state check and starts a fresh render, which increments the generation again. Thus the guard that discards a pre-close completion does not protect against work newly requested after close. A document retained by another operation or caller can resume typesetting, install a PDF, or present an initial-render error after its window has closed.

**Regression:** retain a Markdown `GlassineDocument`, inject a recording `MarkdownTypesetter` as the existing refresh tests do, create its window controllers, close it, and change `Prefs.markdownFontSize` in an isolated suite. Assert that the typesetter receives no additional jobs. Complete earlier jobs too and assert no replacement notification or error presentation. The existing `closeDuringSleep` test covers an old completion, not a new preferences-triggered job.

**Fix:** unregister preferences on close and guard all new work with explicit lifecycle state. If reopening the same instance is supported, rearm that state and observation at the documented reopening boundary.

### F5 — [P2] Closing an iCloud download does not stop its polling or eventual load

**Locations:** [`DocumentSession.swift:260–291`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/DocumentSession.swift#L260) and [`392–417`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/DocumentSession.swift#L392). **Evidence:** source-confirmed, conditional on the session remaining retained after close.

The poll stops only when its weak session disappears or `phase != .downloading`. `close()` does not change `phase`, clear the download deadline, or invalidate a polling generation. If the session is still alive when the file arrives, the poll calls `load()` after security-scoped access has been stopped. A successful load can register a new file presenter/watcher or start a new Markdown render on the closed session; an unsuccessful one can mutate its failure state after closure. Invalidating the previous render generation does not prevent this new load.

**Regression:** retain a session while its resource-status seam reports `.notDownloaded`, close it, then report `.current` and advance the polling callback. Require no read, presenter registration, render, or Recents update. Also verify that polling stops if the file stays unavailable. Use an injected status/scheduler seam so this test does not depend on live iCloud timing.

**Fix:** make close terminal for polling/opening, invalidate its generation, and check lifecycle state before resource reads and before `load()`. Deallocation is not a substitute for cancellation.

### F6 — [P2] Same-named Markdown exports overwrite one another across iPad windows

**Location:** [`DocumentSession.swift:742–747`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/DocumentSession.swift#L742); the picker consumes that URL in [`ExportPicker.swift:25–27`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/ExportPicker.swift#L25). **Evidence:** source-confirmed path collision; picker timing needs device verification.

Every export writes to `<temporaryDirectory>/<title>.pdf`. Two documents named `Notes.md` in different directories therefore return the same URL. The `isExporting` flag is per `ReaderView` and is cleared before the picker finishes. The global render queue serializes rendering, but does not isolate files still being consumed by earlier pickers. Export B overwrites the source handed to export A; depending on when the picker reads it, A can export B's content instead. Non-atomic writes also allow a consumer to encounter a partial replacement.

**Regression:** open two `Notes.md` files containing different markers in separate iPad windows. Export A and leave its picker open; export B. Assert the returned URLs differ and the bytes at A's URL remain A's after B completes. Then finish both pickers and verify the destination contents. No concurrent renderer execution is necessary to hit the path collision.

**Fix:** allocate a UUID directory per export and put the human-readable `<title>.pdf` inside it. Write atomically, keep that directory alive until its picker finishes/cancels, and clean it up at that point.

### F7 — [P2] Footnote extraction consumes following block headings as note text

**Location:** [`MarkdownFootnotes.swift:105–114`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/MarkdownFootnotes.swift#L105). **Platforms:** both apps and Quick Look. **Evidence:** source-confirmed extraction logic.

The definition collector treats every nonblank, unindented line other than another footnote definition as lazy continuation. It does not stop for an unindented heading, fence, thematic break, or other block that interrupts a paragraph. Those lines are removed from the document body before cmark can parse them. With an unreferenced note they disappear completely; with a referenced note they move to the endnotes, and a swallowed heading is absent from the main outline.

**Minimal input:**

```markdown
Intro.

[^unused]: A note.
# Actual section
This belongs in the document body.
```

The current collector puts the last three lines into the unused definition. `MarkdownHTML.body` renders only referenced definitions, so the section and its paragraph are lost. A heading can interrupt a paragraph without a blank line; treating it as an ordinary lazy continuation changes the document's structure.

**Regression:** check that the section remains in both HTML and `headings`, with and without a reference to the note. Add cases for fences/lists/block quotes and retain coverage for legitimate lazy paragraph continuation and explicitly indented note blocks.

**Fix:** make continuation block-aware, ideally using parser-recognized source/block boundaries. A simple requirement for a blank line would still mishandle legitimate Markdown and would not preserve the intended lazy-continuation feature.

## Crash leads requiring native evidence

These are investigation targets, **not additional confirmed crash findings**:

1. **iOS PDF backing bytes can change after the coordinated read.** `load()` constructs `PDFDocument(url:)` inside a read-coordination block, but PDFKit lazily reads after that block ends. The PDF presenter ignores content changes. A security scope grants access; it does not freeze bytes or maintain coordination. Test an in-place truncate/rewrite of a displayed PDF while scrolling/searching unvisited pages. Compare with the Mac's owned `Data` load in `GlassineDocument.read`. A crash stack or corrupted-page reproduction is needed before attributing the reported crashes to this path.
2. **Mac print teardown does not wait for the printing worker.** `WebKitHTMLPrinter.teardown()` clears `activeOperation`, drops the view/window and discards output while `runModal` may still be executing on a secondary print thread. Generation/operation identity guards prevent stale delivery, but do not establish that the old worker has stopped using its host. Exercise sleep/wake and watchdog teardown during an actual long print; inspect AppKit/WebKit stacks and object lifetimes. The framework may retain the required objects itself, so a use-after-free is not established by this code alone.
3. **The new link hit-test builds whole-page character geometry on first click.** `ReaderPDFView.mouseDown` calls `textLink` for ordinary unmodified clicks, and `TextLinkGeometry.linkCharacterIndex` obtains `ReaderPage.textMap` before determining whether the text is a URL. That cache makes a PDFKit selection for each non-line-break UTF-16 unit on the entire page. Profile a long continuous Markdown page and a dense OCR page, including after live reload invalidates page identity. This could explain a click-time beachball or memory spike; it is not yet a measured performance regression.
4. **Locked-document thumbnail transitions remain worth stress testing.** The Mac contains a deferred thumbnail-attachment workaround for a historically reproduced unlock crash. The iOS thumbnail representable has no equivalent locked-document guard, and Mac replacement assigns the new document before asking the sidebar to update attachment. Test both rather than assuming a framework failure reproduced on one platform occurs on the other.

For the user's crash, collect the installed app version/build, OS version, operation immediately before exit, exception/termination reason, and the crashing-thread stack (or a hang sample if the app was force-quit). On macOS, Glassine `.ips` reports are normally in `~/Library/Logs/DiagnosticReports/`. A Swift conversion trap, a main-thread file-coordination wait/watchdog termination, and a PDFKit/WebKit bad access require different fixes. Redact private document paths before posting a report publicly.

## Validation and coverage gaps

- `zsh -n` passed for `build.sh`, `build-ios.sh`, `release.sh`, `release-ios.sh`, and `scripts/make-icon.sh`. No build, signing, release, or upload commands were executed.
- Python `plistlib`/XML parsing passed for the Mac and iOS Info plists, Quick Look entitlements, iOS privacy manifest, and both appcasts.
- **Both iOS export-option plists fail strict XML parsing:** `iOS/ExportOptions.plist:7` and `iOS/ExportOptions-local.plist:5` contain `--no-upload` inside XML comments; the latter also contains standalone `--` in comment prose. XML comments cannot contain `--`. Python reports `ExpatError: not well-formed (invalid token)` at those locations. Remove/rephrase the comment text and add `plutil -lint` on a Mac. Whether Apple's more permissive plist reader currently accepts them was not tested; this is a confirmed format defect, not a demonstrated release failure or runtime crash.
- Existing tests cover replacement-document search identities, cancellation fallback tokens, pre-close render completions, live PDF reload, highlight saves, original-bounds printing, and earlier unlock/selection fixes. They do not establish the close-specific state transitions described here. The native regression procedures above still need implementation/execution.
- Historical findings were checked against current source rather than copied forward. Examples already addressed include owned Mac PDF bytes, presenter-queue hopping on Mac moves, the body-plus-notes image budget, asynchronous Recents resolution, incremental Reader Mode analysis, immutable find-highlight ink, the iOS keyboard-selector collision, iCloud timeout/error reporting, and the iOS trailing-image crop fix.
- A passing test process is not sufficient for crash verification: the repository's historical iPad keyboard run passed assertions and still emitted an `.ips` afterward. Native stress runs should also inspect diagnostic attachments and termination events.

## Suggested order

First obtain the current crash stack and reproduce the relevant native path. In parallel, harden saved-position decoding and make close terminal for search/render/download work; those changes have small, deterministic regression cases. Investigate iOS coordination with controlled scheduling, isolate export files, and then fix footnote block boundaries. Keep platform-sensitive fixes in separate changes so each can be validated against its own reproduction.
