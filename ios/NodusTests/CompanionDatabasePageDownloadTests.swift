import Foundation
import Testing
import NodusKit
@testable import Nodus

@Suite("Selected database row documents") @MainActor
struct CompanionDatabasePageDownloadTests {
    private func presentation(_ count: Int = 3) -> JSONValue {
        .object(["version": .int(1), "vaultId": .string("vault"), "databaseId": .string("database"), "database": .object(["id": .string("database")]),
            "rows": .array((0..<count).map { .object(["id": .string("row-\($0)"), "databaseId": .string("database")]) }),
            "pages": .object(Dictionary(uniqueKeysWithValues: (0..<count).map { ("row-\($0)", .object(["id": .string("page-\($0)"), "title": .string("Título \($0)"), "updatedAt": .string("stamp")])) }))])
    }
    private func document(_ id: String, vault: String = "vault", row: String? = nil, stamp: String = "stamp") -> JSONValue {
        let index = id.replacingOccurrences(of: "page-", with: "")
        return .object(["version": .int(1), "vaultId": .string(vault), "document": .object([
            "revision": .int(2), "markdown": .string("Documento \(index)"), "blocks": .array([]),
            "page": .object(["id": .string(id), "rowId": .string(row ?? "row-\(index)"), "state": .string("active"), "title": .string("Título \(index)"),
                "updatedAt": .string(stamp), "parentPageId": .string("parent"), "coverBlobHash": .string(String(repeating: "a", count: 64)), "revision": .int(4)])]),
            "dependencies": .array([]), "assets": .array([])])
    }
    private func linked(_ id: String, vault: String = "vault", title: String = "Linked") throws -> PrivateBridgeCache.ReadPackRecord {
        .init(domain: .corpus, recordId: CompanionPageDownload.linkedDatabaseKey, data: try JSONEncoder.nodus.encode(JSONValue.object([
            "version": .int(1), "vaultId": .string(vault), "databases": .object([id: .object(["database": .object(["id": .string(id), "name": .string(title)])])])
        ])))
    }
    @Test("All row pages retain their documents, covers, raw owners and shared linked dependencies")
    func complete() async throws {
        var visited: [String] = []
        let result = try await CompanionDatabasePageDownload.capture(vault: "vault", presentation: presentation(), existing: [], maximumBytes: 1_000_000,
            fetch: { id in visited.append(id); return document(id) }, dependencies: { source, _, _ in
                let id = try #require(source.objectValue?["document"]?.objectValue?["page"]?.objectValue?["id"]?.stringValue)
                return [try linked("db-\(id)")]
            })
        #expect(visited == ["page-0", "page-1", "page-2", "page-0", "page-1", "page-2"])
        #expect(result.filter { $0.recordId.hasPrefix("operation:") }.count == 3)
        let metadata = try #require(result.first { $0.recordId == CompanionDatabasePageDownload.key("database") })
        let pages = try #require(JSONDecoder.nodus.decode(JSONValue.self, from: metadata.data).objectValue?["pages"]?.arrayValue)
        #expect(pages.count == 3); #expect(pages.first?.objectValue?["row_id"] == .string("row-0"))
        #expect(pages.first?.objectValue?["cover_blob_hash"] == .string(String(repeating: "a", count: 64)))
        #expect(pages.first?.objectValue?["parent_page_id"] == .string("parent")); #expect(pages.first?.objectValue?["revision"] == .int(4))
        let dependency = try #require(result.first { $0.recordId == CompanionPageDownload.linkedDatabaseKey })
        #expect(try JSONDecoder.nodus.decode(JSONValue.self, from: dependency.data).objectValue?["databases"]?.objectValue?.count == 3)
        #expect(result.reduce(0) { $0 + $1.data.count } <= 1_000_000)
    }

