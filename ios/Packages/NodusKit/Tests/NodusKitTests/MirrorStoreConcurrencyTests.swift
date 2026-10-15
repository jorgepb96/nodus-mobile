import Foundation
import GRDB
import Testing
@testable import NodusKit

@Suite("Mirror multi-handle concurrency")
struct MirrorStoreConcurrencyTests {
    private func snapshot(_ title: String) -> SnapshotDownload {
        SnapshotDownload(document: ["tables": .object(["ideas": .array([
            .object(["id": .string("idea"), "title": .string(title)])
        ])])], formatVersion: 2, revision: title, byteCount: title.utf8.count)
    }

    private func heldTransactionConfiguration() -> Configuration {
        var configuration = MirrorStore.databaseConfiguration()
        // The test deliberately keeps a transaction open across two queue accesses.
        configuration.allowsUnsafeTransactions = true
        return configuration
    }

    @Test("concurrent fresh opens and migrations share one complete mirror")
    func concurrentOpen() async throws {
        let folder = try testDatabaseDirectory(prefix: "mirror-open-concurrent")
        defer { try? FileManager.default.removeItem(at: folder) }
        let handles = try await withThrowingTaskGroup(of: MirrorStore.self) { group in
            for _ in 0..<4 { group.addTask { try await MirrorStore.open(spaceId: "space", directory: folder) } }
            var values: [MirrorStore] = []
            for try await value in group { values.append(value) }
            return values
        }
        let first = try #require(handles.first)
        try await first.replace(with: snapshot("shared"), revision: "shared")
        for handle in handles {
            #expect(try await handle.allRows(table: "ideas").first?.string("title") == "shared")
            #expect(try await handle.summary()?.revision == "shared")
        }
        let fileURL = await first.fileURL
        for suffix in ["", "-wal", "-shm"] {
            #expect(BackupPolicy.decision(at: URL(fileURLWithPath: fileURL.path + suffix)) == .excluded)
        }
    }

    @Test("a live reader retains committed rows while a second handle holds an uncommitted writer")
    func readerDuringWrite() async throws {
        let folder = try testDatabaseDirectory(prefix: "mirror-concurrent")
        defer { try? FileManager.default.removeItem(at: folder) }
        let mirror = try MirrorStore(spaceId: "space", directory: folder)
        try await mirror.replace(with: snapshot("committed"), revision: "one")
        let other = try MirrorStore(spaceId: "space", directory: folder)
        let fileURL = await mirror.fileURL
        let writer = try DatabaseQueue(path: fileURL.path, configuration: heldTransactionConfiguration())
        try await writer.writeWithoutTransaction { db in
            #expect(try String.fetchOne(db, sql: "PRAGMA journal_mode") == "wal")
            #expect(try Int.fetchOne(db, sql: "PRAGMA busy_timeout") == 5_000)
            try db.execute(sql: "BEGIN IMMEDIATE")
            try db.execute(sql: "UPDATE rows_json SET body = ? WHERE tbl = 'ideas'", arguments: ["{\"id\":\"idea\",\"title\":\"uncommitted\"}"])
        }
        do {
            // The write transaction remains open throughout both real store reads.
            #expect(try await mirror.allRows(table: "ideas").first?.string("title") == "committed")
            #expect(try await other.allRows(table: "ideas").first?.string("title") == "committed")
            try await writer.writeWithoutTransaction { try $0.execute(sql: "COMMIT") }
        } catch {
            try? await writer.writeWithoutTransaction { try $0.execute(sql: "ROLLBACK") }
            throw error
        }
        #expect(try await mirror.allRows(table: "ideas").first?.string("title") == "uncommitted")
        #expect(try await other.allRows(table: "ideas").first?.string("title") == "uncommitted")
    }

    @Test("an import commits with an existing reader transaction on the previous snapshot")
    func importDuringRead() async throws {
        let folder = try testDatabaseDirectory(prefix: "mirror-import-concurrent")
        defer { try? FileManager.default.removeItem(at: folder) }
        let mirror = try MirrorStore(spaceId: "space", directory: folder)
        try await mirror.replace(with: snapshot("old"), revision: "old")
        let fileURL = await mirror.fileURL
        let reader = try DatabaseQueue(path: fileURL.path, configuration: heldTransactionConfiguration())
        try await reader.writeWithoutTransaction { db in
            try db.execute(sql: "BEGIN DEFERRED")
            #expect(try String.fetchOne(db, sql: "SELECT body FROM rows_json WHERE tbl = 'ideas'")?.contains("old") == true)
        }
        do {
            // Opening another real store runs its migration while this read remains open.
            let reopened = try await MirrorStore.open(spaceId: "space", directory: folder)
            #expect(try await reopened.allRows(table: "ideas").first?.string("title") == "old")
            try await mirror.replace(with: snapshot("new"), revision: "new")
            try await reader.writeWithoutTransaction { db in
                #expect(try String.fetchOne(db, sql: "SELECT body FROM rows_json WHERE tbl = 'ideas'")?.contains("old") == true)
                try db.execute(sql: "COMMIT")
            }
        } catch {
            try? await reader.writeWithoutTransaction { try $0.execute(sql: "ROLLBACK") }
            throw error
        }
        #expect(try await mirror.summary()?.revision == "new")
        #expect(try await mirror.allRows(table: "ideas").first?.string("title") == "new")
    }
}
