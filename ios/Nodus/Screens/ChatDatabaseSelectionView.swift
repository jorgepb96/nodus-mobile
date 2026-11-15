import NodusAI
import NodusKit
import NodusUI
import SwiftUI

struct ChatDatabaseSelectionView: View {
    let session: SpaceSession
    @Binding var selection: [String]
    @Environment(AISettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [JSONValue] = []
    @State private var loading = true
    @State private var issue: String?
    @State private var query = ""
    @State private var offline = false
    var body: some View {
        NavigationStack {
            List {
                Text(offline ? "Choose from the complete databases downloaded to this device.":"The same complete profiles and samples used by Nodus will support your question.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let issue {
                    NodusNotice(tone:.blocked,title:"Could not load databases",message:LocalizedStringKey(issue))
                    Button("Retry") { Task { await load() } }
                }
                if loading { ProgressView() }
                ForEach(rows.filter { query.isEmpty || ($0.objectValue?["name"]?.stringValue ?? "").localizedCaseInsensitiveContains(query) },id:\.self) { row in
                    if let id = row.objectValue?["id"]?.stringValue {
                        Button {
                            if selection.contains(id) { selection.removeAll{$0 == id} }
                            else if selection.count < 30 { selection.append(id) }
                        } label: {
                            HStack {
                                Image(systemName:selection.contains(id) ? "checkmark.circle.fill":"circle").foregroundStyle(session.accent)
                                VStack(alignment:.leading,spacing:4) {
                                    Text(verbatim:row.objectValue?["name"]?.stringValue ?? id).foregroundStyle(.primary)
                                    if let count = row.objectValue?["rowCount"]?.intValue { Text("\(count) rows").font(.caption).foregroundStyle(.secondary) }
                                }
                            }.frame(minHeight:44)
                        }.buttonStyle(.plain)
                    }
                }
                if rows.isEmpty,!loading,issue == nil { ContentUnavailableView("No databases",systemImage:"tablecells") }
            }
            .navigationTitle("Chat databases").navigationBarTitleDisplayMode(.inline)
            .searchable(text:$query,prompt:"Search databases")
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } } }
            .scrollContentBackground(.hidden).nodusPageBackdrop(accent:session.accent)
            .task { await load() }
        }.tint(session.accent)
    }
    private func load() async {
        loading = true;defer { loading = false }
        do {
            guard let vault = session.vaultId else { throw DesktopBridgeError.permissionDenied }
            let value: JSONValue
            do {
                value = try await ConnectionClient.companionChat(for:session.connection).operation(vaultId:vault,method:"listDatabases",args:[]);offline = false
            } catch {
                guard isPrivateBridgeOffline(error) else { throw error }
                let downloaded = try await AutonomousSurfaceProvider(settings:settings).databaseOfflineCatalogue(session:session)
                guard let sources = downloaded.arrayValue else { throw DesktopBridgeError.malformedResponse }
                value = .array(try sources.map { guard let database = $0.objectValue?["database"] else { throw DesktopBridgeError.malformedResponse };return database });offline = true
            }
            guard let entries = value.arrayValue,entries.allSatisfy({$0.objectValue?["id"]?.stringValue != nil && $0.objectValue?["name"]?.stringValue != nil}) else { throw DesktopBridgeError.malformedResponse }
            rows = entries;issue = nil
        } catch { issue = error.localizedDescription }
    }
}
