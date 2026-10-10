import Foundation
import Testing
import NodusKit
@testable import Nodus

@Suite("Source document navigation")
struct SourceDocumentNavigationTests {
    @Test("source, scope, page and attachment survive the WebKit navigation contract")
    func sourcePosition() throws {
        let input = Data(#"{"itemId":"nodus:source#1","scope":"global","page":12,"attachmentId":"original/opaque"}"#.utf8)
        let target = try JSONDecoder().decode(SourceDocumentTarget.self, from: input)
        try target.validate()
        #expect(target.itemId == "nodus:source#1")
        #expect(target.page == 12)
        #expect(target.scope == .global)
        #expect(target.attachmentId == "original/opaque")
        #expect(try JSONDecoder().decode(SourceDocumentTarget.self, from: JSONEncoder().encode(target)) == target)
    }
    @Test("an invalid page or source cannot be presented as a successful citation jump")
    func invalidSourcePosition() throws {
        for target in [SourceDocumentTarget(itemId:"",scope:.vault,page:1,attachmentId:nil),
                       SourceDocumentTarget(itemId:"source",scope:.vault,page:0,attachmentId:nil),
                       SourceDocumentTarget(itemId:"source",scope:.vault,page:-1,attachmentId:nil),
                       SourceDocumentTarget(itemId:"source",scope:.global,page:nil,attachmentId:"")] {
            #expect(throws: DesktopBridgeError.self) { try target.validate() }
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SourceDocumentTarget.self, from: Data(#"{"itemId":"source","scope":"unknown","page":12}"#.utf8))
        }
    }

    @Test("clean export preserves structured Markdown and isolates unsafe or repeated titles")
    func cleanSourceExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let markdown = "# Fuente\n\n| Evidencia | Página |\n| --- | --- |\n| cita | 2 |\n\n[Referencia](nodus://source/1)\n\n$E=mc^2$\n"
        let title = "../../Fuente:\\citas\u{0}" + String(repeating: "📖", count: 120)
        let first = try exportSourceMarkdown(title: title, markdown: markdown, directory: root)
        let second = try exportSourceMarkdown(title: title, markdown: "Otra copia", directory: root)
        #expect(first.path.hasPrefix(root.path + "/Nodus-source-exports/"))
        #expect(first.pathExtension == "md")
        #expect(first.lastPathComponent.utf8.count <= 183)
        #expect(!first.lastPathComponent.contains(":"))
        #expect(!first.lastPathComponent.contains("\\"))
        #expect(first != second)
        #expect(try String(contentsOf: first, encoding: .utf8) == markdown)
        #expect(try String(contentsOf: second, encoding: .utf8) == "Otra copia")
        let empty = try exportSourceMarkdown(title: "\n\u{0}", markdown: markdown, directory: root)
        #expect(empty.lastPathComponent == "source.md")
    }
}
