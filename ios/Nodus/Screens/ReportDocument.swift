import NodusUI
import SwiftUI
import UIKit
import WebKit

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

    /// A4 at 72 points to the inch — the page the desktop prints
    /// (`electron/export/htmlToPdf.ts` asks Chromium for `pageSize: 'A4'`).
    private static let paperSize = CGSize(width: 595.28, height: 841.89)
    /// The margin the stylesheet's own `@page` rule declares. UIKit printing does not read
    /// `@page`, so the same 20 mm is applied here instead of being lost.
    private static let marginPoints = 20.0 / 25.4 * 72

    /// WebKit lays a printed page out at 1.25× the printable width and scales the result down
    /// to fit — `printingMinimumShrinkFactor` — so a CSS pixel lands on 0.8 of a point where
    /// Chromium puts it on 0.75, and an untouched print job comes out some seven per cent
    /// larger than the desktop's. Laying out on paper this much bigger and drawing the pages
    /// back down onto A4 cancels it: 514 points of printable width become 642.5 CSS pixels,
    /// which is the 170 mm column the design was written for, on a sheet that is still A4.
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
    <style>@media print {
      *, *::before, *::after { -webkit-print-color-adjust: exact !important; print-color-adjust: exact !important; }
      .cover { min-height: 0 !important; }
    }</style>
    """

    /// Load the document into an off-screen web view and print it.
    static func pdf(from html: String) async throws -> Data {
        let paper = CGRect(
            origin: .zero,
            size: CGSize(width: paperSize.width / layoutScale, height: paperSize.height / layoutScale)
        )
        let webView = WKWebView(frame: paper)
        // In the window, not floating free: WebKit will not lay out a detached web view for
        // print, and a print job asked of one comes back empty — which is the other half of
        // "sometimes it does not even generate".
        attach(webView)
        defer { webView.removeFromSuperview() }

        let loader = Loader()
        webView.navigationDelegate = loader
        // A base URL of nil is right: the document is self-contained — its cover image is a
        // `data:` URL and its styles are inline — so there is nothing to resolve against, and
        // a real base would let a stray reference reach the network mid-print.
        webView.loadHTMLString(withPrinterRules(html), baseURL: nil)
        try await loader.finished()

        // WebKit reports the page as laid out only after a turn of the run loop past
        // `didFinish`; printing immediately gives a blank first page.
        try? await Task.sleep(for: .milliseconds(200))

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
        guard pages > 0 else { throw Failure.couldNotRender }

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, CGRect(origin: .zero, size: paperSize), nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: pages))
        for index in 0..<pages {
            UIGraphicsBeginPDFPage()
            guard let context = UIGraphicsGetCurrentContext() else { continue }
            context.saveGState()
            context.scaleBy(x: layoutScale, y: layoutScale)
            renderer.drawPage(at: index, in: paper)
            context.restoreGState()
        }
        UIGraphicsEndPDFContext()

        guard data.length > 0 else { throw Failure.couldNotRender }
        return data as Data
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
    private final class Loader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var settled = false

        func finished() async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        }

        private func settle(_ result: Result<Void, Error>) {
            guard !settled else { return }
            settled = true
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
    }
}

/// A page renderer for a page that is not a printer's.
///
/// `UIPrintPageRenderer` gets `paperRect` and `printableRect` from the print job it belongs to,
/// and there is no job here — the destination is a file. Both are declared `open` precisely so
/// a renderer can state its own page box, which is how the A4 sheet is set without touching a
/// private API.
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

/// The third button beside the two copies: the report as the desktop prints it.
struct ReportPDFButton: View {
    let session: SpaceSession
    let reportId: String
    let title: String
    let accent: Color

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
                let html = try await session.client.deepResearchDocument(
                    reportId,
                    in: session.connection.spaceId
                )
                let bytes = try await ReportDocument.pdf(from: html)
                file = try ReportDocument.file(named: title, bytes: bytes)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
