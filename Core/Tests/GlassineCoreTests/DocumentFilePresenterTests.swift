import Foundation
import Testing
@testable import GlassineCore

@MainActor
@Suite("Document file presenter", .serialized)
struct DocumentFilePresenterTests {
    private func withFile(_ body: @MainActor (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassinePresenter-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Notes.md")
        try Data("first".utf8).write(to: url)
        try await body(url)
    }

    private func registrations(of presenter: DocumentFilePresenter) -> Int {
        NSFileCoordinator.filePresenters.filter { $0 === presenter }.count
    }

    @Test("Background suspends registration, foreground is idempotent, and close is terminal",
          arguments: [false, true])
    func applicationLifecycle(initiallyBackgrounded: Bool) async throws {
        try await withFile { url in
            let presenter = DocumentFilePresenter(url: url, onChange: nil, onMove: { _ in })
            let registration = FilePresenterRegistration(presenter: presenter,
                                                         isBackgrounded: initiallyBackgrounded)
            defer { registration.close() }
            #expect(registrations(of: presenter) == (initiallyBackgrounded ? 0 : 1))
            registration.suspend()
            registration.suspend()
            #expect(registrations(of: presenter) == 0)
            registration.resume()
            registration.resume()
            #expect(registrations(of: presenter) == 1)
            registration.close()
            registration.close()
            registration.resume()
            #expect(registrations(of: presenter) == 0)
        }
    }

    @Test("A session closed before its first foreground never registers")
    func closeWhileBackgrounded() async throws {
        try await withFile { url in
            let presenter = DocumentFilePresenter(url: url, onChange: nil, onMove: { _ in })
            let registration = FilePresenterRegistration(presenter: presenter, isBackgrounded: true)
            registration.close()
            registration.resume()
            #expect(registrations(of: presenter) == 0)
        }
    }

    @Test("Releasing one session removes only its registration")
    func sessionLifetime() async throws {
        try await withFile { url in
            let first = DocumentFilePresenter(url: url, onChange: nil, onMove: { _ in })
            let second = DocumentFilePresenter(url: url, onChange: nil, onMove: { _ in })
            var registration: FilePresenterRegistration? = FilePresenterRegistration(
                presenter: first, isBackgrounded: false)
            let other = FilePresenterRegistration(presenter: second, isBackgrounded: false)
            defer { other.close() }
            #expect(registration != nil)
            #expect(registrations(of: first) == 1)
            registration = nil
            #expect(registrations(of: first) == 0)
            #expect(registrations(of: second) == 1)
        }
    }

}
