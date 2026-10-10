import Foundation
import Testing
@testable import NodusKit

@Suite("Durable code pairing recovery", .serialized)
struct DesktopPairingRecoveryTests {
    private func fixture(renewal: Bool = false) throws -> (DesktopPairingOffer, DesktopBridgePairingStore, UserDefaults, URLSession, String) {
        let id = UUID().uuidString
        let suite = "nodus.tests.pairing-recovery.\(id)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = DesktopBridgePairingStore(defaults: defaults, keychain: KeychainStore(service: suite))
        let offer = DesktopPairingOffer(version: 2, id: id, code: "ABCDE-23456", origins: ["https://mac.nodus.test:7443"],
            certificateFingerprint: String(repeating: "a", count: 64), vaultIds: ["vault-a", "vault-b"], domains: [.corpus, .writing],
            expiresAt: Date().addingTimeInterval(600), deviceName: "Mac", macDeviceId: UUID().uuidString,
            vaults: nil, relay: nil, renewalPairingId: renewal ? UUID().uuidString : nil)
        PairingRecoveryProtocol.state.reset(offer: offer)
        if let grant = offer.renewalPairingId {
            let pairing = try DesktopBridgePairing(id: grant, origin: offer.origins[0], certificateFingerprint: offer.certificateFingerprint,
                deviceId: "phone", deviceName: "Phone", vaultIds: Set(offer.vaultIds), domains: Set(offer.domains),
                pairedAt: Date(timeIntervalSince1970: 1_700_000_000), expiresAt: nil)
            try store.save(pairing, token: PairingRecoveryProtocol.state.original)
        }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PairingRecoveryProtocol.self]
        return (offer, store, defaults, URLSession(configuration: configuration), suite)
    }

    private func clean(_ store: DesktopBridgePairingStore, _ defaults: UserDefaults, _ session: URLSession,
                       _ suite: String, _ offer: DesktopPairingOffer) {
        session.invalidateAndCancel()
        for pairing in store.pairings() { try? store.revokeLocally(pairing) }
        try? store.completePendingPairing(grantId: offer.renewalPairingId ?? offer.id)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("a lost initial POST response survives recreation and an expired code, without another POST")
    func lostInitialResponse() async throws {
        let (offer, store, defaults, session, suite) = try fixture()
        defer { clean(store, defaults, session, suite, offer) }
        PairingRecoveryProtocol.state.failure = .afterCommit
        await #expect(throws: URLError.self) {
            try await DesktopBridgeClient.pair(offer: offer, deviceId: "phone", deviceName: "Phone", store: store, session: session)
        }
        #expect(store.pairings().isEmpty); #expect(store.pendingOffers().count == 1)
        let pending = try #require(store.pendingPairingToken(offerId: offer.id))
        #expect(!String(describing: defaults.dictionaryRepresentation()).contains(pending))
        #expect(!String(describing: defaults.dictionaryRepresentation()).contains(offer.code))
        defaults.removeObject(forKey: "desktop-bridge-pending-offer-ids-v1")
        #expect(store.pendingOffers().count == 1, "The durable Keychain index must survive missing preferences metadata.")
        var data = try JSONSerialization.jsonObject(with: JSONEncoder.nodus.encode(offer)) as! [String: Any]
        data["expiresAt"] = "2000-01-01T00:00:00Z"
        let expired = try JSONDecoder.nodus.decode(DesktopPairingOffer.self, from: JSONSerialization.data(withJSONObject: data))
        let recreated = DesktopBridgePairingStore(defaults: defaults, keychain: KeychainStore(service: suite))
        let recovered = try await DesktopBridgeClient.pair(offer: expired, deviceId: "phone", deviceName: "Phone", store: recreated, session: session)
        #expect(recovered.pairing.id == offer.id); #expect(recovered.token == pending)
        #expect(store.pairings().count == 1); #expect(PairingRecoveryProtocol.state.posts == 1)
        #expect(PairingRecoveryProtocol.state.receipts == 1)
        try store.completePendingPairing(grantId: recovered.pairing.id)
        #expect(store.pendingOffers().isEmpty); #expect(store.pendingPairingToken(offerId: offer.id) == nil)
    }

    @Test("an interrupted request before commit retries with the same candidate and saves exactly one grant")
    func beforeCommit() async throws {
        let (offer, store, defaults, session, suite) = try fixture()
        defer { clean(store, defaults, session, suite, offer) }
        PairingRecoveryProtocol.state.failure = .beforeCommit
        await #expect(throws: URLError.self) {
            try await DesktopBridgeClient.pair(offer: offer, deviceId: "phone", deviceName: "Phone", store: store, session: session)
        }
        let pending = try #require(store.pendingPairingToken(offerId: offer.id))
        let result = try await DesktopBridgeClient.pair(offer: offer, deviceId: "phone", deviceName: "Phone", store: store, session: session)
        #expect(result.token == pending); #expect(store.pairings().count == 1)
        #expect(PairingRecoveryProtocol.state.posts == 2); #expect(PairingRecoveryProtocol.state.commits == 1)
    }

    @Test("the received credential remains recoverable until workspace persistence, including an older Mac")
    func capabilitiesStillPending() async throws {
        let (offer, store, defaults, session, suite) = try fixture()
        defer { clean(store, defaults, session, suite, offer) }
        PairingRecoveryProtocol.state.legacy = true
        let result = try await DesktopBridgeClient.pair(offer: offer, deviceId: "phone", deviceName: "Phone", store: store, session: session)
        #expect(store.credential(for: result.pairing) == result.token)
        #expect(store.pendingOffers().count == 1)
        let count = PairingRecoveryProtocol.state.posts
        let resumed = try await DesktopBridgeClient.pair(offer: offer, deviceId: "phone", deviceName: "Phone", store: store, session: session)
        #expect(resumed.pairing == result.pairing); #expect(resumed.token == result.token)
        #expect(PairingRecoveryProtocol.state.posts == count)
    }

    @Test("a lost code renewal response preserves identity and scopes and does not prepare a second replacement")
    func lostRenewalResponse() async throws {
        let (offer, store, defaults, session, suite) = try fixture(renewal: true)
        defer { clean(store, defaults, session, suite, offer) }
        let original = try #require(store.pairings().first)
        PairingRecoveryProtocol.state.failure = .afterCommit
        await #expect(throws: URLError.self) {
            try await DesktopBridgeClient.pair(offer: offer, deviceId: "phone", deviceName: "Phone", store: store, session: session)
        }
        let recovered = try await DesktopBridgeClient.pair(offer: offer, deviceId: "phone", deviceName: "Phone", store: store, session: session)
        #expect(recovered.pairing == original); #expect(store.pairings() == [original])
        #expect(store.pendingRenewal(for: original) == nil); #expect(PairingRecoveryProtocol.state.posts == 1)
        _ = try await DesktopBridgeClient.pair(offer: offer, deviceId: "phone", deviceName: "Phone", store: store, session: session)
        #expect(store.pendingRenewal(for: original) == nil)
    }

    @Test("a receipt for another device or grant cannot be installed; editing the pending Mac identity is rejected")
    func wrongReceipt() async throws {
        let (offer, store, defaults, session, suite) = try fixture()
        defer { clean(store, defaults, session, suite, offer) }
        PairingRecoveryProtocol.state.failure = .afterCommit
        await #expect(throws: URLError.self) {
            try await DesktopBridgeClient.pair(offer: offer, deviceId: "phone", deviceName: "Phone", store: store, session: session)
        }
        PairingRecoveryProtocol.state.forged = true
        await #expect(throws: DesktopBridgeError.permissionDenied) {
            try await DesktopBridgeClient.pair(offer: offer, deviceId: "phone", deviceName: "Phone", store: store, session: session)
        }
        #expect(store.pairings().isEmpty); #expect(store.pendingOffers().count == 1)
        var fields = try JSONSerialization.jsonObject(with: JSONEncoder.nodus.encode(offer)) as! [String: Any]
        fields["macDeviceId"] = UUID().uuidString
        let changed = try JSONDecoder.nodus.decode(DesktopPairingOffer.self, from: JSONSerialization.data(withJSONObject: fields))
        await #expect(throws: DesktopBridgeError.permissionDenied) {
            try await DesktopBridgeClient.pair(offer: changed, deviceId: "phone", deviceName: "Phone", store: store, session: session)
        }
        #expect(PairingRecoveryProtocol.state.posts == 1)
    }
}

