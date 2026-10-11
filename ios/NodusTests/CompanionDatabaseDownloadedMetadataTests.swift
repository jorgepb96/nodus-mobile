import Foundation
import Testing
import NodusKit
@testable import Nodus

@Suite("Downloaded native linked row inspector")
struct CompanionDatabaseDownloadedMetadataTests {
    @Test("Materialized formulas replace stale cells without losing plain values or another row")
    func computedCells() throws {
        func cell(_ row: String, _ column: String, _ text: String) -> JSONValue { .object(["row_id": .string(row), "column_id": .string(column), "value_text": .string(text)]) }
        let payload: JSONValue = .object(["database": .object(["id": .string("db")]), "cells": .array([cell("row", "sum", "old"), cell("row", "plain", "draft"), cell("other", "sum", "leave")])])
        let source: JSONValue = .object(["databaseId": .string("db"), "columns": .array([.object(["id": .string("sum"), "type": .string("formula")]), .object(["id": .string("plain"), "type": .string("text")])]),
            "rows": .array([.object(["id": .string("row"), "databaseId": .string("db"), "cells": .object(["sum": .string("42"), "plain": .string("draft")])])])])
        let result = try CompanionDatabaseDownloadedMetadata.calculatedRow(payload: payload, source: source, rowId: "row")
        let cells = try #require(result.objectValue?["cells"]?.arrayValue)
        #expect(cells.count == 3); #expect(cells.contains(cell("row", "plain", "draft"))); #expect(cells.contains(cell("other", "sum", "leave")))
        #expect(cells.last?.objectValue?["value_text"] == .string("42")); #expect(cells.last?.objectValue?["database_id"] == .string("db"))
        #expect(throws: DesktopBridgeError.self) { try CompanionDatabaseDownloadedMetadata.calculatedRow(payload: payload, source: source, rowId: "missing") }
    }
}
