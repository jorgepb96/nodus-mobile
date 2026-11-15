import Foundation
import Testing
@testable import NodusKit

@Suite("Citable specialised device sources")
struct CorpusSourceMaterialTests {
    private func copy(_ path: String, id: String = "source/37", fields: [String: JSONValue] = [:], relations: [String: JSONValue] = [:]) throws -> CompanionCollectionCopy {
        let collection = try #require(Collections[path])
        let row = JSONValue.object(fields.merging([collection.idField: .string(id)], uniquingKeysWith: { _, right in right }))
        return try CompanionCollectionCopy(path: path, copies: [.object(["version": .int(1), "path": .string(path),
            "entries": .array([.object(["summary": row, "detail": .object(relations.merging([collection.detailKey: row], uniquingKeysWith: { _, right in right }))])])])])
    }
    @Test("full scene manuscripts stay with their chosen owner; linked scenes are never sources")
    func sceneOwner() throws {
        let literal = "Manuscrito sobre fotografía · " + String(repeating: "37 datos sin recortar. ", count: 1000)
        let scene = try copy("world-scenes", fields: ["title": .string("Escena de fotografía")], relations: [
            "text": .object(["scene_id": .string("source/37"), "content_markdown": .string(literal)]),
            "scenes": .array([.object(["scene_id": .string("neighbour"), "title": .string("Fotografía de otro vecino")])])])
        let source = try CompanionSelectedContext(collections: [scene])
        let response = try source.response(body: .object(["query": .string("fotografía"), "include": .array([.string("sources")]), "budget": .int(120_000)]))
        let package = try JSONDecoder.nodus.decode(ContextPackage.self, from: response.data)
        #expect(package.sections.first?.kind == "sources"); #expect(package.stats.matched == 1)
        let material = try CorpusSourceMaterial(row: #require(package.sections.first?.items.first))
        #expect(material.citation == "nodus://world/scene/source%2F37"); #expect(material.text.contains(literal))
        #expect(!material.text.contains("otro vecino"))
    }
    @Test("primary-source quotations retain their parent; material metadata never claims to be the original")
    func sourceDepth() throws {
        let excerpt = try copy("archive-excerpts", fields: ["item_id": .string("parent/37"), "quoted_text": .string("Cita literal íntegra · fotografía"), "locator_display": .string("p.37")])
        let row = try #require(CorpusSourceMaterial.selected(copy: excerpt).first)
        #expect(row.string("citation") == "nodus://primary-source/parent%2F37/excerpt/source%2F37")
        #expect(row.text("text")?.contains("Cita literal íntegra") == true)
        let metadata = try copy("study-materials", fields: ["title": .string("Fotografía"), "description": .string("Descripción, sin PDF descargado")])
        let material = try #require(CorpusSourceMaterial.selected(copy: metadata).first)
        #expect(material.string("contentScope") == "metadata"); #expect(material.text("text")?.contains("no contiene su documento original") == true)
        var wrong = row; wrong.columns["citation"] = .string("nodus://primary-source/other/excerpt/source%2F37")
        #expect(throws: DesktopBridgeError.self) { try CorpusSourceMaterial(row: wrong) }
        wrong = row; wrong.columns["collection"] = .string("prosopography-private")
        #expect(throws: DesktopBridgeError.self) { try CorpusSourceMaterial(row: wrong) }
    }
    @Test("encoded source identities agree with Desktop and fresh unrelated questions do not reuse old material")
    func identitiesAndFreshQueries() throws {
        let document = try copy("study-docs", id: "doc%2F37", fields: ["title": .string("Fotografía"), "content": .string("Texto completo con 37 datos")])
        let selected = try CompanionSelectedContext(collections: [document])
        let row = try #require(CorpusSourceMaterial.selected(copy: document).first)
        #expect(row.string("citation") == "nodus://study/doc/doc%252F37")
        let response = try selected.response(body: .object(["query": .string("neurología sin relación"), "include": .array([.string("sources")])]))
        let package = try JSONDecoder.nodus.decode(ContextPackage.self, from: response.data)
        #expect(package.sections.isEmpty); #expect(package.sourceScope == "device_downloads")
        #expect(!CorpusSourceMaterial.paths.contains("study-recordings")); #expect(!CorpusSourceMaterial.paths.contains("prosopography-public-search"))
    }
}
