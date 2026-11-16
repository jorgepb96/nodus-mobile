import NodusKit
import NodusUI
import SwiftUI
import UIKit

/// The desktop Workspace projected through `notes` + `note_folders`: one hierarchy, with
/// hand-written notes and graph-backed ideas distinguished by metadata rather than split into
/// unrelated mobile sections.
struct PublishedWorkspaceView: View {
    let session: SpaceSession

    @State private var items: [Row] = []
    @State private var folders: [Row] = []
    @State private var folderId: String?
    @State private var query = ""
    @State private var kind: KindFilter = .all
    @State private var loading = true
    @State private var error: String?
    @State private var loadID = UUID()

    private enum KindFilter: String, CaseIterable, Identifiable {
        case all, notes, ideas
        var id: String { rawValue }
        var title: LocalizedStringKey { switch self { case .all: "All"; case .notes: "Notes"; case .ideas: "Ideas" } }
    }

    private var selectedFolders: Set<String>? {
        guard let folderId else { return nil }
        var result: Set<String> = [folderId]
        var changed = true
        while changed {
            changed = false
            for folder in folders where folder.string("parent_id").map(result.contains) == true {
                guard let id = folder.string("id"), !result.contains(id) else { continue }
                result.insert(id); changed = true
            }
        }
        return result
    }

