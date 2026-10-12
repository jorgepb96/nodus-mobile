import Foundation
import Testing
@testable import NodusKit

@Suite("Long-lived Bridge renewal", .serialized)
struct DesktopBridgeRenewalTests {
    @Test("renewed authorization replaces expiry and token, while weaker grants and unlink stop requests")
    func renewal() async throws {
        let id = UUID().uuidString
        let defaults = UserDefaults(suiteName: "bridge-renewal-\(id)")!
        defer { defaults.removePersistentDomain(forName: "bridge-renewal-\(id)") }
        let keychain = KeychainStore(service: "bridge-renewal-\(id)")
        let store = DesktopBridgePairingStore(defaults: defaults, keychain: keychain)
        let created = Date()
        func grant(expiry: Date, domains: Set<DesktopBridgeDomain> = [.corpus, .writing], fingerprint: String = String(repeating: "a", count: 64), origin: String = "https://mac.nodus.test:7443", vaults: Set<String> = ["vault"], device: String = "mac") throws -> DesktopBridgePairing {
            try DesktopBridgePairing(id: id, origin: origin, certificateFingerprint: fingerprint, deviceId: device, deviceName: "Mac", vaultIds: vaults, domains: domains, pairedAt: created, expiresAt: expiry)
        }
        let initial = try grant(expiry: Date().addingTimeInterval(0.5))
        try store.save(initial, token: "old")
        defer { try? store.revokeLocally(initial) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RenewalProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = DesktopBridgeClient(pairing: initial, token: "old", store: store, session: session)
        RenewalProtocol.state.reset()
        let cacheRoot = URL.temporaryDirectory.appendingPathComponent("renewal-client-\(id)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let nodus = NodusClient(address: try ServerAddress(validating: initial.origin), cache: ResponseCache(directory: cacheRoot), desktopBridge: client, vaultId: "vault")
        _ = try await nodus.snapshot(in: "vault")
        let expiry = Date().addingTimeInterval(60)
        try store.save(grant(expiry: expiry), token: "renewed")
        try await Task.sleep(for: .milliseconds(600))
        #expect(initial.isExpired)
        _ = try await nodus.snapshot(in: "vault")
        #expect(RenewalProtocol.state.tokens() == ["Bearer old", "Bearer renewed"])
        try store.save(grant(expiry: expiry, domains: [.corpus]), token: "weaker")
        await #expect(throws: DesktopBridgeError.permissionDenied) { try await client.sendMutations(vaultId: "vault", body: Data("{}".utf8)) }
        _ = try await client.corpus(vaultId: "vault")
        #expect(RenewalProtocol.state.tokens().last == "Bearer weaker")
        try store.save(grant(expiry: expiry, domains: [.writing]), token: "no-corpus")
        await #expect(throws: DesktopBridgeError.permissionDenied) { try await nodus.snapshot(in: "vault") }
        try keychain.remove(KeychainStore.desktopBridgeKey(pairingId: id))
        await #expect(throws: DesktopBridgeError.locked) { try await client.controlPlane("health") }
        try store.save(grant(expiry: expiry, origin: "https://moved.nodus.test:7443"), token: "moved")
        _ = try await client.corpus(vaultId: "vault")
        #expect(RenewalProtocol.state.tokens().last == "Bearer moved")
        #expect(RenewalProtocol.state.hosts().last == "moved.nodus.test")
        let lostCorpus = try grant(expiry: expiry, domains: [.writing], origin: "https://moved.nodus.test:7443")
        RenewalProtocol.state.failAfter { try? store.save(lostCorpus, token: "lost-during-request") }
        await #expect(throws: DesktopBridgeError.permissionDenied) { try await nodus.snapshot(in: "vault") }
        try store.save(grant(expiry: expiry, vaults: []), token: "no-vault")
        await #expect(throws: DesktopBridgeError.permissionDenied) { try await client.corpus(vaultId: "vault") }
        for changed in [try grant(expiry: expiry, fingerprint: String(repeating: "b", count: 64)), try grant(expiry: expiry, device: "other")] {
            try store.save(changed, token: "untrusted")
            await #expect(throws: DesktopBridgeError.permissionDenied) { try await client.controlPlane("health") }
        }
        try store.save(grant(expiry: Date().addingTimeInterval(-1)), token: "expired")
        await #expect(throws: DesktopBridgeError.expired) { try await client.corpus(vaultId: "vault") }
        try store.revokeLocally(initial)
        await #expect(throws: DesktopBridgeError.permissionDenied) { try await client.controlPlane("health") }
        #expect(RenewalProtocol.state.tokens().count == 5)
    }

    @Test("constructor-only clients retain ephemeral transport compatibility")
    func ephemeral() async throws {
        let id = UUID().uuidString
        let defaults = UserDefaults(suiteName: id)!
        defer { defaults.removePersistentDomain(forName: id) }
        let store = DesktopBridgePairingStore(defaults: defaults, keychain: KeychainStore(service: id))
        let pairing = try DesktopBridgePairing(id: id, origin: "https://mac.nodus.test:7443", certificateFingerprint: String(repeating: "a", count: 64), deviceId: "mac", deviceName: "Mac", vaultIds: ["vault"], domains: [.corpus], pairedAt: Date(), expiresAt: nil)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RenewalProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        RenewalProtocol.state.reset()
        let client = DesktopBridgeClient(pairing: pairing, token: "ephemeral", store: store, session: session)
        _ = try await client.corpus(vaultId: "vault")
        #expect(RenewalProtocol.state.tokens() == ["Bearer ephemeral"])
        try store.save(pairing, token: "adopted")
        _ = try await client.corpus(vaultId: "vault")
        try store.revokeLocally(pairing)
        await #expect(throws: DesktopBridgeError.permissionDenied) { try await client.corpus(vaultId: "vault") }
        #expect(RenewalProtocol.state.tokens() == ["Bearer ephemeral", "Bearer adopted"])
    }
}
private final class RenewalProtocol: URLProtocol, @unchecked Sendable {
    static let state = RenewalState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.record(request)
        if Self.state.failRequest() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        let data = request.url?.path.hasSuffix("/snapshot") == true
            ? try! JSONEncoder.nodus.encode(JSONValue.object(["format": .string(SnapshotFormat.identifier), "formatVersion": .int(Int64(SnapshotFormat.supportedVersions.min()!))]))
            : Data("{}".utf8)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class RenewalState: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String] = []; private var addresses: [String] = []; private var failure: (@Sendable () -> Void)?
    func reset() { lock.withLock { values = []; addresses = []; failure = nil } }
    func record(_ request: URLRequest) { lock.withLock { values.append(request.value(forHTTPHeaderField: "Authorization") ?? ""); addresses.append(request.url?.host ?? "") } }
    func failAfter(_ callback: @escaping @Sendable () -> Void) { lock.withLock { failure = callback } }
    func failRequest() -> Bool {
        let callback = lock.withLock { let pending = failure; failure = nil; return pending }
        callback?(); return callback != nil
    }
    func hosts() -> [String] { lock.withLock { addresses } }
    func tokens() -> [String] { lock.withLock { values } }
}
