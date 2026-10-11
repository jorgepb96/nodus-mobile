import NodusKit
import NodusUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

private struct WorldEntityField: Identifiable, Hashable {
    enum Kind: Hashable { case line, prose, integer, choice([String]), toggle }
    let key: String
    let label: String
    let kind: Kind
    var id: String { key }
}

private struct WorldEntityDefinition {
    let route: NodusRoute
    let table: MutableTable
    let idField: String
    let titleField: String
    let title: String
    let icon: String
    let fields: [WorldEntityField]
    let fixed: [String: JSONValue]

    var section: String { route.rawValue }

    func includes(_ row: Row) -> Bool {
        // A default value for a new character is not a catalogue filter.
        route == .characters || fixed.allSatisfy { row.string($0.key) == $0.value.stringValue }
    }

    func title(of row: Row) -> String {
        row.text(titleField) ?? "Untitled"
    }

    static func forRoute(_ route: NodusRoute) -> WorldEntityDefinition? {
        switch route {
        case .encyclopedia:
            return .init(
                route: route, table: .worldArticles, idField: "article_id", titleField: "title",
                title: "Encyclopedia", icon: "books.vertical",
                fields: [
                    .init(key: "title", label: "Title", kind: .line),
                    .init(key: "category", label: "Category", kind: .choice(["magic", "religion", "language", "creature", "species", "artifact", "technology", "concept", "event", "organization", "flora", "fauna", "custom", "other"])),
                    .init(key: "summary", label: "Summary", kind: .prose),
                    .init(key: "body", label: "Article", kind: .prose),
                    .init(key: "aka", label: "Also known as", kind: .prose),
                    .init(key: "notes", label: "Notes", kind: .prose),
                ], fixed: [:]
            )
        case .characters:
            return .init(
                route: route, table: .persons, idField: "person_id", titleField: "display_name",
                title: "Characters", icon: "person.2",
                fields: [
                    .init(key: "display_name", label: "Name", kind: .line),
                    .init(key: "birth_date", label: "Born", kind: .line),
                    .init(key: "death_date", label: "Died", kind: .line),
                    .init(key: "biography", label: "Biography", kind: .prose),
                    .init(key: "notes", label: "Notes", kind: .prose),
                ], fixed: ["sex": .string("unknown")]
            )
        case .places:
            return .init(
                route: route, table: .places, idField: "place_id", titleField: "name",
                title: "Places", icon: "map",
                fields: [
                    .init(key: "name", label: "Name", kind: .line),
                    .init(key: "kind", label: "Kind", kind: .line),
                    .init(key: "parent_id", label: "Parent place", kind: .line),
                    .init(key: "latitude", label: "Latitude", kind: .line),
                    .init(key: "longitude", label: "Longitude", kind: .line),
                    .init(key: "notes", label: "Notes", kind: .prose),
                ], fixed: [:]
            )
        case .factions, .cultures, .dynasties:
            let kind = route == .factions ? "faction" : route == .cultures ? "culture" : "house"
            let title = route == .factions ? "Factions" : route == .cultures ? "Cultures" : "Dynasties"
            return .init(
                route: route, table: .worldGroups, idField: "group_id", titleField: "name",
                title: title, icon: route == .dynasties ? "shield" : "person.3",
                fields: [
                    .init(key: "name", label: "Name", kind: .line),
                    .init(key: "summary", label: "Summary", kind: .prose),
                    .init(key: "description", label: "Description", kind: .prose),
                    .init(key: "status", label: "Status", kind: .choice(["active", "dormant", "extinct"])),
                    .init(key: "parent_id", label: "Parent group", kind: .line),
                    .init(key: "seat_place_id", label: "Seat", kind: .line),
                    .init(key: "founded_year", label: "Founded", kind: .integer),
                    .init(key: "ended_year", label: "Ended", kind: .integer),
                    .init(key: "visual_seed", label: "Visual identity", kind: .prose),
                    .init(key: "notes", label: "Notes", kind: .prose),
                ], fixed: ["kind": .string(kind)]
            )
        case .scenes:
            return .init(
                route: route, table: .worldScenes, idField: "scene_id", titleField: "title",
                title: "Scenes", icon: "rectangle.stack",
                fields: [
                    .init(key: "title", label: "Title", kind: .line),
                    .init(key: "summary", label: "Summary", kind: .prose),
                    .init(key: "status", label: "Status", kind: .choice(["outline", "draft", "written"])),
                    .init(key: "place_id", label: "Place", kind: .line),
                    .init(key: "world_year", label: "World year", kind: .integer),
                    .init(key: "world_day", label: "World day", kind: .integer),
                    .init(key: "narrative_order", label: "Narrative order", kind: .integer),
                    .init(key: "notes", label: "Notes", kind: .prose),
                ], fixed: [:]
            )
        case .conflicts, .arcs:
            let kind = route == .conflicts ? "conflict" : "arc"
            return .init(
                route: route, table: .worldThreads, idField: "thread_id", titleField: "title",
                title: route == .conflicts ? "Conflicts" : "Story arcs",
                icon: route == .conflicts ? "scale.3d" : "point.topleft.down.to.point.bottomright.curvepath",
                fields: [
                    .init(key: "title", label: "Title", kind: .line),
                    .init(key: "pitch", label: "Pitch", kind: .prose),
                    .init(key: "stakes", label: "Stakes", kind: .prose),
                    .init(key: "scope", label: "Scope", kind: .choice(["external", "background"])),
                    .init(key: "status", label: "Status", kind: .choice(["open", "resolved", "archived"])),
                    .init(key: "resolution", label: "Resolution", kind: .prose),
                    .init(key: "notes", label: "Notes", kind: .prose),
                ], fixed: ["kind": .string(kind)]
            )
        case .rules:
            return .init(
                route: route, table: .worldRules, idField: "rule_id", titleField: "title",
                title: "World rules", icon: "lock",
                fields: [
                    .init(key: "title", label: "Title", kind: .line),
                    .init(key: "statement", label: "Rule", kind: .prose),
                    .init(key: "cost", label: "Cost", kind: .prose),
                    .init(key: "limits", label: "Limits", kind: .prose),
                    .init(key: "hardness", label: "Hardness", kind: .choice(["physical", "costly", "social"])),
                    .init(key: "scope_kind", label: "Scope", kind: .choice(["world", "group", "place"])),
                    .init(key: "scope_id", label: "Scope entry", kind: .line),
                    .init(key: "status", label: "Status", kind: .choice(["canon", "tentative", "retired"])),
                ], fixed: [:]
            )
        case .questions:
            return .init(
                route: route, table: .worldQuestions, idField: "question_id", titleField: "question",
                title: "Open questions", icon: "questionmark.circle",
                fields: [
                    .init(key: "question", label: "Question", kind: .prose),
                    .init(key: "status", label: "Status", kind: .choice(["open", "answered", "parked"])),
                    .init(key: "blocking", label: "Blocks writing", kind: .toggle),
                    .init(key: "anchor_kind", label: "Anchor kind", kind: .line),
                    .init(key: "anchor_id", label: "Anchor", kind: .line),
                ], fixed: ["origin": .string("author")]
            )
        default:
            return nil
        }
    }
}

