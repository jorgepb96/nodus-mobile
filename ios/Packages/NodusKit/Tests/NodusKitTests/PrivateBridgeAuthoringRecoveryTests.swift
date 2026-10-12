import Foundation
import Testing
@testable import NodusKit

@Suite("Revoked authoring preservation")
struct PrivateBridgeAuthoringRecoveryTests {
    struct Fixture {
        let id = UUID().uuidString
        let root: URL
        let keychain: KeychainStore
        let defaults: UserDefaults
        let store: DesktopBridgePairingStore
        let recovery: PrivateBridgeAuthoringRecovery
        init() throws {
            root = .temporaryDirectory.appendingPathComponent("authoring-recovery-\(id)")
            keychain = KeychainStore(service: "authoring-recovery-\(id)")
            defaults = UserDefaults(suiteName: "authoring-recovery-\(id)")!
            store = DesktopBridgePairingStore(defaults: defaults, keychain: keychain)
            recovery = PrivateBridgeAuthoringRecovery(directory: root.appendingPathComponent("archives"), keychain: keychain)
        }
        func pairing(_ grant: String, pin: String = String(repeating: "a", count: 64), vaults: Set<String> = ["vault"]) throws -> DesktopBridgePairing {
            try DesktopBridgePairing(id: grant, origin: "https://mac.nodus.test:7443", certificateFingerprint: pin, deviceId: "phone", deviceName: "Phone", vaultIds: vaults, domains: [.writing, .researchGeneration, .corpus], pairedAt: Date(), expiresAt: Date().addingTimeInterval(600))
        }
        func cache(_ id: String) throws -> PrivateBridgeCache { try PrivateBridgeCache(pairingId: id, directory: root, keychain: keychain) }
        func clean() { defaults.removePersistentDomain(forName: "authoring-recovery-\(id)"); try? FileManager.default.removeItem(at: root) }
    }
    @Test("unlink needs a verified encrypted backup; relink suspends complete authoring and excludes consultation")
    func encryptedRoundTrip() async throws {
        let f = try Fixture(); defer { f.clean() }
        let old = try f.pairing("old"), cache = try f.cache("old")
        try f.store.save(old, token: "secret-token")
        let draft: JSONValue = .object(["workspaceOrganizationSnapshot": .object(["notes": .array([.object(["title": .string("Consulted unrelated note")])])]), "vaultId": .string("vault"), "records": .object(["draft": .object(["state": .string("conflict"), "content": .string("My unsubmitted manuscript"), "frozenRequest": .object(["requestId": .string("receipt-original"), "expectedRevision": .int(42)])])]), "workspaceOrganizationCommands": .object(["move": .object(["state": .string("pending"), "destinationId": .string("folder-original")])])])
        try await cache.store(JSONEncoder.nodus.encode(draft), vaultId: "vault", domain: .writing, recordId: "companion-documents-v1")
        try await cache.store(Data("Consulted private source".utf8), vaultId: "vault", domain: .corpus, recordId: "source")
        #expect(throws: (any Error).self) { try f.store.revokeLocally(old, cacheDirectory: f.root) }
        #expect(f.store.credential(for: old) == "secret-token")
        try await cache.freezeForRevocation(true)
        let snapshot = try await cache.authoringRecoverySnapshot(vaultIds: old.vaultIds)
        #expect(snapshot.records.count == 1)
        let receipt = try await f.recovery.preserve(snapshot: snapshot, pairing: old, macDeviceId: "actual-Mac")
        #expect(try Data(contentsOf: receipt.archiveURL).range(of: Data("My unsubmitted manuscript".utf8)) == nil)
        try f.store.revokeLocally(old, authoringRecovery: receipt, cacheDirectory: f.root)
        try await f.recovery.completeRevocation(receipt)
        #expect(f.store.credential(for: old) == nil)
        let localArchives = try await f.recovery.allSummaries()
        #expect(localArchives.count == 1)
        let exported = try JSONDecoder.nodus.decode(JSONValue.self, from: await f.recovery.export(id: localArchives[0].id))
        let exportedBytes = try #require(exported.objectValue?["records"]?.arrayValue?.first?.objectValue?["data"]?.stringValue.flatMap { Data(base64Encoded: $0) })
        var authoredOnly = draft.objectValue!
        authoredOnly["workspaceOrganizationSnapshot"] = nil
        #expect(try JSONDecoder.nodus.decode(JSONValue.self, from: exportedBytes) == .object(authoredOnly))
        let fresh = try f.pairing("new"), destination = try f.cache("new")
        #expect(try await f.recovery.adopt(pairing: fresh, macDeviceId: "other-Mac", cache: destination) == 0)
        #expect(try await f.recovery.adopt(pairing: f.pairing("new", pin: String(repeating: "b", count: 64)), macDeviceId: "actual-Mac", cache: destination) == 0)
        #expect(try await f.recovery.adopt(pairing: fresh, macDeviceId: "actual-Mac", cache: destination) == 1)
        let bytes = try #require(await destination.data(vaultId: "vault", domain: .writing, recordId: "companion-documents-v1"))
        let recovered = try JSONDecoder.nodus.decode(JSONValue.self, from: bytes)
        let row = recovered.objectValue?["records"]?.objectValue?["draft"]?.objectValue
        #expect(row?["state"] == .string("blocked"))
        #expect(row?["frozenRequest"] == draft.objectValue?["records"]?.objectValue?["draft"]?.objectValue?["frozenRequest"])
        #expect(recovered.objectValue?["workspaceOrganizationCommands"]?.objectValue?["move"]?.objectValue?["state"] == .string("blocked"))
        #expect(try await destination.data(vaultId: "vault", domain: .corpus, recordId: "source") == nil)
        #expect(try await f.recovery.adopt(pairing: fresh, macDeviceId: "actual-Mac", cache: destination) == 0)
        try? f.keychain.remove(receipt.recoveryKeyName)
        try? f.keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: "new"))
    }
    @Test("active paid work shares one close gate until durable raw storage; recovered intents cannot pay again")
    func paidGate() async throws {
        let f = try Fixture(); defer { f.clean() }
        let cache = try f.cache("grant"), second = try f.cache("grant")
        try cache.beginAuthoringActivity()
        await #expect(throws: (any Error).self) { try await second.freezeForRevocation(true) }
        let generation = UUID().uuidString
        let recordId = "autonomous:\(generation):completion:hash"
        try await cache.storeIndexedGeneration(JSONEncoder.nodus.encode(JSONValue.string("Paid complete response")), vaultId: "vault", recordId: recordId, indexId: "autonomous:completion-index:v1", entity: recordId)
        cache.endAuthoringActivity()
        try await second.freezeForRevocation(true)
        #expect(throws: (any Error).self) { try cache.beginAuthoringActivity() }
        let snapshot = try await cache.authoringRecoverySnapshot(vaultIds: ["vault"])
        #expect(snapshot.records.count == 2)
        #expect(snapshot.records.allSatisfy { $0.vaultId == "vault" })
        let checkpoint: JSONValue = .object(["id": .string(generation), "request": .object([:]), "state": .string("running")])
        let raw = try JSONEncoder.nodus.encode(checkpoint)
        let name = "work-" + String(repeating: "a", count: 64) + ".bridgecache"
        let destination = try f.cache("fresh")
        try await destination.adoptAuthoringRecovery(snapshot.records + [.init(filename: name, vaultId: "vault", data: raw, ledger: false, writing: false, recordId: nil, generationKind: nil)], requiresReview: true)
        #expect(try await destination.data(vaultId: "vault", domain: .researchGeneration, recordId: recordId) == JSONEncoder.nodus.encode(JSONValue.string("Paid complete response")))
        await #expect(throws: (any Error).self) { try await destination.requireGenerationExecutionAllowed(vaultId: "vault", generationId: generation) }
        try await destination.requireGenerationExecutionAllowed(vaultId: "vault", generationId: UUID().uuidString)
        for id in ["grant", "fresh"] { try? f.keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)) }
    }
    @Test("paid image saved before a publication ledger recovers exact provider-free review")
    func crashBeforePublication() async throws {
        let f = try Fixture(); defer { f.clean() }
        let cache = try f.cache("image-old")
        let id = UUID().uuidString
        let accepted = try CompanionWorldMapGenerationCheckpoint(.object(["version": .int(1), "id": .string(id), "request": .object(["mapId": .string("map"), "mode": .string("create"), "extra": .string("river")]), "revision": .string(String(repeating: "a", count: 64)), "model": .object(["provider": .string("gemini"), "model": .string("image")]), "state": .string("accepted"), "createdAt": .string(ISO8601DateFormatter().string(from: Date()))]))
        let saved = try accepted.changing(state: .saved, bytes: Data("paid exact image".utf8), mime: "image/png")
        let journal = try await CompanionWorldMapGenerationJournal(cache: cache, vault: "vault")
        try await journal.put(saved)
        // Normal publication preparation can exist without any attached checkpoint.
        let originalLedger = try DesktopJobLedger(cache: cache, vaultId: "vault", data: nil)
        _ = try await originalLedger.prepare(id: id, method: "saveMobileWorldMapImage", args: [saved.publicationInput!])
        let snapshot = try await cache.authoringRecoverySnapshot(vaultIds: ["vault"])
        let destination = try f.cache("image-new")
        try await destination.adoptAuthoringRecovery(snapshot.records, requiresReview: true)
        let ledger = try DesktopJobLedger(cache: destination, vaultId: "vault", data: await destination.data(vaultId: "vault", domain: .researchGeneration, recordId: "job-ledger-v1"))
        let review = try #require(await ledger.all().first)
        #expect(review.id == id && review.state == "recoveryReview")
        #expect(review.method == "saveMobileWorldMapImage")
        #expect(review.checkpoint?.objectValue?["recoveryReviewRequired"] == .bool(true))
        #expect(review.checkpoint?.objectValue?["bytes"] == saved.value.objectValue?["bytes"])
        #expect(review.args == [saved.publicationInput!])
        try await ledger.synchronize(list: { Issue.record("Review must not fetch jobs"); return [] }, submit: { _ in throw DesktopBridgeError.permissionDenied })
        let approved = try await ledger.approveRecoveredSavedResult(id: id)
        #expect(approved.id == id && approved.state == "pending" && approved.jobId == nil)
        #expect(approved.args == review.args)
        #expect(approved.checkpoint?.objectValue?["recoveryReviewRequired"] == nil)
        #expect(approved.checkpoint?.objectValue?["bytes"] == review.checkpoint?.objectValue?["bytes"])
        await #expect(throws: (any Error).self) { try await destination.requireGenerationExecutionAllowed(vaultId: "vault", generationId: id) }
        for key in ["image-old", "image-new"] { try? f.keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: key)) }
    }

    @Test("unknown legacy work prevents destructive closure")
    func unknownWork() async throws {
        let f = try Fixture(); defer { f.clean() }
        let cache = try f.cache("legacy")
        try await cache.store(JSONEncoder.nodus.encode(JSONValue.object(["unrecognised": .string("Keep me")])), vaultId: "vault", domain: .writing, recordId: "unknown")
        await #expect(throws: (any Error).self) { _ = try await cache.authoringRecoverySnapshot(vaultIds: ["vault"]) }
        #expect(try await cache.data(vaultId: "vault", domain: .writing, recordId: "unknown") != nil)
        try? f.keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: "legacy"))
    }
    @Test("new grant suspends send authorization without deleting original payloads or accepted receipts")
    func outboxSuspension() async throws {
        let f = try Fixture(); defer { f.clean() }
        let queue = try MutationOutbox(spaceId: "space", directory: f.root)
        let mutation = Mutation(id: "original", clientId: "phone", kind: .upsert, table: .notes, key: ["note"], row: ["id": .string("note"), "content": .string("draft")], schemaVersion: 245)
        try await queue.enqueue(mutation, title: "Draft")
        try await queue.authorisePending()
        try await queue.markAccepted([mutation.id])
        #expect(try await queue.suspendAuthorisedForRelink() == 1)
        #expect(try await queue.authorisedCount() == 0)
        #expect(try await queue.acceptedWithoutCursor().isEmpty)
        let reopened = try MutationOutbox(spaceId: "space", directory: f.root)
        #expect(try await reopened.items().first?.state == .accepted)
    }
}
