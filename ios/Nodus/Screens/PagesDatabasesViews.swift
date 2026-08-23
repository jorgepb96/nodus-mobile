import NodusKit
import NodusUI
import SwiftUI
import UniformTypeIdentifiers

private let pagesDatabaseTables = [
    "pages", "page_blocks", "page_favorites", "page_links", "page_document_updates",
    "page_revisions", "page_comments", "page_comment_reactions", "page_comment_mentions",
    "workspace_actors", "workspace_groups", "workspace_group_members", "acl_entries",
    "db_databases", "db_data_sources", "db_columns", "db_rows", "db_cells", "db_views",
    "db_view_sources", "db_view_revisions", "db_select_options", "db_relations",
    "db_attachments", "db_row_templates", "db_template_runs", "db_row_hierarchy",
    "db_row_dependencies", "db_task_configs", "db_sprints", "db_sprint_rows",
    "automation_rules", "automation_runs", "automation_notifications", "database_forms",
    "database_form_fields", "database_form_submissions",
]

struct PagesWorkspaceView: View {
    @Environment(WorkspaceTabs.self) private var workspaceTabs
    @Environment(\.horizontalSizeClass) private var sizeClass
    let session: SpaceSession

    @State private var tables: [String: [Row]] = [:]
    @State private var pages: [PagesDatabasesParity.Page] = []
    @State private var query = ""
    @State private var outbox: OutboxController?
    @State private var error: String?
    @State private var showTrash = false

    private let section = "pages"
    private var activeId: String? { workspaceTabs.activeTabId(in: section) }
    private var activePage: PagesDatabasesParity.Page? { pages.first { $0.id == activeId } }
    private var visiblePages: [PagesDatabasesParity.Page] {
        guard !query.isEmpty else { return pages }
        return pages.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTabStrip(section: section, catalogueTitle: "Pages", catalogueImage: "note.text", accent: session.accent)
            if sizeClass == .regular {
                HStack(spacing: 0) {
                    pageTree.frame(width: 285)
                    Divider()
                    if let activePage { PageDocumentWorkspace(session: session, page: activePage, tables: $tables, outbox: outbox) }
                    else { pageCatalogue }
                }
            } else if let activePage {
                PageDocumentWorkspace(session: session, page: activePage, tables: $tables, outbox: outbox)
            } else {
                pageCatalogue
            }
        }
        .nodusPageBackdrop(accent: session.accent)
        .accessibilityIdentifier("pages-workspace")
        .task(id: session.publishedRevision) { await load() }
        .onChange(of: showTrash) { _, _ in rebuild() }
    }

    private var pageTree: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PAGES").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await createPage(parentId: activeId) } } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).disabled(outbox == nil)
                    .accessibilityLabel("Create page")
            }.padding(12)
            NodusSearchField(text: $query, prompt: "Search pages", accent: session.accent).padding(.horizontal, 9).padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(visiblePages) { page in pageTreeRow(page) }
                }.padding(.horizontal, 7)
            }
            Divider()
            Toggle("Trash", isOn: $showTrash).font(.caption).padding(11)
        }
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.48))
    }

    private func pageTreeRow(_ page: PagesDatabasesParity.Page) -> some View {
        Button { open(page) } label: {
            HStack(spacing: 7) {
                Color.clear.frame(width: CGFloat(page.depth) * 13, height: 1)
                Text(page.icon ?? "").frame(width: 18)
                if page.icon == nil { Image(systemName: page.state == "trashed" ? "trash" : "doc.text").frame(width: 18).foregroundStyle(.secondary) }
                Text(page.title).lineLimit(1)
                Spacer()
                if page.favorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(session.accent) }
            }
            .font(.caption)
            .padding(.horizontal, 8).frame(minHeight: 34)
            .background(page.id == activeId ? session.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverEffect(.highlight)
        .accessibilityIdentifier("page-open-\(page.id)")
        .contextMenu {
            Button { Task { await toggleFavorite(page) } } label: { Label(page.favorite ? "Remove favorite" : "Favorite", systemImage: "star") }
            Button { Task { await createPage(parentId: page.id) } } label: { Label("New subpage", systemImage: "plus") }
            Button(role: .destructive) { Task { await setTrashed(page, trashed: page.state != "trashed") } } label: {
                Label(page.state == "trashed" ? "Restore" : "Move to Trash", systemImage: page.state == "trashed" ? "arrow.uturn.backward" : "trash")
            }
        }
    }

    private var pageCatalogue: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                DesktopPageHeader(title: "Pages", subtitle: "Wiki, blocks, backlinks and access", systemImage: "note.text", accent: session.accent, trailing: {
                    Button { Task { await createPage(parentId: nil) } } label: { Label("New page", systemImage: "plus") }
                        .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent)).disabled(outbox == nil)
                })
                if sizeClass == .compact { NodusSearchField(text: $query, prompt: "Search pages", accent: session.accent) }
                if let error { NodusNotice(tone: .blocked, title: "Pages could not load", message: LocalizedStringKey(error)) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .compact ? 280 : 320), spacing: 10)], spacing: 10) {
                    ForEach(visiblePages) { page in
                        Button { open(page) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(page.icon ?? "📄").font(.title2); Spacer(); if page.favorite { Image(systemName: "star.fill").foregroundStyle(session.accent) } }
                                Text(page.title).font(.headline).lineLimit(2)
                                Text("Revision \(page.revision) · \(page.origin.replacingOccurrences(of: "_", with: " "))").font(.caption2).foregroundStyle(.secondary)
                            }.desktopContentRow(accent: session.accent)
                        }
                        .buttonStyle(NodusCardButtonStyle())
                        .accessibilityIdentifier("page-open-\(page.id)")
                    }
                }
            }.padding(NodusSpace.page).frame(maxWidth: 1120).frame(maxWidth: .infinity).nodusTopAnchor()
        }
    }

    private func open(_ page: PagesDatabasesParity.Page) {
        workspaceTabs.open(WorkspaceTab(
            id: page.id, title: page.title, systemImage: "doc.text", kind: .document,
            payload: .reference(kind: "page", id: page.id)
        ), in: section)
    }

    private func load() async {
        do {
            tables = try await databaseParityTables(session, pagesDatabaseTables)
            if outbox == nil { outbox = await OutboxController.open(session: session) }
            rebuild(); error = nil
#if DEBUG
            if ProcessInfo.processInfo.environment["NODUS_SHOW_TAB_DEMO"] == "1", workspaceTabs.tabs(in: section).isEmpty {
                pages.prefix(2).forEach(open)
                if let first = pages.first { workspaceTabs.activate(first.id, in: section) }
            }
#endif
        } catch { self.error = error.localizedDescription }
    }

    private func rebuild() {
        pages = PagesDatabasesParity.pages(in: tables, includeTrashed: showTrash)
    }

    private func createPage(parentId: String?) async {
        guard let outbox else { return }
        let id = "page_\(UUID().uuidString)"
        let now = ISO8601DateFormatter.nodusFractional.string(from: Date())
        var row: [String: JSONValue] = [
            "id": .string(id), "origin": .string("standalone"), "title": .string("Untitled page"),
            "state": .string("active"), "locked": .int(0), "full_width": .int(0), "revision": .int(1),
            "created_by": .string("mobile"), "updated_by": .string("mobile"),
            "created_at": .string(now), "updated_at": .string(now),
        ]
        row["parent_page_id"] = parentId.map(JSONValue.string) ?? .null
        tables["pages", default: []].append(Row(row)); rebuild()
        _ = await outbox.syncMutation(kind: .upsert, table: .pages, key: [id], row: row, title: "Create page")
        if let page = pages.first(where: { $0.id == id }) { open(page) }
    }

    private func toggleFavorite(_ page: PagesDatabasesParity.Page) async {
        guard let outbox else { return }
        if page.favorite {
            tables["page_favorites"]?.removeAll { $0.string("page_id") == page.id }
            _ = await outbox.syncMutation(kind: .delete, table: .pageFavorites, key: [page.id], title: "Remove page favorite")
        } else {
            let row: [String: JSONValue] = ["page_id": .string(page.id), "position": .int(0), "created_at": .string(ISO8601DateFormatter.nodusFractional.string(from: Date()))]
            tables["page_favorites", default: []].append(Row(row))
            _ = await outbox.syncMutation(kind: .upsert, table: .pageFavorites, key: [page.id], row: row, title: "Favorite \(page.title)")
        }
        rebuild()
    }

    private func setTrashed(_ page: PagesDatabasesParity.Page, trashed: Bool) async {
        guard let outbox, let index = tables["pages"]?.firstIndex(where: { $0.string("id") == page.id }) else { return }
        var row = tables["pages"]![index].columns
        row["state"] = .string(trashed ? "trashed" : "active")
        row["revision"] = .int(Int64(page.revision + 1))
        row["updated_at"] = .string(ISO8601DateFormatter.nodusFractional.string(from: Date()))
        tables["pages"]![index] = Row(row); rebuild()
        _ = await outbox.syncMutation(kind: .upsert, table: .pages, key: [page.id], row: row, title: trashed ? "Trash \(page.title)" : "Restore \(page.title)")
        if trashed { workspaceTabs.close(page.id, in: section) }
    }
}