/// Desktop-style catalogue and closeable dossiers for every authored world entity.
struct WorldEntityWorkspaceView: View {
    @Environment(WorkspaceTabs.self) private var workspaceTabs
    @Environment(\.horizontalSizeClass) private var sizeClass

    let session: SpaceSession
    let route: NodusRoute
    var initialRowID: String? = nil

    @State private var rows: [Row] = []
    @State private var relatedTables: [String: [Row]] = [:]
    @State private var assetRefs: [SnapshotAssetRef] = []
    @State private var pendingImageData: [String: Data] = [:]
    @State private var query = ""
    @State private var loading = true
    @State private var error: String?
    @State private var outbox: OutboxController?
    @State private var editorRow: Row?
    @State private var isCreating = false

    private var definition: WorldEntityDefinition { WorldEntityDefinition.forRoute(route)! }
    private var activeId: String? { workspaceTabs.activeTabId(in: definition.section) }
    private var filtered: [Row] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        return rows.filter { row in
            definition.includes(row) && (needle.isEmpty || row.searchableText.localizedLowercase.contains(needle))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTabStrip(
                section: definition.section,
                catalogueTitle: definition.title,
                catalogueImage: definition.icon,
                accent: session.accent
            )
            ZStack {
                catalogue
                    .opacity(activeId == nil ? 1 : 0)
                    .allowsHitTesting(activeId == nil)
                    .accessibilityHidden(activeId != nil)
                ForEach(workspaceTabs.tabs(in: definition.section)) { tab in
                    if case .row(let row) = tab.payload {
                        WorldEntityDossier(
                            session: session,
                            definition: definition,
                            row: currentRow(for: row),
                            relatedTables: relatedTables,
                            assetRefs: assetRefs,
                            pendingImageData: pendingImageData,
                            onAttachImage: supportsImages ? { data in Task { await attachImage(data, to: currentRow(for: row)) } } : nil,
                            onEdit: { editorRow = currentRow(for: row) },
                            onDelete: { Task { await delete(currentRow(for: row), tabId: tab.id) } }
                        )
                        .opacity(activeId == tab.id ? 1 : 0)
                        .allowsHitTesting(activeId == tab.id)
                        .accessibilityHidden(activeId != tab.id)
                    }
                }
            }
        }
        .accessibilityIdentifier("world-workspace-\(route.rawValue)")
        .task(id: session.publishedRevision) { await load() }
        .nodusSheet(isPresented: Binding(
            get: { editorRow != nil || isCreating },
            set: { if !$0 { editorRow = nil; isCreating = false } }
        )) {
            NavigationStack {
                WorldEntityEditor(
                    definition: definition,
                    initial: editorRow,
                    accent: session.accent,
                    onSave: { row in
                        Task { await save(row, isNew: isCreating) }
                    }
                )
            }
            .nodusModalClose(accent: session.accent)
        }
    }

    private var catalogue: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .compact ? 280 : 310), spacing: 9)], spacing: 9) {
                ForEach(filtered, id: \.columns) { row in
                    Button { open(row) } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Image(systemName: definition.icon).foregroundStyle(session.accent.nodusReadable)
                                Spacer()
                                if let status = row.text("status") { NodusChip(key: status, tint: session.accent) }
                            }
                            Text(definition.title(of: row)).font(.headline).lineLimit(2)
                            if let summary = row.text("summary") ?? row.text("pitch") ?? row.text("statement") ?? row.text("notes") {
                                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                        .desktopContentRow(accent: session.accent)
                    }
                    .buttonStyle(NodusCardButtonStyle())
                    .accessibilityIdentifier("world-catalogue-\(definition.table.rawValue)-\(row.string(definition.idField) ?? "")")
                }
            }
            if loading { ProgressView().tint(session.accent).padding(42) }
            else if filtered.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "Nothing here" : "No matches",
                    systemImage: definition.icon,
                    description: Text(query.isEmpty ? "Create the first entry in this world." : "No entry contains “\(query)”.")
                ).padding(.vertical, 42)
            }
            if let error { NodusNotice(tone: .blocked, title: "Could not load the world", message: LocalizedStringKey(error)) }
        }
        .padding(NodusSpace.page)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 7) {
                DesktopPageHeader(
                    title: LocalizedStringKey(definition.title),
                    subtitle: "\(filtered.count) authored entries · offline-capable",
                    systemImage: definition.icon,
                    accent: session.accent,
                    trailing: {
                        Button { isCreating = true } label: { Label("New", systemImage: "plus") }
                            .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent))
                            .disabled(!session.connection.role.canSendChanges || session.isDemo)
                    }
                )
                NodusSearchField(text: $query, prompt: "Search this section", accent: session.accent)
            }
            .padding(.horizontal, NodusSpace.page)
            .padding(.top, 10)
            .background(Color(uiColor: .systemBackground).opacity(0.98))
        }
        .nodusPageBackdrop(accent: session.accent)
    }

    private func currentRow(for row: Row) -> Row {
        guard let id = row.string(definition.idField) else { return row }
        return rows.first { $0.string(definition.idField) == id } ?? row
    }

    private func open(_ row: Row) {
        let id = row.string(definition.idField) ?? UUID().uuidString
        workspaceTabs.open(
            WorkspaceTab(
                id: "\(definition.section):\(id)",
                title: definition.title(of: row),
                systemImage: definition.icon,
                kind: .document,
                payload: .row(row)
            ),
            in: definition.section
        )
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            var tables: [String: [Row]]
            if let mirror = session.mirror {
                let names = [
                    definition.table.rawValue, "world_links", "world_beats", "thread_parties",
                    "scene_characters", "character_affiliations", "character_abilities", "person_names",
                    "person_places", "relationships", "character_profiles", "place_profiles",
                    "secret_knowers", "world_question_options", "world_scene_days",
                    "world_scene_text", "world_chapter_breaks", "world_manuscript_starts",
                    "world_scene_snapshots", "world_images", "persons", "places", "world_groups",
                    "world_articles", "world_scenes", "world_threads", "world_rules", "world_questions",
                ]
                var loaded: [String: [Row]] = [:]
                loaded[definition.table.rawValue] = try await mirror.allRows(table: definition.table.rawValue)
                for name in names where name != definition.table.rawValue { loaded[name] = (try? await mirror.allRows(table: name)) ?? [] }
                var refs: [SnapshotAssetRef] = []
                for row in loaded["world_images"] ?? [] {
                    if let id = row.string("image_id"), let ref = try? await mirror.asset(table: "world_images", key: [id]) { refs.append(ref) }
                }
                assetRefs = refs
                tables = loaded
            } else {
                let snapshot = try await session.client.snapshot(in: session.connection.spaceId)
                assetRefs = snapshot.assetRefs
                tables = snapshot.tables
            }
            if session.connection.desktopPairingId == nil { tables.merge(debugWorldbuildingFixture()) { _, fixture in fixture } }
            relatedTables = tables
            rows = tables[definition.table.rawValue] ?? []
            error = nil
            if outbox == nil { outbox = await OutboxController.open(session: session) }
#if DEBUG
            if ProcessInfo.processInfo.environment["NODUS_SHOW_TAB_DEMO"] == "1" && workspaceTabs.tabs(in: definition.section).isEmpty {
                for row in filtered.prefix(2) { open(row) }
            }
#endif
            if let initialRowID, let selected = filtered.first(where: { $0.string(definition.idField) == initialRowID }) {
                open(selected)
            }
        } catch { self.error = error.localizedDescription }
    }

    private func save(_ edited: Row, isNew: Bool) async {
        guard let outbox else { return }
        var columns = edited.columns
        let now = ISO8601DateFormatter.nodusFractional.string(from: Date())
        let id = edited.string(definition.idField) ?? UUID().uuidString
        columns[definition.idField] = .string(id)
        for (key, value) in definition.fixed { columns[key] = value }
        if columns["created_at"] == nil { columns["created_at"] = .string(now) }
        columns["updated_at"] = .string(now)
        if definition.table == .worldArticles || definition.table == .worldRules || definition.table == .worldThreads {
            let title = columns[definition.titleField]?.stringValue ?? ""
            columns["title_key"] = .string(normalizedWorldTitle(title))
        }
        if definition.table == .worldScenes && columns["narrative_order"] == nil {
            columns["narrative_order"] = .int(Int64((rows.compactMap { $0.int("narrative_order") }.max() ?? -1) + 1))
        }
        let saved = Row(columns)
        if let index = rows.firstIndex(where: { $0.string(definition.idField) == id }) { rows[index] = saved }
        else { rows.append(saved) }
        editorRow = nil; self.isCreating = false
        open(saved)
        _ = await outbox.syncMutation(
            kind: .upsert, table: definition.table, key: [id], row: columns,
            title: "Save \(definition.title(of: saved))"
        )
        if isNew { await createWorldOverlayIfNeeded(id: id, now: now, outbox: outbox) }
    }

    private func createWorldOverlayIfNeeded(id: String, now: String, outbox: OutboxController) async {
        if definition.table == .persons {
            let profile: [String: JSONValue] = [
                "person_id": .string(id), "life_status": .string("unknown"),
                "created_at": .string(now), "updated_at": .string(now),
            ]
            _ = await outbox.syncMutation(kind: .upsert, table: .characterProfiles, key: [id], row: profile, title: "Create character profile")
        } else if definition.table == .places {
            let profile: [String: JSONValue] = [
                "place_id": .string(id), "created_at": .string(now), "updated_at": .string(now),
            ]
            _ = await outbox.syncMutation(kind: .upsert, table: .placeProfiles, key: [id], row: profile, title: "Create place profile")
        }
    }

    private func delete(_ row: Row, tabId: String) async {
        guard let outbox, let id = row.string(definition.idField) else { return }
        rows.removeAll { $0.string(definition.idField) == id }
        workspaceTabs.close(tabId, in: definition.section)

        if let entity = canonicalDeleteEntity {
            do {
                _ = try await session.client.createSpaceAction(
                    idempotencyKey: "world-delete:\(definition.table.rawValue):\(id)".prefix(128).description,
                    kind: .worldbuildingEntityDelete,
                    payload: ["entity": .string(entity), "id": .string(id)],
                    inputRevision: session.publishedRevision,
                    in: session.connection.spaceId
                )
                return
            } catch {
                // Older/offline servers cannot queue the typed repository operation. The
                // generated mutation lane below is durable and mirrors every owned child,
                // so the edit still works without silently leaking polymorphic records.
                self.error = String(localized: "Canonical Desktop delete is unavailable; queued the offline-safe equivalent. \(error.localizedDescription)")
            }
        }

        await reparentRuleChildrenIfNeeded(deleting: row, outbox: outbox)
        for dependency in dependentDeletes(for: id) {
            _ = await outbox.syncMutation(
                kind: .delete, table: dependency.table, key: dependency.key,
                title: dependency.title
            )
            relatedTables[dependency.table.rawValue]?.removeAll { dependency.key(for: $0) == dependency.key }
        }
        _ = await outbox.syncMutation(
            kind: .delete, table: definition.table, key: [id],
            title: "Delete \(definition.title(of: row))"
        )
    }

    private var canonicalDeleteEntity: String? {
        switch definition.table {
        case .worldArticles: "article"
        case .persons: "character"
        case .places: "place"
        case .worldGroups: "group"
        case .worldScenes: "scene"
        case .worldThreads: "thread"
        case .worldRules: "rule"
        case .worldQuestions: "question"
        default: nil
        }
    }

    /// Mirrors the ownership rules in the Desktop repositories. Several world tables use
    /// polymorphic ids intentionally, so SQLite cannot cascade them; deleting only the parent
    /// would leave invisible images, manuscript snapshots and conflict participants behind.
    private func dependentDeletes(for id: String) -> [WorldDependentDelete] {
        var result: [WorldDependentDelete] = []

        func add(
            _ table: MutableTable, keyFields: [String], title: String,
            where predicate: (Row) -> Bool
        ) {
            for row in relatedTables[table.rawValue] ?? [] where predicate(row) {
                let key = keyFields.compactMap { row.string($0) }
                guard key.count == keyFields.count else { continue }
                result.append(.init(table: table, keyFields: keyFields, key: key, title: title))
            }
        }

        switch definition.table {
        case .persons:
            add(.worldImages, keyFields: ["image_id"], title: "Delete character image") {
                $0.string("entity_kind") == "character" && $0.string("entity_id") == id
            }
            add(.threadParties, keyFields: ["thread_id", "party_kind", "party_id"], title: "Remove character from story thread") {
                $0.string("party_kind") == "character" && $0.string("party_id") == id
            }
        case .places:
            add(.worldImages, keyFields: ["image_id"], title: "Delete place image") {
                $0.string("entity_kind") == "place" && $0.string("entity_id") == id
            }
        case .worldGroups:
            add(.worldImages, keyFields: ["image_id"], title: "Delete group image") {
                $0.string("entity_kind") == "group" && $0.string("entity_id") == id
            }
            add(.threadParties, keyFields: ["thread_id", "party_kind", "party_id"], title: "Remove group from story thread") {
                $0.string("party_kind") == "group" && $0.string("party_id") == id
            }
        case .worldScenes:
            add(.worldImages, keyFields: ["image_id"], title: "Delete scene image") {
                $0.string("entity_kind") == "scene" && $0.string("entity_id") == id
            }
            add(.worldBeats, keyFields: ["thread_kind", "thread_id", "scene_id"], title: "Delete scene beat") { $0.string("scene_id") == id }
            add(.worldSceneDays, keyFields: ["scene_id"], title: "Delete scene day") { $0.string("scene_id") == id }
            add(.worldSceneText, keyFields: ["scene_id"], title: "Delete scene prose") { $0.string("scene_id") == id }
            add(.worldChapterBreaks, keyFields: ["scene_id"], title: "Delete chapter break") { $0.string("scene_id") == id }
            add(.worldManuscriptStarts, keyFields: ["scene_id"], title: "Delete manuscript start") { $0.string("scene_id") == id }
            add(.worldSceneSnapshots, keyFields: ["snapshot_id"], title: "Delete scene snapshot") { $0.string("scene_id") == id }
        case .worldThreads:
            add(.threadParties, keyFields: ["thread_id", "party_kind", "party_id"], title: "Delete story-thread party") { $0.string("thread_id") == id }
            add(.worldBeats, keyFields: ["thread_kind", "thread_id", "scene_id"], title: "Delete story-thread beat") {
                $0.string("thread_id") == id && $0.string("thread_kind") != "rule"
            }
            add(.worldLinks, keyFields: ["source_kind", "source_id", "source_field", "target_key"], title: "Delete conflict link") {
                $0.string("source_kind") == "conflict" && $0.string("source_id") == id
            }
        case .worldRules:
            add(.worldBeats, keyFields: ["thread_kind", "thread_id", "scene_id"], title: "Delete rule beat") {
                $0.string("thread_kind") == "rule" && $0.string("thread_id") == id
            }
            add(.worldLinks, keyFields: ["source_kind", "source_id", "source_field", "target_key"], title: "Delete rule link") {
                $0.string("source_kind") == "rule" && $0.string("source_id") == id
            }
        case .worldQuestions:
            add(.worldQuestionOptions, keyFields: ["option_id"], title: "Delete question option") { $0.string("question_id") == id }
        case .worldArticles:
            add(.worldImages, keyFields: ["image_id"], title: "Delete article image") {
                $0.string("entity_kind") == "article" && $0.string("entity_id") == id
            }
            add(.worldLinks, keyFields: ["source_kind", "source_id", "source_field", "target_key"], title: "Delete article link") {
                $0.string("source_kind") == "article" && $0.string("source_id") == id
            }
        default:
            break
        }
        return result
    }

    private func reparentRuleChildrenIfNeeded(deleting row: Row, outbox: OutboxController) async {
        guard definition.table == .worldRules, let id = row.string("rule_id") else { return }
        let parent = row["parent_rule_id"] ?? .null
        for index in rows.indices where rows[index].string("parent_rule_id") == id {
            var columns = rows[index].columns
            columns["parent_rule_id"] = parent
            columns["updated_at"] = .string(ISO8601DateFormatter.nodusFractional.string(from: Date()))
            rows[index] = Row(columns)
            guard let childId = rows[index].string("rule_id") else { continue }
            _ = await outbox.syncMutation(
                kind: .upsert, table: .worldRules, key: [childId], row: columns,
                title: "Preserve rule exception"
            )
        }
    }

    private var supportsImages: Bool {
        [.persons, .places, .worldGroups, .worldScenes].contains(definition.table)
    }

    private func attachImage(_ data: Data, to row: Row) async {
        guard let outbox, let entityId = row.string(definition.idField), let entityKind = worldImageEntityKind else { return }
        do {
            let limit = (try? await session.client.capabilities().maxAssetBytes) ?? 8 * 1024 * 1024
            let upload = try await session.client.upload(imageData: data, in: session.connection.spaceId, maxBytes: limit)
            let imageId = "wim_\(UUID().uuidString)"
            let now = ISO8601DateFormatter.nodusFractional.string(from: Date())
            let order = (relatedTables["world_images"] ?? []).filter {
                $0.string("entity_kind") == entityKind && $0.string("entity_id") == entityId
            }.count
            let metadata: [String: JSONValue] = [
                "image_id": .string(imageId), "entity_kind": .string(entityKind), "entity_id": .string(entityId),
                "kind": .string(entityKind == "character" ? "portrait" : "other"),
                "mime_type": .string(upload.mime ?? "image/jpeg"), "bytes": .int(Int64(upload.bytes)),
                "generated": .int(0), "sort_order": .int(Int64(order)),
                "created_at": .string(now), "updated_at": .string(now),
            ]
            relatedTables["world_images", default: []].append(Row(metadata))
            pendingImageData[imageId] = data
            _ = await outbox.syncMutation(
                kind: .upsert, table: .worldImages, key: [imageId], row: metadata,
                assets: [.init(hash: upload.hash)], title: "Attach image to \(definition.title(of: row))"
            )
        } catch { self.error = error.localizedDescription }
    }

    private var worldImageEntityKind: String? {
        switch definition.table {
        case .persons: "character"
        case .places: "place"
        case .worldGroups: "group"
        case .worldScenes: "scene"
        default: nil
        }
    }
}

