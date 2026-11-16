import CryptoKit
import NodusAI
import NodusKit
import NodusUI
import SwiftUI
import UIKit

private struct WorkshopDraftSummary: Identifiable {
    let id: String
    let title: String
    let kind: String
    let objective: String
    let abstract: String
    let updatedAt: String?
    init(row: Row) throws {
        guard let id = row.string("id"), !id.isEmpty, let title = row.string("title"),
              let kind = row.string("kind"), kind != "deep_research",
              let objective = row.string("objective"), let abstract = row.string("abstractSnippet")
        else { throw DesktopBridgeError.malformedResponse }
        self.id = id; self.title = title; self.kind = kind; self.objective = objective
        self.abstract = abstract; updatedAt = row.string("updatedAt")
    }
    init(legacy: AcademicWritingDraftSummary) {
        id = legacy.id; title = legacy.title; kind = legacy.kind; objective = legacy.objective
        abstract = legacy.abstract; updatedAt = legacy.updatedAt
    }
    init(report: JSONValue) throws {
        guard let body = report.objectValue, let draft = body["draft"]?.objectValue,
              let brief = draft["brief"]?.objectValue, let kind = brief["kind"]?.stringValue,
              kind != "deep_research", let id = body["id"]?.stringValue, let title = body["title"]?.stringValue
        else { throw DesktopBridgeError.malformedResponse }
        self.id = id; self.title = title; self.kind = kind
        objective = brief["objective"]?.stringValue ?? ""; abstract = draft["abstract"]?.stringValue ?? ""
        updatedAt = body["updatedAt"]?.stringValue
    }
}

