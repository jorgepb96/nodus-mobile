import NodusAI
import NodusKit
import NodusUI
import SwiftUI

struct DeepResearchSaveToNotesButton: View {
    let reportId: String
    let title: String
    let markdown: String
    let session: SpaceSession

    @State private var sending = false
    @State private var queued = false
    @State private var failure: String?
    @State private var receipt: String?

    var body: some View {
        Button { save() } label: {
            HStack(spacing: 7) {
                if sending {
                    ProgressView().controlSize(.small).tint(session.accent)
                } else {
                    Image(systemName: queued ? "checkmark.circle" : "note.text.badge.plus")
                }
                Text(queued ? "Solicitud guardada" : "Save to Notes")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(session.accent.nodusReadable)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .reportActionSurface(accent: session.accent)
        }
        .buttonStyle(.plain)
        .disabled(sending || !session.canAuthor || queued)
        .accessibilityHint("The owner desktop creates the vault note through a typed action.")
        .alert("Guardar en notas", isPresented: Binding(
            get: { failure != nil || receipt != nil },
            set: { if !$0 { failure = nil; receipt = nil } }
        )) {
            Button("OK", role: .cancel) { failure = nil; receipt = nil }
        } message: {
            Text(failure ?? receipt ?? "")
        }
    }

    private func save() {
        guard !sending else { return }
        sending = true
        Task {
            do {
                let result = try await session.client.createSpaceAction(
                    idempotencyKey: "deep-research-note:\(reportId)",
                    kind: .deepResearchSaveToNotes,
                    payload: [
                        "reportId": .string(reportId),
                        "title": .string(title),
                        "markdown": .string(markdown),
                    ],
                    inputRevision: session.publishedRevision,
                    executionMode:session.aiExecutionMode.rawValue, in:session.connection.spaceId
                )
                queued = ![.failed, .refused, .cancelled].contains(result.action.status)
                receipt = result.action.receiptMessage
            } catch {
                failure = error.localizedDescription
            }
            sending = false
        }
    }
}

enum DeepResearchReaderSheet: String, Identifiable {
    case outline, workspace, translation, image
    var id: String { rawValue }
}

struct DeepResearchImageEditorSheet: View {
    let saved: LocalReportStore.Saved
    @Bindable var store: LocalReportStore
    let session: SpaceSession

    @Environment(AISettings.self) private var ai
    @State private var style: DecorativeImageStyle = .fallback
    @State private var direction = ""
    @State private var generating = false
    @State private var failure: String?
    @State private var progress: String?
    @State private var recovering = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let current = store.reports.first(where: { $0.id == saved.id }),
                       let url = store.imageURL(for: current) {
                        LocalReportImage(url: url)
                            .frame(height: 230).frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        Button(role: .destructive) { removeImage() } label: {
                            Label("Remove image", systemImage: "trash")
                        }.disabled(generating || recovering)
                    }
                    Picker("Style", selection: $style) {
                        ForEach(DecorativeImageStyle.allCases, id: \.self) { option in
                            Text(LocalizedStringKey(option.label)).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    TextField("Optional art direction", text: $direction, axis: .vertical)
                        .lineLimit(2...5).padding(12).nodusFieldSurface(accent: session.accent)
                    Text(session.aiExecutionMode == .live ? "La imagen se genera en el Mac con su modelo configurado." : "La imagen se genera en este dispositivo con su modelo configurado.")
                        .font(.caption).foregroundStyle(.secondary)
                    if session.aiExecutionMode == .live, saved.vaultRowId == nil {
                        NodusNotice(tone: .info, title: "Guarda el informe en el Mac", message: "La generación Live necesita un informe guardado en el vault vinculado.")
                    }
                    if let progress { Text(progress).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("report-image-progress") }
                    if let failure {
                        NodusNotice(tone: .blocked, title: "Image generation failed", message: LocalizedStringKey(failure))
                    }
                    Button { generate() } label: {
                        if generating { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
                        else { Label("Generate new image", systemImage: "photo.badge.plus").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent))
                    .disabled(generating || recovering || (session.aiExecutionMode == .live ? saved.vaultRowId == nil || session.connection.desktopPairingId == nil || !session.canAuthor : ai.model(for: .image) == nil || ai.model(for: .deepResearch) == nil))
                    .accessibilityIdentifier("report-image-generate")
                }
                .padding(NodusSpace.page)
                .frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
            .navigationTitle("Report image")
            .navigationBarTitleDisplayMode(.inline)
            .nodusPageBackdrop(accent: session.accent)
        }
        .task(id: session.aiExecutionMode) { if session.aiExecutionMode == .live { await recoverMacImage() } }
    }

