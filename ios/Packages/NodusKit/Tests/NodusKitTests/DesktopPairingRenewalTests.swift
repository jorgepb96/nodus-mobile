import Foundation
import Testing
@testable import NodusKit

@Suite("Persistent linked Mac renewal", .serialized)
struct DesktopPairingRenewalTests {
    private func fixture() throws -> (DesktopBridgePairing, DesktopBridgePairingStore, UserDefaults, KeychainStore, URLSession) {
        let id = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: "nodus.tests.renewal.\(id)"))
        let keychain = KeychainStore(service: "nodus.tests.renewal.\(id)")
        let pairing = try DesktopBridgePairing(id: id, origin: "https://mac.nodus.test:7443", certificateFingerprint: String(repeating: "a", count: 64),
            deviceId: "phone", deviceName: "phone", vaultIds: ["vault"], domains: [.corpus, .writing, .researchGeneration], pairedAt: Date(timeIntervalSince1970: 1_700_000_000), expiresAt: nil)
        let store = DesktopBridgePairingStore(defaults: defaults, keychain: keychain)
        try store.save(pairing, token: RenewalProtocol.state.original)
        RenewalProtocol.state.setGrant(id)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RenewalProtocol.self]
        return (pairing, store, defaults, keychain, URLSession(configuration: configuration))
    }

    @Test("a lost renewal response recovers before one authenticated write; cache identity is retained")
    func lostResponse() async throws {
        RenewalProtocol.state.reset(failure: .afterCommit)
        let (pairing, store, defaults, keychain, session) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("renewal-cache-\(pairing.id)")
        defer { session.invalidateAndCancel(); try? store.revokeLocally(pairing); defaults.removePersistentDomain(forName: "nodus.tests.renewal.\(pairing.id)"); try? FileManager.default.removeItem(at: directory) }
        let cache = try PrivateBridgeCache(pairingId: pairing.id, directory: directory, keychain: keychain)
        let draft = Data("Unsent private draft with citations".utf8)
        try await cache.store(draft, vaultId: "vault", domain: .writing, recordId: "unsent-draft")
        let before = store.pairings()
        let client = DesktopBridgeClient(pairing: pairing, token: RenewalProtocol.state.original, store: store, session: session)
        do { _ = try await client.renew(); Issue.record("An ambiguous POST must surface the lost response.") }
        catch { #expect((error as? URLError)?.code == .networkConnectionLost) }
        let candidate = try #require(store.pendingRenewal(for: pairing))
        #expect(store.credential(for: pairing) == RenewalProtocol.state.original)
        let result = try await client.operation(vaultId: "vault", method: "saveManualIdea", args: [.string("exact write")])
        #expect(result == .string("saved-once"))
        #expect(store.credential(for: pairing) == candidate); #expect(store.pendingRenewal(for: pairing) == nil)
        #expect(store.pairings() == before)
        #expect(try await cache.data(vaultId: "vault", domain: .writing, recordId: "unsent-draft") == draft)
        #expect(RenewalProtocol.state.executedWrites == 1)
        #expect(RenewalProtocol.state.acceptedRenewals == 1)
        #expect(RenewalProtocol.state.healthProbes == 1)
        #expect(RenewalProtocol.state.rejectedWrites == 1)
    }

    @Test("a replacement remains pending when nothing reached the Mac, then explicit retry commits it")
    func beforeSend() async throws {
        RenewalProtocol.state.reset(failure: .beforeCommit)
        let (pairing, store, defaults, _, session) = try fixture()
        defer { session.invalidateAndCancel(); try? store.revokeLocally(pairing); defaults.removePersistentDomain(forName: "nodus.tests.renewal.\(pairing.id)") }
        let client = DesktopBridgeClient(pairing: pairing, token: RenewalProtocol.state.original, store: store, session: session)
        do { _ = try await client.renew(); Issue.record("Expected an unreachable Mac.") }
        catch { #expect((error as? URLError)?.code == .notConnectedToInternet) }
        let candidate = try #require(store.pendingRenewal(for: pairing))
        _ = try await client.operation(vaultId: "vault", method: "saveManualIdea", args: [])
        #expect(store.pendingRenewal(for: pairing) == candidate, "A successful old-token read must not discard an in-flight replacement.")
        #expect(RenewalProtocol.state.acceptedRenewals == 0)
        #expect(try await client.renew() == candidate)
        #expect(store.pendingRenewal(for: pairing) == nil)
        #expect(RenewalProtocol.state.acceptedRenewals == 1)
    }

    @Test("existing clients refresh their token and local revocation prevents further requests")
    func existingClient() async throws {
        RenewalProtocol.state.reset(failure: .none)
        let (pairing, store, defaults, _, session) = try fixture()
        defer { session.invalidateAndCancel(); try? store.revokeLocally(pairing); defaults.removePersistentDomain(forName: "nodus.tests.renewal.\(pairing.id)") }
        let first = DesktopBridgeClient(pairing: pairing, token: RenewalProtocol.state.original, store: store, session: session)
        let existing = DesktopBridgeClient(pairing: pairing, token: RenewalProtocol.state.original, store: store, session: session)
        _ = try await first.renew()
        #expect(try await existing.operation(vaultId: "vault", method: "saveManualIdea", args: []) == .string("saved-once"))
        #expect(RenewalProtocol.state.rejectedWrites == 0)
        _ = try store.prepareRenewal(for: pairing)
        try store.revokeLocally(pairing)
        #expect(store.pendingRenewal(for: pairing) == nil); #expect(store.credential(for: pairing) == nil)
        let count = RenewalProtocol.state.requests
        await #expect(throws: DesktopBridgeError.permissionDenied) { try await existing.controlPlane("health") }
        #expect(RenewalProtocol.state.requests == count)
    }

    @Test("replacement preparation is idempotent and a late response cannot overwrite a newer credential")
    func preparation() throws {
        RenewalProtocol.state.reset(failure: .none)
        let (pairing, store, defaults, _, session) = try fixture()
        defer { session.invalidateAndCancel(); try? store.revokeLocally(pairing); defaults.removePersistentDomain(forName: "nodus.tests.renewal.\(pairing.id)") }
        let first = try store.prepareRenewal(for: pairing)
        #expect(first.count == 43); #expect(try store.prepareRenewal(for: pairing) == first)
        try store.commitRenewal(for: pairing, token: first)
        let second = try store.prepareRenewal(for: pairing); #expect(second != first)
        try store.commitRenewal(for: pairing, token: second)
        #expect(throws: DesktopBridgeError.permissionDenied) { try store.commitRenewal(for: pairing, token: first) }
        #expect(store.credential(for: pairing) == second)
        #expect(store.pairings() == [pairing])
    }
}

private final class RenewalProtocol: URLProtocol, @unchecked Sendable {
    static let state = RenewalState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var delivered = request
        if delivered.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            delivered.httpBody = data
        }
        let result = Self.state.respond(delivered)
        if let error = result.error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class RenewalState: @unchecked Sendable {
    enum Failure { case none, beforeCommit, afterCommit }
    let original = String(repeating: "o", count: 43)
    private let lock = NSLock()
    private var current = ""
    private var grant = ""
    private var failure = Failure.none
    private var counts = (requests: 0, writes: 0, renewals: 0, probes: 0, rejected: 0)
    var requests: Int { lock.withLock { counts.requests } }
    var executedWrites: Int { lock.withLock { counts.writes } }
    var acceptedRenewals: Int { lock.withLock { counts.renewals } }
    var healthProbes: Int { lock.withLock { counts.probes } }
    var rejectedWrites: Int { lock.withLock { counts.rejected } }
    func reset(failure: Failure) { lock.withLock { current = original; self.failure = failure; counts = (0, 0, 0, 0, 0) } }
    func setGrant(_ id: String) { lock.withLock { grant = id } }
    func respond(_ request: URLRequest) -> (status: Int, data: Data, error: URLError.Code?) {
        lock.withLock {
            counts.requests += 1
            let path = request.url?.path ?? ""
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(current)" else {
                if path.hasSuffix("/operations") { counts.rejected += 1 }
                return (401, Data(#"{"error":"invalid_token"}"#.utf8), nil)
            }
            if path == "/bridge/v2/pairing/renew" {
                let mode = failure; failure = .none
                if mode == .beforeCommit { return (0, Data(), .notConnectedToInternet) }
                guard let data = request.httpBody,
                      let body = try? JSONSerialization.jsonObject(with: data) as? [String: String], let next = body["nextToken"] else {
                    return (400, Data(#"{"error":"bad_request"}"#.utf8), nil)
                }
                current = next; counts.renewals += 1
                if mode == .afterCommit { return (0, Data(), .networkConnectionLost) }
                return (200, Data("{\"id\":\"\(grant)\"}".utf8), nil)
            }
            if path == "/bridge/v2/health" { counts.probes += 1; return (200, Data(#"{"ok":true}"#.utf8), nil) }
            counts.writes += 1; return (200, Data(#"{"result":"saved-once"}"#.utf8), nil)
        }
    }
}