private struct PageDocumentWorkspace: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let session: SpaceSession
    let page: PagesDatabasesParity.Page
    @Binding var tables: [String: [Row]]
    let outbox: OutboxController?

    @State private var title = ""
    @State private var blockDrafts: [String: String] = [:]
    @State private var inspector = "Links"
    @State private var comment = ""
    @State private var saving = false
    @State private var compactInspector = false

    private var blocks: [PagesDatabasesParity.Block] { PagesDatabasesParity.blocks(pageId: page.id, in: tables) }
    private var backlinks: [PagesDatabasesParity.Backlink] { PagesDatabasesParity.backlinks(pageId: page.id, in: tables) }
    private var comments: [Row] { (tables["page_comments"] ?? []).filter { $0.string("page_id") == page.id } }
    private var revisions: [Row] { (tables["page_revisions"] ?? []).filter { $0.string("page_id") == page.id }.sorted { ($0.int("revision") ?? 0) > ($1.int("revision") ?? 0) } }
    private var access: [Row] { (tables["acl_entries"] ?? []).filter { $0.string("resource_type") == "page" && $0.string("resource_id") == page.id } }

    var body: some View {
        VStack(spacing: 0) {
            documentHeader.padding(NodusSpace.page)
            Divider()
            if sizeClass == .regular {
                HStack(spacing: 0) { editor; Divider(); inspectorRail.frame(width: 320) }
            } else {
                if compactInspector { inspectorRail } else { editor }
            }
        }
        .onAppear { seedDrafts() }
        .onChange(of: page.id) { _, _ in seedDrafts() }
        .accessibilityIdentifier("page-document-\(page.id)")
    }

    private var documentHeader: some View {
        DesktopPageHeader(title: LocalizedStringKey(page.title), subtitle: "Revision \(page.revision) · \(blocks.count) blocks", systemImage: "doc.text", accent: session.accent, trailing: {
            HStack(spacing: 7) {
                if sizeClass == .compact {
                    Button { compactInspector.toggle() } label: { Image(systemName: compactInspector ? "doc.text" : "sidebar.right") }
                        .buttonStyle(NodusGlassButtonStyle(accent: session.accent)).accessibilityLabel(compactInspector ? "Show document" : "Show page details")
                }
                Menu {
                    Button { Task { await addBlock(type: "paragraph") } } label: { Label("Paragraph", systemImage: "text.alignleft") }
                    Button { Task { await addBlock(type: "heading_2") } } label: { Label("Heading", systemImage: "textformat.size") }
                    Button { Task { await addBlock(type: "task") } } label: { Label("Task", systemImage: "checkmark.square") }
                    Button { Task { await addBlock(type: "quote") } } label: { Label("Quote", systemImage: "quote.opening") }
                    Button { Task { await addBlock(type: "callout") } } label: { Label("Callout", systemImage: "lightbulb") }
                } label: { Label("Block", systemImage: "plus") }.buttonStyle(NodusGlassButtonStyle(accent: session.accent)).disabled(outbox == nil)
                Button { Task { await save() } } label: { if saving { ProgressView() } else { Label("Save", systemImage: "checkmark") } }
                    .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent)).disabled(outbox == nil || saving)
            }
        })
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Page title", text: $title, axis: .vertical).font(.largeTitle.bold()).textFieldStyle(.plain)
                ForEach(blocks) { block in blockEditor(block) }
                Button { Task { await addBlock(type: "paragraph") } } label: { Label("Add a block", systemImage: "plus") }
                    .buttonStyle(NodusGlassButtonStyle(accent: session.accent)).disabled(outbox == nil)
            }.padding(NodusSpace.page).frame(maxWidth: page.fullWidth ? .infinity : 850).frame(maxWidth: .infinity, alignment: .top).nodusTopAnchor()
        }.background(Color(uiColor: .systemBackground).opacity(0.34))
    }

    private func blockEditor(_ block: PagesDatabasesParity.Block) -> some View {
        HStack(alignment: .top, spacing: 9) {
            blockIcon(block.type).foregroundStyle(.secondary).frame(width: 22, height: 34)
            if block.type == "divider" { Divider().padding(.vertical, 16) }
            else {
                TextField("Type '/' for commands", text: Binding(
                    get: { blockDrafts[block.id] ?? block.text }, set: { blockDrafts[block.id] = $0 }
                ), axis: .vertical)
                .font(blockFont(block.type)).textFieldStyle(.plain).lineLimit(1...12).padding(.vertical, 6)
            }
            Menu {
                ForEach(["paragraph", "heading_1", "heading_2", "task", "toggle", "quote", "callout", "code"], id: \.self) { type in
                    Button(type.replacingOccurrences(of: "_", with: " ").capitalized) { Task { await changeBlock(block, type: type) } }
                }
                Divider()
                Button(role: .destructive) { Task { await deleteBlock(block) } } label: { Label("Delete block", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis").frame(width: 34, height: 34) }.buttonStyle(.plain)
        }
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(block.type == "callout" ? session.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private var inspectorRail: some View {
        VStack(spacing: 0) {
            Picker("Page details", selection: $inspector) {
                Text("Links").tag("Links"); Text("Comments").tag("Comments"); Text("History").tag("History"); Text("Access").tag("Access")
            }.pickerStyle(.segmented).padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch inspector {
                    case "Comments": commentsPanel
                    case "History": historyPanel
                    case "Access": accessPanel
                    default: linksPanel
                    }
                }.padding(11)
            }
        }.background(Color(uiColor: .secondarySystemBackground).opacity(0.45)).accessibilityIdentifier("page-inspector")
    }

    private var linksPanel: some View {
        Group {
            inspectorTitle("Backlinks", icon: "arrowshape.turn.up.left")
            if backlinks.isEmpty { Text("No page links here yet.").font(.caption).foregroundStyle(.secondary) }
            ForEach(backlinks) { link in
                VStack(alignment: .leading, spacing: 3) {
                    Text(link.label).font(.caption.weight(.semibold)); Text(link.sourcePageId).font(.caption2).foregroundStyle(.secondary)
                }.desktopContentRow(accent: link.broken ? .orange : session.accent)
            }
            inspectorTitle("Mentions", icon: "at")
            Text("Page and block mentions resolve against stable IDs and retain broken-link state.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var commentsPanel: some View {
        Group {
            inspectorTitle("Comments", icon: "bubble.left.and.bubble.right")
            ForEach(comments, id: \.columns) { row in
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.text("body") ?? "Comment").font(.caption)
                    HStack { Text(row.string("created_by") ?? "Member").font(.caption2).foregroundStyle(.secondary); Spacer(); if reactionCount(row.string("id")) > 0 { Text("✅ \(reactionCount(row.string("id")))").font(.caption2) } }
                }.desktopContentRow(accent: session.accent)
            }
            TextField("Reply or mention @member", text: $comment, axis: .vertical).textFieldStyle(.roundedBorder)
            Button { Task { await addComment() } } label: { Label("Comment", systemImage: "paperplane") }
                .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent)).disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || outbox == nil)
        }
    }

    private var historyPanel: some View {
        Group {
            inspectorTitle("Revision history", icon: "clock.arrow.circlepath")
            ForEach(revisions, id: \.columns) { row in
                VStack(alignment: .leading, spacing: 5) {
                    Text("Revision \(row.int("revision") ?? 0)").font(.caption.weight(.semibold))
                    Text(row.text("summary") ?? row.string("reason") ?? "Page update").font(.caption2).foregroundStyle(.secondary)
                    Button("Restore") { Task { await restoreRevision(row) } }.font(.caption).disabled(session.isDemo || outbox == nil)
                }.desktopContentRow(accent: session.accent)
            }
        }
    }

    private var accessPanel: some View {
        Group {
            inspectorTitle("Access", icon: "person.badge.key")
            ForEach(access, id: \.columns) { row in
                HStack { VStack(alignment: .leading) { Text(row.text("principal_name") ?? row.string("principal_id") ?? "Member").font(.caption.weight(.semibold)); Text(row.string("principal_type") ?? "actor").font(.caption2).foregroundStyle(.secondary) }; Spacer(); NodusChip(key: row.string("role") ?? "view", tint: session.accent) }.desktopContentRow(accent: session.accent)
            }
            Text("Inherited vault, page, database, view and row ACLs are resolved by Desktop; mobile only sends schema-checked entries.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func inspectorTitle(_ title: LocalizedStringKey, icon: String) -> some View { Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
    private func reactionCount(_ commentId: String?) -> Int { (tables["page_comment_reactions"] ?? []).filter { $0.string("comment_id") == commentId }.count }
    private func blockIcon(_ type: String) -> Image { Image(systemName: ["heading_1": "textformat.size.larger", "heading_2": "textformat.size", "task": "checkmark.square", "toggle": "chevron.right", "quote": "quote.opening", "callout": "lightbulb", "code": "chevron.left.forwardslash.chevron.right", "database_view": "tablecells" ][type] ?? "text.alignleft") }
    private func blockFont(_ type: String) -> Font { type == "heading_1" ? .title.bold() : type == "heading_2" ? .title2.bold() : type == "quote" ? .body.italic() : type == "code" ? .system(.body, design: .monospaced) : .body }

    private func seedDrafts() { title = page.title; blockDrafts = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0.text) }) }

    private func save() async {
        guard let outbox else { return }; saving = true; defer { saving = false }
        let now = ISO8601DateFormatter.nodusFractional.string(from: Date())
        if let index = tables["pages"]?.firstIndex(where: { $0.string("id") == page.id }) {
            var row = tables["pages"]![index].columns; row["title"] = .string(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled page" : title); row["revision"] = .int(Int64(page.revision + 1)); row["updated_at"] = .string(now); row["updated_by"] = .string("mobile")
            tables["pages"]![index] = Row(row)
            _ = await outbox.syncMutation(kind: .upsert, table: .pages, key: [page.id], row: row, title: "Save \(title)")
        }
        for block in blocks where blockDrafts[block.id] != block.text { await saveBlock(block, text: blockDrafts[block.id] ?? "", outbox: outbox) }
    }

    private func addBlock(type: String) async {
        guard let outbox else { return }
        let id = "block_\(UUID().uuidString)", now = ISO8601DateFormatter.nodusFractional.string(from: Date())
        let text = type.hasPrefix("heading") ? "New heading" : ""
        let row: [String: JSONValue] = ["id": .string(id), "page_id": .string(page.id), "parent_block_id": .null, "sort_order": .double((blocks.last?.order ?? -1) + 1), "type": .string(type), "content_json": .string(jsonObjectString(["text": .string(text)])), "normalized_text": .string(text), "revision": .int(1), "created_by": .string("mobile"), "updated_by": .string("mobile"), "created_at": .string(now), "updated_at": .string(now), "trashed_at": .null]
        tables["page_blocks", default: []].append(Row(row)); blockDrafts[id] = text
        _ = await outbox.syncMutation(kind: .upsert, table: .pageBlocks, key: [id], row: row, title: "Add page block")
    }

    private func saveBlock(_ block: PagesDatabasesParity.Block, text: String, outbox: OutboxController) async {
        guard let index = tables["page_blocks"]?.firstIndex(where: { $0.string("id") == block.id }) else { return }
        var row = tables["page_blocks"]![index].columns; var content = block.content; content["text"] = .string(text); row["content_json"] = .string(jsonObjectString(content)); row["normalized_text"] = .string(text); row["revision"] = .int(Int64(block.revision + 1)); row["updated_by"] = .string("mobile"); row["updated_at"] = .string(ISO8601DateFormatter.nodusFractional.string(from: Date())); tables["page_blocks"]![index] = Row(row)
        _ = await outbox.syncMutation(kind: .upsert, table: .pageBlocks, key: [block.id], row: row, title: "Save page block")
    }

    private func changeBlock(_ block: PagesDatabasesParity.Block, type: String) async {
        guard let outbox, let index = tables["page_blocks"]?.firstIndex(where: { $0.string("id") == block.id }) else { return }
        var row = tables["page_blocks"]![index].columns; row["type"] = .string(type); row["revision"] = .int(Int64(block.revision + 1)); row["updated_at"] = .string(ISO8601DateFormatter.nodusFractional.string(from: Date())); tables["page_blocks"]![index] = Row(row)
        _ = await outbox.syncMutation(kind: .upsert, table: .pageBlocks, key: [block.id], row: row, title: "Change page block")
    }

    private func deleteBlock(_ block: PagesDatabasesParity.Block) async {
        guard let outbox else { return }; tables["page_blocks"]?.removeAll { $0.string("id") == block.id }; blockDrafts[block.id] = nil
        _ = await outbox.syncMutation(kind: .delete, table: .pageBlocks, key: [block.id], title: "Delete page block")
    }

    private func addComment() async {
        guard let outbox else { return }; let id = "comment_\(UUID().uuidString)", now = ISO8601DateFormatter.nodusFractional.string(from: Date()), body = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let row: [String: JSONValue] = ["id": .string(id), "page_id": .string(page.id), "block_id": .null, "parent_comment_id": .null, "body": .string(body), "revision": .int(1), "created_by": .string("mobile"), "updated_by": .string("mobile"), "resolved_at": .null, "resolved_by": .null, "created_at": .string(now), "updated_at": .string(now)]
        tables["page_comments", default: []].append(Row(row)); comment = ""
        _ = await outbox.syncMutation(kind: .upsert, table: .pageComments, key: [id], row: row, title: "Comment on \(page.title)")
    }

    private func restoreRevision(_ row: Row) async {
        guard let revision = row.int("revision") else { return }
        _ = try? await session.client.createSpaceAction(idempotencyKey: "page-restore:\(page.id):\(revision)", kind: .pageRestoreRevision, payload: ["pageId": .string(page.id), "revision": .int(Int64(revision))], inputRevision: session.publishedRevision, in: session.connection.spaceId)
    }
}

