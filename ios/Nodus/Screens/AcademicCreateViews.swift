import NodusKit
import NodusUI
import SwiftUI
import UniformTypeIdentifiers

struct WritingWorkshopMobileView: View {
    let session: SpaceSession

    @State private var tables: [String: [Row]] = [:]
    @State private var drafts: [AcademicWritingDraftSummary] = []
    @State private var selectedId: String?
    @State private var showingComposer = false
    @State private var loading = true
    @State private var message: String?
    @State private var error: String?

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
                            Button { selectedId = draft.id } label: {
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
                    if let selected { WritingDraftReader(draft: selected, session: session) }
                }
            }
            .padding(NodusSpace.page).frame(maxWidth: 1120).frame(maxWidth: .infinity)
            .nodusTopAnchor()
        }
        .nodusPageBackdrop(accent: session.accent)
        .accessibilityIdentifier("academic-writing")
        .task(id: session.publishedRevision) { await load() }
        .nodusSheet(isPresented: $showingComposer) {
            NavigationStack {
                WritingComposer(session: session, tables: tables) { status in
                    message = status; showingComposer = false
                }
            }.nodusModalClose(accent: session.accent)
        }
    }

    private func load() async {
        loading = true
        do {
            tables = try await session.client.snapshot(in: session.connection.spaceId).tables
            drafts = AcademicAuthoredProjection.writingDrafts(from: tables)
            if selectedId == nil { selectedId = drafts.first?.id }
            error = nil
        } catch { self.error = error.localizedDescription }
        loading = false
    }
}

private struct WritingDraftReader: View {
    let draft: AcademicWritingDraftSummary
    let session: SpaceSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.title).font(.title2.weight(.semibold))
                    if !draft.objective.isEmpty { Text(draft.objective).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer()
                ShareLink(item: draft.markdown) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(NodusGlassButtonStyle(accent: session.accent)).accessibilityLabel("Share Markdown")
                Button { UIPasteboard.general.string = draft.markdown } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(NodusGlassButtonStyle(accent: session.accent)).accessibilityLabel("Copy Markdown")
            }
            if !draft.abstract.isEmpty {
                Text(draft.abstract).font(.callout).foregroundStyle(.secondary).padding(12)
                    .background(session.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            }
            CorpusProse(draft.markdown, accent: session.accent, session: session)
                .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        .desktopContentRow(accent: session.accent)
    }
}

private struct WritingComposer: View {
    let session: SpaceSession
    let tables: [String: [Row]]
    let onQueued: (String) -> Void

    @State private var title = ""
    @State private var objective = ""
    @State private var kind = "literature_review"
    @State private var tone = "academic"
    @State private var selectedWorks: Set<String> = []
    @State private var selectedIdeas: Set<String> = []
    @State private var query = ""
    @State private var sending = false
    @State private var error: String?

    private var works: [Row] {
        filtered(tables["works"] ?? [], keys: ["title", "authors_json"])
    }
    private var ideas: [Row] {
        filtered(tables["ideas"] ?? [], keys: ["label", "statement"])
    }

    var body: some View {
        Form {
            Section("Brief") {
                TextField("Draft title", text: $title)
                TextField("Objective, argument or research question", text: $objective, axis: .vertical).lineLimit(3...7)
                Picker("Format", selection: $kind) {
                    Text("State of the question").tag("literature_review")
                    Text("Theoretical framework").tag("theoretical_framework")
                    Text("Debate synthesis").tag("debate")
                    Text("Gap justification").tag("gap_justification")
                    Text("Chapter section").tag("chapter_section")
                    Text("Research question").tag("research_question")
                }
                Picker("Tone", selection: $tone) {
                    Text("Academic").tag("academic"); Text("Synthetic").tag("synthetic")
                    Text("Critical").tag("critical"); Text("Exploratory").tag("exploratory")
                }
            }
            Section("Grounded material") {
                TextField("Filter published material", text: $query)
                DisclosureGroup("Works · \(selectedWorks.count) selected") {
                    ForEach(Array(works.prefix(80).enumerated()), id: \.offset) { _, row in
                        selectionRow(row.text("title") ?? row.string("nodus_id") ?? "Work", id: row.string("nodus_id"), selection: $selectedWorks)
                    }
                }
                DisclosureGroup("Ideas · \(selectedIdeas.count) selected") {
                    ForEach(Array(ideas.prefix(80).enumerated()), id: \.offset) { _, row in
                        selectionRow(row.text("label") ?? row.string("global_id") ?? "Idea", id: row.string("global_id"), selection: $selectedIdeas)
                    }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button { Task { await queue() } } label: {
                    HStack { Spacer(); if sending { ProgressView() } else { Label("Generate in Desktop", systemImage: "desktopcomputer") }; Spacer() }
                }
                .disabled(sending || objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isDemo || !session.connection.role.canSendChanges)
            }
        }
        .navigationTitle("New grounded draft").navigationBarTitleDisplayMode(.inline)
    }

    private func selectionRow(_ label: String, id: String?, selection: Binding<Set<String>>) -> some View {
        Button {
            guard let id else { return }
            if selection.wrappedValue.contains(id) { selection.wrappedValue.remove(id) } else { selection.wrappedValue.insert(id) }
        } label: {
            HStack { Text(label).foregroundStyle(.primary); Spacer(); Image(systemName: id.map(selection.wrappedValue.contains) == true ? "checkmark.circle.fill" : "circle").foregroundStyle(session.accent.nodusReadable) }
        }
    }

    private func filtered(_ rows: [Row], keys: [String]) -> [Row] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !needle.isEmpty else { return rows }
        return rows.filter { row in keys.compactMap { row.text($0) }.joined(separator: " ").localizedLowercase.contains(needle) }
    }

    private func queue() async {
        sending = true; defer { sending = false }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let keySource = "\(kind)|\(objective)|\(selectedWorks.sorted())|\(selectedIdeas.sorted())|\(session.publishedRevision ?? "local")"
        do {
            _ = try await session.client.createSpaceAction(
                idempotencyKey: "writing:\(stableActionFingerprint(keySource))", kind: .writingGenerate,
                payload: [
                    "title": .string(normalizedTitle.isEmpty ? "Grounded draft" : normalizedTitle),
                    "kind": .string(kind), "objective": .string(objective), "tone": .string(tone), "language": .string("es"),
                    "workIds": .array(selectedWorks.sorted().map(JSONValue.string)),
                    "ideaIds": .array(selectedIdeas.sorted().map(JSONValue.string)),
                ],
                inputRevision: session.publishedRevision, in: session.connection.spaceId
            )
            onQueued("Generation queued once. It will appear here after Desktop saves and publishes the draft.")
        } catch { self.error = error.localizedDescription }
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
                    .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
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
            message = "Section update queued once for Desktop."
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
            message = "Chapter import queued once. Desktop will version it and link it to the manuscript."
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
