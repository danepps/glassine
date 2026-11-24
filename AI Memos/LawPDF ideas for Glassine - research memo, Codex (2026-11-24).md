# LawPDF ideas for Glassine

LawPDF offers several ideas that fit Glassine well: footnotes that can be read without losing one's place, copying a passage with useful source information, richer viewing of other people's comments, and local OCR. Its recovery architecture also exposes a concrete improvement to prioritize in Glassine. I recommend adapting these capabilities incrementally while preserving Glassine's fast, native reading experience.

This is a static product and code review, completed on November 24, 2026. It compares LawPDF main at [4f831d7](https://github.com/yonathanarbel/LawPDF/blob/4f831d76ca7807696540297b3109d04e549486c7/Cargo.toml) with Glassine at [79e301e](https://github.com/danepps/glassine/blob/79e301e3f739f091fbb52edb037a6e2bf6741312/README.md), following the Glassine 1.12.0 release. LawPDF's package version is 0.2.92, but its README and GitHub-designated [latest release](https://github.com/yonathanarbel/LawPDF/releases/tag/v0.2.45) remain at 0.2.45. Features below are attributed to the inspected source, not assumed to be available in the latest downloadable package. Neither application was run for this comparison; implementation effort is a relative judgment, not a measured estimate.

| Idea | Recommendation for Glassine | Evidence and principal limitation |
| --- | --- | --- |
| Protect unsaved annotations across external changes | Highest engineering priority; medium scope | LawPDF binds recovery data to a source revision. Glassine currently reloads an externally changed PDF and discards pending highlights. |
| Footnote previews without leaving the passage | Strongest distinctive reading feature; medium for explicit links, large for inferred PDF notes | LawPDF implements previews, but even original-page previews depend on prepared Review data. |
| Copy a selection with source and page information | High priority; small to medium for a basic version | LawPDF has editable journal-citation drafts. Glassine already exports highlights, but lacks equivalent copying for an arbitrary selection. |
| Read more kinds of existing PDF comments | High priority for workshops; medium scope | LawPDF indexes several annotation types and authors. Glassine's sidebar indexes highlights and their attached notes. |
| Local OCR | Good fit; medium to large scope | LawPDF uses macOS Vision. Glassine handles existing OCR layers but has no app-owned recognition pipeline in the inspected code. |
| Explicit DOI recognition | Useful small addition | LawPDF recognizes bare DOI identifiers; Glassine already handles ordinary and wrapped web addresses. |
| Conservative watermark exclusion from copied text | Targeted experiment; feasibility uncertain in PDFKit | LawPDF examines glyph appearance, geometry, and recurrence. Glassine's current copy cleanup solves a different problem. |
| Full article reflow with margin footnotes | Defer to a separately scoped prototype; large scope | LawPDF has a dedicated model-driven reconstruction pipeline. Glassine Reader Mode preserves PDF layout and trims margins. |
| Local read-aloud with passage following | Optional later feature | LawPDF implements system speech and follow-along; useful, but less directly connected to Glassine's current gaps. |

The table's findings are supported by the implementation references below. Feature presence was checked in source; reliability across real documents was not established.

**1. Preserve pending annotations before an external reload.**

This is the most actionable engineering lesson. Glassine already debounces highlight saves, waits for saves on close, and preserves edits after a failed save. The remaining problem is specific: `reloadPDFFromDisk` deliberately lets the external file win, reverting the document and dropping highlights not yet saved. This is observable in the code and its accompanying comment; it is not an inference from missing documentation. [Glassine save and reload implementation](https://github.com/danepps/glassine/blob/79e301e3f739f091fbb52edb037a6e2bf6741312/Sources/Glassine/GlassineDocument.swift#L190)

LawPDF's `DocumentStore` pairs an annotation journal with an immutable source PDF identified by its hash. Its recovery export uses that original revision, and save acknowledgments distinguish older completed saves from newer edits. The important idea is that annotation coordinates belong to a particular document revision. [LawPDF recovery store](https://github.com/yonathanarbel/LawPDF/blob/4f831d76ca7807696540297b3109d04e549486c7/src/document_store.rs#L28)

For Glassine, first prevent automatic reload from destroying dirty annotation state: retain the edited document, show that the file changed, and offer to save the annotated version separately before adopting the replacement. Then consider durable recovery snapshots for crashes and failed writes. Never transplant old highlight rectangles onto revised pages without a separate reconciliation mechanism.

This need not reproduce LawPDF's storage system. Keep expensive serialization and hashing away from interactive reading, retain pending recovery data until resolved, and test a file replacement during the save debounce as the first regression case. Relevant work belongs around `GlassineDocument` and its existing file-watcher and highlight tests.

**2. Let the reader inspect footnotes in place.**

LawPDF's most compelling product idea is making footnotes convenient enough to read as part of the argument. Its Review layout aligns notes with callouts, shortens crowded notes, expands them on demand, and falls back to popovers when margins do not fit. [LawPDF reading layout](https://github.com/yonathanarbel/LawPDF/blob/4f831d76ca7807696540297b3109d04e549486c7/docs/READING_LAYOUT.md)

There is also a subtler feature: previews over footnote markers in the original PDF. The code requires a ready Review document. Linked markers must agree with its footnote mapping; unlinked markers require additional source-line and superscript evidence. Consequently, importing the preview UI alone would not give Glassine reliable footnote detection. [LawPDF preview resolution](https://github.com/yonathanarbel/LawPDF/blob/4f831d76ca7807696540297b3109d04e549486c7/src/app/footnote_peek.rs#L230)

A smaller Glassine design is preferable initially:

- Preserve Markdown's known footnote relationships during rendering, and use them to show a note popover. The source already supplies the relationship.
- For ordinary PDFs, prototype a preview of an explicit internal-link destination. A cropped destination region can preserve the actual typesetting without claiming to have reconstructed a complete footnote.
- Provide keyboard activation, an ordinary jump to the source, and a way to dismiss the preview without moving the reading position.
- Leave unlinked footnote recognition for a later, separately tested phase.

Glassine already parses Markdown footnotes and generates forward and return links; the missing piece is retaining suitable note metadata for the reader UI. [Glassine footnote processing](https://github.com/danepps/glassine/blob/79e301e3f739f091fbb52edb037a6e2bf6741312/Core/Sources/GlassineCore/MarkdownFootnotes.swift)

LawPDF also makes some earlier-note references navigable, including constrained forms of supra and Id. Its resolver rejects ambiguous targets and supports only recognizable patterns. Treat this as a later navigation enhancement, not citation validation. [LawPDF reference resolver](https://github.com/yonathanarbel/LawPDF/blob/4f831d76ca7807696540297b3109d04e549486c7/src/app/review_references.rs#L42)

**3. Copy any selected passage with its source.**

LawPDF's citation-copy feature prepares editable journal-article metadata, separates PDF position from the printed pinpoint, and leaves the journal abbreviation for the reader to supply. Its printed-page detector declines conflicting candidates rather than substituting the PDF index. This is a useful model of making uncertainty visible in the workflow. [Citation draft UI](https://github.com/yonathanarbel/LawPDF/blob/4f831d76ca7807696540297b3109d04e549486c7/src/app/citation_copy.rs#L527), [printed-page detection](https://github.com/yonathanarbel/LawPDF/blob/4f831d76ca7807696540297b3109d04e549486c7/src/review_masthead.rs#L70)

Glassine already has geometry-aware copy cleanup, an unmodified-copy command, and Markdown export of highlights with notes and file-page links. Those capabilities should be extended rather than recreated. [Copy cleanup](https://github.com/danepps/glassine/blob/79e301e3f739f091fbb52edb037a6e2bf6741312/Core/Sources/GlassineCore/CopyCleanup.swift), [highlight export](https://github.com/danepps/glassine/blob/79e301e3f739f091fbb52edb037a6e2bf6741312/Core/Sources/GlassineCore/HighlightMarkdown.swift)

The first version should copy an arbitrary selection with the filename or title, physical PDF page range, and a usable link back. Keep an embedded page label distinct from a user-confirmed printed page: a PDF label alone does not verify a journal pinpoint. Bibliographic fields and a reviewed citation template can come later; the basic command should remain useful when the author, publication, or printed page is unknown.

Page-aware return links need work. Glassine's current custom URL handler resolves a file location, and its path-form parser strips the fragment; it does not implement page navigation. The toolbar also displays physical PDF positions, while highlight and search rows already consult page labels. A shared page-reference model would make these behaviors consistent. [Glassine URL parser](https://github.com/danepps/glassine/blob/79e301e3f739f091fbb52edb037a6e2bf6741312/Core/Sources/GlassineCore/GlassineURL.swift), [page indicator](https://github.com/danepps/glassine/blob/79e301e3f739f091fbb52edb037a6e2bf6741312/Sources/Glassine/ReaderWindowController.swift#L482)

Keep this an explicit copy command. LawPDF's newer source also automatically copies completed selections; that would unexpectedly replace the clipboard during ordinary reading and is a poor default for Glassine. [LawPDF 0.2.91 notes](https://github.com/yonathanarbel/LawPDF/blob/4f831d76ca7807696540297b3109d04e549486c7/docs/releases/v0.2.91.md)

**4. Expand the Highlights sidebar into a useful comments reader.**

LawPDF reads supported third-party highlights, underlines, squiggles, strikeouts, sticky comments, and text boxes, including their author fields. Imported marks have a separate read-only representation. Its Markdown digest distinguishes imported marks and leaves unavailable printed pinpoints unresolved. [Annotation import](https://github.com/yonathanarbel/LawPDF/blob/4f831d76ca7807696540297b3109d04e549486c7/src/pdf_backend/foreign_annotations.rs#L22), [digest formatting](https://github.com/yonathanarbel/LawPDF/blob/4f831d76ca7807696540297b3109d04e549486c7/src/app/annotation_digest.rs#L210)

Glassine already reads highlight annotations regardless of which application created them, and displays their attached contents. The gap is broader annotation types and authors, not basic support for imported highlights. Its indexing and editing checks currently select the Highlight subtype. [Glassine highlight model](https://github.com/danepps/glassine/blob/79e301e3f739f091fbb52edb037a6e2bf6741312/Sources/Glassine/PDFHighlights.swift#L81)

Start by displaying sticky comments, underlines, and strikeouts in the existing sidebar, with author and page. Preserve unsupported annotations in the PDF, and avoid exposing editing until round-trip behavior is tested. Reply threads are a subsequent interoperability task, not something to infer from a flat annotation list. Extend the existing Markdown export instead of adding a parallel notes system. This would directly help reading workshop drafts and feedback from colleagues.

**5. Add explicit, on-device OCR for image-only PDFs.**

LawPDF's Mac OCR backend uses Vision's text-recognition request and assembles recognized lines using their geometry. Its app also documents searchable-copy export. [Mac OCR implementation](https://github.com/yonathanarbel/LawPDF/blob/4f831d76ca7807696540297b3109d04e549486c7/src/system_ocr.rs#L360), [OCR workflow](https://github.com/yonathanarbel/LawPDF/blob/4f831d76ca7807696540297b3109d04e549486c7/README.md)

Glassine's scan-selection patch fixes selection when a scan already contains an OCR text layer. It does not create missing text. That distinction matters for older articles and scanned materials. [Glassine scan-selection implementation](https://github.com/danepps/glassine/blob/79e301e3f739f091fbb52edb037a6e2bf6741312/Sources/Glassine/ScanSelectionPatch.swift#L6)

An appropriate first scope is recognition of selected pages, with progress, cancellation, cached results tied to the document revision, and preservation of the original file. A searchable-copy export can be a separate milestone. Search, hit geometry, selection, and highlights must agree about the recognized text; adding a text cache alone will not automatically make PDFKit's existing search and selection operate on it. Mixed text-and-image documents, page rotation, columns, and footnotes require fixtures before making this a general workflow.

This fits Glassine better than introducing cloud OCR and provider configuration as the default.

**6. Improve source following in two stages.**

The inexpensive stage is explicit DOI handling. LawPDF extracts DOI identifiers and constructs a DOI link without needing to infer the publication. Glassine already joins wrapped web addresses and uses link detection, so extend that path rather than replacing it. [LawPDF DOI extraction](https://github.com/yonathanarbel/LawPDF/blob/4f831d76ca7807696540297b3109d04e549486c7/src/citation_links.rs#L94), [Glassine text links](https://github.com/danepps/glassine/blob/79e301e3f739f091fbb52edb037a6e2bf6741312/Core/Sources/GlassineCore/TextLinks.swift)

The larger stage is searching for an article from a selected citation. LawPDF makes lookup a reader action, returns candidate matches, and uses bounded background work and caching. Its documented service path is BBGPT with Crossref fallback. [Lookup worker](https://github.com/yonathanarbel/LawPDF/blob/4f831d76ca7807696540297b3109d04e549486c7/src/footnote_sources.rs), [network behavior](https://github.com/yonathanarbel/LawPDF/blob/4f831d76ca7807696540297b3109d04e549486c7/docs/PRIVACY.md)

For Glassine, defer an integrated provider until there is demand beyond explicit links. If added, show what text will be sent, let the reader choose the candidate, and distinguish discovery from verification. A matching title or plausible result does not establish that a citation supports a proposition. Automatic document-wide lookup would add latency, network behavior, and UI without a clear benefit to ordinary reading.

**7. Investigate watermark-aware copying, with a narrow scope.**

LawPDF 0.2.92 excludes confidently identified recurring diagonal text watermarks from extraction. The detector examines size, angle, color or opacity, placement, and recurrence across a bounded sample of pages. It preserves ambiguous content and leaves rendering and saved PDF contents alone. This is a particularly relevant idea for scholarship downloaded from repositories or publishers. [Watermark implementation](https://github.com/yonathanarbel/LawPDF/blob/4f831d76ca7807696540297b3109d04e549486c7/src/pdf_backend/watermarks.rs)

Glassine already repairs wrapping, split words, and paragraph structure. Its geometry checks also prevent a tall sideways watermark from being merged into a neighboring line; that is not a general watermark-exclusion system. [Glassine line merging](https://github.com/danepps/glassine/blob/79e301e3f739f091fbb52edb037a6e2bf6741312/Core/Sources/GlassineCore/CopyCleanup.swift#L180)

Begin with a small corpus of affected PDFs and an extraction experiment. LawPDF relies on PDFium character attributes; equivalent evidence must be established in Glassine's PDFKit path before promising the feature. Retain Copy Without Cleanup, and never remove text merely because its wording resembles a common stamp. Success means clean copied prose while genuine diagonal labels, figures, and body text survive.

**8. Treat full reflow and narration as separate decisions.**

LawPDF Review Mode is substantially more ambitious than Glassine Reader Mode. It reconstructs text and note relationships through a dedicated pipeline with model runtimes, source mappings, and numerous layout passes. Glassine's Reader Mode trims outer margins while keeping PDF pages and their layout. Glassine's Markdown typesetter does not supply the missing PDF-to-structured-text analysis. [LawPDF pipeline](https://github.com/yonathanarbel/LawPDF/blob/4f831d76ca7807696540297b3109d04e549486c7/src/liquid2/pipeline.rs), [Glassine Reader Mode](https://github.com/danepps/glassine/blob/79e301e3f739f091fbb52edb037a6e2bf6741312/Sources/Glassine/ReaderModeController.swift)

Full reflow could be valuable, especially on smaller screens, but should start as an optional prototype tested on a representative set of law reviews, opinions, scans, and complicated layouts. A credible prototype must retain source-page links, let readers inspect the original easily, and expose failure instead of silently omitting or reordering material. Footnote popovers offer a useful intermediate improvement.

LawPDF also implements system speech with speed and passage-following controls. A compact local read-aloud feature could suit Glassine later, particularly for accessibility, but document-wide narration depends on sensible reading order. Begin with selected text before taking on whole-document footnote sequencing. [LawPDF speech controls](https://github.com/yonathanarbel/LawPDF/blob/4f831d76ca7807696540297b3109d04e549486c7/src/app/speech_ui.rs)

**Suggested sequence and completion criteria.**

1. **Protect existing work and improve copying.** Preserve dirty annotations on external change; add selection-plus-source copying and page-aware return links. Verify that an external rewrite preserves both versions, and that a copied link returns to the intended physical page.
2. **Improve scholarly reading.** Add Markdown footnote previews, a prototype for explicit PDF destination previews, and broader comment viewing. Verify that previews keep the reader's place and ambiguous destinations remain ordinary links.
3. **Support difficult source material.** Add on-device OCR after proving its search and selection integration; evaluate watermark-aware extraction against real fixtures.
4. **Decide on full reflow from evidence.** Measure the prototype's reading-order and footnote accuracy, startup impact, and memory use before committing to a second reading engine.

Glassine already covers tabs, reading-position memory, outlines, search results, dark page rendering, highlights, attached notes, and Markdown highlight export. These are not new opportunities merely because LawPDF also has them. Likewise, I would not adopt a floating markup bar, a multi-second transition animation, or a suite of cloud-provider controls without an independently demonstrated need. The most appropriate borrowing is a set of quiet improvements to reading, source navigation, and preservation of annotations.

The review established source-level implementation and local integration points. It did not establish runtime reliability, comparative speed, accessibility quality, or reconstruction accuracy, and no code or application tests were run. Any later code reuse should separately inspect the relevant source and bundled-component notices; this recommendation does not require adopting LawPDF's Rust, egui, or PDFium stack.

```text
Topic: LawPDF features and ideas appropriate for Glassine
Date: 2026-11-24
By: Codex-gpt-6-astra
Production details: 1,472,171 aggregate tokens in the latest runtime counter at 2026-11-24T20:17:02.425Z (including 1,334,784 cached-input tokens); elapsed time from run start through completed content audit: 7m 52s; subagents: none; static source review using GitHub, web access, and the local repository; application tests and benchmarks not run. Token counter is the runtime snapshot available at audit completion; later publication and Git operations are excluded.
```
