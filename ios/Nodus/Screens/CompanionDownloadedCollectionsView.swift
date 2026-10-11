import NodusKit
import NodusUI
import SwiftUI

private struct DownloadedDossierTarget: Hashable {
    let collectionPath: String
    let id: String
}

private enum DownloadedCollectionDestination: Hashable {
    case catalogue(String)
    case dossier(DownloadedDossierTarget)
    case privateCatalogue(PrivateCorpusReference.Kind)
}

/// Dossiers stay separate from the full vault and from privacy-scoped private tables.
/// Only the collection currently being read is decrypted into memory.
struct CompanionDownloadedCollectionsView: View {
    let session: SpaceSession
    var paths: [String]? = nil
    var matching: [String: JSONValue] = [:]
    @State private var available: [CollectionDescriptor] = []
    @State private var privateKinds: [PrivateCorpusReference.Kind] = []
    @State private var loading = true
    @State private var issue: String?
    @State private var navigation: [DownloadedCollectionDestination] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack(path: $navigation) {
            List {
                Section {
                    Text("Consulta los dossiers que has elegido llevar contigo. Esta vista muestra las descargas del dispositivo.")
                } footer: {
                    Text("Las copias caducan según el plazo elegido. Las fuentes enlazadas, archivos e imágenes requieren su propia descarga. Los registros privados mantienen sus permisos de acceso.")
                }
                if loading { ProgressView("Leyendo descargas…") }
                if let issue {
                    Section {
                        Text(issue).foregroundStyle(Color.nodusDanger)
                        Button("Reintentar") { Task { await load() } }.frame(minHeight: 44)
                    }
                } else if !loading, available.isEmpty, privateKinds.isEmpty {
                    ContentUnavailableView("Sin dossiers descargados", systemImage: "arrow.down.circle",
                        description: Text("Elige qué contenido llevar contigo en Descargar para llevar, mientras tu Mac está disponible."))
                }
                ForEach(available, id: \.path) { collection in
                    NavigationLink(value: DownloadedCollectionDestination.catalogue(collection.path)) {
                        Label(collection.label, systemImage: collection.icon).frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("downloaded-collection-\(collection.path)")
                }
                ForEach(privateKinds, id: \.self) { kind in
                    NavigationLink(value: DownloadedCollectionDestination.privateCatalogue(kind)) {
                        Label(privateTitle(kind), systemImage: kind == .recording ? "waveform" : "lock.doc").frame(minHeight: 44)
                    }
                }
            }
            .navigationTitle("Dossiers descargados")
            .navigationBarTitleDisplayMode(.inline)
            .nodusPageBackdrop(accent: session.accent)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() }.frame(minHeight: 44) } }
            .navigationDestination(for: DownloadedCollectionDestination.self) { destination in
                switch destination {
                case .catalogue(let path):
                    if let collection = Collections[path] {
                        DownloadedCollectionCatalogue(session: session, collection: collection, matching: matching,
                            open: { navigation.append(.dossier($0)) })
                    }
                case .dossier(let target):
                    DownloadedCollectionDossier(session: session, target: target, open: { navigation.append(.dossier($0)) })
                case .privateCatalogue(let kind):
                    PrivateSourceCatalogueView(session: session, kind: kind, title: privateTitle(kind), icon: kind == .recording ? "waveform" : "lock.doc", downloadedOnly: true)
                }
            }
            .task { await load() }
        }
        .accessibilityIdentifier("companion-downloaded-collections")
    }

    private func load() async {
        loading = true; issue = nil
        defer { loading = false }
        do {
            let (vault, pairing, _) = try privateBridgeConnection(session, domain: .corpus)
            guard !pairing.isExpired else { throw DesktopBridgeError.expired }
            let cache = try PrivateBridgeCache(pairingId: pairing.id)
            var found: [CollectionDescriptor] = []
            for collection in Collections.all where paths == nil || paths!.contains(collection.path) {
                try Task.checkCancellation()
                if try await cache.hasDownloadedData(vaultId: vault, domain: .corpus, recordId: CompanionCollectionCopy.recordId(path: collection.path)) {
                    found.append(collection)
                }
            }
            available = found
            var foundPrivate: [PrivateCorpusReference.Kind] = []
            if paths == nil {
                for kind in [PrivateCorpusReference.Kind.recording, .person, .source, .factoid, .mention, .participant, .interview, .testimonyTranscript, .contrast] where pairing.domains.contains(kind.domain) {
                    if !(try await CompanionPrivateSourceCopy.downloadedCatalogue(cache: cache, vaultId: vault, kind: kind)).isEmpty { foundPrivate.append(kind) }
                }
            }
            privateKinds = foundPrivate
        } catch where error.isCancellation { }
        catch { available = []; privateKinds = []; issue = error.localizedDescription }
    }
    private func privateTitle(_ kind: PrivateCorpusReference.Kind) -> String {
        switch kind {
        case .recording: "Grabaciones"; case .person: "Personas prosopográficas"; case .source: "Fuentes prosopográficas"
        case .factoid: "Observaciones prosopográficas"; case .mention: "Menciones prosopográficas"
        case .participant: "Participantes de testimonios"
        case .interview: "Entrevistas privadas"; case .testimonyTranscript: "Transcripciones privadas"; case .contrast: "Contrastes privados"
        }
    }
}

