import AppKit
import PDFKit
import Testing
@testable import GlassineCore

/// Produces the defensive edge case without making the production jump API
/// public: the returned page exists, but has never belonged to a document.
private final class DetachedReadingPageDocument: PDFDocument {
    private let detachedPage = PDFPage()
    override var pageCount: Int { 1 }
    override func page(at index: Int) -> PDFPage? { index == 0 ? detachedPage : nil }
}

@MainActor private func readingView(_ document: PDFDocument?) -> PDFView {
    let view = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
    view.displayMode = .singlePageContinuous
    view.autoScales = false
    view.scaleFactor = 1
    view.document = document
    view.layoutDocumentView()
    return view
}

@Suite("ReadingPosition", .serialized) @MainActor
struct ReadingPositionTests {
    private func drainRestore() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func lockedDocument() throws -> PDFDocument {
        let source = makeBlankPDF(pageCount: 3)
        let bytes = try #require(source.dataRepresentation(options: [
            PDFDocumentWriteOption.ownerPasswordOption: "owner",
            PDFDocumentWriteOption.userPasswordOption: "reader"
        ]))
        return try #require(PDFDocument(data: bytes))
    }

    @Test("A detached destination page completes its install instead of leaving saves gated")
    func detachedDestinationCompletes() {
        let view = readingView(nil)
        let position = ReadingPosition(pdfView: view, saved: nil, url: { nil })
        let document = DetachedReadingPageDocument()
        var completions = 0
        position.beginInstall()
        position.aim(in: document, target: .init(pageIndex: 0, x: 12, y: 400)) {
            completions += 1
            position.finishInstall()
        }
        #expect(completions == 1)
        #expect(position.restoreStarted && position.restoreFinished)
    }

    @Test("Queued older restores and replaced documents never deliver stale completions")
    func supersededCompletionsRemainIgnored() async {
        let document = makeBlankPDF(pageCount: 3)
        let view = readingView(document)
        let position = ReadingPosition(pdfView: view, saved: nil, url: { nil })
        var completions: [Int] = []
        position.beginInstall()
        position.aim(in: document, target: .init(pageIndex: 1, x: 20, y: 600)) {
            completions.append(1)
        }
        position.beginInstall()
        position.aim(in: document, target: .init(pageIndex: 2, x: 30, y: 500)) {
            completions.append(2)
            position.finishInstall()
        }
        await drainRestore()
        #expect(completions == [2])
        #expect(position.restoreFinished)
        #expect(view.currentPage === document.page(at: 2))

        position.beginInstall()
        position.aim(in: document, target: .init(pageIndex: 1, x: 20, y: 600)) {
            completions.append(3)
            position.finishInstall()
        }
        // Keep the replacement's page count compatible with PDFKit's delayed
        // accessibility notification from the previous go(to:). Identity is
        // what this regression tests; reducing the count trips an unrelated
        // private PDFKit out-of-range callback in a windowless test view.
        view.document = makeBlankPDF(pageCount: 3)
        await drainRestore()
        #expect(completions == [2])
        #expect(!position.restoreFinished)
    }

    @Test("Absent and locked PDFs retain the saved target and restore only after unlock")
    func restoreAfterUnlock() async throws {
        let saved = Prefs.Position(pageIndex: 2, x: 35, y: 620)
        let view = readingView(nil)
        let position = ReadingPosition(pdfView: view, saved: saved, url: { nil })
        var completions = 0
        position.restoreIfNeeded { completions += 1 }
        #expect(!position.restoreStarted && !position.restoreFinished)
        #expect(position.lastInstallTarget == saved)

        let document = try lockedDocument()
        #expect(document.isLocked)
        view.document = document
        position.restoreIfNeeded { completions += 1 }
        await drainRestore()
        #expect(completions == 0)
        #expect(!position.restoreStarted && !position.restoreFinished)
        #expect(position.lastInstallTarget == saved)

        #expect(document.unlock(withPassword: "reader"))
        position.restoreIfNeeded { completions += 1 }
        await drainRestore()
        #expect(completions == 1)
        #expect(position.restoreStarted && position.restoreFinished)
        #expect(view.currentPage === document.page(at: saved.pageIndex))
        position.restoreIfNeeded { completions += 1 }
        #expect(completions == 1)
    }

    @Test("A locked replacement retains its latest target and finishes its pending install after unlock")
    func lockedReplacementRetainsTarget() async throws {
        let source = makeBlankPDF(pageCount: 3)
        let view = readingView(source)
        let saved = Prefs.Position(pageIndex: 1, x: 12, y: 650)
        let latest = Prefs.Position(pageIndex: 2, x: 38, y: 510)
        let position = ReadingPosition(pdfView: view, saved: saved, url: { nil })
        position.restoreIfNeeded {}
        await drainRestore()
        #expect(position.restoreFinished)

        let replacement = try lockedDocument()
        var completions: [String] = []
        position.beginInstall()
        view.document = replacement
        position.aim(in: replacement, target: latest) {
            completions.append("install")
            position.finishInstall()
        }
        position.restoreIfNeeded { completions.append("still locked") }
        await drainRestore()
        #expect(completions.isEmpty)
        #expect(!position.restoreStarted && !position.restoreFinished)
        #expect(position.lastInstallTarget == latest)

        #expect(replacement.unlock(withPassword: "reader"))
        position.restoreIfNeeded { completions.append("unlock") }
        await drainRestore()
        #expect(completions == ["install", "unlock"])
        #expect(position.restoreStarted && position.restoreFinished)
        #expect(position.lastInstallTarget == latest)
        #expect(view.currentPage === replacement.page(at: latest.pageIndex))

        // Retiring a second locked install must also retire its completion.
        let superseded = try lockedDocument()
        position.beginInstall()
        view.document = superseded
        position.aim(in: superseded, target: latest) { completions.append("superseded") }
        position.beginInstall()
        view.document = source
        position.aim(in: source, target: saved) { position.finishInstall() }
        #expect(superseded.unlock(withPassword: "reader"))
        await drainRestore()
        #expect(completions == ["install", "unlock"])
        #expect(position.lastInstallTarget == saved)
    }
}

