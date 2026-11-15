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

    public struct StreamingEntry: Sendable {
        public let filename: String
        public let byteCount: Int64
        public let read: @Sendable (Int64, Int) throws -> Data
        public init(filename: String, byteCount: Int64, read: @escaping @Sendable (Int64, Int) throws -> Data) {
            self.filename = filename; self.byteCount = byteCount; self.read = read
        }
    }
    /// Stored ZIP entries have a conservative finite disk reservation without
    /// reading their content or buffering an entire user-authored file.
    public static func streamingReservation(entries: [StreamingEntry]) throws -> Int64 {
        guard !entries.isEmpty else { throw Failure.empty }
        var bytes: Int64 = 1_048_576
        var names = Set<String>()
        for entry in entries {
            let name = safeFilename(entry.filename)
            guard !name.isEmpty, entry.byteCount >= 0, names.insert(name).inserted else { throw Failure.invalidEntry }
            let (size, overflow) = entry.byteCount.addingReportingOverflow(4096)
            let (next, totalOverflow) = bytes.addingReportingOverflow(size)
            guard !overflow, !totalOverflow else { throw Failure.invalidEntry }; bytes = next
        }
        return bytes
    }
    public static func buildStreaming(entries: [StreamingEntry], at destination: URL, progress: Progress? = nil) throws {
        _ = try streamingReservation(entries: entries)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: destination) } }
        // ZIPFoundation .create refuses an existing file. Seed the standard empty
        // ZIP directory under protection, then append without an unprotected create.
        try PrivateBridgeProtectedFile.write(Data([0x50, 0x4b, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)), to: destination)
        BackupPolicy.apply(.excluded, to: destination)
        progress?.totalUnitCount = entries.reduce(0) { $0 + $1.byteCount }
        let archive = try Archive(url: destination, accessMode: .update, pathEncoding: nil)
        for entry in entries.sorted(by: { $0.filename < $1.filename }) {
            if progress?.isCancelled == true { throw CancellationError() }
            try archive.addEntry(with: safeFilename(entry.filename), type: .file, uncompressedSize: entry.byteCount,
                permissions: 0o600, compressionMethod: .none, bufferSize: 64 * 1024, provider: { offset, count in
                    if progress?.isCancelled == true { throw CancellationError() }
                    guard offset >= 0, count >= 0, count <= 64 * 1024, offset <= entry.byteCount,
                          Int64(count) <= entry.byteCount - offset else { throw Failure.invalidEntry }
                    let bytes = try entry.read(offset, count)
                    guard bytes.count == count else { throw Failure.invalidEntry }
                    progress?.completedUnitCount += Int64(count)
                    return bytes
                })
        }
        complete = true
    }

    public enum Failure: LocalizedError {
        case empty, invalidEntry
        public var errorDescription: String? {
            switch self { case .empty: "There is nothing to export."; case .invalidEntry: "The export contains an invalid or incomplete file." }
        }
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
