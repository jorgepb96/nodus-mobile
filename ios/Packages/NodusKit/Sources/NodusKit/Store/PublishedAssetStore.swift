import CryptoKit
import Foundation

/// The bytes of explicitly published images, retained with the offline corpus.
/// Namespaces include the server and space so equal publication ids on two
/// servers never share a download. Every read checks the content address again.
public actor PublishedAssetStore {
    public static let directory = URL.applicationSupportDirectory.appendingPathComponent("nodus-published-assets-v1", isDirectory: true)
    private let root: URL

    public init(directory: URL = PublishedAssetStore.directory) { root = directory }

    public func read(hash: String, origin: String, spaceId: String) throws -> Data? {
        let file = try location(hash: hash, origin: origin, spaceId: spaceId)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        guard Self.sha(data) == hash else {
            try? FileManager.default.removeItem(at: file)
            throw Self.integrityError
        }
        return data
    }

    public func write(_ data: Data, hash: String, origin: String, spaceId: String) throws {
        let file = try location(hash: hash, origin: origin, spaceId: spaceId)
        guard Self.sha(data) == hash else { throw Self.integrityError }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PrivateBridgeProtectedFile.write(data, to: file, protection: .completeFileProtectionUnlessOpen)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public func remove(origin: String, spaceId: String) throws {
        let directory = namespace(origin: origin, spaceId: spaceId)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func namespace(origin: String, spaceId: String) -> URL {
        root.appendingPathComponent(Self.sha(Data("\(origin)\u{0}\(spaceId)".utf8)), isDirectory: true)
    }

    private func location(hash: String, origin: String, spaceId: String) throws -> URL {
        guard hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw APIError(status: 400, code: "invalid_asset_hash", message: "The publication contains an invalid image address.", details: [:])
        }
        return namespace(origin: origin, spaceId: spaceId).appendingPathComponent(hash)
    }

    private static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static var integrityError: APIError {
        APIError(status: 422, code: "asset_hash_mismatch", message: "The image does not match its published content address. Download the copy again.", details: [:])
    }
}
