import Foundation
import Testing
@testable import NodusKit

@Suite("Native companion offline consultation", .serialized)
struct DesktopCorpusOfflineTests {
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
