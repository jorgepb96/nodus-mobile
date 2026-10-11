import Foundation
import Testing
@testable import NodusKit

@Suite("Durable scoped manuscript drafts")
struct CompanionManuscriptDraftStoreTests {
    @Test("A reopened encrypted draft survives a zero read-cache limit and stays in its own vault")
    func reopening() async throws {
        let id = UUID().uuidString, root = URL.temporaryDirectory.appendingPathComponent("manuscript-draft-\(id)")
        let keychain = KeychainStore(service: "nodus.tests.manuscript.\(id)")
        defer { try? FileManager.default.removeItem(at: root); try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)) }
        let cache = try PrivateBridgeCache(pairingId: id, directory: root, keychain: keychain, readLimitBytes: 0)
        let store = try CompanionManuscriptDraftStore(cache: cache, vaultId: "vault")
        let draft = CompanionManuscriptDraftStore.Draft(sceneId: "scene", baseline: "Texto inicial", text: "Borrador propio sin enviar")
        try await store.set(draft)
        let bytes = try #require(try await cache.data(vaultId: "vault", domain: .writing, recordId: CompanionManuscriptDraftStore.storageKey))
        let reopened = try CompanionManuscriptDraftStore(cache: cache, vaultId: "vault", data: bytes)
        #expect(await reopened.records()["scene"] == draft)
        #expect(try await cache.data(vaultId: "other", domain: .writing, recordId: CompanionManuscriptDraftStore.storageKey) == nil)
        #expect(draft.conflicts(with: "Texto cambiado en el Mac"))
        #expect(!draft.conflicts(with: draft.baseline)); #expect(!draft.conflicts(with: draft.text))
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let file as URL in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            #expect((try Data(contentsOf: file)).range(of: Data(draft.text.utf8)) == nil)
        }
    }
    @Test("A delayed earlier update cannot overwrite newer authored text")
    func ordering() async throws {
        let id = UUID().uuidString, root = URL.temporaryDirectory.appendingPathComponent("manuscript-order-\(id)")
        let keychain = KeychainStore(service: "nodus.tests.manuscript.order.\(id)")
        defer { try? FileManager.default.removeItem(at: root); try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)) }
        let cache = try PrivateBridgeCache(pairingId: id, directory: root, keychain: keychain, readLimitBytes: 0)
        let store = try CompanionManuscriptDraftStore(cache: cache, vaultId: "vault")
        let old = CompanionManuscriptDraftStore.Draft(sceneId: "scene", baseline: "Original", text: "Primero", updatedAt: Date(timeIntervalSince1970: 1))
        let newer = CompanionManuscriptDraftStore.Draft(sceneId: "scene", baseline: "Original", text: "Último texto", updatedAt: Date(timeIntervalSince1970: 2))
        async let first: Void = store.set(old)
        async let second: Void = store.set(newer)
        _ = try await (first, second)
        try await store.set(old)
        let bytes = try #require(try await cache.data(vaultId: "vault", domain: .writing, recordId: CompanionManuscriptDraftStore.storageKey))
        let reopened = try CompanionManuscriptDraftStore(cache: cache, vaultId: "vault", data: bytes)
        #expect(await reopened.records()["scene"] == newer)
    }
}