private struct WorldDependentDelete {
    let table: MutableTable
    let keyFields: [String]
    let key: [String]
    let title: String

    func key(for row: Row) -> [String] { keyFields.compactMap { row.string($0) } }
}

private struct WorldEntityEditor: View {
    @Environment(\.dismiss) private var dismiss
    let definition: WorldEntityDefinition
    let initial: Row?
    let accent: Color
    let onSave: (Row) -> Void

    @State private var values: [String: String]
    @State private var toggles: [String: Bool]

    init(definition: WorldEntityDefinition, initial: Row?, accent: Color, onSave: @escaping (Row) -> Void) {
        self.definition = definition; self.initial = initial; self.accent = accent; self.onSave = onSave
        _values = State(initialValue: Dictionary(uniqueKeysWithValues: definition.fields.map { ($0.key, initial?.string($0.key) ?? "") }))
        _toggles = State(initialValue: Dictionary(uniqueKeysWithValues: definition.fields.map { ($0.key, initial?.bool($0.key) ?? false) }))
    }

    var body: some View {
        Form {
            ForEach(definition.fields) { field in
                Section(field.label) {
                    switch field.kind {
                    case .line:
                        TextField(field.label, text: binding(field.key))
                    case .prose:
                        TextField(field.label, text: binding(field.key), axis: .vertical).lineLimit(3...14)
                    case .integer:
                        TextField(field.label, text: binding(field.key)).keyboardType(.numbersAndPunctuation)
                    case .choice(let options):
                        Picker(field.label, selection: binding(field.key)) {
                            Text("Not set").tag("")
                            ForEach(options, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
                        }
                    case .toggle:
                        Toggle(field.label, isOn: toggleBinding(field.key)).tint(accent)
                    }
                }
            }
        }
        .navigationTitle(initial == nil ? "New \(definition.title)" : "Edit \(definition.title)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { onSave(builtRow()) }
                    .disabled(values[definition.titleField, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key, default: ""] }, set: { values[key] = $0 })
    }

    private func toggleBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { toggles[key, default: false] }, set: { toggles[key] = $0 })
    }

    private func builtRow() -> Row {
        var columns = initial?.columns ?? [:]
        for field in definition.fields {
            switch field.kind {
            case .toggle:
                columns[field.key] = .int(toggles[field.key, default: false] ? 1 : 0)
            case .integer:
                let raw = values[field.key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
                columns[field.key] = raw.isEmpty ? .null : .int(Int64(raw) ?? 0)
            default:
                let raw = values[field.key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
                columns[field.key] = raw.isEmpty ? .null : .string(raw)
            }
        }
        return Row(columns)
    }
}

private struct WorldConnectedTarget: Identifiable {
    let route: NodusRoute
    let row: Row
    let rowID: String
    let title: String
    var id: String { "\(route.rawValue):\(rowID)" }
}

private struct WorldEntityDossier: View {
    let session: SpaceSession
    let definition: WorldEntityDefinition
    let row: Row
    let relatedTables: [String: [Row]]
    let assetRefs: [SnapshotAssetRef]
    let pendingImageData: [String: Data]
    let onAttachImage: ((Data) -> Void)?
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false
    @State private var photo: PhotosPickerItem?
    @State private var connectedTarget: WorldConnectedTarget?

    private var rowId: String { row.string(definition.idField) ?? "" }
    private var profileTable: String? {
        switch definition.route {
        case .characters: "character_profiles"
        case .places: "place_profiles"
        default: nil
        }
    }
    private var profile: Row? {
        guard let profileTable else { return nil }
        return relatedTables[profileTable]?.first { $0.string(definition.idField) == rowId }
    }
    private var profileFields: [WorldEntityField] {
        let fields: [(String, String, WorldEntityField.Kind)] = switch definition.route {
        case .characters: [
            ("species", "Species", .line), ("gender", "Gender", .line), ("pronouns", "Pronouns", .line),
            ("life_status", "Life status", .line), ("narrative_role", "Narrative role", .line),
            ("appearance", "Appearance", .prose), ("personality", "Personality", .prose),
            ("backstory", "Backstory", .prose), ("visual_seed", "Visual identity", .prose),
            ("birth_year_sort", "Birth year", .integer), ("death_year_sort", "Death year", .integer),
            ("arc_want", "Want", .prose), ("arc_need", "Need", .prose), ("arc_flaw", "Flaw", .prose),
            ("arc_lie", "Lie", .prose), ("arc_wound", "Wound", .prose),
            ("voice_register", "Voice register", .prose), ("voice_tics", "Voice tics", .prose),
            ("voice_sample", "Voice sample", .prose), ("biography_proposed", "Proposed biography", .prose),
        ]
        case .places: [
            ("appearance", "Appearance", .prose), ("atmosphere", "Atmosphere", .prose),
            ("history", "History", .prose), ("visual_seed", "Visual identity", .prose),
        ]
        default: []
        }
        return fields.map { .init(key: $0.0, label: $0.1, kind: $0.2) }
    }
    private var related: [(String, Row)] {
        relatedTables.keys.sorted().flatMap { table in
            (relatedTables[table] ?? []).compactMap { candidate in
                guard !(table == definition.table.rawValue && candidate.string(definition.idField) == rowId),
                      !(table == profileTable && candidate.string(definition.idField) == rowId),
                      candidate.columns.values.contains(where: { $0.stringValue == rowId })
                else { return nil }
                return (table, candidate)
            }
        }
    }

    private func target(for pair: (String, Row)) -> WorldConnectedTarget? {
        if pair.0 == "relationships" {
            for key in ["from_person", "to_person"] {
                if let id = pair.1.string(key), id != rowId,
                   let target = entityTarget(id: id, routes: [.characters]) { return target }
            }
        }
        let routes: [NodusRoute] = [.characters, .places, .factions, .cultures, .dynasties, .scenes, .encyclopedia, .conflicts, .arcs, .rules, .questions]
        for route in routes {
            guard let entity = WorldEntityDefinition.forRoute(route) else { continue }
            if pair.0 == entity.table.rawValue, entity.includes(pair.1), let id = pair.1.string(entity.idField), id != rowId {
                return .init(route: route, row: pair.1, rowID: id, title: entity.title(of: pair.1))
            }
            guard let id = pair.1.string(entity.idField), id != rowId,
                  let record = relatedTables[entity.table.rawValue]?.first(where: { $0.string(entity.idField) == id && entity.includes($0) })
            else { continue }
            return .init(route: route, row: record, rowID: id, title: entity.title(of: record))
        }
        return nil
    }

    private func entityTarget(id: String?, routes: [NodusRoute]) -> WorldConnectedTarget? {
        guard let id, id != rowId else { return nil }
        for route in routes {
            guard let entity = WorldEntityDefinition.forRoute(route),
                  let record = relatedTables[entity.table.rawValue]?.first(where: { $0.string(entity.idField) == id && entity.includes($0) })
            else { continue }
            return .init(route: route, row: record, rowID: id, title: entity.title(of: record))
        }
        return nil
    }

    private func target(for field: WorldEntityField) -> WorldConnectedTarget? {
        let routes: [NodusRoute]
        switch field.key {
        case "place_id", "seat_place_id": routes = [.places]
        case "parent_id":
            routes = definition.route == .places ? [.places] : [.factions, .cultures, .dynasties]
        case "scope_id", "anchor_id":
            let kind = row.string(field.key == "scope_id" ? "scope_kind" : "anchor_kind")
            switch kind {
            case "character", "person": routes = [.characters]
            case "place": routes = [.places]
            case "group": routes = [.factions, .cultures, .dynasties]
            case "scene": routes = [.scenes]
            case "article": routes = [.encyclopedia]
            case "conflict": routes = [.conflicts]
            case "arc": routes = [.arcs]
            case "rule": routes = [.rules]
            default: routes = []
            }
        default: routes = []
        }
        return entityTarget(id: row.string(field.key), routes: routes)
    }

    @ViewBuilder private func fieldCell(_ field: WorldEntityField, from source: Row, destination: WorldConnectedTarget? = nil) -> some View {
        if let destination {
            Button { connectedTarget = destination } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(LocalizedStringKey(field.label)).textCase(.uppercase).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    HStack {
                        Text(destination.title).font(.callout).foregroundStyle(session.accent.nodusReadable)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .desktopContentRow(accent: session.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("world-field-link-\(field.key)")
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text(LocalizedStringKey(field.label)).textCase(.uppercase).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(display(field, from: source)).font(field.kind == .prose ? .body : .callout).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .desktopContentRow(accent: session.accent)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                DesktopPageHeader(
                    title: LocalizedStringKey(definition.title(of: row)),
                    subtitle: LocalizedStringKey(definition.title),
                    systemImage: definition.icon,
                    accent: session.accent,
                    trailing: {
                        HStack(spacing: 8) {
                            Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
                                .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
                            Button(role: .destructive) { confirmingDelete = true } label: { Image(systemName: "trash") }
                                .buttonStyle(NodusGlassIconButtonStyle(accent: .red))
                        }
                        .disabled(!session.connection.role.canSendChanges || session.isDemo)
                    }
                )
                if onAttachImage != nil || !images.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text("IMAGES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            if onAttachImage != nil {
                                PhotosPicker(selection: $photo, matching: .images) { Label("Add image", systemImage: "photo.badge.plus") }
                                    .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
                                    .disabled(!session.connection.role.canSendChanges || session.isDemo)
                            }
                        }
                        ScrollView(.horizontal) {
                            HStack(spacing: 9) {
                                ForEach(images, id: \.columns) { image in
                                    WorldRemoteImage(
                                        session: session,
                                        imageId: image.string("image_id"),
                                        caption: image.text("caption") ?? image.text("title") ?? String(localized: "Image"),
                                        reference: assetRefs.first { $0.table == "world_images" && $0.key.first == image.string("image_id") },
                                        pending: image.string("image_id").flatMap { pendingImageData[$0] }
                                    )
                                }
                            }
                        }.scrollIndicators(.hidden)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 9)], spacing: 9) {
                    ForEach(definition.fields.filter { row.text($0.key) != nil || row.bool($0.key) == true }) { field in
                        fieldCell(field, from: row, destination: target(for: field))
                    }
                    if let profile {
                        ForEach(profileFields.filter { profile.text($0.key) != nil }) { field in
                            fieldCell(field, from: profile)
                        }
                    }
                }
                if !related.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("CONNECTED RECORDS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Array(related.enumerated()), id: \.offset) { index, pair in
                            let destination = target(for: pair)
                            let presented = RowPresenter.forTable(pair.0).title(pair.1)
                            Button { connectedTarget = destination } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: RowPresenter.forTable(pair.0).icon).foregroundStyle(session.accent.nodusReadable)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(LocalizedStringKey(destination?.title ?? (presented == "Untitled" ? MirrorOnlySectionsView.label(for: pair.0) : presented))).font(.callout.weight(.medium))
                                        HStack(spacing: 4) {
                                            Text(LocalizedStringKey(MirrorOnlySectionsView.label(for: pair.0)))
                                            if pair.0 == "relationships" {
                                                Text("·")
                                                Text(LocalizedStringKey(presented))
                                            }
                                        }.font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if destination != nil { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                                }.desktopContentRow(accent: .secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(destination == nil)
                            .accessibilityIdentifier("world-connected-record-\(pair.0)-\(index)")
                        }
                    }
                }
            }
            .padding(NodusSpace.page).frame(maxWidth: 1100).frame(maxWidth: .infinity)
            .nodusTopAnchor()
        }
        .nodusPageBackdrop(accent: session.accent)
        .sheet(item: $connectedTarget) { target in
            NavigationStack {
                WorldEntityWorkspaceView(session: session, route: target.route, initialRowID: target.rowID)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { connectedTarget = nil }
                                .accessibilityIdentifier("world-connected-close-\(target.rowID)")
                        }
                    }
            }
        }
        .alert("Delete this entry?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: onDelete); Button("Cancel", role: .cancel) {}
        } message: { Text("The deletion is queued and applied by the owner Desktop without duplicating retries.") }
        .onChange(of: photo) { _, item in
            guard let item, let onAttachImage else { return }
            Task { if let data = try? await item.loadTransferable(type: Data.self) { onAttachImage(data) }; photo = nil }
        }
    }

    private var images: [Row] {
        let kind: String? = switch definition.table {
        case .persons: "character"
        case .places: "place"
        case .worldGroups: "group"
        case .worldScenes: "scene"
        default: nil
        }
        guard let kind else { return [] }
        return (relatedTables["world_images"] ?? []).filter { $0.string("entity_kind") == kind && $0.string("entity_id") == rowId }
    }

    private func display(_ field: WorldEntityField, from source: Row) -> String {
        if field.kind == .toggle { return source.bool(field.key) == true ? String(localized: "Yes") : String(localized: "No") }
        return source.text(field.key) ?? "—"
    }
}

