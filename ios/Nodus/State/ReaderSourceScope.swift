import NodusKit
import NodusUI
import SwiftUI

private struct DownloadedReaderOnlyKey: EnvironmentKey { nonisolated static let defaultValue = false }
extension EnvironmentValues {
    var downloadedReaderOnly: Bool {
        get { self[DownloadedReaderOnlyKey.self] }
        set { self[DownloadedReaderOnlyKey.self] = newValue }
    }
}

/// Reads only actual independent selections and authored documents. There is no
/// NodusClient/Bridge operation in this path, including for missing citations.
@MainActor
private func downloadedReaderSelection(_ session: SpaceSession, path: String, id: String) async throws -> CompanionReaderScope.Selection {
    if session.connection.desktopPairingId == nil {
        guard let mirror = session.mirror else { throw CompanionReaderScope.ReadError.notDownloaded }
        return try await CompanionReaderScope.resolveMirror(path: path, id: id, spaceId: session.connection.spaceId, mirror: mirror)
    }
    let (vault, pairing, _) = try privateBridgeConnection(session, domain: .corpus)
    guard !pairing.isExpired else { throw DesktopBridgeError.expired }
    let cache = try PrivateBridgeCache(pairingId: pairing.id)
    let copy = Collections[path] == nil ? nil : try await CompanionCollectionCopy.downloaded(cache: cache, vaultId: vault, path: path)
    let ideas = ["ideas", "debates"].contains(path) ? try await CompanionIdeaCopy.consultable(cache: cache, vaultId: vault) : nil
    var note: JSONValue?
    if path == "notes" {
        let queue = try await CompanionDocumentOutboxes.shared.outbox(pairingId: pairing.id, vaultId: vault)
        note = await queue.editorData(noteId: id)
        if note == nil { note = await queue.confirmedEditorData(noteId: id) }
        if note == nil {
            let key = try CompanionDocumentOutbox.operationKey("getWorkspaceNoteEditorData", [.string(id)])
            if let bytes = try await cache.downloadedData(vaultId: vault, domain: .corpus, recordId: key).first {
                note = try JSONDecoder.nodus.decode(JSONValue.self, from: bytes)
            }
        }
    }
    if path == "passages", copy?.selectedRows.contains(where: { $0.string("passage_id") == id }) != true,
       let work = try await CompanionCollectionCopy.downloaded(cache: cache, vaultId: vault, path: "works"),
       work.selectedRows.contains(where: { $0.string("nodus_id") == id }) {
        return try CompanionReaderScope.resolve(path: "works", id: id, collections: [work])
    }
    return try CompanionReaderScope.resolve(path: path, id: id, collections: copy.map { [$0] } ?? [], ideas: ideas, noteEditor: note)
}

struct DownloadedReaderReferenceView: View {
    let session: SpaceSession
    let path: String
    let id: String
    var specialised: SpecialisedCorpusReference? = nil
    @State private var selection: CompanionReaderScope.Selection?
    @State private var issue: String?
    @State private var attempt = 0
    @State private var related: Target?
    private struct Target: Identifiable { let path: String; let recordId: String; var id: String { path + ":" + recordId } }
    var body: some View {
        Group {
            if let selection {
                ScrollView {
                    VStack(alignment: .leading, spacing: NodusSpace.block) {
                        Label("Downloaded or authored source", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                        switch selection {
                        case .dossier(let dossier):
                            CollectionDossierBody(session: session, dossier: dossier, showConnectionState: false,
                                onOpenRelated: { collection, row in
                                    if let id = row.string(collection.idField) { related = .init(path: collection.path, recordId: id) }
                                }, downloadedOnly: true)
                            DossierOriginalResourcesView(session: session, dossier: dossier, downloadedOnly: true)
                        case .literal(let value):
                            DossierValueView(session: session, value: value, field: "", linkedCollection: nil)
                        }
                    }.padding(NodusSpace.page).frame(maxWidth: 980).frame(maxWidth: .infinity)
                }
            } else if let issue { CorpusOpenFailure(message: issue) { attempt += 1 } }
            else { ProgressView("Reading downloaded source…") }
        }.environment(\.downloadedReaderOnly, true)
            .navigationTitle("Cited source").navigationBarTitleDisplayMode(.inline).nodusPageBackdrop(accent: session.accent)
            .task(id: "\(path):\(id):\(session.companionDownloadRevision):\(attempt)") {
                selection = nil; issue = nil
                do {
                    let value = try await downloadedReaderSelection(session, path: path, id: id)
                    if case .dossier(let dossier) = value, specialised?.accepts(dossier.primary) == false { throw SpecialisedCorpusReference.ReadError.sourceMismatch }
                    try Task.checkCancellation(); selection = value
                } catch where error.isCancellation { }
                catch { issue = error.localizedDescription }
            }
            .sheet(item: $related) { target in
                NavigationStack {
                    if let collection = Collections[target.path] { RowByIdView(session: session, collection: collection, id: target.recordId) }
                    else { ContentUnavailableView("Source unavailable", systemImage: "questionmark.circle") }
                }
                    .environment(\.downloadedReaderOnly, true)
            }
    }
}
