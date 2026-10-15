import NodusUI
import SwiftUI
import UIKit
import WebKit
import JavaScriptCore
import NodusKit

/// Printing the vault's own report layout to a PDF, on the phone.
///
/// The design is not this app's. It is `shared/professionalReport.ts` — the same cover,
/// contents, section rules and traceability matrix the desktop prints — served by the Nodus
/// Server as one self-contained HTML document at `.../deep-research/<id>/document.html`.
///
/// The server sends HTML rather than a PDF on purpose. Laying out a printed page needs a
/// browser engine, and the server has none: it is Alpine, Node, and not one dependency. This
/// device has WebKit, so it prints the page it is given.
///
/// ## Why this is a print job and not a snapshot
///
/// `WKWebView.createPDF` is not a printer. It photographs the whole rendered page into a
/// single PDF page the size of the content, so it ignores `@page`, ignores every page break
/// the stylesheet declares, and produces exactly what was reported: one sheet 3 514 by 14 400
/// points, unpaginated, with no cover and no margins. Nothing about that is fixable by
/// resizing the web view — a snapshot has no notion of a page.
///
/// `UIPrintPageRenderer` with the web view's own print formatter is the printer: it lays the
/// document out for a page box, honours `break-before`/`break-after`, and hands back one drawn
/// page at a time. That is what turns the same HTML into the A4 document the desktop prints.
@MainActor
enum ReportDocument {
    enum Failure: LocalizedError {
        case couldNotRender

        var errorDescription: String? {
            String(localized: "The report could not be laid out for printing.")
        }
    }

    /// The canonical Desktop renderer is bundled as a pure JavaScript function.
    /// JavaScriptCore has no network or provider bridge; the arguments are data.
    static func renderHTML(draft: JSONValue, image: JSONValue = .object(["dataUrl": .null, "credit": .null])) throws -> String {
        guard let file = Bundle.main.url(forResource: "report-renderer", withExtension: "js", subdirectory: "SharedDesktop"),
              let context = JSContext() else { throw Failure.couldNotRender }
        context.evaluateScript(try String(contentsOf: file, encoding: .utf8))
        guard context.exception == nil,
              let renderer = context.objectForKeyedSubscript("NodusReport"),
              let describe = renderer.objectForKeyedSubscript("deepResearchReportInput"),
              let print = renderer.objectForKeyedSubscript("renderProfessionalReportHtml") else { throw Failure.couldNotRender }
        let args = try [draft, image].map { try JSONSerialization.jsonObject(with: JSONEncoder.nodus.encode($0), options: [.fragmentsAllowed]) }
        guard let input = describe.call(withArguments: args), context.exception == nil,
              let result = print.call(withArguments: [input]), context.exception == nil,
              let html = result.toString(), html.lowercased().contains("<!doctype html>") else { throw Failure.couldNotRender }
        return html
    }

    static func html(session: SpaceSession, reportId: String) async throws -> String {
        if let own = try await CompanionDeepResearchResult.draft(session: session, id: reportId) {
            let cover = try await CompanionDeepResearchResult.cover(session: session, id: reportId, dataURL: true)
            return try renderHTML(draft: own, image: .object(["dataUrl": cover, "credit": .null]))
        }
        if !session.isDemo {
            do { return try await session.client.deepResearchDocument(reportId, in: session.connection.spaceId) }
            catch {
                let offline = isPrivateBridgeOffline(error) || [.offline, .timedOut, .hostNotFound, .cannotConnect].contains(error as? TransportError ?? .cancelled)
                guard offline else { throw error }
                if session.mirror == nil { await session.loadMirror() }
                guard let mirror = session.mirror,
                      let row = try await mirror.row(table: "writing_saved_drafts", id: reportId),
                      let draft = row.embeddedJSON("draft_json") else { throw error }
                let image = try await mirror.deepResearchImage(entityId: reportId)
                return try await renderPublishedHTML(draft: draft, hash: image?.hash, mime: image?.mime, session: session)
            }
        }
        let detail = try await session.client.deepResearchReport(reportId, in: session.connection.spaceId)
        guard let draft = detail.report.embeddedJSON("draft") else { throw Failure.couldNotRender }
        return try await renderPublishedHTML(draft: draft, hash: detail.image?.string("hash"), mime: detail.image?.string("mime"), session: session)
    }