private struct WorldRemoteImage: View {
    let session: SpaceSession
    let imageId: String?
    let caption: String
    let reference: SnapshotAssetRef?
    let pending: Data?
    @State private var image: UIImage?
    @State private var vector: ReaderImageSource.Content?
    @State private var issue: String?
    @State private var attempt = 0
    @State private var opening = false
    @State private var original: RichCorpusProse.OpenImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let image {
                    Button { Task { await open() } } label: { Image(uiImage: image).resizable().scaledToFill().frame(width: 190, height: 130).clipped() }
                        .buttonStyle(.plain).disabled(opening).accessibilityLabel(caption)
                } else if let vector {
                    ReaderVectorImage(content: vector).frame(width: 190, height: 130)
                        .overlay { Button { Task { await open() } } label: { Color.clear.contentShape(Rectangle()) }.buttonStyle(.plain).disabled(opening).accessibilityLabel(caption) }
                } else if issue != nil {
                    VStack(spacing: 4) { Image(systemName: "photo.badge.exclamationmark"); Text("No se pudo cargar la imagen").font(.caption); Button("Retry") { attempt += 1 }.frame(minHeight: 44) }
                        .frame(width: 190, height: 130).background(Color(uiColor: .secondarySystemBackground))
                } else { ProgressView().tint(session.accent).frame(width: 190, height: 130).background(Color(uiColor: .secondarySystemBackground)) }
            }.clipShape(RoundedRectangle(cornerRadius: 10))
            if opening { ProgressView("Abriendo original…").font(.caption) }
            if let issue { Text(issue).font(.caption2).foregroundStyle(.secondary).lineLimit(3).frame(width: 190, alignment: .leading) }
        }
        .task(id: "\(imageId ?? reference?.hash ?? "pending")|\(attempt)") {
            issue = nil; image = nil; vector = nil
            do {
                let data: Data, mime: String?
                if let pending { data = pending; mime = nil }
                else if session.connection.desktopPairingId != nil, let source = source(thumbnail: true) {
                    let content: ReaderImageSource.Content
                    do { content = try await ReaderImageSource.load(source, session: session) }
                    catch {
                        guard isPrivateBridgeOffline(error), let original = self.source(thumbnail: false) else { throw error }
                        content = try await ReaderImageSource.load(original, session: session)
                    }
                    data = content.data; mime = content.mime
                } else if let reference { data = try await session.client.asset(hash: reference.thumbHash ?? reference.hash, in: session.connection.spaceId); mime = reference.thumbHash != nil ? reference.thumbMime ?? reference.mime : reference.mime }
                else { throw APIError(status: 404, code: "image_unavailable", message: "La imagen no está disponible en esta copia.") }
                guard data.count <= ReaderImageSource.maximumBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
                if mime == "image/svg+xml" { try Task.checkCancellation(); vector = .init(data: data, mime: "image/svg+xml"); return }
                let decoded = try ReaderRasterImage.preview(data, maxPixelSize: 768)
                try Task.checkCancellation(); image = decoded
            } catch where error.isCancellation {}
            catch { issue = error.localizedDescription }
        }
        .nodusSheet(item: $original) { item in ReaderImageViewer(content: item.content, image: item.preview, title: item.title, accent: session.accent) }
    }
    private func source(thumbnail: Bool) -> String? {
        guard let imageId, !imageId.isEmpty else { return nil }
        var url = URLComponents(); url.scheme = "nodus-image"; url.host = thumbnail ? "world-thumbnail" : "world"; url.path = "/" + imageId
        return url.url?.absoluteString
    }
    private func open() async {
        opening = true; defer { opening = false }
        do {
            let content: ReaderImageSource.Content
            if let pending {
                guard pending.count <= ReaderImageSource.maximumBytes, let decoder = CGImageSourceCreateWithData(pending as CFData, nil), let type = CGImageSourceGetType(decoder), let mime = UTType(type as String)?.preferredMIMEType, ReaderImageSource.supported(mime) else { throw DesktopBridgeError.malformedResponse }
                content = .init(data: pending, mime: mime)
            } else if session.connection.desktopPairingId != nil, let source = source(thumbnail: false) { content = try await ReaderImageSource.load(source, session: session) }
            else if let reference {
                let data = try await session.client.asset(hash: reference.hash, in: session.connection.spaceId)
                guard data.count <= ReaderImageSource.maximumBytes, ReaderImageSource.supported(reference.mime) else { throw DesktopBridgeError.malformedResponse }
                content = .init(data: data, mime: reference.mime)
            } else { throw DesktopBridgeError.malformedResponse }
            let preview = content.mime == "image/svg+xml" || content.mime == "image/gif" ? nil : try ReaderRasterImage.preview(content.data)
            try Task.checkCancellation(); original = .init(content: content, preview: preview, title: caption); issue = nil
        } catch where error.isCancellation {}
        catch { issue = error.localizedDescription }
    }
}

