import Foundation
import NodusKit
import Testing
@testable import NodusAI

@Suite("Specialised research citations")
struct SpecialisedCitationTests {
    @Test("research budgets keep complete quotations, omitting oversized entries instead of cutting evidence")
    func fullEvidenceBudget() throws {
        let literal = String(repeating: "La fuente literal conserva 37 datos. ", count: 1000)
        let large = CitationCatalog.Entry(token: "nodus://passage/large", kind: "passage", id: "large", label: "Fuente extensa", detail: literal)
        let small = CitationCatalog.Entry(token: "nodus://study/doc/small", kind: "study", id: "small", label: "Apunte elegido", detail: "Texto completo con 37 datos")
        let bounded = try CitationCatalog(entries: [large, small]).bounded(to: 1000)
        #expect(bounded.omitted == 1); #expect(bounded.bytes <= 1000)
        #expect(bounded.catalog.entries == [small]); #expect(bounded.catalog.entries[0].detail == small.detail)
        let complete = try CitationCatalog(entries: [large]).bounded(to: 100_000)
        #expect(complete.omitted == 0); #expect(complete.catalog.entries[0].detail == literal)
    }
    @Test("non-academic sources are citable and retained in the bibliography without invented work IDs")
    func citableSource() throws {
        let source: JSONValue = .object(["version": .int(1), "collection": .string("study-docs"), "recordId": .string("doc/37"),
            "citation": .string("nodus://study/doc/doc%2F37"), "kind": .string("study"), "label": .string("Apuntes de fotografía"),
            "text": .string("Texto literal completo con 37 datos"), "contentScope": .string("record")])
        let json: JSONValue = .object(["sourceScope": .string("device_downloads"), "revision": .string("selected"), "citationScheme": .object([:]),
            "sections": .array([.object(["kind": .string("sources"), "items": .array([source])])]),
            "stats": .object(["chars": .int(400), "budget": .int(1000), "truncated": .bool(false), "matched": .int(1)])])
        let package = try JSONDecoder.nodus.decode(ContextPackage.self, from: JSONEncoder.nodus.encode(json))
        let catalog = CitationCatalog.from(package)
        let entry = try #require(catalog.entry(for: "nodus://study/doc/doc%2F37"))
        #expect(entry.workId == nil); #expect(entry.detail == "Texto literal completo con 37 datos")
        #expect(CitationLabelling.plain([entry]).references == [entry])
        var malformed = source.objectValue!; malformed["citation"] = .string("nodus://study/doc/foreign")
        #expect(throws: DesktopBridgeError.self) { try CorpusSourceMaterial(row: Row(malformed)) }
    }
}