    static func html(saved: LocalReportStore.Saved, store: LocalReportStore) throws -> String {
        let draft = try ReportDraft.document(report: saved.report, language: saved.outputLanguage, now: saved.createdAt)
        var image: JSONValue = .object(["dataUrl": .null, "credit": .null])
        if let url = store.imageURL(for: saved) {
            let bytes = try Data(contentsOf: url)
            let mime = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
            image = .object(["dataUrl": .string("data:\(mime);base64,\(bytes.base64EncodedString())"), "credit": .null])
        }
        return try renderHTML(draft: draft, image: image)
    }

    private static func renderPublishedHTML(draft: JSONValue, hash: String?, mime: String?, session: SpaceSession) async throws -> String {
        var cover: JSONValue = .object(["dataUrl": .null, "credit": .null])
        if let hash {
            let bytes = try await session.client.asset(hash: hash, in: session.connection.spaceId)
            cover = .object(["dataUrl": .string("data:\(mime ?? "image/png");base64,\(bytes.base64EncodedString())"), "credit": .null])
        }
        return try renderHTML(draft: draft, image: cover)
    }

    /// A4 at 72 points to the inch — the page the desktop prints
    /// (`electron/export/htmlToPdf.ts` asks Chromium for `pageSize: 'A4'`).
    private static let paperSize = CGSize(width: 595.28, height: 841.89)
    /// The margin the stylesheet's own `@page` rule declares. UIKit printing does not read
    /// `@page`, so the same 20 mm is applied here instead of being lost.
    private static let marginPoints = 20.0 / 25.4 * 72

    /// With the CSS page margin disabled, this correction preserves Desktop's
    /// typography: 30pt cover headings and 10.7pt body text. Applying the CSS
    /// page box as well changes WebKit's fitting scale and adds a second inset.
    private static let layoutScale = 0.9375

    /// Two instructions for WebKit's printer, and nothing about the design.
    ///
    /// - Backgrounds: WebKit drops every fill when printing unless the page says otherwise, and
    ///   the document only says it for four selectors. Chromium never needed to be told —
    ///   `printBackground: true` covers it — so the desktop's PDF has the cover motif, the
    ///   numbered section circles, the tinted matrix header and the metric pills, and the
    ///   phone's had none of them.
    /// - The cover: it is `min-height: 245 mm`, a height Chromium's page box has room for and
    ///   WebKit's does not — measured, the cover overflowed by exactly its own footer, so every
    ///   report opened with a nearly empty second page carrying the date and the metrics.
    ///   Letting the cover be as tall as its contents keeps it on one sheet; `break-after:
    ///   page` still starts the contents on the next.
    private static let printerRules = """
    <style>
    /* UIKit supplies the paper box and its 20mm margins. WebKit must not add
       a second CSS page box inside it. */
    @page { size: auto; margin: 0; }
    @media print {
      *, *::before, *::after { -webkit-print-color-adjust: exact !important; print-color-adjust: exact !important; }
      .cover { min-height: 0 !important; }
    }</style>
    """

    /// Load the document into an off-screen web view and print it.
    static func pdf(from html: String) async throws -> Data {
        try Task.checkCancellation()
        let paper = CGRect(
            origin: .zero,
            size: CGSize(width: paperSize.width / layoutScale, height: paperSize.height / layoutScale)
        )
        let configuration = WKWebViewConfiguration();configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: paper,configuration:configuration)
        // In the window, not floating free: WebKit will not lay out a detached web view for
        // print, and a print job asked of one comes back empty — which is the other half of
        // "sometimes it does not even generate".
        attach(webView)
        defer { webView.stopLoading();webView.navigationDelegate = nil;webView.removeFromSuperview() }