enum DatabaseWorkspaceMode: Sendable { case catalogue, search, analysis }

struct DatabasesWorkspaceView: View {
    @Environment(WorkspaceTabs.self) private var workspaceTabs
    @Environment(\.horizontalSizeClass) private var sizeClass
    let session: SpaceSession
    var mode: DatabaseWorkspaceMode = .catalogue

    @State private var tables: [String: [Row]] = [:]
    @State private var databases: [PagesDatabasesParity.Database] = []
    @State private var query = ""
    @State private var outbox: OutboxController?
    @State private var error: String?

    private let section = "databases"
    private var activeId: String? { workspaceTabs.activeTabId(in: section) }
    private var activeDatabase: PagesDatabasesParity.Database? { databases.first { $0.id == activeId } }

    var body: some View {
        Group {
            switch mode {
            case .search: DatabaseSearchSurface(session: session, tables: $tables, databases: databases, open: open)
            case .analysis: DatabaseAnalysisSurface(session: session, tables: tables, databases: databases)
            case .catalogue: workspace
            }
        }
        .nodusPageBackdrop(accent: session.accent)
        .task(id: session.publishedRevision) { await load() }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            WorkspaceTabStrip(section: section, catalogueTitle: "Databases", catalogueImage: "tablecells", accent: session.accent)
            if sizeClass == .regular {
                HStack(spacing: 0) {
                    databaseSidebar.frame(width: 250)
                    Divider()
                    if let activeDatabase { DatabaseDetailWorkspace(session: session, database: activeDatabase, tables: $tables, outbox: outbox) }
                    else { catalogue }
                }
            } else if let activeDatabase {
                DatabaseDetailWorkspace(session: session, database: activeDatabase, tables: $tables, outbox: outbox)
            } else { catalogue }
        }.accessibilityIdentifier("databases-workspace")
    }

    private var databaseSidebar: some View {
        VStack(spacing: 0) {
            HStack { Text("DATABASES").font(.caption2.weight(.bold)).foregroundStyle(.secondary); Spacer(); Button { Task { await createDatabase() } } label: { Image(systemName: "plus") }.buttonStyle(.plain).disabled(outbox == nil) }.padding(12)
            NodusSearchField(text: $query, prompt: "Find a database", accent: session.accent).padding(.horizontal, 8).padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(filteredDatabases) { database in
                        Button { open(database) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: database.icon ?? "tablecells").foregroundStyle(session.accent)
                                VStack(alignment: .leading, spacing: 2) { Text(database.name).font(.caption.weight(.medium)).lineLimit(1); Text("\(database.rowCount) rows").font(.caption2).foregroundStyle(.secondary) }
                                Spacer()
                            }.padding(.horizontal, 9).frame(minHeight: 40).background(database.id == activeId ? session.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).hoverEffect(.highlight)
                    }
                }.padding(.horizontal, 7)
            }
        }.background(Color(uiColor: .secondarySystemBackground).opacity(0.48))
    }

    private var filteredDatabases: [PagesDatabasesParity.Database] {
        query.isEmpty ? databases : databases.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.shortId.localizedCaseInsensitiveContains(query) }
    }

    private var catalogue: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                DesktopPageHeader(title: "Databases", subtitle: "Typed properties, linked views and automations", systemImage: "tablecells", accent: session.accent, trailing: {
                    Button { Task { await createDatabase() } } label: { Label("New database", systemImage: "plus") }.buttonStyle(NodusPrimaryButtonStyle(accent: session.accent)).disabled(outbox == nil)
                })
                if sizeClass == .compact { NodusSearchField(text: $query, prompt: "Find a database", accent: session.accent) }
                if let error { NodusNotice(tone: .blocked, title: "Databases could not load", message: LocalizedStringKey(error)) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 10)], spacing: 10) {
                    ForEach(filteredDatabases) { database in
                        Button { open(database) } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack { Image(systemName: database.icon ?? "tablecells").font(.title2).foregroundStyle(session.accent); Spacer(); Text(database.shortId).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                                Text(database.name).font(.headline)
                                HStack { Label("\(database.rowCount) rows", systemImage: "list.bullet"); Spacer(); Label("\(PagesDatabasesParity.views(databaseId: database.id, in: tables).count) views", systemImage: "rectangle.3.group") }.font(.caption2).foregroundStyle(.secondary)
                            }.desktopContentRow(accent: session.accent)
                        }
                        .buttonStyle(NodusCardButtonStyle())
                        .accessibilityIdentifier("database-open-\(database.id)")
                    }
                }
            }.padding(NodusSpace.page).frame(maxWidth: 1120).frame(maxWidth: .infinity).nodusTopAnchor()
        }
    }

    private func open(_ database: PagesDatabasesParity.Database) {
        workspaceTabs.open(WorkspaceTab(id: database.id, title: database.name, systemImage: "tablecells", kind: .document, payload: .reference(kind: "database", id: database.id)), in: section)
    }

    private func load() async {
        do {
            tables = try await databaseParityTables(session, pagesDatabaseTables)
            databases = PagesDatabasesParity.databases(in: tables)
            if outbox == nil { outbox = await OutboxController.open(session: session) }
            error = nil
#if DEBUG
            if ProcessInfo.processInfo.environment["NODUS_SHOW_TAB_DEMO"] == "1", workspaceTabs.tabs(in: section).isEmpty {
                databases.prefix(2).forEach(open)
                if let first = databases.first { workspaceTabs.activate(first.id, in: section) }
            }
#endif
        }
        catch { self.error = error.localizedDescription }
    }

    private func createDatabase() async {
        guard let outbox else { return }; let id = "db_\(UUID().uuidString)", now = ISO8601DateFormatter.nodusFractional.string(from: Date())
        let row: [String: JSONValue] = ["id": .string(id), "short_id": .string("DB-\(UUID().uuidString.prefix(4).uppercased())"), "name": .string("Untitled database"), "icon": .string("tablecells"), "position": .int(Int64(databases.count)), "revision": .int(1), "created_by": .string("mobile"), "updated_by": .string("mobile"), "created_at": .string(now), "updated_at": .string(now)]
        tables["db_databases", default: []].append(Row(row))
        let columnId = "dcol_\(UUID().uuidString)", column: [String: JSONValue] = ["id": .string(columnId), "database_id": .string(id), "name": .string("Name"), "type": .string("title"), "position": .int(0), "config_json": .string("{}"), "revision": .int(1), "created_at": .string(now), "updated_at": .string(now)]
        tables["db_columns", default: []].append(Row(column)); databases = PagesDatabasesParity.databases(in: tables)
        _ = await outbox.syncMutation(kind: .upsert, table: .databases, key: [id], row: row, title: "Create database")
        _ = await outbox.syncMutation(kind: .upsert, table: .databaseColumns, key: [columnId], row: column, title: "Create title property")
        if let database = databases.first(where: { $0.id == id }) { open(database) }
    }
}