    @Test("523 associated documents use bounded batches and verify the complete captured content again")
    func batchedPages() async throws {
        var requests = 0
        func read(_ ids: [String]) async throws -> [String: JSONValue] {
            try await CompanionPageReadBatch.read(vault: "vault", pageIds: ids, maximumBytes: 1_000_000) { input in
                requests += 1
                let ids = input.objectValue!["pageIds"]!.arrayValue!.map { $0.stringValue! }, offset = input.objectValue!["cursor"]!.intValue!
                let end = min(offset + 20, ids.count)
                return .object(["version": .int(1), "vaultId": .string("vault"), "totalCount": .int(Int64(ids.count)),
                    "documents": .array(ids[offset..<end].map { document($0) }), "nextCursor": end < ids.count ? .int(Int64(end)) : .null])
            }
        }
        let result = try await CompanionDatabasePageDownload.capture(vault: "vault", presentation: presentation(523), existing: [], maximumBytes: 1_000_000,
            batch: read, fetch: { _ in throw DesktopBridgeError.malformedResponse }, dependencies: { _, _, _ in [] })
        #expect(requests == 54)
        #expect(result.filter { $0.recordId.hasPrefix("operation:") }.count == 523)
        var round = 0
        await #expect(throws: APIError.self) {
            try await CompanionDatabasePageDownload.capture(vault: "vault", presentation: presentation(1), existing: [], maximumBytes: 1_000_000,
                batch: { ids in
                    round += 1; var source = document(ids[0]).objectValue!, body = source["document"]!.objectValue!
                    if round == 2 { body["markdown"] = .string("Changed structured document at the same page title") }
                    source["document"] = .object(body); return [ids[0]: .object(source)]
                }, fetch: { _ in throw DesktopBridgeError.malformedResponse }, dependencies: { _, _, _ in [] })
        }
    }

    @Test("Batch cursors, order, scope and read budget are validated before retaining sources")
    func invalidBatch() async {
        for kind in ["cursor", "order", "vault", "empty", "count"] {
            await #expect(throws: DesktopBridgeError.self) {
                try await CompanionPageReadBatch.read(vault: "vault", pageIds: ["page-0", "page-1"], maximumBytes: 1_000_000) { _ in
                    .object(["version": .int(1), "vaultId": .string(kind == "vault" ? "other" : "vault"),
                        "totalCount": .int(kind == "count" ? 1 : 2),
                        "documents": .array(kind == "empty" ? [] : [document(kind == "order" ? "page-1" : "page-0")]),
                        "nextCursor": .int(kind == "cursor" ? 0 : 1)])
                }
            }
        }
        await #expect(throws: PrivateBridgeCache.ReadPackError.self) {
            try await CompanionPageReadBatch.read(vault: "vault", pageIds: ["page-0"], maximumBytes: 1) { _ in
                .object(["version": .int(1), "vaultId": .string("vault"), "totalCount": .int(1), "documents": .array([document("page-0")]), "nextCursor": .null])
            }
        }
    }
    @Test("Changed pages, foreign vaults and wrong row owners never commit an incomplete copy")
    func rejectedPages() async {
        await #expect(throws: APIError.self) {
            try await CompanionDatabasePageDownload.capture(vault: "vault", presentation: presentation(1), existing: [], maximumBytes: 1_000_000,
                fetch: { document($0, stamp: "changed") }, dependencies: { _, _, _ in [] })
        }
        for foreign in [true, false] {
            await #expect(throws: DesktopBridgeError.self) {
                try await CompanionDatabasePageDownload.capture(vault: "vault", presentation: presentation(1), existing: [], maximumBytes: 1_000_000,
                    fetch: { document($0, vault: foreign ? "other" : "vault", row: foreign ? nil : "wrong-row") }, dependencies: { _, _, _ in [] })
            }
        }
        var source = presentation(1).objectValue!
        source["rows"] = .array([.object(["id": .string("row-0"), "databaseId": .string("foreign")])])
        await #expect(throws: DesktopBridgeError.self) {
            try await CompanionDatabasePageDownload.capture(vault: "vault", presentation: .object(source), existing: [], maximumBytes: 1_000_000,
                fetch: { document($0) }, dependencies: { _, _, _ in [] })
        }
    }
    @Test("Duplicate page identities and size overflow stop the atomic capture")
    func budgetAndDuplicate() async {
        await #expect(throws: PrivateBridgeCache.ReadPackError.self) {
            try await CompanionDatabasePageDownload.capture(vault: "vault", presentation: presentation(1), existing: [], maximumBytes: 1,
                fetch: { document($0) }, dependencies: { _, _, _ in [] })
        }
        var source = presentation(2).objectValue!, pages = source["pages"]!.objectValue!
        pages["row-1"] = pages["row-0"]; source["pages"] = .object(pages)
        await #expect(throws: DesktopBridgeError.self) {
            try await CompanionDatabasePageDownload.capture(vault: "vault", presentation: .object(source), existing: [], maximumBytes: 1_000_000,
                fetch: { document($0) }, dependencies: { _, _, _ in [] })
        }
    }
    @Test("A shared envelope merges exact dossiers and rejects mixed epochs or foreign scopes")
    func dependencyEpoch() throws {
        var records: [PrivateBridgeCache.ReadPackRecord] = [], bytes = 0
        try CompanionReadPackRecords.merge(linked("first"), into: &records, vault: "vault", bytes: &bytes, maximumBytes: 1_000_000)
        try CompanionReadPackRecords.merge(linked("second"), into: &records, vault: "vault", bytes: &bytes, maximumBytes: 1_000_000)
        #expect(records.count == 1); #expect(bytes == records[0].data.count)
        #expect(throws: APIError.self) { try CompanionReadPackRecords.merge(linked("first", title: "Changed"), into: &records, vault: "vault", bytes: &bytes, maximumBytes: 1_000_000) }
        #expect(throws: DesktopBridgeError.self) { try CompanionReadPackRecords.merge(linked("third", vault: "other"), into: &records, vault: "vault", bytes: &bytes, maximumBytes: 1_000_000) }
        #expect(records.count == 1); #expect(bytes == records[0].data.count)
    }
}