private func normalizedWorldTitle(_ value: String) -> String {
    value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

// MARK: - Timeline, hierarchy, relations and map

struct WorldTimelineView: View {
    let session: SpaceSession
    @State private var entries: [WorldbuildingParity.TimelineEntry] = []
    @State private var chronological = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                DesktopPageHeader(title: "Timeline", subtitle: chronological ? "World chronology" : "Narrative order", systemImage: "clock", accent: session.accent, trailing: {
                    Picker("Order", selection: $chronological) { Text("World").tag(true); Text("Story").tag(false) }.pickerStyle(.segmented).frame(width: 190)
                })
                if let error { NodusNotice(tone: .blocked, title: "Timeline unavailable", message: LocalizedStringKey(error)) }
                ForEach(entries) { item in
                    HStack(spacing: 12) {
                        VStack(spacing: 0) { Circle().fill(session.accent).frame(width: 10, height: 10); Rectangle().fill(session.accent.opacity(0.25)).frame(width: 2, height: 44) }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { NodusChip(key: item.kind, tint: session.accent); if let status = item.status { NodusChip(key: status, tint: .secondary) } }
                            Text(item.title).font(.headline)
                            Text(item.worldDay.map { "World day \($0)" } ?? item.worldYear.map { "Year \($0)" } ?? "Undated · story position \(item.narrativeOrder + 1)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.desktopContentRow(accent: session.accent)
                }
            }.padding(NodusSpace.page).frame(maxWidth: 980).frame(maxWidth: .infinity).nodusTopAnchor()
        }.nodusPageBackdrop(accent: session.accent)
        .task(id: "\(session.publishedRevision ?? "")|\(chronological)") { await load() }
    }

    private func load() async {
        do {
            let tables = try await worldTables(session, ["world_scenes", "events", "event_world_dates"])
            var events = tables["events"] ?? []
            let dates = Dictionary(uniqueKeysWithValues: (tables["event_world_dates"] ?? []).compactMap { row in row.string("event_id").map { ($0, row) } })
            events = events.map { event in
                var value = event.columns
                if let id = event.string("event_id"), let date = dates[id] { value.merge(date.columns) { first, _ in first } }
                return Row(value)
            }
            entries = WorldbuildingParity.timeline(scenes: tables["world_scenes"] ?? [], events: events, chronological: chronological)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct WorldHierarchyView: View {
    let session: SpaceSession
    @State private var nodes: [WorldbuildingParity.HierarchyNode] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                DesktopPageHeader(title: "World hierarchy", subtitle: "Dynasties, cultures, factions and nested places", systemImage: "arrow.triangle.branch", accent: session.accent)
                if loading { ProgressView("Loading hierarchy…").frame(maxWidth: .infinity).padding(.vertical, 32) }
                if let error { NodusNotice(tone: .blocked, title: "Could not load hierarchy", message: LocalizedStringKey(error)) }
                ForEach(Array(flattened.enumerated()), id: \.element.0.id) { _, item in
                    let node = item.0
                    HStack {
                        Image(systemName: node.kind == "place" ? "mappin" : "shield").foregroundStyle(session.accent.nodusReadable)
                        Text(node.title).font(.headline)
                        Spacer()
                        NodusChip(key: node.kind, tint: session.accent)
                    }
                    .desktopContentRow(accent: session.accent)
                    .padding(.leading, CGFloat(item.1) * 22)
                }
                if nodes.isEmpty, !loading, error == nil { ContentUnavailableView("No hierarchy", systemImage: "arrow.triangle.branch", description: Text("World groups and nested places will appear here.")) }
            }.padding(NodusSpace.page).frame(maxWidth: 980).frame(maxWidth: .infinity).nodusTopAnchor()
        }.nodusPageBackdrop(accent: session.accent).task(id: session.publishedRevision) { await load() }
    }

    private var roots: [WorldbuildingParity.HierarchyNode] { nodes.filter { $0.parentId == nil || !Set(nodes.map(\.id)).contains($0.parentId!) } }
    private func children(_ id: String) -> [WorldbuildingParity.HierarchyNode] { nodes.filter { $0.parentId == id } }
    private var flattened: [(WorldbuildingParity.HierarchyNode, Int)] {
        func visit(_ node: WorldbuildingParity.HierarchyNode, depth: Int, result: inout [(WorldbuildingParity.HierarchyNode, Int)], seen: inout Set<String>) {
            guard seen.insert(node.id).inserted else { return }
            result.append((node, depth))
            for child in children(node.id) { visit(child, depth: depth + 1, result: &result, seen: &seen) }
        }
        var result: [(WorldbuildingParity.HierarchyNode, Int)] = []
        var seen = Set<String>()
        for root in roots { visit(root, depth: 0, result: &result, seen: &seen) }
        for node in nodes where !seen.contains(node.id) { visit(node, depth: 0, result: &result, seen: &seen) }
        return result
    }
    private func load() async {
        loading = true; defer { loading = false }
        do {
            let tables = try await worldTables(session, ["world_groups", "places"])
            nodes = WorldbuildingParity.hierarchy(groups: tables["world_groups"] ?? [], places: tables["places"] ?? [])
            error = nil
        } catch { nodes = []; self.error = error.localizedDescription }
    }
}

