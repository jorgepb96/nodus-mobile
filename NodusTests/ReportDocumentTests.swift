import CoreGraphics
import Foundation
import Testing
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
