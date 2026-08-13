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
        List {
            NodusTopAnchorRow()
            if let error {
                NodusNotice(tone: .blocked, title: "Could not load Workspace", message: LocalizedStringKey(error))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            ForEach(Array(visible.enumerated()), id: \.offset) { _, item in
                NavigationLink { PublishedWorkspaceItemView(session: session, summary: item, folderName: folderName(item.string("folder_id"))) } label: {
                    WorkspaceItemCell(item: item, folderName: folderName(item.string("folder_id")), accent: session.accent)
                }.listRowBackground(Color.clear)
            }
            if loading, items.isEmpty { HStack { Spacer(); ProgressView().tint(session.accent); Spacer() }.listRowBackground(Color.clear) }
            if !loading, visible.isEmpty, error == nil {
                ContentUnavailableView("Nothing here", systemImage: "rectangle.stack", description: Text("Try another search, collection or content type."))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).nodusDismissesKeyboard()
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                NodusSearchField(text: $query, prompt: "Search notes and ideas", accent: session.accent, isBusy: loading)
                Picker("Content type", selection: $kind) {
                    ForEach(KindFilter.allCases) { value in Text(value.title).tag(value) }
                }.pickerStyle(.segmented).padding(.horizontal, NodusSpace.page)
            }.padding(.bottom, 8).background(.ultraThinMaterial)
        }
        .navigationTitle("Workspace").navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent).nodusHidesBottomBar()
        .toolbar {
            ToolbarItem(placement: .principal) {
                Menu {
                    Button { folderId = nil } label: {
                        if folderId == nil { Label("All collections", systemImage: "checkmark") } else { Text("All collections") }
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
        loading = true; defer { loading = false }
        do {
            var loaded: [Row] = [], offset = 0, loadedFolders: [Row] = []
            while true {
                let page = try await session.client.notes(in: session.connection.spaceId, limit: 200, offset: offset)
                loaded.append(contentsOf: page.notes); if loadedFolders.isEmpty { loadedFolders = page.folders }
                if !page.hasMore { break }; offset += page.notes.count
            }
            items = loaded; folders = loadedFolders; error = nil
        } catch let apiError as APIError where apiError.isNotPublished {
            items = []; folders = []; error = nil
        } catch { self.error = error.localizedDescription }
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
    @State private var editing: EditableNote?
    @State private var queued = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                if let item {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.text("title") ?? String(localized: "Untitled")).font(.title3.weight(.semibold))
                        HStack(spacing: 10) {
                            Label(item.string("kind") == "idea" ? "Idea" : "Note", systemImage: item.string("kind") == "idea" ? "lightbulb.fill" : "note.text")
                            if let folderName { Label(folderName, systemImage: "folder") }
                            if let updated = item.date("updated_at") { Text(updated, format: .relative(presentation: .named)) }
                        }.font(.caption).foregroundStyle(.secondary)
                        Button { UIPasteboard.general.string = item.text("content") ?? "" } label: { Label("Copy", systemImage: "doc.on.doc") }
                            .font(.caption.weight(.semibold)).tint(session.accent)
                    }.padding(NodusSpace.cardPadding).frame(maxWidth: .infinity, alignment: .leading).nodusGlass(NodusGlass(.regular, tint: session.accent))
                    CorpusProse(item.text("content") ?? "", accent: session.accent, session: session)
                        .padding(ReportLayout.sectionPadding).frame(maxWidth: .infinity, alignment: .leading)
                        .nodusGlass(NodusGlass(.regular, tint: session.accent))
                } else if let error {
                    NodusNotice(tone: .blocked, title: "Could not open", message: LocalizedStringKey(error))
                } else { ProgressView().tint(session.accent).frame(maxWidth: .infinity) }
            }.padding(NodusSpace.page).frame(maxWidth: ReportLayout.readerMeasure).frame(maxWidth: .infinity).nodusTopAnchor()
        }
        .navigationTitle(summary.string("kind") == "idea" ? "Idea" : "Note").navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent).nodusHidesBottomBar().nodusPageFunctions(accent: session.accent)
        .toolbar {
            if session.connection.role.canSendChanges, let item {
                ToolbarItem(placement: .topBarTrailing) { Button { editing = EditableNote(item) } label: { Image(systemName: "pencil") } }
            }
        }
        .nodusSheet(item: $editing) { note in
            NoteEditor(accent: session.accent, note: note) { title, body in
                guard let outbox = await OutboxController.open(session: session) else { return }
                await outbox.queueNote(id: note.id, title: title, body: body, folderId: note.folderId, createdAt: note.createdAt)
                queued = true
            }
        }
        .alert("Queued on this device", isPresented: $queued) { Button("OK", role: .cancel) {} }
        .task { await load() }
    }

    private func load() async {
        guard let id = summary.string("id") else { return }
        do { item = try await session.client.note(id, in: session.connection.spaceId); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
