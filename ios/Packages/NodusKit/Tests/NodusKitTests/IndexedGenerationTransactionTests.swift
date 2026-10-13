import CryptoKit
import Foundation
import Testing
@testable import NodusKit

@Suite("Atomic authored generation summaries")
struct IndexedGenerationTransactionTests {
    @Test("A committed interrupted replacement recovers the exact checkpoint, index and summary")
    func interruptedCommit() async throws {
        let grant = UUID().uuidString, root = URL.temporaryDirectory.appendingPathComponent("indexed-summary-" + grant)
        let keychain = KeychainStore(service: "indexed-summary-" + grant)
        defer { try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: grant)); try? FileManager.default.removeItem(at: root) }
        let cache = try PrivateBridgeCache(pairingId: grant, directory: root, keychain: keychain)
        let entity = "entity", index = "autonomous:deepResearch:index:v1", summary = "autonomous:deepResearch:summary:" + entity
        let record = try CompanionGenerationPublication.recordId(kind: "deepResearch", entity: entity)
        let checkpoint: JSONValue = .object(["id": .string(UUID().uuidString), "entityKey": .string(entity), "request": .object(["query": .string("Authored question")]), "report": .object(["draftMarkdown": .string("Complete paid result")])])
        try await cache.storeIndexedGeneration(JSONEncoder.nodus.encode(checkpoint), vaultId: "vault", recordId: record, indexId: index, entity: entity,
            summary: .init(recordId: summary, data: JSONEncoder.nodus.encode(JSONValue.object(["title": .string("Old summary")]))))
        let folder = root.appendingPathComponent("bridge-" + grant)
        let encodedKey = try #require(keychain.value(for: KeychainStore.desktopBridgeCacheKey(pairingId: grant)))
        let key = SymmetricKey(data: try #require(Data(base64Encoded: encodedKey)))
        // Derive actual naming from the domain value, without depending on its spelling.
        func actualFilename(_ recordId: String) -> String { "work-" + PrivateBridgeAuthoringRecovery.hash(Data("vault\u{1f}\(DesktopBridgeDomain.researchGeneration.rawValue)\u{1f}\(recordId)".utf8)) + ".bridgecache" }
        let next: JSONValue = .object(["id": .string(UUID().uuidString), "entityKey": .string(entity), "request": .object([:]), "report": .object(["draftMarkdown": .string("New complete paid result")])])
        let nextData = try JSONEncoder.nodus.encode(next)
        let header = try JSONEncoder.nodus.encode(JSONValue.object(["title": .string("New exact summary")]))
        let staged = folder.appendingPathComponent("indexed-" + UUID().uuidString + ".transaction")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
        var hashes: [String: String] = [:]
        for (id, data) in [(index, try JSONEncoder.nodus.encode([entity])), (record, try JSONEncoder.nodus.encode(next)), (summary, header)] {
            let encrypted = try #require(try AES.GCM.seal(data, using: key).combined), name = actualFilename(id)
            try PrivateBridgeProtectedFile.write(encrypted, to: staged.appendingPathComponent(name)); hashes[name] = PrivateBridgeAuthoringRecovery.hash(encrypted)
        }
        try PrivateBridgeProtectedFile.write(JSONEncoder.nodus.encode(JSONValue.object(["files": .object(hashes.mapValues(JSONValue.string))])), to: staged.appendingPathComponent("commit.json"))
        // Model a process dying after only the checkpoint destination was replaced.
        try PrivateBridgeProtectedFile.write(Data(contentsOf: staged.appendingPathComponent(actualFilename(record))), to: folder.appendingPathComponent(actualFilename(record)))
        let reopened = try PrivateBridgeCache(pairingId: grant, directory: root, keychain: keychain)
        #expect(try await reopened.data(vaultId: "vault", domain: .researchGeneration, recordId: summary) == header)
        #expect(try await reopened.data(vaultId: "vault", domain: .researchGeneration, recordId: record) == nextData)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        let snapshot = try await reopened.authoringRecoverySnapshot(vaultIds: ["vault"])
        #expect(snapshot.records.first { $0.recordId == summary }?.generationKind == "deepResearchSummary")
        #expect(snapshot.records.first { $0.recordId == record }?.data == nextData)
        await #expect(throws: DesktopBridgeError.self) {
            try await reopened.storeIndexedGeneration(JSONEncoder.nodus.encode(next), vaultId: "vault", recordId: record, indexId: index, entity: entity,
                summary: .init(recordId: "autonomous:deepResearch:summary:another", data: header))
        }
        #expect(try await reopened.data(vaultId: "vault", domain: .researchGeneration, recordId: summary) == header)
    }
}
