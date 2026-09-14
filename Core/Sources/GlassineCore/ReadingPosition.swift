import CoreGraphics
import Foundation
import PDFKit

/// Reading-position memory for one document: what gets saved, when saving is
/// allowed, and how a jump is actually landed.
///
/// Three things here are load-bearing and were all learned the hard way:
///
/// - The saved position is read **once**, at init. `PDFView` posts page-change
///   notifications while it lays out, reporting page 1, and those would
///   otherwise overwrite the stored position before it was ever restored.
/// - `restoreFinished` gates every save, and goes false again across a document
///   swap for the same reason.
/// - A jump is two run-loop passes: `PDFView` silently ignores `go(to:)` before
///   it has laid the document out, so the layout is forced and the jump made on
///   the next pass, then confirmed and retried once if it did not land.
///
/// `lastInstallTarget` is what the next install aims at while a restore is in
/// flight: a burst of saves can land a second render while the first install's
/// two-pass jump is still running, and the live destination is meaningless at
/// that moment.
@MainActor
public final class ReadingPosition {

    /// Read once at init.
    public let saved: Prefs.Position?
    public private(set) var restoreStarted = false
    public private(set) var restoreFinished = false
    public private(set) var lastInstallTarget: Prefs.Position?
    private var jumpGeneration = 0
    private var deferredInstall: (document: PDFDocument, completion: @MainActor () -> Void)?

    private weak var pdfView: PDFView?
    private let url: @MainActor () -> URL?

    public init(pdfView: PDFView,
                saved: Prefs.Position?,
                url: @escaping @MainActor () -> URL?) {
        self.pdfView = pdfView
        self.saved = saved
        self.url = url
    }

    // MARK: Saving

    /// Where the top-left of the visible area is, as a saved position.
    ///
    /// The two platforms need different questions asked. macOS's
    /// `currentDestination` sits a gutter above the top of the visible area,
    /// which is what every restore here has always aimed at. On iOS it comes
    /// back near the *bottom* of the visible area instead (measured: y = 4.9 out
    /// of 792 for a reader parked at the top of a page), so restoring it walks
    /// the reader forward a page every time; `convert(_:to:)` on the view's own
    /// origin is the point `go(to:)` will put back where it came from.
    @MainActor
    private static func current(of pdfView: PDFView) -> Prefs.Position? {
        guard let pdf = pdfView.document else { return nil }
        #if canImport(UIKit)
        // The page under the view's top-left corner, not `currentPage`: at a
        // page break PDFKit calls the *lower* page current, and saving its top
        // would move the reader on every reopen.
        guard let page = pdfView.page(for: .zero, nearest: true) else { return nil }
        let index = pdf.index(for: page)
        guard index != NSNotFound else { return nil }
        let topLeft = pdfView.convert(CGPoint.zero, to: page)
        return Prefs.Position(pageIndex: index, x: topLeft.x, y: topLeft.y)
        #else
        guard let destination = pdfView.currentDestination,
              let page = destination.page else { return nil }
        let index = pdf.index(for: page)
        guard index != NSNotFound else { return nil }
        return Prefs.Position(pageIndex: index,
                              x: destination.point.x,
                              y: destination.point.y)
        #endif
    }

    public func save() {
        // Nothing is worth saving until the restore has run: the layout-time
        // page changes all report page 1.
        guard restoreFinished else { return }
        guard let fileURL = url(), let pdfView,
              let position = Self.current(of: pdfView) else { return }
        Prefs.setLastPosition(position, for: fileURL)
    }

    /// A window can close between the two queued passes of a position restore.
    /// In that case its live destination is still a layout artifact, while the
    /// recorded install target is the position the reader intended to retain.
    /// A first Markdown install can have a target before restoreStarted is set.
    public func saveOnClose() {
        if restoreFinished {
            save()
            return
        }
        guard let fileURL = url(), let target = lastInstallTarget else { return }
        Prefs.setLastPosition(target, for: fileURL)
    }

    // MARK: Restoring

