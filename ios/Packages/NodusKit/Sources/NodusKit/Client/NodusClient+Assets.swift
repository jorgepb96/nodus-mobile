import CryptoKit
import Foundation

/// The image channel, and the only binary that ever moves over this API.
///
/// Documents never reach the server: no PDFs, no audio, no recordings. Only explicitly
/// whitelisted image domains do — report illustrations, portraits, world galleries, maps and
/// image-valued database attachments. The server sniffs every upload and refuses anything that
/// is not PNG, JPEG, WEBP or GIF, including a WAV, which shares its first four bytes with WEBP.
public extension NodusClient {
    /// `GET /api/v1/spaces/:id/assets/:sha256` — needs `read`.
    ///
    /// The response is `cache-control: private, max-age=31536000, immutable`, which is honest:
    /// the URL *is* the hash of the content, so it can never change. Cached by hash, forever,
    /// with no revalidation.
    ///
    /// Note the request needs an `Authorization` header, so these URLs cannot be handed to a
    /// plain `AsyncImage`.
    func asset(hash: String, in spaceId: String) async throws -> Data {
        // Private companion images stay inside the bounded encrypted Bridge cache.
        // The public asset store has a different lifetime and cannot own a temporary
        // private download after its pack expires or the Mac is unlinked.
        if !hasDesktopBridge, let downloaded = try await publishedAssets.read(hash: hash, origin: address.origin, spaceId: spaceId) { return downloaded }
        let response = try await perform(.init(
            path: address.spacePath(spaceId, "/assets/\(escape(hash))"),
            extraHeaders: ["Accept": "image/*"]
        ))
        guard SHA256.hash(data: response.data).map({ String(format: "%02x", $0) }).joined() == hash.lowercased() else {
            throw APIError(status: 422, code: "asset_hash_mismatch", message: "La imagen descargada no coincide con su contenido original.", details: [:])
        }
        if !hasDesktopBridge { try await publishedAssets.write(response.data, hash: hash, origin: address.origin, spaceId: spaceId) }
        return response.data
    }

    /// A completed offline download includes the original image and its thumbnail.
    /// Cancellation or an unavailable image keeps the partial download resumable;
    /// neither is reported as a complete copy.
    func downloadPublishedAssets(_ snapshot: SnapshotDownload, in spaceId: String,
        progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws {
        var expected: [String: Int?] = [:]
        func include(_ hash: String, bytes: Int?) throws {
            if let recorded = expected[hash], let count = recorded, let bytes, count != bytes {
                throw APIError(status: 422, code: "asset_size_mismatch", message: "The publication gives conflicting sizes for an image.", details: [:])
            }
            if expected[hash] == nil || bytes != nil { expected[hash] = .some(bytes) }
        }
        for ref in snapshot.assetRefs {
            try include(ref.hash, bytes: ref.bytes)
            if let hash = ref.thumbHash { try include(hash, bytes: ref.thumbBytes) }
        }
        let hashes = expected.keys.sorted()
        await progress(0, hashes.count)
        for (index, hash) in hashes.enumerated() {
            try Task.checkCancellation()
            let data = try await asset(hash: hash, in: spaceId)
            if let count = expected[hash] ?? nil, count > 0, data.count != count {
                throw APIError(status: 422, code: "asset_size_mismatch", message: "The image size does not match the publication.", details: [:])
            }
            await progress(index + 1, hashes.count)
        }
    }

    func removeDownloadedAssets(in spaceId: String) async throws {
        try await publishedAssets.remove(origin: address.origin, spaceId: spaceId)
    }

    func hasDownloadedPublishedAssets(_ refs: [SnapshotAssetRef], in spaceId: String) async throws -> Bool {
        for ref in refs {
            for (hash, count) in [(ref.hash, Optional(ref.bytes)), (ref.thumbHash, ref.thumbBytes)] {
                guard let hash else { continue }
                guard let bytes = try await publishedAssets.read(hash: hash, origin: address.origin, spaceId: spaceId) else { return false }
                if let count, count > 0, bytes.count != count { return false }
            }
        }
        return true
    }

    /// `POST /api/v1/spaces/:id/assets/negotiate` — which of these does the server not have?
    ///
    /// Republishing an unchanged corpus re-uploads nothing, because the answer is empty.
    func negotiateAssets(_ assets: [(hash: String, bytes: Int)], in spaceId: String) async throws -> [String] {
        let payload: [String: JSONValue] = [
            "assets": .array(assets.map { .object(["hash": .string($0.hash), "bytes": .int(Int64($0.bytes))]) }),
        ]
        let response = try await perform(.init(
            method: "POST",
            path: address.spacePath(spaceId, "/assets/negotiate"),
            body: try JSONEncoder.nodus.encode(payload),
            contentType: "application/json"
        ))
        return (try object(from: response)["missing"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    /// `PUT /api/v1/spaces/:id/assets/:sha256` — needs `write`.
    ///
    /// The hash is computed here rather than taken on trust: the server verifies it and
    /// answers `hash_mismatch`, so getting it wrong locally wastes a whole upload.
    @discardableResult
    func upload(imageData: Data, in spaceId: String, maxBytes: Int) async throws -> AssetUploadResult {
        guard imageData.count <= maxBytes else {
            throw APIError(
                status: 413,
                code: "too_large",
                message: "This image is larger than the server accepts.",
                details: ["limitBytes": .int(Int64(maxBytes)), "uploadBytes": .int(Int64(imageData.count))]
            )
        }
        let hash = Self.sha256Hex(imageData)
        let response = try await perform(.init(
            method: "PUT",
            path: address.spacePath(spaceId, "/assets/\(hash)"),
            body: imageData,
            contentType: "application/octet-stream"
        ))
        let object = try object(from: response)
        return AssetUploadResult(
            hash: hash,
            deduplicated: object["deduplicated"]?.boolValue ?? false,
            mime: object["mime"]?.stringValue,
            bytes: object["bytes"]?.intValue ?? imageData.count
        )
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct AssetUploadResult: Sendable {
    public let hash: String
    /// The server already had these bytes. Not an error — the common case.
    public let deduplicated: Bool
    public let mime: String?
    public let bytes: Int
}