    private var visible: [Row] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let allowed = selectedFolders
        return items.filter { item in
            if let allowed, !allowed.contains(item.string("folder_id") ?? "") { return false }
            let isIdea = item.string("kind") == "idea"
            if kind == .ideas && !isIdea { return false }
            if kind == .notes && isIdea { return false }
            if !needle.isEmpty, ![item.text("title"), item.text("snippet")].compactMap({ $0 }).joined(separator: "\n").localizedLowercase.contains(needle) { return false }
            return true
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 9) {
            if let error {
                NodusNotice(tone: .blocked, title: "Could not load Workspace", message: LocalizedStringKey(error))
                Button("Retry") { Task { await load() } }
                    .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
            }
            ForEach(Array(visible.enumerated()), id: \.offset) { _, item in
                NavigationLink { PublishedWorkspaceItemView(session: session, summary: item, folderName: folderName(item.string("folder_id"))) } label: {
                    WorkspaceItemCell(item: item, folderName: folderName(item.string("folder_id")), accent: session.accent)
                        .desktopContentRow(accent: session.accent)
                }
                .buttonStyle(NodusCardButtonStyle())
            }
            if loading, items.isEmpty { HStack { Spacer(); ProgressView().tint(session.accent); Spacer() }.padding() }
            if !loading, visible.isEmpty, error == nil {
                ContentUnavailableView("Nothing here", systemImage: "rectangle.stack", description: Text("Try another search, collection or content type."))
                    .padding(.vertical, 42)
            }
            }
            .padding(NodusSpace.page)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
            .nodusTopAnchor()
        }
        .nodusDismissesKeyboard()
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                DesktopPageHeader(
                    title: "Workspace",
                    subtitle: loading && items.isEmpty
                        ? "Loading notes and ideas…"
                        : "\(visible.count) items · \(selectedFolderName)",
                    systemImage: "rectangle.stack",
                    accent: session.accent
                )
                .padding(.horizontal, NodusSpace.page)
                HStack {
                    Menu {
                        Button { folderId = nil } label: {
                            if folderId == nil { NodusMenuLabel("All collections", systemImage: "checkmark") }
                            else { Text("All collections") }
                        }
                        WorkspaceFolderMenuItems(folders: folders, parentId: nil, selection: $folderId)
                    } label: {
                        Label(selectedFolderName, systemImage: "folder")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
                    Spacer()
                    Text("\(visible.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, NodusSpace.page)
                NodusSearchField(text: $query, prompt: "Search notes and ideas", accent: session.accent, isBusy: loading)
                    .padding(.horizontal, NodusSpace.page)
                Picker("Content type", selection: $kind) {
                    ForEach(KindFilter.allCases) { value in Text(value.title).tag(value) }
                }.pickerStyle(.segmented).padding(.horizontal, NodusSpace.page)
            }
            .padding(.bottom, 8)
            .padding(.top, 10)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .systemBackground).opacity(0.98))
        }
        .navigationTitle("Workspace").navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent).nodusHidesBottomBar()
        .toolbar {
            ToolbarItem(placement: .principal) {
                Menu {
                    Button { folderId = nil } label: {
                        if folderId == nil { NodusMenuLabel("All collections", systemImage: "checkmark") } else { Text("All collections") }
                    }
                    WorkspaceFolderMenuItems(folders: folders, parentId: nil, selection: $folderId)
                } label: {
                    VStack(spacing: 1) {
                        Text("Workspace").font(.caption2).foregroundStyle(.secondary)
                        Label(selectedFolderName, systemImage: "folder").font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Text("\(visible.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .task(id: session.publishedRevision) { await load() }
        .refreshable { await load() }
    }

    private var selectedFolderName: String { folderName(folderId) ?? String(localized: "All collections") }
    private func folderName(_ id: String?) -> String? {
        guard let id else { return nil }
        return folders.first { $0.string("id") == id }?.text("name")
    }

    private func load() async {
        let token = UUID(), client = session.client, spaceID = session.connection.spaceId
        loadID = token
        loading = true
        defer { if loadID == token { loading = false } }
        do {
            let loaded = try await PageTraversal.complete(identity: { $0.string("id") }) { offset in
                let page = try await client.notes(in: spaceID, limit: PageBounds.maxLimit, offset: offset)
                return Page(items: page.notes, total: page.total, limit: page.limit, offset: page.offset,
                    hasMore: page.hasMore, revision: page.revision)
            }
            // Folder navigation must describe the same publication as the complete catalogue.
            let tree = try await client.notes(in: spaceID, limit: 1, offset: 0)
            guard tree.revision == loaded.revision else { throw PageTraversalError.changingRevision }
            guard loadID == token else { return }
            items = loaded.items; folders = tree.folders; error = nil
        } catch let apiError as APIError where apiError.isNotPublished {
            guard loadID == token else { return }
            items = []; folders = []; error = nil
        } catch where error.isCancellation {
            // A replaced load must not turn cancellation into a catalogue error.
        } catch {
            guard loadID == token else { return }
            self.error = error.localizedDescription
        }
    }
}

private struct WorkspaceFolderMenuItems: View {
    let folders: [Row]
    let parentId: String?
    @Binding var selection: String?

    private var children: [Row] {
        folders.filter { $0.string("parent_id") == parentId }.sorted {
            let left = $0.int("order_idx") ?? 0, right = $1.int("order_idx") ?? 0
            return left == right ? ($0.text("name") ?? "") < ($1.text("name") ?? "") : left < right
        }
    }

    var body: some View {
        ForEach(Array(children.enumerated()), id: \.offset) { _, folder in
            if let id = folder.string("id") {
                let descendants = folders.filter { $0.string("parent_id") == id }
                let name = folder.text("name") ?? String(localized: "Collection")
                if descendants.isEmpty {
                    Button { selection = id } label: {
                        if selection == id { Label(name, systemImage: "checkmark") }
                        else { Label(name, systemImage: "folder") }
                    }
                } else {
                    Menu(name, systemImage: "folder") {
                        Button { selection = id } label: {
                            if selection == id { Label("All in \(name)", systemImage: "checkmark") }
                            else { Text("All in \(name)") }
                        }
                        WorkspaceFolderMenuItems(folders: folders, parentId: id, selection: $selection)
                    }
                }
            }
        }
    }
}

private struct WorkspaceItemCell: View {
    let item: Row
    let folderName: String?
    let accent: Color
    private var isIdea: Bool { item.string("kind") == "idea" }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isIdea ? "lightbulb.fill" : "note.text")
                .foregroundStyle(isIdea ? Color.orange : accent.nodusReadable).frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.text("title") ?? String(localized: "Untitled")).font(.headline).lineLimit(2)
                if let snippet = item.text("snippet"), !snippet.isEmpty { Text(snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
                HStack(spacing: 8) {
                    NodusChip(key: isIdea ? "Idea" : "Note", tint: isIdea ? .orange : accent)
                    if let folderName { Label(folderName, systemImage: "folder").lineLimit(1) }
                    if let updated = item.date("updated_at") { Text(updated, format: .relative(presentation: .named)) }
                }.font(.caption2).foregroundStyle(.tertiary)
            }
        }.padding(.vertical, 6)
    }
}

private struct PublishedWorkspaceItemView: View {
    let session: SpaceSession
    let summary: Row
    let folderName: String?
    @State private var item: Row?
    @State private var error: String?
    @State private var queued = false
    @State private var saving = false
    @State private var saveError: String?
    @State private var draftTitle = ""
    @State private var draftContent = ""
    @State private var loadedStorageID: String?
    @State private var loadRequestID = UUID()