        let loader = Loader()
        webView.navigationDelegate = loader
        // A base URL of nil is right: the document is self-contained — its cover image is a
        // `data:` URL and its styles are inline — so there is nothing to resolve against, and
        // a real base would let a stray reference reach the network mid-print.
        webView.loadHTMLString(withPrinterRules(html), baseURL: nil)
        try await loader.finished()

        // WebKit reports the page as laid out only after a turn of the run loop past
        // `didFinish`; printing immediately gives a blank first page.
        try await Task.sleep(for: .milliseconds(200))
        try await paginateLongTables(in: webView, paper: paper)
        _ = try await webView.evaluateJavaScript("""
        (() => {
          for (const heading of document.querySelectorAll('.prose h1,.prose h2,.prose h3,.prose h4,.section-body > h3')) {
            const paragraph = heading.nextElementSibling;
            if (!paragraph || paragraph.tagName !== 'P') continue;
            const group = document.createElement('div'); group.style.cssText = 'break-inside:avoid;page-break-inside:avoid;';
            heading.before(group); group.append(heading, paragraph);
          }
          return document.body.getBoundingClientRect().height;
        })()
        """)
        let metadata = try await webView.evaluateJavaScript("[document.title, document.querySelector('.cover-kicker')?.textContent || '', getComputedStyle(document.documentElement).getPropertyValue('--accent').trim()]") as? [String] ?? []

