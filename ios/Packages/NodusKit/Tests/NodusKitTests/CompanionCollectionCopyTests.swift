import Foundation
import Testing
@testable import NodusKit

@Suite("Selected public collection dossiers")
struct CompanionCollectionCopyTests {
    @Test("native selected readers filter entity kinds before paging and preserve complete linked context")
    func nativeDomainReaders() throws {
        let entries: [JSONValue] = (0..<603).map { index in
            let kind = index.isMultiple(of: 2) ? "culture" : "faction"
            let row: JSONValue = .object(["group_id": .string("group-\(index)"), "kind": .string(kind), "name": .string("Grupo \(index)")])
            return .object(["summary": row, "detail": .object(["group": row,
                "members": .array([.object(["person_id": .string("linked-only"), "display_name": .string("Persona contextual")])]),
                "futureSection": .object(["note": .string("Contexto completo")])])])
        }
        let copy = try CompanionCollectionCopy(path: "world-groups", copies: [.object(["version": .int(1), "path": .string("world-groups"), "entries": .array(entries)])])
        let page = copy.page(matching: ["kind": .string("faction")], limit: 200, offset: 200)
        #expect(page.fromDevice); #expect(page.total == 301); #expect(page.items.count == 101); #expect(!page.hasMore)
        #expect(page.items.first?.string("group_id") == "group-401")
        #expect(page.items.allSatisfy { $0.string("kind") == "faction" })
        let dossier = try copy.dossier(id: "group-601")
        #expect(dossier.fromDevice)
        #expect(dossier.sections["futureSection"]?.objectValue?["note"] == .string("Contexto completo"))
        #expect(dossier.sections["members"]?.arrayValue?.first?.objectValue?["person_id"] == .string("linked-only"))
        #expect(throws: CompanionCollectionCopy.CopyError.self) { try copy.dossier(id: "linked-only") }
        #expect(copy.page(matching: ["kind": .string("missing")]).total == 0)
        #expect(copy.page(offset: 1000).items.isEmpty)
    }

    static func questions(count: Int = 241) -> JSONValue {
        .object(["version": .int(1), "path": .string("study-questions"), "entries": .array((0..<count).map { index in
            let row: JSONValue = .object(["id": .string("question-\(index)"), "prompt": .string("Pregunta \(index)"),
                "answer": .string(index == count - 1 ? "Texto con 37 datos y %_ literales" : "Respuesta guardada"),
                "notes": .string("Otra columna")])
            return .object(["summary": row, "detail": .object(["question": row,
                "versions": .array([.object(["id": .string("version-\(index)"), "question_id": .string("question-\(index)"), "answer": .string("Historial íntegro")])])])])
        })])
    }
    @Test("new searches and pages use only chosen dossiers and keep full versions")
    func completeCatalogue() throws {
        let copy = try CompanionCollectionCopy(path: "study-questions", copies: [Self.questions()])
        let page = try #require(copy.nativeResponse(path: "study-questions", query: [.init(name: "limit", value: "200"), .init(name: "offset", value: "200")], percentEncoded: false))
        let value = try JSONDecoder.nodus.decode(JSONValue.self, from: page.data).objectValue!
        #expect(value["questions"]?.arrayValue?.count == 41); #expect(value["total"] == .int(241)); #expect(value["hasMore"] == .bool(false))
        let search = try #require(copy.nativeResponse(path: "study-questions", query: [.init(name: "q", value: "  %_ LITERALES  ")], percentEncoded: false))
        #expect(try JSONDecoder.nodus.decode(JSONValue.self, from: search.data).objectValue?["total"] == .int(1))
        let noCrossColumn = try #require(copy.nativeResponse(path: "study-questions", query: [.init(name: "q", value: "guardada Otra")], percentEncoded: false))
        #expect(try JSONDecoder.nodus.decode(JSONValue.self, from: noCrossColumn.data).objectValue?["total"] == .int(0), "A phrase across different columns does not match the server contract")
        let detail = try #require(copy.nativeResponse(path: "study-questions/question-240", query: [], percentEncoded: false))
        #expect(try JSONDecoder.nodus.decode(JSONValue.self, from: detail.data).objectValue?["versions"]?.arrayValue?.first?.objectValue?["answer"] == .string("Historial íntegro"))
        #expect(throws: CompanionCollectionCopy.CopyError.self) { try copy.nativeResponse(path: "study-questions/unselected", query: [], percentEncoded: false) }
        #expect(try copy.nativeResponse(path: "study-questions", query: [.init(name: "surface", value: "unsupported")], percentEncoded: false) == nil)
        #expect(try copy.nativeResponse(path: "study-questions/question-240/relations", query: [], percentEncoded: false) == nil)
    }

