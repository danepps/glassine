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
        setURL(newURL)
        MainActor.assumeIsolated { onMove(newURL) }
    }

    /// The coordinated accessor can supply a different URL from the one that
    /// was requested. Adopt it before registration, without delivering a move.
    func setURL(_ newURL: URL) {
        urlLock.lock()
        url = newURL
        urlLock.unlock()
    }
}

/// Owns one registration across application background/foreground transitions.
/// Keeping the presenter while suspended preserves its URL, but does not leave
/// it registered with Foundation while iOS can suspend the process.
/// `@unchecked Sendable` because the lock serializes both the state and the
/// Foundation calls. Completing a worker read must not race a main-actor
/// suspension or close, and must never wait synchronously for the main queue.
public final class FilePresenterRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private let presenter: any NSFilePresenter & Sendable
    private var isRegistered = false
    private var isClosed = false
    private var isBackgrounded: Bool
    private var initialReadPending: Bool

    public init(presenter: any NSFilePresenter & Sendable, isBackgrounded: Bool,
                initialReadPending: Bool = false) {
        self.presenter = presenter
        self.isBackgrounded = isBackgrounded
        self.initialReadPending = initialReadPending
        if !isBackgrounded, !initialReadPending { resume() }
    }

    deinit {
        if isRegistered { NSFileCoordinator.removeFilePresenter(presenter) }
    }

    public func suspend() {
        lock.lock()
        defer { lock.unlock() }
        isBackgrounded = true
        removeRegistration()
    }

    public func resume() {
        lock.lock()
        defer { lock.unlock() }
        isBackgrounded = false
        addRegistration()
    }

    /// Called inside the initial read's coordinated accessor. A foreground
    /// event before this point must not register a presenter ahead of its read.
    public func completeInitialRead() {
        lock.lock()
        defer { lock.unlock() }
        initialReadPending = false
        addRegistration()
    }

    private func addRegistration() {
        guard !isClosed, !isBackgrounded, !initialReadPending, !isRegistered else { return }
        NSFileCoordinator.addFilePresenter(presenter)
        isRegistered = true
    }

    private func removeRegistration() {
        guard isRegistered else { return }
        NSFileCoordinator.removeFilePresenter(presenter)
        isRegistered = false
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        isClosed = true
        removeRegistration()
    }
}
