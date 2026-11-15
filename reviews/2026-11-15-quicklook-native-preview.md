# Quick Look preview: should Glassine go native, like Marked?

**Date:** 2026-11-15
**By:** Claude (Fable 5.2), Claude Code session
**Status:** Open decision. Nothing here is built. The page-only preview with a headings column is on branch `feature/markdown-quicklook` (commits `217fd4c`, `a03a51f`, `0e974aa`) and has not yet been confirmed in Finder's Quick Look panel.
**Skill:** none (ad hoc session)

## Short version

- Glassine's Finder preview hands macOS one locked-down HTML page. Marked's builds its own window, with a native outline beside a web view. Nothing in macOS forces Glassine's choice; it was a design decision made in September for safety and size.
- Going native buys two things nothing else can: a sidebar that tracks where you are reading, and the option to show the reader's actual pages. It also opens the door to in-preview controls, live refresh, and script-based rendering.
- It does not change how the text is typeset (that is the stylesheet on either route), and it is not what makes the preview use your own style and size. That needs a shared settings container, which works on either route.
- The main risks are whether a web view runs acceptably inside a sandboxed Quick Look extension on current macOS, how much slower the preview appears, and how much Finder lets the extension do with keys and translucency. Marked's extension is evidence the first is solvable; the rest are unmeasured.
- **Recommendation:** run a small spike in the `--preview` build before committing to a rewrite. If it passes, go native with a web view plus a native outline (option A below). Do the shared settings container either way.

## The two ways to build a Quick Look preview

Apple's `QLPreviewingController.h` (macOS 27.2 SDK) describes both:

- **Data-based.** The header says: "For data-based previews, subclass QLPreviewProvider which conforms to this protocol." The extension returns data (here, HTML) and macOS draws it. This is what Glassine does: `Sources/GlassineQuickLook/PreviewProvider.swift`, with `QLIsDataBasedPreview` true in `Support/QuickLook/Info.plist`.
- **View-based.** The extension's principal class is a view controller that implements `preparePreviewOfFile(at:completionHandler:)` and presents the preview in its own view. The header's guidance for this route:
  - "The operating system shows a loading spinner, so call the handler as soon as possible."
  - "Avoid holding the file open during the duration of the preview."
  - "Avoid presenting additional view controllers over your QLPreviewingController."
  - It also warns against gesture recognizers that take over large parts of the view, because they collide with standard preview behaviour.

## What Marked's extension does

Inspected on this Mac: `/Applications/Marked Quick Look.app/Contents/PlugIns/MarkedQuickLookPreview.appex`, version 1.0.28 (build 53).

| Aspect | Marked Quick Look | Glassine (branch) |
|---|---|---|
| Preview type | View-based (`QLIsDataBasedPreview` false; principal class `MKQLPreviewViewController`) | Data-based |
| Sidebar | Native `NSOutlineView` (data source and delegate methods in the binary, a `MKQLTOCNode` class, a `TOCBridge` class, an `outlineClicked:` action) | HTML links in a fixed column, no script |
| Content view | Links WebKit; calls `loadHTMLString:baseURL:` and `evaluateJavaScript:completionHandler:`; contains a `scrollIntoView` snippet | macOS's own HTML viewer |
| Bundled script | `highlight.min.js`, `mathjax-tex-svg.js`, `mermaid.min.js` | None; the CSP blocks script |
| Entitlements | App Sandbox, user-selected read-only, outgoing network, app-scope bookmarks, two app groups (one Team-ID-prefixed, one `group.`-prefixed) | App Sandbox, user-selected read-only |
| Content types | 13, including plain text and Quarto | 6 Markdown types |

Marked's host app carries the same Team-ID-prefixed app group, app-scope bookmarks and outgoing network. My reading, not confirmed: the app group shares settings between app and extension, and the bookmarks let a folder grant made in the app be reused by the extension so sibling images load.

### How unusual is that?

A survey of the eight third-party Quick Look preview extensions registered on this Mac:

- Marked's is the only one that links WebKit, and the only one with the outgoing-network entitlement.
- Five are data-based (Glassine, Mellel, Icon Composer, and two others). Two leave the key unset (Fantastical, Drafts). Marked alone sets it false.
- Four carry an app group (Marked, Fantastical, Mellel, Drafts).

So a web view inside a Quick Look extension is the less-travelled path, and a shared container is common.

## What native would give Glassine

Only available when the extension owns its view:

1. **A tracking outline.** Highlights the current section, collapses nested headings, resizes, hides. It can use the same outline presentation as the reader (`Sources/Glassine/SidebarViewController.swift` is already an `NSOutlineView` controller).
2. **The reader's actual pages** (option B below): paginated, with dark paper, identical to what Glassine shows.
3. **Controls in the preview:** text size, style switcher, an 'Open in Glassine' button.
4. **Live refresh** when the file changes, subject to the header's advice not to hold the file open.
5. **Script-dependent rendering:** math, Mermaid, code highlighting. The reader does none of these today, so this is new work for both, not something native hands over for free.

Not a native question at all:

- **How the text looks.** Fonts, spacing, colours, tables and code come from the stylesheet on either route.
- **Using your reader style and size.** Today the preview is fixed at built-in Manuscript, 12 pt, because the sandboxed extension cannot read the app's preferences or the custom `.css` files. A shared container fixes that for the data-based preview too.
- **Sibling images.** Blocked by the sandbox on both routes. The likely fix is the one Marked appears to use: grant a folder once in the app, share the bookmark with the extension.

## Two shapes for a native preview

**Option A: web view plus native outline (what Marked does).**

