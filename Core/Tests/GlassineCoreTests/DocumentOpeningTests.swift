import Foundation
import Testing
@testable import GlassineCore

@MainActor
@Suite("Document opening", .serialized)
struct DocumentOpeningTests {
    private final class Changes { var count = 0 }

    private final class Barrier: Sendable {
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)

        func pause() {
            entered.signal()
            #expect(proceed.wait(timeout: .now() + 5) == .success)
        }

        func waitForEntry() async {
            let arrived = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: self.entered.wait(timeout: .now() + 5) == .success)
                }
            }
            #expect(arrived)
        }
    }

    /// A nonblocking probe is safe on main; only the worker waits for release.
    private func signaled(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now()) == .success
    }

    private func withFile(_ body: @MainActor (URL) async throws -> Void) async throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/Opening-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Notes.md")
        try Data("first".utf8).write(to: url)
        try await body(url)
    }

    private func registrations(of presenter: DocumentFilePresenter) -> Int {
        NSFileCoordinator.filePresenters.filter { $0 === presenter }.count
    }

    @Test("A newer open retires the old result, and close rejects every later open")
    func generationIsTerminal() throws {
        let gate = DocumentOpenGeneration()
        let first = try #require(gate.begin())
        let second = try #require(gate.begin())
        #expect(!gate.accepts(first))
        #expect(gate.accepts(second))
        gate.close()
        gate.close()
        #expect(!gate.accepts(first))
        #expect(!gate.accepts(second))
        #expect(gate.begin() == nil)
    }

    @Test("Main remains available during a worker read; stale reads cannot register",
          arguments: [false, true])
    func retireDuringRead(close: Bool) async throws {
        try await withFile { url in
            let gate = DocumentOpenGeneration()
            let generation = try #require(gate.begin())
            let presenter = DocumentFilePresenter(url: url, onChange: nil, onMove: { _ in })
            let registration = FilePresenterRegistration(presenter: presenter, isBackgrounded: false,
                                                         initialReadPending: true)
            defer { registration.close() }
            let barrier = Barrier()
            defer { barrier.proceed.signal() }
            let worker = Task.detached {
                CoordinatedDocumentRead<Data>.read(at: url, presenter: presenter, registration: registration,
                                                  coordinate: { url, accessor in accessor(url) }) {
                    #expect(!Thread.isMainThread)
                    barrier.pause()
                    return try? Data(contentsOf: $0)
                }
            }
            await barrier.waitForEntry()
            // These main-actor actions finish while the read is still held.
            #expect(registrations(of: presenter) == 0)
            if close { gate.close() } else { _ = gate.begin() }
            registration.close()
            barrier.proceed.signal()
            let result = await worker.value
            #expect(result?.value == Data("first".utf8))
            #expect(!gate.accepts(generation))
            registration.resume()
            #expect(registrations(of: presenter) == 0)
        }
    }

    @Test("Backgrounding during a read defers registration until foreground",
          arguments: [false, true])
    func backgroundDuringRead(initiallyBackgrounded: Bool) async throws {
        try await withFile { url in
            let presenter = DocumentFilePresenter(url: url, onChange: nil, onMove: { _ in })
            let registration = FilePresenterRegistration(presenter: presenter,
                                                         isBackgrounded: initiallyBackgrounded,
                                                         initialReadPending: true)
            defer { registration.close() }
            let barrier = Barrier()
            defer { barrier.proceed.signal() }
            let worker = Task.detached {
                CoordinatedDocumentRead<Data>.read(at: url, presenter: presenter, registration: registration,
                                                  coordinate: { url, accessor in accessor(url) }) {
                    barrier.pause()
                    return try? Data(contentsOf: $0)
                }
            }
            await barrier.waitForEntry()
            registration.resume()
            #expect(registrations(of: presenter) == 0)
            registration.suspend()
            barrier.proceed.signal()
            let result = await worker.value
            #expect(result != nil)
            #expect(registrations(of: presenter) == 0)
            registration.resume()
            registration.resume()
            #expect(registrations(of: presenter) == 1)
        }
    }

    @Test("Closing or superseding after registration retires the undelivered result",
          arguments: [false, true])
    func retireBeforeDelivery(close: Bool) async throws {
        try await withFile { url in
            let gate = DocumentOpenGeneration()
            let generation = try #require(gate.begin())
            let presenter = DocumentFilePresenter(url: url, onChange: nil, onMove: { _ in })
            let registration = FilePresenterRegistration(presenter: presenter, isBackgrounded: false,
                                                         initialReadPending: true)
            defer { registration.close() }
            let barrier = Barrier()
            defer { barrier.proceed.signal() }
            let worker = Task.detached {
                let result = CoordinatedDocumentRead<Data>.read(
                    at: url, presenter: presenter, registration: registration,
                    coordinate: { url, accessor in accessor(url) },
                    read: { try? Data(contentsOf: $0) })
                barrier.pause()
                return result
            }
            await barrier.waitForEntry()
            #expect(registrations(of: presenter) == 1)
            if close { gate.close() } else { _ = gate.begin() }
            registration.close()
            barrier.proceed.signal()
            #expect(await worker.value != nil)
            #expect(!gate.accepts(generation))
            #expect(registrations(of: presenter) == 0)
        }
    }

    @Test("The presenter is registered before the coordinated accessor exits")
    func registrationPrecedesAccessorExit() async throws {
        try await withFile { url in
            let presenter = DocumentFilePresenter(url: url, onChange: nil, onMove: { _ in })
            let registration = FilePresenterRegistration(presenter: presenter, isBackgrounded: false,
                                                         initialReadPending: true)
            defer { registration.close() }
            let result = await Task.detached {
                CoordinatedDocumentRead<Data>.read(
                    at: url, presenter: presenter, registration: registration,
                    coordinate: { url, accessor in
                        #expect(!NSFileCoordinator.filePresenters.contains { $0 === presenter })
                        accessor(url)
                        // The next writer is eligible as soon as this accessor
                        // exits, before main has received any result.
                        #expect(NSFileCoordinator.filePresenters.contains { $0 === presenter })
                        try? Data("a newer revision".utf8).write(to: url)
                    }, read: { try? Data(contentsOf: $0) })
            }.value
            #expect(result?.value == Data("first".utf8))
            let written = try Data(contentsOf: url)
            #expect(written == Data("a newer revision".utf8))
        }
    }

    @Test("A save after reading still reaches the watcher before result installation")
    func watcherKeepsReadBaseline() async throws {
        try await withFile { url in
            let changes = Changes()
            let presenter = DocumentFilePresenter(url: url, onChange: nil, onMove: { _ in })
            let registration = FilePresenterRegistration(presenter: presenter, isBackgrounded: false,
                                                         initialReadPending: true)
            defer { registration.close() }
            let result = await Task.detached {
                CoordinatedDocumentRead<Data>.read(at: url, presenter: presenter, registration: registration,
                                                  onChange: { changes.count += 1 },
                                                  coordinate: { url, accessor in accessor(url) },
                                                  read: { try? Data(contentsOf: $0) })
            }.value
            let opened = try #require(result)
            defer { opened.watcher?.stop() }
            #expect(opened.value == Data("first".utf8))
            try Data("saved during conversion".utf8).write(to: url, options: .atomic)
            opened.watcher?.poke()
            let deadline = Date().addingTimeInterval(5)
            while changes.count == 0 && Date() < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(changes.count == 1)
        }
    }

    @Test("A failed read leaves no presenter, even after foreground")
    func failedReadClosesRegistration() async throws {
        try await withFile { url in
            let presenter = DocumentFilePresenter(url: url, onChange: nil, onMove: { _ in })
            let registration = FilePresenterRegistration(presenter: presenter, isBackgrounded: false,
                                                         initialReadPending: true)
            defer { registration.close() }
            let result = await Task.detached {
                CoordinatedDocumentRead<Data>.read(at: url, presenter: presenter, registration: registration,
                                                  coordinate: { url, accessor in accessor(url) },
                                                  read: { _ in nil })
            }.value
            #expect(result == nil)
            registration.resume()
            #expect(registrations(of: presenter) == 0)
        }
    }

    @Test("Coordination failure never registers a presenter or reads the file")
    func coordinationFailureClosesRegistration() async throws {
        try await withFile { url in
            let presenter = DocumentFilePresenter(url: url, onChange: nil, onMove: { _ in })
            let registration = FilePresenterRegistration(presenter: presenter, isBackgrounded: false,
                                                         initialReadPending: true)
            defer { registration.close() }
            let result = await Task.detached {
                CoordinatedDocumentRead<Data>.read(
                    at: url, presenter: presenter, registration: registration,
                    coordinate: { _, _ in }, read: { _ in
                        Issue.record("A failed coordinator must not call the reader")
                        return nil
                    })
            }.value
            #expect(result == nil)
            registration.resume()
            #expect(registrations(of: presenter) == 0)
        }
    }

    @Test("The worker retains security access after the owner releases it")
    func accessOutlivesOwner() async {
        let released = DispatchSemaphore(value: 0)
        var access: DocumentAccess? = DocumentAccess(release: { released.signal() })
        let barrier = Barrier()
        defer { barrier.proceed.signal() }
        let worker = Task.detached { [access] in
            withExtendedLifetime(access) { barrier.pause() }
        }
        await barrier.waitForEntry()
        access = nil
        #expect(!signaled(released))
        barrier.proceed.signal()
        await worker.value
        let didRelease = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: released.wait(timeout: .now() + 5) == .success)
            }
        }
        #expect(didRelease)
        #expect(!signaled(released))
    }
}
