import NodusAI
import NodusKit
import NodusUI
import SwiftUI

/// Deep Research: one model call per section, and a report whose citations are real.
struct DeepResearchScreen: View {
    @Environment(AISettings.self) private var ai
    let session: SpaceSession
    let local: LocalReportStore

    @State private var objective = ""
    @State private var length: DeepResearchLength = .concise
    @State private var sections: DeepResearchSectionChoice = .automatic
    @State private var mode: DeepResearchMode?
    @State private var approach: DeepResearchApproach = .general
    @State private var wantsIllustration = false
    @State private var imageStyle: DecorativeImageStyle = .fallback
    @State private var language = Prompts.interfaceLanguage
    @State private var audience = ""
    @State private var focusPerson = ""
    @State private var teachingOutline = ""
    @State private var selectedModel: ModelRef?
    /// A run that stopped before its last section. Kept so the sections already paid for are
    /// not thrown away by a screen that was dismissed or a phone that ran out of patience.
    @State private var unfinished: DeepResearchCheckpoint?
    @Environment(AppPreferences.self) private var preferences
    @State private var published: [Row] = []
    @State private var publishedError: String?
    @State private var publishedFromDevice = false
    @State private var query = ""
    @State private var showingComposer = false
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var isExporting = false
    @AppStorage("deep-research.gallery-view") private var galleryView = "list"
    @AppStorage("deep-research.gallery-sort") private var gallerySort = "newest"
    @AppStorage("deep-research.gallery-read") private var galleryRead = "all"

    /// The run itself, which belongs to the space rather than to this screen: leaving here does
    /// not stop it, and coming back finds it exactly where it got to.
    private var runner: DeepResearchRunner { DeepResearchRunner.shared(for: session.connection.storageId) }

