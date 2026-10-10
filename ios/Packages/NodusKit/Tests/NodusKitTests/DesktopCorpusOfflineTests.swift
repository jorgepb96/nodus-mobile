import Foundation
import Testing
@testable import NodusKit

@Suite("Native companion offline consultation", .serialized)
struct DesktopCorpusOfflineTests {
    @Test("selected dossiers survive cache clearing and answer new filters only on transport loss")
    func selectedIdeas() async throws {
        let id = UUID().uuidString, root = URL.temporaryDirectory.appendingPathComponent("selected-ideas-\(UUID().uuidString)")
        let keychain = KeychainStore(service: "nodus.tests.selected-ideas.\(id)")
        let defaults = try #require(UserDefaults(suiteName: id)), store = DesktopBridgePairingStore(defaults: defaults, keychain: keychain)
        let pairing = try DesktopBridgePairing(id: id, origin: "https://mac.nodus.test:7443", certificateFingerprint: String(repeating: "a", count: 64), deviceId: "phone", deviceName: "phone", vaultIds: ["a"], domains: [.corpus], pairedAt: Date(), expiresAt: nil)
        let cache = try PrivateBridgeCache(pairingId: id, directory: root, keychain: keychain)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OfflineCorpusProtocol.self]
        let session = URLSession(configuration: config), client = DesktopBridgeClient(pairing: pairing, token: "test-only", store: store, session: session)
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root); try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)); defaults.removePersistentDomain(forName: id) }
        let pack = try await cache.saveReadPack(vaultId: "a", title: "Selected ideas", expiresAt: Date().addingTimeInterval(3600), records: [.init(domain: .corpus, recordId: CompanionIdeaCopy.recordId, data: JSONEncoder.nodus.encode(CompanionIdeaCopyTests.copy(ids: ["one", "two"])))])
        let documents = try CompanionDocumentOutbox(cache: cache, vaultId: "a", data: nil)
        let creation = try await documents.createManualIdea(input: .object(["title": .string("New phone idea"), "folderId": .null]))
        let authoredId = try #require(creation.objectValue?["globalId"]?.stringValue)
        try await cache.removeReusableCopies()
        OfflineCorpusProtocol.state.set(error: .notConnectedToInternet, status: 200)
        let query = [URLQueryItem(name: "surface", value: "workspace"), URLQueryItem(name: "q", value: "two")]
        let response = try await client.corpusWithOfflineCopy(vaultId: "a", path: "ideas", query: query, cache: cache)
        #expect(response.fromCache)
        #expect(try JSONDecoder.nodus.decode(IdeaWorkspacePage.self, from: response.response.data).items.map(\.id) == ["two"])
        let dossier = try await client.corpusWithOfflineCopy(vaultId: "a", path: "ideas/two", cache: cache)
        #expect(try JSONDecoder.nodus.decode(IdeaDetail.self, from: dossier.response.data).idea.string("global_id") == "two")
        let newQuery = [URLQueryItem(name: "surface", value: "workspace"), URLQueryItem(name: "q", value: "New phone")]
        let authored = try await client.corpusWithOfflineCopy(vaultId: "a", path: "ideas", query: newQuery, cache: cache)
        #expect(try JSONDecoder.nodus.decode(IdeaWorkspacePage.self, from: authored.response.data).items.map(\.id) == [authoredId])
        await #expect(throws: CompanionIdeaCopy.CopyError.self) { try await client.corpusWithOfflineCopy(vaultId: "a", path: "ideas/missing", cache: cache) }
        await #expect(throws: DesktopBridgeError.self) { try await client.corpusWithOfflineCopy(vaultId: "other", path: "ideas", query: query, cache: cache) }
        for code in [URLError.Code.serverCertificateUntrusted, .cancelled] {
            OfflineCorpusProtocol.state.set(error: code, status: 200)
            await #expect(throws: URLError.self) { try await client.corpusWithOfflineCopy(vaultId: "a", path: "ideas", query: query, cache: cache) }
        }
        OfflineCorpusProtocol.state.set(error: nil, status: 403)
        await #expect(throws: APIError.self) { try await client.corpusWithOfflineCopy(vaultId: "a", path: "ideas", query: query, cache: cache) }
        await #expect(throws: APIError.self) { try await client.corpusWithOfflineCopy(vaultId: "a", path: "ideas/\(authoredId)", cache: cache) }
        OfflineCorpusProtocol.state.set(error: nil, status: 404)
        let unacknowledged = try await client.corpusWithOfflineCopy(vaultId: "a", path: "ideas/\(authoredId)", cache: cache)
        #expect(unacknowledged.fromCache)
        #expect(try JSONDecoder.nodus.decode(IdeaDetail.self, from: unacknowledged.response.data).idea.string("mobileSyncState") == "pending")
        await #expect(throws: APIError.self) { try await client.corpusWithOfflineCopy(vaultId: "a", path: "ideas/two", cache: cache) }
        try await cache.removeReadPack(id: pack.id, vaultId: "a")
        OfflineCorpusProtocol.state.set(error: .notConnectedToInternet, status: 200)
        let kept = try await client.corpusWithOfflineCopy(vaultId: "a", path: "ideas", query: newQuery, cache: cache)
        #expect(try JSONDecoder.nodus.decode(IdeaWorkspacePage.self, from: kept.response.data).items.map(\.id) == [authoredId])
        await #expect(throws: CompanionIdeaCopy.CopyError.self) { try await client.corpusWithOfflineCopy(vaultId: "a", path: "ideas/two", cache: cache) }
    }
    @Test("exact cached pages reopen only after transport loss; permissions, certificate errors and new pages fail explicitly")
    func protectedFallback() async throws {
        let id = UUID().uuidString
        let root = URL.temporaryDirectory.appendingPathComponent("corpus-offline-\(id)")
        let keychain = KeychainStore(service: "nodus.tests.corpus-offline.\(id)")
        let defaults = try #require(UserDefaults(suiteName: id))
        let store = DesktopBridgePairingStore(defaults: defaults, keychain: keychain)
        let pairing = try DesktopBridgePairing(id: id, origin: "https://mac.nodus.test:7443", certificateFingerprint: String(repeating: "a", count: 64), deviceId: "phone", deviceName: "phone", vaultIds: ["a"], domains: [.corpus], pairedAt: Date(), expiresAt: nil)
        let cache = try PrivateBridgeCache(pairingId: id, directory: root, keychain: keychain)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OfflineCorpusProtocol.self]
        let session = URLSession(configuration: config)
        let client = DesktopBridgeClient(pairing: pairing, token: "test-only", store: store, session: session)
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root); try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)); defaults.removePersistentDomain(forName: id) }
        let query = [URLQueryItem(name: "offset", value: "100")]
        OfflineCorpusProtocol.state.set(error: nil, status: 200)
        let online = try await client.corpusWithOfflineCopy(vaultId: "a", path: "deep-research", query: query, cache: cache)
        #expect(!online.fromCache)
        OfflineCorpusProtocol.state.set(error: .notConnectedToInternet, status: 200)
        let reopened = try await client.corpusWithOfflineCopy(vaultId: "a", path: "deep-research", query: query, cache: cache)
        #expect(reopened.fromCache); #expect(reopened.response.data == online.response.data)
        await #expect(throws: URLError.self) { try await client.corpusWithOfflineCopy(vaultId: "a", path: "deep-research", query: [URLQueryItem(name: "offset", value: "200")], cache: cache) }
        await #expect(throws: DesktopBridgeError.self) { try await client.corpusWithOfflineCopy(vaultId: "different-vault", path: "deep-research", query: query, cache: cache) }
        OfflineCorpusProtocol.state.set(error: .serverCertificateUntrusted, status: 200)
        await #expect(throws: URLError.self) { try await client.corpusWithOfflineCopy(vaultId: "a", path: "deep-research", query: query, cache: cache) }
        for status in [401, 403, 500] {
            OfflineCorpusProtocol.state.set(error: nil, status: status)
            await #expect(throws: APIError.self) { try await client.corpusWithOfflineCopy(vaultId: "a", path: "deep-research", query: query, cache: cache) }
        }
    }
}

private final class OfflineCorpusProtocol: URLProtocol, @unchecked Sendable {
    static let state = OfflineCorpusState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (error, status) = Self.state.current()
        if let error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((status == 200 ? #"{"reports":[{"id":"second-page","title":"Saved private report"}]}"# : #"{"error":{"code":"operation_forbidden","message":"Rejected"}}"#).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class OfflineCorpusState: @unchecked Sendable {
    private let lock = NSLock()
    private var error: URLError.Code?
    private var status = 200
    func set(error: URLError.Code?, status: Int) { lock.withLock { self.error = error; self.status = status } }
    func current() -> (URLError.Code?, Int) { lock.withLock { (error, status) } }
}