    @Test("newer complete dossiers own removed versions and encoded identities remain exact")
    func overridesAndIds() throws {
        let id = "source/a#b%2F"
        let row: JSONValue = .object(["item_id": .string(id), "title": .string("Fuente elegida")])
        func copy(_ excerpts: [JSONValue]) -> JSONValue {
            .object(["version": .int(1), "path": .string("archive-items"), "entries": .array([
                .object(["summary": row, "detail": .object(["item": row, "excerpts": .array(excerpts)])])])])
        }
        let selected = try CompanionCollectionCopy(path: "archive-items", copies: [copy([]), copy([.object(["excerpt_id": .string("removed")])])])
        let response = try #require(selected.nativeResponse(path: "archive-items/source%2Fa%23b%252F", query: [], percentEncoded: true))
        let detail = try JSONDecoder.nodus.decode(JSONValue.self, from: response.data).objectValue!
        #expect(detail["item"]?.objectValue?["item_id"] == .string(id)); #expect(detail["excerpts"] == .array([]))
        #expect(throws: DesktopBridgeError.self) { try CompanionCollectionCopy(path: "archive-units", copies: [copy([])]) }
    }

    @Test("every database page retains its own cells, relations and attachments beyond row 200")
    func databasePages() throws {
        let rows: [JSONValue] = (0..<503).map { .object(["id": .string("row-\($0)"), "database_id": .string("db"), "position": .int(Int64($0))]) }
        let cells: [JSONValue] = rows.map { .object(["row_id": $0.objectValue!["id"]!, "column_id": .string("column"), "value_text": .string("37 · íntegro")]) }
        let relation: JSONValue = .object(["row_id": .string("row-502"), "related_row_id": .string("other-table-row"), "column_id": .string("relation")])
        let attachment: JSONValue = .object(["row_id": .string("row-502"), "id": .string("file"), "name": .string("fuente.pdf")])
        let primary: JSONValue = .object(["id": .string("db"), "name": .string("Base elegida")])
        var detail: [String: JSONValue] = ["database": primary, "columns": .array([.object(["id": .string("column"), "database_id": .string("db")])]),
            "views": .array([]), "options": .array([]), "rows": .array(rows), "cells": .array(cells), "relations": .array([relation]), "attachments": .array([attachment]),
            "total": .int(503), "offset": .int(0), "limit": .int(503), "hasMore": .bool(false)]
        func source() -> JSONValue { .object(["version": .int(1), "path": .string("databases"), "entries": .array([.object(["summary": primary, "detail": .object(detail)])])]) }
        let copy = try CompanionCollectionCopy(path: "databases", copies: [source()])
        let page = try #require(copy.nativeResponse(path: "databases/db", query: [.init(name: "offset", value: "500"), .init(name: "limit", value: "200")], percentEncoded: false))
        let decoded = try JSONDecoder.nodus.decode(DatabaseDetail.self, from: page.data)
        #expect(decoded.rows.map { $0.string("id") } == ["row-500", "row-501", "row-502"])
        #expect(decoded.total == 503); #expect(decoded.cells.count == 3); #expect(!decoded.hasMore)
        #expect(decoded.cells.allSatisfy { $0.string("value_text") == "37 · íntegro" }); #expect(decoded.relations.count == 1); #expect(decoded.attachments.count == 1)
        detail["rows"] = .array(Array(rows.prefix(200)))
        #expect(throws: DesktopBridgeError.self) { try CompanionCollectionCopy(path: "databases", copies: [source()]) }
        detail["rows"] = .array(rows); detail["cells"] = .array(cells + [.object(["row_id": .string("foreign-row")])])
        #expect(throws: DesktopBridgeError.self) { try CompanionCollectionCopy(path: "databases", copies: [source()]) }
    }
}
