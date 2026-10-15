import NodusKit
import NodusUI
import SwiftUI
import QuickLook
import UIKit

struct SpaceSettingsView: View {
    @Environment(AppModel.self) private var model
    let session: SpaceSession

    @Environment(AISettings.self) private var ai
    @Environment(AppLock.self) private var lock
    @Environment(AppPreferences.self) private var preferences
    @Environment(CloudBackup.self) private var cloud
    @State private var health: ServerHealth?
    @State private var capabilities: ServerCapabilities?
    @State private var diagnosticFailure: ConnectionFailure?
    @State private var libraryDeletion: LibraryDeletion?
    @State private var showingLibraryDeletion = false
    @State private var liveSettings: JSONValue?
    @State private var liveSettingsError: String?
    @State private var changingMacConnection = false
    @State private var confirmingMacRevocation = false
    @State private var macConnectionResult: String?
    @State private var showingLegacyRecovery = false
    @State private var legacyRecoveryResult: String?
    @State private var showingCompanionDownload = false

    private enum LibraryDeletion: Equatable { case space, everySpace }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DesktopPageHeader(
                    title: "Settings",
                    subtitle: "Space, connection, privacy and device preferences",
                    systemImage: "gearshape",
                    accent: session.accent
                )
                .padding(.horizontal, NodusSpace.page)
                .padding(.top, NodusSpace.page)
                .padding(.bottom, 10)

