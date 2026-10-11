import Foundation
import NodusKit
import Testing
@testable import NodusAI

@Suite("Specialised research citations")
struct SpecialisedCitationTests {
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
