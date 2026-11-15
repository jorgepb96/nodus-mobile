import Foundation
import Testing
@testable import NodusKit

@Suite("Bounded private archival sources")
struct ArchivePrivateSourceTests {
    private func copy(_ id: String = "chosen") throws -> CompanionPrivateSourceCopy {
        let reference = try PrivateCorpusReference(kind: .archive, id: id)
        var rows = Dictionary(uniqueKeysWithValues: reference.kind.groups.map { ($0, [Row]()) })
        rows["textVersions"] = [Row(["_bridge_cursor": .int(1), "item_id": .string(id), "text_version_id": .string("version"), "content": .string("Actual saved version body")])]
        rows["segments"] = [Row(["_bridge_cursor": .int(1), "text_version_id": .string("version"), "content": .string("Actual source segment")])]
        rows["excerpts"] = (1...201).map { Row(["_bridge_cursor": .int($0), "item_id": .string(id), "excerpt_id": .string("excerpt-\($0)"), "quoted_text": .string("Literal quotation \($0)"), "locator_display": .string("folio \($0)")]) }
        let payload: JSONValue = .object(["version": .int(1), "kind": .string(reference.kind.rawValue), "id": .string(id),
            "root": .object(["item_id": .string(id), "title": .string("Chosen source"), "original_available": .int(1)]),
            "revision": .string(String(repeating: "a", count: 64)), "groups": .array(reference.kind.groups.map { key in
                .object(["key": .string(key), "title": .string(key), "total": .int(Int64(rows[key]?.count ?? 0)), "revision": .string(String(repeating: "b", count: 64))]) })])
        let source = try JSONDecoder.nodus.decode(PrivateCorpusSource.self, from: JSONEncoder.nodus.encode(payload))
        return try CompanionPrivateSourceCopy(source: source, rows: rows, reference: reference)
    }
    @Test func sourceAndExcerptReferencesKeepOwningSourceAndGrant() throws {
        let reference = try #require(PrivateCorpusReference(URL(string: "nodus://primary-source/source%2Fa/excerpt/excerpt%252F37")!))
        #expect(reference.kind == .archive)
        #expect(reference.kind.domain == .primarySourceFiles)
        #expect(reference.id == "source/a")
        #expect(reference.annotationId == "excerpt%2F37")
        #expect(reference.publishedCollectionPath == "archive-excerpts")
        #expect(reference.publishedRecordId == "excerpt%2F37")
        let root = try PrivateCorpusReference(kind: .archive, id: "source/a")
        #expect(root.publishedCollectionPath == "archive-items")
        #expect(root.publishedRecordId == "source/a")
        #expect(try reference.path(vaultId: "vault").hasSuffix("archive-source/source%2Fa"))
        #expect(try PrivateCorpusReference.collectionReference(path: "archive-items", id: "source/a")?.kind == .archive)
        #expect(PrivateCorpusReference(URL(string: "nodus://primary-source/source/extra")!) == nil)
        #expect(PrivateCorpusReference(URL(string: "nodus://primary-source/%2E%2E")!) == nil)
    }
    @Test func selectedTextContainsAllOwnedVersionsSegmentsAndExcerpts() throws {
        let source = try copy()
        let material = try #require(PrivateCorpusSourceMaterial.selected(copy: source).first)
        #expect(material.string("citation") == "nodus://primary-source/chosen")
        #expect(material.string("domain") == "primary-source-files")
        #expect(material.string("contentScope") == "record")
        #expect(material.text("text")?.contains("Actual saved version body") == true)
        #expect(material.text("text")?.contains("Actual source segment") == true)
        #expect(material.text("text")?.contains("Literal quotation 201") == true)
        var rows = source.rows
        rows["excerpts"]?[0].columns["item_id"] = .string("unselected-neighbour")
        let poisoned = try CompanionPrivateSourceCopy(source: source.source, rows: rows, reference: .init(kind: .archive, id: "chosen"))
        #expect(throws: DesktopBridgeError.self) { try PrivateCorpusSourceMaterial.selected(copy: poisoned) }
    }
    @Test func archivedSourceNeedsItsOwnExplicitDownloadInCurrentVaultAndDomain() async throws {
        let source = try copy(), reference = try PrivateCorpusReference(kind: .archive, id: "chosen")
        let id = UUID().uuidString, directory = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let keychain = KeychainStore(service: "nodus.tests.archive-source.\(id)")
        defer { try? FileManager.default.removeItem(at: directory); try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)) }
        let cache = try PrivateBridgeCache(pairingId: id, directory: directory, keychain: keychain, readLimitBytes: 500_000)
        let bytes = try JSONEncoder.nodus.encode(source)
        try await cache.store(bytes, vaultId: "vault", domain: .primarySourceFiles, recordId: reference.recordKey)
        #expect(try await CompanionPrivateSourceCopy.downloaded(cache: cache, vaultId: "vault", reference: reference) == nil)
        let pack = try await cache.saveReadPack(vaultId: "vault", title: "Chosen archival source", expiresAt: .distantFuture,
            records: [.init(domain: .primarySourceFiles, recordId: reference.recordKey, data: bytes)])
        #expect(try await CompanionPrivateSourceCopy.downloaded(cache: cache, vaultId: "vault", reference: reference)?.rows["excerpts"]?.count == 201)
        #expect(try await CompanionPrivateSourceCopy.downloaded(cache: cache, vaultId: "other-vault", reference: reference) == nil)
        #expect(try await CompanionPrivateSourceCopy.downloaded(cache: cache, vaultId: "vault", reference: .init(kind: .archive, id: "neighbour")) == nil)
        try await cache.removeReadPack(id: pack.id, vaultId: "vault")
        #expect(try await CompanionPrivateSourceCopy.downloaded(cache: cache, vaultId: "vault", reference: reference) == nil)
    }
}