                List {
                if session.connection.desktopPairingId != nil {
                    macConnectionSection
                    RecoveredAuthoringSettings(session: session)
                }

                Section("Space") {
                    labelled("Name", session.connection.spaceName)
                    labelled("Vault", session.connection.vaultName ?? "—")
                    labelled("Type", session.vaultType?.localizedName ?? "—")
                    labelled("Access", roleLabel)
                }

                if let legacy = ConnectionStorage.legacyData(for: session.connection) {
                    Section("Documentos de la copia anterior") {
                        Text("Se conservan \(legacy.reports) informes y \(legacy.chats) conversaciones sin una conexión identificada.")
                        Button("Recuperar documentos locales aquí") { showingLegacyRecovery = true }
                            .accessibilityIdentifier("recover-legacy-local-documents")
                        if let legacyRecoveryResult { Text(legacyRecoveryResult).font(.caption) }
                    }
                }

                Section {
                    Picker("Execution mode", selection: Binding(get: { session.aiExecutionMode }, set: { session.aiExecutionMode = $0 })) {
                        Text("Live · Mac models").tag(AIExecutionMode.live)
                            .disabled(session.connection.desktopPairingId == nil)
                        Text("Autonomous · this device").tag(AIExecutionMode.autonomous)
                    }
                    .accessibilityIdentifier("ai-execution-mode")
                    if session.connection.desktopPairingId != nil {
                        NavigationLink("Trabajos y resultados") { LiveJobsView(session: session) }
                            .accessibilityIdentifier("companion-jobs-results")
                    }
                    if session.aiExecutionMode == .live {
                        labelled("Mac", session.connection.serverName)
                        if let liveSettings {
                            ForEach(["chatModel", "deepResearchModel", "dictionaryModel", "immersionModel", "writingModel"], id: \.self) { key in
                                let choice = liveSettings.objectValue?[key]?.objectValue
                                labelled(macModelLabel(key), choice?["model"]?.stringValue ?? "—")
                            }
                        }
                        if let liveSettingsError { Text(liveSettingsError).foregroundStyle(Color.nodusDanger).accessibilityIdentifier("mac-live-settings-error") }
                    }
                } header: { Text("Execution mode") } footer: {
                    Text(session.aiExecutionMode == .live
                        ? "Requests run on the linked Mac using its providers and subscription sessions. Credentials stay on the Mac. Disconnection never switches to autonomous mode."
                        : "Requests use the providers configured on this device. The execution mode changes only when you choose it.")
                }


                Section {
                    labelled("This app", NodusVersion.current)
                    labelled("This server", serverVersion ?? "—")
                } header: {
                    Text("Version")
                }

                Section {
                    switch session.embedding {
                    case .published(let identity):
                        labelled("Provider", identity.provider)
                        labelled("Model", identity.model)
                        labelled("Dimensions", "\(identity.dim)")
                            .accessibilityIdentifier("mac-embedding-published")
                        if !session.embedding.isReachableFromPhone {
                            Text("This provider runs on the computer where Nodus desktop lives. iOS cannot produce a matching vector, so search is lexical.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    case .noVectors:
                        Text("This space has no published vectors.")
                            .accessibilityIdentifier("mac-embedding-no-vectors")
                            .font(.caption).foregroundStyle(.secondary)
                    case .unavailable(let message):
                        Text(message).font(.caption).foregroundStyle(Color.nodusCaution)
                            .accessibilityIdentifier("mac-embedding-error")
                    case .unknown:
                        ProgressView()
                    }
                } header: {
                    Text("Embeddings")
                } footer: {
                    Text("The vault fixes the model, not this app: retrieval only works when provider, model and dimension all match exactly.")
                }

                if session.aiExecutionMode == .autonomous { Section {
                    NavigationLink {
                        ProviderSettingsView(accent: session.accent, requiredEmbedding: requiredEmbedding, embedded: true)
                            .environment(ai)
                    } label: {
                        HStack {
                            Label("AI providers", systemImage: "key")
                            Spacer()
                            Text(ai.configuredProviders.isEmpty
                                 ? String(localized: "None configured")
                                 : "\(ai.configuredProviders.count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(AISettings.Task.allCases, id: \.self) { task in
                        NavigationLink {
                            ModelPickerView(task: task, accent: session.accent)
                                .environment(ai)
                        } label: {
                            HStack {
                                Text(LocalizedStringKey(task.label))
                                Spacer()
                                Text(ai.model(for: task)?.model ?? String(localized: "Not chosen"))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                        }
                    }
                } header: {
                    Text("Artificial intelligence")
                } footer: {
                    Text("Your keys stay in this device's keychain. The Nodus Server never receives one — it hands over the material, and this app calls your provider itself.")
                } }

                Section {
                    Toggle(isOn: Binding(
                        get: { lock.isEnabled },
                        // Turning it on authenticates first, so a sensor that does not work is
                        // discovered here rather than at the door.
                        set: { wanted in Task { await lock.enable(wanted) } }
                    )) {
                        Label(lock.biometry.label, systemImage: lock.biometry.systemImage)
                    }
                    .disabled(!lock.biometry.isAvailable)
                    .tint(session.accent)

                    if let failure = lock.failure {
                        Text(failure).font(.caption).foregroundStyle(Color.nodusDanger)
                    }

                    Toggle(isOn: Binding(
                        get: { preferences.showsScrollToTop },
                        set: { preferences.showsScrollToTop = $0 }
                    )) {
                        Label("Back-to-top button", systemImage: "chevron.up.circle")
                    }
                    .tint(session.accent)

                    NavigationLink {
                        SidebarSettingsView(vaultType: session.vaultType, accent: session.accent)
                    } label: {
                        Label("Sidebar", systemImage: "sidebar.left")
                    }
                } header: {
                    Text("This device")
                } footer: {
                    if lock.biometry.isAvailable {
                        Text("Nodus asks again every time it comes back to the screen. Your keys and any offline copy are already unreadable while the phone is locked; this covers a phone that is unlocked and not in your hands.")
                    } else {
                        Text("This device has no passcode set, so there is nothing to lock with.")
                    }
                }


                if let pairingId = session.connection.desktopPairingId {
                    CompanionCopySettings(session: session, pairingId: pairingId, showingDownload: $showingCompanionDownload)
                } else {
                Section {
                    switch session.mirrorProgress {
                    case .absent:
                        Button {
                            Task { await session.downloadMirror() }
                        } label: {
                            Label("Download for offline use", systemImage: "arrow.down.circle")
                        }
                    case .downloading:
                        Label("Downloading the publication…", systemImage: "arrow.down.circle")
                            .foregroundStyle(.secondary)
                    case .importing:
                        Label("Indexing…", systemImage: "gearshape.2")
                            .foregroundStyle(.secondary)
                    case .downloadingAssets(let done, let total):
                        ProgressView(value: Double(done), total: Double(max(1, total))) {
                            Text("Downloading images: \(done) of \(total)")
                        }
                    case .current(let rows, let tables):
                        labelled("Rows", rows.formatted())
                        labelled("Tables", "\(tables)")
                        if let summary = session.mirrorSummary {
                            labelled("Downloaded", summary.importedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        Button { Task { await session.downloadMirror() } } label: {
                            Label("Download again", systemImage: "arrow.clockwise")
                        }
                        Button(role: .destructive) { Task { await session.removeMirror() } } label: {
                            Label("Delete the copy", systemImage: "trash")
                        }
                    case .stale(let rows):
                        Label("The copy is out of date", systemImage: "exclamationmark.arrow.circlepath")
                            .foregroundStyle(Color.nodusCaution)
                        Text("It holds \(rows.formatted()) rows from an earlier publication.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button { Task { await session.downloadMirror() } } label: {
                            Label("Update", systemImage: "arrow.clockwise")
                        }
                    case .failed(let message):
                        Text(message).font(.caption).foregroundStyle(Color.nodusDanger)
                        Button { Task { await session.downloadMirror() } } label: {
                            Label("Try again", systemImage: "arrow.clockwise")
                        }
                    }
                } header: {
                    Text("Offline")
                } footer: {
                    // Not a nicety. The API has no sort parameter anywhere, and it projects
                    // twenty tables out of the dozens a publication can carry — a worldbuilding
                    // vault's scenes and articles have no route at all.
                    Text("Keeps the whole publication on the device: works with no network, sorts instantly, and reaches the tables the API does not expose.")
                }

                }

                Section {
                    Button(role: .destructive) {
                        requestLibraryDeletion(.space)
                    } label: {
                        Label("Delete downloaded library documents", systemImage: "books.vertical.fill")
                    }
                    Button(role: .destructive) {
                        requestLibraryDeletion(.everySpace)
                    } label: {
                        Label("Delete library documents from every space", systemImage: "trash.slash")
                    }
                } header: {
                    Text("Library downloads")
                } footer: {
                    Text("Only the copies stored on this device are removed. The catalogue, reading annotations and the server publication remain available.")
                }

                if let overview = session.overview, !overview.counts.isEmpty {
                    Section {
                        // A hundred table names is diagnostics, not settings. It stays
                        // reachable and stops swallowing the screen it lives on.
                        NavigationLink {
                            PublishedTablesView(counts: overview.counts, accent: session.accent)
                        } label: {
                            HStack {
                                Label("Published tables", systemImage: "tablecells")
                                Spacer()
                                Text("\(overview.counts.values.filter { $0 > 0 }.count)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        model.forget(session.connection)
                    } label: {
                        Label("Forget this space", systemImage: "trash")
                    }
                } footer: {
                    Text("The credential is deleted from this device. Nothing changes on the server.")
                }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .toolbar(.hidden, for: .navigationBar)
            .nodusPageBackdrop(accent: session.accent)
            .tint(session.accent)
            .task(id: session.connection.origin) {
                while !Task.isCancelled {
                    await diagnose()
                    guard !Task.isCancelled else { return }
                    await session.probeEmbedding(retryUnavailable: true)
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { return }
                }
            }
            .confirmationDialog("Delete downloaded copies?", isPresented: $showingLibraryDeletion, titleVisibility: .visible) {
                Button(libraryDeletion == .space ? "Delete in this space" : "Delete in every space", role: .destructive) {
                    confirmLibraryDeletion()
                }
                Button("Cancel", role: .cancel) { libraryDeletion = nil }
            } message: {
                Text("Only files stored on this device will be removed. Catalogues, annotations and server publications are preserved.")
            }
        }
        .accessibilityIdentifier("settings-workspace")
        .sheet(isPresented: $showingCompanionDownload) { CompanionDownloadsView(session: session) }
        .alert("Revoke Mac connection?", isPresented: $confirmingMacRevocation) {
            Button("Revoke Mac connection", role: .destructive) {
                changingMacConnection = true; macConnectionResult = nil
                Task {
                    defer { changingMacConnection = false }
                    do { try await model.revokeDesktop(session.connection) }
                    catch { macConnectionResult = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This device will lose access to every vault linked through this connection. Downloaded reading copies will be deleted. Your local drafts and generated work will stay encrypted. You can recover them through a verified link to the same Mac, or export them from settings.")
        }
        .confirmationDialog("Recuperar en \(session.connection.spaceName)", isPresented: $showingLegacyRecovery, titleVisibility: .visible) {
            Button("Recuperar documentos locales") {
                do {
                    let count = try ConnectionStorage.recoverLocalDocuments(for: session.connection)
                    legacyRecoveryResult = "Se han recuperado \(count) documentos nuevos. Las copias originales se conservan."
                } catch { legacyRecoveryResult = error.localizedDescription }
            }
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text("Confirma que estos documentos son tuyos y corresponden a esta conexión. Los informes y conversaciones se copiarán como documentos locales; revisa sus fuentes antes de enviarlos. Las copias descargadas y los envíos anteriores se conservarán aparte.")
        }
    }

    private var macConnectionSection: some View {
        Section {
            labelled("Mac", session.connection.serverName)
            if let id = session.connection.desktopPairingId,
               let pairing = DesktopBridgePairingStore().pairings().first(where: { $0.id == id }) {
                Text("\(pairing.vaultIds.count) linked vaults")
                DisclosureGroup("Workspace details") {
                    ForEach(model.connections.filter { $0.desktopPairingId == id }) { connection in
                        Text(connection.vaultName ?? connection.spaceName)
                    }
                    Text("Permissions").font(.subheadline.weight(.medium))
                    ForEach(pairing.domains.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { domain in
                        Text(macPermissionLabel(domain)).font(.caption)
                    }
                }
                .accessibilityIdentifier("mac-workspace-details")
            }
            Button {
                changingMacConnection = true; macConnectionResult = nil
                Task {
                    defer { changingMacConnection = false }
                    do { try await model.renewDesktop(session.connection); macConnectionResult = String(localized: "Connection renewed. Copies, drafts and requests are preserved.") }
                    catch { macConnectionResult = error.localizedDescription }
                }
            } label: { Label("Renew Mac connection", systemImage: "arrow.clockwise") }
                .disabled(changingMacConnection).accessibilityIdentifier("renew-mac-connection")
            Button(role: .destructive) {
                confirmingMacRevocation = true
            } label: { Label("Revoke Mac connection", systemImage: "link") }
                .disabled(changingMacConnection).accessibilityIdentifier("revoke-mac-connection")
            if changingMacConnection { ProgressView() }
            if let macConnectionResult { Text(macConnectionResult).font(.caption).accessibilityIdentifier("mac-connection-result") }
        } header: { Text("Linked Mac connection") } footer: {
            Text("Renewal keeps the same vaults and permissions. Revocation requires a connection to the Mac and affects all its linked vaults.")
        }
    }

    private var serverConnectionRows: some View {
        Group {
            labelled("Server", session.connection.serverName)
            labelled("Address", session.connection.origin)
            if let health {
                labelled("Status", health.ok ? "Online · v\(health.version ?? "?")" : "No answer")
            }
            if let capabilities {
                labelled("Largest image", ByteCountFormatter.string(fromByteCount: Int64(capabilities.maxAssetBytes), countStyle: .file))
                labelled("Change batch", "\(capabilities.maxMutationBatch)")
                if let maxMutationBytes = capabilities.maxMutationBytes {
                    labelled("Largest change", ByteCountFormatter.string(fromByteCount: Int64(maxMutationBytes), countStyle: .file))
                }
            }
            if let diagnosticFailure {
                Text(LocalizedStringKey(diagnosticFailure.sentence))
                    .font(.caption)
                    .foregroundStyle(diagnosticFailure.tone == .caution ? Color.nodusCaution : Color.nodusDanger)
            }
        }
    }

    private var connectionDiagnosticsLink: some View {
        NavigationLink {
            ConnectionDiagnosticsView(connection: session.connection).environment(model)
        } label: {
            Label("Diagnostics", systemImage: "stethoscope")
        }
    }

    @ViewBuilder private var workspaceProtocolRows: some View {
        if let revision = session.overview?.space.revision {
            labelled("Revision", String(revision.prefix(12)))
        }
        if let schema = session.overview?.schemaVersion {
            labelled("Schema", "v\(schema)")
        }
    }

    @ViewBuilder private var insecureConnectionFooter: some View {
        if ServerAddress(trusted: session.connection.origin).isInsecure {
            Text("This connection is not encrypted. That should only ever be a local test.")
                .foregroundStyle(Color.nodusCaution)
        }
    }

    private func macModelLabel(_ key: String) -> LocalizedStringKey {
        switch key {
        case "chatModel": "Chat"
        case "deepResearchModel": "Deep Research"
        case "dictionaryModel": "Dictionary"
        case "immersionModel": "Immersion"
        case "writingModel": "Writing"
        default: "Model"
        }
    }

    private func macPermissionLabel(_ domain: DesktopBridgeDomain) -> String {
        switch domain {
        case .corpus: String(localized: "Corpus consultation")
        case .writing: String(localized: "Writing and ideas")
        case .researchGeneration: String(localized: "Research generation")
        case .testimonies: String(localized: "Interviews and participants")
        case .teachingRoster: String(localized: "Students")
        case .teachingGrades: String(localized: "Grades")
        case .studyRecordings: String(localized: "Recordings")
        case .primarySourceFiles: String(localized: "Primary source files")
        case .prosopographyPrivate: String(localized: "Private prosopography data")
        }
    }

    private func requestLibraryDeletion(_ deletion: LibraryDeletion) {
        libraryDeletion = deletion
        showingLibraryDeletion = true
    }

    private func confirmLibraryDeletion() {
        switch libraryDeletion {
        case .space:
            Task {
                let library = PublishedLibraryStore(spaceId: session.connection.spaceId, storageId: session.connection.storageId)
                await library.removeAll()
            }
        case .everySpace:
            try? PublishedLibraryStore.removeAllSpaces()
        case nil:
            break
        }
        libraryDeletion = nil
    }

    /// What the server says it is running. `capabilities` is the authority — `/healthz` is a
    /// liveness probe and an older server answers it without a version at all.
    private var serverVersion: String? {
        capabilities?.server.version ?? capabilities?.version ?? health?.version
    }

    private var requiredEmbedding: EmbeddingIdentity? {
        if case .published(let identity) = session.embedding { return identity }
        return nil
    }

    /// `String(localized:)`: this is the *value* half of a settings row, so it is rendered as
    /// data — but unlike a model name or a revision hash it is a word this app chose, and a
    /// word this app chose is a word it should translate.
    private var roleLabel: String {
        switch session.connection.role {
        case .reader: return String(localized: "Read only")
        case .writer: return String(localized: "Can send changes")
        case .owner: return String(localized: "Owner")
        }
    }

    /// The row label is a `LocalizedStringKey`; the value is not.
    ///
    /// Taking a `String` for the label was enough to leave this whole screen in English on a
    /// Spanish phone: `Text(aString)` renders the string, and only `Text("a literal")` — or a
    /// `LocalizedStringKey` — is looked up. The value stays a `String` on purpose: it is data
    /// from the server, and translating a model name or a revision hash would be a lie.
    private func labelled(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(Color.nodusSecondaryText).multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    /// The two public calls this screen shows numbers from.
    ///
    /// The full ordered run lives one tap away, on its own screen: this one is settings, and it
    /// needs the ceilings and the version, not a verdict. What it does share is the wording —
    /// when the two calls fail, the sentence comes from the same classifier.
    private func diagnose() async {
        let origin = session.connection.origin
        if let pairing = DesktopBridgePairingStore().pairings().first(where: { $0.id == session.connection.desktopPairingId }),
           let token = DesktopBridgePairingStore().credential(for: pairing), let vault = session.vaultId {
            do {
                let settings = try await DesktopBridgeClient(pairing: pairing, token: token).operation(vaultId: vault, method: "getSettings", args: [])
                guard !Task.isCancelled, session.connection.origin == origin else { return }
                liveSettings = settings
                liveSettingsError = nil
            } catch {
                guard !Task.isCancelled, !error.isCancellation, session.connection.origin == origin else { return }
                liveSettingsError = error.localizedDescription
            }
            return
        }
        do {
            async let health = session.client.health()
            async let capabilities = session.client.capabilities()
            let values = try await (health, capabilities)
            guard !Task.isCancelled, session.connection.origin == origin else { return }
            self.health = values.0
            self.capabilities = values.1
            diagnosticFailure = nil
        } catch {
            guard !Task.isCancelled, !error.isCancellation, session.connection.origin == origin else { return }
            let network = await NetworkReachability.current()
            guard !Task.isCancelled, session.connection.origin == origin else { return }
            diagnosticFailure = ConnectionFailure.classify(
                error: error,
                origin: origin,
                network: network,
                knock: .unauthenticated,
                appVersion: NodusVersion.current
            )
        }
    }

}

/// Desktop-compatible navigation customisation. Hidden destinations remain available through
/// Commands and deep links; this only controls the rows rendered in the shared sidebar/drawer.
private struct SidebarSettingsView: View {
    @Environment(AppPreferences.self) private var preferences
    let vaultType: VaultType?
    let accent: Color

    private var effectiveHidden: Set<String> {
        preferences.sidebarCustomized
            ? preferences.sidebarHidden
            : NodusNavigationContract.defaultHiddenRoutes(for: vaultType)
    }

    private var ordered: [NodusNavigationItem] {
        NodusNavigationContract.visibleItems(
            for: vaultType,
            order: preferences.sidebarOrder,
            hidden: Set<String>()
        ).filter { $0.group != nil && $0.route != .library }
    }

    private var groups: [(NodusNavigationGroup, [NodusNavigationItem])] {
        NodusNavigationGroup.allCases.compactMap { group in
            let rows = ordered.filter { $0.group == group }
            return rows.isEmpty ? nil : (group, rows)
        }
    }

    var body: some View {
        List {
            ForEach(groups, id: \.0.id) { group, rows in
                Section(group.title) {
                    ForEach(rows) { row in
                        Toggle(isOn: Binding(
                            get: { !effectiveHidden.contains(row.route.rawValue) },
                            set: { set(row.route, shown: $0) }
                        )) {
                            Label(row.label, systemImage: row.systemImage)
                        }
                        .tint(accent)
                    }
                    .onMove { offsets, destination in move(group: group, offsets: offsets, destination: destination) }
                }
            }

            Section {
                Button("Restore Desktop defaults", systemImage: "arrow.counterclockwise") {
                    preferences.sidebarWidth = 176
                    preferences.sidebarOrder = []
                    preferences.sidebarHidden = []
                    preferences.sidebarCustomized = false
                }
            } footer: {
                Text("Home and Library stay pinned. A hidden section is still available from Commands and deep links.")
            }
        }
        .navigationTitle("Sidebar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .scrollContentBackground(.hidden)
        .nodusPageBackdrop(accent: accent)
    }

    private func set(_ route: NodusRoute, shown: Bool) {
        var hidden = effectiveHidden
        if shown { hidden.remove(route.rawValue) } else { hidden.insert(route.rawValue) }
        preferences.sidebarHidden = hidden
        preferences.sidebarCustomized = true
    }

    private func move(group: NodusNavigationGroup, offsets: IndexSet, destination: Int) {
        var groupOrder = ordered.filter { $0.group == group }.map { $0.route.rawValue }
        groupOrder.move(fromOffsets: offsets, toOffset: destination)
        let members = Set(groupOrder)
        var replacement = groupOrder.makeIterator()
        var all = ordered.map { $0.route.rawValue }
        for index in all.indices where members.contains(all[index]) {
            if let next = replacement.next() { all[index] = next }
        }
        preferences.sidebarOrder = all
        preferences.sidebarCustomized = true
    }
}


/// The published-table census, on its own screen.
struct PublishedTablesView: View {
    let counts: [String: Int]
    let accent: Color

    @State private var query = ""

    private var rows: [(table: String, count: Int)] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return counts
            .filter { needle.isEmpty || $0.key.lowercased().contains(needle) }
            .map { (table: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.table < $1.table : $0.count > $1.count }
    }

    var body: some View {
        List {
            Section {
                ForEach(rows, id: \.table) { row in
                    HStack {
                        Text(row.table)
                            .font(.caption.monospaced())
                            .foregroundStyle(row.count > 0 ? .primary : .secondary)
                        Spacer()
                        Text(row.count.formatted())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(row.count > 0 ? accent : Color.secondary)
                    }
                }
            } footer: {
                Text("A table with no rows was published empty. A table that is absent was never published at all — and the endpoint for it answers an empty page rather than an error.")
            }
        }
        .navigationTitle("Published tables")
        .scrollContentBackground(.hidden)
        .nodusPageBackdrop(accent: accent)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: Text("Filter tables"))
        .nodusDismissesKeyboard()
    }
}

/// A linked workspace retains opened content rather than downloading a complete
/// publication. This control never removes drafts or authorised pending work.
private struct CompanionCopySettings: View {
    let session: SpaceSession
    let pairingId: String
    @State private var usage: PrivateBridgeCache.Usage?
    @State private var issue: String?
    @State private var clearing = false
    @State private var confirmClear = false
    @Binding var showingDownload: Bool
    @State private var packs: [PrivateBridgeCache.ReadPack] = []
    @State private var preview: URL?
    @State private var previewCopy: PrivateBridgeFileCopy?
    @State private var openingFile = false
    var body: some View {
        Section {
            if let usage {
                LabeledContent("Consulted content", value: ByteCountFormatter.string(fromByteCount: Int64(usage.reusableBytes), countStyle: .file))
                LabeledContent("Downloaded content", value: ByteCountFormatter.string(fromByteCount: Int64(usage.downloadedBytes), countStyle: .file))
                LabeledContent("Maximum for this Mac", value: ByteCountFormatter.string(fromByteCount: Int64(usage.readLimitBytes), countStyle: .file))
                LabeledContent("Drafts and pending work", value: ByteCountFormatter.string(fromByteCount: Int64(usage.protectedBytes), countStyle: .file))
                Button("Descargar para llevar") { showingDownload = true }
                    .accessibilityIdentifier("companion-download-select")
                ForEach(packs) { pack in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(pack.title)
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(pack.bytes), countStyle: .file)) · caduca \(pack.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                        if let file = pack.primaryFile {
                            Button("Abrir archivo descargado") {
                                openingFile = true
                                Task {
                                    defer { openingFile = false }
                                    do {
                                        let copy = try await loadPrivateBridgeFile(session, kind: file.kind, id: file.id, downloadedOnly: true, selectedFile: file)
                                        previewCopy = copy; preview = copy.url
                                    }
                                    catch { issue = error.localizedDescription }
                                }
                            }.disabled(openingFile)
                                .accessibilityIdentifier("companion-download-open-\(pack.id)")
                        }
                        Button("Eliminar copia descargada", role: .destructive) {
                            Task {
                                do {
                                    try await PrivateBridgeCache(pairingId: pairingId).removeReadPack(id: pack.id, vaultId: pack.vaultId)
                                    session.didChangeCompanionDownloads()
                                    await refresh()
                                }
                                catch { issue = error.localizedDescription }
                            }
                        }.accessibilityIdentifier("companion-download-remove-\(pack.id)")
                    }
                }
                Button("Free space used by consulted content", role: .destructive) { confirmClear = true }
                    .disabled(clearing)
                    .accessibilityIdentifier("companion-clear-read-copies")
            } else { ProgressView() }
            if let issue { Text(issue).font(.caption).foregroundStyle(Color.nodusDanger) }
        } header: { Text("On this device") } footer: {
            Text("Opened content is kept encrypted for offline reading. Older consulted copies are removed when the limit is reached. Drafts and pending work are always preserved.")
        }
        .task { await refresh() }
        .quickLookPreview($preview)
        .onChange(of: preview) { _, value in if value == nil { previewCopy = nil } }
        .onChange(of: showingDownload) { _, shown in if !shown { Task { await refresh() } } }
        .confirmationDialog("Free space used by consulted content?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Free space", role: .destructive) {
                clearing = true
                Task {
                    defer { clearing = false }
                    do { try await PrivateBridgeCache(pairingId: pairingId).removeReusableCopies(); await refresh() }
                    catch { issue = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Drafts and pending work remain on this device. Open the consulted content again while connected to keep another copy.") }
    }
    private func refresh() async {
        do {
            let cache = try PrivateBridgeCache(pairingId: pairingId)
            usage = try await cache.usage()
            packs = try await cache.readPacks(vaultId: session.vaultId ?? "")
            issue = nil
        }
        catch { issue = error.localizedDescription }
    }
}


private struct RecoveredAuthoringSettings: View {
    let session: SpaceSession
    @State private var archives: [PrivateBridgeAuthoringRecovery.ArchiveInfo] = []
    @State private var requests: [DesktopJobLedger.Request] = []
    @State private var issue: String?
    @State private var reviewing: String?
    @State private var selected: DesktopJobLedger.Request?
    var body: some View {
        Group {
            if !archives.isEmpty || !requests.isEmpty || session.connection.authoringRecoveryNotice != nil {
                Section {
                    if let notice = session.connection.authoringRecoveryNotice { Text(notice).font(.footnote) }
                    ForEach(requests) { request in
                        Button { selected = request } label: { Label(CompanionResultCatalogue.title(request), systemImage: "doc.text") }
                            .frame(minHeight: 44).accessibilityIdentifier("recovered-work-review")
                    }
                    ForEach(archives) { archive in RecoveredAuthoringArchiveRow(archive: archive) }
                    if let issue { Text(issue).font(.caption).foregroundStyle(Color.nodusDanger) }
                } header: { Text("Trabajo local conservado") } footer: {
                    Text("Los cambios de un enlace anterior necesitan revisión. Publicar un resultado ya creado no vuelve a ejecutar el modelo.")
                }
            }
        }
        .task { await refresh() }
        .nodusSheet(item: $selected) { request in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(CompanionResultCatalogue.title(request)).font(.title2.bold())
                        Text("Revisa el resultado antes de guardarlo en el Mac. Los cambios del origen se comprobarán al enviarlo.").font(.footnote).foregroundStyle(.secondary)
                        if let text = resultText(request) { CorpusProse(text, accent: session.accent, session: session) }
                        if let encoded = request.checkpoint?.objectValue?["bytes"]?.stringValue, let data = Data(base64Encoded: encoded), let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                                .accessibilityIdentifier("recovered-work-image")
                        }
                        if let result = request.result { DossierValueView(session: session, value: result, field: "", linkedCollection: nil, onOpenRelated: nil) }
                        if PrivateBridgeAuthoringRecovery.canReviewResult(request) {
                            Button("Guardar este resultado en el Mac") { Task { await approve(request) } }
                                .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent)).disabled(reviewing != nil)
                                .accessibilityIdentifier("recovered-work-publish")
                        } else { Text("El resultado se conserva para consulta. No se repetirá la generación automáticamente.").font(.footnote) }
                        if let issue { Text(issue).foregroundStyle(Color.nodusDanger) }
                    }.padding(NodusSpace.page)
                }
                .navigationTitle("Revisar trabajo")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selected = nil } } }
            }
        }
    }
    private func refresh() async {
        guard let pairing = session.connection.desktopPairingId else { return }
        do {
            archives = try await PrivateBridgeAuthoringRecovery.shared.summaries(macDeviceId: session.connection.macDeviceId, pairingId: pairing)
            if let vault = session.vaultId { requests = try await DesktopJobLedgers.shared.ledger(pairingId: pairing, vaultId: vault).all().filter { $0.state == "recoveryReview" } }
        } catch { issue = error.localizedDescription }
    }
    private func approve(_ original: DesktopJobLedger.Request) async {
        guard let pairing = session.connection.desktopPairingId, let vault = session.vaultId else { return }
        reviewing = original.id; issue = nil
        defer { reviewing = nil }
        do {
            let bridge = try ConnectionClient.companionChat(for: session.connection)
            let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing, vaultId: vault)
            let approved: DesktopJobLedger.Request
            if let publication = try PrivateBridgeAuthoringRecovery.publicationForReview(original) { approved = try await ledger.approveRecoveredPublication(publication) }
            else { approved = try await ledger.approveRecoveredSavedResult(id: original.id) }
            do {
                let job = try await bridge.submitJob(vaultId: vault, method: approved.method, args: approved.args, idempotencyKey: approved.id)
                try await ledger.update(id: approved.id, job: job)
                selected = nil; await refresh()
            } catch {
                if let api = error as? APIError, [400,403,404,409,422].contains(api.status) { try await ledger.rejectUnsubmitted(id: approved.id, issue: api.localizedDescription) }
                else { try await ledger.disconnected(id: approved.id, issue: error.localizedDescription) }
                throw error
            }
        } catch { issue = error.localizedDescription }
    }
    private func resultText(_ request: DesktopJobLedger.Request) -> String? {
        let row = request.checkpoint?.objectValue ?? [:], preview = row["preview"]?.objectValue ?? [:]
        let candidates = [preview["draftMarkdown"], preview["text"], row["markdown"], row["definition"]?.objectValue?["contentMarkdown"], row["detail"]?.objectValue?["report"]?.objectValue?["markdown"], row["raw"]]
        return candidates.compactMap { $0?.stringValue }.first { !$0.isEmpty }
    }
}
struct RecoveredAuthoringArchiveRow: View {
    let archive: PrivateBridgeAuthoringRecovery.ArchiveInfo
    @State private var lease: PrivateBridgeFileLease?
    @State private var issue: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(archive.createdAt, format: .dateTime.day().month().year())
            Text("El archivo original permanece cifrado y puede exportarse.").font(.caption).foregroundStyle(.secondary)
            if !archive.macIdentityKnown { Text("El trabajo se conserva sin incorporarlo automáticamente a otro espacio.").font(.caption) }
            Button {
                Task {
                    do { lease = try PrivateBridgeFileLease.write(try await PrivateBridgeAuthoringRecovery.shared.export(id: archive.id), filename: "Nodus-local-work.json") }
                    catch { issue = error.localizedDescription }
                }
            } label: {
                Text("Exportar trabajo conservado")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }.accessibilityIdentifier("recovered-work-export")
            if let issue { Text(issue).font(.caption).foregroundStyle(Color.nodusDanger) }
        }
        .sheet(isPresented: Binding(get: { lease != nil }, set: { if !$0 { lease = nil } })) {
            if let lease { RecoveredAuthoringShare(lease: lease) }
        }
    }
}

private struct RecoveredAuthoringShare: UIViewControllerRepresentable {
    let lease: PrivateBridgeFileLease
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [lease.url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
