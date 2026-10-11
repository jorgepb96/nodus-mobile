import NodusKit
import NodusUI
import SwiftUI

// MARK: - Ideas

/// Desktop's Ideas catalogue and its resident dossiers. The catalogue owns filters and
/// pagination; every opened idea remains mounted in a sibling tab so scroll, selection and
/// loaded evidence survive switching between dossiers.
struct IdeasWorkspaceView: View {
    @Environment(WorkspaceTabs.self) private var workspaceTabs
    @Environment(\.horizontalSizeClass) private var sizeClass

    let session: SpaceSession
    let onOpenArgument: (ArgumentSeed) -> Void

    @State private var page: IdeaWorkspacePage?
    @State private var query = ""
    @State private var type = ""
    @State private var sort: IdeaWorkspaceSort = .label
    @State private var isLoading = false
    @State private var error: String?
    @State private var loadTask: Task<Void, Never>?

    private var section: String { NodusRoute.ideas.rawValue }
    private var loadID: String { "\(query)|\(type)|\(sort.rawValue)|\(session.publishedRevision ?? "local")" }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTabStrip(section: section, catalogueTitle: "Ideas", catalogueImage: "lightbulb", accent: session.accent)
            ZStack {
                catalogue
                    .opacity(workspaceTabs.activeTabId(in: section) == nil ? 1 : 0)
                    .allowsHitTesting(workspaceTabs.activeTabId(in: section) == nil)
                    .accessibilityHidden(workspaceTabs.activeTabId(in: section) != nil)

                ForEach(workspaceTabs.tabs(in: section)) { tab in
                    if case .row(let row) = tab.payload {
                        IdeaWorkspaceDocument(
                            session: session,
                            row: row,
                            tabId: tab.id,
                            onOpenRelated: open,
                            onOpenArgument: onOpenArgument
                        )
                        .opacity(workspaceTabs.activeTabId(in: section) == tab.id ? 1 : 0)
                        .allowsHitTesting(workspaceTabs.activeTabId(in: section) == tab.id)
                        .accessibilityHidden(workspaceTabs.activeTabId(in: section) != tab.id)
                    }
                }
            }
        }
        .accessibilityIdentifier("workspace-ideas")
    }

    private var catalogue: some View {
        ScrollView {
            LazyVStack(spacing: sizeClass == .regular ? 1 : 9) {
                if sizeClass == .regular, !(page?.items.isEmpty ?? true) { ideaTableHeader }
                if let error {
                    NodusNotice(tone: .blocked, title: "Could not load Ideas", message: LocalizedStringKey(error))
                }
                ForEach(page?.items ?? []) { item in
                    Button { open(row(for: item)) } label: {
                        IdeaWorkspaceRow(item: item, dense: sizeClass == .regular, accent: session.accent)
                    }
                    .buttonStyle(NodusCardButtonStyle())
                    .accessibilityIdentifier("workspace-open-ideas-\(safeIdentifier(item.id))")
                }
                if let page, page.hasMore {
                    Button { Task { await loadMore() } } label: {
                        if isLoading { ProgressView().tint(session.accent) }
                        else { Label("Load more", systemImage: "arrow.down.circle") }
                    }
                    .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
                    .padding(.vertical, 12)
                }
                if page?.items.isEmpty == true, !isLoading, error == nil {
                    ContentUnavailableView(query.isEmpty ? "No ideas" : "No matches", systemImage: "lightbulb")
                        .padding(.vertical, 48)
                }
            }
            .padding(NodusSpace.page)
            .frame(maxWidth: 1160)
            .frame(maxWidth: .infinity)
            .nodusTopAnchor()
        }
        .nodusDismissesKeyboard()
        .nodusPageFunctions(accent: session.accent)
        .nodusPageBackdrop(accent: session.accent)
        .safeAreaInset(edge: .top) { catalogueControls }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if page?.fromDevice == true {
                Label("Sin conexión · contenido de este dispositivo", systemImage: "iphone")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading).background(.thinMaterial)
            }
        }
        .task(id: loadID) { await reload() }
        .refreshable { await reload() }
    }

    private var catalogueControls: some View {
        VStack(spacing: 8) {
            DesktopPageHeader(
                title: "Ideas",
                subtitle: isLoading && page == nil ? "Loading publication…" : "\((page?.total ?? 0).formatted()) ideas · filters and ordering match Desktop",
                systemImage: "lightbulb",
                accent: session.accent
            )
            HStack(spacing: 8) {
                NodusSearchField(text: $query, prompt: "Search label or statement", accent: session.accent, isBusy: isLoading)
                Menu {
                    Picker("Type", selection: $type) {
                        Text("All types").tag("")
                        Text("Claims").tag("claim")
                        Text("Findings").tag("finding")
                        Text("Constructs").tag("construct")
                        Text("Methods").tag("method")
                        Text("Frameworks").tag("framework")
                    }
                } label: {
                    ideasControlIcon(type.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                }
                    .buttonStyle(NodusGlassIconButtonStyle(accent: session.accent))
                    .accessibilityLabel("Filter idea type")
                Menu {
                    Picker("Sort", selection: $sort) {
                        Text("Label").tag(IdeaWorkspaceSort.label)
                        Text("Type").tag(IdeaWorkspaceSort.type)
                        Text("Works").tag(IdeaWorkspaceSort.works)
                        Text("Connections").tag(IdeaWorkspaceSort.connections)
                        Text("Confidence").tag(IdeaWorkspaceSort.confidence)
                    }
                } label: { ideasControlIcon("arrow.up.arrow.down") }
                    .buttonStyle(NodusGlassIconButtonStyle(accent: session.accent))
                    .accessibilityLabel("Sort ideas")
            }
        }
        .padding(.horizontal, NodusSpace.page)
        .padding(.vertical, 9)
        .frame(maxWidth: 1160)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemBackground).opacity(0.97))
    }

    private func ideasControlIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
    }

    private var ideaTableHeader: some View {
        HStack(spacing: 12) {
            Text("IDEA").frame(maxWidth: .infinity, alignment: .leading)
            Text("TYPE").frame(width: 90, alignment: .leading)
            Text("WORKS").frame(width: 58, alignment: .trailing)
            Text("LINKS").frame(width: 58, alignment: .trailing)
            Text("CONF.").frame(width: 64, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func reload() async {
        loadTask?.cancel()
        if !query.isEmpty {
            loadTask = Task {
                try? await Task.sleep(for: .milliseconds(260))
                guard !Task.isCancelled else { return }
                await fetch(offset: 0, replacing: true)
            }
            await loadTask?.value
        } else {
            await fetch(offset: 0, replacing: true)
        }
    }

    private func loadMore() async { await fetch(offset: page?.items.count ?? 0, replacing: false) }

    private func fetch(offset: Int, replacing: Bool) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await session.client.workspaceIdeas(
                in: session.connection.spaceId, query: query, type: type, sort: sort, limit: 80, offset: offset
            )
            guard !Task.isCancelled else { return }
            if replacing || page == nil {
                page = loaded
            } else if let prior = page {
                page = IdeaWorkspacePage.combining(prior, loaded)
            }
            error = nil
#if DEBUG
            if ProcessInfo.processInfo.environment["NODUS_SHOW_TAB_DEMO"] == "1", workspaceTabs.tabs(in: section).isEmpty {
                for item in loaded.items.prefix(2) { open(row(for: item)) }
            }
#endif
        } catch where error.isCancellation {
            // A newer filter superseded this page.
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func open(_ row: Row) {
        guard let id = row.string("global_id") else { return }
        workspaceTabs.open(WorkspaceTab(
            id: "ideas:\(id)", title: row.text("label") ?? id, systemImage: "lightbulb",
            kind: .idea, payload: .row(row)
        ), in: section)
    }

    private func row(for item: IdeaWorkspaceItem) -> Row {
        Row([
            "global_id": .string(item.id), "label": .string(item.label), "type": .string(item.type),
            "statement": .string(item.statement), "work_count": .int(Int64(item.workCount)),
            "connection_count": .int(Int64(item.connectionCount)), "max_confidence": .double(item.maxConfidence),
            "themes": .array(item.themes.map(JSONValue.string)),
        ])
    }
}

private struct IdeaWorkspaceRow: View {
    let item: IdeaWorkspaceItem
    let dense: Bool
    let accent: Color

    var body: some View {
        if dense {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.label).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(item.statement).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                NodusChip(key: item.type, tint: SemanticTone.ideaType(item.type, fallback: accent)).frame(width: 90, alignment: .leading)
                Text(item.workCount.formatted()).frame(width: 58, alignment: .trailing)
                Text(item.connectionCount.formatted()).frame(width: 58, alignment: .trailing)
                Text(item.maxConfidence, format: .percent.precision(.fractionLength(0))).frame(width: 64, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemBackground).opacity(0.62), in: RoundedRectangle(cornerRadius: 6))
        } else {
            VStack(alignment: .leading, spacing: 7) {
                HStack { Text(item.label).font(.subheadline.weight(.semibold)).lineLimit(2); Spacer(); NodusChip(key: item.type, tint: SemanticTone.ideaType(item.type, fallback: accent)) }
                Text(item.statement).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                HStack(spacing: 12) {
                    Label("\(item.workCount)", systemImage: "books.vertical")
                    Label("\(item.connectionCount)", systemImage: "link")
                    Text(item.maxConfidence, format: .percent.precision(.fractionLength(0)))
                }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }.desktopContentRow(accent: accent)
        }
    }
}

