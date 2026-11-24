import Foundation

/// Tracks moves for an open document and optionally forwards coordinated saves
/// into its watcher. The callbacks run on the presenter's main operation queue.
///
/// `@unchecked Sendable` because the URL is protected by `urlLock`, including
/// Foundation's reads from arbitrary queues. The callbacks are immutable and
/// main-actor-isolated; the lock is released before invoking either one.
public final class DocumentFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {

    private let urlLock = NSLock()
    private var url: URL
    public var presentedItemURL: URL? {
        urlLock.lock()
        defer { urlLock.unlock() }
        return url
    }

    public let presentedItemOperationQueue = OperationQueue.main
    private let onChange: (@MainActor () -> Void)?
    private let onMove: @MainActor (URL) -> Void

    public init(url: URL,
                onChange: (@MainActor () -> Void)?,
                onMove: @escaping @MainActor (URL) -> Void) {
        self.url = url
        self.onChange = onChange
        self.onMove = onMove
        super.init()
    }

    public func presentedItemDidChange() {
        guard let onChange else { return }
        MainActor.assumeIsolated { onChange() }
    }

    public func presentedItemDidMove(to newURL: URL) {
        urlLock.lock()
        url = newURL
        urlLock.unlock()
        MainActor.assumeIsolated { onMove(newURL) }
    }
}

/// Owns one registration across application background/foreground transitions.
/// Keeping the presenter while suspended preserves its URL, but does not leave
/// it registered with Foundation while iOS can suspend the process.
@MainActor
public final class FilePresenterRegistration {
    private let presenter: any NSFilePresenter & Sendable
    private var isRegistered = false
    private var isClosed = false

    public init(presenter: any NSFilePresenter & Sendable, isBackgrounded: Bool) {
        self.presenter = presenter
        if !isBackgrounded { resume() }
    }

    deinit {
        if isRegistered { NSFileCoordinator.removeFilePresenter(presenter) }
    }

    public func suspend() {
        guard isRegistered else { return }
        NSFileCoordinator.removeFilePresenter(presenter)
        isRegistered = false
    }

    public func resume() {
        guard !isClosed, !isRegistered else { return }
        NSFileCoordinator.addFilePresenter(presenter)
        isRegistered = true
    }

    public func close() {
        isClosed = true
        suspend()
    }
}