    private var canEdit: Bool {
        session.canAuthor && item != nil && loadedStorageID == session.connection.storageId
            && item?.string("id") == summary.string("id")
    }
    private var hasChanges: Bool {
        guard let item else { return false }
        return draftTitle != (item.text("title") ?? "") || draftContent != (item.text("content") ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                if let item {
                    VStack(alignment: .leading, spacing: 8) {
                        if canEdit {
                            TextField("Untitled", text: $draftTitle, axis: .vertical)
                                .font(.title3.weight(.semibold)).textFieldStyle(.plain)
                                .accessibilityLabel("Title")
                        } else {
                            Text(item.text("title") ?? String(localized: "Untitled")).font(.title3.weight(.semibold))
                        }
                        HStack(spacing: 10) {
                            Label(item.string("kind") == "idea" ? "Idea" : "Note", systemImage: item.string("kind") == "idea" ? "lightbulb.fill" : "note.text")
                            if let folderName { Label(folderName, systemImage: "folder") }
                            if let updated = item.date("updated_at") { Text(updated, format: .relative(presentation: .named)) }
                        }.font(.caption).foregroundStyle(.secondary)
                        Button { UIPasteboard.general.string = canEdit ? draftContent : item.text("content") ?? "" } label: { Label("Copy", systemImage: "doc.on.doc") }
                            .font(.caption.weight(.semibold)).tint(session.accent)
                    }.padding(NodusSpace.cardPadding).frame(maxWidth: .infinity, alignment: .leading).nodusGlass(NodusGlass(.regular, tint: session.accent))
                    if canEdit {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Editor", systemImage: "doc.richtext").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Label("Select text for writing tools", systemImage: "text.cursor").font(.caption2).foregroundStyle(.tertiary)
                            }
                            WorkspaceEditorSurface(text: $draftContent, accent: session.accent, minHeight: 360)
                        }
                    } else {
                        CorpusProse(item.text("content") ?? "", accent: session.accent, session: session)
                            .padding(ReportLayout.sectionPadding).frame(maxWidth: .infinity, alignment: .leading)
                            .nodusGlass(NodusGlass(.regular, tint: session.accent))
                    }
                } else if let error {
                    NodusNotice(tone: .blocked, title: "Could not open", message: LocalizedStringKey(error))
                } else { ProgressView().tint(session.accent).frame(maxWidth: .infinity) }
            }.padding(NodusSpace.page).frame(maxWidth: ReportLayout.readerMeasure).frame(maxWidth: .infinity).nodusTopAnchor()
        }
        .navigationTitle(summary.string("kind") == "idea" ? "Idea" : "Note").navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent).nodusHidesBottomBar().nodusPageFunctions(accent: session.accent)
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await save() } } label: {
                        if saving { ProgressView().controlSize(.small) }
                        else { Image(systemName: hasChanges ? "checkmark.circle.fill" : "checkmark.circle") }
                    }
                    .disabled(saving || !hasChanges)
                    .accessibilityLabel("Save changes")
                }
            }
        }
        .alert(saveError == nil ? Text("Queued on this device") : Text("Could not save"),
            isPresented: Binding(get: { queued || saveError != nil }, set: {
                if !$0 { queued = false; saveError = nil }
            })) { Button("OK", role: .cancel) {} } message: {
                if let saveError { Text(saveError) }
            }
        .task(id: [session.connection.storageId, summary.string("id") ?? ""]) { await load() }
    }

    private func load() async {
        guard let id = summary.string("id") else { return }
        let storageID = session.connection.storageId, client = session.client, spaceID = session.connection.spaceId
        let token = UUID(); loadRequestID = token
        if loadedStorageID != storageID || item?.string("id") != id {
            item = nil; queued = false; saveError = nil
        }
        do {
            let loaded = try await client.note(id, in: spaceID)
            guard loadRequestID == token, session.connection.storageId == storageID, !Task.isCancelled else { return }
            item = loaded
            loadedStorageID = storageID
            draftTitle = loaded.text("title") ?? ""
            draftContent = loaded.text("content") ?? ""
            error = nil
        }
        catch {
            guard loadRequestID == token, session.connection.storageId == storageID, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        guard canEdit, let item, let note = EditableNote(item), hasChanges else { return }
        saving = true; defer { saving = false }
        let titleToSave = draftTitle, contentToSave = draftContent
        let storageID = session.connection.storageId
        let token = loadRequestID
        do {
            guard let outbox = await OutboxController.open(session: session) else { throw DesktopBridgeError.permissionDenied }
            guard session.connection.storageId == storageID, loadRequestID == token else { throw DesktopBridgeError.permissionDenied }
            try await outbox.queueNote(
                id: note.id,
                title: titleToSave,
                body: contentToSave,
                folderId: note.folderId,
                createdAt: note.createdAt
            )
            guard session.connection.storageId == storageID, loadRequestID == token else { return }
            queued = true
            // Keep the queued draft as the new local baseline. The published server copy changes
            // only when the owner's desktop accepts the mutation, but the editor must not keep
            // presenting a change it has already safely written to this device as unsaved.
            self.item = rowReplacing(item, title: titleToSave, content: contentToSave)
            saveError = nil
        } catch {
            guard session.connection.storageId == storageID, loadRequestID == token else { return }
            self.saveError = error.localizedDescription
        }
    }

    private func rowReplacing(_ row: Row, title: String, content: String) -> Row {
        var columns = row.columns
        columns["title"] = .string(title)
        columns["content"] = .string(content)
        return Row(columns)
    }
}