- The extension's principal class becomes an `NSViewController` with a split view: outline on the left, `WKWebView` on the right.
- The web view loads the same HTML `MarkdownPreview.html(for:)` produces today, minus the HTML headings column. The CSP stays, so script in the document is still blocked.
- The outline is built from `converted.headings`, which already carry `level`, `title` and (since `a03a51f`) the `slug` that is the heading's `id`.
- Clicking an outline row scrolls the web view by calling `evaluateJavaScript` from the extension. That call already works against the CSP-protected page: `Tests/GlassineTests/MarkdownPreviewRenderingTests.swift` does it in a bare web view.
- Tracking the current section needs the extension to learn the scroll position, by polling through `evaluateJavaScript` or an injected user script with a message handler. Untested.
- The view controller should live in a small macOS-only library target, not in the extension executable, so the test target can host it directly without Finder.

**Option B: the reader's pages in a PDF view.**

- Run the reader's pipeline (HTML, offscreen WebKit print to PDF, PDFKit) inside the extension and show a `PDFView` with the PDF's own outline.
- The preview would be the reader, exactly. It is also the slowest to appear, needs `WebKitHTMLPrinter` (now in the app target, `Sources/Glassine/MarkdownRenderer.swift`) moved somewhere shareable, and depends on printing to PDF working inside the extension's sandbox, which is unknown.

Option A is the smaller step and the closer match to the request (a headings sidebar). Option B is worth considering only if previews that differ from the reader turn out to bother you.

## Costs, risks and unknowns

- **Web view in a sandboxed Quick Look extension.** Marked's extension does it on this Mac with App Sandbox plus outgoing network and no other exception entitlements, so it is possible on macOS 27. There is history: a WebKit bug report from 2020 (219632) describes `WKWebView` crashing inside a Quick Look preview extension on Big Sur. [unverified: from a web search summary, not read at the source; current status unknown.] Whether Glassine needs the outgoing-network entitlement, or can run the web view without it, is the first thing to test.
- **Sandbox surface.** If the network entitlement is needed, the extension could reach the network in principle. The page's CSP (`default-src 'none'`) and blocked document script keep previewed files from using it, but it is a wider grant than today's.
- **Time to appear.** macOS shows a spinner until the view-based extension says it is ready. Launching a web view in the extension adds startup that the data-based route does not pay. Not measured.
- **Keys and gestures.** Finder owns Space, the arrow keys and the panel's own shortcuts. Whether ⌘F or other shortcuts reach the extension's view is unknown; a web search found no macOS-specific documentation. [unverified]
- **Translucency.** Whether the reader's blurred, translucent treatment shows through in Finder's panel is unknown.
- **Shared container and signing.** Apple's documentation is reported to say a Team-ID-prefixed app group needs no provisioning profile on macOS, and that macOS 15's container protection can prompt the user for other group forms. One forum poster reported trouble with Developer ID signing specifically. [unverified: search summary.] Glassine's app is signed by `build.sh` with no entitlements file and is not sandboxed, so this needs a real test with the Developer ID certificate.
- **What gets thrown away.** A Quick Look extension is data-based or view-based, set in its Info.plist; there is no fallback from one to the other. Going native retires the HTML headings column from `a03a51f`. `MarkdownHeading.slug`, the unique-id fix (`0e974aa`), the preview content filter and all Core tests carry over.
- **Maintenance.** The extension goes from 17 lines of provider code to a view controller, an outline, scroll synchronisation and their tests.

## Proposed spike

Build it in the `--preview` flavour so the installed app is untouched. Each step has a pass or fail:

1. A view-based extension with a split view and a web view loading today's preview HTML renders in Finder with the current two entitlements. If not, add outgoing network and retry. Record which was needed.
2. Clicking an outline row scrolls the web view to the heading.
3. The outline highlights the current section while scrolling.
4. Time from Space to first paint, against the data-based build, on a short file and a long one.
5. ⌘F, arrow keys and Space: note which reach the extension.
6. A translucent background: note whether it shows.
7. The extension reads the reader's style and size through a Team-ID-prefixed app group, under Developer ID signing, with no prompt.

Steps 1 to 3 decide whether option A is viable. Step 4 decides whether it is pleasant. Steps 5 to 7 set the feature list.

## Recommendation

1. Confirm the page-only headings column in Finder first, including whether its links jump. That is the build now running as Glassine Preview.
2. Add the shared settings container regardless of route, so previews use your style and size.
3. Run the spike. If steps 1 to 4 pass, build option A and drop the HTML column.
4. Leave option B and script-based rendering (math, Mermaid, highlighting) as later, separate decisions.

## What was checked, and how

- Marked's extension: `Info.plist`, bundle contents, `codesign -d --entitlements`, and `strings` on the binary. Class and method names are evidence of how it is built, not a reading of its source.
- Installed extensions: `pluginkit -m -p com.apple.quicklook.preview`, then each bundle's `Info.plist`, entitlements and linked frameworks.
- Apple's API: `QuickLookUI.framework/Headers/QLPreviewingController.h` in the macOS 27.2 SDK. The quoted sentences are copied from that header.
- Web sources, used only for the items tagged [unverified] above:
  - WebKit bug 219632: <https://bugs.webkit.org/show_bug.cgi?id=219632>
  - Apple Developer Forums, `WKWebView` and the network entitlement for local content: <https://developer.apple.com/forums/thread/116359>
  - Apple, accessing app group containers: <https://developer.apple.com/documentation/xcode/accessing-app-group-containers>
  - Apple Developer Forums, macOS app group entitlements: <https://developer.apple.com/forums/thread/762639>
- Not done: no native extension was built, nothing was timed, and Marked's preview was not exercised in this session.
