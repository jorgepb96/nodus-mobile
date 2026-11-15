import NodusKit
import NodusUI
import PDFKit
import QuickLook
import SwiftUI

struct SourceDocumentTarget: Codable, Identifiable, Equatable, Sendable {
    enum Scope: String, Codable, Sendable { case global, vault }
    let itemId: String
    let scope: Scope
    let page: Int?
    let attachmentId: String?
    var id: String { "\(scope.rawValue):\(itemId):\(page ?? 0):\(attachmentId ?? "original")" }

    func validate() throws {
        guard !itemId.isEmpty, page == nil || page! > 0,
              attachmentId == nil || !attachmentId!.isEmpty else { throw DesktopBridgeError.malformedResponse }
    }
}

func exportSourceMarkdown(title: String, markdown: String, directory: URL = .temporaryDirectory) throws -> URL {
    var name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
        .replacingOccurrences(of: ":", with: "-")
    name = String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    while name.utf8.count > 180 { name.removeLast() }
    if name.isEmpty || [".", ".."].contains(name) { name = "source" }
    let folder = directory.appendingPathComponent("Nodus-source-exports/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name + ".md")
    try Data(markdown.utf8).write(to: url, options: [.atomic, .completeFileProtection])
    return url
}

@MainActor
func publishedSourceLibraryDocument(_ session: SpaceSession, id: String) async throws -> PublishedLibraryDocument {
    let store = PublishedLibraryStore(spaceId: session.connection.spaceId, storageId: session.connection.storageId)
    do { return try await session.client.publishedLibraryDocument(id, in: session.connection.spaceId) }
    catch {
        guard isPrivateBridgeOffline(error), let document = await store.catalog()?.documents.first(where: { $0.id == id }) else { throw error }
        return document
    }
}

private struct SourceReaderDocument: Decodable {
    struct Attachment: Decodable, Identifiable {
        let id: String
        let title: String
        let fileName: String
        let mimeType: String
        let available: Bool
    }
    let workId: String
    let title: String
    let markdown: String
    let cleanAvailable: Bool
    let originalAvailable: Bool
    let originalMimeType: String?
    let attachments: [Attachment]
}

/// Citation navigation keeps the source identity and page separate from its
/// metadata dossier. Neither opening nor downloading initiates extraction.
struct SourceDocumentReader: View {
    let session: SpaceSession
    let target: SourceDocumentTarget
    @Environment(\.colorScheme) private var colorScheme
    @State private var document: SourceReaderDocument?
    @State private var published: PublishedLibraryDocument?
    @State private var file: PrivateBridgeFileCopy?
    @State private var issue: String?
    @State private var loading = true
    @State private var clean = false
    @State private var selectedAttachment: String?
    @State private var showingDossier = false
    @State private var exportedURL: URL?
    @State private var exportIssue: String?
    @State private var attempt = 0

    init(session: SpaceSession, target: SourceDocumentTarget) {
        self.session = session
        self.target = target
        _selectedAttachment = State(initialValue: target.attachmentId)
    }

    private var requestedPage: Int? {
        // A page locator belongs to its cited file, not every attachment selected later.
        selectedAttachment == target.attachmentId ? target.page : nil
    }

    // Contrast is measured against the surface actually drawn here. The glass
    // surface can be substantially lighter than the app's normal dark cards.
    private var headerBackground: Color { Color(hex: colorScheme == .dark ? "#2c2c2e" : "#f2f2f7") }
    private var headerAccent: Color {
        session.accent.legible(onLuminance: headerBackground.relativeLuminance,
                              towardWhite: colorScheme == .dark, minimumRatio: 4.5)
    }

    private func control(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(minWidth: 44, minHeight: 44) }
    }

    @ViewBuilder private var citationStatus: some View {
        HStack(spacing: 8) {
            if let page = requestedPage, !clean {
                control("Cited page \(page)") { attempt += 1 }.disabled(loading)
            }
            if file?.offline == true {
                Label("Downloaded copy", systemImage: "wifi.slash").foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sourceDetails: some View {
        Button { showingDossier = true } label: {
            Label("Source details", systemImage: "info.circle").frame(minHeight: 44)
        }
    }

    @ViewBuilder private func readingControls(_ document: SourceReaderDocument) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                cleanControl(document); originalControl(document)
                attachmentControl(document); exportControl
            }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 16) { cleanControl(document); originalControl(document) }
                HStack(spacing: 16) { attachmentControl(document); exportControl }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func cleanControl(_ document: SourceReaderDocument) -> some View {
        if document.cleanAvailable { control("Clean Markdown") { selectedAttachment = nil; clean = true; issue = nil } }
    }
    @ViewBuilder private func originalControl(_ document: SourceReaderDocument) -> some View {
        if document.originalAvailable { control("Original") { selectedAttachment = nil; clean = false; attempt += 1 } }
    }
    @ViewBuilder private func attachmentControl(_ document: SourceReaderDocument) -> some View {
        if document.attachments.contains(where: { $0.available }) {
            Menu {
                ForEach(document.attachments.filter(\.available)) { attachment in
                    Button(attachment.title) { selectedAttachment = attachment.id; clean = false; attempt += 1 }
                }
            } label: { Text("Attachments").frame(minWidth: 44, minHeight: 44) }
        }
    }
    @ViewBuilder private var exportControl: some View {
        if clean && document?.cleanAvailable == true || file != nil {
            Button {
                do {
                    if clean, let document {
                        exportedURL = try exportSourceMarkdown(title: document.title, markdown: document.markdown)
                    } else { exportedURL = file?.url }
                } catch { exportIssue = error.localizedDescription }
            } label: { Label("Export", systemImage: "square.and.arrow.up").frame(minHeight: 44) }
                .disabled(loading)
        }
    }

    var body: some View {
        Group {
            if let published {
                PublishedLibraryReader(session: session,
                    store: PublishedLibraryStore(spaceId: session.connection.spaceId, storageId: session.connection.storageId),
                    document: published, initialPage: target.page)
            } else {
                VStack(spacing: 0) {
                    if let document {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(document.title).font(.headline).lineLimit(3)
                                .accessibilityIdentifier("source-document-title")
                            if selectedAttachment != nil, let file {
                                Label(file.descriptor.filename, systemImage: "paperclip").font(.caption).foregroundStyle(.secondary)
                            }
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 16) {
                                    citationStatus; sourceDetails
                                }.fixedSize(horizontal: true, vertical: false)
                                VStack(alignment: .leading, spacing: 4) {
                                    citationStatus; sourceDetails
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            readingControls(document)
                            if let file {
                                CompanionFileDownloadButton(session: session, copy: file,
                                    requiredQueries: [(method: "getLibraryReaderDocument", args: [.string(target.itemId)])])
                            }
                        }.font(.subheadline).buttonStyle(.borderless).tint(headerAccent)
                            .padding(16).background(headerBackground)
                    }
                    if loading {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let issue {
                        ContentUnavailableView {
                            Label("Could not open", systemImage: "doc.badge.ellipsis")
                        } description: { Text(issue) } actions: {
                            Button("Retry") { attempt += 1 }.buttonStyle(.borderedProminent).tint(session.accent)
                            Button("Source details") { showingDossier = true }
                        }
                    } else if clean, let document {
                        ScrollView { CorpusProse(document.markdown, accent: session.accent, session: session).padding(20) }
                            .accessibilityIdentifier("source-document-clean")
                    } else if let file {
                        if file.descriptor.mime == "application/pdf" || file.url.pathExtension.lowercased() == "pdf" {
                            SourceCitationPDF(url: file.url, initialPage: requestedPage)
                        } else if QLPreviewController.canPreview(file.url as NSURL) {
                            SourceFilePreview(url: file.url)
                        } else {
                            ContentUnavailableView("Preview unavailable", systemImage: "doc",
                                description: Text("Export this file to open it in another app."))
                        }
                    } else {
                        ContentUnavailableView("No document available", systemImage: "doc.badge.ellipsis")
                    }
                }
            }
        }
        .navigationTitle(document?.title ?? published?.title ?? String(localized: "Document"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("source-document-reader")
        .task(id: attempt) { await open() }
        .sheet(item: $exportedURL) { ActivityShareSheet(items: [$0]) }
        .alert("Could not export this document", isPresented: Binding(get: { exportIssue != nil }, set: { if !$0 { exportIssue = nil } })) {
            Button("OK", role: .cancel) { exportIssue = nil }
        } message: { Text(exportIssue ?? "") }
        .sheet(isPresented: $showingDossier) {
            NavigationStack {
                RowDetailView(session: session, collection: Collections.byPath["works"], row: Row(["nodus_id": .string(target.itemId)]))
                    .nodusModalClose(accent: session.accent)
            }
        }
    }

    private func open() async {
        let openingAttempt = attempt
        let attachment = selectedAttachment
        let page = requestedPage
        loading = true; issue = nil; file = nil
        defer { if openingAttempt == attempt { loading = false } }
        do {
            try target.validate()
            if session.connection.desktopPairingId == nil {
                published = try await publishedSourceLibraryDocument(session, id: target.itemId)
                return
            }
            let value = try await loadPrivateBridgeValue(session, method: "getLibraryReaderDocument", args: [.string(target.itemId)])
            guard openingAttempt == attempt, !Task.isCancelled else { return }
            guard value != .null else {
                throw APIError(status: 404, code: "source_document_unavailable", message: String(localized: "This source has no readable document on the Mac. Open its details to consult the saved evidence."))
            }
            document = try JSONDecoder.nodus.decode(SourceReaderDocument.self, from: JSONEncoder.nodus.encode(value))
            let downloaded: PrivateBridgeFileCopy?
            if let attachment {
                let identity = try DesktopLibraryAttachmentIdentity.encode(documentId: target.itemId, attachmentId: attachment)
                downloaded = try await loadPrivateBridgeFile(session, kind: .libraryAttachment, id: identity)
            } else if document?.originalAvailable == true {
                downloaded = try await loadPrivateBridgeFile(session, kind: .libraryOriginal, id: target.itemId)
            } else if document?.cleanAvailable == true {
                downloaded = nil
                clean = true
                if page != nil {
                    // A clean copy without an original cannot claim a PDF page jump.
                    issue = String(localized: "The original needed for this page citation is unavailable. The clean reading copy can still be opened.")
                }
            } else {
                throw APIError(status: 404, code: "source_document_unavailable", message: String(localized: "No document available"))
            }
            guard openingAttempt == attempt, !Task.isCancelled else { return }
            file = downloaded
            if let file {
                let isPDF = file.descriptor.mime == "application/pdf" || file.url.pathExtension.lowercased() == "pdf"
                let pdf = isPDF ? PDFDocument(url: file.url) : nil
                if isPDF, pdf == nil || pdf?.pageCount == 0 {
                    throw APIError(status: 422, code: "source_pdf_unreadable", message: String(localized: "The PDF could not be read. Open the source details or retry the download."))
                }
                if let page, pdf == nil || page > (pdf?.pageCount ?? 0) {
                    throw APIError(status: 422, code: "citation_page_unavailable", message: String(localized: "The cited page is not available in this document."))
                }
            }
        } catch {
            if openingAttempt == attempt, !Task.isCancelled { issue = error.localizedDescription }
        }
    }
}

/// PDFKit can reset the page while its initially unattached view is laid out.
/// Apply the citation after the view has a window and a usable reading frame.
final class SourceCitationPDFView: PDFView {
    private var pendingCitation: PDFPage?

    func open(_ document: PDFDocument?, at pageNumber: Int?) {
        pendingCitation = nil
        self.document = document
        if let pageNumber { pendingCitation = document?.page(at: pageNumber - 1) }
        setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard window != nil, bounds.width > 0, bounds.height > 0,
              let page = pendingCitation, page.document === document else { return }
        pendingCitation = nil
        go(to: page)
    }
}

struct SourceCitationPDF: UIViewRepresentable {
    let url: URL
    let initialPage: Int?

    @MainActor final class Coordinator: NSObject {
        weak var view: PDFView?
        func observe(_ view: PDFView) {
            self.view = view
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
        }
        @objc private func pageChanged(_ notification: Notification) { updatePage() }
        func updatePage() {
            guard let view, let document = view.document, let page = view.currentPage else { return }
            view.accessibilityValue = String(localized: "Page \(document.index(for: page) + 1) of \(document.pageCount)")
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> SourceCitationPDFView {
        let view = SourceCitationPDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical; view.backgroundColor = .secondarySystemBackground
        view.accessibilityIdentifier = "source-citation-pdf"
        context.coordinator.observe(view)
        return view
    }
    func updateUIView(_ view: SourceCitationPDFView, context: Context) {
        guard view.document?.documentURL != url else { return }
        view.open(PDFDocument(url: url), at: initialPage)
        context.coordinator.updatePage()
    }
}

private struct SourceFilePreview: UIViewControllerRepresentable {
    let url: URL
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let view = QLPreviewController(); view.dataSource = context.coordinator
        view.view.accessibilityIdentifier = "source-file-preview"
        return view
    }
    func updateUIViewController(_ view: QLPreviewController, context: Context) {
        if context.coordinator.url != url { context.coordinator.url = url; view.reloadData() }
    }
}
