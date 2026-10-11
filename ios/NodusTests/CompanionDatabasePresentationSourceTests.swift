import Foundation
import Testing
import NodusKit
@testable import Nodus

@Suite("Complete selected database presentations") @MainActor
struct CompanionDatabasePresentationSourceTests {
    private var metadata: JSONValue { .object(["database": .object(["id": .string("database")]), "columns": .array([]), "views": .array([]), "revision": .int(7)]) }
    private func wrapper(_ action: String, _ data: JSONValue, vault: String = "vault") -> JSONValue {
        .object(["version": .int(1), "vaultId": .string(vault), "databaseId": .string("database"), "action": .string(action), "data": data])
    }
    private func page(_ start: Int, revision: Int64 = 7) -> JSONValue {
        let end = min(start + 200, 452)
        return .object(["rows": .array((start..<end).map { .object(["id": .string("row-\($0)"), "databaseId": .string("database"), "cells": .object([:])]) }),
            "pages": .object(["row-\(start)": .object(["id": .string("page-\(start)"), "updatedAt": .string("2026-10-11")])]),
            "dependencies": .object(["row-\(start)": .object(["dependency": .array([.string("actual-target")])])]),
            "revision": .int(revision), "queryHash": .string("same-query"), "totalCount": .int(452),
            "hasMore": .bool(end < 452), "nextCursor": end < 452 ? .string("cursor-\(end)") : .null])
    }
    @Test("All pages, activity dates and real targets survive the selected capture")
    func complete() async throws {
        var reads = 0
        let source = try await CompanionDatabasePresentationSource.capture(vault: "vault", database: "database", maximumBytes: 1_000_000) { method, args in
            #expect(method == "getMobileDatabasePresentationRead"); reads += 1
            let action = args[0].objectValue?["action"]?.stringValue ?? ""
            if action == "metadata" { return wrapper(action, metadata) }
            let cursor = args[0].objectValue?["input"]?.objectValue?["cursor"]?.stringValue
            return wrapper(action, page(cursor.flatMap { Int($0.replacingOccurrences(of: "cursor-", with: "")) } ?? 0))
        }
        #expect(reads == 6); #expect(source.objectValue?["rows"]?.arrayValue?.count == 452)
        #expect(source.objectValue?["pages"]?.objectValue?.count == 3)
        #expect(source.objectValue?["dependencies"]?.objectValue?["row-400"]?.objectValue?["dependency"] == .array([.string("actual-target")]))
    }
    @Test("Another vault, changed epoch and an incomplete budget do not create a copy")
    func refused() async {
        await #expect(throws: DesktopBridgeError.self) {
            try await CompanionDatabasePresentationSource.capture(vault: "vault", database: "database", maximumBytes: 1_000_000) { _, _ in wrapper("metadata", metadata, vault: "other") }
        }
        var pages = 0
        await #expect(throws: DesktopBridgeError.self) {
            try await CompanionDatabasePresentationSource.capture(vault: "vault", database: "database", maximumBytes: 1_000_000) { _, args in
                let action = args[0].objectValue?["action"]?.stringValue ?? ""
                if action == "metadata" { return wrapper(action, metadata) }
                pages += 1; return wrapper(action, page((pages - 1) * 200, revision: pages == 1 ? 7 : 8))
            }
        }
        await #expect(throws: PrivateBridgeCache.ReadPackError.self) {
            try await CompanionDatabasePresentationSource.capture(vault: "vault", database: "database", maximumBytes: 1) { _, args in
                let action = args[0].objectValue?["action"]?.stringValue ?? ""
                return wrapper(action, action == "metadata" ? metadata : page(0))
            }
        }
    }
}