    private func generate() {
        guard !generating else { return }
        if session.aiExecutionMode == .live { generateOnMac(); return }
        guard let imageModel = ai.model(for: .image),
              let textModel = ai.model(for: .deepResearch)
        else { return }
        generating = true
        failure = nil
        Task {
            do {
                let scene: String
                if direction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    scene = try await ProviderClient(keyProvider: ai.keyProvider).complete(ChatRequest(
                        model: textModel,
                        messages: [
                            .init(role: .system, content: Prompts.visualContextSystem),
                            .init(role: .user, content: Prompts.visualContext(for: saved.report)),
                        ],
                        temperature: 0.2,
                        maxTokens: 200
                    ))
                } else {
                    scene = direction
                }
                let image = try await ImageService(keyProvider: ai.keyProvider).generate(
                    prompt: style.imagePrompt(scene: scene),
                    with: imageModel
                )
                _ = store.attach(image, to: saved.id)
                await syncImage(image, model: imageModel, visualContext: scene)
            } catch {
                failure = error.localizedDescription
            }
            generating = false
        }
    }

    private func generateOnMac() {
        guard let remoteId = saved.vaultRowId, !generating, !recovering else { return }
        generating = true; failure = nil; progress = "Preparando la solicitud en el Mac"
        let requestedStyle = style.rawValue, requestedDirection = direction
        Task {
            defer { generating = false }
            do {
                let (vault, pairing, token) = try privateBridgeConnection(session, domain: .researchGeneration)
                guard pairing.domains.contains(.writing), pairing.domains.contains(.corpus) else { throw DesktopBridgeError.permissionDenied }
                let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vault)
                let id = UUID().uuidString.lowercased()
                let request: JSONValue = .object(["entityId": .string(remoteId), "style": .string(requestedStyle), "visualContext": .string(requestedDirection)])
                let record = try await ledger.prepare(id: id, method: "generateReportImage", args: [request])
                try await observeMacImage(record, ledger: ledger, client: DesktopBridgeClient(pairing: pairing, token: token), vault: vault, reportId: remoteId)
            } catch { failure = error.localizedDescription }
        }
    }

    private func recoverMacImage() async {
        guard let remoteId = saved.vaultRowId else { return }
        recovering = true
        defer { recovering = false }
        do {
            let (vault, pairing, token) = try privateBridgeConnection(session, domain: .researchGeneration)
            let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vault)
            guard let record = await ledger.all().first(where: { $0.method == "generateReportImage" && $0.args.first?.objectValue?["entityId"] == .string(remoteId) }) else { return }
            guard !["failed", "cancelled", "interrupted"].contains(record.state) else { failure = record.issue; return }
            try await observeMacImage(record, ledger: ledger, client: DesktopBridgeClient(pairing: pairing, token: token), vault: vault, reportId: remoteId)
        } catch is CancellationError { }
        catch { failure = error.localizedDescription }
    }

    private func observeMacImage(_ record: DesktopJobLedger.Request, ledger: DesktopJobLedger, client: DesktopBridgeClient, vault: String, reportId: String) async throws {
        do {
            let job: DesktopBridgeJob
            if let id = record.jobId { job = try await client.readJob(vaultId: vault, id: id) }
            else { job = try await client.submitJob(vaultId: vault, method: record.method, args: record.args, idempotencyKey: record.id) }
            try await ledger.update(id: record.id, job: job)
            _ = try await client.awaitJob(vaultId: vault, job: job, onState: { current in
                try await ledger.update(id: record.id, job: current)
                await MainActor.run { progress = "Mac · \(current.state.rawValue)" }
            }, onEvents: { events in
                guard let phase = events.last(where: { $0.channel == "mobile:reportImage:progress" })?.args.first?.objectValue?["phase"]?.stringValue else { return }
                await MainActor.run {
                    switch phase {
                    case "context": progress = "Preparando el contexto visual en el Mac"
                    case "generating": progress = "Generando la imagen en el Mac"
                    case "saving": progress = "Guardando la imagen en el vault"
                    default: break
                    }
                }
            })
            let metadata = try await client.operation(vaultId: vault, method: "getDecorativeImage", args: [.string("deep_research"), .string(reportId)])
            let dataURL = try await client.operation(vaultId: vault, method: "getDecorativeImageDataUrl", args: [.string("deep_research"), .string(reportId), .bool(false)])
            let image = try CompanionReportImage.bytes(metadata: metadata, dataURL: dataURL, reportId: reportId)
            guard store.attach(GeneratedImage(data: image.data, mimeType: image.mime), to: saved.id) != nil else {
                throw APIError(status: 507, code: "report_image_device_save_failed", message: "La imagen está guardada en el Mac, pero no pudo conservarse en este dispositivo. Vuelve a abrir este panel para recuperarla.")
            }
            progress = "Imagen guardada en el Mac y en este dispositivo"
        } catch {
            try? await ledger.disconnected(id: record.id, issue: error.localizedDescription)
            throw error
        }
    }

    private func removeImage() {
        store.removeImage(from: saved.id)
        guard let remoteId = saved.vaultRowId else { return }
        Task {
            guard let controller = await OutboxController.open(session: session) else { return }
            _ = await controller.syncMutation(
                kind: .delete,
                table: .decorativeImages,
                key: ["deep_research", remoteId],
                title: String(localized: "Remove Deep Research image")
            )
        }
    }

    private func syncImage(_ image: GeneratedImage, model: ModelRef, visualContext: String) async {
        guard let remoteId = saved.vaultRowId,
              let controller = await OutboxController.open(session: session) else { return }
        do {
            let limit = (try? await session.client.capabilities().maxAssetBytes) ?? 8 * 1024 * 1024
            let upload = try await session.client.upload(
                imageData: image.data,
                in: session.connection.spaceId,
                maxBytes: limit
            )
            let now = ISO8601DateFormatter.nodusFractional.string(from: Date())
            let row: [String: JSONValue] = [
                "entity_kind": .string("deep_research"), "entity_id": .string(remoteId),
                "requested": .int(1), "status": .string("ready"),
                "provider": .string(model.provider.rawValue), "model": .string(model.model),
                "style": .string(style.rawValue), "visual_context": .string(visualContext),
                "prompt": .string(style.imagePrompt(scene: visualContext)),
                "asset_ref": .string("server:\(upload.hash)"),
                "mime_type": .string(upload.mime ?? image.mimeType), "source": .string("ai"),
                "created_at": .string(now), "updated_at": .string(now),
            ]
            _ = await controller.syncMutation(
                kind: .upsert,
                table: .decorativeImages,
                key: ["deep_research", remoteId],
                row: row,
                assets: [.init(hash: upload.hash)],
                title: String(localized: "Deep Research image")
            )
        } catch {
            failure = error.localizedDescription
        }
    }
}

