import Foundation
import Testing
import NodusKit
@testable import Nodus

@Suite("Packaged offline linked database engine") @MainActor
struct CompanionDatabaseQueryRuntimeTests {
    private func input() -> JSONValue {
        let filter: JSONValue = .object(["type": .string("condition"), "columnId": .string("a-group"), "op": .string("equals"), "value": .string("A")])
        let view: JSONValue = .object(["id": .string("view"), "databaseId": .string("primary"), "revision": .int(1),
            "config": .object(["filter": filter, "sorts": .array([])])])
        func column(_ id: String, _ type: String) -> JSONValue {
            .object(["id": .string(id), "type": .string(type), "config": .object([:]), "options": .array([])])
        }
        func row(_ id: String, _ database: String, _ title: String, _ group: String, _ value: String, _ position: Int64) -> JSONValue {
            .object(["id": .string(id), "databaseId": .string(database), "position": .int(position), "revision": .int(1),
                "createdAt": .string("2026-10-11T10:00:00Z"), "updatedAt": .string("2026-10-11T10:00:00Z"),
                "cells": .object([title: .string("</script><script>throw new Error('data-only')</script>"), group: .string(value)])])
        }
        func source(_ database: String, _ title: String, _ group: String, _ rows: [JSONValue], _ views: [JSONValue]) -> JSONValue {
            .object(["version": .int(1), "vaultId": .string("vault"), "databaseId": .string(database),
                "database": .object(["id": .string(database)]), "revision": .int(1), "localChanges": .bool(true), "localRevision": .string("pending"),
                "columns": .array([column(title, "title"), column(group, "text")]), "views": .array(views),
                "rows": .array(rows), "pages": .object([:]), "dependencies": .object([:])])
        }
        let linked: [JSONValue] = [
            .object(["sourceId": .string("source-a"), "databaseId": .string("primary"), "primary": .bool(true), "revision": .int(1), "alias": .string("Principal"), "propertyMap": .object(["title": .string("a-title"), "text": .string("a-group")])]),
            .object(["sourceId": .string("source-b"), "databaseId": .string("linked"), "primary": .bool(false), "revision": .int(1), "alias": .string("Enlazada"), "propertyMap": .object(["title": .string("b-title"), "text": .string("b-group")])])
        ]
        return .object(["version": .int(1), "vaultId": .string("vault"), "viewId": .string("view"),
            "definition": .object(["viewId": .string("view"), "revision": .int(3), "sources": .array(linked), "properties": .array([])]),
            "sources": .object([
                "primary": source("primary", "a-title", "a-group", [row("edited", "primary", "a-title", "a-group", "B", 0), row("created", "primary", "a-title", "a-group", "A", 1)], [view]),
                "linked": source("linked", "b-title", "b-group", [row("same-id", "linked", "b-title", "b-group", "A", 0)], [])
            ])])
    }

    @Test("The actual bundled WK engine maps sources, filters edits and treats document strings as data")
    func linkedQuery() async throws {
        let result = try await CompanionDatabaseQueryRuntime.query(input())
        let rows = try #require(result.objectValue?["rows"]?.arrayValue)
        #expect(rows.compactMap { $0.objectValue?["id"]?.stringValue } == ["source-a:created", "source-b:same-id"])
        #expect(rows.last?.objectValue?["databaseId"] == .string("linked"))
        #expect(rows.first?.objectValue?["cells"]?.objectValue?["title"] == .string("</script><script>throw new Error('data-only')</script>"))
        #expect(result.objectValue?["revision"]?.stringValue?.hasPrefix("offline:") == true)
    }

    @Test("Missing linked copies and changed configurations fail instead of returning an empty view")
    func incomplete() async throws {
        var value = try #require(input().objectValue)
        var sources = try #require(value["sources"]?.objectValue); sources.removeValue(forKey: "linked")
        value["sources"] = .object(sources)
        await #expect(throws: (any Error).self) { try await CompanionDatabaseQueryRuntime.query(.object(value)) }
        value = try #require(input().objectValue)
        var definition = try #require(value["definition"]?.objectValue); definition["revision"] = .int(4)
        value["definition"] = .object(definition)
        await #expect(throws: (any Error).self) { try await CompanionDatabaseQueryRuntime.query(.object(value)) }
    }
    @Test("The bundled derived engine uses the complete local table and clears stale inspector values")
    func derivedInspector() async throws {
        var source = try #require(input().objectValue?["sources"]?.objectValue?["primary"]?.objectValue)
        var columns = try #require(source["columns"]?.arrayValue)
        columns.append(.object(["id": .string("amount"), "type": .string("number"), "config": .object([:]), "options": .array([])]))
        columns.append(.object(["id": .string("sum"), "type": .string("formula"), "config": .object([
            "formula": .object(["kind": .string("columnStat"), "fn": .string("sum"), "columnId": .string("amount")])]), "options": .array([])]))
        source["columns"] = .array(columns)
        source["rows"] = .array(try #require(source["rows"]?.arrayValue).enumerated().map { index, value in
            var row = value.objectValue!, cells = row["cells"]!.objectValue!
            cells["amount"] = .string(index == 0 ? "12" : "30"); cells["sum"] = .string("old")
            row["cells"] = .object(cells); return .object(row)
        })
        let result = try await CompanionDatabaseQueryRuntime.derived(.object(source))
        #expect(result.objectValue?["rows"]?.arrayValue?.allSatisfy { $0.objectValue?["cells"]?.objectValue?["sum"] == .string("42") } == true)
    }
}