// These tests share PrefsTests' existing serialization boundary because they
// temporarily replace the same global Prefs.defaults. Their scopes are entirely
// synchronous, so no other preference test can run while the suite is swapped.
extension PrefsTests {
    @MainActor private func withPositionDefaults(_ body: (URL) throws -> Void) rethrows {
        let name = "com.epps.Glassine.reading-position-tests.\(UUID())"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("could not create reading-position defaults")
            return
        }
        let previous = Prefs.defaults
        Prefs.defaults = defaults
        defer {
            Prefs.defaults = previous
            defaults.removePersistentDomain(forName: name)
        }
        try body(URL(fileURLWithPath: "/tmp/reading-position-\(UUID()).pdf"))
    }

    @Test("Close during the first or a later install saves the intended target; ordinary saves stay gated")
    @MainActor func pendingReadingPositionOnClose() {
        withPositionDefaults { url in
            let previous = Prefs.Position(pageIndex: 0, x: 0, y: 700)
            Prefs.setLastPosition(previous, for: url)
            let document = makeBlankPDF(pageCount: 3)
            let view = readingView(document)
            let position = ReadingPosition(pdfView: view, saved: nil, url: { url })
            let first = Prefs.Position(pageIndex: 1, x: 20, y: 600)
            position.beginInstall()
            position.aim(in: document, target: first) { position.finishInstall() }
            #expect(!position.restoreStarted && !position.restoreFinished)
            #expect(view.currentPage === document.page(at: 0))
            position.save()
            #expect(Prefs.lastPosition(for: url) == previous)
            position.saveOnClose()
            #expect(Prefs.lastPosition(for: url) == first)

            position.finishInstall()
            let latest = Prefs.Position(pageIndex: 2, x: 42, y: 510)
            position.beginInstall()
            position.aim(in: document, target: latest) { position.finishInstall() }
            #expect(position.restoreStarted && !position.restoreFinished)
            position.save()
            #expect(Prefs.lastPosition(for: url) == first)
            position.saveOnClose()
            #expect(Prefs.lastPosition(for: url) == latest)
        }
    }

    @Test("Close before any target exists leaves stored position alone; completed restores save the live view")
    @MainActor func readingPositionCloseWithoutPendingTarget() throws {
        try withPositionDefaults { url in
            let previous = Prefs.Position(pageIndex: 2, x: 24, y: 500)
            Prefs.setLastPosition(previous, for: url)
            let document = makeBlankPDF(pageCount: 3)
            let view = readingView(document)
            let position = ReadingPosition(pdfView: view, saved: nil, url: { url })
            position.saveOnClose()
            #expect(Prefs.lastPosition(for: url) == previous)
            position.restoreIfNeeded {}
            #expect(position.restoreFinished)
            let destination = try #require(view.currentDestination)
            let page = try #require(destination.page)
            let live = Prefs.Position(pageIndex: document.index(for: page),
                                      x: destination.point.x, y: destination.point.y)
            position.saveOnClose()
            #expect(Prefs.lastPosition(for: url) == live)
        }
    }
}
