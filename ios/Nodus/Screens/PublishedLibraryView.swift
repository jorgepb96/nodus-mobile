import NodusKit
import NodusUI
import SwiftUI
import UIKit
import WebKit

struct PublishedLibraryView: View {
    let session: SpaceSession

    @State private var store: PublishedLibraryStore
    @State private var collections: [PublishedLibraryCollection] = []
    @State private var documents: [PublishedLibraryDocument] = []
    @State private var downloaded: Set<String> = []
    @State private var query = ""
    @State private var collectionId: String?
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var loading = true
    @State private var error: String?
    @State private var pendingDeletion: Deletion?
    @State private var showingDeletionConfirmation = false

    private enum Deletion {
        case documents(Set<String>)
        case space
        case everySpace
    }

    init(session: SpaceSession) {
        self.session = session
        _store = State(initialValue: PublishedLibraryStore(spaceId: session.connection.spaceId))
    }

    private var visible: [PublishedLibraryDocument] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        return documents.filter { document in
            if let collectionId, !document.collectionIds.contains(collectionId) { return false }
            guard !needle.isEmpty else { return true }
            return ([document.title, document.abstract ?? ""] + document.creators + document.tags)
                .joined(separator: "\n").localizedLowercase.contains(needle)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                filterBar
                if loading, documents.isEmpty { ProgressView().tint(session.accent).frame(maxWidth: .infinity) }
                if let error, documents.isEmpty {
                    NodusNotice(tone: .caution, title: "Could not update the library", message: LocalizedStringKey(error))
                }
                ForEach(visible) { document in row(document) }
                if !loading, visible.isEmpty {
                    ContentUnavailableView("No documents", systemImage: "books.vertical", description: Text("Try another search or collection."))
                }
            }
            .padding(NodusSpace.page)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .nodusTopAnchor()
        }
        .searchable(text: $query, prompt: "Search title, author or tag")
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .nodusHidesBottomBar()
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if selecting, !selection.isEmpty {
                    Button(role: .destructive) { requestDeletion(.documents(selection)) } label: { Image(systemName: "trash") }
                }
                Button(selecting ? "Done" : "Select") {
                    selecting.toggle(); if !selecting { selection.removeAll() }
                }
                Menu {
                    Button(role: .destructive) { requestDeletion(.space) } label: { Label("Delete all downloads in this space", systemImage: "trash") }
                    Button(role: .destructive) { requestDeletion(.everySpace) } label: { Label("Delete all library downloads", systemImage: "trash.slash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .confirmationDialog("Delete downloaded copies?", isPresented: $showingDeletionConfirmation, titleVisibility: .visible) {
            Button(deletionButtonTitle, role: .destructive) { confirmDeletion() }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Only files stored on this device will be removed. The catalogue, annotations and server publication are preserved.")
        }
        .refreshable { await load(remoteOnly: true) }
        .task(id: session.publishedRevision) { await load(remoteOnly: false) }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Label("\(visible.count) documents", systemImage: "books.vertical")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("All collections") { collectionId = nil }
                ForEach(collections) { collection in
                    Button { collectionId = collection.id } label: {
                        if collectionId == collection.id { Label(collection.name, systemImage: "checkmark") }
                        else { Text(collection.name) }
                    }
                }
            } label: {
                Label(collectionName, systemImage: "line.3.horizontal.decrease.circle")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 11).frame(minHeight: 38)
                    .reportActionSurface(accent: session.accent)
            }
        }
    }

    private var collectionName: String {
        guard let collectionId else { return String(localized: "All collections") }
        return collections.first { $0.id == collectionId }?.name ?? String(localized: "Collection")
    }

    @ViewBuilder
    private func row(_ document: PublishedLibraryDocument) -> some View {
        let card = HStack(alignment: .top, spacing: 12) {
            if selecting {
                Image(systemName: selection.contains(document.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(selection.contains(document.id) ? session.accent : .secondary)
            } else {
                Image(systemName: downloaded.contains(document.id) ? "checkmark.icloud.fill" : "doc.text")
                    .font(.title3).foregroundStyle(session.accent.nodusReadable).frame(width: 25)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(document.title).font(.headline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                if !document.creators.isEmpty {
                    Text(document.creators.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 10) {
                    if let year = document.year { Label("\(year)", systemImage: "calendar") }
                    Label("\(document.wordCount.formatted()) words", systemImage: "text.word.spacing")
                    if document.figureCount > 0 { Label("\(document.figureCount)", systemImage: "photo") }
                }.font(.caption2).foregroundStyle(.tertiary)
                if !document.tags.isEmpty {
                    Text(document.tags.prefix(4).map { "#\($0)" }.joined(separator: "  "))
                        .font(.caption2).foregroundStyle(session.accent.nodusReadable).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if !selecting { Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .padding(NodusSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nodusGlass(NodusGlass(.regular, tint: session.accent), in: NodusRadius.panelShape)

        if selecting {
            Button { toggle(document.id) } label: { card }.buttonStyle(.plain)
        } else {
            NavigationLink { PublishedLibraryReader(session: session, store: store, document: document) } label: { card }
                .buttonStyle(NodusCardButtonStyle())
                .contextMenu {
                    if downloaded.contains(document.id) {
                        Button(role: .destructive) { requestDeletion(.documents(Set([document.id]))) } label: { Label("Delete download", systemImage: "trash") }
                    }
                }
        }
    }

    private func toggle(_ id: String) { if !selection.insert(id).inserted { selection.remove(id) } }
    private var deletionButtonTitle: String {
        switch pendingDeletion {
        case .documents(let ids): return ids.count == 1 ? String(localized: "Delete download") : String(localized: "Delete selected downloads")
        case .space: return String(localized: "Delete all in this space")
        case .everySpace: return String(localized: "Delete all library downloads")
        case nil: return String(localized: "Delete")
        }
    }
    private func requestDeletion(_ deletion: Deletion) {
        pendingDeletion = deletion
        showingDeletionConfirmation = true
    }
    private func confirmDeletion() {
        switch pendingDeletion {
        case .documents(let ids):
            remove(ids); selection.subtract(ids)
            if selection.isEmpty { selecting = false }
        case .space:
            remove(downloaded)
        case .everySpace:
            try? PublishedLibraryStore.removeAllSpaces()
            downloaded.removeAll()
        case nil:
            break
        }
        pendingDeletion = nil
    }
    private func remove(_ ids: Set<String>) {
        Task { await store.remove(ids); downloaded.subtract(ids) }
    }

    private func load(remoteOnly: Bool) async {
        loading = true
        if !remoteOnly, let cached = await store.catalog() {
            collections = cached.collections; documents = cached.documents
        }
        downloaded = Set(await store.allDownloads().map(\.id))
        do {
            async let foundCollections = session.client.publishedLibraryCollections(in: session.connection.spaceId)
            var all: [PublishedLibraryDocument] = []
            var offset = 0
            while true {
                let page = try await session.client.publishedLibraryDocuments(in: session.connection.spaceId, limit: 200, offset: offset)
                all.append(contentsOf: page.items)
                if !page.hasMore { break }
                offset += page.items.count
            }
            collections = try await foundCollections
            documents = all
            await store.saveCatalog(collections: collections, documents: documents)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

private struct PublishedLibraryReader: View {
    let session: SpaceSession
    let store: PublishedLibraryStore
    let document: PublishedLibraryDocument

    @Environment(AppPreferences.self) private var preferences
    @State private var markdown: String?
    @State private var figures: [URL] = []
    @State private var packageURL: URL?
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    PageText(document.title, order: 0).font(.title3.weight(.semibold))
                    if !document.creators.isEmpty { Text(document.creators.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary) }
                    HStack(spacing: 12) {
                        Label("\(document.wordCount.formatted()) words", systemImage: "text.alignleft")
                        if document.figureCount > 0 { Label("\(document.figureCount) figures", systemImage: "photo") }
                    }.font(.caption).foregroundStyle(.secondary)
                    if let markdown { ReportActions(markdown: markdown, title: document.title, accent: session.accent) }
                    if let packageURL { ShareLink(item: packageURL) { Label("Export package", systemImage: "square.and.arrow.up") } }
                }
                .padding(NodusSpace.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .nodusGlass(NodusGlass(.regular, tint: session.accent))
                .nodusSearchOrder(0)

                if let failure { NodusNotice(tone: .blocked, title: "Could not open", message: LocalizedStringKey(failure)) }
                if let markdown {
                    CorpusProse(markdown, accent: session.accent, session: session)
                        .padding(ReportLayout.sectionPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .nodusGlass(NodusGlass(.regular, tint: session.accent))
                        .nodusSearchOrder(1)
                } else if failure == nil { ProgressView().tint(session.accent).frame(maxWidth: .infinity) }

                ForEach(Array(figures.enumerated()), id: \.element) { index, figure in
                    LibraryFigure(url: figure)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .nodusSearchOrder(index + 2)
                }

                if document.originalAvailable {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(document.originalFileName ?? String(localized: "Original document")).font(.subheadline.weight(.semibold))
                            Text("The original file will be available in a future version.").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                    .padding(NodusSpace.cardPadding).frame(maxWidth: .infinity, alignment: .leading)
                    .nodusGlass(NodusGlass(.thin, tint: session.accent))
                }
            }
            .padding(NodusSpace.page)
            .frame(maxWidth: ReportLayout.readerMeasure).frame(maxWidth: .infinity)
            .nodusTopAnchor()
        }
        .nodusReadingStyle(ReadingStyle(scale: preferences.readingScale, document: true))
        .nodusPageFunctions(accent: session.accent, chat: PageChatSubject(id: document.libraryDraftId, title: document.title, session: session))
        .nodusHidesBottomBar()
        .navigationTitle("Document")
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .modifier(SyncedReportReadingTools(
            session: session,
            id: document.libraryDraftId,
            rows: document.annotationRows,
            scope: "library",
            annotationPrefix: document.libraryAnnotationRoutingPrefix
        ))
        .task { await open() }
    }

    private func open() async {
        do {
            markdown = try await store.download(document, using: session.client)
            figures = await store.figures(document.id)
            packageURL = await store.packageURL(document.id)
        } catch { failure = error.localizedDescription }
    }
}

private struct LibraryFigure: View {
    let url: URL
    var body: some View {
        if url.pathExtension.lowercased() == "svg", let source = try? String(contentsOf: url, encoding: .utf8) {
            LibrarySVGFigure(source: source)
                .aspectRatio(Self.aspectRatio(source), contentMode: .fit)
                .frame(maxWidth: .infinity)
        } else if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
        } else {
            Label(url.lastPathComponent, systemImage: "photo").padding().frame(maxWidth: .infinity)
                .background(.thinMaterial)
        }
    }

    private static func aspectRatio(_ source: String) -> CGFloat {
        guard let expression = try? NSRegularExpression(pattern: #"viewBox\s*=\s*[\"']\s*[-+\d.]+[ ,]+[-+\d.]+[ ,]+([-+\d.]+)[ ,]+([-+\d.]+)"#, options: .caseInsensitive),
              let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let widthRange = Range(match.range(at: 1), in: source),
              let heightRange = Range(match.range(at: 2), in: source),
              let width = Double(source[widthRange]), let height = Double(source[heightRange]),
              width > 0, height > 0 else { return 4 / 3 }
        return CGFloat(width / height)
    }
}

/// SVGs are displayed in an isolated, script-free web view. The CSP also blocks remote images,
/// fonts and other resources, so an imported figure cannot turn reading a document into a
/// network request.
private struct LibrarySVGFigure: UIViewRepresentable {
    let source: String

    final class Coordinator {
        var loadedSource: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedSource != source else { return }
        context.coordinator.loadedSource = source
        let html = """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}body{display:flex;align-items:center;justify-content:center}svg{display:block;max-width:100%;max-height:100%;width:100%;height:auto}</style>
        </head><body>\(source)</body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
}
