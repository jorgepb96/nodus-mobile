import NodusKit
import SwiftUI

/// The section's own results remain one tap away when the Mac is asleep. This
/// reads the encrypted local ledger and never probes the connection or models.
struct CompanionResultsButton: View {
    let session: SpaceSession
    let surface: DesktopSurface
    let generationStatus: String?
    @State private var results: [DesktopJobLedger.Request] = []
    @State private var showing = false

    var body: some View {
        Group {
            if !results.isEmpty {
                Button { showing = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                        Text("Resultados del móvil (\(results.count))")
                        Spacer(minLength: 4)
                        if results.contains(where: { $0.state != "available" }) { Image(systemName: "arrow.triangle.2.circlepath").accessibilityLabel("Hay resultados pendientes de sincronizar") }
                        Image(systemName: "chevron.right")
                    }.font(.caption).padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).background(.thinMaterial)
                    .accessibilityIdentifier("companion-surface-results-\(surface.rawValue)")
            }
        }
        .task(id: "\(session.companionPublicationRevision):\(generationStatus ?? "")") { await refresh() }
        .sheet(isPresented: $showing) {
            NavigationStack {
                List(results) { request in
                    if let checkpoint = request.checkpoint {
                        NavigationLink {
                            CompanionGeneratedResultView(session: session, request: request, checkpoint: checkpoint)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(CompanionResultCatalogue.title(request)).font(.headline).lineLimit(3)
                                Text(request.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                Label(request.state == "available" ? "Sincronizado con Nodus" : ["failed", "interrupted", "cancelled"].contains(request.state)
                                    ? "Resultado conservado · revisar sincronización" : "Guardado en el móvil · pendiente de sincronizar",
                                    systemImage: request.state == "available" ? "checkmark.circle" : "iphone")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }.padding(.vertical, 4)
                        }.accessibilityIdentifier("companion-surface-result-\(request.id)")
                    }
                }
                .navigationTitle("Resultados del móvil").navigationBarTitleDisplayMode(.inline)
                .nodusModalClose(accent: session.accent)
                .task(id: session.companionPublicationRevision) { await refresh() }
            }
        }
    }
    private func refresh() async {
        guard let pairingId = session.connection.desktopPairingId, let vaultId = session.vaultId,
              let ledger = try? await DesktopJobLedgers.shared.ledger(pairingId: pairingId, vaultId: vaultId) else { results = []; return }
        results = await ledger.all().filter { CompanionResultCatalogue.contains($0, in: surface.rawValue) }
    }
}
