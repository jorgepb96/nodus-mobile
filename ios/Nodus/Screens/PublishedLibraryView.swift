import NodusKit
import NodusUI
import PDFKit
import QuickLook
import SwiftUI
import UIKit
import WebKit

struct PublishedLibraryView: View {
    @Environment(WorkspaceTabs.self) private var workspaceTabs

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
    @State private var metadataDocument: PublishedLibraryDocument?

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
        let allowedCollections = selectedCollectionIds
        return documents.filter { document in
            if let allowedCollections, document.collectionIds.allSatisfy({ !allowedCollections.contains($0) }) { return false }
            guard !needle.isEmpty else { return true }
            return ([document.title, document.abstract ?? ""] + document.creators + document.tags)
                .joined(separator: "\n").localizedLowercase.contains(needle)
        }
    }

    private var selectedCollectionIds: Set<String>? {
        guard let collectionId else { return nil }
        var result: Set<String> = [collectionId]
        var changed = true
        while changed {
            changed = false
            for collection in collections where collection.parentId.map(result.contains) == true && !result.contains(collection.id) {
                result.insert(collection.id); changed = true
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTabStrip(
                section: "library",
                catalogueTitle: "Library",
                catalogueImage: "books.vertical",
                accent: session.accent
            )
            ZStack {
                catalogue
                    .opacity(workspaceTabs.activeTabId(in: "library") == nil ? 1 : 0)
                    .allowsHitTesting(workspaceTabs.activeTabId(in: "library") == nil)
                    .accessibilityHidden(workspaceTabs.activeTabId(in: "library") != nil)

                ForEach(workspaceTabs.tabs(in: "library")) { tab in
                    if case .libraryDocument(let document) = tab.payload {
                        PublishedLibraryReader(session: session, store: store, document: document)
                            .opacity(workspaceTabs.activeTabId(in: "library") == tab.id ? 1 : 0)
                            .allowsHitTesting(workspaceTabs.activeTabId(in: "library") == tab.id)
                            .accessibilityHidden(workspaceTabs.activeTabId(in: "library") != tab.id)
                    }
                }
            }
        }
        .accessibilityIdentifier("workspace-library")
    }

    private var catalogue: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                DesktopPageHeader(
                    title: "Library",
                    subtitle: loading && documents.isEmpty
                        ? "Loading published catalogue…"
                        : "\(visible.count) documents · \(collectionName)",
                    systemImage: "books.vertical",
                    accent: session.accent
                )
                NodusSearchField(text: $query, prompt: "Search title, author or tag", accent: session.accent, isBusy: loading)
                libraryControlBar
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
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
            .nodusTopAnchor()
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .nodusHidesBottomBar()
        .toolbar {
            ToolbarItem(placement: .principal) {
                Menu {
                    Button { collectionId = nil } label: {
                        if collectionId == nil { Label("All collections", systemImage: "checkmark") }
                        else { Text("All collections") }
                    }
                    LibraryCollectionMenuItems(collections: collections, parentId: nil, selection: $collectionId)
                } label: {
                    VStack(spacing: 1) {
                        Text("Library").font(.caption2).foregroundStyle(.secondary)
                        Label(collectionName, systemImage: "folder")
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                }
                .accessibilityLabel("Collection: \(collectionName)")
            }
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
        .sheet(item: $metadataDocument) { document in
            LibraryMetadataSheet(document: document, accent: session.accent)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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
            Text(collectionName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var libraryControlBar: some View {
        HStack(spacing: 10) {
            Menu {
                Button { collectionId = nil } label: {
                    if collectionId == nil { Label("All collections", systemImage: "checkmark") }
                    else { Text("All collections") }
                }
                LibraryCollectionMenuItems(collections: collections, parentId: nil, selection: $collectionId)
            } label: {
                Label(collectionName, systemImage: "folder")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(NodusGlassButtonStyle(accent: session.accent))

            Spacer(minLength: 8)

            if selecting, !selection.isEmpty {
                Button(role: .destructive) { requestDeletion(.documents(selection)) } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(NodusGlassButtonStyle(accent: .red))
            }
            Button(selecting ? "Done" : "Select") {
                selecting.toggle(); if !selecting { selection.removeAll() }
            }
            .buttonStyle(NodusGlassButtonStyle(accent: session.accent))

            Menu {
                Button(role: .destructive) { requestDeletion(.space) } label: { Label("Delete all downloads in this space", systemImage: "trash") }
                Button(role: .destructive) { requestDeletion(.everySpace) } label: { Label("Delete all library downloads", systemImage: "trash.slash") }
            } label: {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(NodusGlassIconButtonStyle(accent: session.accent))
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
                    Text(document.itemType.replacingOccurrences(of: "-", with: " ")).textCase(.uppercase)
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
            Button { open(document) } label: { card }
                .buttonStyle(NodusCardButtonStyle())
                .accessibilityIdentifier("workspace-open-library-\(safeIdentifier(document.id))")
                .contextMenu {
                    Button { metadataDocument = document } label: { Label("View metadata", systemImage: "info.circle") }
                    Button { copyReference(document) } label: { Label("Copy reference", systemImage: "doc.on.doc") }
                    if downloaded.contains(document.id) {
                        Button(role: .destructive) { requestDeletion(.documents(Set([document.id]))) } label: { Label("Delete download", systemImage: "trash") }
                    }
                }
        }
    }

    private func open(_ document: PublishedLibraryDocument) {
        workspaceTabs.open(
            WorkspaceTab(
                id: "library:\(document.id)",
                title: document.title,
                systemImage: "doc.text",
                kind: .document,
                payload: .libraryDocument(document)
            ),
            in: "library"
        )
    }

    private func safeIdentifier(_ value: String) -> String {
        value.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
    }

    private func copyReference(_ document: PublishedLibraryDocument) {
        UIPasteboard.general.string = document.reference ?? document.title
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
#if DEBUG
            if ProcessInfo.processInfo.environment["NODUS_SHOW_TAB_DEMO"] == "1",
               workspaceTabs.tabs(in: "library").isEmpty {
                for document in documents.prefix(2) { open(document) }
            }
#endif
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

private struct LibraryCollectionMenuItems: View {
    let collections: [PublishedLibraryCollection]
    let parentId: String?
    @Binding var selection: String?

    private var children: [PublishedLibraryCollection] {
        collections.filter { $0.parentId == parentId }
            .sorted { $0.position == $1.position ? $0.name < $1.name : $0.position < $1.position }
    }

    var body: some View {
        ForEach(children) { collection in
            let descendants = collections.filter { $0.parentId == collection.id }
            if descendants.isEmpty {
                Button { selection = collection.id } label: {
                    if selection == collection.id { Label(collection.name, systemImage: "checkmark") }
                    else { Label(collection.name, systemImage: "folder") }
                }
            } else {
                Menu(collection.name, systemImage: "folder") {
                    Button { selection = collection.id } label: {
                        if selection == collection.id { Label("All in \(collection.name)", systemImage: "checkmark") }
                        else { Text("All in \(collection.name)") }
                    }
                    LibraryCollectionMenuItems(collections: collections, parentId: collection.id, selection: $selection)
                }
            }
        }
    }
}

private struct LibraryMetadataSheet: View {
    let document: PublishedLibraryDocument
    let accent: Color
    @Environment(\.dismiss) private var dismiss

    private var fields: [(String, String?)] {
        [
            (String(localized: "Type"), document.itemType.replacingOccurrences(of: "-", with: " ")),
            (String(localized: "Authors"), document.creators.isEmpty ? nil : document.creators.joined(separator: ", ")),
            (String(localized: "Date"), document.date ?? document.year.map(String.init)),
            (String(localized: "Publication"), document.publicationTitle),
            (String(localized: "Publisher"), document.publisher),
            (String(localized: "Volume"), document.volume),
            (String(localized: "Issue"), document.issue),
            (String(localized: "Pages"), document.pages),
            (String(localized: "Edition"), document.edition),
            (String(localized: "Place"), document.place),
            ("DOI", document.doi), ("PMID", document.pmid), ("PMCID", document.pmcid), ("arXiv", document.arxiv),
            ("ISBN", document.isbn?.joined(separator: ", ")), ("ISSN", document.issn?.joined(separator: ", ")),
            (String(localized: "Language"), document.language),
            (String(localized: "Citation key"), document.citationKey),
            (String(localized: "Rights"), document.rights),
        ]
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(document.title).font(.headline)
                    if let abstract = document.abstract, !abstract.isEmpty { Text(abstract).font(.subheadline).foregroundStyle(.secondary) }
                }
                Section("Bibliographic reference") {
                    Text(document.reference ?? document.title).textSelection(.enabled)
                    Button { UIPasteboard.general.string = document.reference ?? document.title } label: {
                        Label("Copy reference", systemImage: "doc.on.doc")
                    }.tint(accent)
                }
                Section("Metadata") {
                    ForEach(fields.filter { $0.1?.isEmpty == false }, id: \.0) { label, value in
                        LabeledContent(label) { Text(value ?? "").multilineTextAlignment(.trailing).textSelection(.enabled) }
                    }
                    if !document.tags.isEmpty { LabeledContent("Tags") { Text(document.tags.joined(separator: ", ")).multilineTextAlignment(.trailing) } }
                    if let url = document.url, let destination = URL(string: url) { Link(destination: destination) { Label("Open URL", systemImage: "arrow.up.right.square") } }
                }
            }
            .navigationTitle("Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct PublishedLibraryReader: View {
    let session: SpaceSession
    let store: PublishedLibraryStore
    let document: PublishedLibraryDocument

    @State private var markdown: String?
    @State private var figures: [URL] = []
    @State private var originalURL: URL?
    @State private var packageURL: URL?
    @State private var failure: String?
    @State private var source: ReadingSource
    @State private var showingMetadata = false

    private enum ReadingSource: String, CaseIterable, Identifiable {
        case clean, original
        var id: String { rawValue }
    }

    init(session: SpaceSession, store: PublishedLibraryStore, document: PublishedLibraryDocument) {
        self.session = session; self.store = store; self.document = document
        _source = State(initialValue: document.cleanAvailable ? .clean : .original)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(document.title).font(.headline).lineLimit(2)
                        if !document.creators.isEmpty { Text(document.creators.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    Button { showingMetadata = true } label: { Image(systemName: "info.circle") }
                }
                if markdown != nil && originalURL != nil {
                    Picker("Reading format", selection: $source) {
                        Label("Clean Markdown", systemImage: "text.alignleft").tag(ReadingSource.clean)
                        Label("Original", systemImage: "doc.richtext").tag(ReadingSource.original)
                    }.pickerStyle(.segmented)
                }
                HStack(spacing: 14) {
                    Button { UIPasteboard.general.string = document.reference ?? document.title } label: { Label("Copy reference", systemImage: "doc.on.doc") }
                    if let packageURL { ShareLink(item: packageURL) { Label("Export", systemImage: "square.and.arrow.up") } }
                }.font(.caption.weight(.semibold)).tint(session.accent)
            }
            .padding(.horizontal, NodusSpace.page).padding(.vertical, 10)
            .background(.ultraThinMaterial)

            if let failure {
                NodusNotice(tone: .blocked, title: "Could not open", message: LocalizedStringKey(failure)).padding(NodusSpace.page)
                Spacer()
            } else if markdown == nil && originalURL == nil {
                ProgressView().tint(session.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if source == .clean, let markdown {
                LibraryCleanReader(session: session, document: document, markdown: markdown, figures: figures)
            } else if source == .original, let originalURL {
                LibraryOriginalReader(session: session, document: document, url: originalURL)
            } else {
                ContentUnavailableView("Format unavailable", systemImage: "doc.badge.ellipsis")
            }
        }
        .nodusPageFunctions(accent: session.accent, chat: PageChatSubject(id: document.libraryDraftId, title: document.title, session: session))
        .nodusHidesBottomBar()
        .navigationTitle("Document")
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .sheet(isPresented: $showingMetadata) {
            LibraryMetadataSheet(document: document, accent: session.accent)
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .task { await open() }
    }

    private func open() async {
        do {
            let prepared = try await store.prepare(document, using: session.client)
            markdown = prepared.markdown
            originalURL = prepared.original
            figures = await store.figures(document.id)
            packageURL = prepared.package
            if source == .clean, markdown == nil { source = .original }
            if source == .original, originalURL == nil { source = .clean }
        } catch { failure = error.localizedDescription }
    }
}

private struct LibraryCleanReader: View {
    let session: SpaceSession
    let document: PublishedLibraryDocument
    let markdown: String
    let figures: [URL]
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ReportActions(markdown: markdown, title: document.title, accent: session.accent)
                CorpusProse(markdown, accent: session.accent, session: session)
                    .padding(ReportLayout.sectionPadding).frame(maxWidth: .infinity, alignment: .leading)
                    .nodusGlass(NodusGlass(.regular, tint: session.accent)).nodusSearchOrder(1)
                ForEach(Array(figures.enumerated()), id: \.element) { index, figure in
                    LibraryFigure(url: figure).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)).nodusSearchOrder(index + 2)
                }
            }
            .padding(NodusSpace.page).frame(maxWidth: ReportLayout.readerMeasure).frame(maxWidth: .infinity).nodusTopAnchor()
        }
        .nodusReadingStyle(ReadingStyle(scale: preferences.readingScale, document: true))
        .modifier(SyncedReportReadingTools(
            session: session, id: document.libraryDraftId,
            rows: document.annotationRows(for: "library-clean"), scope: "library-clean",
            annotationPrefix: document.libraryAnnotationRoutingPrefix
        ))
    }
}

private struct LibraryOriginalReader: View {
    let session: SpaceSession
    let document: PublishedLibraryDocument
    let url: URL
    @State private var text: String?

    private var extensionName: String { url.pathExtension.lowercased() }
    private var isText: Bool { ["md", "markdown", "txt", "csv", "tsv", "xml", "jats", "html", "htm"].contains(extensionName) }

    var body: some View {
        Group {
            if extensionName == "pdf" {
                LibraryPDFOriginalReader(session: session, document: document, url: url)
            } else if isText {
                ScrollView {
                    if let text {
                        CorpusProse(text, accent: session.accent, session: session)
                            .padding(ReportLayout.sectionPadding).frame(maxWidth: ReportLayout.readerMeasure).frame(maxWidth: .infinity)
                            .nodusGlass(NodusGlass(.regular, tint: session.accent)).padding(NodusSpace.page)
                    } else { ProgressView().tint(session.accent).padding() }
                }
                .modifier(SyncedReportReadingTools(
                    session: session, id: document.libraryDraftId,
                    rows: document.annotationRows(for: "library-original"), scope: "library-original",
                    annotationPrefix: document.libraryAnnotationRoutingPrefix
                ))
                .task { text = try? String(contentsOf: url, encoding: .utf8) }
            } else if ["png", "jpg", "jpeg", "webp", "gif", "bmp", "svg", "tif", "tiff"].contains(extensionName) {
                ScrollView { LibraryFigure(url: url).padding(NodusSpace.page) }
            } else {
                LibraryQuickLookPreview(url: url)
            }
        }
    }
}

private struct PDFOriginalHighlight: Sendable {
    let id: String
    let page: Int
    let start: Int
    let end: Int
    let text: String
}

private struct LibraryPDFOriginalReader: View {
    let session: SpaceSession
    let document: PublishedLibraryDocument
    let url: URL
    @State private var hasSelection = false
    @State private var highlightRequest = 0
    @State private var syncMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Select text in the PDF to highlight it", systemImage: "text.cursor")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { highlightRequest += 1 } label: { Label("Highlight", systemImage: "highlighter") }
                    .buttonStyle(.borderedProminent).tint(session.accent).disabled(!hasSelection)
            }
            .padding(.horizontal, NodusSpace.page).padding(.vertical, 8).background(.thinMaterial)
            LibraryPDFView(
                url: url,
                annotations: document.annotations.filter { $0.scope == "original" },
                highlightRequest: highlightRequest,
                onSelectionChanged: { hasSelection = $0 },
                onHighlight: sync
            )
        }
        .alert("The highlight is waiting on this device", isPresented: Binding(
            get: { syncMessage != nil }, set: { if !$0 { syncMessage = nil } }
        )) { Button("OK") { syncMessage = nil } } message: { Text(syncMessage ?? "") }
    }

    private func sync(_ highlight: PDFOriginalHighlight) {
        let target = "{\"type\":\"text\",\"attachmentId\":\"original\",\"page\":\(highlight.page)}"
        let timestamp = ISO8601DateFormatter.nodusFractional.string(from: Date())
        let rowId = document.libraryAnnotationRoutingPrefix + highlight.id
        let row: [String: JSONValue] = [
            "id": .string(rowId), "draft_id": .string(document.libraryDraftId),
            "scope": .string("library-original"), "kind": .string("highlight"), "color": .string("yellow"),
            "start_offset": .int(Int64(highlight.start)), "end_offset": .int(Int64(highlight.end)),
            "selected_text": .string(highlight.text), "prefix": .string(""), "suffix": .string(""),
            "comment_text": .null, "target_json": .string(target),
            "created_at": .string(timestamp), "updated_at": .string(timestamp),
        ]
        Task {
            guard let outbox = await OutboxController.open(session: session) else {
                syncMessage = String(localized: "Your access to this space is read only."); return
            }
            _ = await outbox.syncReaderAnnotation(kind: .upsert, rowId: rowId, row: row, title: String(localized: "Add PDF highlight"))
            if let error = outbox.lastError { syncMessage = error }
        }
    }
}

private struct LibraryPDFView: UIViewRepresentable {
    let url: URL
    let annotations: [PublishedLibraryAnnotation]
    let highlightRequest: Int
    let onSelectionChanged: (Bool) -> Void
    let onHighlight: (PDFOriginalHighlight) -> Void

    @MainActor
    final class Coordinator: NSObject {
        var parent: LibraryPDFView
        weak var view: PDFView?
        var handledRequest = 0
        var installed = Set<String>()

        init(parent: LibraryPDFView) { self.parent = parent }

        func attach(_ view: PDFView) {
            self.view = view
            NotificationCenter.default.addObserver(self, selector: #selector(selectionDidChange), name: .PDFViewSelectionChanged, object: view)
        }

        @objc private func selectionDidChange() {
            parent.onSelectionChanged(!(view?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
        }

        func installPublished() {
            guard let document = view?.document else { return }
            for item in parent.annotations where item.kind == "highlight" && !installed.contains(item.id) {
                guard let pageNumber = item.target?.page, pageNumber > 0, pageNumber <= document.pageCount,
                      let page = document.page(at: pageNumber - 1), let source = page.string else { continue }
                let text = source as NSString
                let range = NSRange(location: item.startOffset, length: item.endOffset - item.startOffset)
                guard range.location >= 0, range.length > 0, NSMaxRange(range) <= text.length,
                      text.substring(with: range) == item.selectedText,
                      let selection = page.selection(for: range) else { continue }
                let annotation = PDFAnnotation(bounds: selection.bounds(for: page), forType: .highlight, withProperties: nil)
                annotation.color = UIColor.systemYellow.withAlphaComponent(0.45)
                annotation.userName = "nodus:\(item.id)"
                page.addAnnotation(annotation); installed.insert(item.id)
            }
        }

        func addHighlight() {
            guard let view, let selection = view.currentSelection,
                  let selected = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty,
                  let page = selection.pages.first, let document = view.document else { return }
            let pageNumber = document.index(for: page) + 1
            guard pageNumber > 0, let source = page.string else { return }
            let pageText = source as NSString
            let range = pageText.range(of: selected)
            guard range.location != NSNotFound, range.length == (selected as NSString).length else { return }
            let id = UUID().uuidString
            let annotation = PDFAnnotation(bounds: selection.bounds(for: page), forType: .highlight, withProperties: nil)
            annotation.color = UIColor.systemYellow.withAlphaComponent(0.45); annotation.userName = "nodus:\(id)"
            page.addAnnotation(annotation); installed.insert(id)
            _ = document.write(to: parent.url)
            view.clearSelection()
            parent.onSelectionChanged(false)
            parent.onHighlight(.init(id: id, page: pageNumber, start: range.location, end: NSMaxRange(range), text: selected))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical; view.displaysPageBreaks = true; view.backgroundColor = .secondarySystemBackground
        view.document = PDFDocument(url: url); context.coordinator.attach(view); context.coordinator.installPublished()
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.installPublished()
        if highlightRequest != context.coordinator.handledRequest {
            context.coordinator.handledRequest = highlightRequest; context.coordinator.addHighlight()
        }
    }
}

private struct LibraryQuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
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