        let renderer = FixedPageRenderer(
            paper: paper,
            printable: paper.insetBy(dx: marginPoints / layoutScale, dy: marginPoints / layoutScale)
        )
        let formatter = webView.viewPrintFormatter()
        // A print formatter carries a one-inch top and left inset of its own, which would land
        // on top of the margins the renderer already sets.
        formatter.perPageContentInsets = .zero
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)

        let pages = renderer.numberOfPages
        try Task.checkCancellation()
        guard pages > 0 else { throw Failure.couldNotRender }

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, CGRect(origin: .zero, size: paperSize), [
            kCGPDFContextTitle as String: metadata.first ?? "",
            kCGPDFContextAuthor as String: "Nodus",
            kCGPDFContextCreator as String: "Nodus"
        ])
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: pages))
        for index in 0..<pages {
            UIGraphicsBeginPDFPage()
            guard let context = UIGraphicsGetCurrentContext() else { continue }
            context.saveGState()
            context.scaleBy(x: layoutScale, y: layoutScale)
            renderer.drawPage(at: index, in: paper)
            context.restoreGState()
            if index > 0 { drawRunningFurniture(page: index + 1, total: pages, kind: metadata.count > 1 ? metadata[1] : "", accentHex: metadata.count > 2 ? metadata[2] : "") }
        }
        UIGraphicsEndPDFContext()

        guard data.length > 0 else { throw Failure.couldNotRender }
        return data as Data
    }

    /// WebKit's UIKit formatter does not reliably repeat `thead` or keep `tr`
    /// together. Measure each continuation with that same formatter, then give
    /// it an explicit page break and its own copy of the column headings. No
    /// font estimates, row-count limits or content truncation determine a page.
    private static func paginateLongTables(in webView: WKWebView, paper: CGRect) async throws {
        let counts = try await webView.evaluateJavaScript("""
        (() => {
          window.nodusPrintTables = Array.from(document.querySelectorAll('table')).filter(table => table.tBodies.length && table.tHead);
          window.nodusPrintStartsSection = table => {
            let node = table;
            while (node.parentElement && node.parentElement !== document.body) {
              const parent = node.parentElement;
              if (parent.classList.contains('report-section')) return node.previousElementSibling?.classList.contains('section-heading') === true;
              if (parent.firstElementChild !== node) return false;
              node = parent;
            }
            return false;
          };
          window.nodusPrintSegment = (index, start, end, ancestors) => {
            const original = window.nodusPrintTables[index], table = original.cloneNode(false);
            for (const child of original.children) if (['CAPTION','COLGROUP','THEAD'].includes(child.tagName)) table.appendChild(child.cloneNode(true));
            const rows = Array.from(original.tBodies).flatMap(body => Array.from(body.rows)), body = original.tBodies[0].cloneNode(false);
            for (const row of rows.slice(start, end)) body.appendChild(row.cloneNode(true));
            table.appendChild(body);
            if (end === rows.length && original.tFoot) table.appendChild(original.tFoot.cloneNode(true));
            let root = table;
            if (ancestors) for (let parent = original.parentElement; parent && parent !== document.body; parent = parent.parentElement) {
              const wrapper = parent.cloneNode(false); wrapper.removeAttribute('id'); wrapper.appendChild(root);
              if (start === 0 && window.nodusPrintStartsSection(original) && parent.classList.contains('report-section')) {
                const heading = parent.querySelector(':scope > .section-heading');
                if (heading) wrapper.prepend(heading.cloneNode(true));
              }
              root = wrapper;
            }
            return root.outerHTML;
          };
          return window.nodusPrintTables.map(table => Array.from(table.tBodies).reduce((sum, body) => sum + body.rows.length, 0));
        })()
        """) as? [Int] ?? []
        guard counts.contains(where: { $0 > 1 }) else { return }
        let head = try await webView.evaluateJavaScript("document.head.innerHTML") as? String ?? ""
        let configuration = WKWebViewConfiguration();configuration.websiteDataStore = .nonPersistent()
        let probe = WKWebView(frame: paper,configuration:configuration)
        attach(probe)
        defer { probe.stopLoading();probe.navigationDelegate = nil;probe.removeFromSuperview() }
        let probeRules = "<style>@media print { .report-section { break-before: auto !important; page-break-before: auto !important; } }</style>"

        func pageCount(table index: Int, start: Int, end: Int) async throws -> Int {
            guard let body = try await webView.evaluateJavaScript("window.nodusPrintSegment(\(index),\(start),\(end),true)") as? String else { throw Failure.couldNotRender }
            let loader = Loader(); probe.navigationDelegate = loader
            probe.loadHTMLString("<!doctype html><html><head>" + head + probeRules + "</head><body>" + body + "</body></html>", baseURL: nil)
            try await loader.finished()
            try await Task.sleep(for: .milliseconds(100))
            let renderer = FixedPageRenderer(paper: paper, printable: paper.insetBy(dx: marginPoints / layoutScale, dy: marginPoints / layoutScale))
            let formatter = probe.viewPrintFormatter(); formatter.perPageContentInsets = .zero
            renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
            let pages = renderer.numberOfPages
            guard pages > 0 else { throw Failure.couldNotRender }
            return pages
        }

        for (index, count) in counts.enumerated() where count > 1 {
            guard try await pageCount(table: index, start: 0, end: count) > 1 else { continue }
            var start = 0, chunks: [[Int]] = []
            while start < count {
                try Task.checkCancellation()
                var lower = start + 1, upper = count, lastFitting = start
                while lower <= upper {
                    let end = lower + (upper - lower) / 2
                    if try await pageCount(table: index, start: start, end: end) == 1 {
                        lastFitting = end; lower = end + 1
                    } else { upper = end - 1 }
                }
                // A row taller than A4 still uses WebKit's normal text splitting;
                // the whole row is retained, never silently omitted or clipped.
                let end = max(start + 1, lastFitting)
                chunks.append([start, end]); start = end
            }
            let encoded = String(decoding: try JSONEncoder().encode(chunks), as: UTF8.self)
            _ = try await webView.evaluateJavaScript("""
            (() => {
              const original = window.nodusPrintTables[\(index)], fragment = document.createDocumentFragment();
              for (const [start, end] of \(encoded)) {
                const continuation = document.createElement('div');
                const keepSectionHeading = start === 0 && window.nodusPrintStartsSection(original);
                continuation.style.cssText = keepSectionHeading ? 'break-inside:avoid;page-break-inside:avoid;' : 'break-before:page;page-break-before:always;';
                continuation.innerHTML = window.nodusPrintSegment(\(index),start,end,false);
                fragment.appendChild(continuation);
              }
              original.replaceWith(fragment);
              return true;
            })()
            """)
        }
        _ = try await webView.evaluateJavaScript("document.body.getBoundingClientRect().height")
        try await Task.sleep(for: .milliseconds(200))
    }

    /// Desktop stamps these after Chromium prints. UIKit draws the same brand mark,
    /// running rules and page numbers after WebKit prints each page.
    private static func drawRunningFurniture(page: Int, total: Int, kind: String, accentHex: String) {
        let color = UInt32(accentHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x6366f1
        let accent = UIColor(red: CGFloat((color >> 16) & 255) / 255, green: CGFloat((color >> 8) & 255) / 255, blue: CGFloat(color & 255) / 255, alpha: 1)
        let center = paperSize.width / 2
        let rule = UIBezierPath()
        rule.move(to: CGPoint(x: marginPoints, y: 39)); rule.addLine(to: CGPoint(x: center - 16, y: 39))
        rule.move(to: CGPoint(x: center + 16, y: 39)); rule.addLine(to: CGPoint(x: paperSize.width - marginPoints, y: 39))
        rule.move(to: CGPoint(x: marginPoints, y: paperSize.height - 39)); rule.addLine(to: CGPoint(x: paperSize.width - marginPoints, y: paperSize.height - 39))
        UIColor(red: 0.84, green: 0.86, blue: 0.9, alpha: 1).setStroke(); rule.lineWidth = 0.45; rule.stroke()
        let mark = UIBezierPath()
        mark.move(to: CGPoint(x: center - 4.9, y: 30.8)); mark.addLine(to: CGPoint(x: center - 4.9, y: 19.2))
        mark.addLine(to: CGPoint(x: center + 4.9, y: 30.8)); mark.addLine(to: CGPoint(x: center + 4.9, y: 19.2))
        accent.setStroke(); mark.lineWidth = 2.4; mark.lineCapStyle = .round; mark.stroke(); accent.setFill()
        for x in [center - 4.9, center + 4.9] { for y in [19.2, 30.8] { UIBezierPath(ovalIn: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)).fill() } }
        let gray = UIColor(red: 0.46, green: 0.49, blue: 0.56, alpha: 1)
        let textStyle: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 6.5, weight: .bold), .foregroundColor: gray]
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        var kindStyle = textStyle; kindStyle[.paragraphStyle] = paragraph
        (kind.uppercased() as NSString).draw(in: CGRect(x: marginPoints, y: paperSize.height - 28.5, width: center - marginPoints - 24, height: 12), withAttributes: kindStyle)
        var brandStyle = textStyle; brandStyle[.foregroundColor] = accent
        let brand = "NODUS" as NSString; let brandSize = brand.size(withAttributes: brandStyle)
        brand.draw(at: CGPoint(x: paperSize.width - marginPoints - brandSize.width, y: paperSize.height - 28.5), withAttributes: brandStyle)
        let number = "\(page) / \(total)" as NSString
        let numberStyle: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 7.5), .foregroundColor: gray]
        let numberSize = number.size(withAttributes: numberStyle)
        number.draw(at: CGPoint(x: center - numberSize.width / 2, y: paperSize.height - 29), withAttributes: numberStyle)
    }

    /// The printer rules go last in `<head>`, so they win against the document's own.
    private static func withPrinterRules(_ html: String) -> String {
        guard let head = html.range(of: "</head>") else { return html + printerRules }
        return html.replacingCharacters(in: head, with: printerRules + "</head>")
    }

    private static func attach(_ webView: WKWebView) {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        guard let window else { return }
        // Behind everything and effectively invisible, but laid out: a hidden view or one at
        // zero alpha is skipped by the render server, and the print job comes back blank.
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        window.insertSubview(webView, at: 0)
    }

    /// Writes the PDF where a share sheet can reach it, under a name worth seeing.
    static func file(named title: String, bytes: Data) throws -> URL {
        let safe = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = safe.isEmpty ? "informe" : String(safe.prefix(80))
        let url = URL.temporaryDirectory.appendingPathComponent("\(name).pdf")
        try bytes.write(to: url, options: .atomic)
        return url
    }

    /// `WKNavigationDelegate` as one awaited call.
    @MainActor
    private final class Loader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var result: Result<Void,Error>?
        private var timeout: Task<Void,Never>?

        func finished() async throws {
            try Task.checkCancellation()
            if let result { return try result.get() }
            try await withTaskCancellationHandler(operation:{
                try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                    self.continuation = continuation
                    timeout = Task { @MainActor [weak self] in
                        do { try await Task.sleep(for:.seconds(30));self?.settle(.failure(URLError(.timedOut))) } catch { }
                    }
                }
            },onCancel:{ Task { @MainActor in self.settle(.failure(CancellationError())) } })
        }

        private func settle(_ result: Result<Void, Error>) {
            guard self.result == nil else { return }
            self.result = result;timeout?.cancel();timeout = nil
            switch result {
            case .success: continuation?.resume()
            case .failure(let error): continuation?.resume(throwing: error)
            }
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            settle(.success(()))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            settle(.failure(error))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            settle(.failure(error))
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { settle(.failure(Failure.couldNotRender)) }
    }
}

