import CryptoKit
import Foundation
import Testing
@testable import NodusKit

@Suite("Authored database file chunks") struct CompanionDatabaseAttachmentsTests {
    struct Fixture {
        let id = UUID().uuidString
        let directory: URL
        let keys: KeychainStore
        let cache: PrivateBridgeCache
        init() throws {
            directory = .temporaryDirectory.appendingPathComponent("nodus-db-chunks-" + id)
            keys = KeychainStore(service: "nodus.test.database-files." + id)
            cache = try PrivateBridgeCache(pairingId: id, directory: directory, keychain: keys, readLimitBytes: 0)
        }
        func clean() { try? keys.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)); try? FileManager.default.removeItem(at: directory) }
    }
    actor Server {
        let id: UUID
        let bytes: Data
        var received: [Int: String] = [:]
        var sends: [Int: Int] = [:]
        var drop = true
        var commits = 0
        init(id: UUID, bytes: Data) { self.id = id; self.bytes = bytes }
        func descriptor(result: JSONValue = .null) -> JSONValue {
            .object(["version": .int(1), "id": .string(id.uuidString.lowercased()), "chunkBytes": .int(Int64(CompanionDatabaseAttachments.chunkBytes)), "state": .string(result == .null ? "pending" : "available"), "received": .array(received.sorted { $0.key < $1.key }.map { .object(["index": .int(Int64($0.key)), "sha256": .string($0.value)]) }), "result": result])
        }
        func invoke(_ id: UUID, _ action: String, _ body: JSONValue) throws -> JSONValue {
            #expect(id == self.id)
            if action == "begin" { return descriptor() }
            if action == "chunk" {
                let index = try #require(body.objectValue?["index"]?.intValue)
                let encoded = try #require(body.objectValue?["bytes"]?.stringValue)
                let chunk = try #require(Data(base64Encoded: encoded))
                let offset = index * CompanionDatabaseAttachments.chunkBytes
                #expect(chunk == Data(bytes[offset..<min(bytes.count, offset + CompanionDatabaseAttachments.chunkBytes)]))
                let sha = SHA256.hash(data: chunk).map {String(format: "%02x", $0)}.joined()
                #expect(body.objectValue?["sha256"] == .string(sha))
                sends[index, default: 0] += 1; received[index] = sha
                if drop { drop = false; throw URLError(.networkConnectionLost) }
                return descriptor()
            }
            if action == "commit" {
                commits += 1
                let hash = SHA256.hash(data: bytes).map {String(format: "%02x", $0)}.joined()
                return descriptor(result: .object(["id": .string("datt_" + id.uuidString.lowercased()), "rowId": .string("row"), "columnId": .string("column"), "fileName": .string("original.bin"), "mimeType": .string("application/octet-stream"), "bytes": .int(Int64(bytes.count)), "sha256": .string(hash)]))
            }
            throw DesktopBridgeError.malformedResponse
        }
        func counts() -> ([Int:Int], Int) { (sends, commits) }
    }
    @Test func chunksAreEncryptedAndResumeLostAcknowledgementAfterReopen() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let bytes = Data(repeating: 0x6e, count: CompanionDatabaseAttachments.chunkBytes * 3 + 17), id = UUID()
        let first = CompanionDatabaseAttachments(cache: fixture.cache, vaultId: "vault")
        let imported = try await first.importData(bytes, filename: "original.bin", mimeType: "application/octet-stream", rowId: "row", columnId: "column", expectedRowRevision: 3, expectedColumnRevision: 5, uploadId: id)
        #expect(imported.chunkHashes.count == 4); #expect(imported.importedBytes == Int64(bytes.count))
        for file in try FileManager.default.contentsOfDirectory(at: fixture.directory.appendingPathComponent("bridge-" + fixture.id), includingPropertiesForKeys: nil) where file.pathExtension == "bridgecache" {
            #expect(try Data(contentsOf: file).range(of: Data(repeating: 0x6e, count: 1024)) == nil)
        }
        let server = Server(id: id, bytes: bytes)
        await #expect(throws: URLError.self) { try await first.upload(id, commit: true) { try await server.invoke($0, $1, $2) } }
        let reopened = CompanionDatabaseAttachments(cache: fixture.cache, vaultId: "vault")
        let uploaded = try await reopened.upload(id, commit: true) { try await server.invoke($0, $1, $2) }
        #expect(uploaded.state == "available"); #expect(uploaded.uploadedBytes == Int64(bytes.count))
        let (sends, commits) = await server.counts(); #expect(sends == [0:1, 1:1, 2:1, 3:1]); #expect(commits == 1)
        let exported = try await reopened.export(id)
        #expect(try Data(contentsOf: exported.url) == bytes)
        #expect(try await reopened.all().map(\.id) == [id])
    }
    @Test func changedOriginalAndUnreviewedGrantNeverUpload() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let store = CompanionDatabaseAttachments(cache: fixture.cache, vaultId: "vault"), id = UUID(), bytes = Data("authored original".utf8)
        let transfer = try await store.importData(bytes, filename: "original.bin", mimeType: "application/octet-stream", rowId: "row", columnId: "column", expectedRowRevision: 3, expectedColumnRevision: 5, uploadId: id)
        await #expect(throws: APIError.self) { try await store.importData(Data("changed original!".utf8), filename: "original.bin", mimeType: "application/octet-stream", rowId: "row", columnId: "column", expectedRowRevision: 3, expectedColumnRevision: 5, uploadId: id) }
        var reviewed = transfer; reviewed.recoveryReviewRequired = true
        _ = try await fixture.cache.store(JSONEncoder.nodus.encode(reviewed), vaultId: "vault", domain: .writing, recordId: CompanionDatabaseAttachments.recordId(id))
        await #expect(throws: APIError.self) { try await store.upload(id, commit: true) { _, _, _ in Issue.record("unreviewed transfer reached network"); throw DesktopBridgeError.permissionDenied } }
        let exported = try await store.export(id); #expect(try Data(contentsOf: exported.url) == bytes)
        try await store.approveRecovered(id)
        #expect(try await store.transfer(id)?.recoveryReviewRequired == nil)
    }
    @Test func acknowledgedDeviceCopyCanBeDiscardedWithoutLosingItsReceipt() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let store = CompanionDatabaseAttachments(cache: fixture.cache, vaultId: "vault"), id = UUID()
        let bytes = Data(repeating: 0x42, count: CompanionDatabaseAttachments.chunkBytes + 17)
        _ = try await store.importData(bytes, filename: "original.bin", mimeType: "application/octet-stream", rowId: "row", columnId: "column", expectedRowRevision: 3, expectedColumnRevision: 5, uploadId: id)
        await #expect(throws: DesktopBridgeError.self) { try await store.discardDeviceCopy(id) }
        let server = Server(id: id, bytes: bytes)
        await #expect(throws: URLError.self) { try await store.upload(id, commit: true) { try await server.invoke($0, $1, $2) } }
        _ = try await store.upload(id, commit: true) { try await server.invoke($0, $1, $2) }
        let before = try await fixture.cache.usage()
        try await store.discardDeviceCopy(id)
        let stored = try await store.transfer(id)
        let kept = try #require(stored)
        #expect(kept.state == "discarded"); #expect(kept.discardComplete == true); #expect(kept.result != nil)
        #expect(try await store.all().isEmpty)
        #expect(try await fixture.cache.data(vaultId: "vault", domain: .writing, recordId: CompanionDatabaseAttachments.chunkId(id, 0)) == nil)
        let after = try await fixture.cache.usage(); #expect(after.protectedBytes < before.protectedBytes)
        await #expect(throws: DesktopBridgeError.self) { try await store.importData(bytes, filename: "original.bin", mimeType: "application/octet-stream", rowId: "row", columnId: "column", expectedRowRevision: 3, expectedColumnRevision: 5, uploadId: id) }
        // Explicit re-publication may restore only the exact retained paid bytes.
        let restored = try await store.importData(bytes, filename: "original.bin", mimeType: "application/octet-stream", rowId: "row", columnId: "column", expectedRowRevision: 3, expectedColumnRevision: 5, uploadId: id, allowRestoringDiscarded: true)
        #expect(restored.sha256 == kept.sha256); #expect(restored.state == "ready")
    }

}