    /// Restore the saved position, once. `completion` runs when the restore has
    /// finished (or immediately when there is nothing to restore), which is when
    /// the page readout is worth rebuilding.
    public func restoreIfNeeded(completion: @escaping @MainActor () -> Void) {
        guard !restoreStarted else { return }
        if deferredInstall == nil { lastInstallTarget = lastInstallTarget ?? saved }
        // A Markdown document has no PDF yet when its window is shown, and a
        // locked PDF cannot supply a usable destination until it is unlocked.
        // Leave restoreStarted false so installation or unlock can retry.
        guard let pdfView, let pdf = pdfView.document, !pdf.isLocked else { return }
        restoreStarted = true

        if let pending = deferredInstall {
            deferredInstall = nil
            if pending.document === pdf {
                // The replacement's page count was unavailable while locked.
                // Clamp now, and complete the install that was waiting for it
                // before delivering the unlock caller's completion.
                aim(in: pdf, target: lastInstallTarget) { [weak self] in
                    guard let self else { return }
                    self.restoreFinished = true
                    pending.completion()
                    completion()
                }
                return
            }
            // A caller replaced the view's document without beginInstall.
            // Do not deliver another document's deferred completion or target.
            lastInstallTarget = saved
        }

        guard let target = lastInstallTarget,
              target.pageIndex > 0 || target.x != 0 || target.y != 0,
              target.pageIndex >= 0,
              target.pageIndex < pdf.pageCount,
              let page = pdf.page(at: target.pageIndex)
        else {
            restoreFinished = true
            completion()
            return
        }

        let destination = PDFDestination(page: page, at: CGPoint(x: target.x, y: target.y))
        jump(to: destination, expectingPageIndex: target.pageIndex) { [weak self] in
            guard let self else { return }
            self.restoreFinished = true
            completion()
        }
    }

    // MARK: Installing a replacement document

    /// Where the next install should aim. On the first render there is nothing
    /// on screen yet, so the saved position is it; on a reload, hold the place
    /// the reader is actually looking at -- unless a restore is still in flight,
    /// when the live destination is meaningless and the last install's target is
    /// the better answer.
    public func targetForInstall(initial: Bool) -> Prefs.Position? {
        var target = initial ? saved : lastInstallTarget
        if !initial, restoreFinished, let pdfView, let live = Self.current(of: pdfView) {
            target = live
        }
        return target
    }

    /// Call before assigning the replacement document: assigning one makes
    /// `PDFView` lay out and report page 1, and those reports would overwrite
    /// the position being restored.
    public func beginInstall() {
        jumpGeneration &+= 1
        deferredInstall = nil
        restoreFinished = false
    }

    /// Call after the replacement document has been assigned to the view.
    /// Clamps the target to the new page count, records it, and jumps.
    public func aim(in document: PDFDocument,
                    target: Prefs.Position?,
                    completion: @escaping @MainActor () -> Void) {
        guard !document.isLocked else {
            // A locked replacement may report no pages. Keep the intended
            // target unmodified, and finish this install only after unlock.
            lastInstallTarget = target
            deferredInstall = (document, completion)
            restoreStarted = false
            restoreFinished = false
            return
        }
        let clamped = target.map {
            Prefs.Position(pageIndex: min(max($0.pageIndex, 0), max(document.pageCount - 1, 0)),
                           x: $0.x, y: $0.y)
        }
        lastInstallTarget = clamped
        guard let clamped, let page = document.page(at: clamped.pageIndex) else {
            completion()
            return
        }
        let destination = PDFDestination(page: page, at: CGPoint(x: clamped.x, y: clamped.y))
        jump(to: destination, expectingPageIndex: clamped.pageIndex, completion: completion)
    }

    /// Call once the install's jump has run.
    public func finishInstall() {
        restoreStarted = true
        restoreFinished = true
    }

    // MARK: Jumping

    /// PDFView silently ignores go(to:) before it has laid the document out, so
    /// force layout and jump on the next runloop pass; then confirm we actually
    /// landed on the expected page and retry once if not.
    private func jump(to destination: PDFDestination,
                      expectingPageIndex index: Int,
                      completion: @escaping @MainActor () -> Void) {
        let generation = jumpGeneration
        guard let document = destination.page?.document else {
            completion()
            return
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.jumpGeneration == generation,
                      let pdfView = self.pdfView, pdfView.document === document else { return }
                pdfView.layoutDocumentView()
                pdfView.go(to: destination)

                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self.jumpGeneration == generation, pdfView.document === document else { return }
                        let landed = pdfView.currentPage
                            .map { pdfView.document?.index(for: $0) ?? NSNotFound } ?? NSNotFound
                        if landed != index { pdfView.go(to: destination) }
                        completion()
                    }
                }
            }
        }
    }
}