/// A page renderer for a page that is not a printer's.
///
/// `UIPrintPageRenderer` gets `paperRect` and `printableRect` from the print job it belongs to,
/// and there is no job here — the destination is a file. Both are declared `open` precisely so
/// a renderer can state its own page box, which is how the A4 sheet is set without touching a
/// private API.
#if compiler(>=6.2)
nonisolated final class FixedPageRenderer: UIPrintPageRenderer {
    private let paper: CGRect
    private let printable: CGRect

    init(paper: CGRect, printable: CGRect) {
        self.paper = paper
        self.printable = printable
        super.init()
    }

    override var paperRect: CGRect { paper }
    override var printableRect: CGRect { printable }
}
#else
@MainActor final class FixedPageRenderer: UIPrintPageRenderer {
    private let paper: CGRect
    private let printable: CGRect

    init(paper: CGRect, printable: CGRect) {
        self.paper = paper
        self.printable = printable
        super.init()
    }

    override var paperRect: CGRect { paper }
    override var printableRect: CGRect { printable }
}
#endif

/// The third button beside the two copies: the report as the desktop prints it.
struct ReportPDFButton: View {
    let session: SpaceSession
    let reportId: String
    let title: String
    let accent: Color
    var local: (saved: LocalReportStore.Saved, store: LocalReportStore)?

