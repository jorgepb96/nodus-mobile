import NodusKit
import NodusUI
import SwiftUI

/// Metadata pages are lightweight. The user chooses each complete temporary
/// conversation download before it becomes available without the Mac.
struct CompanionChatCatalogueView: View {
    let session: SpaceSession
    let store: ChatHistoryStore
    let onOpen: (ChatHistoryStore.Conversation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [JSONValue] = []
    @State private var cursor = 0
    @State private var revision: String?
    @State private var hasMore = true
    @State private var loading = false
    @State private var downloading: String?
    @State private var issue: String?
    @State private var query = ""
    @State private var placementFilter = "all"
    private var kind: CompanionChatKind { CompanionChatKind(vaultType:session.vaultType) }
    private var filtered: [JSONValue] {
        let needle = query.trimmingCharacters(in:.whitespacesAndNewlines)
        return rows.filter { row in
            let raw = row.objectValue ?? [:]
            let scope = placementFilter == "all" || placementFilter == "pinned" && raw["pinnedAt"]?.stringValue != nil || placementFilter.hasPrefix("project:") && raw["projectId"]?.stringValue == String(placementFilter.dropFirst(8)) || placementFilter.hasPrefix("folder:") && raw["folderId"]?.stringValue == String(placementFilter.dropFirst(7)) || placementFilter.hasPrefix("notebook:") && raw["notebookId"]?.stringValue == String(placementFilter.dropFirst(9))
            return scope && (needle.isEmpty || (raw["title"]?.stringValue ?? "").localizedCaseInsensitiveContains(needle))
        }
    }
    var body: some View {
        NavigationStack {
            List {
                ChatHistoryScopePicker(organisation:store.organisation,filter:$placementFilter)
                Text("Choose a conversation to keep it on this device for 14 days. Editing it keeps your work until it synchronizes.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let issue {
                    NodusNotice(tone:.blocked,title:"History needs attention",message:LocalizedStringKey(issue))
                    Button("Retry") { Task { await load(reset:true) } }.disabled(loading)
                }
                ForEach(filtered,id:\.self) { row in
                    if let id = row.objectValue?["id"]?.stringValue {
                        Button { Task { await download(id) } } label: {
                            HStack {
                                VStack(alignment:.leading,spacing:5) {
                                    Text(verbatim:row.objectValue?["title"]?.stringValue ?? "").foregroundStyle(.primary).lineLimit(3)
                                    if let count = row.objectValue?["messageCount"]?.intValue { Text("\(count) messages").font(.caption).foregroundStyle(.secondary) }
                                    if row.objectValue?["pinnedAt"]?.stringValue != nil { Label("Fijada",systemImage:"pin.fill").font(.caption).foregroundStyle(.secondary) }
                                    if let project = row.objectValue?["projectId"]?.stringValue,let name = store.organisation?.projects.first(where:{$0.id == project})?.name { Text(verbatim:name).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength:12)
                                if downloading == id { ProgressView() } else { Image(systemName:"arrow.down.circle").foregroundStyle(session.accent) }
                            }.frame(minHeight:44)
                        }.disabled(downloading != nil)
                    }
                }
                if loading { ProgressView() }
                else if hasMore { Button("Load more conversations") { Task { await load(reset:false) } } }
                else if rows.isEmpty,issue == nil { ContentUnavailableView("No conversations yet",systemImage:"bubble.left.and.text.bubble.right") }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .searchable(text:$query,prompt:"Filter loaded conversations")
            .navigationTitle("Mac conversations").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Done") { dismiss() } } }
            .nodusPageBackdrop(accent:session.accent)
            .task { await load(reset:true) }
        }.tint(session.accent)
    }
    private func load(reset: Bool) async {
        guard !loading else { return };loading = true;defer { loading = false }
        do {
            guard let vault = session.vaultId else { throw DesktopBridgeError.permissionDenied }
            let bridge = try ConnectionClient.companionChat(for:session.connection)
            let page = try await bridge.chatHistoryPage(vaultId:vault,kind:kind,cursor:reset ? 0:cursor,revision:reset ? nil:revision)
            if let organisation = page.organisation { try organisation.validate(kind:kind);try store.retainOrganisation(organisation) }
            let existing = Set((reset ? []:rows).compactMap{$0.objectValue?["id"]?.stringValue})
            let ids = page.rows.compactMap{$0.objectValue?["id"]?.stringValue}
            guard Set(ids).count == ids.count,existing.isDisjoint(with:ids) else { throw DesktopBridgeError.malformedResponse }
            rows = (reset ? []:rows) + page.rows;cursor = page.cursor;revision = page.revision;hasMore = page.hasMore;issue = nil
        } catch { issue = error.localizedDescription }
    }
    private func download(_ id: String) async {
        guard downloading == nil else { return };downloading = id;defer { downloading = nil }
        do {
            guard let vault = session.vaultId else { throw DesktopBridgeError.permissionDenied }
            let document = try await ConnectionClient.companionChat(for:session.connection).chatDocument(vaultId:vault,kind:kind,id:id)
            let conversation = try store.importDesktop(document)
            onOpen(conversation);dismiss()
        } catch { issue = error.localizedDescription }
    }
}
