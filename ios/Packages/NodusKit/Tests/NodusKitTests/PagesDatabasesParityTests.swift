import Testing
@testable import NodusKit

@Suite("Pages and Databases parity")
struct PagesDatabasesParityTests {
    @Test("A canonical error remains queryable when its computed value is absent")
    func canonicalComputedError() throws {
        let tables: [String: [Row]] = [
            "db_rows": [row(["id": "r", "database_id": "db"])],
            "db_columns": [row(["id": "formula", "database_id": "db", "name": "Cálculo", "type": "formula", "config_json": #"{"formula":{"kind":"expression","source":"unavailable"}}"#])],
            "db_cells": [row(["id": "cell", "row_id": "r", "column_id": "formula", "error": "Propiedad no disponible", "color": "#115599"])]]
        let item = try #require(PagesDatabasesParity.rows(databaseId: "db", in: tables).first)
        let column = try #require(PagesDatabasesParity.columns(databaseId: "db", in: tables).first)
        #expect(item.formulaErrors["formula"] == "Propiedad no disponible")
        #expect(item.formulaColors["formula"] == "#115599")
        #expect(PagesDatabasesParity.displayValue(column: column, row: item, allRows: [item], columns: [column]) == "Propiedad no disponible")
    }
    @Test("saved layouts select their actual properties instead of the first compatible field")
    func savedPresentationProperties() {
        let columns = PagesDatabasesParity.columns(databaseId: "db", in: ["db_columns": [
            row(["id": "title", "database_id": "db", "name": "Título", "type": "title", "position": 0]),
            row(["id": "hidden", "database_id": "db", "name": "Privada", "type": "text", "position": 1]),
            row(["id": "earlier-date", "database_id": "db", "name": "Creación", "type": "date", "position": 2]),
            row(["id": "chosen-date", "database_id": "db", "name": "Entrega", "type": "date", "position": 3]),
            row(["id": "new-property", "database_id": "db", "name": "Nueva", "type": "text", "position": 4])]])
        let config: [String: JSONValue] = ["properties": .array([
            .object(["columnId": .string("hidden"), "visible": .bool(false), "order": .int(0)]),
            .object(["columnId": .string("chosen-date"), "visible": .bool(true), "order": .int(1)]),
            .object(["columnId": .string("title"), "visible": .bool(true), "order": .int(2)])]),
            "cardPropertyIds": .array([.string("chosen-date"), .string("new-property")]), "dateColumnId": .string("chosen-date")]
        #expect(PagesDatabasesParity.visibleColumns(columns, config: config).map(\.id) == ["chosen-date", "title", "earlier-date", "new-property"])
        #expect(PagesDatabasesParity.cardColumns(columns, config: config).map(\.id) == ["chosen-date", "new-property"])
        #expect(PagesDatabasesParity.layoutColumn(columns, config: config, field: "dateColumnId", types: ["date"])?.id == "chosen-date")
    }
    @Test("page hierarchy is stable and cyclic ancestry remains visible")
    func pageHierarchy() {
        let tables: [String: [Row]] = [
            "pages": [
                row(["id": "root", "title": "Research home", "state": "active", "revision": 2]),
                row(["id": "child", "parent_page_id": "root", "title": "Methods", "state": "active"]),
                row(["id": "cycle-a", "parent_page_id": "cycle-b", "title": "A", "state": "active"]),
                row(["id": "cycle-b", "parent_page_id": "cycle-a", "title": "B", "state": "active"]),
                row(["id": "trash", "title": "Discarded", "state": "trashed"]),
            ],
            "page_favorites": [row(["page_id": "root"])],
        ]
        let pages = PagesDatabasesParity.pages(in: tables)
        #expect(pages.map(\.id) == ["root", "child", "cycle-a", "cycle-b"])
        #expect(pages.first(where: { $0.id == "child" })?.depth == 1)
        #expect(pages.first?.favorite == true)
    }

    @Test("blocks and backlinks use materialized Desktop rows")
    func blocksAndBacklinks() {
        let tables: [String: [Row]] = [
            "pages": [row(["id": "p1"]), row(["id": "p2"])],
            "page_blocks": [
                row(["id": "b2", "page_id": "p1", "sort_order": 2, "type": "quote", "content_json": #"{"text":"Evidence"}"#]),
                row(["id": "b1", "page_id": "p1", "sort_order": 1, "type": "heading_1", "content_json": #"{"text":"Claim"}"#]),
            ],
            "page_links": [row(["id": "link", "source_page_id": "p2", "target_page_id": "p1", "label": "Supports", "kind": "mention"])],
        ]
        #expect(PagesDatabasesParity.blocks(pageId: "p1", in: tables).map(\.text) == ["Claim", "Evidence"])
        #expect(PagesDatabasesParity.backlinks(pageId: "p1", in: tables).first?.sourcePageId == "p2")
    }

    @Test("typed cells, stable query and Desktop formula recipes agree")
    func databaseProjectionAndFormula() {
        let formula = #"{"formula":{"kind":"arithmetic","op":"multiply","operands":[{"kind":"column","columnId":"amount"},{"kind":"number","value":2}]}}"#
        let tables: [String: [Row]] = [
            "db_databases": [row(["id": "db", "short_id": "DB-QA", "name": "Evidence", "position": 0])],
            "db_columns": [
                row(["id": "title", "database_id": "db", "name": "Name", "type": "title", "position": 0]),
                row(["id": "amount", "database_id": "db", "name": "Amount", "type": "number", "position": 1]),
                row(["id": "status", "database_id": "db", "name": "Status", "type": "status", "position": 2]),
                row(["id": "double", "database_id": "db", "name": "Double", "type": "formula", "position": 3, "config_json": formula]),
            ],
            "db_select_options": [row(["id": "done", "column_id": "status", "label": "Complete", "position": 0])],
            "db_rows": [
                row(["id": "r1", "database_id": "db", "position": 0]),
                row(["id": "r2", "database_id": "db", "position": 1]),
            ],
            "db_cells": [
                row(["database_id": "db", "row_id": "r1", "column_id": "title", "value_text": "Gamma"]),
                row(["database_id": "db", "row_id": "r1", "column_id": "amount", "value_number": 12.5]),
                row(["database_id": "db", "row_id": "r1", "column_id": "status", "value_reference": "done"]),
                row(["database_id": "db", "row_id": "r2", "column_id": "title", "value_text": "Alpha"]),
                row(["database_id": "db", "row_id": "r2", "column_id": "amount", "value_number": 4]),
            ],
        ]
        let databases = PagesDatabasesParity.databases(in: tables)
        let columns = PagesDatabasesParity.columns(databaseId: "db", in: tables)
        let rows = PagesDatabasesParity.rows(databaseId: "db", in: tables)
        #expect(databases.first?.rowCount == 2)
        #expect(PagesDatabasesParity.displayValue(column: columns[2], row: rows[0], allRows: rows, columns: columns) == "Complete")
        #expect(PagesDatabasesParity.displayValue(column: columns[3], row: rows[0], allRows: rows, columns: columns) == "25")
        #expect(PagesDatabasesParity.filteredRows(rows, columns: columns, query: "", sortColumnId: "title").map(\.id) == ["r2", "r1"])
    }

    private func row(_ values: [String: Any]) -> Row {
        Row(values.mapValues { value in
            switch value {
            case let value as String: return .string(value)
            case let value as Int: return .int(Int64(value))
            case let value as Double: return .double(value)
            case let value as Bool: return .bool(value)
            default: return .null
            }
        })
    }
}
