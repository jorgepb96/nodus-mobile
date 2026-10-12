import Foundation

/// Quick Look/PDF/audio need a protected plaintext URL while they are open.
/// ARC keeps it alive through shared readers and removes it after the last owner
/// closes. These previews have their own bounded transient budget, never a backup.
public final class PrivateBridgeFileLease: @unchecked Sendable {
    public let url: URL
    private let directory: URL
    private static let diskLock = NSLock()
    public static let defaultDirectory: URL = {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Nodus-private-files", isDirectory: true)
        // A fresh process has no viewers holding yesterday's temporary files.
        // Only remove UUID directories created by this preview implementation.
        for old in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            if UUID(uuidString: old.lastPathComponent) != nil { try? FileManager.default.removeItem(at: old) }
        }
        return root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }()
    private init(url: URL, directory: URL) { self.url = url; self.directory = directory }
    deinit { Self.diskLock.withLock { try? FileManager.default.removeItem(at: directory) } }

    public static func write(_ data: Data, filename: String, directory: URL = defaultDirectory,
        limitBytes: Int = PrivateBridgeCache.defaultReadLimitBytes) throws -> PrivateBridgeFileLease {
        guard !filename.isEmpty, ![".", ".."].contains(filename), !filename.contains("/"), !filename.contains("\\"),
              limitBytes >= 0 else { throw DesktopBridgeError.malformedResponse }
        return try diskLock.withLock {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            BackupPolicy.apply(.excluded, to: directory)
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
            var used = 0
            while let file = files?.nextObject() as? URL {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true { used += values.fileSize ?? 0 }
            }
            guard data.count <= max(0, limitBytes - used) else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            BackupPolicy.apply(.excluded, to: folder)
            let url = folder.appendingPathComponent(filename)
            do { try PrivateBridgeProtectedFile.write(data, to: url) }
            catch { try? FileManager.default.removeItem(at: folder); throw error }
            BackupPolicy.apply(.excluded, to: url)
            return PrivateBridgeFileLease(url: url, directory: folder)
        }
    }
}
