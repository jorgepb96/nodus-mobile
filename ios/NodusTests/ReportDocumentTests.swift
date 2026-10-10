import CoreGraphics
import Foundation
import Testing
import NodusKit
import NodusAI
import PDFKit
import UIKit
@testable import Nodus

/// The report, printed.
///
/// One assertion carries this suite: the output is *paginated A4*. What shipped before was a
/// `WKWebView.createPDF` snapshot, which is not a printer — it photographs the rendered page
/// into a single PDF page the size of the content, ignoring `@page` and every break the
/// stylesheet declares. The reported symptom was a file of one sheet 3 514 by 14 400 points,
/// and no test here would have caught it, because nothing checked the shape of the result.
@Suite("Report document")
@MainActor
struct ReportDocumentTests {
    @Test("the bundled Desktop renderer preserves rich content, cover images and bibliography without a server")
    func canonicalOfflineLayout() throws {
        let prose = "## Memoria y fuentes\n\nUna cita [Fuente](nodus://passage/work%23source).\n\n| Fuente | Año |\n| --- | --- |\n| Archivo | 2026 |\n\n<script>untrusted()</script>"
        let section = DeepResearchSection(title: "Memoria", prose: prose, citations: [], rejectedCitations: [])
        let report = DeepResearchReport(objective: "La memoria colectiva", sections: [section], references: [CitationCatalog.Entry(token: "nodus://work/work", kind: "work", id: "work", label: "Autora. Memoria colectiva (2026).")], words: section.wordCount,
            pages: 1, citationsChecked: 0, citationsRejected: 0, stoppedReason: nil)
        let row = Row(ReportDraft.row(id: "isolated-report", report: report, mode: .research,
            model: ModelRef(provider: .openai, model: "isolated-renderer-fixture"), language: "es", now: Date(timeIntervalSince1970: 0)))
        let draft = try #require(row.embeddedJSON("draft_json"))
        let image = try coverImage()
        let html = try ReportDocument.renderHTML(draft: draft, image: .object(["dataUrl": .string(image), "credit": .null]))
        #expect(html.contains("La memoria colectiva"))
        #expect(html.contains("Memoria y fuentes"))
        #expect(html.contains("<table"))
        #expect(html.contains("class=\"cover"))
        #expect(html.contains(image))
        #expect(html.contains("Autora. Memoria colectiva (2026)."))
        #expect(!html.contains("<script>untrusted()</script>"))
        #expect(throws: ReportDocument.Failure.self) { try ReportDocument.renderHTML(draft: .object([:])) }
    }

