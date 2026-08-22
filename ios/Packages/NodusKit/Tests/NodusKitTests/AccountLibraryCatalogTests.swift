import Foundation
import Testing
@testable import NodusKit

@Suite("Account Library materialized catalogue")
struct AccountLibraryCatalogTests {
    @Test("local CRUD creates immutable history and recoverable tombstones")
    func localHistoryAndRecovery() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try await AccountLibraryCatalog.open(accountId: "owner-a", directory: root)
        var item = AccountLibraryItem(
            metadata: AccountLibraryMetadata(title: "First title", creators: [.init(firstName: "Ada", lastName: "Lovelace")]),
            deviceId: "iphone"
        )
        let first = try await catalog.upsertItem(item, deviceId: "iphone")
        item.metadata.title = "Revised title"
        let second = try await catalog.upsertItem(item, deviceId: "ipad")
        #expect(second.baseVersionId == first.versionId)
        #expect(try await catalog.items().map(\.metadata.title) == ["Revised title"])
        #expect(try await catalog.history(recordId: item.id).count == 2)

        let tombstone = try #require(try await catalog.setDeleted(recordId: item.id, deleted: true, deviceId: "iphone"))
        #expect(tombstone.deleted)
        #expect(try await catalog.items().isEmpty)
        #expect(try await catalog.items(includeDeleted: true).count == 1)
        _ = try await catalog.setDeleted(recordId: item.id, deleted: false, deviceId: "iphone")
        #expect(try await catalog.items().count == 1)
    }

    @Test("accounts never share materialized rows or object paths")
    func accountIsolation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await AccountLibraryCatalog.open(accountId: "one@example.test", directory: root)
        let second = try await AccountLibraryCatalog.open(accountId: "two@example.test", directory: root)
        _ = try await first.upsertItem(AccountLibraryItem(metadata: .init(title: "Private"), deviceId: "mac"), deviceId: "mac")
        #expect(try await first.items().count == 1)
        #expect(try await second.items().isEmpty)

        let bytes = Data("object".utf8)
        let hash = try await first.stageObject(bytes, mime: "text/plain")
        #expect(try await first.objectURL(hash: hash) != nil)
        #expect(try await second.objectURL(hash: hash) == nil)
    }

    private func temporaryDirectory() throws -> URL {
        try testDatabaseDirectory(prefix: "nodus-account-library")
    }
}
