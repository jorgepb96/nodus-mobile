import Foundation
import NodusKit
import Testing
@testable import Nodus

@Suite("Complete selected page dependency closure") @MainActor
struct CompanionPageDownloadTests {
    private final class Fixture {
        var requests: [String] = []
        var queryReads: [String: Int] = [:]
        var finalChangedPage = false
        var changedQuery = false
        var foreignOwner = false
        var cancelResources = false
        func document(_ id: String) -> JSONValue {
            let dependencies: [JSONValue] = id == "root" ? [.object(["kind": .string("syncedBlock"), "id": .string("shared")])] :
                id == "owner" ? [.object(["kind": .string("linkedDatabase"), "viewId": .string("view")])] :
                [.object(["kind": .string("syncedBlock"), "id": .string("shared")])]
            return .object(["version": .int(1), "vaultId": .string("vault"), "assets": .array([]), "dependencies": .array(dependencies),
                "document": .object(["revision": .int(2), "markdown": .string("Prosa de \(id)"), "blocks": .array([]),
                    "page": .object(["id": .string(id), "rowId": id == "row-page" ? .string("row") : .null,
                        "state": .string("active"), "title": .string(id), "updatedAt": .string("stamp"),
                        "parentPageId": .null, "order": .int(0), "createdAt": .string("stamp"), "revision": .int(4)])])])
        }
        var presentation: JSONValue {
            .object(["version": .int(1), "vaultId": .string("vault"), "databaseId": .string("database"),
                "database": .object(["id": .string("database")]),
                "rows": .array([.object(["id": .string("row"), "databaseId": .string("database")])]),
                "pages": .object(["row": .object(["id": .string("row-page"), "title": .string("row-page"), "updatedAt": .string("stamp")])])])
        }
        func operation(_ method: String, _ args: [JSONValue]) async throws -> JSONValue {
            requests.append(method)
            if method == "getMobilePageDocument", let id = args.first?.stringValue { return document(id) }
            if method == "getMobilePageDocuments" {
                let ids = try #require(args.first?.objectValue?["pageIds"]?.arrayValue).compactMap(\.stringValue)
                var docs = ids.map { document($0) }
                if finalChangedPage && ids.contains("root") {
                    var source = docs[0].objectValue!, body = source["document"]!.objectValue!
                    body["markdown"] = .string("Edited while downloading"); source["document"] = .object(body); docs[0] = .object(source)
                }
                return .object(["version": .int(1), "vaultId": .string("vault"), "totalCount": .int(Int64(ids.count)), "documents": .array(docs), "nextCursor": .null])
            }
            if method == "getMobileSyncedBlockSource" {
                return .object(["version": .int(1), "vaultId": .string(foreignOwner ? "other" : "vault"),
                    "source": .object(["block": .object(["id": .string("shared")]), "page": .object(["id": .string("owner")])])])
            }
            if method == "getMobileLinkedDatabaseRead" {
                let input = try #require(args.first?.objectValue)
                if input["action"] == .string("definition") {
                    return .object(["version": .int(1), "vaultId": .string("vault"), "data": .object([
                        "viewId": .string("view"), "sources": .array([.object(["sourceId": .string("source"), "databaseId": .string("database")])])])])
                }
                let query = try #require(input["input"]?.objectValue)
                let tab = query["sourceId"]?.stringValue ?? "combined", cursor = query["cursor"]?.stringValue
                let start = cursor.flatMap(Int.init) ?? 0, end = min(start + 30, 73)
                if cursor == nil { queryReads[tab, default: 0] += 1 }
                return .object(["version": .int(1), "vaultId": .string("vault"), "data": .object([
                    "revision": .string(changedQuery && queryReads[tab, default: 0] > 1 ? "changed" : "original"), "totalCount": .int(73),
                    "rows": .array((start..<end).map { .object(["id": .string("source:row-\($0)")]) }),
                    "nextCursor": end < 73 ? .string(String(end)) : .null, "hasMore": .bool(end < 73)])])
            }
            throw DesktopBridgeError.malformedResponse
        }
        func capture(maximumBytes: Int = 1_000_000) async throws -> [PrivateBridgeCache.ReadPackRecord] {
            try await CompanionPageDownload.capture(vault: "vault", root: document("root"), existing: [], maximumBytes: maximumBytes, supportsBatch: true,
                operation: { method, args in try await self.operation(method, args) },
                resources: { collection, id, _, catalogue, existing, _ in
                    if self.cancelResources { throw CancellationError() }
                    let key = "fixture-resource:\(collection):\(id)"
                    #expect(!existing.contains(key))
                    if collection == "pages" { #expect(catalogue?.objectValue?["id"] == .string(id)) }
                    return [.init(domain: .corpus, recordId: key, data: Data("retained original \(id)".utf8))]
                }, presentation: { _, _ in
                    .init(domain: .corpus, recordId: CompanionDatabasePresentationSource.key("database"), data: try JSONEncoder.nodus.encode(self.presentation))
                }, database: { _, _ in .object(["database": .object(["id": .string("database")]), "rows": .array([])]) })
        }
    }

    @Test("Synced owners, associated row pages, cyclic dependencies and every linked query page are retained together")
    func complete() async throws {
        let fixture = Fixture(), records = try await fixture.capture()
        #expect(Set(records.map(\.recordId)).count == records.count)
        #expect(records.filter { $0.recordId.hasPrefix("fixture-resource:pages:") }.count == 3)
        for id in ["root", "owner", "row-page"] {
            #expect(records.contains { $0.recordId == (try? CompanionDocumentOutbox.operationKey("getMobilePageDocument", [.string(id)])) })
        }
        #expect(records.contains { $0.recordId == CompanionPageDownload.linkedDatabaseKey })
        #expect(records.contains { $0.recordId == CompanionDatabasePageDownload.key("database") })
        #expect(fixture.queryReads == ["combined": 2, "source": 2])
        #expect(fixture.requests.filter { $0 == "getMobileSyncedBlockSource" }.count == 1)
        #expect(fixture.requests.filter { $0 == "getMobilePageDocuments" }.count == 3)
        #expect(records.reduce(0) { $0 + $1.data.count } <= 1_000_000)
    }
    @Test("Changed page contents and changed linked rows prevent an incoherent copy")
    func changedEpochs() async {
        let page = Fixture(); page.finalChangedPage = true
        await #expect(throws: APIError.self) { try await page.capture() }
        let query = Fixture(); query.changedQuery = true
        await #expect(throws: APIError.self) { try await query.capture() }
    }
    @Test("Another vault, exhausted selected storage and cancellation cannot return a partial success")
    func rejectedCopies() async {
        let foreign = Fixture(); foreign.foreignOwner = true
        await #expect(throws: DesktopBridgeError.self) { try await foreign.capture() }
        let small = Fixture()
        await #expect(throws: PrivateBridgeCache.ReadPackError.self) { try await small.capture(maximumBytes: 100) }
        let cancelled = Fixture(); cancelled.cancelResources = true
        await #expect(throws: CancellationError.self) { try await cancelled.capture() }
    }
}
