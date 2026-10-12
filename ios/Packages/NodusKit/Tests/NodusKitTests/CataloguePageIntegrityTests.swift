import Foundation
import Testing
@testable import NodusKit

struct CataloguePageIntegrityTests {
    @Test func malformedEnvelopeNeverBecomesEmptyCatalogue() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = NodusClient(address: ServerAddress(trusted: "https://catalogue.example"), cache: ResponseCache(directory: directory))
        let valid: [String: JSONValue] = ["entries": .array([]), "total": .int(0), "limit": .int(60), "offset": .int(0), "hasMore": .bool(false), "revision": .string("published")]
        for field in ["total", "limit", "offset", "hasMore", "revision"] {
            var missing = valid; missing.removeValue(forKey: field)
            let response = NodusClient.Response(data: try JSONEncoder.nodus.encode(missing), status: 200, headers: [:], fromCache: false)
            await #expect(throws: TransportError.self) { try await client.page(from: response, key: "entries") }
        }
        var wrongType = valid; wrongType["hasMore"] = .string("false")
        let response = NodusClient.Response(data: try JSONEncoder.nodus.encode(wrongType), status: 200, headers: [:], fromCache: false)
        await #expect(throws: TransportError.self) { try await client.page(from: response, key: "entries") }
        let revalidated = NodusClient.Response(data: try JSONEncoder.nodus.encode(valid), status: 200, headers: [:], fromCache: true)
        let page = try await client.page(from: revalidated, key: "entries")
        #expect(page.items.isEmpty)
        #expect(!page.fromDevice, "An online HTTP 304 is not a selected offline download")
    }

    @Test func prematureEndAndBrokenPageBoundsAreErrors() async {
        await #expect(throws: PageTraversalError.self) {
            try await PageTraversal.all { offset in Page(items: [offset], total: 300, limit: 60, offset: offset, hasMore: false, revision: "a") }
        }
        for page in [Page(items: [1, 2], total: 2, limit: 1, offset: 0, hasMore: false, revision: "a"),
                     Page(items: [1], total: 1, limit: 0, offset: 0, hasMore: false, revision: "a"),
                     Page(items: [1], total: 1, limit: 1, offset: 0, hasMore: false, revision: "")] {
            #expect(throws: PageTraversalError.self) { try CataloguePageIntegrity.validate(page) }
        }
        // Canonical server supports an offset past the end without inventing records.
        let empty = Page<Int>(items: [], total: 2, limit: 60, offset: 400, hasMore: false, revision: "a")
        #expect(throws: Never.self) { try CataloguePageIntegrity.validate(empty) }
    }

    @Test func incrementalPagesRejectWrongOffsetDuplicatesChangedTotalAndMixedSources() {
        let previous = Page(items: [Row(["id": .string("a")])], total: 3, limit: 60, offset: 0, hasMore: true, revision: "a")
        for next in [Page(items: [Row(["id": .string("a")])], total: 3, limit: 60, offset: 1, hasMore: true, revision: "a"),
                     Page(items: [Row(["id": .string("b")])], total: 3, limit: 60, offset: 0, hasMore: true, revision: "a"),
                     Page(items: [Row(["id": .string("b")])], total: 4, limit: 60, offset: 1, hasMore: true, revision: "a"),
                     Page(items: [Row(["id": .string("b")])], total: 3, limit: 60, offset: 1, hasMore: true, revision: "a", fromDevice: true)] {
            #expect(throws: PageTraversalError.self) { try CataloguePageIntegrity.validateRows(next, idField: "id", offset: 1, previous: previous) }
        }
    }

    @Test func completeCatalogueCannotRepeatAnIdentityAcrossPages() async {
        await #expect(throws: PageTraversalError.self) {
            try await PageTraversal.complete(identity: { $0.text("id") }) { offset in
                Page(items: [Row(["id": .string("same")])], total: 3, limit: 1, offset: offset, hasMore: offset < 2, revision: "a")
            }
        }
    }
}
