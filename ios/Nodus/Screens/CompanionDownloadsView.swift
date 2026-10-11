import SwiftUI
import NodusKit
import NodusUI

/// Selective companion copies use the same encrypted query keys as Scriptor.
/// The tree and every chosen structured document must finish before committing.
struct CompanionDownloadsView: View {
    let session: SpaceSession
    @Environment(\.dismiss) private var dismiss
    @State private var tree: JSONValue?
    @State private var selected = Set<String>()
    @State private var query = ""
    @State private var days = 7
    @State private var progress: (done: Int, total: Int)?
    @State private var issue: String?
    @State private var loading = true
    @State private var saved = false
    @State private var downloadTask: Task<Void, Never>?
    @State private var showingDownloadedDossiers = false
    @State private var showingStudySources = false
    @State private var studyOptions = CompanionStudyChatOptions()
    @State private var showingWorldSources = false
    @State private var worldOptions = CompanionWorldChatOptions()

    private var notes: [[String: JSONValue]] {
        (tree?.objectValue?["notes"]?.arrayValue ?? []).compactMap(\.objectValue)
            .filter { $0["trashedAt"] == nil || $0["trashedAt"] == .null }
            .sorted { ($0["title"]?.stringValue ?? "").localizedStandardCompare($1["title"]?.stringValue ?? "") == .orderedAscending }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if session.vaultType == .worldbuilding { Button("Contexto del chat de mundos") { showingWorldSources = true }.frame(minHeight:44) }
                    if session.vaultType == .estudio || session.vaultType == .docencia {
                        Button("Fuentes del chat de estudio") { showingStudySources = true }.frame(minHeight:44)
                    }
                    if session.vaultType == .databases {
                        NavigationLink("Informes de bases de datos") { CompanionDatabaseResearchDownloadsView(session:session) }
                            .accessibilityIdentifier("companion-download-database-research")
                    }
                    Button { showingDownloadedDossiers = true } label: {
                        Label("Consultar dossiers descargados", systemImage: "arrow.down.circle")
                    }.frame(minHeight: 44).accessibilityIdentifier("companion-open-downloaded-dossiers")
                    NavigationLink("Biblioteca y otros dossiers") {
                        CompanionCollectionDownloadsView(session: session)
                    }.accessibilityIdentifier("companion-download-collections")
                    Text("Elige qué notas e ideas de Scriptor llevar contigo. Podrás leerlas y editarlas sin el Mac; tus cambios se sincronizarán cuando vuelva a estar disponible.")
                    Picker("Conservar la descarga", selection: $days) {
                        Text("7 días").tag(7); Text("30 días").tag(30)
                    }.disabled(progress != nil)
                } footer: {
                    Text("Las copias temporales caducan. Los borradores y cambios pendientes se conservan siempre. Los archivos externos y las imágenes enlazadas requieren su propia copia.")
                }
                Section {
                    if session.vaultType == .academic {
                        NavigationLink("Ideas y conexiones del corpus") {
                            CompanionIdeaDownloadsView(session: session)
                        }.accessibilityIdentifier("companion-download-ideas")
                        NavigationLink("Material para crear inmersiones") {
                            CompanionImmersionDownloadsView(session: session)
                        }.accessibilityIdentifier("companion-download-immersion-material")
                    }
                    NavigationLink("Informes, diccionario e inmersiones") {
                        CompanionResearchDownloadsView(session: session)
                    }.accessibilityIdentifier("companion-download-research")
                }
                if loading { ProgressView("Cargando documentos del Mac…") }
                if let issue {
                    Section {
                        Text(issue).foregroundStyle(Color.nodusDanger).accessibilityIdentifier("companion-download-error")
                        if progress == nil { Button("Volver a cargar") { Task { await load() } } }
                    }
                }
                if let progress {
                    Section {
                        ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                        Text("Descargando \(progress.done) de \(progress.total)")
                    }
                }
                if saved { Label("Descarga disponible sin conexión", systemImage: "checkmark.circle.fill").foregroundStyle(.green).accessibilityIdentifier("companion-download-ready") }
                Section("Documentos") {
                    ForEach(notes.filter { query.isEmpty || ($0["title"]?.stringValue ?? "").localizedStandardContains(query) }, id: \.idForDownload) { note in
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
            .searchable(text: $query, prompt: "Buscar notas e ideas")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 12) {
                    if saved {
                        Button("Cerrar") { dismiss() }
                            .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent))
                    } else {
                        Button(progress == nil ? "Cerrar" : "Cancelar") {
                            if progress != nil { downloadTask?.cancel() } else { dismiss() }
                        }.buttonStyle(NodusGlassButtonStyle(accent: session.accent))
                        Button("Descargar") { downloadTask = Task { await download() } }
                            .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent))
                            .disabled(selected.isEmpty || tree == nil || progress != nil)
                            .accessibilityIdentifier("companion-download-start")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, NodusSpace.page)
                .padding(.vertical, 10)
                .background { NodusBackdrop(accent: session.accent) }
            }
            .task { await load() }
            .nodusSheet(isPresented: $showingDownloadedDossiers) { CompanionDownloadedCollectionsView(session: session) }
            .nodusSheet(isPresented:$showingStudySources) { ChatStudyOptionsView(session:session,options:$studyOptions,downloadOnly:true) }
            .nodusSheet(isPresented:$showingWorldSources) { ChatWorldOptionsView(session:session,options:$worldOptions,downloadOnly:true) }
            .onDisappear { downloadTask?.cancel() }
        }
    }
    private func load() async {
        loading = true; issue = nil; saved = false
        defer { loading = false }
        do {
            let (vault, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
            guard !pairing.isExpired else { throw DesktopBridgeError.permissionDenied }
            let value = try await DesktopBridgeClient(pairing: pairing, token: token).operation(vaultId: vault, method: "getNotesTree", args: [.bool(true)])
            guard value.objectValue?["notes"]?.arrayValue != nil, value.objectValue?["folders"]?.arrayValue != nil else { throw DesktopBridgeError.malformedResponse }
            tree = value
            selected.formIntersection(Set((value.objectValue?["notes"]?.arrayValue ?? []).compactMap { $0.objectValue?["id"]?.stringValue }))
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
            let catalogueData = try JSONEncoder.nodus.encode(JSONValue.object(catalogue))
            // Scriptor opens the complete catalogue (including trash), while
            // chapter navigation requests the default, untrashed catalogue.
            var records = [PrivateBridgeCache.ReadPackRecord(domain: .corpus,
                recordId: try CompanionDocumentOutbox.operationKey("getNotesTree", [.bool(true)]), data: catalogueData)]
            var visibleCatalogue = catalogue
            visibleCatalogue["notes"] = .array(catalogue["notes"]!.arrayValue!.filter { note in
                note.objectValue?["trashedAt"] == nil || note.objectValue?["trashedAt"] == .null
            })
            records.append(.init(domain: .corpus, recordId: try CompanionDocumentOutbox.operationKey("getNotesTree", []),
                                 data: try JSONEncoder.nodus.encode(JSONValue.object(visibleCatalogue))))
            // These read-only queries bootstrap the shared editor. They must be
            // part of the chosen copy, rather than depend on disposable cache.
            for method in ["getSettings", "listStudyStyles", "listAllWorkspaceLibraryLinks", "getThemes"] {
                try Task.checkCancellation()
                var value = try await client.operation(vaultId: vault, method: method, args: [])
                if method == "getSettings" {
                    guard value.objectValue != nil else { throw DesktopBridgeError.malformedResponse }
                } else {
                    guard let rows = value.arrayValue else { throw DesktopBridgeError.malformedResponse }
                    if method == "listAllWorkspaceLibraryLinks" {
                        let folders = Set((catalogue["folders"]?.arrayValue ?? []).compactMap { $0.objectValue?["id"]?.stringValue })
                        value = .array(rows.filter { row in
                            guard let object = row.objectValue, let owner = object["ownerId"]?.stringValue else { return false }
                            return object["ownerKind"]?.stringValue == "note" ? selected.contains(owner) : folders.contains(owner)
                        })
                    }
                }
                records.append(.init(domain: .corpus, recordId: try CompanionDocumentOutbox.operationKey(method, []),
                                     data: try JSONEncoder.nodus.encode(value)))
            }
            var bytes = records.reduce(0) { $0 + $1.data.count }
            guard bytes <= PrivateBridgeCache.maximumSelectedCopyBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            var selectedImages = Set<String>()
            for (index, id) in selected.sorted().enumerated() {
                try Task.checkCancellation()
                let args: [JSONValue] = [.string(id)]
                let value = try await client.operation(vaultId: vault, method: "getWorkspaceNoteEditorData", args: args)
                guard value.objectValue?["revision"]?.intValue != nil, value.objectValue?["nativeDocument"]?.arrayValue != nil else { throw DesktopBridgeError.malformedResponse }
                let data = try JSONEncoder.nodus.encode(value); bytes += data.count
                guard bytes <= PrivateBridgeCache.maximumSelectedCopyBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
                records.append(.init(domain: .corpus, recordId: try CompanionDocumentOutbox.operationKey("getWorkspaceNoteEditorData", args), data: data))
                for sourceURL in try CompanionCorpusImage.sourceURLs(in:value) {
                    guard selectedImages.insert(sourceURL).inserted else { continue }
                    let image = try await CompanionCorpusImage.load(client:client,cache:cache,vaultId:vault,source:sourceURL,domains:Array(pairing.domains))
                    let data = try JSONEncoder.nodus.encode(image); bytes += data.count
                    guard bytes <= PrivateBridgeCache.maximumSelectedCopyBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
                    records.append(.init(domain:.corpus,recordId:CompanionCorpusImage.recordId(source:sourceURL),data:data))
                }
                for sourceURL in try CompanionEmbeddedResource.sourceURLs(in:value) {
                    guard selectedImages.insert(sourceURL).inserted else { continue }
                    let resource = try await CompanionEmbeddedResource.load(client:client,cache:cache,vaultId:vault,source:sourceURL,domains:Array(pairing.domains))
                    let data = try JSONEncoder.nodus.encode(resource); bytes += data.count
                    guard bytes <= PrivateBridgeCache.maximumSelectedCopyBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
                    records.append(.init(domain:.corpus,recordId:CompanionEmbeddedResource.recordId(source:sourceURL),data:data))
                }
                let sourceArgs: [JSONValue] = [.object(["noteId": .string(id)])]
                let source = try await client.operation(vaultId: vault, method: "getStudyImprovementOfflineSource", args: sourceArgs)
                guard source.objectValue?["version"] == .int(1), source.objectValue?["noteId"] == .string(id),
                      source.objectValue?["source"]?.objectValue?["id"] == .string(id),
                      source.objectValue?["styles"]?.arrayValue != nil else { throw DesktopBridgeError.malformedResponse }
                let sourceData = try JSONEncoder.nodus.encode(source); bytes += sourceData.count
                guard bytes <= PrivateBridgeCache.maximumSelectedCopyBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
                records.append(.init(domain: .corpus, recordId: try CompanionDocumentOutbox.operationKey("getStudyImprovementOfflineSource", sourceArgs), data: sourceData))
                // The editor and autonomous source must describe one canonical
                // revision. A concurrent Mac edit rejects the complete pack.
                let current = try await client.operation(vaultId: vault, method: "getWorkspaceNoteEditorData", args: args)
                guard current == value else { throw DesktopBridgeError.malformedResponse }
                progress = (index + 1, selected.count)
            }
            try Task.checkCancellation()
            let id = try PrivateBridgeCache.readPackSelectionId(vaultId: vault, recordIds: selected.map { "scriptor:\($0)" })
            try await cache.saveReadPack(id: id, vaultId: vault, title: selected.count == 1 ? "1 documento de Scriptor" : "\(selected.count) documentos de Scriptor",
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
