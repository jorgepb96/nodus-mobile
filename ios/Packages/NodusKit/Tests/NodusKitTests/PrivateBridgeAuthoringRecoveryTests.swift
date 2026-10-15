import Foundation
import CryptoKit
import ZIPFoundation
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
    @Test("archive size reads existing encrypted files and deletion respects active leases and other archives")
    func archiveStorageManagement() async throws {
        let f = try Fixture(); defer { f.clean() }
        let pairing = try f.pairing("storage")
        let record = PrivateBridgeAuthoringRecovery.Record(filename: "work-" + String(repeating: "a", count: 64) + ".bridgecache", vaultId: "vault", data: Data("exact authored state".utf8), ledger: false, writing: true, recordId: "draft", generationKind: "mutationOutbox")
        let snapshot = PrivateBridgeAuthoringRecovery.Snapshot(records: [record], fingerprints: [:])
        let first = try await f.recovery.preserve(snapshot: snapshot, pairing: pairing, macDeviceId: "mac")
        let second = try await f.recovery.preserve(snapshot: snapshot, pairing: pairing, macDeviceId: "mac")
        let firstID = try #require(UUID(uuidString: first.archiveURL.deletingPathExtension().lastPathComponent))
        let secondID = try #require(UUID(uuidString: second.archiveURL.deletingPathExtension().lastPathComponent))
        let folder = first.archiveURL.deletingPathExtension().appendingPathExtension("records")
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: folder.deletingLastPathComponent().path).sorted()
        let bytes = try ([first.archiveURL] + FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)).reduce(Int64(0)) { total, url in
            total + Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
        }
        let infos = try await f.recovery.allSummaries()
        #expect(infos.first { $0.id == firstID }?.byteCount == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.deletingLastPathComponent().path).sorted() == filesBefore)
        let originalSecond = try await f.recovery.export(id: secondID)
        let use = try await f.recovery.beginArchiveUse(id: firstID)
        #expect(try await f.recovery.allSummaries().first { $0.id == firstID }?.isBusy == true)
        await #expect(throws: PrivateBridgeAuthoringRecovery.RecoveryError.self) { try await f.recovery.delete(id: firstID) }
        #expect(FileManager.default.fileExists(atPath: folder.path))
        await f.recovery.endArchiveUse(use)
        try await f.recovery.delete(id: firstID)
        #expect(!FileManager.default.fileExists(atPath: first.archiveURL.path))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(f.keychain.value(for: first.recoveryKeyName) == nil)
        #expect(try await f.recovery.export(id: secondID) == originalSecond)
        #expect(try await f.recovery.allSummaries().map(\.id) == [secondID])
        try await f.recovery.discard(second)
        #expect(try await f.recovery.allSummaries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: second.archiveURL.deletingPathExtension().appendingPathExtension("records").path))
    }
    @Test("a confirmed file discard survives interrupted cleanup without orphaning chunks or retaining their bytes")
    func discardedFileCleanup() async throws {
        for discarded in [false, true] {
            let f = try Fixture(); defer { f.clean() }
            let old = try f.pairing("discard-old"), cache = try f.cache(old.id), file = UUID()
            let bytes = Data(repeating: 79, count: CompanionDatabaseAttachments.chunkBytes)
            var transfer = CompanionDatabaseAttachments.Transfer(id: file, vaultId: "vault", rowId: "row", columnId: "column", filename: "discard.bin", mimeType: "application/octet-stream", byteCount: Int64(bytes.count + 17), expectedRowRevision: 1, expectedColumnRevision: 1)
            transfer.state = discarded ? "discarded" : "ready"
            transfer.chunkHashes = [PrivateBridgeAuthoringRecovery.hash(bytes), PrivateBridgeAuthoringRecovery.hash(Data(repeating: 80, count: 17))]
            try await cache.storeAuthoredBatch(vaultId: "vault", records: [
                .init(domain: .writing, recordId: CompanionDatabaseAttachments.indexKey, data: JSONEncoder.nodus.encode(CompanionDatabaseAttachments.Index(vaultId: "vault", ids: [file]))),
                .init(domain: .writing, recordId: CompanionDatabaseAttachments.recordId(file), data: JSONEncoder.nodus.encode(transfer))])
            // Model a process interrupted after deleting the final chunk only.
            try await cache.store(JSONEncoder.nodus.encode(CompanionDatabaseAttachments.Chunk(id: file, index: 0, bytes: bytes.base64EncodedString())), vaultId: "vault", domain: .writing, recordId: CompanionDatabaseAttachments.chunkId(file, 0))
            if !discarded {
                await #expect(throws: PrivateBridgeAuthoringRecovery.RecoveryError.self) { _ = try await cache.authoringRecoverySnapshot(vaultIds: ["vault"]) }
                continue
            }
            try await cache.freezeForRevocation(true)
            let snapshot = try await cache.authoringRecoverySnapshot(vaultIds: ["vault"])
            let tombstone = try #require(snapshot.records.first { $0.generationKind == "discardedDatabaseFileChunk" })
            #expect(tombstone.data.count < 256)
            #expect(tombstone.source == nil)
            #expect(try JSONDecoder.nodus.decode(JSONValue.self, from: tombstone.data).objectValue?["discarded"] == .bool(true))
            let receipt = try await f.recovery.preserve(snapshot: snapshot, pairing: old, macDeviceId: "actual-mac")
            try await cache.retireArchivedVaultRecords(snapshot.records, receipt: receipt)
            let files = try FileManager.default.contentsOfDirectory(at: f.root.appendingPathComponent("bridge-" + old.id), includingPropertiesForKeys: nil)
            #expect(!files.contains { $0.pathExtension == "bridgecache" })
            try await f.recovery.completeRevocation(receipt)
            let fresh = try f.pairing("discard-new"), destination = try f.cache(fresh.id)
            _ = try await f.recovery.adopt(pairing: fresh, macDeviceId: "actual-mac", cache: destination)
            let missing = try await destination.data(vaultId: "vault", domain: .writing, recordId: CompanionDatabaseAttachments.chunkId(file, 0))
            #expect(missing == nil)
            let metadata = try await destination.data(vaultId: "vault", domain: .writing, recordId: CompanionDatabaseAttachments.recordId(file))
            let restored = try JSONDecoder.nodus.decode(CompanionDatabaseAttachments.Transfer.self, from: #require(metadata))
            #expect(restored.state == "discarded")
            try? f.keychain.remove(receipt.recoveryKeyName)
            for id in [old.id, fresh.id] { try? f.keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)) }
        }
    }

    @Test("present chunks still require their exact identity and hash after a confirmed discard")
    func discardedChunksStillValidate() async throws {
        let f = try Fixture(); defer { f.clean() }
        let cache = try f.cache("discard-invalid"), file = UUID(), bytes = Data("original".utf8)
        var transfer = CompanionDatabaseAttachments.Transfer(id: file, vaultId: "vault", rowId: "row", columnId: "column", filename: "original.txt", mimeType: "text/plain", byteCount: Int64(bytes.count), expectedRowRevision: 1, expectedColumnRevision: 1)
        transfer.state = "discarded"; transfer.chunkHashes = [PrivateBridgeAuthoringRecovery.hash(bytes)]
        try await cache.storeAuthoredBatch(vaultId: "vault", records: [
            .init(domain: .writing, recordId: CompanionDatabaseAttachments.indexKey, data: JSONEncoder.nodus.encode(CompanionDatabaseAttachments.Index(vaultId: "vault", ids: [file]))),
            .init(domain: .writing, recordId: CompanionDatabaseAttachments.recordId(file), data: JSONEncoder.nodus.encode(transfer))])
        for corrupt in [CompanionDatabaseAttachments.Chunk(id: UUID(), index: 0, bytes: bytes.base64EncodedString()),
                        CompanionDatabaseAttachments.Chunk(id: file, index: 0, bytes: Data("tampered".utf8).base64EncodedString())] {
            try await cache.store(JSONEncoder.nodus.encode(corrupt), vaultId: "vault", domain: .writing, recordId: CompanionDatabaseAttachments.chunkId(file, 0))
            await #expect(throws: PrivateBridgeAuthoringRecovery.RecoveryError.self) { _ = try await cache.authoringRecoverySnapshot(vaultIds: ["vault"]) }
        }
        try? f.keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: "discard-invalid"))
    }

    @Test("chunked authored files revoke into a lazy v2 archive, export original bytes and relink only for review")
    func chunkedRecoveryV2() async throws {
        let f = try Fixture(); defer { f.clean() }
        let old = try f.pairing("chunk-old"), cache = try f.cache(old.id), file = UUID()
        let content = Data(repeating: 73, count: CompanionDatabaseAttachments.chunkBytes + 17)
        let payloads = [content.prefix(CompanionDatabaseAttachments.chunkBytes), content.suffix(17)].map { Data($0) }
        var transfer = CompanionDatabaseAttachments.Transfer(id: file, vaultId: "vault", rowId: "row", columnId: "column", filename: "authored.bin", mimeType: "application/octet-stream", byteCount: Int64(content.count), expectedRowRevision: 7, expectedColumnRevision: 8)
        transfer.chunkHashes = payloads.map(PrivateBridgeAuthoringRecovery.hash); transfer.sha256 = PrivateBridgeAuthoringRecovery.hash(content); transfer.state = "ready"
        try await cache.storeAuthoredBatch(vaultId: "vault", records: [
            .init(domain: .writing, recordId: CompanionDatabaseAttachments.indexKey, data: JSONEncoder.nodus.encode(CompanionDatabaseAttachments.Index(vaultId: "vault", ids: [file]))),
            .init(domain: .writing, recordId: CompanionDatabaseAttachments.recordId(file), data: JSONEncoder.nodus.encode(transfer))])
        for (index, bytes) in payloads.enumerated() {
            try await cache.store(JSONEncoder.nodus.encode(CompanionDatabaseAttachments.Chunk(id: file, index: index, bytes: bytes.base64EncodedString())), vaultId: "vault", domain: .writing, recordId: CompanionDatabaseAttachments.chunkId(file, index))
        }
        try await cache.freezeForRevocation(true)
        let snapshot = try await cache.authoringRecoverySnapshot(vaultIds: ["vault"])
        let chunks = snapshot.records.filter { $0.generationKind == "databaseFileChunk" }
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.data.isEmpty && $0.source != nil })
        let receipt = try await f.recovery.preserve(snapshot: snapshot, pairing: old, macDeviceId: "actual-mac")
        // The encrypted header has metadata only, independent of total file bytes.
        #expect(try Data(contentsOf: receipt.archiveURL).count < 16_384)
        #expect(try receipt.validates(pairingId: old.id, folder: f.root.appendingPathComponent("bridge-" + old.id)))
        // Validate external data while this receipt is still current, before the
        // final revoked marker deliberately changes its encrypted header digest.
        let archivedChunk = receipt.archiveURL.deletingPathExtension().appendingPathExtension("records").appendingPathComponent(chunks[0].filename)
        let encryptedChunk = try Data(contentsOf: archivedChunk)
        try FileManager.default.removeItem(at: archivedChunk)
        #expect(throws: (any Error).self) { _ = try receipt.validates(pairingId: old.id, folder: f.root.appendingPathComponent("bridge-" + old.id)) }
        try PrivateBridgeProtectedFile.write(encryptedChunk, to: archivedChunk)
        #expect(try receipt.validates(pairingId: old.id, folder: f.root.appendingPathComponent("bridge-" + old.id)))
        try await f.recovery.completeRevocation(receipt)
        let summaries = try await f.recovery.allSummaries(), archive = try #require(summaries.first)
        let lease = try await f.recovery.exportFile(id: archive.id)
        #expect(lease.url.pathExtension == "zip")
        let zip = try ZIPFoundation.Archive(url: lease.url, accessMode: .read, pathEncoding: nil)
        let entry = try #require(zip.first { $0.path.hasSuffix("authored.bin") })
        var exported = Data()
        _ = try zip.extract(entry) { exported.append($0) }
        #expect(exported == content)
        #expect(zip["Nodus-local-work.json"] != nil)
        let fresh = try f.pairing("chunk-new"), destination = try f.cache(fresh.id)
        let adopted = try await f.recovery.adopt(pairing: fresh, macDeviceId: "actual-mac", cache: destination)
        #expect(adopted == 4)
        let files = CompanionDatabaseAttachments(cache: destination, vaultId: "vault")
        let recovered = try await files.transfer(file)
        #expect(recovered?.recoveryReviewRequired == true)
        await #expect(throws: APIError.self) {
            _ = try await files.upload(file, commit: true) { _, _, _ in Issue.record("Recovered files must not send without explicit approval"); return .null }
        }
        for (index, bytes) in payloads.enumerated() {
            let stored = try await destination.data(vaultId: "vault", domain: .writing, recordId: CompanionDatabaseAttachments.chunkId(file, index))
            let value = try JSONDecoder.nodus.decode(CompanionDatabaseAttachments.Chunk.self, from: #require(stored))
            #expect(value.bytes == bytes.base64EncodedString())
        }
        try? f.keychain.remove(receipt.recoveryKeyName)
        for id in [old.id, fresh.id] { try? f.keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)) }
    }

    @Test("version-1 encrypted work archives remain readable and export their exact structured bytes")
    func legacyArchiveCompatibility() async throws {
        let f = try Fixture(); defer { f.clean() }
        let id = UUID(), name = "private-bridge-authoring-recovery-" + id.uuidString
        let keyBytes = Data(repeating: 29, count: 32), key = SymmetricKey(data: keyBytes)
        try f.keychain.set(keyBytes.base64EncodedString(), for: name)
        defer { try? f.keychain.remove(name) }
        let original = Data("original structured legacy manuscript".utf8)
        let record: JSONValue = .object(["filename": .string("work-" + String(repeating: "a", count: 64) + ".bridgecache"), "vaultId": .string("vault"),
            "data": .string(original.base64EncodedString()), "ledger": .bool(false), "writing": .bool(true), "recordId": .string("companion-documents-v1")])
        let document: JSONValue = .object(["version": .int(1), "id": .string(id.uuidString), "sourcePairingId": .string("legacy-grant"),
            "macDeviceId": .string("actual-mac"), "fingerprint": .string(String(repeating: "a", count: 64)), "vaultIds": .array([.string("vault")]),
            "createdAt": .string(Date().ISO8601Format()), "records": .array([record]), "adoptedBy": .object([:]), "revoked": .bool(true)])
        let folder = f.root.appendingPathComponent("archives")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cipher = try #require(try AES.GCM.seal(JSONEncoder.nodus.encode(document), using: key).combined)
        try PrivateBridgeProtectedFile.write(cipher, to: folder.appendingPathComponent(id.uuidString + ".authoring"))
        let result = try await f.recovery.export(id: id)
        let exported = try JSONDecoder.nodus.decode(JSONValue.self, from: result)
        #expect(exported.objectValue?["records"]?.arrayValue?.first?.objectValue?["data"] == .string(original.base64EncodedString()))
        let after = try Data(contentsOf: folder.appendingPathComponent(id.uuidString + ".authoring"))
        #expect(after == cipher)
    }

    @Test("general native outbox work remains globally exportable after revoke without importing old grant receipts")
    func generalMutationWorkExportOnly() async throws {
        let f = try Fixture(); defer { f.clean() }
        let old = try f.pairing("mutation-old"), cache = try f.cache(old.id)
        let original = JSONValue.object(["version": .int(1), "vaultId": .string("vault"), "spaceId": .string("stable-owning-space"),
            "items": .array([.object(["id": .string("original-request"), "state": .string("accepted"), "cursor": .int(17),
                "authorised": .bool(true), "payload": .string("exact original payload and authored comment")])])])
        let bytes = try JSONEncoder.nodus.encode(original)
        try await cache.store(bytes, vaultId: "vault", domain: .writing, recordId: "companion-mutation-outbox-v1")
        try await cache.store(Data("private consulted copy".utf8), vaultId: "vault", domain: .corpus, recordId: "consulted")
        try await cache.freezeForRevocation(true)
        let snapshot = try await cache.authoringRecoverySnapshot(vaultIds: ["vault"])
        #expect(snapshot.records.count == 1)
        #expect(snapshot.records.first?.data == bytes)
        #expect(snapshot.records.first?.generationKind == "mutationOutbox")
        let receipt = try await f.recovery.preserve(snapshot: snapshot, pairing: old, macDeviceId: "actual-mac")
        try await f.recovery.completeRevocation(receipt)
        let archives = try await f.recovery.allSummaries()
        let archive = try #require(archives.first)
        let exported = try await f.recovery.export(id: archive.id)
        let exportJSON = try JSONDecoder.nodus.decode(JSONValue.self, from: exported)
        let record = try #require(exportJSON.objectValue?["records"]?.arrayValue?.first?.objectValue)
        #expect(record["data"] == .string(bytes.base64EncodedString()))
        let fresh = try f.pairing("mutation-new"), destination = try f.cache(fresh.id)
        let count = try await f.recovery.adopt(pairing: fresh, macDeviceId: "actual-mac", cache: destination)
        #expect(count == 0)
        let imported = try await destination.data(vaultId: "vault", domain: .writing, recordId: "companion-mutation-outbox-v1")
        #expect(imported == nil)
        try? f.keychain.remove(receipt.recoveryKeyName)
        for id in [old.id, fresh.id] { try? f.keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)) }
    }

    @Test("exact legacy surface preferences no longer block unlink; unknown editorial versions stay export-only")
    func legacySurfaceStorage() async throws {
        for authored in [false, true] {
            let f = try Fixture(); defer { f.clean() }
            let old = try f.pairing("old", vaults: ["vault", "empty"]), cache = try f.cache("old")
            try f.store.save(old, token: "original-token")
            let editorial = "{\"title\":\"Untouched authored title\",\"contentMarkdown\":\"Full authored manuscript\",\"nativeDocument\":{\"blocks\":[{\"type\":\"paragraph\"}]},\"revision\":7,\"academicMetadata\":{\"kind\":\"article\"},\"style\":{\"fontSize\":14},\"savedAt\":\"2026-10-12T00:00:00Z\"}"
            var entries: [String: JSONValue] = ["nodus.argumentMap.autoFocus": .string("false"), "nodus.graph.detailFontSize": .string("14"), "nodus.graph.detailWidth": .string("360")]
            if authored {
                entries["nodus.editorialDraft.article.doc-original"] = .string(editorial)
                entries["unknown.future.authored"] = .string("Original opaque authored version")
                entries["nodus.graph.detailWidth"] = .string("Unrecognized custom value")
            }
            let bytes = try JSONEncoder.nodus.encode(JSONValue.object(entries))
            try await cache.store(bytes, vaultId: "vault", domain: .writing, recordId: "surface-storage:v1")
            try await cache.store(JSONEncoder.nodus.encode(JSONValue.object([:])), vaultId: "empty", domain: .writing, recordId: "surface-storage:v1")
            try await cache.freezeForRevocation(true)
            let snapshot = try await cache.authoringRecoverySnapshot(vaultIds: old.vaultIds)
            #expect(snapshot.fingerprints.count == 2)
            #expect(snapshot.records.count == (authored ? 1 : 0))
            let receipt = try await f.recovery.preserve(snapshot: snapshot, pairing: old, macDeviceId: "actual-Mac")
            try await cache.freezeForRevocation(false)
            #expect(try await cache.data(vaultId: "vault", domain: .writing, recordId: "surface-storage:v1") == bytes)
            try await cache.freezeForRevocation(true)
            try f.store.revokeLocally(old, authoringRecovery: receipt, cacheDirectory: f.root)
            try await f.recovery.completeRevocation(receipt)
            let fresh = try f.pairing("new", vaults: old.vaultIds), destination = try f.cache("new")
            #expect(try await f.recovery.adopt(pairing: fresh, macDeviceId: "actual-Mac", cache: destination) == 0)
            #expect(try await destination.data(vaultId: "vault", domain: .writing, recordId: "surface-storage:v1") == nil)
            #expect(try await f.recovery.allSummaries().count == (authored ? 1 : 0))
            let archiveId = try #require(UUID(uuidString: receipt.archiveURL.deletingPathExtension().lastPathComponent))
            let export = try JSONDecoder.nodus.decode(JSONValue.self, from: await f.recovery.export(id: archiveId))
            let rows = try #require(export.objectValue?["records"]?.arrayValue)
            if authored {
                let retained = try #require(rows.first?.objectValue?["data"]?.stringValue.flatMap { Data(base64Encoded: $0) })
                let object = try #require(JSONDecoder.nodus.decode(JSONValue.self, from: retained).objectValue)
                #expect(object["nodus.editorialDraft.article.doc-original"] == .string(editorial))
                #expect(object["unknown.future.authored"] == .string("Original opaque authored version"))
                #expect(object["nodus.graph.detailWidth"] == .string("Unrecognized custom value"))
                #expect(object["nodus.argumentMap.autoFocus"] == nil)
                #expect(try Data(contentsOf: receipt.archiveURL).range(of: Data("Full authored manuscript".utf8)) == nil)
            } else { #expect(rows.isEmpty) }
            try? f.keychain.remove(receipt.recoveryKeyName)
            try? f.keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: "new"))
        }
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
