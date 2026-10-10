import SwiftUI
import NodusKit

/// Selective companion copies use the same encrypted query keys as Scriptor.
/// The tree and every chosen structured document must finish before committing.
struct CompanionDownloadsView: View {
    let session: SpaceSession
    @Environment(\.dismiss) private var dismiss
    @State private var tree: JSONValue?
    @State private var selected = Set<String>()
    @State private var days = 7
    @State private var progress: (done: Int, total: Int)?
    @State private var issue: String?
    @State private var loading = true
    @State private var saved = false
    @State private var downloadTask: Task<Void, Never>?

    private var notes: [[String: JSONValue]] {
        (tree?.objectValue?["notes"]?.arrayValue ?? []).compactMap(\.objectValue)
            .filter { $0["trashedAt"] == nil || $0["trashedAt"] == .null }
            .sorted { ($0["title"]?.stringValue ?? "").localizedStandardCompare($1["title"]?.stringValue ?? "") == .orderedAscending }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Elige qué notas e ideas de Scriptor llevar contigo. Podrás leerlas y editarlas sin el Mac; tus cambios se sincronizarán cuando vuelva a estar disponible.")
                    Picker("Conservar la descarga", selection: $days) {
                        Text("7 días").tag(7); Text("30 días").tag(30)
                    }.disabled(progress != nil)
                } footer: {
                    Text("Las copias temporales caducan. Los borradores y cambios pendientes se conservan siempre. Los archivos externos y las imágenes enlazadas requieren su propia copia.")
                }
                if loading { ProgressView("Cargando documentos del Mac…") }
                if let issue { Section { Text(issue).foregroundStyle(Color.nodusDanger).accessibilityIdentifier("companion-download-error") } }
                if let progress {
                    Section {
                        ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                        Text("Descargando \(progress.done) de \(progress.total)")
                    }
                }
                if saved { Label("Descarga disponible sin conexión", systemImage: "checkmark.circle.fill").foregroundStyle(.green).accessibilityIdentifier("companion-download-ready") }
                Section("Documentos") {
                    ForEach(notes, id: \.idForDownload) { note in
                        if let id = note["id"]?.stringValue {
                            Button {
                                if !selected.insert(id).inserted { selected.remove(id) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selected.contains(id) ? "checkmark.circle.fill" : "circle").foregroundStyle(session.accent)
                                    Text(note["title"]?.stringValue ?? "Sin título").foregroundStyle(.primary).multilineTextAlignment(.leading)
                                }.frame(minHeight: 44)
                            }.accessibilityIdentifier("companion-download-note-\(id)")
                                .accessibilityValue(selected.contains(id) ? "Seleccionado" : "Sin seleccionar")
                                .disabled(progress != nil || saved)
                        }
                    }
                }
            }
            .navigationTitle("Descargar para llevar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(progress == nil ? "Cerrar" : "Cancelar") {
                        if progress != nil { downloadTask?.cancel() } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Descargar") { downloadTask = Task { await download() } }
                        .disabled(selected.isEmpty || tree == nil || progress != nil || saved)
                        .accessibilityIdentifier("companion-download-start")
                }
            }
            .task { await load() }
            .onDisappear { downloadTask?.cancel() }
        }
    }
    private func load() async {
        defer { loading = false }
        do {
            let (vault, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
            guard !pairing.isExpired else { throw DesktopBridgeError.permissionDenied }
            let value = try await DesktopBridgeClient(pairing: pairing, token: token).operation(vaultId: vault, method: "getNotesTree", args: [])
            guard value.objectValue?["notes"]?.arrayValue != nil, value.objectValue?["folders"]?.arrayValue != nil else { throw DesktopBridgeError.malformedResponse }
            tree = value
        } catch { issue = error.localizedDescription }
    }
    private func download() async {
        guard let tree else { return }
        issue = nil; progress = (0, selected.count)
        defer { progress = nil }
        do {
            let (vault, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
            guard !pairing.isExpired else { throw DesktopBridgeError.permissionDenied }
            let client = DesktopBridgeClient(pairing: pairing, token: token)
            let cache = try PrivateBridgeCache(pairingId: pairing.id)
            // Retain catalogue navigation without carrying the text of every
            // unselected document alongside one chosen download.
            var catalogue = tree.objectValue!
            catalogue["notes"] = .array(catalogue["notes"]!.arrayValue!.map { value in
                guard var note = value.objectValue else { return value }
                if !selected.contains(note["id"]?.stringValue ?? "") { note["content"] = .string("") }
                return .object(note)
            })
            var records = [PrivateBridgeCache.ReadPackRecord(domain: .corpus,
                recordId: try CompanionDocumentOutbox.operationKey("getNotesTree", []), data: try JSONEncoder.nodus.encode(JSONValue.object(catalogue))) ]
            var bytes = records[0].data.count
            for (index, id) in selected.sorted().enumerated() {
                try Task.checkCancellation()
                let args: [JSONValue] = [.string(id)]
                let value = try await client.operation(vaultId: vault, method: "getWorkspaceNoteEditorData", args: args)
                guard value.objectValue?["revision"]?.intValue != nil, value.objectValue?["nativeDocument"]?.arrayValue != nil else { throw DesktopBridgeError.malformedResponse }
                let data = try JSONEncoder.nodus.encode(value); bytes += data.count
                guard bytes <= PrivateBridgeCache.defaultReadLimitBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
                records.append(.init(domain: .corpus, recordId: try CompanionDocumentOutbox.operationKey("getWorkspaceNoteEditorData", args), data: data))
                progress = (index + 1, selected.count)
            }
            try Task.checkCancellation()
            try await cache.saveReadPack(vaultId: vault, title: selected.count == 1 ? "1 documento de Scriptor" : "\(selected.count) documentos de Scriptor",
                expiresAt: Date().addingTimeInterval(Double(days) * 86_400), records: records)
            saved = true
        } catch is CancellationError { issue = "Descarga cancelada. No se ha creado una copia incompleta." }
        catch let error as URLError where error.code == .cancelled { issue = "Descarga cancelada. No se ha creado una copia incompleta." }
        catch { issue = error.localizedDescription }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    var idForDownload: String { self["id"]?.stringValue ?? "" }
}
