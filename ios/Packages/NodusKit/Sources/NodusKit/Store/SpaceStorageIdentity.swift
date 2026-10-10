import CryptoKit
import Foundation

/// Disk identity is independent of the route's space ID. Two servers can publish the same
/// ID, and a linked Mac keeps its identity when its LAN address changes.
public struct SpaceStorageIdentity: Sendable, Hashable, Codable {
    public let connectionID: String
    public var key: String { "c2-" + SHA256.hash(data: Data(connectionID.utf8)).map { String(format: "%02x", $0) }.joined() }

    public init(connectionID: String) { self.connectionID = connectionID }

    public enum Preparation: Sendable, Equatable { case ready, migrated, unclaimedLegacy }
    public enum IdentityError: Error { case ownerMismatch, conflictingFolders, unsafeFolder }

    /// Only a matching ownership receipt permits automatic migration. Unlabelled legacy
    /// files remain intact and are never opened as another server's private corpus or queue.
    @discardableResult
    public func prepare(in directory: URL, legacySpaceID: String? = nil) throws -> Preparation {
        let manager = FileManager.default, target = directory.appendingPathComponent(key, isDirectory: true)
        let marker = "connection-owner.json"
        let legacy = legacySpaceID.flatMap { id -> URL? in
            guard !id.isEmpty, ![".", ".."].contains(id), !id.contains("/"), !id.contains("\\"), !id.hasPrefix("c2-") else { return nil }
            return directory.appendingPathComponent(id, isDirectory: true)
        }
        for folder in [target, legacy].compactMap({ $0 }) where manager.fileExists(atPath: folder.path) {
            guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw IdentityError.unsafeFolder }
        }
        func owner(_ folder: URL) throws -> SpaceStorageIdentity? {
            let file = folder.appendingPathComponent(marker)
            guard manager.fileExists(atPath: file.path) else { return nil }
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        }
        if let current = try owner(target), current != self { throw IdentityError.ownerMismatch }
        var result = Preparation.ready
        if let legacy, manager.fileExists(atPath: legacy.path) {
            if try owner(legacy) == self {
                guard !manager.fileExists(atPath: target.path) else { throw IdentityError.conflictingFolders }
                try manager.moveItem(at: legacy, to: target)
                result = .migrated
            } else { result = .unclaimedLegacy }
        }
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: target.appendingPathComponent(marker), options: .atomic)
        return result
    }
}
