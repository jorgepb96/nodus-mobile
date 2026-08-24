import NodusKit
import NodusUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct AccountLibraryView: View {
    @Environment(WorkspaceTabs.self) private var workspaceTabs
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let session: SpaceSession

    @State private var catalog: AccountLibraryCatalog?
    @State private var outbox: AccountLibraryOutbox?
    @State private var items: [AccountLibraryItem] = []
    @State private var collections: [AccountLibraryCollection] = []
    @State private var savedSearches: [AccountLibrarySavedSearch] = []
    @State private var viewPreferences: AccountLibraryViewPreferences?
    @State private var conflicts: [AccountLibraryCatalog.Conflict] = []
    @State private var commands: [LibraryCommand] = []
    @State private var query = ""
    @State private var collectionId: String?
    @State private var itemType: String?
    @State private var sort: LibrarySort = .updated
    @State private var viewMode: LibraryViewMode = .table
    @State private var showingTrash = false
    @State private var duplicatesOnly = false
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var loading = true
    @State private var syncing = false
    @State private var error: String?
    @State private var editor: AccountLibraryItem?
    @State private var creatingItem = false
    @State private var showingImporter = false
    @State private var showingCollectionEditor = false
    @State private var newCollectionName = ""
    @State private var showingSavedSearchEditor = false
    @State private var savedSearchName = ""
    @State private var shareURL: URL?

    private let section = NodusRoute.library.rawValue
    private var deviceId: String { LibraryDeviceIdentity.current }

    private var filtered: [AccountLibraryItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        var result = items.filter { item in
            (showingTrash ? item.deletedAt != nil : item.deletedAt == nil)
                && (collectionId == nil || item.collectionIds.contains(collectionId!))
                && (itemType == nil || item.metadata.itemType == itemType)
                && (needle.isEmpty || item.searchableText.contains(needle))
        }
        if duplicatesOnly {
            let duplicateIds = Set(duplicateGroups.flatMap { $0.map(\.id) })
            result.removeAll { !duplicateIds.contains($0.id) }
        }
        result.sort { lhs, rhs in
            switch sort {
            case .updated: return lhs.clock.updatedAt > rhs.clock.updatedAt
            case .title: return lhs.metadata.title.localizedCaseInsensitiveCompare(rhs.metadata.title) == .orderedAscending
            case .creator: return (lhs.metadata.creators.first?.label ?? "").localizedCaseInsensitiveCompare(rhs.metadata.creators.first?.label ?? "") == .orderedAscending
            case .year: return (lhs.metadata.year ?? 0) > (rhs.metadata.year ?? 0)
            }
        }
        return result
    }

    private var duplicateGroups: [[AccountLibraryItem]] {
        let grouped = Dictionary(grouping: items.filter { $0.deletedAt == nil }) { item in
            if let doi = item.metadata.doi?.lowercased(), !doi.isEmpty { return "doi:\(doi)" }
            let title = item.metadata.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
            return "title:\(title):\(item.metadata.year ?? 0)"
        }
        return grouped.values.filter { $0.count > 1 }
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTabStrip(section: section, catalogueTitle: "Library", catalogueImage: "books.vertical", accent: session.accent)
            ZStack {
                catalogueView
                    .opacity(workspaceTabs.activeTabId(in: section) == nil ? 1 : 0)
                    .allowsHitTesting(workspaceTabs.activeTabId(in: section) == nil)
                    .accessibilityHidden(workspaceTabs.activeTabId(in: section) != nil)

                ForEach(workspaceTabs.tabs(in: section)) { tab in
                    if case .accountLibraryItem(let item) = tab.payload {
                        AccountLibraryReader(
                            session: session,
                            item: item,
                            catalog: catalog,
                            isActive: workspaceTabs.activeTabId(in: section) == tab.id,
                            onSave: save,
                            onOpenRelation: openItem,
                            onExport: export
                        )
                        .opacity(workspaceTabs.activeTabId(in: section) == tab.id ? 1 : 0)
                        .allowsHitTesting(workspaceTabs.activeTabId(in: section) == tab.id)
                        .accessibilityHidden(workspaceTabs.activeTabId(in: section) != tab.id)
                    }
                }
            }
        }
        .task { await bootstrap() }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.pdf, .epub, .plainText, .rtf, .html, .image, .spreadsheet, .presentation],
            allowsMultipleSelection: true,
            onCompletion: importFiles
        )
        .sheet(isPresented: $creatingItem) {
            LibraryItemEditor(item: nil, accent: session.accent) { metadata in create(metadata: metadata) }
        }
        .sheet(item: $editor) { item in
            LibraryItemEditor(item: item, accent: session.accent) { metadata in
                var copy = item; copy.metadata = metadata; save(copy)
            }
        }
        .alert("New collection", isPresented: $showingCollectionEditor) {
            TextField("Name", text: $newCollectionName)
            Button("Create") { createCollection() }.disabled(newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Save search", isPresented: $showingSavedSearchEditor) {
            TextField("Name", text: $savedSearchName)
            Button("Save") { saveSearch() }.disabled(savedSearchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: { Text(query.isEmpty ? "The current filters will be saved." : query) }
        .sheet(item: $shareURL) { url in ActivityShareSheet(items: [url]) }
        .onChange(of: sort) { _, _ in saveViewPreferences() }
        .onChange(of: viewMode) { _, _ in saveViewPreferences() }
    }

    private var catalogueView: some View {
        VStack(spacing: 0) {
            libraryHeader
            libraryControls
            Divider().opacity(0.45)
            if loading, items.isEmpty {
                ProgressView("Opening the account Library…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                Group {
                    if let error {
                        ContentUnavailableView(
                            showingTrash ? "Trash is empty" : "No references",
                            systemImage: showingTrash ? "trash" : "books.vertical",
                            description: Text(error)
                        )
                    } else {
                        ContentUnavailableView(
                            showingTrash ? "Trash is empty" : "No references",
                            systemImage: showingTrash ? "trash" : "books.vertical",
                            description: Text("Import a file, create a reference or change the filters.")
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if horizontalSizeClass == .regular, viewMode == .table {
                libraryTable
            } else {
                libraryCards
            }
        }
        .nodusPageBackdrop(accent: session.accent)
    }

    private var libraryHeader: some View {
        DesktopPageHeader(
            title: showingTrash ? "Library Trash" : "Library",
            subtitle: "\(filtered.count) of \(items.filter { $0.deletedAt == nil }.count) references · account-global",
            systemImage: showingTrash ? "trash" : "books.vertical",
            accent: session.accent,
            trailing: {
                HStack(spacing: 6) {
                    if syncing { ProgressView().controlSize(.small).frame(width: 28, height: 44) }
                    Button { Task { await sync() } } label: {
                        libraryControlIcon("arrow.triangle.2.circlepath", active: syncing)
                    }
                    .buttonStyle(.plain)
                    .disabled(syncing || session.isDemo)
                    .accessibilityLabel("Sync")
                    Menu {
                        Button { creatingItem = true } label: { Label("New reference", systemImage: "plus") }
                        Button { showingImporter = true } label: { Label("Import files", systemImage: "square.and.arrow.down") }
                        Button { newCollectionName = ""; showingCollectionEditor = true } label: { Label("New collection", systemImage: "folder.badge.plus") }
                        Divider()
                        Button { enqueueCommand(.zoteroSync, title: "Zotero sync", payload: [:]) } label: { Label("Sync Zotero on Mac", systemImage: "desktopcomputer") }
                        Button { enqueueCommand(.extract, title: "Prepare selected files", payload: ["itemIds": .array(selection.map(JSONValue.string))]) } label: { Label("Prepare on Mac", systemImage: "text.viewfinder") }
                    } label: { libraryControlIcon("plus") }
                    .buttonStyle(.plain)
                    .disabled(session.isDemo)
                    .accessibilityLabel("Add to Library")
                }
            }
        )
        .padding(.horizontal, NodusSpace.page)
        .padding(.top, NodusSpace.page)
    }

    private var libraryControls: some View {
        VStack(spacing: 8) {
            NodusSearchField(text: $query, prompt: "Search title, creator, tag or citation key", accent: session.accent, isBusy: syncing)
            HStack(spacing: 8) {
                Menu {
                    Section("Collection") {
                        Button("All collections") { collectionId = nil }
                        ForEach(collections) { collection in Button(collection.name) { collectionId = collection.id } }
                    }
                    Section("Type") {
                        Button("All types") { itemType = nil }
                        ForEach(Set(items.map(\.metadata.itemType)).sorted(), id: \.self) { type in Button(type) { itemType = type } }
                    }
                } label: {
                    libraryControlIcon(collectionId != nil || itemType != nil ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                }
                .accessibilityLabel("Filter Library")

                Menu {
                    ForEach(LibrarySort.allCases) { value in
                        Button { sort = value } label: { Text(LocalizedStringKey(value.title)) }
                    }
                } label: { libraryControlIcon("arrow.up.arrow.down", active: sort != .updated) }
                .accessibilityLabel("Sort Library")

                Button { duplicatesOnly.toggle() } label: {
                    libraryControlIcon(duplicatesOnly ? "square.on.square.fill" : "square.on.square", active: duplicatesOnly)
                }
                .accessibilityLabel("Duplicates \(duplicateGroups.count)")

                Button { showingTrash.toggle(); selection.removeAll() } label: {
                    libraryControlIcon(showingTrash ? "books.vertical" : "trash", active: showingTrash)
                }
                .accessibilityLabel(showingTrash ? "Library" : "Trash")

                Menu {
                    ForEach(savedSearches) { search in Button(search.name) { apply(search) } }
                } label: { libraryControlIcon("bookmark.fill") }
                .disabled(savedSearches.isEmpty)
                .accessibilityLabel("Saved searches")

                Button { selecting.toggle(); if !selecting { selection.removeAll() } } label: {
                    libraryControlIcon(selecting ? "checkmark.circle.fill" : "checkmark.circle", active: selecting)
                }
                .accessibilityLabel(selecting ? "Done" : "Select")

                Menu {
                    if !query.isEmpty || collectionId != nil || itemType != nil {
                        Button { savedSearchName = query.isEmpty ? "Filtered Library" : query; showingSavedSearchEditor = true } label: { Label("Save search", systemImage: "bookmark") }
                    }
                    if selecting, !selection.isEmpty {
                        Button(showingTrash ? "Recover" : "Trash") { setSelectionDeleted(!showingTrash) }
                        Button("Export") { export(items.filter { selection.contains($0.id) }) }
                        if selection.count > 1 { Button("Merge") { enqueueMerge() } }
                    }
                    if !conflicts.isEmpty {
                        Section("Conflicts") {
                            ForEach(conflicts.prefix(20)) { conflict in Label(conflict.recordId, systemImage: conflict.winnerVersionId == conflict.versionId ? "checkmark.seal" : "arrow.triangle.branch") }
                        }
                    }
                    if !commands.isEmpty {
                        Section("Mac jobs") {
                            ForEach(commands.suffix(20).reversed()) { command in
                                Button {
                                    if !command.status.isTerminal { cancel(command) }
                                } label: {
                                    Label("\(command.kind.rawValue) · \(command.status.rawValue)", systemImage: command.status.isTerminal ? "checkmark.circle" : "desktopcomputer")
                                }
                                .disabled(command.status.isTerminal)
                            }
                        }
                    }
                } label: { libraryControlIcon("ellipsis") }
                .accessibilityLabel("More Library actions")
                .accessibilityIdentifier("library-more-actions")
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            if horizontalSizeClass == .regular {
                Picker("View", selection: $viewMode) {
                    Image(systemName: "list.bullet.rectangle").tag(LibraryViewMode.table)
                    Image(systemName: "square.grid.2x2").tag(LibraryViewMode.grid)
                }
                .pickerStyle(.segmented)
                .frame(width: 92)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, NodusSpace.page)
        .padding(.bottom, 10)
    }

    private func libraryControlIcon(_ systemImage: String, active: Bool = false) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(active ? session.accent.nodusReadable : Color.primary)
            .frame(width: 44, height: 44)
            .nodusGlass(NodusGlass(.regular, tint: active ? session.accent : .clear), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
    }

    private var libraryTable: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(filtered) { item in tableRow(item) }
                } header: {
                    HStack(spacing: 12) {
                        Text("").frame(width: 24)
                        Text("Title").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Creator").frame(width: 220, alignment: .leading)
                        Text("Year").frame(width: 60, alignment: .leading)
                        Text("Type").frame(width: 150, alignment: .leading)
                        Text("Status").frame(width: 100, alignment: .leading)
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, NodusSpace.page).frame(height: 36)
                    .background(.bar)
                }
            }
        }
    }

    private func tableRow(_ item: AccountLibraryItem) -> some View {
        Button { selecting ? toggle(item.id) : openItem(item) } label: {
            HStack(spacing: 12) {
                Image(systemName: selecting ? (selection.contains(item.id) ? "checkmark.circle.fill" : "circle") : "doc.text")
                    .foregroundStyle(selection.contains(item.id) || !selecting ? session.accent.nodusReadable : .secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.metadata.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(item.metadata.tags.prefix(3).map { "#\($0)" }.joined(separator: "  ")).font(.caption2).foregroundStyle(session.accent.nodusReadable).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(item.metadata.creators.first?.label ?? "—").frame(width: 220, alignment: .leading).lineLimit(1)
                Text(item.metadata.year.map(String.init) ?? "—").frame(width: 60, alignment: .leading)
                Text(item.metadata.itemType).frame(width: 150, alignment: .leading).lineLimit(1)
                Label(item.attachments.isEmpty ? "Metadata" : "Ready", systemImage: item.attachments.isEmpty ? "doc.badge.ellipsis" : "paperclip")
                    .frame(width: 100, alignment: .leading).foregroundStyle(.secondary)
            }
            .font(.caption).foregroundStyle(.primary)
            .padding(.horizontal, NodusSpace.page).frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { rowMenu(item) }
        .overlay(alignment: .bottom) { Divider().padding(.leading, 60) }
        .accessibilityIdentifier("workspace-open-library-\(safeIdentifier(item.id))")
    }

    private var libraryCards: some View {
        ScrollView {
            LazyVGrid(columns: horizontalSizeClass == .regular && viewMode == .grid ? [GridItem(.adaptive(minimum: 290), spacing: 12)] : [GridItem(.flexible())], spacing: 12) {
                ForEach(filtered) { item in
                    Button { selecting ? toggle(item.id) : openItem(item) } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack { Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "doc.text").foregroundStyle(session.accent.nodusReadable); Spacer(); Text(item.metadata.year.map(String.init) ?? "").font(.caption).foregroundStyle(.secondary) }
                            Text(item.metadata.title).font(.headline).multilineTextAlignment(.leading).lineLimit(3)
                            Text(item.metadata.creators.map(\.label).joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            HStack { Text(item.metadata.itemType.uppercased()); Spacer(); Label("\(item.attachments.count)", systemImage: "paperclip") }.font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(NodusSpace.cardPadding).frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                        .nodusGlass(NodusGlass(.regular, tint: session.accent), in: NodusRadius.panelShape)
                    }
                    .buttonStyle(NodusCardButtonStyle()).contextMenu { rowMenu(item) }
                    .accessibilityIdentifier("workspace-open-library-\(safeIdentifier(item.id))")
                }
            }.padding(NodusSpace.page)
        }
    }

    @ViewBuilder private func rowMenu(_ item: AccountLibraryItem) -> some View {
        Button { openItem(item) } label: { Label("Open in tab", systemImage: "rectangle.on.rectangle") }
        Button { editor = item } label: { Label("Edit metadata", systemImage: "pencil") }
        Button { export([item]) } label: { Label("Export Markdown", systemImage: "square.and.arrow.up") }
        Button(role: showingTrash ? nil : .destructive) { setDeleted(item, !showingTrash) } label: { Label(showingTrash ? "Recover" : "Move to Trash", systemImage: showingTrash ? "arrow.uturn.backward" : "trash") }
    }

    private func bootstrap() async {
        loading = true
        defer { loading = false }
        do {
            let accountId: String
            if session.isDemo { accountId = "nodus-demo-account" }
            else { accountId = try await session.client.me().user.id }
            let directory = URL.applicationSupportDirectory.appendingPathComponent("global-library", isDirectory: true)
            let openedCatalog = try await AccountLibraryCatalog.open(accountId: accountId, directory: directory)
            let openedOutbox = try await AccountLibraryOutbox.open(accountId: accountId, directory: directory)
            catalog = openedCatalog; outbox = openedOutbox
            if session.isDemo { try await seedDemoIfNeeded(catalog: openedCatalog) }
            else { await sync() }
            try await reloadLocal()
#if DEBUG
            if ProcessInfo.processInfo.environment["NODUS_SHOW_TAB_DEMO"] == "1", workspaceTabs.tabs(in: section).isEmpty {
                for item in items.prefix(2) { openItem(item) }
            }
#endif
        } catch { self.error = error.localizedDescription }
    }

    private func sync() async {
        guard !session.isDemo, let catalog, let outbox, !syncing else { return }
        syncing = true; defer { syncing = false }
        do {
            _ = try await catalog.flushObjects(using: session.client)
            _ = try await outbox.flush(using: session.client)
            var cursor = try await catalog.cursor()
            repeat {
                let page = try await session.client.libraryChanges(since: cursor, limit: 100)
                try await catalog.apply(page)
                cursor = page.cursor
                if !page.hasMore { break }
            } while true
            var commandCursor = 0; var allCommands: [LibraryCommand] = []
            repeat {
                let page = try await session.client.libraryCommands(since: commandCursor, limit: 100)
                allCommands.append(contentsOf: page.commands); commandCursor = page.cursor
                if !page.hasMore { break }
            } while true
            commands = allCommands
            try await reloadLocal(); error = nil
        } catch { self.error = error.localizedDescription; try? await reloadLocal() }
    }

    private func reloadLocal() async throws {
        guard let catalog else { return }
        items = try await catalog.items(includeDeleted: true)
        collections = try await catalog.collections()
        savedSearches = try await catalog.savedSearches()
        viewPreferences = try await catalog.viewPreferences()
        if let remoteSort = viewPreferences?.sort.first {
            sort = switch remoteSort.field {
            case "title": .title
            case "creator": .creator
            case "year": .year
            default: .updated
            }
        }
        conflicts = try await catalog.conflicts()
        refreshOpenTabs()
    }

    private func seedDemoIfNeeded(catalog: AccountLibraryCatalog) async throws {
        guard try await catalog.items(includeDeleted: true).isEmpty, let descriptor = Collections.byPath["works"] else { return }
        let page = try await session.client.list(descriptor, in: session.connection.spaceId, query: nil, limit: 40, offset: 0)
        for row in page.items {
            let title = row.text("title") ?? row.text("label") ?? "Untitled"
            let creator = row.text("authors") ?? row.text("author")
            let metadata = AccountLibraryMetadata(
                title: title,
                itemType: row.text("item_type") ?? "book",
                creators: creator.map { [.init(name: $0)] } ?? [],
                abstract: row.text("abstract") ?? row.text("summary"),
                year: row.int("year"),
                language: row.text("language"),
                publisher: row.text("publisher"),
                doi: row.text("doi"),
                tags: row.text("tags")?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            )
            _ = try await catalog.upsertItem(AccountLibraryItem(id: "demo-library:\(row.string("nodus_id") ?? UUID().uuidString)", metadata: metadata, deviceId: "demo"), deviceId: "demo")
        }
    }

    private func openItem(_ item: AccountLibraryItem) {
        workspaceTabs.open(.init(id: "library:\(item.id)", title: item.metadata.title, systemImage: "doc.text", kind: .document, payload: .accountLibraryItem(item)), in: section)
    }

    private func refreshOpenTabs() {
        for item in items where workspaceTabs.tabs(in: section).contains(where: { $0.id == "library:\(item.id)" }) { openItem(item) }
    }

    private func create(metadata: AccountLibraryMetadata) {
        save(AccountLibraryItem(metadata: metadata, collectionIds: collectionId.map { [$0] } ?? [], deviceId: deviceId))
    }

    private func save(_ item: AccountLibraryItem) {
        guard !session.isDemo, let catalog, let outbox else { return }
        Task {
            do {
                let version = try await catalog.upsertItem(item, deviceId: deviceId)
                _ = try await outbox.enqueue(.record(version), title: item.metadata.title)
                try await reloadLocal(); if let updated = items.first(where: { $0.id == item.id }) { openItem(updated) }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func setDeleted(_ item: AccountLibraryItem, _ deleted: Bool) {
        guard !session.isDemo, let catalog, let outbox else { return }
        Task {
            if let version = try await catalog.setDeleted(recordId: item.id, deleted: deleted, deviceId: deviceId) {
                _ = try await outbox.enqueue(.record(version), title: item.metadata.title)
            }
            try await reloadLocal()
        }
    }

    private func setSelectionDeleted(_ deleted: Bool) { for item in items where selection.contains(item.id) { setDeleted(item, deleted) }; selection.removeAll(); selecting = false }
    private func toggle(_ id: String) { if !selection.insert(id).inserted { selection.remove(id) } }

    private func createCollection() {
        guard !session.isDemo, let catalog, let outbox else { return }
        let name = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines); guard !name.isEmpty else { return }
        Task {
            let value = AccountLibraryCollection(name: name, parentId: collectionId, position: collections.count, deviceId: deviceId)
            let version = try await catalog.upsertCollection(value, deviceId: deviceId)
            _ = try await outbox.enqueue(.record(version), title: value.name)
            try await reloadLocal(); collectionId = value.id
        }
    }

    private func saveSearch() {
        guard !session.isDemo, let catalog, let outbox else { return }
        Task {
            let search = AccountLibrarySavedSearch(name: savedSearchName.trimmingCharacters(in: .whitespacesAndNewlines), query: currentSmartQuery)
            let version = try await catalog.upsertSavedSearch(search, deviceId: deviceId)
            _ = try await outbox.enqueue(.record(version), title: search.name); try await reloadLocal()
        }
    }

    private var currentSmartQuery: JSONValue {
        var rules: [JSONValue] = []
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rules.append(.object(["id": .string(UUID().uuidString), "field": .string("title"), "operator": .string("contains"), "value": .string(query)]))
        }
        if let collectionId {
            rules.append(.object(["id": .string(UUID().uuidString), "field": .string("collection"), "operator": .string("equals"), "value": .string(collectionId)]))
        }
        if let itemType {
            rules.append(.object(["id": .string(UUID().uuidString), "field": .string("itemType"), "operator": .string("equals"), "value": .string(itemType)]))
        }
        return .object(["id": .string(UUID().uuidString), "mode": .string("all"), "rules": .array(rules)])
    }

    private func apply(_ search: AccountLibrarySavedSearch) {
        guard case .object(let group) = search.query, let rules = group["rules"]?.arrayValue else {
            if let legacy = search.query.stringValue { query = legacy }
            return
        }
        query = ""; collectionId = nil; itemType = nil
        for rule in rules {
            guard case .object(let value) = rule,
                  let field = value["field"]?.stringValue,
                  let operand = value["value"]?.stringValue else { continue }
            switch field {
            case "title", "abstract", "creator", "tag": query = operand
            case "collection": collectionId = operand
            case "itemType": itemType = operand
            default: continue
            }
        }
    }

    private func saveViewPreferences() {
        guard !session.isDemo, let catalog, let outbox, !loading else { return }
        var value = viewPreferences ?? AccountLibraryViewPreferences()
        value.sort = [.init(field: sort == .updated ? "updatedAt" : sort.rawValue, direction: sort == .title || sort == .creator ? "asc" : "desc")]
        value.updatedAt = ISO8601DateFormatter.nodusFractional.string(from: Date())
        viewPreferences = value
        Task {
            let version = try await catalog.upsertViewPreferences(value, deviceId: deviceId)
            _ = try await outbox.enqueue(.record(version), title: "Library view preferences")
        }
    }

    private func enqueueCommand(_ kind: LibraryCommandKind, title: String, payload: [String: JSONValue]) {
        guard let outbox else { return }
        Task {
            let command = AccountLibraryOutbox.QueuedCommand(idempotencyKey: "\(kind.rawValue):\(UUID().uuidString)", kind: kind, payload: payload)
            _ = try await outbox.enqueue(.command(command), title: title)
        }
    }

    private func enqueueMerge() {
        enqueueCommand(.merge, title: "Merge \(selection.count) references", payload: ["itemIds": .array(selection.sorted().map(JSONValue.string))])
    }

    private func cancel(_ command: LibraryCommand) {
        Task {
            do {
                _ = try await session.client.cancelLibraryCommand(id: command.id)
                await sync()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard !session.isDemo, let catalog, let outbox else { return }
        Task {
            do {
                for url in try result.get() {
                    let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    let type = UTType(filenameExtension: url.pathExtension)
                    let mime = type?.preferredMIMEType ?? "application/octet-stream"
                    let hash = try await catalog.stageObject(data, mime: mime)
                    var item = AccountLibraryItem(metadata: .init(title: url.deletingPathExtension().lastPathComponent, itemType: libraryItemType(type)), collectionIds: collectionId.map { [$0] } ?? [], deviceId: deviceId)
                    item.attachments = [.init(title: url.lastPathComponent, fileName: url.lastPathComponent, mimeType: mime, byteSize: data.count, sha256: hash)]
                    let version = try await catalog.upsertItem(item, deviceId: deviceId)
                    _ = try await outbox.enqueue(.record(version), title: item.metadata.title)
                }
                try await reloadLocal()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func libraryItemType(_ type: UTType?) -> String {
        if type?.conforms(to: .epub) == true { return "book" }
        if type?.conforms(to: .spreadsheet) == true { return "dataset" }
        if type?.conforms(to: .presentation) == true { return "presentation" }
        if type?.conforms(to: .html) == true { return "webpage" }
        return "document"
    }

    private func export(_ selected: [AccountLibraryItem]) {
        guard !selected.isEmpty else { return }
        var markdown = "# Nodus Library\n\n"
        for item in selected {
            markdown += "## \(item.metadata.title)\n\n"
            if !item.metadata.creators.isEmpty { markdown += "**\(item.metadata.creators.map(\.label).joined(separator: ", "))**"
                + (item.metadata.year.map { " (\($0))" } ?? "") + "\n\n" }
            if let abstract = item.metadata.abstract { markdown += abstract + "\n\n" }
            if let doi = item.metadata.doi { markdown += "DOI: \(doi)\n\n" }
            for note in item.notes ?? [] { markdown += "### \(note.title)\n\n\(note.markdown)\n\n" }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nodus-library-\(UUID().uuidString).md")
        do { try Data(markdown.utf8).write(to: url, options: .atomic); shareURL = url } catch { self.error = error.localizedDescription }
    }

    private func safeIdentifier(_ value: String) -> String { value.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression) }
}

private enum LibrarySort: String, CaseIterable, Identifiable {
    case updated, title, creator, year
    var id: String { rawValue }
    var title: String { switch self { case .updated: String(localized: "Updated"); case .title: String(localized: "Title"); case .creator: String(localized: "Creator"); case .year: String(localized: "Year") } }
}

private enum LibraryViewMode: String { case table, grid }

@MainActor
enum LibraryDeviceIdentity {
    static var current: String {
        let key = "nodus.account-library-device.v1"
        if let stored = UserDefaults.standard.string(forKey: key) { return stored }
        let value = "ios-\(UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString)"
        UserDefaults.standard.set(value, forKey: key); return value
    }
}

private struct LibraryItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    let item: AccountLibraryItem?
    let accent: Color
    let onSave: (AccountLibraryMetadata) -> Void
    @State private var title: String
    @State private var itemType: String
    @State private var creators: String
    @State private var year: String
    @State private var abstract: String
    @State private var doi: String
    @State private var tags: String

    init(item: AccountLibraryItem?, accent: Color, onSave: @escaping (AccountLibraryMetadata) -> Void) {
        self.item = item; self.accent = accent; self.onSave = onSave
        _title = State(initialValue: item?.metadata.title ?? "")
        _itemType = State(initialValue: item?.metadata.itemType ?? "document")
        _creators = State(initialValue: item?.metadata.creators.map(\.label).joined(separator: "; ") ?? "")
        _year = State(initialValue: item?.metadata.year.map(String.init) ?? "")
        _abstract = State(initialValue: item?.metadata.abstract ?? "")
        _doi = State(initialValue: item?.metadata.doi ?? "")
        _tags = State(initialValue: item?.metadata.tags.joined(separator: ", ") ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reference") {
                    TextField("Title", text: $title, axis: .vertical)
                    TextField("Type", text: $itemType)
                    TextField("Creators, separated by ;", text: $creators)
                    TextField("Year", text: $year).keyboardType(.numberPad)
                    TextField("DOI", text: $doi).textInputAutocapitalization(.never)
                    TextField("Tags, separated by commas", text: $tags)
                }
                Section("Abstract") { TextEditor(text: $abstract).frame(minHeight: 150) }
            }
            .navigationTitle(item == nil ? "New reference" : "Edit metadata")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var metadata = item?.metadata ?? .init(title: title)
                        metadata.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        metadata.itemType = itemType.trimmingCharacters(in: .whitespacesAndNewlines)
                        metadata.creators = creators.split(separator: ";").map { .init(name: $0.trimmingCharacters(in: .whitespaces)) }
                        metadata.year = Int(year); metadata.abstract = abstract.isEmpty ? nil : abstract
                        metadata.doi = doi.isEmpty ? nil : doi
                        metadata.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        onSave(metadata); dismiss()
                    }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).tint(accent)
                }
            }
        }
    }
}

private struct AccountLibraryReader: View {
    let session: SpaceSession
    let item: AccountLibraryItem
    let catalog: AccountLibraryCatalog?
    let isActive: Bool
    let onSave: (AccountLibraryItem) -> Void
    let onOpenRelation: (AccountLibraryItem) -> Void
    let onExport: ([AccountLibraryItem]) -> Void
    @State private var pane: Pane = .read
    @State private var previewURL: URL?
    @State private var loadingAttachment: String?
    @State private var noteTitle = ""
    @State private var noteBody = ""
    @State private var history: [LibraryRecordVersion] = []
    @State private var error: String?

    private enum Pane: String, CaseIterable, Identifiable {
        case read, metadata, notes, relations, history
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .read: "Read"
            case .metadata: "Metadata"
            case .notes: "Notes"
            case .relations: "Relations"
            case .history: "History"
            }
        }
        var systemImage: String {
            switch self {
            case .read: "book"
            case .metadata: "info.circle"
            case .notes: "note.text"
            case .relations: "link"
            case .history: "clock.arrow.circlepath"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(Pane.allCases) { candidate in paneButton(candidate).id(candidate.id) }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    .onChange(of: pane, initial: true) { _, value in
                        withAnimation(NodusMotion.quick) { proxy.scrollTo(value.id, anchor: .center) }
                    }
                }
                Divider().frame(height: 28)
                Button { onExport([item]) } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(session.accent.nodusReadable)
                        .background(session.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).stroke(session.accent.opacity(0.28)) }
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Export")
                .accessibilityHint("Exports this reference")
                .accessibilityIdentifier("library-reader-export")
                .accessibilityHidden(!isActive)
            }.padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(item.metadata.title).font(.largeTitle.bold())
                    if !item.metadata.creators.isEmpty { Text(item.metadata.creators.map(\.label).joined(separator: ", ")).font(.title3).foregroundStyle(.secondary) }
                    HStack { Text(item.metadata.itemType); if let year = item.metadata.year { Text("· \(year)") }; if let key = item.citationKey { Text("· @\(key)") } }.font(.caption.weight(.semibold)).foregroundStyle(session.accent.nodusReadable)
                    Divider()
                    switch pane {
                    case .read: readPane
                    case .metadata: metadataPane
                    case .notes: notesPane
                    case .relations: relationsPane
                    case .history: historyPane
                    }
                    if let error { NodusNotice(tone: .caution, title: "Reader action failed", message: LocalizedStringKey(error)) }
                }.padding(NodusSpace.page).frame(maxWidth: 980).frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .nodusPageBackdrop(accent: session.accent)
        .quickLookPreview($previewURL)
        .task(id: pane) {
            guard pane == .history, let catalog else { return }
            do { history = try await catalog.history(recordId: item.id); error = nil }
            catch { history = []; self.error = error.localizedDescription }
        }
    }

    private func paneButton(_ candidate: Pane) -> some View {
        let selected = pane == candidate
        return Button { pane = candidate } label: {
            HStack(spacing: 7) {
                Image(systemName: candidate.systemImage)
                    .font(.system(size: 15, weight: selected ? .semibold : .regular))
                    .frame(width: 20, height: 20)
                if selected {
                    Text(paneTitle(candidate))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, selected ? 12 : 0)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(selected ? session.accent.nodusReadable : Color.secondary)
            .background(selected ? session.accent.opacity(0.13) : Color.clear, in: Capsule())
            .overlay { Capsule().stroke(selected ? session.accent.opacity(0.3) : Color.clear) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(paneTitle(candidate))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("library-reader-pane-\(candidate.rawValue)")
    }

    private func paneTitle(_ candidate: Pane) -> LocalizedStringKey {
        switch candidate {
        case .notes: "Notes \(item.notes?.count ?? 0)"
        case .relations: "Relations \(item.relations?.count ?? 0)"
        default: candidate.title
        }
    }

    private var readPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let abstract = item.metadata.abstract, !abstract.isEmpty { Text(abstract).font(.body).lineSpacing(5).textSelection(.enabled) }
            if item.attachments.isEmpty { ContentUnavailableView("No attachments", systemImage: "paperclip", description: Text("Add a file from the Library catalogue.")) }
            ForEach(item.attachments.sorted { $0.position < $1.position }) { attachment in
                Button { open(attachment) } label: {
                    HStack { Image(systemName: "doc").foregroundStyle(session.accent.nodusReadable); VStack(alignment: .leading) { Text(attachment.title).fontWeight(.semibold); Text("\(attachment.mimeType) · \(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteSize), countStyle: .file))").font(.caption).foregroundStyle(.secondary) }; Spacer(); if loadingAttachment == attachment.id { ProgressView() } else { Image(systemName: "arrow.down.circle") } }
                        .padding().nodusGlass(NodusGlass(.regular, tint: session.accent), in: NodusRadius.panelShape)
                }.buttonStyle(.plain)
            }
        }
    }

    private var metadataPane: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
            metadataRow("Type", item.metadata.itemType); metadataRow("Publication", item.metadata.publicationTitle)
            metadataRow("Publisher", item.metadata.publisher); metadataRow("DOI", item.metadata.doi)
            metadataRow("ISBN", item.metadata.isbn.joined(separator: ", ")); metadataRow("Language", item.metadata.language)
            metadataRow("Tags", (item.metadata.tags + (item.localTags ?? [])).joined(separator: ", "))
            metadataRow("Updated", item.clock.updatedAt); metadataRow("Revision", String(item.clock.revision))
        }.textSelection(.enabled)
    }

    @ViewBuilder private func metadataRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty { GridRow { Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary); Text(value) }; Divider().gridCellUnsizedAxes(.horizontal) }
    }

    private var notesPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(item.notes ?? []) { note in
                VStack(alignment: .leading, spacing: 6) { Text(note.title).font(.headline); Text(note.markdown).textSelection(.enabled) }
                    .padding().frame(maxWidth: .infinity, alignment: .leading).nodusGlass(NodusGlass(.regular, tint: session.accent), in: NodusRadius.panelShape)
            }
            if !session.isDemo {
                TextField("Note title", text: $noteTitle)
                TextEditor(text: $noteBody).frame(minHeight: 130).padding(8).nodusGlass(NodusGlass(.regular, tint: session.accent), in: NodusRadius.panelShape)
                Button { var copy = item; copy.notes = (copy.notes ?? []) + [.init(title: noteTitle.isEmpty ? "Note" : noteTitle, markdown: noteBody)]; noteTitle = ""; noteBody = ""; onSave(copy) } label: { Label("Add note", systemImage: "plus") }.buttonStyle(NodusGlassButtonStyle(accent: session.accent)).disabled(noteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var relationsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            if item.relations?.isEmpty != false { ContentUnavailableView("No relations", systemImage: "link", description: Text("Relations created on Desktop will appear here and can open sibling reader tabs.")) }
            ForEach(item.relations ?? []) { relation in Label("\(relation.relationType) · \(relation.targetItemId)", systemImage: "arrow.right").padding().frame(maxWidth: .infinity, alignment: .leading).nodusGlass(NodusGlass(.regular, tint: session.accent), in: NodusRadius.panelShape) }
        }
    }

    private var historyPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(history) { version in
                HStack { VStack(alignment: .leading) { Text(version.versionId).font(.caption.monospaced()).lineLimit(1); Text(version.hlc).font(.caption2).foregroundStyle(.secondary) }; Spacer(); if version.winner == true { Label("Winner", systemImage: "checkmark.seal.fill") }; if version.conflicted == true { Label("Conflict", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) } }
                    .padding().nodusGlass(NodusGlass(.regular, tint: session.accent), in: NodusRadius.panelShape)
            }
        }
    }

    private func open(_ attachment: AccountLibraryAttachment) {
        guard let catalog else { return }
        loadingAttachment = attachment.id
        Task { do { previewURL = try await catalog.fetchObject(hash: attachment.sha256, mime: attachment.mimeType, using: session.client) } catch { self.error = error.localizedDescription }; loadingAttachment = nil }
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }
