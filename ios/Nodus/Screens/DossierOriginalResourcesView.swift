import NodusKit
import NodusUI
import SwiftUI

/// Native file controls and full-resolution, zoomable dossier illustrations.
/// Metadata and gallery identity remain tied to the selected parent dossier.
struct DossierOriginalResourcesView: View {
    let session: SpaceSession
    let dossier: CollectionDossier
    var downloadedOnly = false
    @State private var files: [CompanionDossierResources.File] = []
    @State private var images: [String] = []
    @State private var issue: String?
    @State private var loading = false
    @State private var attempt = 0
    @State private var visibleFiles = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !images.isEmpty {
                DisclosureGroup("Imágenes · \(images.count)") {
                    LazyVStack(spacing: 16) {
                        ForEach(images, id: \.self) { source in
                            ReaderInlineImage(reference: .init(source: source, alternative: dossier.collection.presenter.title(dossier.primary)), session: session, accent: session.accent, downloadedOnly: downloadedOnly)
                        }
                    }.padding(.top, 12)
                }
            }
            if !files.isEmpty {
                DisclosureGroup("Archivos originales · \(files.count)") {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(files.prefix(visibleFiles)) { file in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(file.title).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                                if file.available { PrivateFileButton(session: session, kind: file.kind, id: file.fileId, downloadedOnly: downloadedOnly) }
                                else { Label("El original no está disponible en el Mac", systemImage: "doc.badge.ellipsis").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        if visibleFiles < files.count { Button("Mostrar más archivos (\(files.count - visibleFiles))") { visibleFiles += 30 }.frame(minHeight: 44) }
                    }.padding(.top, 12)
                }
            }
            if loading { ProgressView("Consultando originales…") }
            if let issue {
                NodusNotice(tone: .caution, title: "Originales no disponibles", message: LocalizedStringKey(issue))
                Button("Reintentar") { attempt += 1 }.frame(minHeight: 44)
            }
        }
        .task(id: "\(dossier.collection.path)|\(dossier.primary.string(dossier.collection.idField) ?? "")|\(attempt)|\(session.companionDownloadRevision)") {
            guard session.connection.desktopPairingId != nil, let id = dossier.primary.string(dossier.collection.idField) else { return }
            loading = true; issue = nil; images = []; files = []; visibleFiles = 30
            defer { loading = false }
            do {
                images = try CompanionDossierResources.imageSources(collection: dossier.collection.path, id: id, detail: dossier.payload)
                if CompanionDossierResources.fileCollections.contains(dossier.collection.path) {
                    let args = CompanionDossierResources.arguments(collection: dossier.collection.path, id: id)
                    let value = try await loadPrivateBridgeValue(session, method: "getMobileDossierFiles", args: args, downloadedOnly: downloadedOnly)
                    let catalog = try CompanionDossierResources(value: value, collection: dossier.collection.path, id: id)
                    try Task.checkCancellation(); files = catalog.files
                }
            } catch where error.isCancellation {}
            catch { issue = error.localizedDescription }
        }
    }
}
