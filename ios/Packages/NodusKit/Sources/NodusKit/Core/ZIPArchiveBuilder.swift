import Foundation
import ZIPFoundation

public enum ZIPArchiveBuilder {
    public struct Entry: Sendable, Hashable {
        public let filename: String
        public let data: Data

        public init(filename: String, data: Data) {
            self.filename = filename
            self.data = data
        }
    }

    public enum Failure: LocalizedError {
        case empty
        public var errorDescription: String? { "There is nothing to export." }
    }

    /// Builds a deterministic flat ZIP suitable for a share sheet.
    public static func build(entries: [Entry], at destination: URL) throws {
        guard !entries.isEmpty else { throw Failure.empty }
        try? FileManager.default.removeItem(at: destination)
        let archive = try Archive(url: destination, accessMode: .create, pathEncoding: nil)
        for entry in entries.sorted(by: { $0.filename < $1.filename }) {
            let name = safeFilename(entry.filename)
            try archive.addEntry(
                with: name,
                type: .file,
                uncompressedSize: Int64(entry.data.count),
                compressionMethod: .deflate,
                provider: { position, size in
                    let lower = Int(position)
                    let upper = min(lower + size, entry.data.count)
                    return entry.data.subdata(in: lower..<upper)
                }
            )
        }
    }

    private static func safeFilename(_ value: String) -> String {
        let leaf = URL(fileURLWithPath: value).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " .-_()"))
        let cleaned = leaf.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        return String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines).prefix(140).description
    }
}