    private var report: DeepResearchReport? { nil }
    private var queue: DeepResearchQueue { .shared }
    private var marks: ReportMarks { .shared(for: session.connection.storageId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                workspaceHeader
                queueStrip

                if let unfinished { resumeNotice(unfinished) }
                if let publishedError {
                    NodusNotice(tone: .caution, title: "Published reports are unavailable", message: LocalizedStringKey(publishedError))
                        .accessibilityIdentifier("deep-research-catalog-error")
                    Button { Task { await loadPublished() } } label: { Label("Try again", systemImage: "arrow.clockwise") }
                        .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
                        .accessibilityIdentifier("deep-research-catalog-retry")
                }
                if publishedFromDevice {
                    Label("Sin conexión · se muestran tus informes descargados", systemImage: "wifi.slash")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("deep-research-downloaded-catalogue")
                }
                galleryControls
                gallery
            }
            .padding(NodusSpace.page)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
            .nodusTopAnchor()
        }
        .accessibilityIdentifier("deep-research-gallery-scroll")
        .nodusReadingStyle(ReadingStyle(scale: preferences.readingScale, document: false))
        .nodusDismissesKeyboard()
        .navigationTitle("Deep Research")
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .task {
            runner.attachPending(session: session, ai: ai)
            readCheckpoint()
            seedVisualFixtureIfNeeded()
        }
        .task(id: "\(session.publishedRevision ?? ""):\(session.companionDownloadRevision)") { await loadPublished() }
        .onChange(of: runner.isRunning) { _, running in
            if !running, runner.finished == nil { readCheckpoint() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingComposer = true } label: { Label("New research", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showingComposer) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let unfinished { resumeNotice(unfinished) }
                        form
                    }
                    .padding(NodusSpace.page)
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                }
                .navigationTitle("New research")
                .navigationBarTitleDisplayMode(.inline)
                .nodusPageBackdrop(accent: session.accent)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showingComposer = false }
                    }
                }
            }
            .presentationDetents([.large])
        }
        .alert(
            "Could not export the reports",
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(LocalizedStringKey(exportError ?? ""))
        }
    }

    // MARK: Workspace

    private var workspaceHeader: some View {
        DesktopPageHeader(
            title: "Deep Research",
            subtitle: "Reports grounded in the current corpus",
            systemImage: "telescope",
            accent: session.accent
        ) {
            Button { showingComposer = true } label: {
                Label("New research", systemImage: "sparkles")
            }
            .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent))
            .accessibilityIdentifier("deep-research-new")
        }
    }

    @ViewBuilder
    private var queueStrip: some View {
        let jobs = queue.jobs(in: session.connection.storageId)
        if !jobs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    NodusSectionLabel("Research queue")
                    Spacer()
                    if jobs.contains(where: { $0.status.isFinished }) {
                        Button("Clear finished") { queue.clearFinished() }
                            .font(.caption)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(jobs) { job in
                            DeepResearchQueueCard(
                                job: job,
                                accent: session.accent,
                                cancel: { queue.cancel(job.id) },
                                retry: {
                                    queue.retry(job.id)
                                    runner.attachPending(session: session, ai: ai)
                                },
                                remove: { queue.remove(job.id) }
                            )
                        }
                    }
                }
            }
            .padding(14)
            .nodusGlass(NodusGlass(.regular, tint: session.accent))
            .accessibilityIdentifier("deep-research-queue")
        }
    }

    private var galleryControls: some View {
        VStack(spacing: 10) {
            NodusSearchField(text: $query, prompt: "Search reports", accent: session.accent)
            HStack(spacing: 8) {
                Menu {
                    Picker("Reading state", selection: $galleryRead) {
                        Label("All", systemImage: "doc.text").tag("all")
                        Label("Unread", systemImage: "circle").tag("unread")
                        Label("Read", systemImage: "checkmark.circle.fill").tag("read")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(NodusGlassIconButtonStyle(accent: session.accent))
                .accessibilityLabel(readFilterLabel)

                Menu {
                    Picker("Sort reports", selection: $gallerySort) {
                        Text("Newest").tag("newest")
                        Text("Oldest").tag("oldest")
                        Text("Title").tag("title")
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .buttonStyle(NodusGlassIconButtonStyle(accent: session.accent))
                .accessibilityLabel(sortLabel)

                Picker("View", selection: $galleryView) {
                    Image(systemName: "square.grid.2x2").tag("grid")
                    Image(systemName: "list.bullet").tag("list")
                }
                .pickerStyle(.segmented)
                .frame(width: 92, height: 44)

                Button {
                    selecting.toggle()
                    if !selecting { selection.removeAll() }
                } label: {
                    Image(systemName: selecting ? "checkmark" : "checkmark.circle")
                }
                .buttonStyle(NodusGlassIconButtonStyle(accent: session.accent))
                .accessibilityLabel(selecting ? "Done" : "Select")
                Spacer(minLength: 0)
            }

            if selecting, !selection.isEmpty {
                HStack {
                    Text("\(selection.count) selected")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Menu {
                        Button { export(.markdown) } label: { Label("Markdown ZIP", systemImage: "doc.text") }
                        Button { export(.pdf) } label: { Label("PDF ZIP", systemImage: "doc.richtext") }
                        Button { export(.both) } label: { Label("Markdown + PDF ZIP", systemImage: "archivebox") }
                    } label: {
                        if isExporting { ProgressView().controlSize(.small) }
                        else { Label("Export", systemImage: "square.and.arrow.up") }
                    }
                    .disabled(isExporting)
                    .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share ZIP", systemImage: "paperplane")
                        }
                        .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
                    }
                    Button(role: .destructive) { deleteSelection() } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(NodusGlassButtonStyle(accent: Color.nodusDanger))
                }
            }
        }
    }

    @ViewBuilder
    private var gallery: some View {
        let entries = galleryEntries
        if entries.isEmpty, publishedError != nil {
            EmptyView()
        } else if entries.isEmpty {
            ContentUnavailableView(
                query.isEmpty ? "No reports" : "No matches",
                systemImage: "doc.text.magnifyingglass",
                description: Text(query.isEmpty ? "Start a research job to create the first report." : "Change the search or reading filter.")
            )
            .frame(maxWidth: .infinity, minHeight: 300)
            .accessibilityIdentifier("deep-research-catalog-empty")
        } else if galleryView == "grid" {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                ForEach(entries) { entry in galleryCell(entry, grid: true) }
            }
        } else {
            LazyVStack(spacing: 8) {
                ForEach(entries) { entry in galleryCell(entry, grid: false) }
            }
        }
    }

    @ViewBuilder
    private func galleryCell(_ entry: DeepResearchGalleryEntry, grid: Bool) -> some View {
        if selecting {
            Button { toggle(entry.id) } label: {
                DeepResearchGalleryCard(entry: entry, selected: selection.contains(entry.id), grid: grid, session: session)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                switch entry.origin {
                case .local(let saved): LocalReportReader(session: session, local: local, saved: saved)
                case .published(let row): PublishedReportReader(session: session, row: row)
                }
            } label: {
                DeepResearchGalleryCard(entry: entry, selected: false, grid: grid, session: session)
            }
            .buttonStyle(.plain)
        }
    }

    private var galleryEntries: [DeepResearchGalleryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var entries = local.reports.map { DeepResearchGalleryEntry(local: $0, imageURL: local.imageURL(for: $0), marks: marks) }
        entries += published.map { DeepResearchGalleryEntry(published: $0, marks: marks) }
        entries = entries.filter {
            (needle.isEmpty || $0.searchText.contains(needle)) &&
            (galleryRead == "all" || (galleryRead == "read") == $0.isRead)
        }
        switch gallerySort {
        case "oldest": entries.sort { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        case "title": entries.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        default: entries.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }
        return entries
    }

    private var readFilterLabel: String {
        switch galleryRead { case "read": String(localized: "Read"); case "unread": String(localized: "Unread"); default: String(localized: "All") }
    }

    private var sortLabel: String {
        switch gallerySort { case "oldest": String(localized: "Oldest"); case "title": String(localized: "Title"); default: String(localized: "Newest") }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func deleteSelection() {
        for entry in galleryEntries where selection.contains(entry.id) {
            guard case .local(let saved) = entry.origin else { continue }
            marks.forget(saved.id)
            local.delete(saved.id)
        }
        selection.removeAll()
        selecting = false
    }

    private func export(_ format: DeepResearchBulkExportFormat) {
        guard !isExporting else { return }
        isExporting = true
        exportURL = nil
        Task {
            do {
                var archiveEntries: [ZIPArchiveBuilder.Entry] = []
                for entry in galleryEntries where selection.contains(entry.id) {
                    let document = try await exportDocument(for: entry)
                    let stem = exportFilename(entry.title)
                    if format != .pdf {
                        archiveEntries.append(.init(filename: "\(stem).md", data: Data(document.markdown.utf8)))
                    }
                    if format != .markdown {
                        let pdf = try await ReportDocument.pdf(from: document.html)
                        archiveEntries.append(.init(filename: "\(stem).pdf", data: pdf))
                    }
                }
                let directory = URL.cachesDirectory.appendingPathComponent("deep-research-exports", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let output = directory.appendingPathComponent("Nodus Deep Research.zip")
                try ZIPArchiveBuilder.build(entries: archiveEntries, at: output)
                exportURL = output
            } catch {
                exportError = error.localizedDescription
            }
            isExporting = false
        }
    }

    private func exportDocument(for entry: DeepResearchGalleryEntry) async throws -> (markdown: String, html: String) {
        switch entry.origin {
        case .local(let saved):
            let markdown = saved.report.markdown
            return (markdown, try ReportDocument.html(saved: saved, store: local))
        case .published(let row):
            guard let id = row.string("id") else { throw DeepResearchExportFailure.missingReport }
            async let detail = session.client.deepResearchReport(id, in: session.connection.spaceId)
            async let html = ReportDocument.html(session: session, reportId: id)
            let resolved = try await detail
            guard let markdown = publishedMarkdown(resolved.report) else { throw DeepResearchExportFailure.missingReport }
            let resolvedHTML = try await html
            return (markdown, resolvedHTML)
        }
    }

    private func publishedMarkdown(_ row: Row) -> String? {
        let draft = (row.embeddedJSON("draft") ?? row["draft"])?.objectValue
        if let markdown = draft?["draftMarkdown"]?.stringValue, !markdown.isEmpty { return markdown }
        if let sections = draft?["sections"]?.arrayValue {
            let markdown = sections.compactMap { entry -> String? in
                guard let object = entry.objectValue,
                      let body = object["markdown"]?.stringValue ?? object["body"]?.stringValue ?? object["prose"]?.stringValue
                else { return nil }
                return object["title"]?.stringValue.map { "## \($0)\n\n\(body)" } ?? body
            }.joined(separator: "\n\n")
            if !markdown.isEmpty { return markdown }
        }
        return row.text("content") ?? row.text("markdown")
    }

    private func exportFilename(_ title: String) -> String {
        title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    private func loadPublished() async {
        do {
            let catalogue = try await session.client.deepResearchCatalogue(in: session.connection.spaceId)
            try Task.checkCancellation()
            published = catalogue.items
            publishedFromDevice = catalogue.fromDevice
            for row in published {
                guard let remoteId = row.string("id") else { continue }
                let localId = local.reports.first(where: { $0.vaultRowId == remoteId })?.id ?? remoteId
                marks.reconcileRead(localId: localId, remoteId: remoteId, readAt: row.date("read_at"))
            }
            publishedError = nil
        } catch let apiError as APIError where apiError.isNotPublished {
            published = []
            publishedFromDevice = false
            publishedError = nil
        } catch where error.isCancellation {
        } catch {
            publishedError = error.localizedDescription
        }
    }

    private func seedVisualFixtureIfNeeded() {
#if DEBUG
        guard ProcessInfo.processInfo.environment["NODUS_SHOW_TAB_DEMO"] == "1" else { return }
        if queue.jobs(in: session.connection.storageId).isEmpty {
            let queuedRequest = DeepResearchRequest(
                objective: "Contested meanings of sovereignty",
                targetLength: .standard,
                approach: .scholarlyDebate,
                model: ModelRef(provider: .openai, model: "gpt-5")
            )
            queue.enqueue(
                id: "visual-deep-research-complete-\(session.connection.storageId)",
                spaceId: session.connection.storageId,
                spaceName: session.connection.spaceName,
                request: queuedRequest
            ) {
                DeepResearchQueueResult(
                    savedReportId: "visual-deep-research-complete",
                    publicationNote: String(localized: "Saved locally and queued for the vault.")
                )
            }
        }
        guard local.reports.isEmpty else { return }
        let model = ModelRef(provider: .openai, model: "gpt-5")
        let samples = [
            ("Networks of correspondence in the early modern Atlantic", "Evidence and method", "Correspondence networks reveal how trust, credit and political information travelled between ports. The report distinguishes documented links from inferred proximity."),
            ("Genealogy of the public sphere", "Conceptual lineages", "The corpus supports several competing definitions of publicity. Their differences matter more than a single linear origin story.")
        ]
        for sample in samples {
            let section = DeepResearchSection(title: sample.1, prose: sample.2, citations: [], rejectedCitations: [])
            _ = local.save(
                DeepResearchReport(objective: sample.0, sections: [section], references: [], words: section.wordCount, pages: 1.0, citationsChecked: 12, citationsRejected: 0, stoppedReason: nil),
                mode: .research,
                model: model
            )
        }
#endif
    }

    /// What the hub's third seat opens onto, once there is a report to ask about.
    private var chatSubject: PageChatSubject? {
        guard let saved = runner.finished else { return nil }
        return PageChatSubject(id: saved.id, title: saved.report.objective, session: session)
    }

    // MARK: Resuming

    /// The sections a stopped run already paid for, if there are any.
    private func readCheckpoint() {
        let saved = DeepResearchCheckpointStore.load(spaceId: session.connection.storageId)
        unfinished = (saved?.isComplete == false) ? saved : nil
    }

    /// What a half-finished run looks like when you come back to it.
    ///
    /// The number of sections is the point: it is what the user already paid a model call each
    /// for, and resuming spends nothing on them a second time.
    private func resumeNotice(_ checkpoint: DeepResearchCheckpoint) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            NodusNotice(
                tone: .info,
                title: "An unfinished report",
                message: "“\(checkpoint.request.objective)” stopped after \(checkpoint.sections.count) of \(checkpoint.titles.count) sections. Carrying on writes only the ones that are missing.",
                systemImage: "hourglass"
            )
            HStack {
                Button {
                    resume(checkpoint)
                } label: {
                    Label("Carry on", systemImage: "play")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent))
                .disabled(ai.model(for: .deepResearch) == nil)

                Button(role: .destructive) {
                    DeepResearchCheckpointStore.clear(spaceId: session.connection.storageId)
                    unfinished = nil
                } label: {
                    Label("Discard", systemImage: "trash")
                }
                .font(.caption)
            }
        }
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text((mode ?? defaultMode) == .teachingUnit ? "Unit topic" : "Objective")
                .font(.subheadline.weight(.medium))
            TextField(
                (mode ?? defaultMode) == .teachingUnit
                    ? "What unit do you want to prepare from these materials"
                    : "What should it research in this corpus",
                text: $objective,
                axis: .vertical
            )
                .lineLimit(2...5)
                .textFieldStyle(.plain)
                .padding(13)
                .nodusFieldSurface(accent: session.accent)

            // Teaching vaults default to the unit pack, the way the desktop does
            // (`electron/ai/deepResearch.ts:39`), but it stays a choice: a teacher may well
            // want a plain report about their own materials.
            Picker("Mode", selection: Binding(
                get: { mode ?? defaultMode },
                set: { mode = $0 }
            )) {
                ForEach(DeepResearchMode.allCases, id: \.self) { option in
                    Text(LocalizedStringKey(option.label)).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Text(LocalizedStringKey((mode ?? defaultMode).explanation))
                .font(.caption).foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 10) {
                adaptiveMenu("Language", value: LocalizedStringKey(DeepResearchPromptLanguage.label(for: language))) {
                    ForEach(DeepResearchPromptLanguage.options, id: \.code) { option in
                        Button {
                            language = option.code
                        } label: {
                            if language == option.code { Label(option.label, systemImage: "checkmark") }
                            else { Text(option.label) }
                        }
                    }
                }
                adaptiveMenu("Model", value: LocalizedStringKey(chosenModel?.model ?? String(localized: "Not chosen"))) {
                    ForEach(modelChoices, id: \.self) { model in
                        Button {
                            selectedModel = model
                        } label: {
                            if model == chosenModel { Label(model.model, systemImage: "checkmark") }
                            else { Text("\(model.provider.label) · \(model.model)") }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Audience").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("Academic readers, students, general public…", text: $audience)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .nodusFieldSurface(accent: session.accent)
            }

            adaptiveMenu("Research approach", value: LocalizedStringKey(approach.label)) {
                ForEach(DeepResearchApproach.allCases) { option in
                    Button {
                        approach = option
                    } label: {
                        if option == approach {
                            Label(LocalizedStringKey(option.label), systemImage: "checkmark")
                        } else {
                            Text(LocalizedStringKey(option.label))
                        }
                    }
                }
            }

            Text(LocalizedStringKey(approach.explanation))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.top, -7)

            adaptiveMenu("Length", value: LocalizedStringKey(length.label)) {
                ForEach(DeepResearchLength.allCases, id: \.self) { option in
                    Button {
                        length = option
                    } label: {
                        if option == length {
                            Label(LocalizedStringKey(option.label), systemImage: "checkmark")
                        } else {
                            Text(LocalizedStringKey(option.label))
                        }
                    }
                }
            }

            // The desktop's own second control beside the length (`DeepResearchView.tsx:59-66`).
            // Length says how many pages; this says how they are divided, and the two are not
            // the same question — eight pages in four sections is a different document from
            // eight pages in ten.
            adaptiveMenu("Sections", value: LocalizedStringKey(sections.label)) {
                ForEach(DeepResearchSectionChoice.allCases) { option in
                    Button {
                        sections = option
                    } label: {
                        if option == sections {
                            Label(LocalizedStringKey(option.label), systemImage: "checkmark")
                        } else {
                            Text(LocalizedStringKey(option.label))
                        }
                    }
                }
            }

            illustrationControls

            if session.vaultType == .genealogy {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Focus person").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("Name or person identifier", text: $focusPerson)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .nodusFieldSurface(accent: session.accent)
                    Text("The focus narrows retrieval; every claim still requires a corpus citation.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if (mode ?? defaultMode) == .teachingUnit {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Teaching outline").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("One intended part per line", text: $teachingOutline, axis: .vertical)
                        .lineLimit(3...8)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .nodusFieldSurface(accent: session.accent)
                    Text("Optional: the corpus remains the only source of evidence.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            // A run is one model call per section plus planning. Saying so before the button
            // is pressed is the difference between a cost and a surprise.
            NodusNotice(
                tone: .info,
                title: LocalizedStringKey(costEstimate),
                message: "Each section is one model call. It keeps going if you leave this screen, and you can stop it at any point and keep what was written.",
                systemImage: "hourglass"
            )

            if ai.model(for: .deepResearch) == nil {
                NodusNotice(
                    tone: .caution,
                    title: "No model chosen",
                    message: "Choose one under Providers before starting.",
                    systemImage: "key"
                )
            }

            Button {
                start()
            } label: {
                Label((mode ?? defaultMode) == .teachingUnit ? "Generate the unit" : "Generate the report", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent))
            .disabled(objective.trimmingCharacters(in: .whitespaces).count < 8 || chosenModel == nil)
        }
        .padding(16)
        .nodusGlass(NodusGlass(.regular, tint: session.accent))
    }

    /// A desktop-style menu field whose selected value may wrap. The stock menu picker assumes
    /// one line and clipped the value at accessibility text sizes on a narrow iPhone.
    private func adaptiveMenu<Content: View>(
        _ title: LocalizedStringKey,
        value: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Menu {
                content()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(value)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tint(session.accent)
        }
        .padding(12)
        .nodusFieldSurface(accent: session.accent)
    }

    /// The cover, and only the questions that follow from wanting one.
    ///
    /// The style picker appears once the toggle is on, exactly as it does on the desktop
    /// (`DeepResearchView.tsx:1616-1627`): a list of twelve aesthetics beside a switch that is
    /// off is twelve choices about nothing.
    @ViewBuilder
    private var illustrationControls: some View {
        Toggle(isOn: $wantsIllustration) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Decorative image").font(.subheadline)
                Text("Drawn once, after the report is written.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .tint(session.accent)
        .disabled(ai.model(for: .image) == nil)

        if wantsIllustration {
            Picker("Style", selection: $imageStyle) {
                ForEach(DecorativeImageStyle.allCases, id: \.self) { style in
                    Text(LocalizedStringKey(style.label)).tag(style)
                }
            }
            .pickerStyle(.menu)
            .tint(session.accent)
        }

        if ai.model(for: .image) == nil {
            Text("Choose an image model under Providers to illustrate a report.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Docencia vaults open on the unit pack; everything else on the report.
    private var defaultMode: DeepResearchMode {
        session.vaultType == .docencia ? .teachingUnit : .research
    }

    private var costEstimate: String {
        let pages = DeepResearchLimits.targetPages(length, citableCount: 200)
        let plan = DeepResearchLimits.sectionPlan(pages: pages, requested: sections.limit)
        return "≈ \(plan.target) sections · \(pages.lowerBound)–\(pages.upperBound) pages"
    }

    private var modelChoices: [ModelRef] {
        var choices = ai.pinnedModels
        if let current = ai.model(for: .deepResearch), !choices.contains(current) { choices.insert(current, at: 0) }
        return choices
    }

    private var chosenModel: ModelRef? { selectedModel ?? ai.model(for: .deepResearch) }

    // MARK: Report

    private func reportView(_ saved: LocalReportStore.Saved) -> some View {
        let report = saved.report
        return VStack(alignment: .leading, spacing: 16) {
            if let url = local.imageURL(for: saved) {
                LocalReportImage(url: url)
            }

            VStack(alignment: .leading, spacing: 8) {
                PageText(report.objective, order: 0).font(.title3.weight(.semibold))
                HStack(spacing: 12) {
                    Label("\(report.words.formatted()) words", systemImage: "text.alignleft")
                    Label(String(format: "%.1f pp.", report.pages), systemImage: "doc")
                }
                .font(.caption).foregroundStyle(.secondary)

                // The number that matters. A run where the model invented sources is a run
                // whose prose is thinner than it looks, and hiding that would be the one
                // dishonest thing this screen could do.
                if report.citationsRejected > 0 {
                    NodusNotice(
                        tone: .caution,
                        title: "\(report.citationsRejected) invented citations, removed",
                        message: "Of \(report.citationsChecked) checked. Sentences that rested only on them are left unsupported.",
                        systemImage: "exclamationmark.triangle"
                    )
                } else if report.citationsChecked > 0 {
                    Label("\(report.citationsChecked) citations, all from the corpus", systemImage: "checkmark.seal")
                        .font(.caption).foregroundStyle(Color.nodusSuccess)
                }

                if let stopped = report.stoppedReason {
                    NodusNotice(tone: .caution, title: "The report is incomplete", message: LocalizedStringKey(stopped))
                }

                // `report.markdown` already opens with the objective as its heading, so the
                // listening copy is not given a title to prepend on top of it.
                //
                // The send control is built only for an access that may send changes, so a
                // read-only reader gets its absence rather than a control that refuses.
                ReportActions(
                    markdown: report.markdown,
                    title: nil,
                    send: sendContext,
                    accent: session.accent
                )
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(NodusSpace.cardPadding)
            .nodusGlass(NodusGlass(.regular, tint: session.accent))
            // Nought: the objective is the first thing on the page, and the sections number
            // themselves from one.
            .nodusSearchOrder(0)

            ReportBody(report: report, session: session)

            ShareLink(item: report.markdown) {
                Label("Share as Markdown", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
        }
    }

    /// What the send control needs, or nothing at all when this access cannot send.
    ///
    /// Read from `runner.finished` rather than from a copy this screen holds: the run outlives
    /// the screen, and the record is where "already sent" and the vault row id live.
    private var sendContext: ReportSendContext? {
        guard session.connection.role.canSendChanges, let saved = runner.finished else { return nil }
        return ReportSendContext(session: session, store: local, saved: saved)
    }

    // MARK: Run

    /// Pick up a run that stopped, on its own terms rather than on the form's.
    ///
    /// The checkpoint carries the request it was started with, so the objective, mode and
    /// length come from there — using whatever happens to be in the fields would resume a
    /// half-written report into a different question.
    private func resume(_ checkpoint: DeepResearchCheckpoint) {
        objective = checkpoint.request.objective
        length = checkpoint.request.targetLength
        mode = checkpoint.request.mode
        approach = checkpoint.request.resolvedApproach
        language = checkpoint.request.language
        audience = checkpoint.request.audience ?? ""
        selectedModel = checkpoint.request.model
        focusPerson = checkpoint.request.focusPerson ?? ""
        teachingOutline = checkpoint.request.teachingOutline ?? ""
        sections = DeepResearchSectionChoice(limit: checkpoint.request.sectionLimit)
        unfinished = nil
        runner.start(checkpoint.request, resuming: checkpoint, session: session, ai: ai)
        showingComposer = false
    }

    private func start() {
        guard let model = chosenModel else { return }
        unfinished = nil
        // No `sentReportId` to clear: whether a report has been sent is now a fact on the saved
        // record rather than a piece of this screen's memory, which is what lets the library
        // and a reopened report agree with the button.
        runner.start(
            DeepResearchRequest(
                objective: objective.trimmingCharacters(in: .whitespacesAndNewlines),
                language: language,
                audience: audience.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                targetLength: length,
                sectionLimit: sections.limit,
                mode: mode ?? defaultMode,
                approach: approach,
                model: model,
                illustration: wantsIllustration && ai.model(for: .image) != nil ? imageStyle : nil,
                focusPerson: focusPerson.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                teachingOutline: teachingOutline.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ),
            session: session,
            ai: ai
        )
        showingComposer = false
    }
}

private enum DeepResearchPromptLanguage {
    static let options: [(code: String, label: String)] = [
        ("es", "Español"), ("en", "English"), ("fr", "Français"), ("tr", "Türkçe"),
        ("de", "Deutsch"), ("pt", "Português"), ("pt-BR", "Português (Brasil)"), ("it", "Italiano")
    ]

    static func label(for code: String) -> String {
        options.first(where: { $0.code == code })?.label ?? code
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private enum DeepResearchBulkExportFormat { case markdown, pdf, both }

private enum DeepResearchExportFailure: LocalizedError {
    case missingReport
    var errorDescription: String? { String(localized: "The full report is unavailable.") }
}

struct DeepResearchGalleryEntry: Identifiable {
    enum Origin {
        case local(LocalReportStore.Saved)
        case published(Row)
    }

    enum Cover {
        case local(URL)
        case published(hash: String)
    }

    let id: String
    let title: String
    let subtitle: String
    let searchText: String
    let date: Date?
    let isRead: Bool
    let wordCount: Int?
    let citationCount: Int?
    let cover: Cover?
    let origin: Origin

    @MainActor
    init(local saved: LocalReportStore.Saved, imageURL: URL?, marks: ReportMarks) {
        id = "local:\(saved.id)"
        title = saved.title
        subtitle = saved.mode.label
        searchText = ([saved.title] + saved.report.sections.map(\.title)).joined(separator: " ").lowercased()
        date = saved.createdAt
        isRead = marks.isRead(saved.id)
        wordCount = saved.report.words
        citationCount = saved.report.citationsChecked - saved.report.citationsRejected
        cover = imageURL.map(Cover.local)
        origin = .local(saved)
    }

    @MainActor
    init(published row: Row, marks: ReportMarks) {
        let rowId = row.string("id") ?? UUID().uuidString
        id = "published:\(rowId)"
        title = row.text("title") ?? String(localized: "Report")
        subtitle = String(localized: "Published in the vault")
        searchText = [title, row.text("objective") ?? ""].joined(separator: " ").lowercased()
        date = row.date("created_at") ?? row.date("updated_at")
        isRead = marks.isRead(rowId)
        wordCount = row.int("word_count")
        citationCount = row.int("citations_checked")
        cover = row.embeddedJSON("image")?.objectValue?["hash"]?.stringValue.map { Cover.published(hash: $0) }
        origin = .published(row)
    }
}

private struct DeepResearchGalleryCard: View {
    let entry: DeepResearchGalleryEntry
    let selected: Bool
    let grid: Bool
    let session: SpaceSession

    private var accent: Color { session.accent }

    var body: some View {
        Group {
            if grid {
                VStack(alignment: .leading, spacing: 0) {
                    cover
                        .frame(maxWidth: .infinity)
                        .frame(height: 142)
                        .clipped()
                    details.padding(14)
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    cover
                        .frame(width: 96, height: 58)
                        .clipped()
                    details
                    Spacer(minLength: 0)
                }
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity, minHeight: grid ? 224 : 78, alignment: .topLeading)
        .nodusGlass(NodusGlass(selected ? .prominent : .regular, tint: accent))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var cover: some View {
        ZStack {
            LinearGradient(
                colors: [accent.opacity(0.2), accent.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            NodusIcon(name: "telescope", size: grid ? 30 : 20, weight: .medium)
                .foregroundStyle(accent.opacity(0.7))
            switch entry.cover {
            case .local(let url):
                LocalReportImage(url: url)
            case .published(let hash):
                AssetImage(session: session, hash: hash)
            case nil:
                EmptyView()
            }
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white, accent)
                    .padding(7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: grid ? 16 : 9, style: .continuous))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.title)
                .font(.subheadline.weight(entry.isRead ? .regular : .semibold))
                .foregroundStyle(entry.isRead ? Color.nodusSecondaryText : Color.primary)
                .lineLimit(grid ? 3 : 2)
            Text(entry.subtitle).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if let words = entry.wordCount { Label(words.formatted(), systemImage: "text.alignleft") }
                if let citations = entry.citationCount { Label(citations.formatted(), systemImage: "quote.opening") }
                if let date = entry.date { Text(date.formatted(date: .abbreviated, time: .omitted)) }
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DeepResearchQueueCard: View {
    let job: DeepResearchQueueJob
    let accent: Color
    let cancel: () -> Void
    let retry: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(statusLabel, systemImage: statusIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                Spacer()
                Menu {
                    if !job.status.isFinished {
                        Button(role: .destructive, action: cancel) { Label("Cancel", systemImage: "xmark") }
                    } else if job.status != .completed {
                        Button(action: retry) { Label("Retry", systemImage: "arrow.clockwise") }
                    }
                    if job.status.isFinished {
                        Button(role: .destructive, action: remove) { Label("Remove", systemImage: "trash") }
                    }
                } label: { Image(systemName: "ellipsis") }
                    .buttonStyle(.plain)
            }
            Text(job.title).font(.subheadline.weight(.medium)).lineLimit(2)
            if let progress = job.progress, !job.status.isFinished {
                ProgressView(value: progress.fraction).tint(accent)
                Text(progress.sectionTitle ?? progress.message)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else if let note = job.publicationNote {
                Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            } else if let error = job.errorMessage {
                Text(error).font(.caption2).foregroundStyle(Color.nodusDanger).lineLimit(2)
            }
        }
        .padding(12)
        .frame(width: 260, alignment: .topLeading)
        .frame(minHeight: 112, alignment: .topLeading)
        .background(Color.primary.opacity(0.035), in: NodusRadius.controlShape)
        .overlay(NodusRadius.controlShape.stroke(Color.primary.opacity(0.09), lineWidth: 1))
    }

    private var statusLabel: String {
        switch job.status {
        case .queued: String(localized: "Queued")
        case .running: String(localized: "Running")
        case .completed: String(localized: "Completed")
        case .failed: String(localized: "Failed")
        case .cancelled: String(localized: "Cancelled")
        }
    }

    private var statusIcon: String {
        switch job.status {
        case .queued: "clock"
        case .running: "sparkles"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .completed: Color.nodusSuccess
        case .failed: Color.nodusDanger
        case .cancelled: Color.nodusCaution
        default: accent.nodusReadable
        }
    }
}

/// How many sections the report is divided into.
///
/// The desktop's own list (`DEEP_SECTION_OPTIONS`, `DeepResearchView.tsx:59-66`): auto, or a
/// ceiling of four, five, six, eight or ten. A number is a ceiling with one section of grace,
/// never a quota — see `DeepResearchLimits.sectionPlan`.
enum DeepResearchSectionChoice: Hashable, Identifiable, CaseIterable {
    case automatic
    case atMost(Int)

    static let allCases: [DeepResearchSectionChoice] = [.automatic, .atMost(4), .atMost(5), .atMost(6), .atMost(8), .atMost(10)]

    init(limit: Int?) {
        self = limit.map { .atMost($0) } ?? .automatic
    }

    var id: String {
        switch self {
        case .automatic: return "auto"
        case .atMost(let count): return "\(count)"
        }
    }

    var limit: Int? {
        switch self {
        case .automatic: return nil
        case .atMost(let count): return count
        }
    }

    /// `String(localized:)` rather than a key, because one of the two interpolates a number:
    /// a `LocalizedStringKey` built from an already-interpolated string is looked up as
    /// "At most 6 sections" and found in no catalogue.
    var label: String {
        switch self {
        case .automatic: return String(localized: "Sections: automatic")
        case .atMost(let count): return String(localized: "At most \(count) sections")
        }
    }
}

/// What a run looks like while it is running, wherever it is shown.
///
/// Cancelling asks first. A run is one model call per section, so the tap that stops it is a tap
/// that spends nothing more and also finishes nothing — worth a sentence before it happens.
struct DeepResearchProgressCard: View {
    let objective: String
    let progress: DeepResearchProgress
    var isIllustrating = false
    let accent: Color
    let onCancel: () -> Void

    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(objective).font(.subheadline.weight(.medium)).lineLimit(2)
                Spacer()
                Button("Cancel") { confirming = true }
                    .font(.caption).tint(Color.nodusDanger)
            }

            if let fraction = progress.fraction {
                ProgressView(value: fraction).tint(accent)
            } else {
                ProgressView().tint(accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(isIllustrating ? String(localized: "Drawing the illustration") : progress.message)
                    .font(.callout)
                if let index = progress.sectionIndex, let total = progress.sectionTotal {
                    Text("Section \(index + 1) of \(total)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if progress.wordsSoFar > 0 {
                    Text("\(progress.wordsSoFar.formatted()) words · \(String(format: "%.1f", progress.pagesSoFar)) pages")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(NodusSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nodusGlass(NodusGlass(.regular, tint: accent))
        .nodusConfirmsCancelling($confirming, onCancel: onCancel)
    }
}

/// The one question asked before a run is stopped, worded the same wherever it is asked from.
extension View {
    func nodusConfirmsCancelling(_ isPresented: Binding<Bool>, onCancel: @escaping () -> Void) -> some View {
        alert("Stop this report?", isPresented: isPresented) {
            Button("Stop it", role: .destructive, action: onCancel)
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("The sections already written are kept, and you can carry on from there later. Nothing more will be spent.")
        }
    }
}
