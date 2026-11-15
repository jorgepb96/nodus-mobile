import CryptoKit
import Foundation
import Testing
import GRDB
@testable import NodusKit

@Suite("Published images offline", .serialized)
struct PublishedAssetTests {
    private let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jM1kAAAAASUVORK5CYII=")!
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @Test("an older mirror upgrades without inventing a thumbnail size or losing its references")
    func legacyMirror() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: folder.appendingPathComponent("mirror.sqlite").path)
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE asset_refs(hash TEXT NOT NULL, thumb_hash TEXT, mime TEXT NOT NULL, thumb_mime TEXT, bytes INTEGER NOT NULL, kind TEXT NOT NULL, tbl TEXT NOT NULL, row_key TEXT NOT NULL, PRIMARY KEY(tbl,row_key,hash))")
            try db.execute(sql: "INSERT INTO asset_refs VALUES (?, ?, 'image/png', 'image/png', ?, 'person_portrait', 'person_portraits', 'person')", arguments: [hash(image), hash(image), image.count])
        }
        try queue.close()
        let mirror = try await MirrorStore.open(spaceId: "legacy", directory: root)
        let refs = try await mirror.assetRefs()
        #expect(refs.count == 1)
        #expect(refs.first?.hash == hash(image))
        #expect(refs.first?.thumbBytes == nil)
        #expect(try await mirror.portrait(personId: "person") == refs.first)
    }

    @Test("an authenticated download survives a new client and an unavailable server")
    func offlineRelaunch() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PublishedAssetProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        PublishedAssetProtocol.state.reset(data: image)
        let address = ServerAddress(trusted: "https://isolated.nodus.test")
        let first = NodusClient(address: address, token: "isolated-test-token", session: session,
            cache: ResponseCache(directory: root.appendingPathComponent("http")), publishedAssets: PublishedAssetStore(directory: root.appendingPathComponent("images")))
        let sha = hash(image)
        #expect(try await first.asset(hash: sha, in: "shared-name") == image)
        #expect(PublishedAssetProtocol.state.requests().first?.value(forHTTPHeaderField: "Authorization") == "Bearer isolated-test-token")
        PublishedAssetProtocol.state.disconnect()
        let second = NodusClient(address: address, session: session,
            cache: ResponseCache(directory: root.appendingPathComponent("new-http")), publishedAssets: PublishedAssetStore(directory: root.appendingPathComponent("images")))
        #expect(try await second.asset(hash: sha, in: "shared-name") == image)
        #expect(PublishedAssetProtocol.state.requests().count == 1)
        try await second.removeDownloadedAssets(in: "shared-name")
        await #expect(throws: TransportError.self) { try await second.asset(hash: sha, in: "shared-name") }
    }

    @Test("download completeness includes originals and thumbnails and rejects incorrect metadata")
    func completeDownload() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PublishedAssetProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        PublishedAssetProtocol.state.reset(data: image)
        let client = NodusClient(address: ServerAddress(trusted: "https://isolated.nodus.test"), session: session,
            cache: ResponseCache(directory: root.appendingPathComponent("http")), publishedAssets: PublishedAssetStore(directory: root.appendingPathComponent("images")))
        let ref: JSONValue = .object(["hash": .string(hash(image)), "thumbHash": .string(hash(image)), "bytes": .int(Int64(image.count)), "thumbBytes": .int(Int64(image.count)),
            "mime": .string("image/png"), "thumbMime": .string("image/png"), "kind": .string("deep_research"), "table": .string("decorative_images"), "key": .array([.string("deep_research"), .string("report")])])
        let snapshot = try SnapshotDownload.read(JSONEncoder.nodus.encode(JSONValue.object([
            "format": .string(SnapshotFormat.identifier), "formatVersion": .int(2), "tables": .object([:]), "assets": .array([ref])
        ])))
        #expect(try await !client.hasDownloadedPublishedAssets(snapshot.assetRefs, in: "space"))
        try await client.downloadPublishedAssets(snapshot, in: "space")
        #expect(try await client.hasDownloadedPublishedAssets(snapshot.assetRefs, in: "space"))
        let mirror = try await MirrorStore.open(spaceId: "space", directory: root.appendingPathComponent("mirror"))
        try await mirror.replace(with: snapshot, revision: "image-revision")
        #expect(try await mirror.assetRefs() == snapshot.assetRefs)
        #expect(PublishedAssetProtocol.state.requests().count == 1)
        var wrong = try #require(ref.objectValue)
        wrong["thumbBytes"] = .int(999)
        let incomplete = try SnapshotDownload.read(JSONEncoder.nodus.encode(JSONValue.object([
            "format": .string(SnapshotFormat.identifier), "formatVersion": .int(2), "tables": .object([:]), "assets": .array([.object(wrong)])
        ])))
        await #expect(throws: APIError.self) { try await client.downloadPublishedAssets(incomplete, in: "space") }
        try await client.removeDownloadedAssets(in: "space")
        #expect(try await !client.hasDownloadedPublishedAssets(mirror.assetRefs(), in: "space"))
    }

    @Test("equal space ids stay isolated, invalid addresses never reach the server, and corruption is detected")
    func isolationAndIntegrity() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PublishedAssetStore(directory: root), sha = hash(image)
        try await store.write(image, hash: sha, origin: "https://first.test", spaceId: "default")
        #expect(try await store.read(hash: sha, origin: "https://second.test", spaceId: "default") == nil)
        #expect(try await store.read(hash: sha, origin: "https://first.test", spaceId: "other") == nil)
        await #expect(throws: APIError.self) { try await store.write(Data("different".utf8), hash: sha, origin: "https://first.test", spaceId: "default") }
        await #expect(throws: APIError.self) { try await store.read(hash: "../../private", origin: "https://first.test", spaceId: "default") }
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        let file = try #require(enumerator.allObjects.compactMap { $0 as? URL }.first { $0.lastPathComponent == sha })
        try Data("corrupted".utf8).write(to: file)
        await #expect(throws: APIError.self) { try await store.read(hash: sha, origin: "https://first.test", spaceId: "default") }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

private final class PublishedAssetProtocol: URLProtocol, @unchecked Sendable {
    static let state = PublishedAssetState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.state.record(request)
        guard let data else { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["content-type":"image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class PublishedAssetState: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var calls: [URLRequest] = []
    func reset(data: Data) { lock.withLock { self.data = data; calls = [] } }
    func disconnect() { lock.withLock { data = nil } }
    func record(_ request: URLRequest) -> Data? { lock.withLock { calls.append(request); return data } }
    func requests() -> [URLRequest] { lock.withLock { calls } }
}
