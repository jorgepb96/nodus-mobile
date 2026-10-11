import CryptoKit
import NodusKit
import NodusAI
import NodusUI
import SwiftUI
import UniformTypeIdentifiers

struct WritingWorkshopMobileView: View {
    let session: SpaceSession
    @Environment(\.horizontalSizeClass) private var horizontalSize

    @State private var tables: [String: [Row]] = [:]
    @State private var drafts: [AcademicWritingDraftSummary] = []
    @State private var selectedId: String?
    @State private var showingComposer = false
    @State private var loading = true
    @State private var message: String?
    @State private var error: String?
    @State private var reading: AcademicWritingDraftSummary?
    @State private var usingDownloads = false

    private var selected: AcademicWritingDraftSummary? {
        drafts.first { $0.id == selectedId } ?? drafts.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                DesktopPageHeader(
                    title: "Writing Workshop",
                    subtitle: "Drafts grounded in selected ideas, themes, gaps, works and passages",
                    systemImage: "square.and.pencil",
                    accent: session.accent,
                    trailing: {
                        Button { showingComposer = true } label: { Label("New draft", systemImage: "plus") }
                            .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent))
                    }
                )
                CompanionResultsButton(session: session, surface: .writingWorkshop, generationStatus: nil)
                if let error { NodusNotice(tone: .blocked, title: "Writing Workshop unavailable", message: LocalizedStringKey(error)) }
                if let message { NodusNotice(tone: .info, title: "Desktop action", message: LocalizedStringKey(message)) }
                if loading && drafts.isEmpty { HStack { Spacer(); ProgressView().tint(session.accent); Spacer() }.padding(40) }
                else if drafts.isEmpty {
                    ContentUnavailableView(
                        "No saved drafts", systemImage: "doc.text",
                        description: Text("Create a grounded draft. Desktop will generate and save it, then the publication makes it available here.")
                    ).padding(.vertical, 42)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 9)], spacing: 9) {
                        ForEach(drafts) { draft in
                            Button {
                                selectedId = draft.id
                                if UIDevice.current.userInterfaceIdiom == .phone || horizontalSize == .compact { reading = draft }
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack { NodusChip(key: draft.kind.replacingOccurrences(of: "_", with: " "), tint: session.accent); Spacer(); Image(systemName: selected?.id == draft.id ? "checkmark.circle.fill" : "doc.text").foregroundStyle(session.accent.nodusReadable) }
                                    Text(draft.title).font(.headline).lineLimit(2)
                                    Text(draft.abstract.isEmpty ? draft.objective : draft.abstract).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    if let date = draft.updatedAt { Text(date).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1) }
                                }
                                .desktopContentRow(accent: selected?.id == draft.id ? session.accent : .secondary)
                            }.buttonStyle(NodusCardButtonStyle())
                        }
                    }
                    if UIDevice.current.userInterfaceIdiom != .phone, horizontalSize != .compact, let selected { WritingDraftReader(draft: selected, session: session, document: draftValue(selected.id)) }
                }
            }
            .padding(NodusSpace.page).frame(maxWidth: 1120).frame(maxWidth: .infinity)
            .nodusTopAnchor()
        }
        .nodusPageBackdrop(accent: session.accent)
        .accessibilityIdentifier("academic-writing")
        .task(id: "\(session.publishedRevision ?? ""): \(session.companionPublicationRevision):\(session.companionDownloadRevision)") { await load() }
        .sheet(item: $reading) { draft in
            NavigationStack {
                ScrollView { WritingDraftReader(draft: draft, session: session, document: draftValue(draft.id)).padding(16) }
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

    private func draftValue(_ id: String) -> JSONValue? {
        tables["writing_saved_drafts"]?.first(where: { $0.string("id") == id })?.embeddedJSON("draft_json")
    }

    private func load() async {
        loading = true
        do {
            tables = try await session.client.snapshot(in: session.connection.spaceId).tables
            drafts = AcademicAuthoredProjection.writingDrafts(from: tables)
            if selectedId == nil { selectedId = drafts.first?.id }
            usingDownloads = false
            error = nil
        } catch {
            self.error = error.localizedDescription
            if isPrivateBridgeOffline(error) { usingDownloads = true; tables = [:]; drafts = [] }
        }
        loading = false
    }
}

private struct WritingDraftReader: View {
    let draft: AcademicWritingDraftSummary
    let session: SpaceSession
    var document: JSONValue? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.title).font(.title2.weight(.semibold))
                    if !draft.objective.isEmpty { Text(draft.objective).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer()
                ShareLink(item: draft.markdown) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(NodusGlassIconButtonStyle(accent: session.accent)).accessibilityLabel("Share Markdown")
                Button { UIPasteboard.general.string = draft.markdown } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(NodusGlassIconButtonStyle(accent: session.accent)).accessibilityLabel("Copy Markdown")
            }
            if !draft.abstract.isEmpty {
                Text(draft.abstract).font(.callout).foregroundStyle(.secondary).padding(12)
                    .background(session.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            }
            CorpusProse(draft.markdown, accent: session.accent, session: session)
                .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
            if let document { WorkshopDraftSections(draft: document, session: session) }
        }
        .desktopContentRow(accent: session.accent)
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
    private var autonomous: Bool { session.aiExecutionMode == .autonomous }
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
                    .disabled(objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isDemo || !session.connection.role.canSendChanges
                        || (autonomous && (ai.model(for: .writing) == nil || selections.values.allSatisfy(\.isEmpty))))
                }
            }
        }
        .navigationTitle("Nuevo borrador").navigationBarTitleDisplayMode(.inline)
        .onChange(of: query) { _, _ in limits = [:] }
        .onDisappear { generationTask?.cancel() }
        .task(id: "\(query):\(session.companionDownloadRevision):\(session.publishedRevision ?? "")") {
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
                    "query": .string(currentQuery), "limit": .int(100), "offset": .int(offset)])], timeout: 4)
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
        }.disabled(identity == nil || sending)
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
                _ = try await session.client.createSpaceAction(idempotencyKey: "writing:\(stable)", kind: .writingGenerate,
                    payload: payload, inputRevision: session.publishedRevision, in: session.connection.spaceId)
                onQueued("Nodus ha aceptado la generación. El borrador aparecerá cuando esté guardado y disponible para consultar.")
            }
        } catch where error.isCancellation { status = "Generación cancelada. El original permanece intacto." }
        catch { self.error = error.localizedDescription }
    }
}

