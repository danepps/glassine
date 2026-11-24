import Foundation

/// Watches one file and reports when its contents actually changed.
///
/// NSFilePresenter is not enough: `presentedItemDidChange` only fires for
/// writers that go through NSFileCoordinator, which text editors and AI command
/// line tools generally do not. So this watches the vnode directly -- and also
/// the containing directory, because the common "atomic save" (write a temp
/// file, rename it into place) leaves the original vnode untouched and shows up
/// only as a write on the directory.
///
/// Every event is debounced and then gated on a `(inode, mtime, size)`
/// signature, so a save that rewrites identical bytes, or one editor's flurry of
/// writes, produces at most one callback.
/// `@unchecked Sendable` because it really is: every mutable field is touched
/// only on `queue` (or before that queue starts), which is exactly what the
/// note below the properties says.
public final class FileWatcher: @unchecked Sendable {

    private struct Signature: Equatable {
        var inode: UInt64
        var modified: TimeInterval
        var size: Int64
    }

    private static let debounce: TimeInterval = 0.25
    private static let reopenDelay: TimeInterval = 0.2
    private static let maxReopenAttempts = 5

    /// Delivered on the main actor.
    private let onChange: @MainActor @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.epps.Glassine.FileWatcher")

    // Everything below is touched only on `queue` (or before it starts).
    private var url: URL
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var signature: Signature?
    private var pending: DispatchWorkItem?
    private var reopenAttempts = 0
    private var stopped = false
    /// Bumped by `acceptCurrentState()` and `retarget(to:)`. A change already on
    /// its way to the main actor carries the epoch it was seen in, and is dropped
    /// there if the owner has since accepted that state or changed the URL.
    private var epoch = 0

    public init(url: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
        self.signature = Self.signature(of: url)
        queue.async { [weak self] in self?.openSources() }
    }

    /// Not `stop()`: the last reference can be dropped from inside one of the
    /// watcher's own queue blocks, and then `queue.sync` would deadlock on the
    /// serial queue it is already running on. Nothing else can reach these
    /// fields during deinit, so touch them directly.
    deinit {
        stopped = true
        pending?.cancel()
        fileSource?.cancel()
        directorySource?.cancel()
    }

    public func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            pending?.cancel()
            pending = nil
            fileSource?.cancel()
            fileSource = nil
            directorySource?.cancel()
            directorySource = nil
        }
    }

    /// Follow the owner's new URL, adopting its current state. Retire queued
    /// checks and deliveries from the old file before returning, just as for
    /// an accepted save. The watcher's queue never waits on the main actor.
    public func retarget(to newURL: URL) {
        queue.sync {
            guard !self.stopped else { return }
            self.pending?.cancel()
            self.pending = nil
            self.epoch &+= 1
            self.url = newURL
            self.signature = Self.signature(of: newURL)
            self.fileSource?.cancel()
            self.fileSource = nil
            self.directorySource?.cancel()
            self.directorySource = nil
            self.reopenAttempts = 0
            self.openSources()
        }
    }

    /// Take the file as it is now as the baseline, and drop any change already
    /// seen but not yet delivered. For an owner that has just written the file
    /// itself (Glassine saving highlights into a PDF), so its own save is not
    /// reported back to it as somebody else's.
    ///
    /// Synchronous, so that by the time it returns no earlier change can still
    /// arrive. Safe from the main actor: the watcher's queue never waits on main.
    public func acceptCurrentState() {
        queue.sync {
            guard !stopped else { return }
            pending?.cancel()
            pending = nil
            signature = Self.signature(of: url)
            epoch &+= 1
        }
    }

    /// Ask for a check now (the NSFilePresenter callback routes in here so both
    /// paths share one debounce and one signature gate).
    public func poke() {
        queue.async { [weak self] in self?.scheduleNotify() }
    }

    // MARK: Sources

    private func openSources() {
        guard !stopped else { return }

        if fileSource == nil {
            let descriptor = open(url.path, O_EVTONLY)
            if descriptor >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor,
                    eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
                    queue: queue)
                source.setEventHandler { [weak self] in self?.handleFileEvent() }
                source.setCancelHandler { close(descriptor) }
                fileSource = source
                reopenAttempts = 0
                source.resume()
            } else {
                scheduleReopen()
            }
        }

        if directorySource == nil {
            let directory = url.deletingLastPathComponent()
            let descriptor = open(directory.path, O_EVTONLY)
            if descriptor >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor, eventMask: [.write], queue: queue)
                source.setEventHandler { [weak self] in self?.scheduleNotify() }
                source.setCancelHandler { close(descriptor) }
                directorySource = source
                source.resume()
            }
        }
    }

    private func handleFileEvent() {
        guard !stopped, let source = fileSource else { return }
        let flags = source.data
        // The vnode we hold is gone (renamed over, deleted, or unmounted): drop
        // it and pick up whatever now lives at the path.
        if !flags.isDisjoint(with: [.delete, .rename, .revoke]) {
            source.cancel()
            fileSource = nil
            reopenAttempts = 0
            scheduleReopen()
        }
        scheduleNotify()
    }

    private func scheduleReopen() {
        guard !stopped, reopenAttempts < Self.maxReopenAttempts else { return }
        reopenAttempts += 1
        queue.asyncAfter(deadline: .now() + Self.reopenDelay) { [weak self] in
            guard let self, !self.stopped, self.fileSource == nil else { return }
            self.openSources()
        }
    }

    private func scheduleNotify() {
        guard !stopped else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.pending = nil
            // A file recreated at the same path needs a fresh descriptor.
            if self.fileSource == nil {
                self.reopenAttempts = 0
                self.openSources()
            }
            guard let current = Self.signature(of: self.url), current != self.signature else {
                return
            }
            self.signature = current
            let notify = self.onChange
            let seenIn = self.epoch
            // The work item runs on the watcher's private queue; hop to main,
            // where the callback is declared to run -- unless, by the time it
            // gets there, the watcher has been stopped or the owner has claimed
            // this state of the file as its own write.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isLive(epoch: seenIn) else { return }
                MainActor.assumeIsolated { notify() }
            }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    private func isLive(epoch seenIn: Int) -> Bool {
        queue.sync { !stopped && epoch == seenIn }
    }

    private static func signature(of url: URL) -> Signature? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Signature(
            inode: UInt64(info.st_ino),
            modified: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000,
            size: Int64(info.st_size))
    }
}
