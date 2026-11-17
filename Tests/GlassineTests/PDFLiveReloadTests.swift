import AppKit
import CoreText
import GlassineCore
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import Glassine

extension MacAppTests {
    /// A PDF rewritten by another program (a LaTeX build, a script) is
    /// reloaded in place, the way a Markdown file is re-rendered -- but
    /// Glassine's own highlight saves into the same file are not.
    @MainActor
    @Suite("PDF live reload", .serialized)
    struct PDFLiveReloadTests {

        private static func pdfData(pages: Int) throws -> Data {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            let consumer = try #require(CGDataConsumer(data: data))
            let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
            for index in 0..<pages {
                context.beginPDFPage(nil)
                let string = NSAttributedString(string: "Page \(index + 1) of a document to reload.", attributes: [
                    .font: CTFontCreateWithName("Helvetica" as CFString, 16, nil)
                ])
                CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(string),
                    CFRange(location: 0, length: 0), CGPath(rect: box.insetBy(dx: 48, dy: 48), transform: nil), nil),
                    context)
                context.endPDFPage()
            }
            context.closePDF()
            return data as Data
        }

        private func withDocument(_ body: (GlassineDocument, URL) async throws -> Void) async throws {
            _ = NSApplication.shared
            Prefs.flushRecentDocumentWrites()
            let name = "com.epps.Glassine.pdf-reload-tests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: name))
            let previous = Prefs.defaults
            Prefs.defaults = defaults
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("GlassinePDFReload-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer {
                Prefs.flushRecentDocumentWrites()
                Prefs.defaults = previous
                defaults.removePersistentDomain(forName: name)
                try? FileManager.default.removeItem(at: folder)
            }
            let url = folder.appendingPathComponent("Build.pdf")
            try Self.pdfData(pages: 2).write(to: url)
            let document = try GlassineDocument(contentsOf: url, ofType: UTType.pdf.identifier)
            document.undoManager?.groupsByEvent = false
            document.makeWindowControllers()
            defer { document.close() }
            // Let the watcher open its sources before anything is written.
            try await Task.sleep(for: .milliseconds(150))
            try await body(document, url)
        }

        /// Highlights reach the change count through undo groups, as in
        /// HighlightsTests.
        @discardableResult
        private func highlight(_ document: GlassineDocument) throws -> Int {
            let selection = try #require(document.pdf?.selectionForEntireDocument)
            document.undoManager?.beginUndoGrouping()
            let added = document.addHighlight(selection: selection, color: .yellow)
            document.undoManager?.endUndoGrouping()
            return added.count
        }

        private func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition() && Date() < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            try #require(condition())
        }

        @Test("A PDF rewritten by another program is reloaded")
        func outsideRewriteReloads() async throws {
            try await withDocument { document, url in
                let original = try #require(document.pdf)
                #expect(original.pageCount == 2)
                // Written directly, as a TeX engine or script does: no file
                // coordination, so only the vnode watcher can see it.
                try Self.pdfData(pages: 3).write(to: url, options: .atomic)
                try await waitUntil { document.pdf !== original }
                #expect(document.pdf?.pageCount == 3)
                #expect(!document.isDocumentEdited)
            }
        }

        @Test("Glassine's own highlight save is not reloaded")
        func ownSaveIsNotReloaded() async throws {
            try await withDocument { document, _ in
                let pdf = try #require(document.pdf)
                #expect(try highlight(document) > 0)
                #expect(document.isDocumentEdited)
                var saveError: Error?
                var saved = false
                document.flushHighlights { error in saveError = error; saved = true }
                try await waitUntil { saved }
                #expect(saveError == nil)
                // Past the watcher's debounce: a reload would have replaced the
                // document by now.
                try await Task.sleep(for: .milliseconds(700))
                #expect(document.pdf === pdf)
                #expect(document.savedHighlights.count == 2)
            }
        }

        @Test("An outside rewrite wins over highlights not yet saved, and they are not saved over it")
        func outsideRewriteBeatsPendingHighlights() async throws {
            try await withDocument { document, url in
                let pdf = try #require(document.pdf)
                #expect(try highlight(document) > 0)
                #expect(document.isDocumentEdited)
                let rebuilt = try Self.pdfData(pages: 4)
                try rebuilt.write(to: url, options: .atomic)
                try await waitUntil { document.pdf !== pdf }
                #expect(document.pdf?.pageCount == 4)
                #expect(!document.isDocumentEdited)
                #expect(document.savedHighlights.isEmpty)
                // Past the 1.5 s highlight debounce: the cancelled save must not
                // have written the old pages back.
                try await Task.sleep(for: .milliseconds(1800))
                #expect(try Data(contentsOf: url) == rebuilt)
            }
        }
    }
}