struct ProjectsMobileView: View {
    let session: SpaceSession

    @State private var tables: [String: [Row]] = [:]
    @State private var projects: [AcademicProjectSummary] = []
    @State private var selectedId: String?
    @State private var showingCreate = false
    @State private var importing = false
    @State private var loading = true
    @State private var message: String?
    @State private var error: String?

    private var selected: AcademicProjectSummary? {
        projects.first { $0.id == selectedId } ?? projects.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                DesktopPageHeader(
                    title: "Projects",
                    subtitle: "Research containers, coverage, drafts and manuscript chapters",
                    systemImage: "folder",
                    accent: session.accent,
                    trailing: {
                        Button { showingCreate = true } label: { Label("New project", systemImage: "plus") }
                            .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent))
                    }
                )
                if let error { NodusNotice(tone: .blocked, title: "Projects unavailable", message: LocalizedStringKey(error)) }
                if let message { NodusNotice(tone: .info, title: "Desktop action", message: LocalizedStringKey(message)) }
                if loading && projects.isEmpty { HStack { Spacer(); ProgressView().tint(session.accent); Spacer() }.padding(40) }
                else if projects.isEmpty {
                    ContentUnavailableView("No projects", systemImage: "folder", description: Text("Create the first project here; Desktop will initialise its canonical Notes structure."))
                        .padding(.vertical, 42)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(projects) { project in
                                Button { selectedId = project.id } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack { NodusChip(key: project.status, tint: project.status == "done" ? .green : session.accent); Spacer(); Text(project.kind.replacingOccurrences(of: "_", with: " ")).font(.caption2).foregroundStyle(.secondary) }
                                        Text(project.title).font(.headline).lineLimit(2)
                                        Text(project.brief).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }.frame(width: 240, alignment: .leading).desktopContentRow(accent: selected?.id == project.id ? session.accent : .secondary)
                                }.buttonStyle(NodusCardButtonStyle())
                            }
                        }.padding(.vertical, 2)
                    }.scrollIndicators(.hidden)
                    if let selected { projectDossier(selected) }
                }
            }
            .padding(NodusSpace.page).frame(maxWidth: 1140).frame(maxWidth: .infinity)
            .nodusTopAnchor()
        }
        .nodusPageBackdrop(accent: session.accent)
        .accessibilityIdentifier("academic-projects")
        .task(id: session.publishedRevision) { await load() }
        .nodusSheet(isPresented: $showingCreate) {
            NavigationStack { ProjectCreateForm(session: session) { message = $0; showingCreate = false } }
                .nodusModalClose(accent: session.accent)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text], allowsMultipleSelection: false) { result in
            Task { await importChapter(result) }
        }
    }

    @ViewBuilder private func projectDossier(_ project: AcademicProjectSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.title).font(.title2.weight(.semibold))
                    Text(project.brief).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button { importing = true } label: { Label("Import Markdown or text", systemImage: "doc.badge.plus") }
                    ShareLink(item: projectMarkdown(project)) { Label("Export Markdown", systemImage: "square.and.arrow.up") }
                } label: { Image(systemName: "ellipsis.circle") }
                    .buttonStyle(NodusGlassIconButtonStyle(accent: session.accent))
            }
            if let target = project.targetWords { Label("Target: \(target.formatted()) words", systemImage: "text.word.spacing").font(.caption).foregroundStyle(.secondary) }
            Text("Sections").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)], spacing: 8) {
                ForEach(project.sections) { section in
                    Menu {
                        ForEach(["empty", "in_progress", "review", "ready", "discarded"], id: \.self) { status in
                            Button { Task { await update(section: section, status: status) } } label: {
                                if section.status == status { Label(status.replacingOccurrences(of: "_", with: " "), systemImage: "checkmark") }
                                else { Text(status.replacingOccurrences(of: "_", with: " ")) }
                            }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Text(section.role).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(); NodusChip(key: section.status.replacingOccurrences(of: "_", with: " "), tint: section.status == "ready" ? .green : session.accent)
                        }.desktopContentRow(accent: session.accent)
                    }
                }
            }
            if !project.chapters.isEmpty {
                Text("Manuscript").font(.headline).padding(.top, 4)
                ForEach(project.chapters) { chapter in
                    DisclosureGroup {
                        CorpusProse(chapter.markdown, accent: session.accent, session: session).padding(.top, 8)
                    } label: {
                        HStack { Label(chapter.title, systemImage: "doc.text").font(.subheadline.weight(.semibold)); Spacer(); Text("\(chapter.wordCount.formatted()) words").font(.caption2).foregroundStyle(.secondary) }
                    }.padding(12).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
                }
            }
            if !project.links.isEmpty {
                Text("Linked evidence").font(.headline).padding(.top, 4)
                ForEach(project.links) { link in
                    HStack { NodusChip(key: link.kind, tint: session.accent); Text(link.label).font(.caption); Spacer(); Text(link.role).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }.desktopContentRow(accent: session.accent)
    }

    private func load() async {
        loading = true
        do {
            tables = try await session.client.snapshot(in: session.connection.spaceId).tables
            projects = AcademicAuthoredProjection.projects(from: tables)
            if selectedId == nil { selectedId = projects.first?.id }
            error = nil
        } catch { self.error = error.localizedDescription }
        loading = false
    }

    private func update(section: AcademicProjectSection, status: String) async {
        do {
            _ = try await session.client.createSpaceAction(
                idempotencyKey: "project-section:\(section.id):\(status):\(session.publishedRevision ?? "local")",
                kind: .projectsSectionUpdate,
                payload: ["id": .string(section.id), "status": .string(status)], inputRevision: session.publishedRevision,
                in: session.connection.spaceId
            )
            message = String(localized: "Section update queued once for Desktop.")
        } catch { self.error = error.localizedDescription }
    }

    private func importChapter(_ result: Result<[URL], Error>) async {
        guard let project = selected else { return }
        do {
            let url = try result.get().first!
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard data.count <= 500_000, let text = String(data: data, encoding: .utf8) else {
                throw AcademicCreateFailure.importTooLargeOrBinary
            }
            _ = try await session.client.createSpaceAction(
                idempotencyKey: "project-chapter:\(project.id):\(stableActionFingerprint(text))",
                kind: .projectsChapterImport,
                payload: [
                    "projectId": .string(project.id), "title": .string(url.deletingPathExtension().lastPathComponent),
                    "sourceFormat": .string(url.pathExtension.lowercased() == "md" ? "markdown" : "txt"), "text": .string(text),
                ], inputRevision: session.publishedRevision, in: session.connection.spaceId
            )
            message = String(localized: "Chapter import queued once. Desktop will version it and link it to the manuscript.")
        } catch { self.error = error.localizedDescription }
    }

    private func projectMarkdown(_ project: AcademicProjectSummary) -> String {
        (["# \(project.title)", "", project.brief] + project.chapters.flatMap { ["", $0.markdown] }).joined(separator: "\n")
    }
}