private struct DatabaseDetailWorkspace: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let session: SpaceSession
    let database: PagesDatabasesParity.Database
    @Binding var tables: [String: [Row]]
    let outbox: OutboxController?

    @State private var query = ""
    @State private var activeViewId: String?
    @State private var adHocLayout = "table"
    @State private var selectedRowId: String?
    @State private var showInspector = false
    @State private var sortColumnId: String?
    @State private var sortDirection: PagesDatabasesParity.SortDirection = .ascending
    @State private var creatingColumn = false
    @State private var importingCSV = false
    @State private var importMessage: String?

    private var columns: [PagesDatabasesParity.Column] { PagesDatabasesParity.columns(databaseId: database.id, in: tables) }
    private var allRows: [PagesDatabasesParity.DataRow] { PagesDatabasesParity.rows(databaseId: database.id, in: tables) }
    private var rows: [PagesDatabasesParity.DataRow] { PagesDatabasesParity.filteredRows(allRows, columns: columns, query: query, sortColumnId: sortColumnId, direction: sortDirection) }
    private var views: [PagesDatabasesParity.SavedView] { PagesDatabasesParity.views(databaseId: database.id, in: tables) }
    private var activeView: PagesDatabasesParity.SavedView? { views.first { $0.id == activeViewId } }
    private var layout: String { activeView?.layout ?? adHocLayout }
    private var selectedRow: PagesDatabasesParity.DataRow? { allRows.first { $0.id == selectedRowId } }
    private var csv: String {
        ([columns.map(\.name)] + rows.map { row in columns.map { PagesDatabasesParity.displayValue(column: $0, row: row, allRows: allRows, columns: columns) } })
            .map { $0.map(csvCell).joined(separator: ",") }.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(NodusSpace.page)
            Divider()
            viewStrip
            Divider()
            HStack(spacing: 0) {
                content
                if sizeClass == .regular, let selectedRow { Divider(); DatabaseRowInspector(session: session, database: database, row: selectedRow, tables: $tables, outbox: outbox).frame(width: 330) }
            }
        }
        .onAppear { if activeViewId == nil { activeViewId = views.first?.id; adHocLayout = views.first?.layout ?? "table" } }
        .onChange(of: database.id) { _, _ in activeViewId = views.first?.id; selectedRowId = nil }
        .nodusSheet(isPresented: $showInspector) { if let selectedRow { NavigationStack { DatabaseRowInspector(session: session, database: database, row: selectedRow, tables: $tables, outbox: outbox).navigationTitle("Row details") }.nodusModalClose(accent: session.accent) } }
        .nodusSheet(isPresented: $creatingColumn) { NewDatabaseColumnSheet(session: session, databaseId: database.id, tables: $tables, outbox: outbox) }
        .fileImporter(isPresented: $importingCSV, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            Task { await requestDesktopImport(url) }
        }
        .accessibilityIdentifier("database-detail-\(database.id)")
    }

    private var header: some View {
        DesktopPageHeader(title: LocalizedStringKey(database.name), subtitle: "\(database.shortId) · \(rows.count) of \(allRows.count) rows", systemImage: database.icon ?? "tablecells", accent: session.accent, trailing: {
            HStack(spacing: 7) {
                Menu {
                    Button { creatingColumn = true } label: { Label("New property", systemImage: "rectangle.split.1x2") }
                    Button { importingCSV = true } label: { Label("Import CSV", systemImage: "tablecells.badge.ellipsis") }.disabled(session.isDemo)
                    ShareLink(item: csv) { Label("Export CSV", systemImage: "square.and.arrow.up") }
                } label: { Label("Manage", systemImage: "ellipsis.circle") }.buttonStyle(NodusGlassButtonStyle(accent: session.accent))
                Button { Task { await addRow() } } label: { Label("New", systemImage: "plus") }.buttonStyle(NodusPrimaryButtonStyle(accent: session.accent)).disabled(outbox == nil)
            }
        })
    }

    private var viewStrip: some View {
        HStack(spacing: 7) {
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(views) { view in
                        Button { activeViewId = view.id; adHocLayout = view.layout } label: { Label(view.name, systemImage: layoutIcon(view.layout)).font(.caption) }
                            .buttonStyle(.bordered).tint(activeViewId == view.id ? session.accent : .secondary)
                    }
                    Menu {
                        ForEach(["table", "gallery", "board", "calendar", "timeline"], id: \.self) { candidate in Button { activeViewId = nil; adHocLayout = candidate } label: { Label(candidate.capitalized, systemImage: layoutIcon(candidate)) } }
                    } label: { Label("View", systemImage: "plus") }.buttonStyle(.bordered)
                }
            }.scrollIndicators(.hidden)
            Spacer(minLength: 0)
            Menu {
                Picker("Sort property", selection: $sortColumnId) { Text("Manual order").tag(String?.none); ForEach(columns) { Text($0.name).tag(Optional($0.id)) } }
                Picker("Direction", selection: $sortDirection) { Text("Ascending").tag(PagesDatabasesParity.SortDirection.ascending); Text("Descending").tag(PagesDatabasesParity.SortDirection.descending) }
            } label: { Image(systemName: "arrow.up.arrow.down") }.buttonStyle(NodusGlassButtonStyle(accent: session.accent)).accessibilityLabel("Sort rows")
        }.padding(.horizontal, 10).frame(minHeight: 44).background(Color(uiColor: .secondarySystemBackground).opacity(0.4))
    }

    private var content: some View {
        VStack(spacing: 0) {
            NodusSearchField(text: $query, prompt: "Filter rows and properties", accent: session.accent).padding(10)
            if let importMessage { Text(importMessage).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading) }
            Group {
                switch layout {
                case "gallery": gallery
                case "board", "kanban": board
                case "calendar": calendar
                case "timeline": timeline
                default: table
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var table: some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(rows) { row in databaseTableRow(row) }
                    } header: {
                        databaseTableHeader
                    }
                }
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
            .scrollIndicators(.visible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var databaseTableHeader: some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                HStack {
                    Image(systemName: propertyIcon(column.type))
                    Text(column.name).lineLimit(1)
                    if column.isReadOnly { Image(systemName: "lock.fill").font(.caption2) }
                    Spacer()
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: columnWidth(column), height: 38).padding(.horizontal, 9)
                .background(Color(uiColor: .secondarySystemBackground))
                .overlay(alignment: .trailing) { Divider() }
            }
        }
    }

    private func databaseTableRow(_ row: PagesDatabasesParity.DataRow) -> some View {
        Button { select(row) } label: {
            HStack(spacing: 0) {
                ForEach(columns) { column in databaseTableCell(column, row: row) }
            }
            .background(selectedRowId == row.id ? session.accent.opacity(0.11) : Color(uiColor: .systemBackground).opacity(0.35))
            .overlay(alignment: .bottom) { Divider() }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("database-row-\(row.id)")
    }

    private func databaseTableCell(_ column: PagesDatabasesParity.Column, row: PagesDatabasesParity.DataRow) -> some View {
        Text(PagesDatabasesParity.displayValue(column: column, row: row, allRows: allRows, columns: columns))
            .font(.caption).lineLimit(2)
            .frame(width: columnWidth(column), alignment: .leading)
            .frame(minHeight: 42)
            .padding(.horizontal, 9)
            .overlay(alignment: .trailing) { Divider() }
    }

    private var gallery: some View {
        ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) { ForEach(rows) { row in Button { select(row) } label: { VStack(alignment: .leading, spacing: 8) { RoundedRectangle(cornerRadius: 9).fill(session.accent.opacity(0.12)).frame(height: 92).overlay { Image(systemName: "doc.richtext").font(.largeTitle).foregroundStyle(session.accent) }; Text(rowTitle(row)).font(.headline).lineLimit(2); ForEach(columns.dropFirst().prefix(3)) { column in HStack { Text(column.name); Spacer(); Text(PagesDatabasesParity.displayValue(column: column, row: row, allRows: allRows, columns: columns)).lineLimit(1) }.font(.caption2).foregroundStyle(.secondary) } }.desktopContentRow(accent: selectedRowId == row.id ? session.accent : .secondary) }.buttonStyle(NodusCardButtonStyle()) } }.padding(10) }
    }

    private var board: some View {
        let groupColumn = columns.first { ["status", "select"].contains($0.type) }
        let groups = Dictionary(grouping: rows) { row in groupColumn.map { PagesDatabasesParity.displayValue(column: $0, row: row, allRows: allRows, columns: columns) } ?? "Uncategorized" }
        return ScrollView(.horizontal) { HStack(alignment: .top, spacing: 10) { ForEach(groups.keys.sorted(), id: \.self) { group in VStack(alignment: .leading, spacing: 8) { HStack { Text(group.isEmpty ? "No value" : group).font(.caption.weight(.semibold)); Spacer(); CountBadge(count: groups[group]?.count ?? 0, accent: session.accent) }; ForEach(groups[group] ?? []) { row in Button { select(row) } label: { VStack(alignment: .leading, spacing: 5) { Text(rowTitle(row)).font(.caption.weight(.semibold)); ForEach(columns.filter { $0.id != groupColumn?.id }.dropFirst().prefix(2)) { column in Text(PagesDatabasesParity.displayValue(column: column, row: row, allRows: allRows, columns: columns)).font(.caption2).foregroundStyle(.secondary).lineLimit(1) } }.desktopContentRow(accent: selectedRowId == row.id ? session.accent : .secondary) }.buttonStyle(NodusCardButtonStyle()) } }.frame(width: 245).padding(9).background(Color(uiColor: .secondarySystemBackground).opacity(0.45), in: RoundedRectangle(cornerRadius: 12)) } }.padding(10) }
    }

    private var calendar: some View {
        let dateColumn = columns.first { $0.type == "date" }
        return ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(rows.sorted { value(dateColumn, $0) < value(dateColumn, $1) }) { row in
                    Button { select(row) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(value(dateColumn, row).isEmpty ? "No date" : value(dateColumn, row))
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(rowTitle(row)).font(.headline)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.desktopContentRow(accent: selectedRowId == row.id ? session.accent : .secondary)
                    }.buttonStyle(NodusCardButtonStyle())
                }
            }.padding(10).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
    }

    private var timeline: some View {
        let dateColumn = columns.first { $0.type == "date" }
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.sorted { value(dateColumn, $0) < value(dateColumn, $1) }.enumerated()), id: \.element.id) { index, row in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            Circle().fill(session.accent).frame(width: 10, height: 10)
                            if index < rows.count - 1 { Rectangle().fill(session.accent.opacity(0.25)).frame(width: 2, height: 62) }
                        }
                        Button { select(row) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(value(dateColumn, row).isEmpty ? "Unscheduled" : value(dateColumn, row)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                Text(rowTitle(row)).font(.headline)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 25)
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(14).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
    }

    private func select(_ row: PagesDatabasesParity.DataRow) { selectedRowId = row.id; if sizeClass == .compact { showInspector = true } }
    private func rowTitle(_ row: PagesDatabasesParity.DataRow) -> String { columns.first(where: { $0.type == "title" }).map { PagesDatabasesParity.displayValue(column: $0, row: row, allRows: allRows, columns: columns) }?.nonEmpty ?? "Untitled row" }
    private func value(_ column: PagesDatabasesParity.Column?, _ row: PagesDatabasesParity.DataRow) -> String { column.map { PagesDatabasesParity.displayValue(column: $0, row: row, allRows: allRows, columns: columns) } ?? "" }
    private func columnWidth(_ column: PagesDatabasesParity.Column) -> CGFloat { column.type == "title" ? 250 : column.type == "formula" ? 125 : 160 }

    private func addRow() async {
        guard let outbox else { return }; let id = "drow_\(UUID().uuidString)", now = ISO8601DateFormatter.nodusFractional.string(from: Date())
        let row: [String: JSONValue] = ["id": .string(id), "database_id": .string(database.id), "position": .double((allRows.last?.position ?? -1) + 1), "unique_sequence": .int(Int64(allRows.count + 1)), "revision": .int(1), "created_by": .string("mobile"), "updated_by": .string("mobile"), "created_at": .string(now), "updated_at": .string(now)]
        tables["db_rows", default: []].append(Row(row)); _ = await outbox.syncMutation(kind: .upsert, table: .databaseRows, key: [id], row: row, title: "Add database row"); selectedRowId = id
        if sizeClass == .compact { showInspector = true }
    }

    private func requestDesktopImport(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 380_000, let text = String(data: data, encoding: .utf8) else { throw DatabaseImportError.unsupportedSize }
            let parsed = parseCSV(text)
            guard let headers = parsed.first, !headers.isEmpty, parsed.count > 1 else { throw DatabaseImportError.empty }
            let rows = Array(parsed.dropFirst().prefix(10_000)).map { row in
                Array((row + Array(repeating: "", count: max(0, headers.count - row.count))).prefix(headers.count))
            }
            let types = inferredDatabaseTypes(headers: headers, rows: rows)
            let payload: [String: JSONValue] = [
                "name": .string(url.deletingPathExtension().lastPathComponent),
                "headers": .array(headers.map(JSONValue.string)),
                "rows": .array(rows.map { .array($0.map(JSONValue.string)) }),
                "types": .array(types.map(JSONValue.string)),
            ]
            let result = try await session.client.createSpaceAction(
                idempotencyKey: "database-import:\(UUID().uuidString)", kind: .databaseImportCSV,
                payload: payload, inputRevision: session.publishedRevision, in: session.connection.spaceId
            )
            importMessage = "CSV queued for Desktop as \(result.action.id). It will appear after the vault republishes."
        } catch {
            importMessage = "CSV import could not be queued: \(error.localizedDescription)"
        }
    }
}

