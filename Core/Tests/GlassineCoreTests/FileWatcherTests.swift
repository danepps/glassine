import Foundation
import Testing
@testable import GlassineCore

@MainActor
@Suite("FileWatcher", .serialized)
struct FileWatcherTests {

    private final class Counter { var count = 0 }

    private func withFile(_ body: (URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassineWatcher-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("watched.pdf")
        try Data("first".utf8).write(to: url)
        try await body(url)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition())
    }

    @Test("A write by someone else is reported once")
    func reportsOutsideWrite() async throws {
        try await withFile { url in
            let counter = Counter()
            let watcher = FileWatcher(url: url) { counter.count += 1 }
            defer { watcher.stop() }
            try await Task.sleep(for: .milliseconds(100))
            try Data("second, and longer".utf8).write(to: url, options: .atomic)
            try await waitUntil { counter.count == 1 }
            try await Task.sleep(for: .milliseconds(500))
            #expect(counter.count == 1)
        }
    }

    @Test("A write the owner claims with acceptCurrentState is not reported")
    func ownWriteIsSwallowed() async throws {
        try await withFile { url in
            let counter = Counter()
            let watcher = FileWatcher(url: url) { counter.count += 1 }
            defer { watcher.stop() }
            try await Task.sleep(for: .milliseconds(100))
            try Data("saved by the owner".utf8).write(to: url, options: .atomic)
            watcher.acceptCurrentState()
            try await Task.sleep(for: .milliseconds(600))
            #expect(counter.count == 0)

            // ...and the next outside write is still seen.
            try Data("then someone else".utf8).write(to: url, options: .atomic)
            try await waitUntil { counter.count == 1 }
        }
    }

    @Test("A change already on its way to the main actor is dropped once claimed")
    func inFlightChangeIsDropped() async throws {
        try await withFile { url in
            let counter = Counter()
            let watcher = FileWatcher(url: url) { counter.count += 1 }
            defer { watcher.stop() }
            try Data("saved by the owner".utf8).write(to: url, options: .atomic)
            watcher.poke()
            // Hold the main actor past the debounce, so the watcher has seen the
            // change and queued its delivery before the owner claims the write.
            Thread.sleep(forTimeInterval: 0.5)
            watcher.acceptCurrentState()
            try await Task.sleep(for: .milliseconds(400))
            #expect(counter.count == 0)
        }
    }
}
