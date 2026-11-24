# Glassine code review — 2026-11-24

Reviewed `main` at [`10a00da12031b5050989d1cb1ccbd8e218c96c10`](https://github.com/danepps/glassine/tree/10a00da12031b5050989d1cb1ccbd8e218c96c10) (macOS v1.11.1). This is a findings-only review; no application code was changed.

**Updated after a second pass by six independent specialist reviewers.** F8–F22 are additional findings. The original findings were challenged as well: F2's claimed circular deadlock was not established and has been corrected; F3 now distinguishes closing a document from clearing search; F4 has a concrete export-retention path; F5 remains conditional hardening; and F7 is explicitly a GitHub/CommonMark compatibility issue. The new crash-relevant priorities are F8 (a documented iOS termination risk) and F9 (quadratic parsing work), not a claim that either caused the user's crashes.

## Assessment and limits

There are actionable lifecycle, input-validation, export, and Markdown-parsing defects below. **This review does not establish which defect caused the reported crashes.** No current crash report, triggering document, platform, or installed version was supplied. In particular, the invalid-preferences trap requires an invalid saved value; it is not evidence that ordinary scrolling produces that value.

This was a repository-wide static review of the macOS app, shared Core, iOS app, Quick Look, packaging/release scripts, and relevant existing tests and historical reviews. The investigation emphasized PDF lifetime, asynchronous callbacks, cancellation, file coordination, rendering, highlights and saves, search, selection, document replacement, and close/unlock behavior. It also covered preferences, recents, Markdown conversion, outline/position logic, export/print, and window/tab ownership.

The second pass divided that scope among six reviewers: Mac document/window lifecycle; iOS sessions/scenes; rendering and reload queues; search/selection; Markdown/Quick Look/preferences; and an adversarial audit of evidence, framework contracts, and release tooling. Findings were reconciled against the source and existing tests. Agreement between reviewers is not a substitute for a native reproduction.

The execution environment was Linux, with neither Swift nor Xcode. `swift test --package-path Core` failed with `swift: command not found`; neither the Core nor the app/UI tests ran. Core itself imports PDFKit and CoreGraphics, so installing Linux Swift alone would not enable those suites. All native reproductions below are **proposed regression tests, not tests run in this review**. “Source-confirmed” means the erroneous state transition or operation follows from the source; it does not mean an end-to-end crash was reproduced.

Severity: P1 = high-impact termination/responsiveness risk requiring prompt investigation; P2 = correctness or lifecycle bug to fix; P3 = lower-priority resource cleanup. Severity is distinct from confidence: source evidence, documented framework behavior, and unexecuted native reproductions are identified separately. Line links throughout are pinned to the reviewed commit.

## Findings

### F1 — [P2] Invalid saved positions can trap while opening a document or populating Recents

**Location:** [`Prefs.swift:313–316`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/Prefs.swift#L313). **Platforms:** macOS and iOS. **Evidence:** source-confirmed trapping conversion.

`lastPosition(for:)` checks the stored array's type and length, then converts `raw[0]` with `Int(raw[0])`. A finite out-of-range value such as `1e30`, NaN, or infinity traps in Swift; it does not return nil. This runs during reader construction and through `RecentsModel.detailText`, so one bad preference entry can also crash the picker before the user opens that file. The position's x/y coordinates are likewise accepted without finite-value checks and later passed to PDFKit.

**Regression:** use an isolated `UserDefaults` suite, assign it to `Prefs.defaults`, and set `lastPositions` to `[url.path: [1e30, 0.0, 0.0]]`. Call `Prefs.lastPosition(for: url)` in a subprocess: the current conversion traps. After fixing, test out-of-range, nonfinite, negative, fractional, truncated-array, and valid legacy entries, expecting invalid entries to return nil. Do not modify the user's real defaults to test this.

**Fix:** decode defensively, using a failable conversion such as `Int(exactly:)`, requiring a nonnegative index and finite coordinates. Reject the individual entry rather than the entire position table. Keep the existing document-page-count checks at restoration. There is no evidence here that the app's normal position writer generates an out-of-range page number.

### F2 — [P2] iOS performs blocking file coordination and Markdown conversion on main

**Locations:** [`DocumentSession.swift:302–315`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/DocumentSession.swift#L302), [`434–441`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/DocumentSession.swift#L434), and [`1146–1169`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/DocumentSession.swift#L1146). **Evidence:** blocking operations and main-actor ownership confirmed; native hang duration and termination unmeasured.

`DocumentSession` is main-actor isolated. Both opening paths call synchronous `NSFileCoordinator.coordinate` there. The PDF path constructs the document in the coordinated block; the Markdown path reads all bytes there and then converts them to HTML on main. A slow file provider or a competing coordinated writer therefore prevents UI processing for the duration of the read. Expensive Markdown conversion adds to that interval; F9 provides a specific input that makes it especially expensive.

**Second-pass correction:** the first version of this report asserted a circular wait between main and a writer. `DocumentFilePresenter` uses `OperationQueue.main`, but implements only change/move notifications, not relinquish/save callbacks. The source does not establish that a writer waits for those particular notifications before releasing its access. The exact deadlock schedule is **unproven** and is not the basis for this finding. F8 is a separate, documented background-presenter problem.

**Regression:** hold a coordinated write from a worker/companion process, then open that file in Glassine while a UI responsiveness probe runs. Release the writer from the worker after a controlled delay and verify that opening eventually completes. Also use a deliberately delayed provider read. Record a main-thread sample rather than labeling every long wait a deadlock. If investigating a circular wait, separately prove which presenter callback the writer is awaiting.

**Fix:** perform coordinated reading and Markdown conversion on a worker, carry owned bytes/value results back to main, and install only if the session's open generation is still current. Keep security-scoped access alive until work finishes. Moving only the presenter queue would not remove the blocking I/O or conversion from main.

### F3 — [P2] Closing a document during query replacement leaves the queued find armed

**Location:** [`FindController.swift:199–203`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/FindController.swift#L199), with the pending-query timer at [`171–196`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/FindController.swift#L171). **Platforms:** both. **Evidence:** source-confirmed state-machine defect; resulting native crash not demonstrated.

Both close handlers use `cancelIfFinding()`. That method cancels PDFKit's current work but does not clear `pendingQuery`, retire `cancellationToken`, clear `isAwaitingCancelledFindEnd`, or prevent subsequent result delivery. If query A has been cancelled to queue B, closing leaves B eligible to start from either A's end callback or the 0.5-second fallback. This occurs if the controller and document survive close long enough for delivery; weak captures only help after deallocation. On macOS the view has already had its document detached in `windowWillClose`, so this also permits find/UI callbacks after teardown.

Clearing/dismissing search itself calls `startFind("")` and does not have this defect. iOS close also disconnects `bridge.findSink`, so its post-close restart route is the fallback timer, not an end callback delivered through that bridge. A normal-app long-lived owner of the closed Mac window controller has not been demonstrated; the retained-controller state transition is deterministic, but a production post-close crash is not.

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

`close()` invalidates the current render generation and stops reloads, but leaves the preferences observer registered until `deinit`. `prefsChanged()` has no closed-state check and starts a fresh render, which increments the generation again. Thus the guard that discards a pre-close completion does not protect against work newly requested after close. A retained document can resume typesetting and install a PDF after its window has closed.

There is a real retention path: [`exportAsPDF`'s completion at lines 528–534](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Sources/Glassine/GlassineDocument.swift#L528) captures `self` strongly, and continuous Markdown export carries that completion through the queued typesetter job at lines 566–574. Start an export, close its reader while the export is queued, and change typography from another window. The export can legitimately finish, but it should not keep the closed reader subscribed to new rendering work. This route already has an installed PDF, so it does not establish a post-close *initial-render* error.

**Regression:** retain a Markdown `GlassineDocument`, inject a recording `MarkdownTypesetter` as the existing refresh tests do, create its window controllers, close it, and change `Prefs.markdownFontSize` in an isolated suite. Assert that the typesetter receives no additional jobs. Complete earlier jobs too and assert no replacement notification or error presentation. The existing `closeDuringSleep` test covers an old completion, not a new preferences-triggered job.

**Fix:** unregister preferences on close and guard all new work with explicit lifecycle state. If reopening the same instance is supported, rearm that state and observation at the documented reopening boundary.

### F5 — [P2] Closing an iCloud download does not stop its polling or eventual load

**Locations:** [`DocumentSession.swift:260–291`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/DocumentSession.swift#L260) and [`392–417`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/DocumentSession.swift#L392). **Evidence:** source-confirmed, conditional on the session remaining retained after close.

The poll stops only when its weak session disappears or `phase != .downloading`. `close()` does not change `phase`, clear the download deadline, or invalidate a polling generation. If the session is still alive when the file arrives, the poll calls `load()` after security-scoped access has been stopped. A successful load can register a new file presenter/watcher or start a new Markdown render on the closed session; an unsuccessful one can mutate its failure state after closure. Invalidating the previous render generation does not prevent this new load.

**Second-pass qualification:** no sustained production owner of a closed, downloading session was proved. `RootView` replaces/clears its session, the poll holds it weakly, and the PDFView command closure does not exist yet during `.downloading`. Treat this as conditional lifecycle hardening, not an established ordinary-user-flow resurrection or a diagnosed crash.

**Regression:** retain a session while its resource-status seam reports `.notDownloaded`, close it, then report `.current` and advance the polling callback. Require no read, presenter registration, render, or Recents update. Also verify that polling stops if the file stays unavailable. Use an injected status/scheduler seam so this test does not depend on live iCloud timing.

**Fix:** make close terminal for polling/opening, invalidate its generation, and check lifecycle state before resource reads and before `load()`. Deallocation is not a substitute for cancellation.

### F6 — [P2] Same-named Markdown exports overwrite one another across iPad windows

**Location:** [`DocumentSession.swift:742–747`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/DocumentSession.swift#L742); the picker consumes that URL in [`ExportPicker.swift:25–27`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/ExportPicker.swift#L25). **Evidence:** source-confirmed path collision; picker timing needs device verification.

Every export writes to `<temporaryDirectory>/<title>.pdf`. Two documents named `Notes.md` in different directories therefore return the same URL. The `isExporting` flag is per `ReaderView` and is cleared before the picker finishes. The global render queue serializes rendering, but does not isolate files still being consumed by earlier pickers. Export B overwrites the source handed to export A; depending on when the picker reads it, A can export B's content instead. Non-atomic writes also allow a consumer to encounter a partial replacement.

**Regression:** open two `Notes.md` files containing different markers in separate iPad windows. Export A and leave its picker open; export B. Assert the returned URLs differ and the bytes at A's URL remain A's after B completes. Then finish both pickers and verify the destination contents. No concurrent renderer execution is necessary to hit the path collision.

**Fix:** allocate a UUID directory per export and put the human-readable `<title>.pdf` inside it. Write atomically, keep that directory alive until its picker finishes/cancels, and clean it up at that point.

### F7 — [P2] Footnote extraction consumes headings that remain body blocks in GitHub-style Markdown

**Location:** [`MarkdownFootnotes.swift:105–114`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/MarkdownFootnotes.swift#L105). **Platforms:** both apps and Quick Look. **Evidence:** source-confirmed extraction logic.

The definition collector treats every nonblank, unindented line other than another footnote definition as lazy continuation. It does not stop for an unindented heading or other interrupting block. Those lines are removed from the document body before cmark can parse them. With an unreferenced note they disappear completely; with a referenced note they move to the endnotes, and a swallowed heading is absent from the main outline. This conflicts with the advertised GitHub-style footnote support; it is not a claim that every Markdown dialect treats this input identically.

**Minimal input:**

```markdown
Intro.

[^unused]: A note.
# Actual section
This belongs in the document body.
```

The current collector puts the last three lines into the unused definition. `MarkdownHTML.body` renders only referenced definitions, so the section and its paragraph are lost. A heading can interrupt a paragraph without a blank line; treating it as an ordinary lazy continuation changes the document's structure.

For a referenced version (`Intro.[^n]`, followed by `[^n]: A note.` and the same heading/body), an executed comparison with Pandoc 3.1.11.1's `gfm` and `commonmark_x` readers produced a note containing only “A note.” followed by a top-level heading and paragraph. Pandoc's default `markdown` reader instead consumed the following lines into the note. This dialect difference is why the finding is scoped to GitHub/CommonMark compatibility. Glassine itself was not executed.

**Regression:** check that the section remains in both HTML and `headings`, with and without a reference to the note. Add cases for fences/lists/block quotes and retain coverage for legitimate lazy paragraph continuation and explicitly indented note blocks.

**Fix:** make continuation block-aware, ideally using parser-recognized source/block boundaries. A simple requirement for a blank line would still mishandle legitimate Markdown and would not preserve the intended lazy-continuation feature.

## Additional findings from the second pass

### F8 — [P1] iOS keeps file presenters registered while the app is backgrounded

**Locations:** [`DocumentSession.swift:334–345`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/DocumentSession.swift#L334), [`601–614`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/DocumentSession.swift#L601), [`806–808`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/DocumentSession.swift#L806), and [`RootView.swift:55–57`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/RootView.swift#L55). **Evidence:** source-confirmed missing lifecycle handling plus an explicit Apple platform requirement; termination not reproduced.

Both PDF and Markdown sessions register a file presenter. Only `close()` and `deinit` remove it. The app-background observer and scene-background handler save reading position but leave the presenter registered. Suspending the Markdown render queue elsewhere does not remove these presenters.

[Apple's NSFileCoordinator documentation](https://developer.apple.com/documentation/foundation/nsfilecoordinator), under “File Presenters and iOS,” states: “If your app or extension enters the background with an active file presenter, it may be terminated by the system in order to prevent deadlock on that file.” Apple directs apps to remove presenters on background and add them again on foreground. This is a stronger crash-investigation lead than the unproved circular wait in the original F2. It does not prove that every background transition terminates Glassine or identify the reported crash.

**Regression:** open an external PDF or Markdown file, background the app, and check that its presenters have been removed. Perform coordinated writes/moves from Files or a companion process while it is backgrounded; foreground it and require exactly one registration per live session, a current URL, and reconciliation of missed changes. Capture device termination diagnostics. Repeat with multiple iPad scenes: one scene entering background while another remains active is different from the entire application entering background.

**Fix:** centralize app-level presenter suspension/resumption, preserve session state, and revalidate files when resuming. Make registration idempotent and ensure close cannot be undone by a later foreground event. Use app-wide lifecycle events for this requirement; unregistering all presenters merely because one scene backgrounds would break the other active scenes.

### F9 — [P1] URL punctuation trimming does quadratic work on a small Markdown file

**Location:** [`MarkdownAutolinks.swift:175–186`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/MarkdownAutolinks.swift#L175). **Platforms:** both apps and Quick Look. **Evidence:** source-confirmed algorithmic complexity; native time, peak memory, and watchdog outcome unmeasured.

For each unmatched trailing `)` or `]`, `trimmedEnd` calls `filter` over the entire remaining address twice to recount its opening and closing brackets, then removes only one scalar. A document containing `https://example.com/` followed by 100,000 closing parentheses is only 100,020 ASCII bytes, but the two filters perform 10,004,100,000 predicate evaluations under the source algorithm. The closing-bracket filters also materialize an aggregate 5,000,050,000 elements across successive temporary arrays; that is cumulative allocation work, **not simultaneous peak memory**.

The app/preview conversion paths both run this rewriter. Quick Look's 2 MiB source cap therefore does not bound the work adequately. Initial iOS Markdown conversion is on main (F2), so this input can monopolize UI processing before the render queue and its watchdog even start. Mac initial reads may run concurrently, but still consume the CPU and delay opening; Quick Look can be delayed independently of Glassine's reader window.

**Regression:** test `MarkdownAutolinker.segments(in:)` directly with `"https://example.com/" + String(repeating: ")", count: n)` for increasing `n`, verify the stripped suffix stays plain text, and establish approximately linear scaling after the fix. Include alternating unmatched `)`/`]`, balanced brackets, and trailing punctuation. Run large inputs in a bounded subprocess so a regression cannot hang the test runner. The operation counts here were checked with Python arithmetic, not a Swift benchmark.

**Fix:** count bracket balances once and update them as the suffix shrinks, or use another single-pass suffix algorithm. Moving parsing off main improves responsiveness but does not fix the quadratic work.

### F10 — [P2] Save As has no path to retarget the Mac PDF's custom watcher

**Locations:** [`GlassineDocument.swift:310–318`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Sources/Glassine/GlassineDocument.swift#L310), [`383–410`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Sources/Glassine/GlassineDocument.swift#L383), and [`FileWatcher.swift:79–90`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/FileWatcher.swift#L79). **Evidence:** high-confidence source/API diagnosis; inherited NSDocument Save As lifecycle still needs native verification.

The app exposes inherited Save As. It changes the document's `fileURL` while preserving the original file, but the custom watcher is created once and retargeted only by `presentedItemDidMove`. There is no file-URL-change or successful-Save-As hook. Copying a document to B is not moving the original A. The expected result is a reader whose reload method reads B while its watcher still checks A. Even coordinated changes only poke that same watcher.

Consequently, external changes to B can be ignored. A change to A can instead trigger `reloadPDFFromDisk()` against B. If B has a newly added highlight still awaiting its 1.5-second save, that unrelated A event can revert B and discard the pending highlight and undo state. This loss was not executed on macOS; it follows from the mismatched watcher/read paths if Save As leaves the watcher at A.

**Regression:** extend [`HighlightsTests.saveAs`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Tests/GlassineTests/HighlightsTests.swift#L276) to create real window controllers/watchers. Save A as B, rewrite B, and require a reload. Then add a highlight to B and rewrite A before the highlight debounce fires; require no B revert or lost highlight. The current test verifies the new `fileURL` and unchanged A bytes, but does not exercise watching.

**Fix:** retarget and rebaseline the watcher whenever the authoritative document URL changes, including successful Save As, with pending save/reload generations updated together.

### F11 — [P2] A PDF revision saved immediately before a move can be lost by the reload gate

**Locations:** [`GlassineDocument.swift:393–410`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Sources/Glassine/GlassineDocument.swift#L393), its Markdown-only reload guard at [`367`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Sources/Glassine/GlassineDocument.swift#L367), and [`FileWatcher.swift:186–189`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/FileWatcher.swift#L186). **Evidence:** source-confirmed state transition; native regression unrun.

Retargeting adopts the moved file's current signature. The move handler then explicitly reloads to recover a revision saved before the watcher's 250 ms debounce completed—but calls the Markdown-only method. For a PDF that recovery is a no-op. Open a two-page PDF, replace it with three pages, and move it before the pending change check. The retargeted signature now describes the three-page file; the pending check sees no difference, while the reader still holds two pages. It can remain stale until another write or reopening.

**Regression/fix:** extend [`FilePresenterTests.moveAfterUnseenSave`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Tests/GlassineTests/FilePresenterTests.swift#L163), which already covers this race for Markdown, to differing-page-count PDFs. Preserve pre-move content identity/signature and reload from the new URL when an unseen revision exists. Keep the existing unchanged-PDF rename identity behavior; unconditional reloading on every rename would throw away that protection.

### F12 — [P2] Moving unchanged Markdown can leave images from the old directory

**Locations:** [`MarkdownDocumentModel.swift:68–75`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/MarkdownDocumentModel.swift#L68), [`GlassineDocument.swift:351–358`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Sources/Glassine/GlassineDocument.swift#L351), and [`DocumentSession.swift:624–655`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/DocumentSession.swift#L624). **Platforms:** both apps. **Evidence:** source-confirmed cache-key mismatch.

Conversion embeds local images relative to the Markdown file's directory, but `MarkdownContent.hash` hashes only the source bytes. Both move handlers reload from the new directory, then reject the fresh HTML when that byte hash matches. Open `A/notes.md` containing `![](diagram.png)`, then move it to B, where `diagram.png` has different contents. The new HTML can contain B's image yet be discarded; the screen and subsequent exports keep A's embedded image until a source edit or reopening.

**Regression/fix:** create the two directories with distinct images, verify that conversion produces different HTML for identical Markdown bytes, and drive each platform's move/reload path with a recording typesetter. Require the newly resolved image. Invalidate location-dependent content on a directory move or include resolved dependencies in the content identity. Merely rereading the file, as the current code does, is insufficient.

### F13 — [P2] Tinted custom paper brings back iOS clipping of trailing images

**Location:** [`MarkdownRendererIOS.swift:596–628`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/MarkdownRendererIOS.swift#L596). **Evidence:** source/geometry analysis supported by existing ink-test expectations; native rendered fixture unrun.

The tall continuous-page fallback crops its final sheet using the lower of text and raster ink. Tinted paper makes raster ink reach the sheet's bottom; lines 617–619 explicitly discard that measurement as background and fall back to text alone. A substantial image below the last text is therefore excluded from the crop. Custom CSS is an advertised iOS feature, `body` uses `--paper`, and the printer enables background printing. This is not limited to an unsupported stylesheet.

**Regression:** select `:root { --paper: #fffaf0; }` and open continuous Markdown exceeding 14,400 pt, with ordinary text followed by a tall image on the final sheet. Compare its crop with white paper and require the entire image. A synthetic two-sheet PDF can isolate the geometry: on the 14,400 pt final sheet, place text near y=13,900 and an image at y=11,500–11,900 over full-sheet tint. Discarding the ink result leaves a crop lower edge near y=13,823, cutting away the image. Existing tests cover tint detection and white-paper trailing images separately; the combination is missing.

**Fix:** retain the full final page when background makes ink bounds unreliable, or measure content independently of the background. A little extra trailing space is preferable to removing document content. The earlier white-background trailing-image fix is real but incomplete for this case.

### F14 — [P2] Recreating the iOS PDFView fails to restore or clear existing find highlights

**Locations:** [`DocumentSession.swift:780–825`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/DocumentSession.swift#L780), [`843–865`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/DocumentSession.swift#L843), [`1049–1052`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/DocumentSession.swift#L1049), and [`FindHighlighter.swift:44–73`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/FindHighlighter.swift#L44). **Evidence:** source-confirmed missing state restoration once a second view is attached; SwiftUI recreation route needs a device test.

The session survives view replacement and retains the finished query/matches. `attach` installs the document and position into the new PDFView but never reapplies those matches. `inversionChanged` returns early when the session's appearance is unchanged. In light mode, the new view has no native `highlightedSelections`, so the count survives while the match wash disappears.

Dark mode has a different failure: the shared `ReaderPage` objects retain the old highlight ink, but the new view's `FindHighlighter` has empty per-page caches. Next cannot update the outlined current match, and Done clears an empty cache without knowing which pages still carry the old boxes. Do not describe this as all dark-mode ink simply disappearing.

**Regression/fix:** finish a query, attach a fresh `ReaderPDFView` to the same session, and test both appearances. Require all matches/current index to restore and Done to remove every page's ink. Also resize an iPad window across the compact/regular transition in `RootView`, which switches view hierarchies. Initialize inversion and highlight state whenever attaching a new view; retire the old view's page ink in a defined order.

### F15 — [P3] A busy close-time teardown is never retried after the render queue drains

**Locations:** [`RenderQueue.swift:140–153`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/RenderQueue.swift#L140) and [`236–242`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/RenderQueue.swift#L236). **Platforms:** both apps. **Evidence:** source-confirmed resource-retention path, not a demonstrated crash or unbounded leak.

`releaseIfIdle()` schedules a single check after 30 seconds. If any job remains, it returns without teardown or rescheduling. `finish()` only pumps the next job. Closing documents invalidates their delivery generations but leaves their queued rendering work. With four different documents taking nine seconds each, closing all at t=0 yields completions at 9/18/27/36 seconds. The check at t=30 sees the fourth job and exits; after t=36 the singleton can retain its hidden WebKit view and last content indefinitely, until another teardown trigger occurs.

**Regression/fix:** use the existing fake-printer/scheduler seams to execute that schedule and require eventual teardown after the final job. Track a pending release request or rearm cleanup when the queue becomes empty. A lone normally asynchronous job is bounded by its two ten-second attempts, so it is not a valid example of this particular 30-second race. Memory size and any jetsam relationship need device measurement.

### F16 — [P2] The iOS presenter's URL getter is not thread-safe

**Location:** [`DocumentSession.swift:1142–1169`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/DocumentSession.swift#L1142). **Evidence:** unsynchronized shared storage plus documented framework access contract; no TSan result or reproduced bad access.

`presentedItemURL` is a mutable stored `URL?` written during `presentedItemDidMove`. The `@unchecked Sendable` rationale assumes all access is on the main presenter queue, but [Apple's operation-queue documentation](https://developer.apple.com/documentation/foundation/nsfilepresenter/presenteditemoperationqueue) specifically excludes requests for the presented URL. The [URL accessor's contract](https://developer.apple.com/documentation/foundation/nsfilepresenter/presenteditemurl) requires thread safety across concurrent queues. Foundation can therefore read the Swift value storage while the main-queue move callback replaces it.

**Regression/fix:** exercise concurrent URL queries and coordinated renames under Thread Sanitizer, including another scene opening the file. Protect the backing URL with a lock and return a copied value under that lock; update it under the same lock before delivering the move to main. Do not synchronously hop to main from the getter, which would introduce another coordination wait. This is a credible race to investigate, not proof of the user's `EXC_BAD_ACCESS`.

### F17 — [P2] iOS registers presenters after the protected initial read has ended

**Locations:** [`DocumentSession.swift:312–330`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/DocumentSession.swift#L312), [`434–451`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/DocumentSession.swift#L434), and registration at lines 344/613. **Evidence:** source-confirmed coordination gap plus documented ordering requirement; native interleaving unrun.

The PDF read block returns before `startPresentingPDF`; the Markdown block returns before conversion/render setup and `startWatching`. [Apple's addFilePresenter guidance](https://developer.apple.com/documentation/foundation/nsfilecoordinator/addfilepresenter(_:)) directs the initial read and presenter registration to occur within the same coordinated accessor to avoid missing intervening operations. Here another process can save or move the file between the read and registration. The session can then hold old content or an obsolete URL without receiving the event. For Markdown, the later watcher may baseline the already-updated file, so it has no signature change left to detect.

**Regression/fix:** add a test barrier after the accessor exits but before registration, perform a coordinated save/move, then resume opening. Require the displayed revision and session URL to be current. Register the prepared presenter while still holding the read coordination, and reconcile state before exposing the session. Integrate this with F2's worker read and F8's lifecycle handling; merely moving the existing sequence to a worker preserves the gap.

### F18 — [P2] Fully linked Markdown headings lose Mac outline geometry

**Locations:** [`MarkdownHTML.swift:455–469`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/MarkdownHTML.swift#L455) and [`MarkdownDocumentModel.swift:118–148`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/MarkdownDocumentModel.swift#L118). **Evidence:** source-confirmed nested-anchor output and executed HTML parser check; final WebKit/PDFKit annotation outcome needs native verification.

`HeadingAnchorer` wraps every heading's formatted children in a private outline link, even when those children are already links. `# [Section](https://example.com)` therefore generates an anchor inside another anchor. Parsing that exact generated structure with lxml closes the private anchor before the visible external link, leaving the private marker empty. It has no dimensions supplied by CSS. On the Mac, outline placement depends on a PDF annotation for that marker; if it is absent, the code assigns the previous heading's destination instead. The autolinker already avoids generating links in headings for this reason, but explicit Markdown links still pass through.

**Regression/fix:** put a fully linked heading on a later page and require its bookmark to land at that heading while its external link still works. Generate a nonnested geometry marker or otherwise collect the heading's position independently of its child links. iOS's measured-heading route and Quick Look's ordinary heading IDs are different paths; do not assume the Mac bookmark failure applies to all outputs.

### F19 — [P2] Footnote reference IDs collide with other labels and heading IDs

**Locations:** [`MarkdownFootnotes.swift:318–359`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/MarkdownFootnotes.swift#L318) and [`MarkdownHTML.swift:449–469`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/MarkdownHTML.swift#L449). **Evidence:** deterministic generated-ID collision; native navigation unrun.

In `A[^a] Again[^a] B[^a-2]` with definitions for `a` and `a-2`, the second use of `a` and first use of `a-2` both receive `id="fnref-a-2"`. B's backlink targets that duplicate ID and can land on A's earlier reference. Distinct label slugs do not prevent collisions introduced by repeat counters. Headings allocate IDs separately too: `# fn-a` collides with the destination for footnote `a`.

**Regression/fix:** render both examples, require every generated ID to be unique, and verify each note's forward/backward targets identify the intended element. Allocate generated IDs in a document-wide registry, and store each note's actual first-reference ID instead of rebuilding it from a slug. Preserve stable heading-fragment behavior while reserving internal IDs.

### F20 — [P2] A queued Recents write can undo a later removal

**Location:** [`Prefs.swift:403–436`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/Prefs.swift#L403). **Platforms:** both apps. **Evidence:** source-confirmed ordering defect; native test unrun.

`noteRecentDocument` queues bookmark creation and insertion on `recentsQueue`, while `removeRecentDocument` immediately removes the row under the lock. An earlier queued open can therefore insert the entry after the later removal has completed. The lock prevents simultaneous mutation, not this logical reversal. The iOS move path removes the old path then queues the new one, so an older pending open can also resurrect the old row beside the new row.

**Regression/fix:** seed an entry, hold the recents queue with the existing `performAfterRecentDocumentWrites` seam, queue another note of that entry, remove it, release the queue, and flush. The entry must stay removed. Serialize removal with writes or invalidate older pending writes by generation/tombstone; keep blocking bookmark creation off main. Add the equivalent old-path/new-path move case.

### F21 — [P2] Scan drag selection assumes left-to-right, one-unit characters

**Locations:** [`PageTextMap.swift:84–100`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/PageTextMap.swift#L84), [`247–253`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/PageTextMap.swift#L247), and [`ReaderPage.swift:209–213`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/Core/Sources/GlassineCore/ReaderPage.swift#L209). **Evidence:** deterministic synthetic geometry/range calculation; actual OCR/PDFKit fixture unrun.

The hit-test chooses `glyph.index` on the left half and `glyph.index + 1` on the right half, regardless of writing direction. For logical text `"\u{FFFC}אבג"`, place the Hebrew glyphs at x=20–30, 10–20, and 0–10. Dragging x=1 to x=29 across all letters yields `NSRange(location: 2, length: 1)`, selecting only the middle letter, instead of `(1, 3)`. The scan-selection override passes that range to PDFKit. A faithful Python model verified the caret arithmetic; this was not a native selection test.

The UTF-16-unit iteration has a related boundary problem when both halves of an emoji share bounds: the first equal-distance glyph wins, and a drag can yield `(0, 1)` for a two-unit character. Whether PDFKit normalizes that range, returns incomplete text, or rejects it needs a native test; do not infer a crash from the split range alone.

**Regression/fix:** add synthetic RTL and composed-character map tests, then a real OCR scan containing Hebrew/Arabic and supplementary-plane characters. Use direction-aware caret boundaries and valid composed-character ranges rather than assuming `index + 1` always denotes the opposite side of a visual glyph.

### F22 — [P2] iOS print and export failures disappear without feedback

**Location:** [`ReaderView.swift:407–425`](https://github.com/danepps/glassine/blob/10a00da12031b5050989d1cb1ccbd8e218c96c10/iOS/Sources/ReaderView.swift#L407). **Evidence:** source-confirmed failure handling.

The print closure returns for any failed render or missing PDF representation. Export resets `isExporting` and returns for every failure without presenting an error. Real errors from the renderer (timeout, print failure, empty output) and temporary-file writes already reach these closures but are discarded. The reader sees a stopped progress indicator or an action that appears to do nothing, with no explanation or recovery route.

**Regression/fix:** inject a typesetter failure and an export write failure, require a visible actionable error, verify the busy state resets, and allow a successful retry. Surface the existing error through an alert and handle print-controller completion failures as well. This is a failed-output workflow bug, not evidence of process termination.

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
- Second-pass portable checks executed: Pandoc 3.1.11.1 `gfm`/`commonmark_x`/`markdown` comparisons for F7; lxml parsing of F18's generated nested anchors; Python calculation of F9's scan counts, F19's ID formula, and F21's synthetic RTL caret range. These validate comparison semantics or source-derived models, not Glassine's Swift execution or PDFKit behavior.
- Apple's current file-coordinator/presenter documentation was checked for F8, F16, and F17. `git diff --check` and validation of all 48 pinned source-line links passed for the expanded report. Only this review document changed; no native regression tests or application fixes were added.
- Historical findings were checked against current source rather than copied forward. Examples already addressed include owned Mac PDF bytes, presenter-queue hopping on Mac moves, the body-plus-notes image budget, asynchronous Recents resolution, incremental Reader Mode analysis, immutable find-highlight ink, the iOS keyboard-selector collision, and iCloud timeout/error reporting. The earlier iOS trailing-image fix covers white paper; F13 identifies the remaining tinted-paper combination.
- A passing test process is not sufficient for crash verification: the repository's historical iPad keyboard run passed assertions and still emitted an `.ips` afterward. Native stress runs should also inspect diagnostic attachments and termination events.

## Suggested order

First match the installed platform/version and crash or termination report to a reproduction. For iOS, prioritize the background-presenter lifecycle (F8), exercise URL synchronization under TSan (F16), and address blocking read/registration boundaries together (F2/F17). For either app and Quick Look, reproduce and remove the quadratic URL scan (F9). Those are investigation priorities, not an assertion that the reported crashes occurred on iOS.

Next protect output and file tracking: unique export files (F6), Save As/move handling (F10/F11), location-dependent Markdown images (F12), and conservative image cropping (F13). Then address view/search restoration, Markdown navigation/compatibility, Recents ordering, selection boundaries, and output-error reporting. Saved-position hardening (F1) and terminal close semantics remain useful, but the conditional retained-controller/session cases (F3/F5) should not displace a matching crash stack or the stronger new evidence. Keep fixes separately reviewable and run each native regression before declaring the issue resolved.