    @State private var isBuilding = false
    @State private var file: URL?
    @State private var error: String?

    var body: some View {
        Group {
            if let file {
                // Once it exists it is a share sheet, not a button that builds it again.
                ShareLink(item: file) {
                    label("arrow.up.doc", title: "PDF")
                }
                .accessibilityLabel("Save the PDF")
                .accessibilityIdentifier("report-pdf-ready")
            } else {
                Button {
                    build()
                } label: {
                    if isBuilding {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small).tint(accent)
                            Text("PDF").font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(accent.nodusReadable)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .reportActionSurface(accent: accent)
                    } else {
                        label("arrow.down.doc", title: "PDF")
                    }
                }
                .buttonStyle(.plain)
                .disabled(isBuilding)
                .accessibilityLabel("Download as a PDF")
                .accessibilityIdentifier("report-pdf-build")
            }
        }
        .alert(
            "Could not build the PDF",
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(LocalizedStringKey(error ?? ""))
        }
    }

    /// The same shape the copy control and the size stepper wear, so the row of actions reads as
    /// a row of one kind of thing.
    private func label(_ systemImage: String, title: LocalizedStringKey) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(accent.nodusReadable)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .reportActionSurface(accent: accent)
    }

    private func build() {
        isBuilding = true
        Task {
            defer { isBuilding = false }
            do {
                let html: String
                if let local { html = try ReportDocument.html(saved: local.saved, store: local.store) }
                else { html = try await ReportDocument.html(session: session, reportId: reportId) }
                let bytes = try await ReportDocument.pdf(from: html)
                file = try ReportDocument.file(named: title, bytes: bytes)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
