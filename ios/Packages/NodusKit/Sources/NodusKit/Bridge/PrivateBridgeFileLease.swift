import Foundation

/// Quick Look/PDF/audio need a protected plaintext URL while they are open.
/// ARC keeps it alive through shared readers and removes it after the last owner
/// closes. These previews have their own bounded transient budget, never a backup.
public final class PrivateBridgeFileLease: @unchecked Sendable {
    public let url: URL
    private let directory: URL
    private static let diskLock = NSLock()
    nonisolated(unsafe) private static var reservations: [URL: Int64] = [:]
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

    private static func reserve(filename: String, reservedBytes: Int64, directory: URL, limitBytes: Int) throws -> (URL, URL) {
        guard !filename.isEmpty, ![".", ".."].contains(filename), !filename.contains("/"), !filename.contains("\\"),
              reservedBytes >= 0, limitBytes >= 0 else { throw DesktopBridgeError.malformedResponse }
        return try diskLock.withLock {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            BackupPolicy.apply(.excluded, to: directory)
            var used: Int64 = 0, reservedActual: [URL: Int64] = [:]
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
            while let file = files?.nextObject() as? URL {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true {
                    let size = Int64(values.fileSize ?? 0); used += size
                    let folder = file.deletingLastPathComponent()
                    if reservations[folder] != nil { reservedActual[folder, default: 0] += size }
                }
            }
            for (folder, size) in reservations where folder.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path {
                used += max(0, size - (reservedActual[folder] ?? 0))
            }
            guard used <= Int64(limitBytes), reservedBytes <= Int64(limitBytes) - used else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            if let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity {
                var unwritten: Int64 = 0
                for (folder, reserved) in reservations {
                    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
                    let actual = try files.reduce(Int64(0)) { total, file in total + Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
                    unwritten += max(0, reserved - actual)
                }
                guard unwritten <= Int64(available), reservedBytes <= Int64(available) - unwritten else { throw CocoaError(.fileWriteOutOfSpace) }
            }
            let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            BackupPolicy.apply(.excluded, to: folder)
            let url = folder.appendingPathComponent(filename)
            do { try PrivateBridgeProtectedFile.write(Data(), to: url) }
            catch { try? FileManager.default.removeItem(at: folder); throw error }
            BackupPolicy.apply(.excluded, to: url)
            reservations[folder] = reservedBytes
            return (url, folder)
        }
    }
    private static func finish(url: URL, folder: URL, reservedBytes: Int64) throws -> PrivateBridgeFileLease {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? 0) <= reservedBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
#if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
#else
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
#endif
        BackupPolicy.apply(.excluded, to: url)
        return PrivateBridgeFileLease(url: url, directory: folder)
    }
    public static func create(filename: String, reservedBytes: Int64, directory: URL = defaultDirectory,
        limitBytes: Int = PrivateBridgeCache.defaultReadLimitBytes, writeTo: (URL) throws -> Void) throws -> PrivateBridgeFileLease {
        let (url, folder) = try reserve(filename: filename, reservedBytes: reservedBytes, directory: directory, limitBytes: limitBytes)
        var complete = false
        defer {
            diskLock.withLock { reservations[folder] = nil }
            if !complete { try? FileManager.default.removeItem(at: folder) }
        }
        try writeTo(url)
        let lease = try finish(url: url, folder: folder, reservedBytes: reservedBytes); complete = true; return lease
    }
    public static func create(filename: String, reservedBytes: Int64, directory: URL = defaultDirectory,
        limitBytes: Int = PrivateBridgeCache.defaultReadLimitBytes, writeTo: @Sendable (URL) async throws -> Void) async throws -> PrivateBridgeFileLease {
        let (url, folder) = try reserve(filename: filename, reservedBytes: reservedBytes, directory: directory, limitBytes: limitBytes)
        var complete = false
        defer {
            diskLock.withLock { reservations[folder] = nil }
            if !complete { try? FileManager.default.removeItem(at: folder) }
        }
        try Task.checkCancellation()
        try await writeTo(url)
        try Task.checkCancellation()
        let lease = try finish(url: url, folder: folder, reservedBytes: reservedBytes); complete = true; return lease
    }
    public static func write(_ data: Data, filename: String, directory: URL = defaultDirectory,
        limitBytes: Int = PrivateBridgeCache.defaultReadLimitBytes) throws -> PrivateBridgeFileLease {
        try create(filename: filename, reservedBytes: Int64(data.count), directory: directory, limitBytes: limitBytes) { url in
            try PrivateBridgeProtectedFile.write(data, to: url)
        }
    }
}