private struct IdeaWorkspaceDocument: View {
    @Environment(WorkspaceTabs.self) private var workspaceTabs

    let session: SpaceSession
    let row: Row
    let tabId: String
    let onOpenRelated: (Row) -> Void
    let onOpenArgument: (ArgumentSeed) -> Void

    @State private var showingAssistant = false
    @State private var confirmingDelete = false
    @State private var actionState: String?
    @State private var isActing = false

    private var id: String { row.string("global_id") ?? "" }
    private var label: String { row.text("label") ?? id }
    private var canAct: Bool { !session.isDemo && session.connection.role.canSendChanges }

    var body: some View {
        VStack(spacing: 0) {
            workspaceActionBar
            RowDetailView(
                session: session, collection: Collections["ideas"], row: row,
                onOpenRelated: { collection, related in
                    if collection.path == "ideas" { onOpenRelated(related) }
                }
            )
        }
        .nodusSheet(isPresented: $showingAssistant) { NavigationStack { ChatTab(session: session, showsModalDone: true) } }
        .confirmationDialog("Delete this idea in Desktop?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await run(.ideaDelete) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The typed action is sent once and Desktop applies it to the canonical vault.") }
    }

    private var workspaceActionBar: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                actionButton("Argument map", image: "arrow.triangle.branch") { onOpenArgument(ArgumentSeed(id: id, label: label)) }
                actionButton("Assistant", image: "sparkles") { showingAssistant = true }
                actionButton("Save to Notes", image: "note.text.badge.plus", disabled: !canAct || isActing) { Task { await run(.ideaSaveToNotes) } }
                actionButton("Delete", image: "trash", tint: .red, disabled: !canAct || isActing) { confirmingDelete = true }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NodusSpace.page).padding(.vertical, 8)
            if let actionState { Text(actionState).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, NodusSpace.page).frame(maxWidth: .infinity, alignment: .leading) }
            else if !canAct { Text("Vault-changing actions require a writable space connected to Desktop.").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, NodusSpace.page).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .background(Color(uiColor: .systemBackground).opacity(0.96))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func actionButton(_ title: LocalizedStringKey, image: String, tint: Color? = nil, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
        }
        .buttonStyle(NodusGlassIconButtonStyle(accent: tint ?? session.accent))
        .disabled(disabled)
        .accessibilityLabel(title)
    }

    private func run(_ kind: SpaceActionKind) async {
        guard canAct, !id.isEmpty else { return }
        isActing = true
        defer { isActing = false }
        do {
            let result = try await session.client.createSpaceAction(
                idempotencyKey: "ios:\(kind.rawValue):\(session.connection.spaceId):\(id):\(session.publishedRevision ?? "local")",
                kind: kind, payload: ["ideaId": .string(id)], inputRevision: session.publishedRevision,
                executionMode:session.aiExecutionMode.rawValue, in:session.connection.spaceId
            )
            actionState = result.duplicate ? String(localized: "This action was already queued.") : String(localized: "Queued for Desktop · \(result.action.status.rawValue)")
            if kind == .ideaDelete { workspaceTabs.close(tabId, in: NodusRoute.ideas.rawValue) }
        } catch { actionState = error.localizedDescription }
    }
}

