import NodusKit
import NodusUI
import SwiftUI

/// A table that only exists offline.
///
/// Worldbuilding is the case that makes this necessary: a published world carries scenes,
/// articles, factions, cultures, threads, rules and character profiles, and the REST surface
/// projects none of them. Without the mirror the app could search a world and never list it.
struct MirrorTableView: View {
    struct Filter: Hashable {
        let field: String
        let values: [String]

        func includes(_ row: Row) -> Bool {
            guard let value = row.string(field) else { return false }
            return values.contains(value)
        }
    }

    let session: SpaceSession
    let table: String
    let title: String
    var filter: Filter? = nil

    @State private var rows: [Row] = []
    @State private var total = 0
    @State private var query = ""
    @State private var sort: MirrorStore.SortOrder = .published
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var isDownloading = false
    @State private var loading = false
    @State private var requestID = UUID()
    @State private var loadedQuery = ""
    @State private var loadedSort: MirrorStore.SortOrder = .published
    @State private var lastPage: Page<Row>?

    private var presenter: RowPresenter { RowPresenter.forTable(table) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 9) {
                if session.mirror == nil {
                    VStack(spacing: 14) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 34))
                            .foregroundStyle(session.accent)
                        Text("Keep an offline copy to open this section")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text("Desktop publishes this workspace inside the snapshot rather than as a public collection. The downloaded copy stays on this device and refreshes with the vault.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 520)
                        Button {
                            Task {
                                isDownloading = true
                                await session.downloadMirror()
                                isDownloading = false
                                await reload()
                            }
                        } label: {
                            Label(isDownloading ? "Downloading…" : "Keep offline copy", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent))
                        .disabled(isDownloading)
                    }
                    .padding(.vertical, 64)
                    .frame(maxWidth: .infinity)
                } else {
                    if let error {
                        NodusNotice(tone: .blocked, title: "Could not read the mirror", message: LocalizedStringKey(error))
                        Button("Retry") { Task { await reload() } }
                            .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        NavigationLink {
                            RowDetailView(session: session, collection: nil, row: row, title: title)
                        } label: {
                            RowCell(row: row, presenter: presenter, accent: session.accent)
                                .desktopContentRow(accent: session.accent)
                        }
                        .buttonStyle(NodusCardButtonStyle())
                    }
                    if rows.count < total, filter == nil, error == nil {
                        HStack { Spacer(); ProgressView().tint(session.accent); Spacer() }
                            .padding()
                            .task(id: rows.count) { await loadMore() }
                    }
                    if loading, rows.isEmpty { ProgressView().tint(session.accent).padding() }
                    if rows.isEmpty, error == nil, !loading {
                        ContentUnavailableView(
                            query.isEmpty ? "Nothing here" : "No matches",
                            systemImage: presenter.icon
                        )
                        .padding(.vertical, 42)
                    }
                }
            }
            .padding(NodusSpace.page)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
            .nodusTopAnchor()
        }
        .nodusDismissesKeyboard()
        .navigationTitle(Text(LocalizedStringKey(title)))
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 7) {
                HStack(spacing: 10) {
                    DesktopPageHeader(
                        title: LocalizedStringKey(title),
                        subtitle: session.mirror == nil ? "Offline snapshot required" : "\(total) published records",
                        systemImage: presenter.icon,
                        accent: session.accent
                    )
                    if session.mirror != nil { sortMenu }
                }
                .padding(.horizontal, NodusSpace.page)
                if session.mirror != nil {
                    NodusSearchField(text: $query, prompt: "Filter on any field", accent: session.accent)
                        .padding(.horizontal, NodusSpace.page)
                        .padding(.bottom, 8)
                }
            }
            .padding(.top, 10)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .systemBackground).opacity(0.98))
        }
        .onChange(of: query) { _, _ in schedule() }
        // The publication revision changes before a potentially large mirror finishes
        // importing. Keying this local read to the mirror's own revision prevents one reload
        // from racing the import and then remaining on the old rows.
        .task(id: session.mirrorSummary?.revision) { await reload() }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                Text("Publication").tag(MirrorStore.SortOrder.published)
                Text("Title A–Z").tag(MirrorStore.SortOrder.titleAscending)
                Text("Title Z–A").tag(MirrorStore.SortOrder.titleDescending)
                Text("Newest").tag(MirrorStore.SortOrder.dateDescending)
                Text("Oldest").tag(MirrorStore.SortOrder.dateAscending)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .onChange(of: sort) { _, _ in
            requestID = UUID()
            Task { await reload() }
        }
    }

    private func schedule() {
        searchTask?.cancel()
        // Invalidate an in-flight page immediately, including during the debounce.
        requestID = UUID()
        searchTask = Task {
            // No round trip here — this is a local index — so the debounce only exists to keep
            // a fast typist from re-querying on every keystroke.
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    private func reload() async {
        guard let mirror = session.mirror else { return }
        let token = UUID(), requestedQuery = query, requestedSort = sort, requestedTable = table
        requestID = token
        loading = true
        defer { if requestID == token { loading = false } }
        do {
            let page: Page<Row>
            if let filter {
                let complete = try await PageTraversal.complete { offset in
                    try await mirror.page(
                        table: requestedTable,
                        query: requestedQuery.isEmpty ? nil : requestedQuery,
                        sort: requestedSort,
                        limit: 500,
                        offset: offset
                    )
                }
                let matching = complete.items.filter(filter.includes)
                page = Page(items: matching, total: matching.count, limit: max(1, matching.count),
                    offset: 0, hasMore: false, revision: complete.revision, fromDevice: complete.fromDevice)
            } else {
                page = try await mirror.page(
                    table: table,
                    query: requestedQuery.isEmpty ? nil : requestedQuery,
                    sort: requestedSort,
                    limit: 80,
                    offset: 0
                )
                try CataloguePageIntegrity.validate(page)
            }
            guard requestID == token, query == requestedQuery, sort == requestedSort else { return }
            rows = page.items
            total = page.total
            lastPage = page
            loadedQuery = requestedQuery
            loadedSort = requestedSort
            error = nil
        } catch where error.isCancellation {
            // Superseded or let go of. Nothing failed, so nothing is reported.
        } catch {
            guard requestID == token else { return }
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard filter == nil, let mirror = session.mirror, rows.count < total, !loading,
              loadedQuery == query, loadedSort == sort, let previous = lastPage else { return }
        let token = requestID, offset = rows.count, requestedQuery = query, requestedSort = sort
        loading = true
        defer { if requestID == token { loading = false } }
        do {
            let page = try await mirror.page(
                table: table,
                query: requestedQuery.isEmpty ? nil : requestedQuery,
                sort: requestedSort,
                limit: 80,
                offset: offset
            )
            guard requestID == token, query == requestedQuery, sort == requestedSort else { return }
            try CataloguePageIntegrity.validate(page)
            guard page.offset == offset, page.total == previous.total else { throw PageTraversalError.invalidProgress }
            guard page.revision == previous.revision else { throw PageTraversalError.changingRevision }
            rows.append(contentsOf: page.items)
            lastPage = page
        } catch PageTraversalError.changingRevision {
            guard requestID == token else { return }
            await reload()
        } catch where error.isCancellation {
            // Superseded or let go of. Nothing failed, so nothing is reported.
        } catch {
            guard requestID == token else { return }
            self.error = error.localizedDescription
        }
    }
}

/// The sections a space has only because its snapshot was downloaded.
struct MirrorOnlySectionsView: View {
    let session: SpaceSession

    var body: some View {
        List {
            Section {
                ForEach(session.mirrorOnlyTables, id: \.table) { entry in
                    NavigationLink {
                        MirrorTableView(session: session, table: entry.table, title: Self.label(for: entry.table))
                    } label: {
                        Label {
                            HStack {
                                Text(LocalizedStringKey(Self.label(for: entry.table)))
                                Spacer()
                                CountBadge(count: entry.count, accent: session.accent)
                            }
                        } icon: {
                            Image(systemName: RowPresenter.forTable(entry.table).icon)
                                .foregroundStyle(session.accent)
                        }
                    }
                }
            } header: {
                Text("Offline only")
            } footer: {
                Text("These tables travel in the publication but have no REST route, so they can only be listed from the downloaded copy.")
            }
        }
        .scrollContentBackground(.hidden)
        .nodusDismissesKeyboard()
        .navigationTitle("More from this space")
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
    }

    /// Spanish names for the tables the desktop shows under its own labels.
    static func label(for table: String) -> String {
        switch table {
        case "character_profiles": return "Characters"
        case "place_profiles": return "Place profiles"
        case "world_groups": return "Factions"
        case "world_cultures": return "Cultures"
        case "world_scenes": return "Scenes"
        case "world_articles": return "Encyclopedia"
        case "world_threads": return "Story arcs"
        case "world_rules": return "World rules"
        case "world_questions": return "Open questions"
        case "world_secrets": return "Secrets"
        case "world_beats": return "Beats"
        case "world_families": return "Families"
        case "world_dynasties": return "Dynasties"
        case "kinship_suggestions": return "Suggested kinships"
        case "archive_items": return "Archive"
        case "archive_folders": return "Archive folders"
        case "study_recordings": return "Recordings"
        case "study_transcripts": return "Transcripts"
        case "study_plans": return "Study plans"
        case "study_goals": return "Goals"
        case "study_calendar_events": return "Calendar"
        case "study_schedule_periods": return "Timetables"
        case "teaching_logos": return "Logos"
        case "work_summaries": return "Work summaries"
        case "author_dossier_synthesis": return "Author dossiers"
        case "projects": return "Projects"
        case "project_chapters": return "Chapters"
        case "saved_searches": return "Saved searches"
        case "research_questions": return "Research questions"
        case "collections": return "Collections"
        case "db_rows": return "Database rows"
        case "db_views": return "Views"
        default:
            return table.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