struct DeepResearchOutlineSheet: View {
    let report: DeepResearchReport
    let activeSection: Int
    let accent: Color
    let select: (Int) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(report.sections.enumerated()), id: \.offset) { index, section in
                        Button {
                            select(index)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(section.title).foregroundStyle(.primary)
                                Spacer()
                                if index == activeSection { Image(systemName: "location.fill").foregroundStyle(accent) }
                            }
                        }
                    }
                } header: { Text("Contents") }
                if !report.references.isEmpty {
                    Section("Bibliography") {
                        ForEach(report.references, id: \.token) { reference in
                            Text(reference.label).font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Report outline")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("report-outline-sheet")
    }
}

private enum ResearchWorkspaceTab: String, CaseIterable, Identifiable {
    case support, ideas, works, authors, passages, gaps, contradictions
    var id: String { rawValue }
    var label: String {
        switch self {
        case .support: String(localized: "Support matrix")
        case .ideas: String(localized: "Ideas")
        case .works: String(localized: "Works")
        case .authors: String(localized: "Authors")
        case .passages: String(localized: "Passages")
        case .gaps: String(localized: "Gaps")
        case .contradictions: String(localized: "Contradictions")
        }
    }
    var icon: String {
        switch self {
        case .support: "tablecells"
        case .ideas: "lightbulb"
        case .works: "books.vertical"
        case .authors: "person.2"
        case .passages: "quote.opening"
        case .gaps: "circle.dashed"
        case .contradictions: "arrow.left.arrow.right"
        }
    }
}

struct DeepResearchWorkspaceSheet: View {
    let report: DeepResearchReport
    let session: SpaceSession
    @State private var tab: ResearchWorkspaceTab = .support

    private var cells: [DeepResearchSupportCell] { report.resolvedSupportMatrix }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ResearchWorkspaceTab.allCases) { option in
                            Button {
                                tab = option
                            } label: {
                                Label(option.label, systemImage: option.icon)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 40)
                                    .background(tab == option ? session.accent.opacity(0.17) : Color.primary.opacity(0.04), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                Divider().opacity(0.4)
                content
            }
            .navigationTitle("Sources and citations")
            .navigationBarTitleDisplayMode(.inline)
            .nodusPageBackdrop(accent: session.accent)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .support:
            matrix(cells)
        case .ideas:
            matrix(cells.filter { $0.citationToken.contains("/idea/") })
        case .works:
            matrix(cells.filter { $0.citationToken.contains("/work/") })
        case .authors:
            matrix(cells.filter { $0.citationToken.contains("/author/") })
        case .passages:
            matrix(cells.filter { $0.citationToken.contains("/passage/") })
        case .gaps:
            gaps
        case .contradictions:
            contradictions
        }
    }

    private func matrix(_ rows: [DeepResearchSupportCell]) -> some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView("No entries", systemImage: tab.icon, description: Text("This report does not contain grounded entries in this category."))
            } else {
                List(rows) { cell in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(cell.sectionTitle).font(.caption.weight(.semibold))
                            Spacer()
                            Label(cell.status.rawValue.capitalized, systemImage: cell.status == .supported ? "checkmark.seal.fill" : "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(cell.status == .supported ? Color.nodusSuccess : Color.nodusCaution)
                        }
                        Text(cell.claimPreview).font(.subheadline).lineLimit(3)
                        Text(cell.sourceLabel).font(.caption).foregroundStyle(session.accent.nodusReadable)
                    }
                    .padding(.vertical, 5)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var gaps: some View {
        List {
            if let reason = report.stoppedReason {
                Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(Color.nodusCaution)
            }
            ForEach(cells.filter { $0.status != .supported }) { cell in
                VStack(alignment: .leading) {
                    Text(cell.claimPreview)
                    Text(cell.sourceLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
            if report.stoppedReason == nil, cells.allSatisfy({ $0.status == .supported }) {
                ContentUnavailableView("No recorded gaps", systemImage: "checkmark.seal", description: Text("Every materialised support row resolves to an available source."))
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
    }

    private var contradictions: some View {
        Group {
            if report.citationsRejected == 0 {
                ContentUnavailableView("No citation contradictions", systemImage: "checkmark.seal", description: Text("No invented or unavailable citation survived verification."))
            } else {
                List(report.sections.filter { !$0.rejectedCitations.isEmpty }, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(section.title).font(.headline)
                        ForEach(section.rejectedCitations, id: \.self) { Text($0).font(.caption.monospaced()) }
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
    }
}

struct DeepResearchTranslationSheet: View {
    let reportId: String
    let sourceMarkdown: String
    let sourceTitle: String
    let session: SpaceSession
    var remoteRows: [Row]? = nil
    var syncEnabled = true

    @Environment(AISettings.self) private var ai
    @Environment(\.dismiss) private var dismiss
    @State private var store: DeepResearchTranslationStore
    @State private var language = "es"
    @State private var translating = false
    @State private var failure: String?
    @State private var recovering = false
    @State private var progress: String?

    init(
        reportId: String,
        sourceMarkdown: String,
        sourceTitle: String = "Deep Research",
        session: SpaceSession,
        remoteRows: [Row]? = nil,
        syncEnabled: Bool = true
    ) {
        self.reportId = reportId
        self.sourceMarkdown = sourceMarkdown
        self.sourceTitle = sourceTitle
        self.session = session
        self.remoteRows = remoteRows
        self.syncEnabled = syncEnabled
        _store = State(initialValue: DeepResearchTranslationStore(spaceId: session.connection.storageId, reportId: reportId))
    }

    private var selected: ContentTranslation? { store.translation(language: language) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Translation language", selection: $language) {
                        ForEach(TranslationLanguage.supported) { option in
                            Text("\(option.nativeName) — \(option.name)").tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(session.accent)
                    .accessibilityIdentifier("report-translation-language")
                    .disabled(translating || recovering)

                    if let progress { Text(progress).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("report-translation-state") }
                    if let failure {
                        NodusNotice(tone: .blocked, title: "Translation failed", message: LocalizedStringKey(failure))
                            .accessibilityIdentifier("report-translation-error")
                    }

                    if let selected {
                        HStack {
                            Text("Saved \((selected.updatedAt ?? selected.createdAt).formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if session.canAuthor { Button(role: .destructive) { deleteTranslation() } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .frame(minHeight: 44).disabled(translating || recovering) }
                        }
                        CorpusProse(selected.markdown, accent: session.accent, session: session)
                            .padding(16)
                            .nodusGlass(NodusGlass(.regular, tint: session.accent))
                            .accessibilityIdentifier("report-translation-body")
                    } else {
                        ContentUnavailableView("No saved translation", systemImage: "character.book.closed", description: Text("Generate it once and it remains available offline."))
                            .frame(maxWidth: .infinity, minHeight: 240)
                    }

                    if session.canAuthor { Text(session.aiExecutionMode == .live
                         ? "Translate with your Mac’s research model. Your Mac must be connected."
                         : "Translate with the provider and translation model configured on this device.")
                        .font(.caption).foregroundStyle(.secondary)
                    if session.aiExecutionMode == .live && !syncEnabled {
                        Text("Save this report to Nodus before translating with your Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button { translate() } label: {
                        if translating || recovering { ProgressView().controlSize(.small).frame(maxWidth: .infinity).accessibilityIdentifier("report-translation-progress") }
                        else { Label(selected == nil ? "Translate report" : "Regenerate translation", systemImage: "character.book.closed").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent))
                    .disabled(translating || recovering || (session.aiExecutionMode == .autonomous ? ai.model(for: .translation) == nil : !syncEnabled || session.connection.desktopPairingId == nil))
                    .accessibilityIdentifier("report-translation-generate")
                    }
                }
                .padding(NodusSpace.page)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Translations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .nodusPageBackdrop(accent: session.accent)
        }
        .task(id: "\(session.publishedRevision ?? "")|\(language)|\(session.aiExecutionMode.rawValue)") {
            if syncEnabled, let remoteRows { store.replaceFromServer(rows: remoteRows) }
            if session.aiExecutionMode == .live, syncEnabled, !translating {
                recovering = true
                defer { recovering = false }
                do { try await translateOnMac(explicit: false, requestedLanguage: language) }
                catch is CancellationError { }
                catch { failure = error.localizedDescription }
            }
        }
    }

    private func translate() {
        guard !translating else { return }
        if session.aiExecutionMode == .live {
            translating = true; failure = nil
            let requestedLanguage = language
            Task {
                defer { translating = false }
                do { try await translateOnMac(explicit: true, requestedLanguage: requestedLanguage) }
                catch { failure = error.localizedDescription }
            }
            return
        }
        guard let model = ai.model(for: .translation),
              let languageName = TranslationLanguage.supported.first(where: { $0.id == language })?.name
        else { return }
        translating = true
        failure = nil
        let requestedLanguage = language
        Task {
            do {
                let provider = ProviderClient(keyProvider: ai.keyProvider)
                let response = try await AcademicTranslation.translate(source: sourceMarkdown, language: languageName) { system, source in
                    try await provider.complete(ChatRequest(model: model, messages: [
                        .init(role: .system, content: system), .init(role: .user, content: source)
                    ], temperature: 0.1, maxTokens: 16_000))
                }
                let value = store.save(reportId: reportId, language: requestedLanguage, markdown: response, model: model)
                await sync(value)
            } catch {
                failure = error.localizedDescription
            }
            translating = false
        }
    }

    private func translateOnMac(explicit: Bool, requestedLanguage: String) async throws {
        guard syncEnabled else { return }
        let (vault, pairing, token) = try privateBridgeConnection(session, domain: .writing)
        let client = DesktopBridgeClient(pairing: pairing, token: token)
        let settings = try await client.operation(vaultId: vault, method: "getSettings", args: [])
        guard let model = settings.objectValue?["deepResearchModel"], model.objectValue != nil else {
            throw APIError(status: 409, code: "mac_research_model_missing", message: "Selecciona un modelo de investigación en Nodus para Mac.")
        }
        let request: JSONValue = .object(["entityKind": .string("deep_research"), "entityId": .string(reportId),
            "language": .string(requestedLanguage), "sourceTitle": .string(sourceTitle),
            "sourceMarkdown": .string(sourceMarkdown), "model": model])
        let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vault)
        let decision = CompanionTranslationRecovery.decide(request: request, records: await ledger.all(),
            savedTranslationId: store.translation(language: requestedLanguage)?.id, explicit: explicit,
            pendingDeletion: store.isPendingDeletion(language: requestedLanguage))
        let record: DesktopJobLedger.Request
        switch decision {
        case .resume(let existing), .recover(let existing): record = existing
        case .create:
            try Task.checkCancellation()
            record = try await ledger.prepare(id: UUID().uuidString.lowercased(), method: "generateContentTranslation", args: [request])
        case .failed(let existing):
            progress = "Mac · \(existing.state)"; failure = existing.issue
            return
        case .none: progress = nil; return
        }
        progress = "Recuperando la solicitud de traducción del Mac"
        let result: JSONValue
        do {
            if record.state == "available", let savedResult = record.result {
                result = savedResult
            } else {
                let job: DesktopBridgeJob
                if let id = record.jobId { job = try await client.readJob(vaultId: vault, id: id) }
                else { job = try await client.submitJob(vaultId: vault, method: record.method, args: record.args, idempotencyKey: record.id) }
                try await ledger.update(id: record.id, job: job)
                result = try await client.awaitJob(vaultId: vault, job: job, onState: { current in
                    try await ledger.update(id: record.id, job: current)
                    await MainActor.run { progress = "Mac · \(current.state.rawValue)" }
                }, onEvents: { _ in })
            }
            guard let translationId = result.objectValue?["id"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
            let full = try await client.operation(vaultId: vault, method: "getContentTranslation", args: [.string(translationId)])
            guard let value = full.objectValue, value["entityKind"] == .string("deep_research"),
                  value["entityId"] == .string(reportId), value["language"] == .string(requestedLanguage),
                  let markdown = value["markdown"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
            let modelRef = try? JSONDecoder.nodus.decode(ModelRef.self, from: JSONEncoder.nodus.encode(model))
            store.acceptServer(ContentTranslation(id: translationId, reportId: reportId, language: requestedLanguage,
                markdown: markdown, model: modelRef,
                createdAt: value["createdAt"]?.stringValue.flatMap { ISO8601DateFormatter.nodusFractional.date(from: $0) } ?? Date(),
                updatedAt: value["updatedAt"]?.stringValue.flatMap { ISO8601DateFormatter.nodusFractional.date(from: $0) }))
            progress = "Traducción guardada en el Mac y en este dispositivo"; failure = nil
        } catch {
            try? await ledger.disconnected(id: record.id, issue: error.localizedDescription)
            throw error
        }
    }

    private func deleteTranslation() {
        guard let value = selected else { return }
        store.delete(language: language)
        guard syncEnabled else { return }
        Task {
            guard let controller = await OutboxController.open(session: session) else { return }
            _ = await controller.syncMutation(
                kind: .delete,
                table: .contentTranslations,
                key: [value.id],
                title: String(localized: "Delete Deep Research translation")
            )
        }
    }

    private func sync(_ value: ContentTranslation) async {
        guard syncEnabled, let controller = await OutboxController.open(session: session) else { return }
        _ = await controller.syncMutation(
            kind: .upsert,
            table: .contentTranslations,
            key: [value.id],
            row: value.row,
            title: String(localized: "Deep Research translation")
        )
    }
}