struct WritingWorkshopMobileView: View {
    let session: SpaceSession
    @Environment(\.horizontalSizeClass) private var horizontalSize
    @State private var tables: [String: [Row]] = [:]
    @State private var drafts: [WorkshopDraftSummary] = []
    @State private var selected: WorkshopDraftSummary?
    @State private var reading: WorkshopDraftSummary?
    @State private var catalogue: Page<Row>?
    @State private var showingComposer = false
    @State private var loading = true
    @State private var message: String?
    @State private var error: String?
    @State private var usingDownloads = false
    @State private var query = ""
    @State private var kind = ""
    @State private var sort = "newest"
    private var compact: Bool { UIDevice.current.userInterfaceIdiom == .phone || horizontalSize == .compact }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                DesktopPageHeader(title: "Taller de escritura", subtitle: "Borradores con las fuentes que elijas",
                    systemImage: "square.and.pencil", accent: session.accent, trailing: {
                        Button { showingComposer = true } label: { Label("Nuevo borrador", systemImage: "plus") }
                            .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent))
                    })
                CompanionResultsButton(session: session, surface: .writingWorkshop, generationStatus: nil)
                TextField("Buscar borradores", text: $query).textFieldStyle(.roundedBorder)
                ViewThatFits(in: .horizontal) {
                    HStack { formatPicker; sortPicker }
                    VStack(alignment: .leading) { formatPicker; sortPicker }
                }
                if let error {
                    NodusNotice(tone: .blocked, title: "No se pudo consultar el taller", message: LocalizedStringKey(error))
                    Button("Reintentar") { Task { await load(reset: true) } }.frame(minHeight: 44)
                }
                if let message { NodusNotice(tone: .info, title: "Taller de escritura", message: LocalizedStringKey(message)) }
                if loading && drafts.isEmpty { ProgressView("Consultando borradores").frame(maxWidth: .infinity).padding(40) }
                else if drafts.isEmpty && error == nil {
                    ContentUnavailableView(usingDownloads ? "Sin borradores descargados" : "Sin borradores guardados", systemImage: "doc.text",
                        description: Text(usingDownloads ? "Elige borradores en Descargas mientras Nodus esté conectado. Los resultados creados en el móvil siguen disponibles arriba."
                            : "Elige tus fuentes y genera un borrador con Nodus o con el modelo del móvil."))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 9)], spacing: 9) {
                        ForEach(drafts) { draft in
                            Button { selected = draft; if compact { reading = draft } } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        NodusChip(key: draft.kind.replacingOccurrences(of: "_", with: " "), tint: session.accent)
                                        Spacer(minLength: 4)
                                        Image(systemName: selected?.id == draft.id ? "checkmark.circle.fill" : "doc.text").foregroundStyle(session.accent.nodusReadable)
                                    }
                                    Text(draft.title).font(.headline).lineLimit(2)
                                    Text(draft.abstract.isEmpty ? draft.objective : draft.abstract).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    if let date = draft.updatedAt { Text(date).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1) }
                                }.desktopContentRow(accent: selected?.id == draft.id ? session.accent : .secondary)
                            }.buttonStyle(NodusCardButtonStyle())
                        }
                    }
                    if catalogue?.hasMore == true {
                        Button("Cargar más borradores") { Task { await load(reset: false) } }.frame(minHeight: 44).disabled(loading)
                    }
                    if !compact, let selected { WritingDraftReader(summary: selected, session: session, legacyDocument: draftValue(selected.id)).id(selected.id) }
                }
            }.padding(NodusSpace.page).frame(maxWidth: 1120).frame(maxWidth: .infinity).nodusTopAnchor()
        }
        .nodusPageBackdrop(accent: session.accent)
        .accessibilityIdentifier("academic-writing")
        .task(id: "\(query):\(kind):\(sort):\(session.contentEpoch): \(session.companionPublicationRevision):\(session.companionDownloadRevision)") {
            if !query.isEmpty { do { try await Task.sleep(for: .milliseconds(250)) } catch { return } }
            await load(reset: true)
        }
        .sheet(item: $reading) { draft in
            NavigationStack {
                ScrollView { WritingDraftReader(summary: draft, session: session, legacyDocument: draftValue(draft.id)).padding(16) }
                    .navigationTitle("Borrador").navigationBarTitleDisplayMode(.inline)
                    .nodusModalClose(accent: session.accent)
            }.nodusTextHierarchy()
        }
        .nodusSheet(isPresented: $showingComposer) {
            NavigationStack {
                WritingComposer(session: session, tables: tables, usingDownloads: usingDownloads) { status in
                    message = status; showingComposer = false
                }
            }.nodusModalClose(accent: session.accent)
        }
    }
    private var formatPicker: some View {
        Picker("Formato", selection: $kind) {
            Text("Todos los formatos").tag("")
            Text("Estado de la cuestión").tag("literature_review"); Text("Marco teórico").tag("theoretical_framework")
            Text("Síntesis del debate").tag("debate"); Text("Justificación de un hueco").tag("gap_justification")
            Text("Sección de capítulo").tag("chapter_section"); Text("Pregunta de investigación").tag("research_question")
        }.pickerStyle(.menu).frame(minHeight: 44)
    }
    private var sortPicker: some View {
        Picker("Orden", selection: $sort) {
            Text("Más recientes").tag("newest"); Text("Más antiguos").tag("oldest"); Text("Título").tag("title")
        }.pickerStyle(.menu).frame(minHeight: 44)
    }
    private func draftValue(_ id: String) -> JSONValue? {
        tables["writing_saved_drafts"]?.first(where: { $0.string("id") == id })?.embeddedJSON("draft_json")
    }
    private func load(reset: Bool) async {
        loading = true; defer { loading = false }
        let currentQuery = query, currentKind = kind, currentSort = sort
        do {
            if session.connection.desktopPairingId != nil {
                let (vault, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
                let offset = reset ? 0 : drafts.count
                var input: [String: JSONValue] = ["offset": .int(Int64(offset)), "limit": .int(100), "query": .string(currentQuery), "sort": .string(currentSort)]
                if !currentKind.isEmpty { input["kind"] = .string(currentKind) }
                let value = try await DesktopBridgeClient(pairing: pairing, token: token).operation(vaultId: vault,
                    method: "getWritingWorkshopMobileDraftCatalogue", args: [.object(input)], timeout: 4)
                let page = try CompanionWorkshopSource.cataloguePage(value, idKey: "id", labelKey: "title")
                guard page.offset == offset, reset || catalogue?.revision == page.revision else {
                    catalogue = nil; drafts = []; throw DesktopBridgeError.malformedResponse
                }
                let items = try page.items.map(WorkshopDraftSummary.init(row:))
                try Task.checkCancellation()
                guard currentQuery == query, currentKind == kind, currentSort == sort else { return }
                drafts = (reset ? [] : drafts) + items; catalogue = page; tables = [:]
            } else {
                tables = try await session.client.snapshot(in: session.connection.spaceId).tables
                drafts = AcademicAuthoredProjection.writingDrafts(from: tables).map(WorkshopDraftSummary.init(legacy:))
                catalogue = nil
            }
            if let current = selected { selected = drafts.first(where: { $0.id == current.id }) ?? current }
            usingDownloads = false; error = nil; message = nil
        } catch where error.isCancellation { }
        catch {
            guard currentQuery == query, currentKind == kind, currentSort == sort else { return }
            guard isPrivateBridgeOffline(error), session.connection.desktopPairingId != nil else { self.error = error.localizedDescription; return }
            do {
                let (vault, pairing, _) = try privateBridgeConnection(session, domain: .corpus)
                guard !pairing.isExpired else { throw DesktopBridgeError.expired }
                let copy = try await CompanionResearchCorpusCopy.downloaded(cache: PrivateBridgeCache(pairingId: pairing.id), vaultId: vault)
                let reports = copy?.selectedReports.filter { $0.objectValue?["draft"]?.objectValue?["brief"]?.objectValue?["kind"]?.stringValue != nil
                    && $0.objectValue?["draft"]?.objectValue?["brief"]?.objectValue?["kind"] != .string("deep_research") } ?? []
                drafts = try reports.map(WorkshopDraftSummary.init(report:)).filter { (currentKind.isEmpty || $0.kind == currentKind)
                    && (currentQuery.isEmpty || "\($0.title) \($0.objective)".localizedStandardContains(currentQuery)) }
                if currentSort == "title" { drafts.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
                else { drafts.sort { currentSort == "oldest" ? ($0.updatedAt ?? "") < ($1.updatedAt ?? "") : ($0.updatedAt ?? "") > ($1.updatedAt ?? "") } }
                tables = [:]; catalogue = nil
                usingDownloads = true; self.error = nil
                message = "El Mac está desconectado. La galería muestra únicamente los borradores descargados; los resultados del móvil se conservan aparte."
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct WritingDraftReader: View {
    let summary: WorkshopDraftSummary
    let session: SpaceSession
    let legacyDocument: JSONValue?
    @State private var report: JSONValue?
    @State private var loading = true
    @State private var issue: String?
    @State private var downloaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if loading && report == nil { ProgressView("Abriendo borrador") }
            if let issue {
                NodusNotice(tone: .blocked, title: "No se pudo abrir el borrador", message: LocalizedStringKey(issue))
                Button("Reintentar") { Task { await load() } }.frame(minHeight: 44)
            }
            if let draft = report?.objectValue?["draft"], let value = draft.objectValue, let markdown = value["draftMarkdown"]?.stringValue {
                let title = report?.objectValue?["title"]?.stringValue ?? summary.title
                Text(title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if downloaded { Label("Copia descargada · Mac sin conexión", systemImage: "wifi.slash").font(.caption).foregroundStyle(.secondary) }
                if let abstract = value["abstract"]?.stringValue, !abstract.isEmpty { CorpusProse(abstract, accent: session.accent, session: session) }
                ReportCopyButtons(markdown: markdown, title: title, accent: session.accent)
                CorpusProse(markdown, accent: session.accent, session: session)
                WorkshopDraftSections(draft: draft, session: session)
            }
        }.frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        .task(id: "\(summary.id):\(session.contentEpoch): \(session.companionDownloadRevision)") { await load() }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do {
            let result: JSONValue
            if session.connection.desktopPairingId != nil {
                let (vault, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
                do {
                    result = try await DesktopBridgeClient(pairing: pairing, token: token).operation(vaultId: vault,
                        method: "getWritingWorkshopDraft", args: [.string(summary.id)], timeout: 4)
                    downloaded = false
                } catch {
                    guard isPrivateBridgeOffline(error), !pairing.isExpired else { throw error }
                    let copy = try await CompanionResearchCorpusCopy.downloaded(cache: PrivateBridgeCache(pairingId: pairing.id), vaultId: vault)
                    guard let local = copy?.selectedReports.first(where: { $0.objectValue?["id"] == .string(summary.id) }) else { throw CompanionWorkshopSource.SourceError.notDownloaded }
                    result = local; downloaded = true
                }
            } else if let legacyDocument { result = .object(["id": .string(summary.id), "title": .string(summary.title), "draft": legacyDocument]); downloaded = false }
            else { throw DesktopBridgeError.malformedResponse }
            guard result.objectValue?["id"] == .string(summary.id), result.objectValue?["draft"]?.objectValue?["draftMarkdown"]?.stringValue != nil else { throw DesktopBridgeError.malformedResponse }
            try Task.checkCancellation(); report = result; issue = nil
        } catch where error.isCancellation { }
        catch { report = nil; issue = error.localizedDescription }
    }
}

private struct WritingComposer: View {
    let session: SpaceSession
    let tables: [String: [Row]]
    let usingDownloads: Bool
    let onQueued: (String) -> Void
    @Environment(AISettings.self) private var ai
    @State private var title = ""
    @State private var objective = ""
    @State private var audience = ""
    @State private var kind = "literature_review"
    @State private var tone = "academic"
    @State private var language = "es"
    @State private var selections: [String: Set<String>] = [:]
    @State private var limits: [String: Int] = [:]
    @State private var query = ""
    @State private var sending = false
    @State private var status: String?
    @State private var error: String?
    @State private var downloadedSource: CompanionWorkshopSource?
    @State private var sourceRows: [String: [Row]] = [:]
    @State private var sourcePages: [String: Page<Row>] = [:]
    @State private var sourceOffline = false
    @State private var readingSources = false
    @State private var generationTask: Task<Void, Never>?
    @State private var completed: DesktopJobLedger.Request?
    @State private var savingSources = false
    @State private var sourceDownloadTask: Task<Void, Never>?
    private var autonomous: Bool { session.aiExecutionMode == .autonomous }
    private var selectionCount: Int { selections.values.reduce(0) { $0 + $1.count } }
    private let categories: [(key: String, table: String, id: String, title: String)] = [
        ("workIds", "works", "nodus_id", "Obras"), ("ideaIds", "ideas", "global_id", "Ideas"),
        ("themeIds", "themes", "theme_id", "Temas"), ("gapIds", "gaps", "id", "Huecos"),
        ("passageIds", "passages", "passage_id", "Pasajes"),
        ("contradictionIds", "global_edges", "id", "Contradicciones"), ("tutorRouteIds", "tutor_routes", "id", "Rutas")]
    private let languages = [("es", "Español"), ("en", "English"), ("fr", "Français"), ("tr", "Türkçe"),
        ("de", "Deutsch"), ("pt", "Português (Portugal)"), ("pt-BR", "Português (Brasil)"), ("it", "Italiano"),
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("vi", "Tiếng Việt"), ("ja", "日本語"),
        ("ru", "Русский"), ("uk", "Українська"), ("ko", "한국어")]
    private var selection: JSONValue {
        .object(Dictionary(uniqueKeysWithValues: CompanionWorkshopSource.groups.keys.map {
            ($0, .array((selections[$0] ?? []).sorted().map(JSONValue.string)))
        }))
    }
    var body: some View {
        Form {
            Section("Encargo") {
                TextField("Título del borrador", text: $title)
                TextField("Objetivo, argumento o pregunta", text: $objective, axis: .vertical).lineLimit(3...7)
                TextField("Audiencia (opcional)", text: $audience)
                Picker("Formato", selection: $kind) {
                    Text("Estado de la cuestión").tag("literature_review")
                    Text("Marco teórico").tag("theoretical_framework")
                    Text("Síntesis del debate").tag("debate")
                    Text("Justificación de un hueco").tag("gap_justification")
                    Text("Sección de capítulo").tag("chapter_section")
                    Text("Pregunta de investigación").tag("research_question")
                }
                Picker("Tono", selection: $tone) {
                    Text("Académico").tag("academic"); Text("Sintético").tag("synthetic")
                    Text("Crítico").tag("critical"); Text("Exploratorio").tag("exploratory")
                }
                Picker("Idioma", selection: $language) {
                    ForEach(languages, id: \.0) { code, label in Text(label).tag(code) }
                }
            }
            Section(autonomous ? "Modelo del móvil" : "Modelo de Nodus") {
                if autonomous {
                    NavigationLink { ModelPickerView(task: .writing, accent: session.accent) } label: {
                        LabeledContent("Modelo", value: ai.model(for: .writing)?.model ?? "Seleccionar")
                    }
                    Text("Se utiliza el proveedor configurado en este dispositivo. Si el Mac está desconectado, el borrador se basa en las fuentes descargadas que selecciones.")
                } else { Text("Nodus genera con la configuración del Mac. El modo se cambia expresamente desde los ajustes de conexión.") }
            }.font(.subheadline)
            Section(sourceOffline ? "Fuentes descargadas" : "Elegir fuentes") {
                TextField("Buscar fuentes", text: $query)
                if readingSources { ProgressView("Consultando fuentes") }
                ForEach(categories, id: \.key) { category in
                    let available = rows(category)
                    let limit = limits[category.key] ?? 60
                    DisclosureGroup("\(category.title) · \(selections[category.key]?.count ?? 0) seleccionadas") {
                        ForEach(Array(available.prefix(limit).enumerated()), id: \.offset) { _, row in
                            selectionRow(row, category: category)
                        }
                        if available.count > limit {
                            Button("Mostrar más (\(available.count - limit))") { limits[category.key] = limit + 60 }
                                .frame(minHeight: 44)
                        } else if sourcePages[category.key]?.hasMore == true {
                            Button("Cargar más fuentes") { Task { await loadSourcePage(category.key, reset: false) } }
                                .frame(minHeight: 44).disabled(readingSources)
                        }
                    }
                }
            }
            if session.connection.desktopPairingId != nil {
                Section("Fuentes para llevar") {
                    Text("Conserva las fuentes elegidas para generar un borrador sin conexión. Incluye contradicciones y rutas del tutor; sus documentos y archivos se descargan desde sus lectores.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(selectionCount) fuentes elegidas · máximo 200").font(.caption)
                    Menu {
                        Button("Conservar 7 días") { downloadSources(days: 7) }
                        Button("Conservar 30 días") { downloadSources(days: 30) }
                    } label: {
                        if savingSources { ProgressView("Guardando fuentes…") }
                        else { Label("Conservar selección sin conexión", systemImage: "arrow.down.circle") }
                    }.disabled(savingSources || sending || selectionCount == 0 || selectionCount > 200 || usingDownloads)
                        .frame(minHeight: 44).accessibilityIdentifier("workshop-download-selection")
                    if savingSources { Button("Cancelar descarga", role: .cancel) { sourceDownloadTask?.cancel() }.frame(minHeight: 44) }
                }
            }
            if let error { Section { Text(error).foregroundStyle(Color.nodusDanger).fixedSize(horizontal: false, vertical: true) } }
            if let status { Section { Text(status).fixedSize(horizontal: false, vertical: true) } }
            Section {
                if sending {
                    HStack { ProgressView(); Text(status ?? "Preparando") }
                    Button("Cancelar", role: .cancel) { generationTask?.cancel() }.frame(minHeight: 44)
                } else {
                    Button { generationTask = Task { await queue() } } label: {
                        Label(autonomous ? "Generar en el móvil" : "Generar con Nodus", systemImage: autonomous ? "iphone" : "desktopcomputer")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isDemo || !session.canAuthor
                        || savingSources || selectionCount > 200
                        || (autonomous && (ai.model(for: .writing) == nil || selections.values.allSatisfy(\.isEmpty))))
                }
            }
        }
        .navigationTitle("Nuevo borrador").navigationBarTitleDisplayMode(.inline)
        .onChange(of: query) { _, _ in limits = [:] }
        .onDisappear { generationTask?.cancel(); sourceDownloadTask?.cancel() }
        .task(id: "\(query):\(session.companionDownloadRevision):\(session.contentEpoch)") {
            if !query.isEmpty {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            do {
                let (vault, pairing, _) = try privateBridgeConnection(session, domain: .corpus)
                guard !pairing.isExpired else { throw DesktopBridgeError.expired }
                downloadedSource = try await CompanionWorkshopSource.downloaded(cache: PrivateBridgeCache(pairingId: pairing.id), vaultId: vault)
            } catch { if usingDownloads { self.error = error.localizedDescription } }
            sourceOffline = usingDownloads
            sourceRows = [:]; sourcePages = [:]
            if session.connection.desktopPairingId != nil, !sourceOffline {
                for category in categories {
                    await loadSourcePage(category.key, reset: true)
                    if sourceOffline || Task.isCancelled { break }
                }
            }
        }
        .sheet(item: $completed) { result in
            NavigationStack {
                if let checkpoint = result.checkpoint {
                    CompanionGeneratedResultView(session: session, request: result, checkpoint: checkpoint)
                        .nodusModalClose(accent: session.accent)
                }
            }.nodusTextHierarchy()
        }
    }
    private func rows(_ category: (key: String, table: String, id: String, title: String)) -> [Row] {
        var rows = sourceOffline ? [] : (session.connection.desktopPairingId != nil ? sourceRows[category.key] ?? [] : tables[category.table] ?? [])
        if category.key == "contradictionIds", session.connection.desktopPairingId == nil { rows = rows.filter { $0.string("type") == "contradiction" } }
        var seen = Set(rows.compactMap { $0.string("selection_id") ?? $0.string(category.id) ?? $0.columns[category.id]?.intValue.map { String($0) } })
        for row in (sourceOffline ? downloadedSource?.rows(for: category.key) ?? [] : []) {
            if let id = row.string("selection_id"), seen.insert(id).inserted { rows.append(row) }
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty ? rows : rows.filter { $0.searchableText.localizedStandardContains(needle) }
    }
    private func loadSourcePage(_ key: String, reset: Bool) async {
        readingSources = true
        defer { readingSources = false }
        let currentQuery = query, offset = reset ? 0 : sourceRows[key]?.count ?? 0
        do {
            let (vault, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
            let result = try await DesktopBridgeClient(pairing: pairing, token: token).operation(vaultId: vault,
                method: "getWritingWorkshopMobileCatalogue", args: [.object(["selectionKey": .string(key),
                    "query": .string(currentQuery), "limit": .int(100), "offset": .int(Int64(offset))])], timeout: 4)
            let page = try CompanionWorkshopSource.cataloguePage(result)
            try Task.checkCancellation()
            guard currentQuery == query else { return }
            guard page.offset == offset, page.items.allSatisfy({ $0.string("selection_id") != nil }),
                  reset || sourcePages[key]?.revision == page.revision else {
                sourceRows[key] = []; sourcePages[key] = nil
                throw DesktopBridgeError.malformedResponse
            }
            sourceRows[key] = (reset ? [] : sourceRows[key] ?? []) + page.items
            sourcePages[key] = page; limits[key] = sourceRows[key]?.count ?? 60
        } catch where error.isCancellation { }
        catch {
            guard currentQuery == query else { return }
            if isPrivateBridgeOffline(error) { sourceOffline = true; sourceRows = [:]; sourcePages = [:] }
            else { self.error = error.localizedDescription }
        }
    }
    private func selectionRow(_ row: Row, category: (key: String, table: String, id: String, title: String)) -> some View {
        let identity = row.string("selection_id") ?? row.string(category.id) ?? row.columns[category.id]?.intValue.map { String($0) }
        let label = ["title", "label", "statement", "text", "titulo", "etiqueta", "enunciado", "texto", "desde", "prompt"].compactMap { row.text($0) }.first ?? identity ?? "Fuente"
        return Button {
            guard let identity else { return }
            if selections[category.key, default: []].contains(identity) { selections[category.key]?.remove(identity) }
            else { selections[category.key, default: []].insert(identity) }
        } label: {
            HStack { Text(label).foregroundStyle(.primary).lineLimit(4); Spacer(minLength: 8)
                Image(systemName: identity.map { selections[category.key]?.contains($0) == true } == true ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(session.accent.nodusReadable)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.disabled(identity == nil || sending || savingSources)
    }
    private func downloadSources(days: Int) {
        let selected = selection
        savingSources = true; error = nil
        sourceDownloadTask = Task {
            defer { savingSources = false }
            do {
                try await saveWorkshopSourceSelection(session, selection: selected, days: days)
                status = "Fuentes guardadas para llevar durante \(days) días. Los borradores nuevos se conservarán hasta que decidas eliminarlos."
            } catch is CancellationError { status = "Descarga cancelada." }
            catch { self.error = error.localizedDescription }
        }
    }
    private func queue() async {
        sending = true; error = nil; defer { sending = false }
        do {
            let brief: JSONValue = .object(["kind": .string(kind), "objective": .string(objective),
                "audience": .string(audience), "tone": .string(tone), "language": .string(language)])
            if autonomous {
                guard let model = ai.model(for: .writing) else { error = "Selecciona un modelo de escritura del móvil."; return }
                let modelJSON = try JSONDecoder.nodus.decode(JSONValue.self, from: JSONEncoder.nodus.encode(model))
                let request = JSONValue.object(["brief": brief, "selection": selection, "title": .string(title), "model": modelJSON])
                let generator = CompanionWorkshopGeneration(settings: ai)
                completed = try await generator.run(session: session, request: request) { status = $0 }
            } else {
                var payload = brief.objectValue!
                payload["title"] = .string(title)
                payload.merge(selection.objectValue!) { _, new in new }
                let fingerprint = try JSONEncoder.nodus.encode(JSONValue.object(payload))
                let stable = SHA256.hash(data: fingerprint).map { String(format: "%02x", $0) }.joined()
                let result = try await session.client.createSpaceAction(idempotencyKey: "writing:\(stable)", kind: .writingGenerate,
                    payload: payload, inputRevision: session.publishedRevision, executionMode:session.aiExecutionMode.rawValue, in:session.connection.spaceId)
                onQueued(result.action.receiptMessage)
            }
        } catch where error.isCancellation { status = "Generación cancelada. El original permanece intacto." }
        catch { self.error = error.localizedDescription }
    }
}
