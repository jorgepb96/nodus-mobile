import CryptoKit
import Foundation
import Testing
@testable import NodusKit

@Suite("Atomic authored generation summaries")
struct IndexedGenerationTransactionTests {
    @Test("authored batches survive interrupted file replacement and reject reading copies without changing work")
    func authoredFileBatch() async throws {
        let grant = UUID().uuidString, root = URL.temporaryDirectory.appendingPathComponent("authored-batch-" + grant)
        let keychain = KeychainStore(service: "authored-batch-" + grant)
        defer { try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: grant)); try? FileManager.default.removeItem(at: root) }
        let cache = try PrivateBridgeCache(pairingId: grant, directory: root, keychain: keychain)
        let manifest = Data("original manifest".utf8), chunk = Data("original authored chunk".utf8)
        try await cache.storeAuthoredBatch(vaultId: "vault", records: [
            .init(domain: .writing, recordId: "manifest", data: manifest), .init(domain: .writing, recordId: "chunk", data: chunk)])
        let folder = root.appendingPathComponent("bridge-" + grant)
        let encoded = try #require(keychain.value(for: KeychainStore.desktopBridgeCacheKey(pairingId: grant)))
        let key = SymmetricKey(data: try #require(Data(base64Encoded: encoded)))
        func filename(_ id: String) -> String { "work-" + PrivateBridgeAuthoringRecovery.hash(Data("vault\u{1f}\(DesktopBridgeDomain.writing.rawValue)\u{1f}\(id)".utf8)) + ".bridgecache" }
        let nextManifest = Data("new exact manifest".utf8), nextChunk = Data("new exact authored chunk".utf8)
        let staged = folder.appendingPathComponent("indexed-" + UUID().uuidString + ".transaction")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
        var hashes: [String: String] = [:]
        for (id, bytes) in [("manifest", nextManifest), ("chunk", nextChunk)] {
            let encrypted = try #require(try AES.GCM.seal(bytes, using: key).combined), name = filename(id)
            try PrivateBridgeProtectedFile.write(encrypted, to: staged.appendingPathComponent(name))
            hashes[name] = PrivateBridgeAuthoringRecovery.hash(encrypted)
        }
        try PrivateBridgeProtectedFile.write(JSONEncoder.nodus.encode(JSONValue.object(["files": .object(hashes.mapValues(JSONValue.string))])), to: staged.appendingPathComponent("commit.json"))
        try PrivateBridgeProtectedFile.write(Data(contentsOf: staged.appendingPathComponent(filename("chunk"))), to: folder.appendingPathComponent(filename("chunk")))
        let reopened = try PrivateBridgeCache(pairingId: grant, directory: root, keychain: keychain)
        #expect(try await reopened.data(vaultId: "vault", domain: .writing, recordId: "manifest") == nextManifest)
        #expect(try await reopened.data(vaultId: "vault", domain: .writing, recordId: "chunk") == nextChunk)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        await #expect(throws: DesktopBridgeError.self) {
            try await reopened.storeAuthoredBatch(vaultId: "vault", records: [
                .init(domain: .writing, recordId: "manifest", data: manifest), .init(domain: .corpus, recordId: "private reading", data: chunk)])
        }
        #expect(try await reopened.data(vaultId: "vault", domain: .writing, recordId: "manifest") == nextManifest)
        #expect(try await reopened.data(vaultId: "vault", domain: .corpus, recordId: "private reading") == nil)
    }

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
    @Test("visual-only summaries commit with their actual parent, reject bodies, and remain review-only after relink")
    func documentVisualSummary() async throws {
        let f = try PrivateBridgeAuthoringRecoveryTests.Fixture(); defer { f.clean() }
        let old = try f.pairing("visual-summary-old"), cache = try f.cache(old.id), session = UUID(), target = UUID().uuidString.lowercased()
        let entity = "deep-research:" + target, index = "autonomous:documentVisuals:index:v1", summaryId = "autonomous:documentVisuals:summary:" + entity
        let record = try CompanionGenerationPublication.recordId(kind: "documentVisuals", entity: entity)
        let scope: JSONValue = .object(["kind": .string("deep-research"), "id": .string(target)])
        var parent: [String: JSONValue] = ["version": .int(1), "kind": .string("documentVisuals"), "id": .string(session.uuidString.lowercased()), "entityKey": .string(entity), "target": scope, "manifest": .null,
            "state": .string("running"), "source": .object(["vaultId": .string("vault"), "draft": .object(["title": .string("Existing report"), "draftMarkdown": .string(String(repeating: "private authored text", count: 10_000))]), "origin": .string("desktop-capture"), "contentHash": .string(String(repeating: "a", count: 64))])]
        var header: [String: JSONValue] = ["kind": .string("documentVisuals"), "id": parent["id"]!, "entityKey": .string(entity), "target": scope, "state": .string("running"),
            "source": .object(["title": .string("Existing report"), "origin": .string("desktop-capture"), "contentHash": .string(String(repeating: "a", count: 64))])]
        let oldData = try JSONEncoder.nodus.encode(JSONValue.object(parent)), oldHeader = try JSONEncoder.nodus.encode(JSONValue.object(header))
        try await cache.storeIndexedGeneration(oldData, vaultId: "vault", recordId: record, indexId: index, entity: entity, summary: .init(recordId: summaryId, data: oldHeader))
        #expect(oldHeader.count < 1_024 && oldData.count > 100_000)
        var invalid = header; invalid["calls"] = .object(["body": .string("must not enter polling metadata")])
        let invalidData = try JSONEncoder.nodus.encode(JSONValue.object(invalid))
        await #expect(throws: DesktopBridgeError.self) { try await cache.storeIndexedGeneration(oldData, vaultId: "vault", recordId: record, indexId: index, entity: entity, summary: .init(recordId: summaryId, data: invalidData)) }
        invalid = header; invalid["id"] = .string(UUID().uuidString)
        let wrongIdentity = try JSONEncoder.nodus.encode(JSONValue.object(invalid))
        await #expect(throws: DesktopBridgeError.self) { try await cache.storeIndexedGeneration(oldData, vaultId: "vault", recordId: record, indexId: index, entity: entity, summary: .init(recordId: summaryId, data: wrongIdentity)) }
        #expect(try await cache.data(vaultId: "vault", domain: .researchGeneration, recordId: summaryId) == oldHeader)
        parent["state"] = .string("failed"); parent["error"] = .string("Actual interrupted snapshot")
        header["state"] = parent["state"]; header["error"] = parent["error"]
        let next = try JSONEncoder.nodus.encode(JSONValue.object(parent)), nextHeader = try JSONEncoder.nodus.encode(JSONValue.object(header))
        // Model termination after replacing just the checkpoint, leaving the old
        // summary. Reopening must complete the same three-file durable commit.
        let folder = f.root.appendingPathComponent("bridge-" + old.id)
        let encodedKey = try #require(f.keychain.value(for: KeychainStore.desktopBridgeCacheKey(pairingId: old.id)))
        let key = SymmetricKey(data: try #require(Data(base64Encoded: encodedKey)))
        func filename(_ id: String) -> String { "work-" + PrivateBridgeAuthoringRecovery.hash(Data("vault\u{1f}\(DesktopBridgeDomain.researchGeneration.rawValue)\u{1f}\(id)".utf8)) + ".bridgecache" }
        let staged = folder.appendingPathComponent("indexed-" + UUID().uuidString + ".transaction")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
        var hashes: [String: String] = [:]
        for (id, bytes) in [(index, try JSONEncoder.nodus.encode([entity])), (record, next), (summaryId, nextHeader)] {
            let encrypted = try #require(try AES.GCM.seal(bytes, using: key).combined), name = filename(id)
            try PrivateBridgeProtectedFile.write(encrypted, to: staged.appendingPathComponent(name)); hashes[name] = PrivateBridgeAuthoringRecovery.hash(encrypted)
        }
        try PrivateBridgeProtectedFile.write(JSONEncoder.nodus.encode(JSONValue.object(["files": .object(hashes.mapValues(JSONValue.string))])), to: staged.appendingPathComponent("commit.json"))
        try PrivateBridgeProtectedFile.write(Data(contentsOf: staged.appendingPathComponent(filename(record))), to: folder.appendingPathComponent(filename(record)))
        let reopened = try f.cache(old.id)
        #expect(try await reopened.data(vaultId: "vault", domain: .researchGeneration, recordId: summaryId) == nextHeader)
        #expect(try await reopened.data(vaultId: "vault", domain: .researchGeneration, recordId: record) == next)
        let snapshot = try await reopened.authoringRecoverySnapshot(vaultIds: ["vault"])
        #expect(snapshot.records.first { $0.recordId == summaryId }?.generationKind == "documentVisualsSummary")
        let saved = try await f.recovery.preserve(snapshot: snapshot, pairing: old, macDeviceId: "real-mac")
        try await f.recovery.completeRevocation(saved)
        let fresh = try f.pairing("visual-summary-new"), destination = try f.cache(fresh.id)
        _ = try await f.recovery.adopt(pairing: fresh, macDeviceId: "real-mac", cache: destination)
        let restoredData = try #require(await destination.data(vaultId: "vault", domain: .researchGeneration, recordId: summaryId))
        #expect(try JSONDecoder.nodus.decode(JSONValue.self, from: restoredData).objectValue?["recoveryReviewRequired"] == .bool(true))
        let ledgerData = try #require(await destination.data(vaultId: "vault", domain: .researchGeneration, recordId: "job-ledger-v1"))
        let ledger = try JSONDecoder.nodus.decode([String: DesktopJobLedger.Request].self, from: ledgerData)
        #expect(ledger.count == 1 && ledger.values.first?.method == "localDocumentVisuals" && ledger.values.first?.args.isEmpty == true)
        // A restored summary and checkpoint still form one valid authored scope.
        _ = try await destination.authoringRecoverySnapshot(vaultIds: ["vault"])
        for id in [old.id, fresh.id] { try? f.keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)) }; try? f.keychain.remove(saved.recoveryKeyName)
    }

}