private struct DownloadedCollectionCatalogue: View {
    let session: SpaceSession
    let collection: CollectionDescriptor
    let matching: [String: JSONValue]
    let open: (DownloadedDossierTarget) -> Void
    @State private var rows: [Row] = []
    @State private var query = ""
    @State private var total = 0
    @State private var hasMore = false
    @State private var loading = true
    @State private var issue: String?
    @State private var revision: String?

    var body: some View {
        List {
            Section {
                Label("Contenido de este dispositivo", systemImage: "iphone")
                Text("\(total.formatted()) dossiers descargados").font(.caption).foregroundStyle(.secondary)
            }
            if let issue { Section { Text(issue).foregroundStyle(Color.nodusDanger); Button("Reintentar") { Task { await load(reset: true) } } } }
            ForEach(rows, id: \.columns) { row in
                if let id = row.string(collection.idField) {
                    Button { open(.init(collectionPath: collection.path, id: id)) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(collection.presenter.title(row)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                            if let subtitle = collection.presenter.subtitle(row) { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.accessibilityIdentifier("downloaded-dossier-\(collection.path)-\(id)")
                }
            }
            if loading { ProgressView("Leyendo dossiers…") }
            else if hasMore { Button("Mostrar más") { Task { await load(reset: false) } }.frame(minHeight: 44) }
            else if rows.isEmpty, issue == nil { Text(query.isEmpty ? "No hay dossiers de este tipo en tus descargas." : "No hay coincidencias en los dossiers descargados.").foregroundStyle(.secondary) }
        }
        .navigationTitle(Text(collection.label))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Buscar en las descargas")
        .nodusPageBackdrop(accent: session.accent)
        .task(id: query) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled else { return }
            await load(reset: true)
        }
        .refreshable { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        guard reset || !loading else { return }
        loading = true; issue = nil
        let requestedQuery = query, requestedOffset = reset ? 0 : rows.count
        defer { loading = false }
        do {
            let copy = try await downloadedCollection(session, path: collection.path)
            let page = copy.page(query: requestedQuery, matching: matching, limit: 80, offset: requestedOffset)
            try Task.checkCancellation()
            guard query == requestedQuery else { return }
            if !reset, revision != page.revision { await load(reset: true); return }
            rows = reset ? page.items : rows + page.items
            total = page.total; hasMore = page.hasMore; revision = page.revision
        } catch where error.isCancellation { }
        catch { rows = []; total = 0; hasMore = false; issue = error.localizedDescription }
    }
}

private struct DownloadedCollectionDossier: View {
    let session: SpaceSession
    let target: DownloadedDossierTarget
    let open: (DownloadedDossierTarget) -> Void
    @State private var dossier: CollectionDossier?
    @State private var issue: String?

    var body: some View {
        Group {
            if let dossier {
                if target.collectionPath == "databases" {
                    CompanionDownloadedDatabaseWorkspace(session:session,dossier:dossier)
                } else if target.collectionPath == "pages" {
                    SharedDesktopSurface(session:session,surface:.page,initialPageId:target.id,pageDownloadedOnly:true)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: NodusSpace.block) {
                            Label("Dossier descargado · lectura", systemImage: "arrow.down.circle")
                                .font(.caption).foregroundStyle(.secondary)
                            CollectionDossierBody(session: session, dossier: dossier, showConnectionState: false,
                                onOpenRelated: { collection, row in
                                    if let id = row.string(collection.idField) { open(.init(collectionPath: collection.path, id: id)) }
                                })
                            DossierOriginalResourcesView(session: session, dossier: dossier, downloadedOnly: true)
                        }.padding(NodusSpace.page).frame(maxWidth: 980).frame(maxWidth: .infinity)
                    }
                    .navigationTitle(Text(dossier.collection.presenter.title(dossier.primary)))
                }
            } else if let issue {
                VStack(alignment: .leading, spacing: 16) {
                    NodusNotice(tone: .caution, title: "Dossier no disponible", message: LocalizedStringKey(issue))
                    Button("Reintentar") { Task { await load() } }.frame(minHeight: 44)
                }.padding(NodusSpace.page)
            } else { ProgressView("Leyendo dossier…") }
        }
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .task(id: target) { await load() }
    }
    private func load() async {
        dossier = nil; issue = nil
        do {
            let copy = try await downloadedCollection(session, path: target.collectionPath)
            let value = try copy.dossier(id: target.id)
            try Task.checkCancellation(); dossier = value
        } catch where error.isCancellation { }
        catch { issue = error.localizedDescription }
    }
}

/// Specialised workspaces keep their complete live/editor surface. A selected
/// read copy opens in a separate native stack, never masquerading as a full snapshot.
struct CompanionCollectionAccess: ViewModifier {
    let session: SpaceSession
    let route: NodusRoute
    @State private var showing = false
    @State private var available = false

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if available {
                HStack {
                    Spacer()
                    Button { showing = true } label: { Label("Consultar descargas", systemImage: "arrow.down.circle") }
                        .font(.caption).frame(minHeight: 44)
                        .accessibilityIdentifier("workspace-downloads-\(route.rawValue)")
                }.padding(.horizontal, NodusSpace.page).background(.thinMaterial)
            }
        }
        .nodusSheet(isPresented: $showing) { CompanionDownloadedCollectionsView(session: session, paths: paths, matching: matching) }
        .task(id: session.companionDownloadRevision) { await refresh() }
    }

    private var matching: [String: JSONValue] {
        switch route {
        case .factions: ["kind": .string("faction")]
        case .cultures: ["kind": .string("culture")]
        case .dynasties: ["kind": .string("house")]
        case .conflicts: ["kind": .string("conflict")]
        case .arcs: ["kind": .string("arc")]
        default: [:]
        }
    }
    private var paths: [String] {
        switch route {
        case .encyclopedia: ["world-articles"]
        case .characters, .prosopPersons, .persons: ["persons"]
        case .places: ["places"]
        case .factions, .cultures, .dynasties: ["world-groups"]
        case .rules: ["world-rules"]
        case .conflicts, .arcs: ["world-threads"]
        case .questions: ["world-questions"]
        case .scenes, .manuscript: ["world-scenes"]
        case .continuity: ["world-questions", "world-rules", "world-secrets"]
        case .timeline: ["events", "world-scenes"]
        case .relations: ["relationships", "world-threads"]
        case .map: ["places", "world-maps"]
        case .tree: ["persons", "world-groups"]
        case .archive: ["archive-items", "archive-repositories", "archive-units", "archive-excerpts", "source-analyses"]
        case .prosopSearch: ["persons", "prosopography-public-population", "prosopography-public-variables", "prosopography-public-sources", "prosopography-public-analysis", "prosopography-public-networks"]
        case .prosopPopulation: ["prosopography-public-population", "prosopography-public-variables"]
        case .prosopSources: ["prosopography-public-sources"]
        case .prosopAnalysis: ["prosopography-public-analysis"]
        case .prosopNetworks: ["prosopography-public-networks"]
        case .testimonyInterviews: ["testimony-interviews", "testimony-transcripts", "testimony-codes"]
        case .testimonyContrasts: ["testimony-contrasts"]
        case .pages: ["database-pages"]
        case .databases, .dbSearch, .dbAnalysis: ["databases"]
        case .studyCourses: ["study-courses", "study-subjects", "study-topics"]
        case .studyLibrary: ["study-materials", "study-docs"]
        case .studySchedule, .studyCalendar: ["study-schedule", "study-plans", "study-goals"]
        case .studyQuestions: ["study-questions"]
        case .studyReview: ["study-flashcards"]
        case .teachingExams: ["teaching-exams", "study-questions"]
        case .teachingRubrics: ["teaching-rubrics"]
        case .teachingUnits: ["study-subjects", "study-docs", "study-plans"]
        default: []
        }
    }
    private func refresh() async {
        guard session.connection.desktopPairingId != nil, !paths.isEmpty else { available = false; return }
        do {
            let (vault, pairing, _) = try privateBridgeConnection(session, domain: .corpus)
            guard !pairing.isExpired else { available = false; return }
            let cache = try PrivateBridgeCache(pairingId: pairing.id)
            var found = false
            for path in paths {
                if try await cache.hasDownloadedData(vaultId: vault, domain: .corpus, recordId: CompanionCollectionCopy.recordId(path: path)) { found = true; break }
            }
            try Task.checkCancellation(); available = found
        } catch where error.isCancellation { }
        catch { available = false }
    }
}
