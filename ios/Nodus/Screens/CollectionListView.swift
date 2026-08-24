import NodusKit
import NodusUI
import SwiftUI

/// One collection, paged.
///
/// The server has no sort parameter on any endpoint, so what arrives is snapshot order and the
/// list says so rather than pretending to a sort it did not ask for. Filtering is the server's
/// `?q=`, which is a substring match across every string column of the row — not a field
/// search, and the placeholder is worded accordingly.
struct CollectionListView: View {
    @Environment(WorkspaceTabs.self) private var workspaceTabs

    let session: SpaceSession
    let collection: CollectionDescriptor
    /// Present only when this collection is the root of a Desktop-style workspace. Nested
    /// collections retain ordinary NavigationStack pushes instead of creating tabs in a parent.
    var workspaceRoute: NodusRoute? = nil

    @State private var rows: [Row] = []
    @State private var revision: String?
    @State private var total = 0
    @State private var hasMore = false
    @State private var query = ""
    @State private var isLoading = false
    @State private var error: String?
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        if let workspaceRoute {
            VStack(spacing: 0) {
                WorkspaceTabStrip(
                    section: workspaceRoute.rawValue,
                    catalogueTitle: collection.label,
                    catalogueImage: collection.icon,
                    accent: session.accent
                )
                ZStack {
                    catalogue
                        .opacity(workspaceTabs.activeTabId(in: workspaceRoute.rawValue) == nil ? 1 : 0)
                        .allowsHitTesting(workspaceTabs.activeTabId(in: workspaceRoute.rawValue) == nil)
                        .accessibilityHidden(workspaceTabs.activeTabId(in: workspaceRoute.rawValue) != nil)

                    ForEach(workspaceTabs.tabs(in: workspaceRoute.rawValue)) { tab in
                        if case .row(let row) = tab.payload {
                            rowDetail(row)
                                .opacity(workspaceTabs.activeTabId(in: workspaceRoute.rawValue) == tab.id ? 1 : 0)
                                .allowsHitTesting(workspaceTabs.activeTabId(in: workspaceRoute.rawValue) == tab.id)
                                .accessibilityHidden(workspaceTabs.activeTabId(in: workspaceRoute.rawValue) != tab.id)
                        }
                    }
                }
            }
            .accessibilityIdentifier("workspace-\(workspaceRoute.rawValue)")
        } else {
            catalogue
        }
    }

    private var catalogue: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 9) {
            if let error {
                NodusNotice(tone: .blocked, title: "Could not load", message: LocalizedStringKey(error))
            }

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                rowLink(row)
            }

            if hasMore {
                HStack {
                    Spacer()
                    ProgressView().tint(session.accent)
                    Spacer()
                }
                .padding()
                .task { await loadMore() }
            }

            if rows.isEmpty, !isLoading, error == nil {
                ContentUnavailableView(
                    query.isEmpty ? "Nothing here" : "No matches",
                    systemImage: collection.icon,
                    description: Text(query.isEmpty
                        ? "This publication carries nothing under \(collection.label.lowercased())."
                        : "No row contains “\(query)”.")
                )
                .padding(.vertical, 42)
            }
            }
            .padding(NodusSpace.page)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
            .nodusTopAnchor()
        }
        .nodusDismissesKeyboard()
        .nodusPageFunctions(accent: session.accent)
        .navigationTitle(Text(LocalizedStringKey(collection.label)))
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 7) {
                DesktopPageHeader(
                    title: LocalizedStringKey(collection.label),
                    subtitle: isLoading && rows.isEmpty
                        ? "Loading publication…"
                        : "\(total.formatted()) published records",
                    systemImage: collection.icon,
                    accent: session.accent
                )
                .padding(.horizontal, NodusSpace.page)
                NodusSearchField(text: $query, prompt: "Filter on any field", accent: session.accent, isBusy: isLoading)
                    .padding(.horizontal, NodusSpace.page)
                    .padding(.bottom, 8)
            }
            .padding(.top, 10)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .systemBackground).opacity(0.98))
        }
        .onChange(of: query) { _, _ in scheduleReload() }
        .task(id: session.publishedRevision) { await reload() }
        .refreshable { await reload() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if total > 0 {
                    Text("\(rows.count.formatted()) / \(total.formatted())")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func rowLink(_ row: Row) -> some View {
        if let workspaceRoute {
            Button { open(row, in: workspaceRoute) } label: { rowLabel(row) }
                .buttonStyle(NodusCardButtonStyle())
                .accessibilityIdentifier("workspace-open-\(workspaceRoute.rawValue)-\(safeIdentifier(rowId(row)))")
        } else {
            NavigationLink { rowDetail(row) } label: { rowLabel(row) }
                .buttonStyle(NodusCardButtonStyle())
        }
    }

    private func rowLabel(_ row: Row) -> some View {
        RowCell(row: row, presenter: collection.presenter, accent: session.accent)
            .desktopContentRow(accent: session.accent)
    }

    @ViewBuilder
    private func rowDetail(_ row: Row) -> some View {
        if collection.path == "databases" {
            DatabaseGridView(session: session, database: row)
        } else {
            RowDetailView(session: session, collection: collection, row: row)
        }
    }

    private func open(_ row: Row, in route: NodusRoute) {
        let kind: WorkspaceTabKind = switch collection.path {
        case "ideas": .idea
        case "authors": .author
        default: .document
        }
        workspaceTabs.open(
            WorkspaceTab(
                id: "\(route.rawValue):\(rowId(row))",
                title: collection.presenter.title(row),
                systemImage: collection.icon,
                kind: kind,
                payload: .row(row)
            ),
            in: route.rawValue
        )
    }

    private func rowId(_ row: Row) -> String {
        row.string(collection.idField)
            ?? row.string("global_id")
            ?? "\(collection.path):\(collection.presenter.title(row))"
    }

    private func safeIdentifier(_ value: String) -> String {
        value.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
    }

    /// The server's `?q=` is rate-free but the round trip is not, and a keystroke-per-request
    /// list feels worse than one that waits a beat.
    private func scheduleReload() {
        loadTask?.cancel()
        loadTask = Task {
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await session.client.list(
                collection,
                in: session.connection.spaceId,
                query: query.isEmpty ? nil : query,
                limit: 60,
                offset: 0
            )
            rows = page.items
            total = page.total
            hasMore = page.hasMore
            revision = page.revision
            error = nil
#if DEBUG
            if ProcessInfo.processInfo.environment["NODUS_SHOW_TAB_DEMO"] == "1",
               let route = workspaceRoute,
               workspaceTabs.tabs(in: route.rawValue).isEmpty {
                for row in rows.prefix(2) { open(row, in: route) }
            }
#endif
        } catch let apiError as APIError where apiError.isNotPublished {
            rows = []; total = 0; hasMore = false; error = nil
        } catch is CancellationError {
            // Superseded by a newer keystroke.
        } catch where error.isCancellation {
            // Superseded or let go of. Nothing failed, so nothing is reported.
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await session.client.list(
                collection,
                in: session.connection.spaceId,
                query: query.isEmpty ? nil : query,
                limit: 60,
                offset: rows.count
            )
            // Two pages from different publications are two different corpora. Stitching them
            // would show a state the vault was never in, so the list restarts instead.
            guard page.revision == revision else {
                await reload()
                return
            }
            rows.append(contentsOf: page.items)
            hasMore = page.hasMore
        } catch {
            hasMore = false
            self.error = error.localizedDescription
        }
    }
}

struct RowCell: View {
    let row: Row
    let presenter: RowPresenter
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            NodusIcon(name: presenter.icon, size: 14)
                .foregroundStyle(accent.nodusReadable)
                .frame(width: 22, height: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                Text(presenter.title(row))
                    // Two lines, not three or four. An idea's label is a whole sentence and a
                    // work's title is a sentence with a subtitle after it, and in a list the
                    // point of the line is to be recognised, not read: four-line titles turned
                    // a page of ten rows into a page of four.
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if let subtitle = presenter.subtitle(row) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let detail = presenter.detail(row) {
                    // A tag, in the colour its meaning carries everywhere else. `claim`,
                    // `method` and `finding` were the accent at 85% — the same violet for three
                    // different kinds of thing, in a size and weight no other tag in the app
                    // used.
                    // `key:`, because for an idea this is the corpus's own `type` column —
                    // "claim", "finding" — and the catalogue has those words. Anything not in
                    // it (a Zotero item type, "5 works", "p. 40") comes back unchanged.
                    NodusChip(key: detail, tint: SemanticTone.ideaType(detail, fallback: accent))
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// Debates, notes, Deep Research reports and immersion sessions — the four resources that are
/// not a plain table projection.
struct SpecialListView: View {
    let session: SpaceSession
    let resource: SpecialResource

    @State private var rows: [Row] = []
    @State private var folders: [Row] = []
    @State private var total = 0
    @State private var hasMore = false
    @State private var error: String?
    @State private var isLoading = false
    @State private var outbox: OutboxController?
    @State private var composing = false
    @State private var editing: EditableNote?
    @State private var queued = false
    @State private var query = ""

    /// Filtered on what the row actually shows.
    ///
    /// The four resources here are the only lists in the app that had no filter at all, and
    /// they are the ones a corpus fills fastest: a vault with eighteen reports and a hundred
    /// debates is a lot of scrolling for a title you already know.
    private var visible: [Row] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter { row in
            let fields = [presenter.title(row), presenter.subtitle(row), presenter.detail(row)]
            return fields.compactMap { $0 }.contains { $0.lowercased().contains(needle) }
        }
    }

    var body: some View {
        List {
            NodusTopAnchorRow()
            if let error {
                NodusNotice(tone: .blocked, title: "Could not load", message: LocalizedStringKey(error))
                    .listRowBackground(Color.clear)
            }
            ForEach(Array(visible.enumerated()), id: \.offset) { _, row in
                NavigationLink {
                    // An immersion session is a whole study route — stations, quizzes, an exam
                    // — and rendering it as a column dump showed a wall of JSON. It gets its
                    // own reader; everything else here really is a row.
                    if resource == .immersion, let id = row.string("id") {
                        ImmersionView(session: session, sessionId: id, title: row.text("title") ?? title)
                    } else if resource == .debates, let id = row.string("id") {
                        // The list row is intentionally lean; opening it resolves the full
                        // debate so both positions and all published evidence remain visible.
                        DebateByIdView(session: session, edgeId: id)
                    } else {
                        RowDetailView(session: session, collection: nil, row: row, title: title)
                    }
                } label: {
                    RowCell(row: row, presenter: presenter, accent: session.accent)
                }
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing) {
                    if canEditNotes {
                        Button(role: .destructive) {
                            Task { await deleteNote(row) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            editing = EditableNote(row)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(session.accent)
                    }
                }
            }
            if visible.isEmpty, !isLoading, error == nil {
                ContentUnavailableView(
                    query.isEmpty ? "Nothing here" : "No matches",
                    systemImage: icon,
                    description: query.isEmpty ? nil : Text("Nothing here contains “\(query)”.")
                )
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .nodusDismissesKeyboard()
        .listStyle(.plain)
        .listRowSeparatorTint(Color.nodusTertiaryText.opacity(0.45))
        .nodusPageFunctions(accent: session.accent)
        .safeAreaInset(edge: .top) {
            NodusSearchField(text: $query, prompt: filterPrompt, accent: session.accent, isBusy: isLoading)
                .padding(.horizontal, NodusSpace.page)
                .padding(.vertical, 8)
        }
        .navigationTitle(Text(LocalizedStringKey(title)))
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .toolbar {
            if canEditNotes {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { composing = true } label: { Image(systemName: "square.and.pencil") }
                        .tint(session.accent)
                }
            }
        }
        .nodusSheet(isPresented: $composing) {
            NoteEditor(accent: session.accent, note: nil) { title, body in
                await outbox?.queueNote(title: title, body: body, folderId: nil)
                queued = true
            }
        }
        .nodusSheet(item: $editing) { note in
            NoteEditor(accent: session.accent, note: note) { title, body in
                await outbox?.queueNote(
                    id: note.id,
                    title: title,
                    body: body,
                    folderId: note.folderId,
                    createdAt: note.createdAt
                )
                queued = true
            }
        }
        // The one sentence this screen owes the user. A change here is not in the vault: it is
        // on the phone until it is sent, and in the ledger until the owner republishes. The
        // list underneath still shows the published rows, which is why nothing appears to
        // change when a note is edited.
        .alert("Queued on this device", isPresented: $queued) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Send it from the send queue. It joins the vault when its owner next opens Nodus desktop and republishes — until then this list still shows what was published.")
        }
        .task(id: session.publishedRevision) {
            // The rows first, and the queue afterwards. The queue is a SQLite file being opened
            // and migrated, and opening it before the fetch meant Debates, Deep Research and
            // Immersion — none of which can write anything — all waited on a disk they were
            // never going to use.
            await reload()
            if resource == .notes, outbox == nil {
                outbox = await OutboxController.open(session: session)
            }
        }
        .refreshable { await reload() }
    }

    /// Only notes are writable here, and only for a role the server would accept a change from.
    private var canEditNotes: Bool {
        resource == .notes && session.connection.role.canSendChanges && outbox != nil
    }

    private func deleteNote(_ row: Row) async {
        guard let id = row.string("id") else { return }
        await outbox?.queueNoteDeletion(id: id, title: row.text("title") ?? String(localized: "Untitled"))
        queued = true
    }

    private var title: String {
        switch resource {
        case .debates: return String(localized: "Debates")
        case .notes: return String(localized: "Notes")
        case .deepResearch: return String(localized: "Deep Research")
        case .immersion: return String(localized: "Immersion")
        }
    }

    private var filterPrompt: LocalizedStringKey {
        switch resource {
        case .debates: return "Filter debates"
        case .notes: return "Filter notes"
        case .deepResearch: return "Filter reports"
        case .immersion: return "Filter sessions"
        }
    }

    private var icon: String {
        switch resource {
        case .debates: return "bubble.left.and.bubble.right"
        case .notes: return "note.text"
        case .deepResearch: return "telescope"
        case .immersion: return "waveform"
        }
    }

    private var presenter: RowPresenter {
        switch resource {
        case .notes: return RowPresenter.forTable("notes")
        case .debates:
            return RowPresenter(collection: "debates", icon: icon) { row in
                row.text("relation").map(relationLabel) ?? String(localized: "Debate")
            } subtitle: { row in
                row.text("tension")
            } detail: { row in
                row.int("clusterSize").map { String(localized: "\($0) ideas") }
            }
        case .deepResearch:
            return RowPresenter(collection: "reports", icon: icon) { row in
                row.text("title") ?? String(localized: "Report")
            } subtitle: { row in
                row.text("objective")
            } detail: { row in
                row.text("language")
            }
        case .immersion:
            return RowPresenter(collection: "sessions", icon: icon) { row in
                row.text("title") ?? row.text("topic") ?? String(localized: "Session")
            } subtitle: { row in
                row.text("topic")
            } detail: { row in
                row.int("minutes").map { String(localized: "\($0) min") }
            }
        }
    }

    /// `String(localized:)`, not a literal: this is the *title* of a debate row, and a title
    /// reaches `Text` as a value rather than as a key — so the five words that name what a
    /// disagreement is stayed English on every phone.
    private func relationLabel(_ relation: String) -> String {
        switch relation {
        case "contradicts": return String(localized: "Contradicts")
        case "refutes": return String(localized: "Refutes")
        case "refines": return String(localized: "Refines")
        case "variant_of": return String(localized: "Variant of")
        case "extends": return String(localized: "Extends")
        default: return relation
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            switch resource {
            case .debates:
                let page = try await session.client.debates(in: session.connection.spaceId, limit: 60)
                rows = page.items; total = page.total; hasMore = page.hasMore
            case .notes:
                let page = try await session.client.notes(in: session.connection.spaceId, limit: 60)
                rows = page.notes; folders = page.folders; total = page.total; hasMore = page.hasMore
            case .deepResearch:
                let page = try await session.client.deepResearchReports(in: session.connection.spaceId, limit: 60)
                rows = page.items; total = page.total; hasMore = page.hasMore
            case .immersion:
                let page = try await session.client.immersionSessions(in: session.connection.spaceId, limit: 60)
                rows = page.items; total = page.total; hasMore = page.hasMore
            }
            error = nil
        } catch let apiError as APIError where apiError.isNotPublished {
            rows = []; error = nil
        } catch where error.isCancellation {
            // Superseded or let go of. Nothing failed, so nothing is reported.
        } catch {
            self.error = error.localizedDescription
        }
    }
}