struct WorldRelationsView: View {
    let session: SpaceSession
    @State private var people: [String: String] = [:]
    @State private var relations: [Row] = []
    @State private var affiliations: [Row] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                DesktopPageHeader(title: "Relations", subtitle: "Kinship, social bonds and affiliations", systemImage: "link", accent: session.accent)
                if loading { ProgressView("Loading relations…").frame(maxWidth: .infinity).padding(.vertical, 32) }
                if let error { NodusNotice(tone: .blocked, title: "Could not load relations", message: LocalizedStringKey(error)) }
                ForEach(relations, id: \.columns) { row in
                    relationCard(from: people[row.string("from_person") ?? ""] ?? "Unknown", to: people[row.string("to_person") ?? ""] ?? "Unknown", label: row.text("type") ?? "relation")
                }
                ForEach(affiliations, id: \.columns) { row in
                    relationCard(from: people[row.string("person_id") ?? ""] ?? "Unknown", to: row.text("group_id") ?? "Group", label: row.text("rank") ?? "member")
                }
                if relations.isEmpty, affiliations.isEmpty, !loading, error == nil { ContentUnavailableView("No relations", systemImage: "link", description: Text("Relationships and affiliations will appear here.")) }
            }.padding(NodusSpace.page).frame(maxWidth: 980).frame(maxWidth: .infinity).nodusTopAnchor()
        }.nodusPageBackdrop(accent: session.accent).task(id: session.publishedRevision) { await load() }
    }
    private func relationCard(from: String, to: String, label: String) -> some View {
        HStack { Text(from).font(.headline); Spacer(); VStack { Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary); Image(systemName: "arrow.right").foregroundStyle(session.accent) }; Spacer(); Text(to).font(.headline) }.desktopContentRow(accent: session.accent)
    }
    private func load() async {
        loading = true; defer { loading = false }
        do {
            let tables = try await worldTables(session, ["persons", "relationships", "character_affiliations", "world_groups"])
            people = Dictionary(uniqueKeysWithValues: (tables["persons"] ?? []).compactMap { row in (row.string("person_id") ?? row.string("id")).map { ($0, row.text("display_name") ?? $0) } })
            let groups = Dictionary(uniqueKeysWithValues: (tables["world_groups"] ?? []).compactMap { row in (row.string("group_id") ?? row.string("id")).map { ($0, row.text("name") ?? $0) } })
            relations = tables["relationships"] ?? []
            affiliations = (tables["character_affiliations"] ?? []).map { row in var value = row.columns; if let id = row.string("group_id") { value["group_id"] = .string(groups[id] ?? id) }; return Row(value) }
            error = nil
        } catch { people = [:]; relations = []; affiliations = []; self.error = error.localizedDescription }
    }
}

