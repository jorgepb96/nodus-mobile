import Foundation
import Testing
@testable import NodusKit

@Suite("Research over chosen device material")
struct CompanionSelectedContextTests {
    static func passages(count: Int = 253, lastText: String? = nil) throws -> CompanionCollectionCopy {
        let entries: [JSONValue] = (0..<count).map { index in
            let text = index == count - 1 ? lastText ?? "La fotografía conserva 37 huellas de propaganda: testimonio literal final." : "Fotografía y propaganda: testimonio literal \(index)."
            let row: JSONValue = .object(["passage_id": .string("passage-\(index)"), "nodus_id": .string("work"), "text": .string(text), "page_label": .string("\(index)")])
            return .object(["summary": row, "detail": .object(["passage": row])])
        }
        return try CompanionCollectionCopy(path: "passages", copies: [.object(["version": .int(1), "path": .string("passages"), "entries": .array(entries)])])
    }

    @Test("fresh questions search all chosen source rows and expose exact literal text and restricted scope")
    func freshQuestion() throws {
        let source = try CompanionSelectedContext(collections: [Self.passages()])
        let response = try source.response(body: .object(["query": .string("¿Cómo se relacionan la fotografía y la propaganda?"), "budget": .int(120_000), "include": .array([.string("passages")])]))
        let package = try JSONDecoder.nodus.decode(ContextPackage.self, from: response.data)
        #expect(package.sourceScope == "device_downloads"); #expect(package.stats.matched == 253); #expect(!package.stats.truncated)
        #expect(package.sections.first?.items.count == 253)
        #expect(package.sections.first?.items.last?.string("text") == "La fotografía conserva 37 huellas de propaganda: testimonio literal final.")
        let missing = try source.response(body: .object(["query": .string("astronomía")]))
        let empty = try JSONDecoder.nodus.decode(ContextPackage.self, from: missing.data)
        #expect(empty.sections.isEmpty); #expect(empty.stats.matched == 0)
        #expect(throws: DesktopBridgeError.self) { try source.response(body: .object(["query": .string("fotografía"), "include": .array([.string("private_roster")])])) }
        #expect(throws: DesktopBridgeError.self) { try source.response(body: .object(["query": .string(" ")])) }
    }

    @Test("oversized passages are omitted with an explicit truncated flag rather than altered quotations")
    func literalBudget() throws {
        let literal = "Fotografía: " + String(repeating: "37 palabras sin recortar. ", count: 200)
        let source = try CompanionSelectedContext(collections: [Self.passages(count: 2, lastText: literal)])
        let response = try source.response(body: .object(["query": .string("fotografía"), "budget": .int(1000)]))
        let package = try JSONDecoder.nodus.decode(ContextPackage.self, from: response.data)
        #expect(package.stats.truncated); #expect(package.stats.matched == 2); #expect(package.stats.chars <= 1000)
        #expect(package.sections.first?.items.map { $0.string("passage_id") } == ["passage-0"])
        #expect(package.sections.first?.items.first?.string("text") == "Fotografía y propaganda: testimonio literal 0.")
    }

    @Test("graph neighbours and linked summaries never become independently citable source rows")
    func chosenOwnersOnly() throws {
        let row: JSONValue = .object(["nodus_id": .string("chosen-work"), "title": .string("Historia de la fotografía")])
        let copy = try CompanionCollectionCopy(path: "works", copies: [.object(["version": .int(1), "path": .string("works"), "entries": .array([
            .object(["summary": row, "detail": .object(["work": row,
                "ideas": .array([.object(["global_id": .string("linked-only"), "label": .string("Fotografía")])]),
                "documentProfile": .object(["quotation": .string("An invented orientation quotation must not enter the catalogue")])])])])])])
        let source = try CompanionSelectedContext(collections: [copy])
        let package = try JSONDecoder.nodus.decode(ContextPackage.self, from: source.response(body: .object(["query": .string("fotografía")])).data)
        #expect(package.sections.map(\.kind) == ["works"])
        #expect(package.sections.first?.items.first?.string("nodus_id") == "chosen-work")
        #expect(package.sections.first?.items.first?["documentProfile"] == nil)
    }
}