private struct DatabaseRowInspector: View {
    let session: SpaceSession
    let database: PagesDatabasesParity.Database
    let row: PagesDatabasesParity.DataRow
    @Binding var tables: [String: [Row]]
    let outbox: OutboxController?
    @State private var drafts: [String: String] = [:]
    @State private var tab = "Properties"
    @State private var saving = false

    private var columns: [PagesDatabasesParity.Column] { PagesDatabasesParity.columns(databaseId: database.id, in: tables) }
    private var allRows: [PagesDatabasesParity.DataRow] { PagesDatabasesParity.rows(databaseId: database.id, in: tables) }
    private var relations: [Row] { (tables["db_relations"] ?? []).filter { $0.string("row_id") == row.id } }
    private var attachments: [Row] { (tables["db_attachments"] ?? []).filter { $0.string("row_id") == row.id } }

    var body: some View {
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading) { Text(rowTitle).font(.headline).lineLimit(2); Text("Row \(row.id)").font(.caption2.monospaced()).foregroundStyle(.secondary) }; Spacer(); Button { Task { await save() } } label: { if saving { ProgressView() } else { Image(systemName: "checkmark") } }.buttonStyle(NodusPrimaryButtonStyle(accent: session.accent)).disabled(outbox == nil || saving) }.padding(12)
            Picker("Row panel", selection: $tab) { Text("Properties").tag("Properties"); Text("Relations").tag("Relations"); Text("Page").tag("Page") }.pickerStyle(.segmented).padding(.horizontal, 10).padding(.bottom, 10)
            Divider()
            ScrollView { VStack(alignment: .leading, spacing: 10) { if tab == "Relations" { relationsPanel } else if tab == "Page" { pagePanel } else { propertiesPanel } }.padding(11) }
        }.background(Color(uiColor: .secondarySystemBackground).opacity(0.42)).onAppear { seed() }.onChange(of: row.id) { _, _ in seed() }.accessibilityIdentifier("database-row-inspector")
    }

    private var propertiesPanel: some View {
        ForEach(columns) { column in
            VStack(alignment: .leading, spacing: 5) {
                Label(column.name, systemImage: propertyIcon(column.type)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                if column.isReadOnly { Text(PagesDatabasesParity.displayValue(column: column, row: row, allRows: allRows, columns: columns).nonEmpty ?? "No computed value").font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(9).background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7)) }
                else if ["select", "status"].contains(column.type) {
                    Picker(column.name, selection: Binding(get: { drafts[column.id] ?? "" }, set: { drafts[column.id] = $0 })) { Text("No value").tag(""); ForEach(column.options) { Text($0.label).tag($0.id) } }.pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                } else if column.type == "checkbox" { Toggle("Checked", isOn: Binding(get: { ["1", "true"].contains((drafts[column.id] ?? "").lowercased()) }, set: { drafts[column.id] = $0 ? "1" : "0" })) }
                else { TextField(column.name, text: Binding(get: { drafts[column.id] ?? "" }, set: { drafts[column.id] = $0 }), axis: .vertical).textFieldStyle(.roundedBorder).keyboardType(column.type == "number" ? .decimalPad : column.type == "email" ? .emailAddress : column.type == "url" ? .URL : .default) }
            }
        }
    }

    private var relationsPanel: some View {
        Group {
            Label("Relations", systemImage: "link").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if relations.isEmpty { Text("No linked rows, pages or Nodus entities.").font(.caption).foregroundStyle(.secondary) }
            ForEach(relations, id: \.columns) { relation in HStack { Image(systemName: "link"); VStack(alignment: .leading) { Text(relation.text("last_known_label") ?? relation.string("target_id") ?? "Linked item").font(.caption.weight(.semibold)); Text(relation.string("target_kind") ?? "entity").font(.caption2).foregroundStyle(.secondary) }; Spacer() }.desktopContentRow(accent: session.accent) }
            Label("Files", systemImage: "paperclip").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
            if attachments.isEmpty { Text("Files use the secure object channel and download on demand.").font(.caption).foregroundStyle(.secondary) }
            ForEach(attachments, id: \.columns) { file in Label(file.text("file_name") ?? "Attachment", systemImage: "doc").desktopContentRow(accent: session.accent) }
        }
    }

    private var pagePanel: some View {
        let page = (tables["pages"] ?? []).first { $0.string("row_id") == row.id }
        return Group {
            Label("Universal row page", systemImage: "doc.text").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let page { Text(page.text("title") ?? rowTitle).font(.headline); Text("The row page keeps blocks, comments, backlinks and ACLs under stable ID \(page.string("id") ?? "").").font(.caption).foregroundStyle(.secondary) }
            else { Text("Desktop will materialize the universal page when this queued row is applied.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var rowTitle: String { columns.first(where: { $0.type == "title" }).flatMap { drafts[$0.id]?.nonEmpty ?? PagesDatabasesParity.displayValue(column: $0, row: row, allRows: allRows, columns: columns).nonEmpty } ?? "Untitled row" }
    private func seed() { drafts = row.cells }
    private func save() async {
        guard let outbox else { return }; saving = true; defer { saving = false }
        let now = ISO8601DateFormatter.nodusFractional.string(from: Date())
        for column in columns where !column.isReadOnly && drafts[column.id] != row.cells[column.id] {
            let value = drafts[column.id] ?? "", existing = tables["db_cells"]?.first { $0.string("row_id") == row.id && $0.string("column_id") == column.id }
            var cell = existing?.columns ?? ["database_id": .string(database.id), "row_id": .string(row.id), "column_id": .string(column.id), "created_by": .string("mobile"), "created_at": .string(now), "revision": .int(1)]
            cell["value_type"] = .string(databaseCellType(column.type)); cell["value_text"] = .string(value); cell["value_reference"] = ["select", "status"].contains(column.type) ? .string(value) : .null; cell["value_number"] = column.type == "number" ? Double(value).map(JSONValue.double) ?? .null : .null; cell["updated_by"] = .string("mobile"); cell["updated_at"] = .string(now)
            tables["db_cells"]?.removeAll { $0.string("row_id") == row.id && $0.string("column_id") == column.id }; tables["db_cells", default: []].append(Row(cell))
            _ = await outbox.syncMutation(kind: value.isEmpty ? .delete : .upsert, table: .databaseCells, key: [row.id, column.id], row: value.isEmpty ? nil : cell, title: "Update \(column.name)")
        }
    }
}

private struct NewDatabaseColumnSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: SpaceSession
    let databaseId: String
    @Binding var tables: [String: [Row]]
    let outbox: OutboxController?
    @State private var name = ""
    @State private var type = "text"

    var body: some View {
        NavigationStack {
            Form {
                TextField("Property name", text: $name)
                Picker("Type", selection: $type) { ForEach(["text", "number", "date", "status", "multi_select", "checkbox", "person", "url", "email", "files", "relation", "rollup", "formula"], id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) } }
                Text(["formula", "rollup"].contains(type) ? "Computed properties are configured safely on Desktop and their materialized values remain queryable here." : "The property is written through the same typed mutation ledger as Desktop.").font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("New property").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Create") { Task { await create() } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || outbox == nil) } }
        }.nodusModalClose(accent: session.accent)
    }

    private func create() async {
        guard let outbox else { return }; let id = "dcol_\(UUID().uuidString)", now = ISO8601DateFormatter.nodusFractional.string(from: Date()), position = (tables["db_columns"] ?? []).filter { $0.string("database_id") == databaseId }.count
        let row: [String: JSONValue] = ["id": .string(id), "database_id": .string(databaseId), "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)), "type": .string(type), "position": .int(Int64(position)), "config_json": .string("{}"), "revision": .int(1), "created_by": .string("mobile"), "updated_by": .string("mobile"), "created_at": .string(now), "updated_at": .string(now)]
        tables["db_columns", default: []].append(Row(row)); _ = await outbox.syncMutation(kind: .upsert, table: .databaseColumns, key: [id], row: row, title: "Create \(name)"); dismiss()
    }
}

private struct DatabaseSearchSurface: View {
    let session: SpaceSession
    @Binding var tables: [String: [Row]]
    let databases: [PagesDatabasesParity.Database]
    let open: (PagesDatabasesParity.Database) -> Void
    @State private var query = ""

    private var hits: [(PagesDatabasesParity.Database, PagesDatabasesParity.DataRow, String)] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return databases.flatMap { database -> [(PagesDatabasesParity.Database, PagesDatabasesParity.DataRow, String)] in
            let columns = PagesDatabasesParity.columns(databaseId: database.id, in: tables), rows = PagesDatabasesParity.rows(databaseId: database.id, in: tables)
            return rows.compactMap { row in
                let matches = columns.compactMap { column -> String? in let value = PagesDatabasesParity.displayValue(column: column, row: row, allRows: rows, columns: columns); return value.localizedCaseInsensitiveContains(query) ? "\(column.name): \(value)" : nil }
                return matches.first.map { (database, row, $0) }
            }
        }
    }

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 10) { DesktopPageHeader(title: "Search", subtitle: "Pages, rows, cells and attachments", systemImage: "magnifyingglass", accent: session.accent); NodusSearchField(text: $query, prompt: "Search every database", accent: session.accent); ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in Button { open(hit.0) } label: { HStack { Image(systemName: hit.0.icon ?? "tablecells").foregroundStyle(session.accent); VStack(alignment: .leading) { Text(hit.2).font(.callout.weight(.medium)).lineLimit(2); Text(hit.0.name).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "arrow.up.right") }.desktopContentRow(accent: session.accent) }.buttonStyle(NodusCardButtonStyle()) }; if hits.isEmpty { ContentUnavailableView(query.isEmpty ? "Search databases" : "No matches", systemImage: "magnifyingglass", description: Text(query.isEmpty ? "Search database names, page blocks and typed cells." : "Try a broader term.")) } }.padding(NodusSpace.page).frame(maxWidth: 900).frame(maxWidth: .infinity).nodusTopAnchor() }.accessibilityIdentifier("database-search")
    }
}