    @Test("a long canonical title with an illustration keeps the cover facts on its first page")
    func illustratedLongTitleDoesNotSpill() async throws {
        let title = "La mirada extranjera sobre la España franquista: entre el mito arcádico y la legitimación política"
        let section = DeepResearchSection(title: "Resumen", prose: "El corpus conserva las fuentes y sus relaciones.", citations: [], rejectedCitations: [])
        let report = DeepResearchReport(objective: title, sections: [section], references: [], words: section.wordCount,
            pages: 1, citationsChecked: 0, citationsRejected: 0, stoppedReason: nil)
        let row = Row(ReportDraft.row(id: "isolated-long-title", report: report, mode: .research,
            model: ModelRef(provider: .openai, model: "isolated-renderer-fixture"), language: "es"))
        var draft = try #require(row.embeddedJSON("draft_json")?.objectValue)
        draft["brief"] = .object(["kind": .string("deep_research"), "language": .string("es"), "objective": .string("Mirada extranjera durante el franquismo. ¿Qué temas trataban en sus obras e imágenes y qué excluían?")])
        let image = try coverImage()
        let html = try ReportDocument.renderHTML(draft: .object(draft), image: .object(["dataUrl": .string(image), "credit": .null]))
        let pdf = try #require(PDFDocument(data: try await ReportDocument.pdf(from: html)))
        let first = try #require(pdf.page(at: 0)?.string)
        let second = try #require(pdf.page(at: 1)?.string)
        #expect(first.contains("qué excluían"))
        #expect(first.contains("SECCIONES"))
        #expect(first.contains("PALABRAS"))
        #expect(second.contains("Contenido"), "the second page must contain the contents, never a spilled cover footer")
        let titleSelection = try #require(pdf.findString("La mirada extranjera", withOptions: []).first)
        let titleBounds = titleSelection.bounds(for: try #require(pdf.page(at: 0)))
        #expect(abs(titleBounds.minX - 20 / 25.4 * 72) < 2, "the title uses Desktop's 20mm margin rather than an extra formatter inset")
        let titleFont = try #require(titleSelection.attributedString?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(abs(titleFont.pointSize - 30) < 0.5, "the cover uses the canonical 30pt type size, without WebKit shrinking or enlarging it")
    }

    private func coverImage() throws -> String {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1528, height: 1029)).image { context in
            UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1528, height: 1029))
        }
        return "data:image/png;base64," + (try #require(image.pngData())).base64EncodedString()
    }

    @Test("long source tables keep each fitting row together and repeat their column headings")
    func sourceTablePagination() async throws {
        let rows = (1...32).map { index in
            "| BEGIN\(index) " + String(repeating: "El testimonio conserva el contexto de la fuente. ", count: 8) + " END\(index) | Fuente \(index) |"
        }.joined(separator: "\n")
        let prose = "| Testimonio verificable | Referencia documental |\n| --- | --- |\n" + rows
        let section = DeepResearchSection(title: "Fuentes", prose: prose, citations: [], rejectedCitations: [])
        let report = DeepResearchReport(objective: "La consulta de las fuentes", sections: [section], references: [], words: section.wordCount,
            pages: 1, citationsChecked: 0, citationsRejected: 0, stoppedReason: nil)
        let draft = try ReportDraft.document(report: report, language: "es", now: Date(timeIntervalSince1970: 0))
        let html = try ReportDocument.renderHTML(draft: draft)
        let pdf = try #require(PDFDocument(data: try await ReportDocument.pdf(from: html)))
        var rowPages = Set<Int>()
        for index in 1...32 {
            let first = try #require(pdf.findString("BEGIN\(index) ", withOptions: []).first?.pages.first)
            let last = try #require(pdf.findString("END\(index)", withOptions: []).first?.pages.first)
            #expect(pdf.index(for: first) == pdf.index(for: last), "source row \(index) fits on one page and must not be split")
            rowPages.insert(pdf.index(for: first))
            rowPages.insert(pdf.index(for: last))
        }
        #expect(rowPages.count > 2, "the fixture must exercise table continuation across several pages")
        for page in rowPages {
            let text = try #require(pdf.page(at: page)?.string)
            #expect(text.contains("Testimonio verificable"), "each table page needs its column headings")
            #expect(text.contains("Referencia documental"))
        }
    }

    @Test("section headings stay on the same page as the beginning of their text")
    func headingsStayWithTheirParagraph() async throws {
        let blocks = (1...24).map { index in
            "<h3>Encabezado comprobable \(index)</h3><p>COMIENZO\(index) " + String(repeating: "El testimonio conserva las relaciones y el contexto de su fuente. ", count: 10) + "</p>"
        }.joined()
        let html = "<html><head><style>body{margin:0;font:10.7pt/1.62 Georgia}h3{font:700 12pt Arial;margin:6mm 0 2mm}p{margin:0 0 3.8mm}</style></head><body><div class='prose'>" + blocks + "</div></body></html>"
        let pdf = try #require(PDFDocument(data: try await ReportDocument.pdf(from: html)))
        #expect(pdf.pageCount > 3)
        for index in 1...24 {
            let heading = try #require(pdf.findString("Encabezado comprobable \(index)", withOptions: []).first?.pages.first)
            let text = try #require(pdf.findString("COMIENZO\(index) ", withOptions: []).first?.pages.first)
            #expect(pdf.index(for: heading) == pdf.index(for: text), "heading \(index) must accompany the beginning of its paragraph")
        }
    }
    /// Two pages' worth of prose with a forced break between them, in the shape the server
    /// sends: one self-contained document with its styles inline.
    private func document(paragraphs: Int) -> String {
        let prose = (1...paragraphs)
            .map { "<p>Párrafo \($0). " + String(repeating: "Texto suficiente para llenar la página. ", count: 12) + "</p>" }
            .joined()
        return """
        <!doctype html>
        <html lang="es"><head><meta charset="utf-8"><title>Informe</title>
        <style>
          @page { size: A4; margin: 20mm; }
          body { margin: 0; font-family: Georgia, serif; font-size: 10.7pt; }
          .cover { min-height: 245mm; break-after: page; background: #eef; }
          h1 { font-size: 30pt; }
        </style></head>
        <body><main>
          <section class="cover"><h1>Sujetos de los márgenes</h1></section>
          <section>\(prose)</section>
        </main></body></html>
        """
    }

    private func pages(of data: Data) throws -> (count: Int, first: CGRect) {
        let provider = try #require(CGDataProvider(data: data as CFData))
        let pdf = try #require(CGPDFDocument(provider))
        let first = try #require(pdf.page(at: 1))
        return (pdf.numberOfPages, first.getBoxRect(.mediaBox))
    }

    @Test("a long report comes back as several A4 pages, not one enormous one")
    func printsA4Pages() async throws {
        let data = try await ReportDocument.pdf(from: document(paragraphs: 40))
        let result = try pages(of: data)

        #expect(result.count > 1, "a report longer than a page has to be paginated")
        // A4 at 72 points to the inch, to the nearest point. Anything else means the page box
        // came from the content rather than from the paper.
        #expect(abs(result.first.width - 595.28) < 1)
        #expect(abs(result.first.height - 841.89) < 1)
    }

    /// The cover is `min-height: 245mm`, sized for Chromium's page box; WebKit's is shorter, so
    /// it used to overflow by exactly its own footer and put a nearly empty sheet after it.
    @Test("the cover keeps to one page")
    func coverDoesNotSpill() async throws {
        let data = try await ReportDocument.pdf(from: document(paragraphs: 2))
        let result = try pages(of: data)
        #expect(result.count == 2, "one cover page and one of prose")
    }

    /// `</head>` is where the printer's instructions have to land: last in the head, so they
    /// win against the document's own rules.
    @Test("a document with no head still carries the printer rules")
    func printsHeadlessDocument() async throws {
        let data = try await ReportDocument.pdf(from: "<p>Una sola línea, sin cabecera.</p>")
        let result = try pages(of: data)
        #expect(result.count == 1)
        #expect(abs(result.first.width - 595.28) < 1)
    }
}
