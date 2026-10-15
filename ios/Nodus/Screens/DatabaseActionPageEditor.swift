import NodusKit
import NodusUI
import SwiftUI

/// The existing BlockNote page surface edits the complete authored document.
/// Its page store holds writes until the owning button creation is acknowledged.
struct DatabaseActionPageEditor: View {
    let session: SpaceSession
    let checkpoint: JSONValue
    let rowId: String
    @State private var pageId: String?
    @State private var issue: String?
    var body: some View {
        Group {
            if let pageId {
                SharedDesktopSurface(session: session, surface: .page, initialPageId: pageId, downloadedOnly: true)
            } else if let issue {
                ContentUnavailableView("No se pudo abrir la página", systemImage: "doc.text", description: Text(issue))
            } else { ProgressView("Abriendo documento guardado…") }
        }
        .navigationTitle("Página creada").navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let (vault, pairing, _) = try privateBridgeConnection(session, domain: .writing)
                let store = try await CompanionPageDocumentStores.shared.store(pairingId: pairing.id, vaultId: vault)
                pageId = try await store.prepareDatabaseActionPage(checkpoint: CompanionDatabaseActionCheckpoint(checkpoint), rowId: rowId)
            } catch { issue = error.localizedDescription }
        }
        .accessibilityIdentifier("database-action-page-editor-" + rowId)
    }
}