private struct DatabaseAnalysisSurface: View {
    let session: SpaceSession
    let tables: [String: [Row]]
    let databases: [PagesDatabasesParity.Database]
    private var formulas: Int { (tables["db_columns"] ?? []).filter { $0.string("type") == "formula" }.count }
    private var relations: Int { (tables["db_relations"] ?? []).count }
    private var automations: [Row] { tables["automation_rules"] ?? [] }
    private var forms: [Row] { tables["database_forms"] ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                DesktopPageHeader(title: "Analysis", subtitle: "Charts, forms and automation audit", systemImage: "chart.bar", accent: session.accent)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                    metric("Databases", databases.count, "tablecells")
                    metric("Rows", databases.reduce(0) { $0 + $1.rowCount }, "list.bullet")
                    metric("Formulas", formulas, "function")
                    metric("Relations", relations, "link")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label("Row distribution", systemImage: "chart.bar.xaxis").font(.headline)
                    ForEach(databases) { database in
                        HStack {
                            Text(database.name).font(.caption).frame(width: 150, alignment: .leading).lineLimit(1)
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 4).fill(session.accent.opacity(0.2)).overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4).fill(session.accent).frame(width: proxy.size.width * CGFloat(database.rowCount) / CGFloat(max(1, databases.map(\.rowCount).max() ?? 1)))
                                }
                            }.frame(height: 12)
                            Text("\(database.rowCount)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }.desktopContentRow(accent: session.accent)
                    }
                }
                VStack(alignment: .leading, spacing: 9) {
                    Label("Automations", systemImage: "bolt").font(.headline)
                    ForEach(automations, id: \.columns) { row in
                        HStack {
                            VStack(alignment: .leading) { Text(row.text("name") ?? "Automation").font(.callout.weight(.medium)); Text(row.bool("enabled") == false ? "Paused" : "Active").font(.caption2).foregroundStyle(.secondary) }
                            Spacer(); NodusChip(key: row.bool("enabled") == false ? "paused" : "active", tint: row.bool("enabled") == false ? .secondary : session.accent)
                        }.desktopContentRow(accent: session.accent)
                    }
                }
                VStack(alignment: .leading, spacing: 9) {
                    Label("Forms", systemImage: "list.clipboard").font(.headline)
                    ForEach(forms, id: \.columns) { row in
                        HStack {
                            VStack(alignment: .leading) { Text(row.text("name") ?? "Form").font(.callout.weight(.medium)); Text("/\(row.string("slug") ?? "form") · \(row.string("access") ?? "private")").font(.caption2).foregroundStyle(.secondary) }
                            Spacer(); Image(systemName: row.bool("active") == false ? "pause.circle" : "checkmark.circle.fill").foregroundStyle(session.accent)
                        }.desktopContentRow(accent: session.accent)
                    }
                }
            }.padding(NodusSpace.page).frame(maxWidth: 1040).frame(maxWidth: .infinity).nodusTopAnchor()
        }.accessibilityIdentifier("database-analysis")
    }
    private func metric(_ title: LocalizedStringKey, _ value: Int, _ icon: String) -> some View { VStack(alignment: .leading, spacing: 7) { Image(systemName: icon).foregroundStyle(session.accent); Text("\(value)").font(.title.bold().monospacedDigit()); Text(title).font(.caption).foregroundStyle(.secondary) }.desktopContentRow(accent: session.accent) }
}

