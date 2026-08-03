import Foundation
import NodusKit
import Testing
@testable import Nodus

/// What a cell of a database means.
///
/// `db_cells.value_text` is text for every column and says nothing about itself: a select
/// stores an option id, a multi-select a JSON array of them, a checkbox the digit 1. Reading it
/// without the column's type is how a select renders as a UUID and a checkbox as "1" — which is
/// what this screen did, because it also looked the value up under `value`, a column
/// `db_cells` does not have.
@Suite("Database cells")
struct DatabaseCellTests {
    /// The wire shape, decoded rather than hand-built: it pins the response the server sends
    /// as well as the reading of it.
    private func detail(
        columns: [(id: String, type: String)],
        cells: [(row: String, column: String, value: String)],
        options: [(id: String, column: String, label: String, colour: String?)] = [],
        attachments: [(id: String, row: String, column: String, name: String, hash: String?)] = [],
        relations: [(row: String, column: String)] = []
    ) throws -> DatabaseDetail {
        let payload: [String: Any] = [
            "database": ["id": "db-1", "name": "Fototeca"],
            "columns": columns.enumerated().map { ["id": $1.id, "type": $1.type, "name": $1.id, "position": $0] },
            "views": [],
            "options": options.map { ["id": $0.id, "column_id": $0.column, "label": $0.label, "color": $0.colour as Any] },
            "rows": [["id": "r-1", "position": 0]],
            "cells": cells.map { ["row_id": $0.row, "column_id": $0.column, "value_text": $0.value] },
            "relations": relations.map { ["id": "\($0.row)-\($0.column)", "row_id": $0.row, "column_id": $0.column] },
            "attachments": attachments.map {
                ["id": $0.id, "row_id": $0.row, "column_id": $0.column, "file_name": $0.name, "hash": $0.hash as Any, "position": 0]
            },
            "total": 1, "limit": 50, "offset": 0, "hasMore": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(DatabaseDetail.self, from: data)
    }

    private func column(_ id: String, _ type: String) -> Row {
        Row(["id": .string(id), "type": .string(type), "name": .string(id)])
    }

    @Test("a select shows its option's label, never the id stored in the cell")
    func selectResolvesItsOption() throws {
        let detail = try detail(
            columns: [("c-1", "select")],
            cells: [("r-1", "c-1", "opt-a")],
            options: [("opt-a", "c-1", "Retrato", "#b30333")]
        )
        let context = DatabaseCell.Context(detail: detail, rowId: "r-1")
        guard case .options(let options) = DatabaseCell.value(of: column("c-1", "select"), in: context) else {
            Issue.record("a select should decode to options")
            return
        }
        #expect(options.map(\.label) == ["Retrato"])
        #expect(options.first?.colour == "#b30333")
    }

    /// The desktop drops option ids with no option behind them on read. Showing the raw id
    /// instead would be showing a UUID and calling it a value.
    @Test("an option id with nothing behind it is dropped, not printed")
    func unknownOptionIsDropped() throws {
        let detail = try detail(
            columns: [("c-1", "multi_select")],
            cells: [("r-1", "c-1", #"["opt-a","opt-gone"]"#)],
            options: [("opt-a", "c-1", "Calle", nil)]
        )
        let context = DatabaseCell.Context(detail: detail, rowId: "r-1")
        guard case .options(let options) = DatabaseCell.value(of: column("c-1", "multi_select"), in: context) else {
            Issue.record("a multi-select should decode to options")
            return
        }
        #expect(options.map(\.label) == ["Calle"])
    }

    @Test("a checkbox is a state, not the digit it is stored as")
    func checkboxDecodes() throws {
        let detail = try detail(
            columns: [("c-on", "checkbox"), ("c-off", "checkbox")],
            cells: [("r-1", "c-on", "1"), ("r-1", "c-off", "0")]
        )
        let context = DatabaseCell.Context(detail: detail, rowId: "r-1")
        guard
            case .checkbox(let on) = DatabaseCell.value(of: column("c-on", "checkbox"), in: context),
            case .checkbox(let off) = DatabaseCell.value(of: column("c-off", "checkbox"), in: context)
        else {
            Issue.record("a checkbox should decode to a boolean")
            return
        }
        #expect(on)
        #expect(!off)
    }

    /// The three cases an attachment column has to tell apart, because only one of them is a
    /// picture: an image whose bytes travelled, a file whose bytes did not, and no file at all.
    @Test("an attachment says whether there is an image to show")
    func attachmentsDistinguishImagesFromFiles() throws {
        let detail = try detail(
            columns: [("c-file", "attachment"), ("c-none", "attachment")],
            cells: [],
            attachments: [
                ("att-1", "r-1", "c-file", "plaza.png", "abc123"),
                ("att-2", "r-1", "c-file", "expediente.pdf", nil),
            ]
        )
        let context = DatabaseCell.Context(detail: detail, rowId: "r-1")
        guard case .files(let files) = DatabaseCell.value(of: column("c-file", "attachment"), in: context) else {
            Issue.record("an attachment column with files should decode to files")
            return
        }
        #expect(files.count == 2)
        #expect(DatabaseCell.imageHash(files[0]) == "abc123")
        #expect(DatabaseCell.imageHash(files[1]) == nil, "a PDF has no image to fetch")

        if case .empty = DatabaseCell.value(of: column("c-none", "attachment"), in: context) {} else {
            Issue.record("a column with no file at all is empty")
        }
    }

    @Test("a relation cell counts what it points at")
    func relationsAreCounted() throws {
        let detail = try detail(
            columns: [("c-rel", "relation")],
            cells: [],
            relations: [("r-1", "c-rel")]
        )
        let context = DatabaseCell.Context(detail: detail, rowId: "r-1")
        guard case .relations(let count) = DatabaseCell.value(of: column("c-rel", "relation"), in: context) else {
            Issue.record("a relation column should decode to a count")
            return
        }
        #expect(count == 1)
    }

    /// A column type this build has never heard of — a later migration's — reads as text,
    /// exactly as `columnTypeDef` falls back to text on the desktop.
    @Test("an unknown column type is read as text rather than dropped")
    func unknownTypeFallsBackToText() throws {
        let detail = try detail(columns: [("c-x", "something_new")], cells: [("r-1", "c-x", "un valor")])
        let context = DatabaseCell.Context(detail: detail, rowId: "r-1")
        guard case .text(let value) = DatabaseCell.value(of: column("c-x", "something_new"), in: context) else {
            Issue.record("an unknown type should read as text")
            return
        }
        #expect(value == "un valor")
    }
}