private struct ProjectCreateForm: View {
    let session: SpaceSession
    let onQueued: (String) -> Void
    @State private var title = ""
    @State private var kind = "thesis"
    @State private var brief = ""
    @State private var targetWords = 50_000
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Project") {
                TextField("Title", text: $title)
                Picker("Kind", selection: $kind) {
                    Text("Thesis").tag("thesis"); Text("Article").tag("article"); Text("Chapter").tag("chapter")
                    Text("Literature review").tag("literature_review"); Text("Theoretical framework").tag("theoretical_framework"); Text("Other").tag("other")
                }
                TextField("Brief and scope", text: $brief, axis: .vertical).lineLimit(4...8)
                Stepper("Target: \(targetWords.formatted()) words", value: $targetWords, in: 1_000...500_000, step: 1_000)
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button { Task { await queue() } } label: { HStack { Spacer(); if sending { ProgressView() } else { Label("Create in Desktop", systemImage: "desktopcomputer") }; Spacer() } }
                    .disabled(sending || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isDemo || !session.connection.role.canSendChanges)
            }
        }.navigationTitle("New project").navigationBarTitleDisplayMode(.inline)
    }

    private func queue() async {
        sending = true; defer { sending = false }
        do {
            let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await session.client.createSpaceAction(
                idempotencyKey: "project-create:\(stableActionFingerprint("\(normalized)|\(kind)|\(brief)"))", kind: .projectsCreate,
                payload: ["title": .string(normalized), "kind": .string(kind), "brief": .string(brief), "targetWords": .int(Int64(targetWords))],
                inputRevision: session.publishedRevision, in: session.connection.spaceId
            )
            onQueued("Project creation queued once. Desktop will initialise every canonical section and publish it.")
        } catch { self.error = error.localizedDescription }
    }
}

private enum AcademicCreateFailure: LocalizedError {
    case importTooLargeOrBinary
    var errorDescription: String? { "Mobile imports accept UTF-8 Markdown or text up to 500 KB. Use “Run on Mac” for PDF, DOCX or larger files." }
}

/// Stable, non-secret FNV fingerprint used only for outbox idempotency.
private func stableActionFingerprint(_ source: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in source.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
    return String(hash, radix: 16)
}