// MARK: - Authors

struct AuthorsWorkspaceView: View {
    @Environment(WorkspaceTabs.self) private var workspaceTabs
    @Environment(\.horizontalSizeClass) private var sizeClass

    let session: SpaceSession
    let onOpenIdea: (Row) -> Void
    let onOpenArgument: (ArgumentSeed) -> Void

    @State private var page: AuthorWorkspacePage?
    @State private var query = ""
    @State private var sort: AuthorWorkspaceSort = .surname
    @State private var synthesis: AuthorSynthesisFilter = .all
    @State private var savedOnly = false
    @State private var savedIds: Set<String> = []
    @State private var selected: Set<String> = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var loadTask: Task<Void, Never>?

    private var section: String { NodusRoute.authors.rawValue }
    private var loadID: String { "\(query)|\(sort.rawValue)|\(synthesis.rawValue)|\(session.publishedRevision ?? "local")" }
    private var visible: [AuthorWorkspaceItem] { (page?.items ?? []).filter { !savedOnly || savedIds.contains($0.authorId) } }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTabStrip(section: section, catalogueTitle: "Authors", catalogueImage: "person.2", accent: session.accent)
            ZStack {
                catalogue.opacity(workspaceTabs.activeTabId(in: section) == nil ? 1 : 0)
                    .allowsHitTesting(workspaceTabs.activeTabId(in: section) == nil)
                    .accessibilityHidden(workspaceTabs.activeTabId(in: section) != nil)
                ForEach(workspaceTabs.tabs(in: section)) { tab in
                    Group {
                        if tab.kind == .matrix {
                            AuthorSynthesisMatrixView(session: session, onOpenIdea: onOpenIdea)
                        } else if case .row(let row) = tab.payload {
                            AuthorWorkspaceDocument(
                                session: session, row: row,
                                isSaved: savedIds.contains(row.string("author_id") ?? ""),
                                onToggleSaved: { toggleSaved(row.string("author_id") ?? "") },
                                onOpenIdea: onOpenIdea, onOpenArgument: onOpenArgument
                            )
                        }
                    }
                    .opacity(workspaceTabs.activeTabId(in: section) == tab.id ? 1 : 0)
                    .allowsHitTesting(workspaceTabs.activeTabId(in: section) == tab.id)
                    .accessibilityHidden(workspaceTabs.activeTabId(in: section) != tab.id)
                }
            }
        }
        .accessibilityIdentifier("workspace-authors")
        .task { loadSaved() }
    }

    private var catalogue: some View {
        ScrollView {
            LazyVStack(spacing: sizeClass == .regular ? 1 : 9) {
                if sizeClass == .regular, !visible.isEmpty { authorTableHeader }
                if let error { NodusNotice(tone: .blocked, title: "Could not load Authors", message: LocalizedStringKey(error)) }
                ForEach(visible) { item in
                    AuthorWorkspaceRow(
                        item: item, dense: sizeClass == .regular, accent: session.accent,
                        saved: savedIds.contains(item.authorId), selected: selected.contains(item.authorId),
                        onSelect: { toggleSelection(item.authorId) }, onSave: { toggleSaved(item.authorId) },
                        onOpen: { open(item) }
                    )
                }
                if visible.isEmpty, !isLoading, error == nil {
                    ContentUnavailableView(savedOnly ? "No saved authors" : (query.isEmpty ? "No authors" : "No matches"), systemImage: "person.2")
                        .padding(.vertical, 48)
                }
            }
            .padding(NodusSpace.page).frame(maxWidth: 1160).frame(maxWidth: .infinity).nodusTopAnchor()
        }
        .nodusDismissesKeyboard().nodusPageFunctions(accent: session.accent).nodusPageBackdrop(accent: session.accent)
        .safeAreaInset(edge: .top) { authorControls }
        .task(id: loadID) { await reload() }
        .refreshable { await fetch() }
    }

    private var authorControls: some View {
        VStack(spacing: 8) {
            DesktopPageHeader(
                title: "Authors", subtitle: "\((page?.total ?? 0).formatted()) authors · saved state remains local to this device",
                systemImage: "person.2", accent: session.accent
            )
            HStack(spacing: 8) {
                NodusSearchField(text: $query, prompt: "Search authors", accent: session.accent, isBusy: isLoading)
                Menu {
                    Picker("Synthesis", selection: $synthesis) {
                        Text("All").tag(AuthorSynthesisFilter.all); Text("With synthesis").tag(AuthorSynthesisFilter.with); Text("Without synthesis").tag(AuthorSynthesisFilter.without)
                    }
                    Picker("Sort", selection: $sort) {
                        Text("Surname").tag(AuthorWorkspaceSort.surname); Text("Name").tag(AuthorWorkspaceSort.name); Text("Works").tag(AuthorWorkspaceSort.works); Text("Ideas").tag(AuthorWorkspaceSort.ideas); Text("Connections").tag(AuthorWorkspaceSort.connections)
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease") }
                    .buttonStyle(NodusGlassIconButtonStyle(accent: session.accent))
                Button { savedOnly.toggle() } label: { Image(systemName: savedOnly ? "bookmark.fill" : "bookmark") }
                    .buttonStyle(NodusGlassIconButtonStyle(accent: session.accent)).accessibilityLabel("Saved authors only")
                Button { openMatrix() } label: { Image(systemName: "square.grid.3x3") }
                    .buttonStyle(NodusGlassIconButtonStyle(accent: session.accent)).accessibilityLabel("Synthesis matrix")
                if !selected.isEmpty {
                    ShareLink(item: selectedMarkdown) { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(NodusGlassIconButtonStyle(accent: session.accent)).accessibilityLabel("Export selected authors")
                }
            }
        }
        .padding(.horizontal, NodusSpace.page).padding(.vertical, 9).frame(maxWidth: 1160).frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemBackground).opacity(0.97))
    }

    private var authorTableHeader: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 34); Text("AUTHOR").frame(maxWidth: .infinity, alignment: .leading)
            Text("WORKS").frame(width: 58, alignment: .trailing); Text("IDEAS").frame(width: 58, alignment: .trailing)
            Text("LINKS").frame(width: 58, alignment: .trailing); Color.clear.frame(width: 34)
        }.font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func reload() async {
        loadTask?.cancel()
        loadTask = Task {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(260)) }
            guard !Task.isCancelled else { return }
            await fetch()
        }
        await loadTask?.value
    }

    private func fetch() async {
        isLoading = true; defer { isLoading = false }
        do {
            page = try await session.client.workspaceAuthors(
                in: session.connection.spaceId, query: query, sort: sort, synthesis: synthesis, limit: 100
            )
            error = nil
#if DEBUG
            if ProcessInfo.processInfo.environment["NODUS_SHOW_TAB_DEMO"] == "1", workspaceTabs.tabs(in: section).isEmpty {
                for item in (page?.items ?? []).prefix(2) { open(item) }
            }
#endif
        } catch where error.isCancellation {} catch { self.error = error.localizedDescription }
    }

    private func open(_ item: AuthorWorkspaceItem) {
        let row = Row(["author_id": .string(item.authorId), "name": .string(item.name), "display_name": .string(item.fullName), "affiliation": item.affiliation.map(JSONValue.string) ?? .null])
        workspaceTabs.open(WorkspaceTab(id: "authors:\(item.authorId)", title: item.fullName, systemImage: "person.crop.circle", kind: .author, payload: .row(row)), in: section)
    }

    private func openMatrix() {
        workspaceTabs.open(WorkspaceTab(
            id: "authors:matrix", title: "Synthesis matrix", systemImage: "square.grid.3x3",
            kind: .matrix, payload: .reference(kind: "authors-matrix", id: "matrix")
        ), in: section)
    }

    private func toggleSaved(_ id: String) {
        guard !id.isEmpty else { return }
        if savedIds.contains(id) { savedIds.remove(id) } else { savedIds.insert(id) }
        persistSaved()
    }

    private func toggleSelection(_ id: String) { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }
    private var savedKey: String { "nodus.saved-authors.\(session.connection.spaceId).v1" }
    private func loadSaved() {
#if DEBUG
        if ProcessInfo.processInfo.environment["NODUS_RESET_SAVED_AUTHORS"] == "1" {
            UserDefaults.standard.removeObject(forKey: savedKey)
        }
#endif
        savedIds = Set(UserDefaults.standard.stringArray(forKey: savedKey) ?? [])
    }
    private func persistSaved() { UserDefaults.standard.set(Array(savedIds).sorted(), forKey: savedKey) }
    private var selectedMarkdown: String {
        let values = (page?.items ?? []).filter { selected.contains($0.authorId) }
        return (["# Authors"] + values.map { "- **\($0.fullName)** — \($0.workCount) works, \($0.ideaCount) ideas, \($0.relationCount) connections" }).joined(separator: "\n")
    }
}

