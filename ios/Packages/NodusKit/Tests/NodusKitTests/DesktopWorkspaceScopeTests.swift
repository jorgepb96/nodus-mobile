import Foundation
import Testing
@testable import NodusKit

@Suite("Authenticated dynamic workspace scopes", .serialized)
struct DesktopWorkspaceScopeTests {
    struct Fixture {
        let id = UUID().uuidString
        let root: URL
        let defaults: UserDefaults
        let keychain: KeychainStore
        let store: DesktopBridgePairingStore
        let recovery: PrivateBridgeAuthoringRecovery
        init() throws {
            root = URL.temporaryDirectory.appendingPathComponent("dynamic-workspace-" + id)
            defaults = UserDefaults(suiteName: "dynamic-workspace-" + id)!
            keychain = KeychainStore(service: "dynamic-workspace-" + id)
            store = DesktopBridgePairingStore(defaults: defaults, keychain: keychain, cacheDirectory: root)
            recovery = PrivateBridgeAuthoringRecovery(directory: root.appendingPathComponent("archives"), keychain: keychain)
        }
        func pairing(_ id: String? = nil, whole: Bool? = true, vaults: Set<String> = ["kept", "removed"]) throws -> DesktopBridgePairing {
            try .init(id: id ?? self.id, origin: "https://workspace.fixture:7443", certificateFingerprint: String(repeating: "a", count: 64), deviceId: "phone-identity", deviceName: "Phone", vaultIds: vaults, domains: [.corpus, .writing, .researchGeneration, .primarySourceFiles], pairedAt: Date(timeIntervalSince1970: 1_000), expiresAt: Date().addingTimeInterval(3_600), wholeWorkspace: whole, macDeviceId: "actual-Mac")
        }
        func cache(_ id: String? = nil) throws -> PrivateBridgeCache { try .init(pairingId: id ?? self.id, directory: root, keychain: keychain) }
        func clean() { defaults.removePersistentDomain(forName: "dynamic-workspace-" + id); try? FileManager.default.removeItem(at: root) }
    }
    func capabilities(_ vaults: [String], whole: Bool? = true, mac: String = "actual-Mac", domains: [DesktopBridgeDomain]? = nil) throws -> DesktopLiveCapabilities {
        var json: [String: JSONValue] = ["protocolVersion": .int(2), "deviceId": .string(mac), "deviceName": .string("Mac"), "vaults": .array(vaults.map { .object(["id": .string($0), "name": .string($0), "type": .string("academic")]) }), "operations": .array([])]
        if let whole { json["wholeWorkspace"] = .bool(whole) }
        if let domains { json["domains"] = .array(domains.map { .string($0.rawValue) }) }
        return try JSONDecoder.nodus.decode(DesktopLiveCapabilities.self, from: JSONEncoder.nodus.encode(JSONValue.object(json)))
    }
    @Test("only explicit whole scope grows; actual Mac identity is independent from phone identity")
    func authorization() throws {
        let f = try Fixture(); defer { f.clean() }
        let first = try f.pairing(), grown = try first.refreshedWorkspace(capabilities(["kept", "future"]), trustedMacDeviceId: "actual-Mac")
        #expect(grown.id == first.id && grown.deviceId == "phone-identity")
        #expect(grown.macDeviceId == "actual-Mac" && grown.certificateFingerprint == first.certificateFingerprint)
        #expect(grown.vaultIds == ["kept", "future"])
        #expect(grown.retainedAuthoringVaultIds == ["removed"])
        for flag in [nil, false] as [Bool?] {
            let enumerated = try f.pairing(whole: flag)
            #expect(throws: DesktopBridgeError.permissionDenied) { try enumerated.refreshedWorkspace(capabilities(["kept", "future"]), trustedMacDeviceId: "actual-Mac") }
            #expect(try enumerated.refreshedWorkspace(capabilities(["kept"]), trustedMacDeviceId: "actual-Mac").wholeWorkspace == flag)
        }
        #expect(throws: DesktopBridgeError.permissionDenied) { try first.refreshedWorkspace(capabilities(["kept"], mac: "phone-identity"), trustedMacDeviceId: "actual-Mac") }
        #expect(throws: DesktopBridgeError.permissionDenied) { try first.refreshedWorkspace(capabilities(["kept"], whole: nil), trustedMacDeviceId: "actual-Mac") }
        #expect(throws: DesktopBridgeError.malformedResponse) { try first.refreshedWorkspace(capabilities(["kept", "kept"]), trustedMacDeviceId: "actual-Mac") }
        #expect(try first.refreshedWorkspace(capabilities([]), trustedMacDeviceId: "actual-Mac").vaultIds.isEmpty)
    }
    @Test("fresh stored vault/domain scope gates private files and cannot promote a legacy client")
    func freshPrivateFileGrants() async throws {
        let f = try Fixture(); defer { f.clean() }
        let first = try f.pairing(); try f.store.save(first, token: "old")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WorkspaceScopeProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let client = DesktopBridgeClient(pairing: first, token: "old", store: f.store, session: session)
        WorkspaceScopeProtocol.state.configure(status: 200, data: Data("{}".utf8))
        let fresh = try first.refreshedWorkspace(capabilities(["kept", "future"], domains: [.corpus]), trustedMacDeviceId: "actual-Mac")
        try f.store.save(fresh, token: "renewed")
        await #expect(throws: DesktopBridgeError.permissionDenied) { _ = try await client.fileDescriptor(vaultId: "kept", kind: .archiveFile, id: "file") }
        await #expect(throws: DesktopBridgeError.permissionDenied) { _ = try await client.corpus(vaultId: "removed") }
        #expect(WorkspaceScopeProtocol.state.count == 0)
        _ = try await client.corpus(vaultId: "future")
        #expect(WorkspaceScopeProtocol.state.tokens == ["Bearer renewed"])
        let legacy = try f.pairing("legacy", whole: nil); try f.store.save(legacy, token: "legacy")
        let oldClient = DesktopBridgeClient(pairing: legacy, token: "legacy", store: f.store, session: session)
        try f.store.save(f.pairing("legacy", whole: true), token: "unapproved")
        await #expect(throws: DesktopBridgeError.permissionDenied) { _ = try await oldClient.controlPlane("health") }
        #expect(WorkspaceScopeProtocol.state.count == 1)
        try f.store.revokeLocally(first, cacheDirectory: f.root); try f.store.revokeLocally(legacy, cacheDirectory: f.root)
    }
    @Test("only an actual Bridge invalid_token closes authorization; late paid response survives before purge")
    func remoteRevoke() async throws {
        let f = try Fixture(); defer { f.clean() }
        let first = try f.pairing(vaults: ["kept"]); try f.store.save(first, token: "old")
        let cache = try f.cache(), queue = try CompanionDocumentOutbox(cache: cache, vaultId: "kept", data: nil)
        _ = try await queue.create(input: .object(["title": .string("Authored draft"), "content": .string("")]))
        try await cache.store(Data("Consulted private bytes".utf8), vaultId: "kept", domain: .corpus, recordId: "source")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WorkspaceScopeProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let client = DesktopBridgeClient(pairing: first, token: "old", store: f.store, session: session)
        WorkspaceScopeProtocol.state.configure(status: 401, data: Data("{\"error\":\"invalid_api_key\"}".utf8))
        await #expect(throws: APIError.self) { _ = try await client.controlPlane("health") }
        #expect(!f.store.isAuthorizationRevoked(pairingId: first.id))
        try cache.beginAuthoringActivity()
        WorkspaceScopeProtocol.state.configure(status: 401, data: Data("{\"error\":\"invalid_token\"}".utf8))
        await #expect(throws: DesktopBridgeError.credentialRevoked) { _ = try await client.controlPlane("health") }
        #expect(f.store.pairings().isEmpty && f.store.pairings(includeRevoked: true).count == 1)
        #expect(f.store.credential(for: first) == "old", "Backup still owns the original encryption key.")
        await #expect(throws: (any Error).self) { _ = try await cache.data(vaultId: "kept", domain: .corpus, recordId: "source") }
        #expect(throws: (any Error).self) { try cache.beginAuthoringActivity() }
        await #expect(throws: (any Error).self) { try await cache.freezeForRevocation(true) }
        let generation = UUID().uuidString, rawKey = "autonomous:\(generation):completion:exact"
        try await cache.storeIndexedGeneration(JSONEncoder.nodus.encode(JSONValue.string("Actual late paid response")), vaultId: "kept", recordId: rawKey, indexId: "autonomous:completion-index:v1", entity: rawKey)
        // Use the actual non-indexed production persistence paths while closing:
        // a writer flush and a paid map journal both call cache.store.
        try await queue.prepareForRevocation()
        let journal = try await CompanionWorldMapGenerationJournal(cache: cache, vault: "kept")
        let accepted = try CompanionWorldMapGenerationCheckpoint(.object(["version": .int(1), "id": .string(UUID().uuidString), "request": .object(["mapId": .string("isolated-map"), "mode": .string("create"), "extra": .string("river")]), "revision": .string(String(repeating: "a", count: 64)), "model": .object(["provider": .string("gemini"), "model": .string("image")]), "state": .string("accepted"), "createdAt": .string(ISO8601DateFormatter().string(from: Date()))]))
        let saved = try accepted.changing(state: .saved, bytes: Data("Late journal result".utf8), mime: "image/png")
        try await journal.put(saved)
        #expect(try await journal.load(scope: saved.scope)?.publicationInput == saved.publicationInput)
        cache.endAuthoringActivity()
        try await PrivateBridgeCache.waitForAuthoringToFinish(pairingId: first.id, directory: f.root)
        try await queue.prepareForRevocation(); try await cache.freezeForRevocation(true)
        let snapshot = try await cache.authoringRecoverySnapshot(vaultIds: first.vaultIds)
        let receipt = try await f.recovery.preserve(snapshot: snapshot, pairing: first, macDeviceId: "actual-Mac")
        try f.store.revokeLocally(first, authoringRecovery: receipt, cacheDirectory: f.root)
        try await f.recovery.completeRevocation(receipt)
        #expect(f.store.credential(for: first) == nil && f.store.pairings(includeRevoked: true).isEmpty)
        let replacement = try f.pairing("replacement", vaults: ["kept"]), recovered = try f.cache("replacement")
        #expect(try await f.recovery.adopt(pairing: replacement, macDeviceId: "actual-Mac", cache: recovered) == snapshot.records.count)
        #expect(try await recovered.data(vaultId: "kept", domain: .researchGeneration, recordId: rawKey) == JSONEncoder.nodus.encode(JSONValue.string("Actual late paid response")))
        let reopened = try CompanionDocumentOutbox(cache: recovered, vaultId: "kept", data: await recovered.data(vaultId: "kept", domain: .writing, recordId: "companion-documents-v1"))
        try await reopened.synchronize { _ in Issue.record("New grant must not replay authoring without review"); throw DesktopBridgeError.permissionDenied }
        await #expect(throws: DesktopBridgeError.permissionDenied) { _ = try await client.controlPlane("health") }
        #expect(WorkspaceScopeProtocol.state.count == 1)
        try? f.keychain.remove(receipt.recoveryKeyName); try? f.keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: "replacement"))
    }
    @Test("authenticated metadata refresh cannot roll back renewed credentials and expiry")
    func renewalDuringCatalogueRefresh() throws {
        let f = try Fixture(); defer { f.clean() }
        let original = try f.pairing(); try f.store.save(original, token: "old")
        let renewed = try DesktopBridgePairing(id: original.id, origin: original.origin,
            certificateFingerprint: original.certificateFingerprint, deviceId: original.deviceId,
            deviceName: original.deviceName, vaultIds: original.vaultIds, domains: original.domains,
            pairedAt: original.pairedAt, expiresAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 7_200),
            wholeWorkspace: true, macDeviceId: "actual-Mac")
        try f.store.save(renewed, token: "renewed")
        let refreshed = try f.store.updateWorkspaceMetadata(capabilities(["kept", "future"]), expectedPairing: original, trustedMacDeviceId: "actual-Mac")
        #expect(refreshed.expiresAt == renewed.expiresAt)
        #expect(f.store.credential(for: refreshed) == "renewed")
        #expect(!f.store.markAuthorizationRevoked(pairingId: original.id, rejectedToken: "old"))
        #expect(!f.store.isAuthorizationRevoked(pairingId: original.id))
    }
    @Test("compact whole-workspace flag is explicit and legacy offers remain enumerated")
    func compactFlag() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let base: [Any] = [2, "offer", "ABCDE-23456", ["https://workspace.fixture"], String(repeating: "a", count: 64), ["corpus"], "2023-11-14T22:23:20Z", "Mac", [["kept", "Kept", "academic"]], NSNull(), "d37f3d86-4351-4af4-9cf5-455fa11c098f"]
        func read(_ values: [Any]) throws -> DesktopPairingOffer {
            try DesktopPairingOffer.read("nodus://pair?q=" + JSONSerialization.data(withJSONObject: values).base64EncodedString(), now: now)
        }
        #expect(try read(base).wholeWorkspace == nil)
        #expect(try read(base + ["d37f3d86-4351-4af4-9cf5-455fa11c098f"]).wholeWorkspace == nil)
        for flag in [true, false] { #expect(try read(base + [NSNull(), flag]).wholeWorkspace == flag) }
        for invalid in [1, "true", NSNull()] as [Any] {
            #expect(throws: DesktopBridgeError.malformedResponse) { try read(base + [NSNull(), invalid]) }
        }
    }
    @Test("removed-vault authorship is archived for review while other selected copies survive")
    func removedVault() async throws {
        let f = try Fixture(); defer { f.clean() }
        let original = try f.pairing(), cache = try f.cache()
        for vault in original.vaultIds {
            let queue = try CompanionDocumentOutbox(cache: cache, vaultId: vault, data: nil)
            _ = try await queue.create(input: .object(["title": .string(vault), "content": .string("")]))
            try await cache.store(Data(vault.utf8), vaultId: vault, domain: .corpus, recordId: "reusable")
            _ = try await cache.saveReadPack(id: UUID(), vaultId: vault, title: vault, expiresAt: Date().addingTimeInterval(3_600), records: [.init(domain: .corpus, recordId: "source", data: Data(vault.utf8))])
        }
        let keptBefore = try await cache.data(vaultId: "kept", domain: .writing, recordId: "companion-documents-v1")
        try await cache.freezeForRevocation(true)
        let snapshot = try await cache.authoringRecoverySnapshot(vaultIds: original.vaultIds)
        let retired = snapshot.records.filter { $0.vaultId == "removed" }
        let receipt = try await f.recovery.preserve(snapshot: snapshot.selectingVaults(["removed"]), pairing: original, macDeviceId: "actual-Mac", forceReview: true)
        #expect(throws: (any Error).self) { try f.store.revokeLocally(original, authoringRecovery: receipt, cacheDirectory: f.root) }
        await #expect(throws: (any Error).self) { try await cache.retireArchivedVaultRecords(snapshot.records, receipt: receipt) }
        try await cache.retireArchivedVaultRecords(retired, receipt: receipt)
        try await f.recovery.completeRevocation(receipt)
        try await cache.purgeReadingCopies(vaultIds: ["removed"]); try await cache.freezeForRevocation(false)
        #expect(try await cache.data(vaultId: "kept", domain: .writing, recordId: "companion-documents-v1") == keptBefore)
        await #expect(throws: DesktopBridgeError.permissionDenied) { _ = try await cache.data(vaultId: "removed", domain: .writing, recordId: "companion-documents-v1") }
        #expect(try await cache.data(vaultId: "kept", domain: .corpus, recordId: "reusable") == Data("kept".utf8))
        #expect(try await cache.readPacks(vaultId: "kept").count == 1)
        let fresh = try f.cache()
        #expect(try await f.recovery.adopt(pairing: original, macDeviceId: "actual-Mac", cache: fresh) == retired.count)
        await #expect(throws: DesktopBridgeError.permissionDenied) { _ = try await cache.store(Data("stale overwrite".utf8), vaultId: "removed", domain: .writing, recordId: "companion-documents-v1") }
        await #expect(throws: DesktopBridgeError.permissionDenied) { try await cache.remove(vaultId: "removed", domain: .writing, recordId: "companion-documents-v1") }
        #expect(try await fresh.data(vaultId: "removed", domain: .corpus, recordId: "reusable") == nil)
        #expect(try await fresh.readPacks(vaultId: "removed").isEmpty)
        let restored = try CompanionDocumentOutbox(cache: fresh, vaultId: "removed", data: await fresh.data(vaultId: "removed", domain: .writing, recordId: "companion-documents-v1"))
        try await restored.synchronize { _ in Issue.record("Returning scope requires review even under the same grant"); throw DesktopBridgeError.permissionDenied }
        let all = try await f.recovery.allSummaries(); #expect(all.count == 1)
        #expect(try Data(contentsOf: receipt.archiveURL).range(of: Data("removed".utf8)) == nil)
        let modes = try FileManager.default.attributesOfItem(atPath: receipt.archiveURL.path)[.posixPermissions] as? NSNumber
        #expect(modes?.intValue == 0o600)
        try? f.keychain.remove(receipt.recoveryKeyName); try? f.keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: original.id))
    }
}
private final class WorkspaceScopeProtocol: URLProtocol, @unchecked Sendable {
    static let state = WorkspaceScopeHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "workspace.fixture" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let result = Self.state.receive(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.1); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class WorkspaceScopeHTTPState: @unchecked Sendable {
    private let lock = NSLock(); private var status = 200; private var data = Data(); private var values: [String] = []
    func configure(status: Int, data: Data) { lock.withLock { self.status = status; self.data = data; values = [] } }
    func receive(_ request: URLRequest) -> (Int, Data) { lock.withLock { values.append(request.value(forHTTPHeaderField: "Authorization") ?? ""); return (status, data) } }
    var count: Int { lock.withLock { values.count } }
    var tokens: [String] { lock.withLock { values } }
}