struct WorldMapView: View {
    let session: SpaceSession
    @State private var maps: [Row] = []
    @State private var markers: [Row] = []
    @State private var selectedId: String?
    @State private var loading = true
    @State private var error: String?

    private var selected: Row? { maps.first { $0.string("map_id") == selectedId } ?? maps.first }
    private var visibleMarkers: [Row] { guard let id = selected?.string("map_id") else { return [] }; return markers.filter { $0.string("map_id") == id } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                DesktopPageHeader(title: "Maps", subtitle: "Layered maps with normalized markers", systemImage: "map", accent: session.accent, trailing: {
                    if !maps.isEmpty { Picker("Map", selection: Binding(get: { selected?.string("map_id") ?? "" }, set: { selectedId = $0 })) { ForEach(maps, id: \.columns) { Text($0.text("name") ?? "Map").tag($0.string("map_id") ?? "") } }.frame(width: 220) }
                })
                if loading { ProgressView("Loading maps…").frame(maxWidth: .infinity).padding(.vertical, 32) }
                if let error { NodusNotice(tone: .blocked, title: "Could not load maps", message: LocalizedStringKey(error)) }
                if let selected {
                    GeometryReader { proxy in
                        ZStack {
                            RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [session.accent.opacity(0.22), Color(uiColor: .secondarySystemBackground)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            Canvas { context, size in
                                var grid = Path()
                                stride(from: 0.0, through: size.width, by: max(40, size.width / 8)).forEach { x in grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)) }
                                stride(from: 0.0, through: size.height, by: max(40, size.height / 6)).forEach { y in grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
                                context.stroke(grid, with: .color(session.accent.opacity(0.12)), lineWidth: 1)
                            }
                            ForEach(visibleMarkers, id: \.columns) { marker in
                                VStack(spacing: 2) { Image(systemName: marker.text("icon") ?? "mappin.circle.fill").font(.title2); Text(marker.text("label") ?? "Marker").font(.caption2.weight(.medium)).lineLimit(1) }
                                    .foregroundStyle(session.accent.nodusReadable)
                                    .position(x: CGFloat(marker.double("x") ?? 0.5) * proxy.size.width, y: CGFloat(marker.double("y") ?? 0.5) * proxy.size.height)
                            }
                        }
                    }.frame(minHeight: 440).overlay(alignment: .topLeading) { Text(selected.text("name") ?? "Map").font(.title2.weight(.semibold)).padding(18) }
                } else if !loading, error == nil { ContentUnavailableView("No maps", systemImage: "map", description: Text("Maps created on Desktop will keep their layers and markers here.")) }
            }.padding(NodusSpace.page).frame(maxWidth: 1120).frame(maxWidth: .infinity).nodusTopAnchor()
        }.nodusPageBackdrop(accent: session.accent).task(id: session.publishedRevision) { await load() }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do {
            let tables = try await worldTables(session, ["world_maps", "map_markers"])
            maps = tables["world_maps"] ?? []; markers = tables["map_markers"] ?? []
            if selectedId == nil { selectedId = maps.first?.string("map_id") ?? maps.first?.string("id") }
            error = nil
        } catch { maps = []; markers = []; self.error = error.localizedDescription }
    }
}

@MainActor
func worldTables(_ session: SpaceSession, _ names: [String]) async throws -> [String: [Row]] {
    let fixture = session.connection.desktopPairingId == nil ? debugWorldbuildingFixture() : [:]
    if let mirror = session.mirror {
        var result: [String: [Row]] = [:]
        for name in names { result[name] = try await mirror.allRows(table: name) }
        for name in names where fixture[name] != nil { result[name] = fixture[name] }
        return result
    }
    let snapshot = try await session.client.snapshot(in: session.connection.spaceId)
    return Dictionary(uniqueKeysWithValues: names.map { ($0, fixture[$0] ?? snapshot.tables[$0] ?? []) })
}

private func debugWorldbuildingFixture() -> [String: [Row]] {
#if DEBUG
    guard ProcessInfo.processInfo.environment["NODUS_VAULT_TYPE_OVERRIDE"] == "worldbuilding",
          let url = Bundle.main.url(forResource: "worldbuilding-fixture", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let object = try? JSONDecoder().decode([String: JSONValue].self, from: data)
    else { return [:] }
    return object.compactMapValues { value in value.arrayValue?.compactMap { $0.objectValue.map(Row.init) } }
#else
    return [:]
#endif
}
