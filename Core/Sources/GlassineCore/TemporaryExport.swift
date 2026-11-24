import Foundation

/// Owns a file until its export picker finishes. Each export has its own
/// directory so a second window can use the same readable filename safely.
public final class TemporaryExport: Identifiable, Sendable {
    public let id = UUID()
    public let url: URL
    private let directory: URL

    public init(data: Data, filename: String,
                temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws {
        directory = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent(filename)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Explicit on completion or cancellation; deinit also covers a dismissed
    /// sheet or a reader that disappears before the picker can be presented.
    public func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { remove() }
}