private struct AuthorWorkspaceRow: View {
    let item: AuthorWorkspaceItem
    let dense: Bool
    let accent: Color
    let saved: Bool
    let selected: Bool
    let onSelect: () -> Void
    let onSave: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) { Image(systemName: selected ? "checkmark.circle.fill" : "circle").frame(width: 24, height: 44) }
                .buttonStyle(.plain).foregroundStyle(selected ? accent : Color.secondary).accessibilityLabel("Select \(item.fullName)")
            Button(action: onOpen) {
                Group {
                    if dense {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.fullName).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(([item.affiliation] + item.topThemes.prefix(2).map(Optional.some)).compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(item.workCount.formatted()).frame(width: 58, alignment: .trailing)
                            Text(item.ideaCount.formatted()).frame(width: 58, alignment: .trailing)
                            Text(item.relationCount.formatted()).frame(width: 58, alignment: .trailing)
                        }.font(.caption.monospacedDigit())
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.fullName).font(.subheadline.weight(.semibold)).lineLimit(2)
                            if let affiliation = item.affiliation { Text(affiliation).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            HStack(spacing: 11) { Label("\(item.workCount)", systemImage: "books.vertical"); Label("\(item.ideaCount)", systemImage: "lightbulb"); Label("\(item.relationCount)", systemImage: "link") }
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("workspace-open-author-row-\(safeIdentifier(item.authorId))")
            Button(action: onSave) { Image(systemName: saved ? "bookmark.fill" : "bookmark").frame(width: 34, height: 44) }
                .buttonStyle(.plain).foregroundStyle(saved ? accent : Color.secondary).accessibilityLabel(saved ? "Remove saved author" : "Save author")
                .accessibilityIdentifier("workspace-author-save-\(saved ? "saved" : "unsaved")-\(safeIdentifier(item.authorId))")
        }
        .padding(.horizontal, 10).padding(.vertical, dense ? 3 : 8)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.62), in: RoundedRectangle(cornerRadius: dense ? 6 : 12))
    }
}

