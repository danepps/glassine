import Foundation

/// An initial read can finish after close or after a later open. Only the
/// newest generation may install its result, and closing is terminal.
@MainActor
public final class DocumentOpenGeneration {
    private var generation = 0
    private var isClosed = false

    public init() {}

    public func begin() -> Int? {
        guard !isClosed else { return nil }
        generation &+= 1
        return generation
    }

    public func accepts(_ candidate: Int) -> Bool {
        !isClosed && candidate == generation
    }

    public func close() { isClosed = true }
}

/// The session and each in-flight worker share this token. Closing the session
/// releases its ownership, but cannot end access underneath a coordinated read.
public final class DocumentAccess: Sendable {
    private let release: (@Sendable () -> Void)?

    public init(url: URL) {
        if url.startAccessingSecurityScopedResource() {
            release = { url.stopAccessingSecurityScopedResource() }
        } else {
            release = nil
        }
    }

    package init(release: @escaping @Sendable () -> Void) {
        self.release = release
    }

    deinit { release?() }
}

/// The watcher starts with a baseline no newer than the bytes being read.
/// Its notifications can arrive before main installs the result, so the owner
/// must buffer them until then and poke it again after installation.
public struct CoordinatedDocumentRead<Value: Sendable>: Sendable {
    public let value: Value
    public let url: URL
    public let watcher: FileWatcher?

    /// This synchronous operation belongs on a worker. Registration stays in
    /// the accessor so a coordinated save or move cannot fall between the
    /// initial read and the presenter becoming visible to Foundation.
    public static func read(at url: URL,
                            presenter: DocumentFilePresenter,
                            registration: FilePresenterRegistration,
                            onChange: (@MainActor @Sendable () -> Void)? = nil,
                            read: @escaping (URL) -> Value?) -> Self? {
        Self.read(at: url, presenter: presenter, registration: registration, onChange: onChange,
                  coordinate: { url, accessor in
                      var error: NSError?
                      NSFileCoordinator().coordinate(readingItemAt: url, options: [],
                                                     error: &error, byAccessor: accessor)
                  }, read: read)
    }

    /// A test can hold the accessor or inspect its exit without needing the
    /// system file-coordination service, which is unavailable in the sandbox.
    package static func read(at url: URL,
                             presenter: DocumentFilePresenter,
                             registration: FilePresenterRegistration,
                             onChange: (@MainActor @Sendable () -> Void)? = nil,
                             coordinate: (URL, (URL) -> Void) -> Void,
                             read: @escaping (URL) -> Value?) -> Self? {
        var result: Self?
        coordinate(url) { readURL in
            let watcher = onChange.map { FileWatcher(url: readURL, onChange: $0) }
            guard let value = read(readURL) else {
                watcher?.stop()
                return
            }
            presenter.setURL(readURL)
            registration.completeInitialRead()
            result = Self(value: value, url: readURL, watcher: watcher)
        }
        if result == nil { registration.close() }
        return result
    }
}