private final class PairingRecoveryProtocol: URLProtocol, @unchecked Sendable {
    static let state = PairingRecoveryState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var delivered = request
        if delivered.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            delivered.httpBody = data
        }
        let result = Self.state.respond(delivered)
        if let error = result.error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: result.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class PairingRecoveryState: @unchecked Sendable {
    enum Failure { case none, beforeCommit, afterCommit }
    let original = String(repeating: "o", count: 43)
    private let lock = NSLock()
    private var offer: DesktopPairingOffer?
    private var token: String?
    private var consumed = false
    private var mode = Failure.none
    private var legacyMode = false
    private var forgedReceipt = false
    private var counts = (posts: 0, commits: 0, receipts: 0)
    var posts: Int { lock.withLock { counts.posts } }
    var commits: Int { lock.withLock { counts.commits } }
    var receipts: Int { lock.withLock { counts.receipts } }
    var failure: Failure { get { lock.withLock { mode } } set { lock.withLock { mode = newValue } } }
    var legacy: Bool { get { lock.withLock { legacyMode } } set { lock.withLock { legacyMode = newValue } } }
    var forged: Bool { get { lock.withLock { forgedReceipt } } set { lock.withLock { forgedReceipt = newValue } } }
    func reset(offer: DesktopPairingOffer) {
        lock.withLock { self.offer = offer; token = offer.renewalPairingId == nil ? nil : original; consumed = false
            mode = .none; legacyMode = false; forgedReceipt = false; counts = (0, 0, 0) }
    }
    func respond(_ request: URLRequest) -> (status: Int, data: Data, error: URLError.Code?) {
        lock.withLock {
            guard let offer else { return (500, Data(), nil) }
            let receipt: [String: Any] = ["id": forgedReceipt ? "other-grant" : (offer.renewalPairingId ?? offer.id),
                "deviceId": "phone", "deviceName": "Phone", "vaultIds": offer.vaultIds,
                "domains": offer.domains.map(\.rawValue), "createdAt": "2023-11-14T22:13:20Z"]
            if request.url?.path == "/bridge/v2/pairing" {
                guard let token, request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" else { return (401, Data(), nil) }
                if legacyMode { return (404, Data(), nil) }
                counts.receipts += 1
                return (200, try! JSONSerialization.data(withJSONObject: ["pairing": receipt]), nil)
            }
            counts.posts += 1
            let failure = mode; mode = .none
            if failure == .beforeCommit { return (0, Data(), .notConnectedToInternet) }
            guard !consumed, let data = request.httpBody,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  body["code"] == offer.code, let candidate = body["nextToken"] else { return (400, Data(), nil) }
            if offer.renewalPairingId != nil, request.value(forHTTPHeaderField: "Authorization") != "Bearer \(token!)" { return (401, Data(), nil) }
            token = legacyMode ? String(repeating: "l", count: 43) : candidate; consumed = true; counts.commits += 1
            if failure == .afterCommit { return (0, Data(), .networkConnectionLost) }
            return (201, try! JSONSerialization.data(withJSONObject: ["pairing": receipt, "token": token!]), nil)
        }
    }
}