private struct AuthorWorkspaceDocument: View {
    @Environment(AISettings.self) private var ai
    let session: SpaceSession
    let row: Row
    let isSaved: Bool
    let onToggleSaved: () -> Void
    let onOpenIdea: (Row) -> Void
    let onOpenArgument: (ArgumentSeed) -> Void

    @State private var dossier: AuthorWorkspaceDossier?
    @State private var isLoading = false
    @State private var error: String?
    @State private var actionState: String?
    @State private var showingAssistant = false
    @State private var localSynthesis: AuthorDossierSynthesis?
    @State private var generationTask: Task<Void, Never>?
    private var sourceRequest: JSONValue { CompanionAcademicGeneration.sourceRequest(kind: "author", author: id, language: CompanionAcademicGeneration.language) }

    private var id: String { row.string("author_id") ?? "" }
    private var canAct: Bool {
#if DEBUG
        if ProcessInfo.processInfo.environment["NODUS_UI_TEST_ACTIONS"] == "1" { return true }
#endif
        return !session.isDemo && session.connection.role.canSendChanges
    }

    var body: some View {
        Group {
            if let dossier { dossierBody(dossier) }
            else if isLoading { ProgressView().tint(session.accent).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error { ContentUnavailableView("Could not load dossier", systemImage: "person.crop.circle.badge.exclamationmark", description: Text(error)) }
            else { ProgressView().tint(session.accent) }
        }
        .nodusPageBackdrop(accent: session.accent)
        .task(id: session.publishedRevision) { await load() }
        .nodusSheet(isPresented: $showingAssistant) { NavigationStack { ChatTab(session: session, showsModalDone: true) } }
    }

    private func dossierBody(_ dossier: AuthorWorkspaceDossier) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(dossier.fullName).font(.title3.weight(.semibold))
                    if let affiliation = dossier.author.text("affiliation") { Text(affiliation).font(.subheadline).foregroundStyle(.secondary) }
                    FlowLayout(spacing: 6) { ForEach(dossier.themes, id: \.self) { NodusChip($0, tint: session.accent.nodusReadable) } }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(NodusSpace.cardPadding).nodusGlass(NodusGlass(.regular, tint: session.accent))

                FlowLayout(spacing: 8) {
                    Button(action: onToggleSaved) { Label(isSaved ? "Saved" : "Save", systemImage: isSaved ? "bookmark.fill" : "bookmark") }
                    Button { showingAssistant = true } label: { Label("Assistant", systemImage: "sparkles") }
                    if let idea = dossier.ideas.first { Button { onOpenArgument(ArgumentSeed(id: idea.globalId, label: idea.label)) } label: { Label("Argument map", systemImage: "point.3.connected.trianglepath.dotted") } }
                    Button { generationTask = Task { defer { generationTask = nil }; await generateSynthesis() } } label: { Label(dossier.synthesis == nil && localSynthesis == nil ? "Generate synthesis" : "Regenerate synthesis", systemImage: "wand.and.stars") }.disabled(!canAct || generationTask != nil)
                    if generationTask != nil { Button("Cancelar") { generationTask?.cancel() } }
                    if session.connection.desktopPairingId != nil { CompanionAcademicDownloadButton(session: session, request: sourceRequest) }
                }.buttonStyle(NodusGlassButtonStyle(accent: session.accent))
                if let actionState { Text(actionState).font(.caption).foregroundStyle(.secondary) }

                if let synthesis = freshestSynthesis(dossier.synthesis) { synthesisPanel(synthesis) }
                authorWorks("Works", dossier.works)
                authorWorks("Edited works", dossier.editedWorks)
                authorIdeas(dossier.ideas)
                authorRelations(dossier.relations)
            }
            .padding(NodusSpace.page).frame(maxWidth: 1060).frame(maxWidth: .infinity).nodusTopAnchor()
        }.nodusPageFunctions(accent: session.accent)
    }

    private func synthesisPanel(_ value: AuthorDossierSynthesis) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { NodusSectionLabel("Synthesis"); Spacer(); if value.stale { NodusChip("Out of date", tint: .nodusCaution) } }
            VStack(alignment: .leading, spacing: 9) {
                Text(value.thesis).font(.body.weight(.medium)).textSelection(.enabled)
                if !value.positioning.isEmpty { Text(value.positioning).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                ForEach(value.remember, id: \.self) { Label($0, systemImage: "pin").font(.caption) }
            }.padding(NodusSpace.cardPadding).frame(maxWidth: .infinity, alignment: .leading).nodusGlass(NodusGlass(.thin, tint: session.accent))
        }
    }

    private func authorWorks(_ title: LocalizedStringKey, _ works: [AuthorDossierWork]) -> some View {
        Group { if !works.isEmpty { VStack(alignment: .leading, spacing: 8) { NodusSectionLabel(title, count: works.count); VStack(spacing: 0) { ForEach(works) { work in VStack(alignment: .leading, spacing: 3) { Text(work.title).font(.subheadline.weight(.medium)); HStack { if let year = work.year { Text(String(year)) }; NodusChip(work.role, tint: session.accent.nodusReadable); if !work.attributed { NodusChip("Not attributed", tint: .nodusCaution) } }.font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8); Divider().opacity(0.3) } }.padding(.horizontal, NodusSpace.cardPadding).nodusGlass(NodusGlass(.thin, tint: session.accent)) } } }
    }

    private func authorIdeas(_ ideas: [AuthorDossierIdea]) -> some View {
        Group { if !ideas.isEmpty { VStack(alignment: .leading, spacing: 8) { NodusSectionLabel("Ideas", count: ideas.count); VStack(spacing: 0) { ForEach(ideas) { idea in Button { onOpenIdea(Row(["global_id": .string(idea.globalId), "label": .string(idea.label), "statement": .string(idea.statement), "type": .string(idea.type)])) } label: { VStack(alignment: .leading, spacing: 5) { HStack { Text(idea.label).font(.subheadline.weight(.medium)); Spacer(); NodusChip(key: idea.type, tint: SemanticTone.ideaType(idea.type, fallback: session.accent)) }; Text(idea.development).font(.caption).foregroundStyle(.secondary).lineLimit(3); if idea.provisional { NodusChip("Editor-only · provisional", tint: .nodusCaution) } }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).contentShape(Rectangle()) }.buttonStyle(.plain); Divider().opacity(0.3) } }.padding(.horizontal, NodusSpace.cardPadding).nodusGlass(NodusGlass(.thin, tint: session.accent)) } } }
    }

    private func authorRelations(_ relations: [AuthorDossierRelation]) -> some View {
        Group { if !relations.isEmpty { VStack(alignment: .leading, spacing: 8) { NodusSectionLabel("Relationships", count: relations.count); VStack(spacing: 0) { ForEach(relations) { relation in HStack { VStack(alignment: .leading) { Text(relation.name).font(.subheadline.weight(.medium)); Text(relation.sharedThemes.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }; Spacer(); NodusChip(RowDetailView.relationLabel(relation.type), tint: session.accent.nodusReadable); Text(relation.weight, format: .number.precision(.fractionLength(1))).font(.caption.monospacedDigit()) }.padding(.vertical, 8); Divider().opacity(0.3) } }.padding(.horizontal, NodusSpace.cardPadding).nodusGlass(NodusGlass(.thin, tint: session.accent)) } } }
    }

    private func load() async {
        guard !id.isEmpty else { return }
        isLoading = true; defer { isLoading = false }
        do {
            dossier = try await session.client.authorWorkspaceDossier(id, in: session.connection.spaceId)
            if session.connection.desktopPairingId != nil, let value = try await CompanionAcademicGeneration.saved(session: session, request: sourceRequest) {
                localSynthesis = try JSONDecoder.nodus.decode(AuthorDossierSynthesis.self, from: JSONEncoder.nodus.encode(value))
            }
            error = nil
        }
        catch where error.isCancellation {} catch { self.error = error.localizedDescription }
    }

    private func generateSynthesis() async {
        guard canAct else { return }
        do {
            if session.aiExecutionMode == .autonomous, session.connection.desktopPairingId != nil {
                let value = try await CompanionAcademicGeneration(settings: ai).run(session: session, request: sourceRequest) { actionState = $0 }
                localSynthesis = try JSONDecoder.nodus.decode(AuthorDossierSynthesis.self, from: JSONEncoder.nodus.encode(value))
                return
            }
            let result = try await session.client.createSpaceAction(
                idempotencyKey: "ios:author-synthesis:\(session.connection.spaceId):\(id):\(session.publishedRevision ?? "local")",
                kind: .authorSynthesisGenerate, payload: ["authorId": .string(id)], inputRevision: session.publishedRevision,
                executionMode:session.aiExecutionMode.rawValue, in:session.connection.spaceId
            )
            actionState = result.duplicate ? String(localized: "This synthesis is already queued.") : String(localized: "Synthesis queued for Desktop.")
        } catch { actionState = error.localizedDescription }
    }
    private func freshestSynthesis(_ remote: AuthorDossierSynthesis?) -> AuthorDossierSynthesis? {
        guard let localSynthesis else { return remote }; guard let remote else { return localSynthesis }
        return remote.generatedAt > localSynthesis.generatedAt ? remote : localSynthesis
    }
}

