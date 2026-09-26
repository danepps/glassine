import AppKit
import GlassineCore
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import Glassine

@MainActor
@Suite("File presenter moves", .serialized)
struct FilePresenterTests {
    private func withFixture(
        _ body: (URL) async throws -> Void
    ) async throws {
        _ = NSApplication.shared
        Prefs.flushRecentDocumentWrites()
        let name = "com.epps.Glassine.file-presenter-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let previous = Prefs.defaults
        Prefs.defaults = defaults
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassineFilePresenter-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            Prefs.flushRecentDocumentWrites()
            Prefs.defaults = previous
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: folder)
        }
        try await body(folder)
    }

    /// NSDocument receives Finder moves on its own operation queue, not the
    /// main actor. Calling the override directly from a UI test hides this bug.
    private func deliverMove(_ document: GlassineDocument, to url: URL) async {
        let onMainThread = await withCheckedContinuation { continuation in
            document.presentedItemOperationQueue.addOperation {
                let onMainThread = Thread.isMainThread
                document.presentedItemDidMove(to: url)
                continuation.resume(returning: onMainThread)
            }
        }
        #expect(!onMainThread)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition())
    }

    /// Exercise the OS delivery path as well as the deterministic queue test.
    /// Coordination must leave the main thread free for NSDocument to respond.
    private func coordinatedMove(from source: URL, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let coordinator = NSFileCoordinator(filePresenter: nil)
                var coordinationError: NSError?
                var moveError: Error?
                coordinator.coordinate(writingItemAt: source, options: .forMoving,
                                       writingItemAt: destination, options: .forReplacing,
                                       error: &coordinationError) { source, destination in
                    do {
                        coordinator.item(at: source, willMoveTo: destination)
                        try FileManager.default.moveItem(at: source, to: destination)
                        coordinator.item(at: source, didMoveTo: destination)
                    } catch {
                        moveError = error
                    }
                }
                if let error = coordinationError ?? moveError {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    @Test("A PDF renamed on the presenter queue stays open and saves to its new path")
    func pdfRename() async throws {
        try await withFixture { folder in
            let originalURL = folder.appendingPathComponent("Original.pdf")
            let renamedURL = folder.appendingPathComponent("Renamed.pdf")
            let fixture = PDFDocument()
            fixture.insert(PDFPage(), at: 0)
            try #require(fixture.write(to: originalURL))
            let document = try GlassineDocument(contentsOf: originalURL, ofType: UTType.pdf.identifier)
            document.makeWindowControllers()
            defer { document.close() }
            let pdf = try #require(document.pdf)
            let window = try #require(document.windowControllers.first?.window)

            try FileManager.default.moveItem(at: originalURL, to: renamedURL)
            await deliverMove(document, to: renamedURL)
            try await waitUntil { document.fileURL == renamedURL && window.representedURL == renamedURL }
            #expect(document.pdf === pdf)
            #expect(document.displayName == "Renamed.pdf")

            let note = PDFAnnotation(bounds: CGRect(x: 40, y: 40, width: 20, height: 20),
                                     forType: .text, withProperties: nil)
            note.contents = "Saved after rename"
            pdf.page(at: 0)?.addAnnotation(note)
            document.updateChangeCount(.changeDone)
            let error = await withCheckedContinuation { continuation in
                document.flushHighlights { continuation.resume(returning: $0) }
            }
            #expect(error == nil)
            #expect(!document.isDocumentEdited)
            #expect(!FileManager.default.fileExists(atPath: originalURL.path))
            let reopened = try #require(PDFDocument(url: renamedURL))
            #expect(reopened.page(at: 0)?.annotations.first?.contents == "Saved after rename")
        }
    }

    @Test("Coordinated Markdown renames and folder moves keep automatic refresh working")
    func markdownMoves() async throws {
        try await withFixture { folder in
            let originalURL = folder.appendingPathComponent("Original.md")
            let renamedURL = folder.appendingPathComponent("Renamed.md")
            let destinationFolder = folder.appendingPathComponent("Moved", isDirectory: true)
            try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            let movedURL = destinationFolder.appendingPathComponent("Final.md")
            try "# Original\n\nOriginal text.".write(to: originalURL, atomically: true, encoding: .utf8)
            let document = try GlassineDocument(contentsOf: originalURL,
                                                ofType: GlassineDocument.markdownType.identifier)
            let typesetter = ControlledMarkdownTypesetter()
            document.markdownTypesetter = typesetter
            document.makeWindowControllers()
            // The fixture bypasses NSDocumentController's open workflow.
            NSFileCoordinator.addFilePresenter(document)
            defer {
                NSFileCoordinator.removeFilePresenter(document)
                document.close()
            }
            try #require(typesetter.requests.count == 1)
            var installed = typesetter.succeed(0)
            let window = try #require(document.windowControllers.first?.window)
            try #require(NSFileCoordinator.filePresenters.contains { $0 === document })

            var source = originalURL
            for (index, destination) in [renamedURL, movedURL].enumerated() {
                try await coordinatedMove(from: source, to: destination)
                try await waitUntil { document.fileURL == destination && window.representedURL == destination }
                #expect(document.pdf === installed)
                // Let the watcher finish its queued retarget and any debounce
                // from the move before editing the new path without coordination.
                try await Task.sleep(for: .milliseconds(400))
                let text = "# Revision \(index)\n\nSaved at \(destination.lastPathComponent)."
                try text.write(to: destination, atomically: true, encoding: .utf8)
                try await waitUntil { typesetter.requests.count == index + 2 }
                #expect(typesetter.requests[index + 1].html.contains("Saved at \(destination.lastPathComponent)."))
                installed = typesetter.succeed(index + 1)
                #expect(document.pdf === installed)
                #expect(!FileManager.default.fileExists(atPath: source.path))
                source = destination
            }
        }
    }

    @Test("Closing before queued move handling does not restart Markdown refresh")
    func closeBeforeMoveHandling() async throws {
        try await withFixture { folder in
            let originalURL = folder.appendingPathComponent("Closing.md")
            let renamedURL = folder.appendingPathComponent("Closed.md")
            try "# Closing".write(to: originalURL, atomically: true, encoding: .utf8)
            let document = try GlassineDocument(contentsOf: originalURL,
                                                ofType: GlassineDocument.markdownType.identifier)
            let typesetter = ControlledMarkdownTypesetter()
            document.markdownTypesetter = typesetter
            document.makeWindowControllers()
            try #require(typesetter.requests.count == 1)
            typesetter.succeed(0)

            try FileManager.default.moveItem(at: originalURL, to: renamedURL)
            // Stay on the main actor so the move's queued work cannot run
            // until after close has stopped and released the watcher.
            document.presentedItemDidMove(to: renamedURL)
            document.close()
            try "# Changed after close".write(to: renamedURL, atomically: true, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(600))
            #expect(typesetter.requests.count == 1)
        }
    }
}
