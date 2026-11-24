import Foundation
import Testing
@testable import GlassineCore

@Suite("Temporary exports")
struct TemporaryExportTests {
    @Test("Same-named exports keep distinct bytes until each picker finishes")
    func sameNameExports() throws {
        let first = try TemporaryExport(data: Data("Window A".utf8), filename: "Notes.pdf")
        let second = try TemporaryExport(data: Data("Window B".utf8), filename: "Notes.pdf")
        defer { first.remove(); second.remove() }
        #expect(first.url != second.url)
        #expect(first.url.lastPathComponent == "Notes.pdf")
        #expect(second.url.lastPathComponent == "Notes.pdf")
        #expect(try Data(contentsOf: first.url) == Data("Window A".utf8))
        #expect(try Data(contentsOf: second.url) == Data("Window B".utf8))
        first.remove()
        first.remove()
        #expect(!FileManager.default.fileExists(atPath: first.url.deletingLastPathComponent().path))
        #expect(try Data(contentsOf: second.url) == Data("Window B".utf8))
        second.remove()
        #expect(!FileManager.default.fileExists(atPath: second.url.deletingLastPathComponent().path))
    }

    @Test("Dropping an unpresented or dismissed export removes its directory")
    func abandonedExport() throws {
        var export: TemporaryExport? = try TemporaryExport(data: Data("PDF".utf8), filename: "Notes.pdf")
        let directory = try #require(export?.url.deletingLastPathComponent())
        export = nil
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("A write failure propagates its error, removes its directory, and allows retry")
    func failedWrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassineExportTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A missing subdirectory fails after the per-export directory exists.
        #expect(throws: (any Error).self) {
            _ = try TemporaryExport(data: Data("PDF".utf8), filename: "missing/Notes.pdf",
                                    temporaryDirectory: root)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let retry = try TemporaryExport(data: Data("PDF".utf8), filename: "Notes.pdf",
                                        temporaryDirectory: root)
        #expect(try Data(contentsOf: retry.url) == Data("PDF".utf8))
        retry.remove()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
