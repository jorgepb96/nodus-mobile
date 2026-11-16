import NodusKit
import NodusUI
import SwiftUI

private struct PrivateSourceReaderTarget: Identifiable {
    let reference: PrivateCorpusReference
    var id: String { reference.recordKey }
}

/// Private catalogues request one metadata page. Transcripts and audio are
/// addressed only after the user chooses a source; offline lists are selections.
struct PrivateSourceCatalogueView: View {
    let session: SpaceSession
    let kind: PrivateCorpusReference.Kind
    let title: String
    let icon: String
    var downloadedOnly = false
    @State private var items: [PrivateCorpusSource.CatalogueItem] = []
    @State private var query = ""
    @State private var state = "active"
    @State private var loading = true
    @State private var loadingMore = false
    @State private var total = 0
    @State private var hasMore = false
    @State private var revision: String?
    @State private var offline = false
    @State private var issue: String?
    @State private var selected: PrivateSourceReaderTarget?
    @State private var retry = 0
    private var loadKey: String { "\(query):\(state):\(session.contentEpoch):\(session.companionDownloadRevision):\(retry)" }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                DesktopPageHeader(title: LocalizedStringKey(title), subtitle: "Fuentes privadas del workspace vinculado", systemImage: icon, accent: session.accent)
                TextField("Buscar", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder).frame(minHeight: 44)
                if kind == .recording || kind == .interview {
                    Picker("Estado", selection: $state) {
                        Text("Activas").tag("active"); Text("Archivadas").tag("archived")
                        Text("Papelera").tag("trash"); Text("Todas").tag("all")
                    }.pickerStyle(.menu).frame(minHeight: 44)
                }
                if offline { Label("Descargadas en este dispositivo", systemImage: "wifi.slash").font(.caption).foregroundStyle(.secondary) }
                if loading { ProgressView("Cargando catálogo…").frame(maxWidth: .infinity, minHeight: 80) }
                if let issue { CorpusOpenFailure(message: issue) { retry += 1 } }
                if !loading, issue == nil {
                    if items.isEmpty {
                        ContentUnavailableView("No hay fuentes para esta selección", systemImage: icon,
                            description: Text(offline ? "Las fuentes elegidas para llevar aparecen aquí. Conserva una fuente desde su lector mientras el Mac está disponible." : "Prueba con otro filtro o una búsqueda diferente."))
                    } else {
                        Text("\(items.count) de \(total)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(items) { item in
                    Button {
                        do { selected = .init(reference: try PrivateCorpusReference(kind: kind, id: item.id)) }
                        catch { issue = error.localizedDescription }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: icon).foregroundStyle(session.accent)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title).font(.headline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                if let date = Row(["date": .string(item.updatedAt)]).date("date") { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.frame(minHeight: 44).desktopContentRow(accent: session.accent)
                    }.buttonStyle(NodusCardButtonStyle()).accessibilityIdentifier("private-source-\(kind.rawValue)-\(item.id)")
                }
                if hasMore {
                    Button { Task { await loadMore() } } label: {
                        if loadingMore { ProgressView() } else { Label("Cargar más", systemImage: "chevron.down") }
                    }.disabled(loadingMore || loading).frame(minHeight: 44)
                }
            }.padding(NodusSpace.page).frame(maxWidth: 900).frame(maxWidth: .infinity).nodusTopAnchor()
        }
        .nodusPageBackdrop(accent: session.accent)
        .task(id: loadKey) {
            do { try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation(); await load() }
            catch is CancellationError { }
            catch { issue = error.localizedDescription }
        }
        .nodusSheet(item: $selected) { target in
            PrivateCorpusSourceSheet(session: session, reference: target.reference, downloadedOnly: downloadedOnly)
        }
        .accessibilityIdentifier("private-source-catalogue-\(kind.rawValue)")
    }

    @MainActor private func load() async {
        loading = true; issue = nil; items = []; hasMore = false; revision = nil
        defer { loading = false }
        do {
#if DEBUG
            if session.connection.desktopPairingId == nil, !downloadedOnly, kind == .recording {
                let fixtures = try debugPrivateRecordingCopies()
                if !fixtures.isEmpty {
                    items = fixtures.map { CompanionPrivateSourceCopy.CatalogueEntry(source: $0.source).item }
                        .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
                    total = items.count; offline = false
                    return
                }
            }
#endif
            let (vault, pairing, token) = try privateBridgeConnection(session, domain: kind.domain)
            guard !pairing.isExpired else { throw DesktopBridgeError.expired }
            if downloadedOnly { try await loadDownloaded(vault: vault, pairing: pairing); return }
            do {
                let page = try await DesktopBridgeClient(pairing: pairing, token: token)
                    .privateSourceCatalogue(vaultId: vault, kind: kind, query: query, state: state)
                try Task.checkCancellation()
                items = page.items; total = page.total; hasMore = page.hasMore; revision = page.revision; offline = false
            } catch {
                guard isPrivateBridgeOffline(error) else { throw error }
                try await loadDownloaded(vault: vault, pairing: pairing)
            }
        } catch is CancellationError { }
        catch { items = []; issue = error.localizedDescription }
    }

    @MainActor private func loadDownloaded(vault: String, pairing: DesktopBridgePairing) async throws {
        let cache = try PrivateBridgeCache(pairingId: pairing.id)
        let downloaded = try await CompanionPrivateSourceCopy.downloadedCatalogue(cache: cache, vaultId: vault, kind: kind)
        let search = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).trimmingCharacters(in: .whitespacesAndNewlines)
        var matches: [PrivateCorpusSource.CatalogueItem] = []
        for item in downloaded {
            if [.recording, .interview].contains(kind), state != "all", (item.state ?? "active") != state { continue }
            if !search.isEmpty {
                let target = try PrivateCorpusReference(kind: kind, id: item.id)
                guard let copy = try await CompanionPrivateSourceCopy.downloaded(cache: cache, vaultId: vault, reference: target) else { throw DesktopBridgeError.malformedResponse }
                let texts = [item.title, item.detail] + copy.source.root.columns.values.compactMap(\.stringValue)
                    + copy.rows.values.flatMap { $0.flatMap { $0.columns.values.compactMap(\.stringValue) } }
                guard texts.contains(where: { $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(search) }) else { continue }
            }
            matches.append(item)
        }
        try Task.checkCancellation()
        items = matches.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        total = items.count; offline = true
    }

    @MainActor private func loadMore() async {
        guard hasMore, !loadingMore, !offline else { return }
        loadingMore = true; issue = nil
        let queryBefore = query, stateBefore = state, revisionBefore = revision, idsBefore = items.map(\.id)
        defer { loadingMore = false }
        do {
            let (vault, pairing, token) = try privateBridgeConnection(session, domain: kind.domain)
            let page = try await DesktopBridgeClient(pairing: pairing, token: token)
                .privateSourceCatalogue(vaultId: vault, kind: kind, offset: idsBefore.count, query: queryBefore, state: stateBefore)
            guard queryBefore == query, stateBefore == state, idsBefore == items.map(\.id) else { return }
            guard page.revision == revisionBefore, page.total == total,
                  Set(idsBefore).isDisjoint(with: Set(page.items.map(\.id))) else { throw PrivateCorpusSourceError.changed }
            items += page.items; hasMore = page.hasMore
        } catch is CancellationError { }
        catch { items = []; hasMore = false; issue = error.localizedDescription }
    }
}