@MainActor
func databaseParityTables(_ session: SpaceSession, _ names: [String]) async throws -> [String: [Row]] {
    let fixture = debugDatabasesFixture()
    if let mirror = session.mirror {
        var result: [String: [Row]] = [:]
        for name in names { result[name] = try await mirror.allRows(table: name) }
        for name in names where fixture[name] != nil { result[name] = fixture[name] }
        return result
    }
    let snapshot = try await session.client.snapshot(in: session.connection.spaceId)
    return Dictionary(uniqueKeysWithValues: names.map { ($0, fixture[$0] ?? snapshot.tables[$0] ?? []) })
}

private func debugDatabasesFixture() -> [String: [Row]] {
#if DEBUG
    guard ProcessInfo.processInfo.environment["NODUS_VAULT_TYPE_OVERRIDE"] == "databases",
          let url = Bundle.main.url(forResource: "databases-fixture", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let object = try? JSONDecoder().decode([String: JSONValue].self, from: data)
    else { return [:] }
    return object.compactMapValues { $0.arrayValue?.compactMap { $0.objectValue.map(Row.init) } }
#else
    return [:]
#endif
}

private func layoutIcon(_ layout: String) -> String { ["table": "tablecells", "gallery": "square.grid.2x2", "board": "rectangle.3.group", "kanban": "rectangle.3.group", "calendar": "calendar", "timeline": "timeline.selection", "chart": "chart.bar", "map": "map", "feed": "list.bullet.rectangle" ][layout] ?? "tablecells" }
private func propertyIcon(_ type: String) -> String { ["title": "textformat", "rich_text": "text.alignleft", "text": "text.alignleft", "number": "number", "date": "calendar", "time": "clock", "select": "tag", "status": "circle.dashed", "multi_select": "tag.fill", "checkbox": "checkmark.square", "person": "person", "url": "link", "email": "envelope", "phone": "phone", "location": "mappin", "files": "paperclip", "attachment": "paperclip", "relation": "link", "rollup": "square.stack.3d.up", "formula": "function", "ai": "sparkles", "ai_image": "photo.badge.plus" ][type] ?? "textformat" }
private func databaseCellType(_ type: String) -> String { type == "number" ? "number" : type == "date" ? "date" : ["select", "status", "relation"].contains(type) ? "reference" : type == "multi_select" ? "json" : "text" }
private func jsonObjectString(_ object: [String: JSONValue]) -> String { (try? JSONEncoder().encode(JSONValue.object(object))).flatMap { String(data: $0, encoding: .utf8) } ?? "{}" }
private func csvCell(_ value: String) -> String { "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\"" }

private enum DatabaseImportError: LocalizedError {
    case unsupportedSize, empty
    var errorDescription: String? {
        switch self {
        case .unsupportedSize: "Choose a UTF-8 CSV smaller than 380 KB for a typed Desktop handoff."
        case .empty: "The CSV needs a header and at least one data row."
        }
    }
}

/// RFC-4180 essentials used before the typed payload crosses devices: quoted commas, escaped
/// quotes and CRLF. Desktop receives cells, never a filesystem path it cannot safely resolve.
private func parseCSV(_ source: String) -> [[String]] {
    var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
    let characters = Array(source)
    var index = 0
    while index < characters.count {
        let character = characters[index]
        if character == "\"" {
            if quoted, index + 1 < characters.count, characters[index + 1] == "\"" { field.append("\""); index += 1 }
            else { quoted.toggle() }
        } else if character == ",", !quoted { row.append(field); field = "" }
        else if (character == "\n" || character == "\r"), !quoted {
            if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" { index += 1 }
            row.append(field); field = ""
            if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
            row = []
        } else { field.append(character) }
        index += 1
    }
    if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
    return rows
}

private func inferredDatabaseTypes(headers: [String], rows: [[String]]) -> [String] {
    headers.indices.map { column in
        if column == 0 { return "title" }
        let values = rows.compactMap { column < $0.count ? $0[column].trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty : nil }
        guard !values.isEmpty else { return "text" }
        if values.allSatisfy({ Double($0) != nil }) { return "number" }
        if values.allSatisfy({ ["true", "false", "yes", "no", "1", "0"].contains($0.lowercased()) }) { return "checkbox" }
        if values.allSatisfy({ $0.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil }) { return "date" }
        return "text"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