private struct AuthorSynthesisMatrixView: View {
    @Environment(AISettings.self) private var ai
    @Environment(\.horizontalSizeClass) private var sizeClass
    let session: SpaceSession
    let onOpenIdea: (Row) -> Void

    @State private var matrix: SynthesisMatrix?
    @State private var isLoading = false
    @State private var error: String?
    @State private var generated: [String: String] = [:]
    @State private var localCells: [String: SynthesisMatrixCell] = [:]
    @State private var generating: Set<String> = []
    @State private var selectedTheme = ""
    private var phone: Bool { UIDevice.current.userInterfaceIdiom == .phone || sizeClass != .regular }

    var body: some View {
        Group {
            if let matrix { matrixBody(matrix) }
            else if isLoading { ProgressView().tint(session.accent).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error { ContentUnavailableView("Could not load matrix", systemImage: "square.grid.3x3", description: Text(error)) }
            else { ProgressView().tint(session.accent) }
        }
        .nodusPageBackdrop(accent: session.accent)
        .task(id: "\(session.publishedRevision ?? ""):\(session.companionResultRevision):\(session.companionPublicationRevision)") { await load() }
    }

    private func matrixBody(_ matrix: SynthesisMatrix) -> some View {
        VStack(spacing: 0) {
            DesktopPageHeader(title: "Authors × themes", subtitle: "\(matrix.authors.count) authors · \(matrix.themes.count) themes · grounded cells only", systemImage: "square.grid.3x3", accent: session.accent)
                .padding(NodusSpace.page).background(Color(uiColor: .systemBackground).opacity(0.97))
            if phone {
                Picker("Tema", selection: $selectedTheme) { ForEach(matrix.themes) { Text($0.label).tag($0.themeId) } }
                    .pickerStyle(.menu).padding(.horizontal, 16).frame(minHeight: 44)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let theme = matrix.themes.first(where: { $0.themeId == selectedTheme }) ?? matrix.themes.first {
                            ForEach(matrix.authors) { author in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(author.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                                    Text(theme.label).font(.subheadline).foregroundStyle(.secondary)
                                    matrixCell(author: author, theme: theme, matrix: matrix)
                                }.padding(12).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }.padding(16)
                }
            } else { ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .topLeading, horizontalSpacing: 1, verticalSpacing: 1) {
                    GridRow {
                        Text("AUTHOR").matrixHeader(width: 190)
                        ForEach(matrix.themes) { Text($0.label).matrixHeader(width: 260) }
                    }
                    ForEach(matrix.authors) { author in
                        GridRow {
                            VStack(alignment: .leading, spacing: 3) { Text(author.name).font(.subheadline.weight(.semibold)); Text("\(author.workCount) works").font(.caption).foregroundStyle(.secondary) }
                                .padding(10).frame(width: 190, height: 120, alignment: .topLeading).background(Color(uiColor: .secondarySystemBackground))
                            ForEach(matrix.themes) { theme in matrixCell(author: author, theme: theme, matrix: matrix) }
                        }
                    }
                }.padding(NodusSpace.page)
            } }
        }
    }

    private func matrixCell(author: SynthesisMatrixAuthor, theme: SynthesisMatrixTheme, matrix: SynthesisMatrix) -> some View {
        let key = "\(author.authorId):\(theme.themeId)"
        let cell = localCells[key] ?? matrix.cells.first { $0.authorId == author.authorId && $0.themeId == theme.themeId }
        return VStack(alignment: .leading, spacing: 6) {
            if let cell {
                HStack { NodusChip("\(cell.ideaCount) ideas", tint: session.accent.nodusReadable, capitalises: false); Spacer() }
                if let stance = cell.stance { Text(stance).font(.caption).fixedSize(horizontal: false, vertical: true) }
                Button(cell.stance == nil ? "Generate stance" : "Regenerate synthesis") { Task { await generate(author.authorId, theme.themeId, key: key) } }.font(.caption.weight(.semibold)).disabled(session.isDemo || !session.connection.role.canSendChanges || generating.contains(key))
                ForEach(cell.ideas) { idea in Button(idea.label) { onOpenIdea(Row(["global_id": .string(idea.globalId), "label": .string(idea.label), "type": .string(idea.type)])) }.font(.caption).fixedSize(horizontal: false, vertical: true).frame(minHeight: 44, alignment: .leading) }
                if session.connection.desktopPairingId != nil { CompanionAcademicDownloadButton(session: session, request: sourceRequest(author.authorId, theme.themeId)) }
            } else { Text("—").foregroundStyle(.tertiary) }
            if let status = generated[key] { Text(status).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(10).frame(width: phone ? nil : 260, alignment: .topLeading).frame(maxWidth: phone ? .infinity : nil, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
    }

    private func load() async {
        isLoading = true; defer { isLoading = false }
        do {
            let snapshot = try await session.client.synthesisMatrixSnapshot(in: session.connection.spaceId)
            let value = snapshot.matrix; matrix = value
            localCells = [:]
            if selectedTheme.isEmpty { selectedTheme = value.themes.first?.themeId ?? "" }
            if session.connection.desktopPairingId != nil {
                for cell in value.cells {
                    // A fresh canonical Mac cell wins over an acknowledged
                    // local preview, including later edits on another device.
                    if let saved = try await CompanionAcademicGeneration.saved(session: session, request: sourceRequest(cell.authorId, cell.themeId), onlyUnpublished: !snapshot.fromCache) {
                        localCells[cell.id] = try JSONDecoder.nodus.decode(SynthesisMatrixCell.self, from: JSONEncoder.nodus.encode(saved))
                    }
                }
            }
            error = nil
        }
        catch where error.isCancellation {} catch { self.error = error.localizedDescription }
    }

    private func generate(_ authorId: String, _ themeId: String, key: String) async {
        guard !generating.contains(key) else { return }; generating.insert(key); defer { generating.remove(key) }
        do {
            if session.aiExecutionMode == .autonomous, session.connection.desktopPairingId != nil {
                let value = try await CompanionAcademicGeneration(settings: ai).run(session: session, request: sourceRequest(authorId, themeId)) { generated[key] = $0 }
                localCells[key] = try JSONDecoder.nodus.decode(SynthesisMatrixCell.self, from: JSONEncoder.nodus.encode(value)); return
            }
            _ = try await session.client.createSpaceAction(
                idempotencyKey: "ios:matrix:\(session.connection.spaceId):\(authorId):\(themeId):\(session.publishedRevision ?? "local")",
                kind: .authorsMatrixGenerate, payload: ["authorId": .string(authorId), "themeId": .string(themeId)],
                inputRevision: session.publishedRevision, executionMode:session.aiExecutionMode.rawValue, in:session.connection.spaceId
            )
            generated[key] = "Queued"
        } catch { generated[key] = error.localizedDescription }
    }
    private func sourceRequest(_ authorId: String, _ themeId: String) -> JSONValue {
        CompanionAcademicGeneration.sourceRequest(kind: "matrix", author: authorId, theme: themeId, language: CompanionAcademicGeneration.language)
    }
}

private extension View {
    func matrixHeader(width: CGFloat) -> some View {
        self.font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(10)
            .frame(width: width, height: 44, alignment: .leading).background(Color(uiColor: .tertiarySystemBackground))
    }
}

private extension IdeaWorkspacePage {
    static func combining(_ left: Self, _ right: Self) -> Self {
        let existing = Set(left.items.map(\.id))
        let appended = left.items + right.items.filter { !existing.contains($0.id) }
        return Self(
            items: appended, total: right.total, offset: 0, limit: appended.count,
            hasMore: right.hasMore, revision: right.revision, fromDevice: right.fromDevice
        )
    }
}

private func safeIdentifier(_ value: String) -> String {
    value.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
}
