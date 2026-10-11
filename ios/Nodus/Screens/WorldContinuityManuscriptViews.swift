import Foundation
import NodusKit
import NodusUI
import SwiftUI

struct WorldContinuityView: View {
    let session: SpaceSession

    @State private var findings: [WorldbuildingParity.ContinuityFinding] = []
    @State private var muted = Set<String>()
    @State private var loading = true
    @State private var runningDesktop = false
    @State private var message: String?
    @State private var error: String?
    @State private var outbox: OutboxController?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                DesktopPageHeader(
                    title: "Continuity",
                    subtitle: "Immediate portable checks plus the canonical Desktop audit",
                    systemImage: "checkmark.seal",
                    accent: session.accent,
                    trailing: {
                        Button { Task { await runDesktop() } } label: {
                            if runningDesktop { ProgressView() } else { Label("Full audit", systemImage: "desktopcomputer") }
                        }
                        .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent))
                        .disabled(runningDesktop || session.isDemo || !session.connection.role.canSendChanges)
                    }
                )
                if let message { NodusNotice(tone: .info, title: "Continuity audit", message: LocalizedStringKey(message)) }
                if let error { NodusNotice(tone: .blocked, title: "Could not check continuity", message: LocalizedStringKey(error)) }
                HStack(spacing: 8) {
                    metric("Errors", findings.filter { $0.severity == .error }.count, .red)
                    metric("Warnings", findings.filter { $0.severity == .warning }.count, .orange)
                    metric("Notes", findings.filter { $0.severity == .info }.count, session.accent)
                    metric("Muted", muted.count, .secondary)
                }
                if loading { HStack { Spacer(); ProgressView().tint(session.accent); Spacer() }.padding(42) }
                else if findings.isEmpty {
                    ContentUnavailableView(
                        "No active findings", systemImage: "checkmark.seal.fill",
                        description: Text("The portable checks found no unresolved chronology, thread, rule or blocking-question issues.")
                    ).padding(.vertical, 42)
                } else {
                    ForEach(findings) { finding in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(alignment: .top) {
                                Image(systemName: icon(finding.severity)).foregroundStyle(color(finding.severity)).font(.title3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(finding.headline).font(.headline)
                                    Text(finding.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Spacer()
                                Button { Task { await mute(finding) } } label: { Label("Mute", systemImage: "speaker.slash") }
                                    .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
                                    .disabled(outbox == nil)
                            }
                            ScrollView(.horizontal) {
                                HStack { ForEach(finding.subjectIds, id: \.self) { NodusChip($0, tint: color(finding.severity), capitalises: false) } }
                            }.scrollIndicators(.hidden)
                        }
                        .desktopContentRow(accent: color(finding.severity))
                    }
                }
                if !muted.isEmpty {
                    DisclosureGroup("Muted findings · \(muted.count)") {
                        ForEach(muted.sorted(), id: \.self) { fingerprint in
                            HStack { Text(fingerprint).font(.caption.monospaced()).lineLimit(2); Spacer(); Button("Restore") { Task { await unmute(fingerprint) } } }
                                .padding(.vertical, 5)
                        }
                    }.desktopContentRow(accent: .secondary)
                }
            }
            .padding(NodusSpace.page).frame(maxWidth: 1050).frame(maxWidth: .infinity).nodusTopAnchor()
        }
        .nodusPageBackdrop(accent: session.accent)
        .accessibilityIdentifier("world-continuity")
        .task(id: session.publishedRevision) { await load() }
    }

    private func metric(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(value.formatted()).font(.title2.weight(.semibold).monospacedDigit()); Text(label).font(.caption).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, alignment: .leading).desktopContentRow(accent: color)
    }

    private func icon(_ severity: WorldbuildingParity.ContinuityFinding.Severity) -> String {
        switch severity { case .info: "info.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .error: "xmark.octagon.fill" }
    }
    private func color(_ severity: WorldbuildingParity.ContinuityFinding.Severity) -> Color {
        switch severity { case .info: session.accent; case .warning: .orange; case .error: .red }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            let tables = try await worldTables(session, ["world_scenes", "world_threads", "world_beats", "world_rules", "world_questions", "world_notice_mutes"])
            muted = Set((tables["world_notice_mutes"] ?? []).compactMap { $0.string("fingerprint") })
            findings = WorldbuildingParity.continuity(
                scenes: tables["world_scenes"] ?? [], threads: tables["world_threads"] ?? [],
                beats: tables["world_beats"] ?? [], rules: tables["world_rules"] ?? [],
                questions: tables["world_questions"] ?? [], mutedFingerprints: muted
            )
            if outbox == nil { outbox = await OutboxController.open(session: session) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func runDesktop() async {
        runningDesktop = true; defer { runningDesktop = false }
        do {
            let creation = try await session.client.createSpaceAction(
                idempotencyKey: "continuity:\(session.connection.spaceId):\(session.publishedRevision ?? "local")",
                kind: .worldbuildingContinuity, payload: [:], inputRevision: session.publishedRevision,
                executionMode:session.aiExecutionMode.rawValue, in:session.connection.spaceId
            )
            message = creation.action.receiptMessage
        } catch { self.error = error.localizedDescription }
    }

    private func mute(_ finding: WorldbuildingParity.ContinuityFinding) async {
        guard let outbox else { return }
        let now = ISO8601DateFormatter.nodusFractional.string(from: Date())
        let subjects = finding.subjectIds.map { ["kind": finding.subjectKind, "id": $0] }
        let subjectData = try? JSONSerialization.data(withJSONObject: subjects, options: [.sortedKeys])
        let subjectJSON = subjectData.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let row: [String: JSONValue] = [
            "fingerprint": .string(finding.id), "check_id": .string(finding.checkId),
            "scope": .string("finding"), "subjects": .string(subjectJSON),
            "headline": .string(finding.headline), "reason_code": .string("deliberate"),
            "created_at": .string(now), "updated_at": .string(now),
        ]
        muted.insert(finding.id); findings.removeAll { $0.id == finding.id }
        _ = await outbox.syncMutation(kind: .upsert, table: .worldNoticeMutes, key: [finding.id], row: row, title: "Mute continuity finding")
    }

    private func unmute(_ fingerprint: String) async {
        guard let outbox else { return }
        muted.remove(fingerprint)
        _ = await outbox.syncMutation(kind: .delete, table: .worldNoticeMutes, key: [fingerprint], title: "Restore continuity finding")
        await load()
    }
}

struct WorldManuscriptView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let session: SpaceSession

    @State private var scenes: [WorldbuildingParity.ManuscriptScene] = []
    @State private var sceneRows: [String: Row] = [:]
    @State private var textRows: [String: Row] = [:]
    @State private var chapterRows: [String: Row] = [:]
    @State private var bookRows: [String: Row] = [:]
    @State private var supportTables: [String: [Row]] = [:]
    @State private var selectedId: String?
    @State private var draft = ""
    @State private var loading = true
    @State private var saving = false
    @State private var message: String?
    @State private var error: String?
    @State private var outbox: OutboxController?
    @State private var structureEditor = false
    @State private var compactPane = ProcessInfo.processInfo.environment["NODUS_MANUSCRIPT_PANE"] == "scene" ? 1 : 0

    private var selected: WorldbuildingParity.ManuscriptScene? { scenes.first { $0.id == selectedId } ?? scenes.first }
    private var totalWords: Int { scenes.reduce(0) { $0 + $1.wordCount } }
    private var exportMarkdown: String {
        scenes.map { scene in
            var parts: [String] = []
            if let book = scene.bookTitle { parts.append("# \(book)") }
            if let chapter = scene.chapterTitle { parts.append("## \(chapter)") }
            parts.append("### \(scene.title)\n\n\(scene.text)")
            return parts.joined(separator: "\n\n")
        }.joined(separator: "\n\n---\n\n")
    }

    var body: some View {
        GeometryReader { geometry in
            // An iPad retains a regular size class even when its sidebar or
            // window leaves too little room for all three Desktop panes.
            let showsThreePanes = geometry.size.width >= 1_100 && !dynamicTypeSize.isAccessibilitySize
            VStack(spacing: 0) {
                header
                Divider()
                if showsThreePanes {
                    HStack(spacing: 0) {
                        sceneList.frame(width: 310)
                        Divider()
                        editor
                        Divider()
                        inspector.frame(width: 330)
                    }
                } else {
                    VStack(spacing: 0) {
                        compactSelector
                        Divider()
                        if compactPane == 0 { editor }
                        else { inspector }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .nodusPageBackdrop(accent: session.accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("world-manuscript")
        .task(id: session.publishedRevision) { await load() }
        .onChange(of: selectedId) { _, _ in selectDraft() }
        .nodusSheet(isPresented: $structureEditor) {
            if let selected {
                NavigationStack {
                    ManuscriptStructureEditor(
                        scene: selected, accent: session.accent,
                        onSave: { chapter, book, target in Task { await saveStructure(chapter: chapter, book: book, targetWords: target) } }
                    )
                }.nodusModalClose(accent: session.accent)
            }
        }
    }

    private var header: some View {
        DesktopPageHeader(
            title: "Manuscript", subtitle: "\(totalWords.formatted()) words · \(scenes.count) scenes",
            systemImage: "square.and.pencil", accent: session.accent,
            trailing: {
                HStack(spacing: 8) {
                    ShareLink(item: exportMarkdown) { manuscriptActionLabel("Export", systemImage: "square.and.arrow.up") }
                        .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
                        .accessibilityLabel("Export manuscript")
                    Button { structureEditor = true } label: { manuscriptActionLabel("Structure", systemImage: "rectangle.split.3x1") }
                        .buttonStyle(NodusGlassButtonStyle(accent: session.accent)).disabled(selected == nil)
                        .accessibilityLabel("Edit manuscript structure")
                    Button { Task { await save() } } label: {
                        if saving { ProgressView() } else { manuscriptActionLabel("Save", systemImage: "checkmark") }
                    }
                    .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent)).disabled(selected == nil || saving || outbox == nil)
                    .accessibilityLabel("Save manuscript scene")
                }
            }
        ).padding(NodusSpace.page)
    }

    @ViewBuilder
    private func manuscriptActionLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        if sizeClass == .compact {
            Image(systemName: systemImage).frame(minWidth: 18, minHeight: 18)
        } else {
            Label(title, systemImage: systemImage)
        }
    }

    private var sceneList: some View {
        ScrollView {
            LazyVStack(spacing: 5) {
                ForEach(scenes) { scene in
                    Button { selectedId = scene.id } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            if let book = scene.bookTitle { Text(book.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(session.accent.nodusReadable) }
                            if let chapter = scene.chapterTitle { Text(chapter).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                            Text(scene.title).font(.callout.weight(scene.id == selected?.id ? .semibold : .regular)).lineLimit(2)
                            HStack { NodusChip(key: scene.status, tint: session.accent); Spacer(); Text("\(scene.wordCount.formatted()) words").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                        }.desktopContentRow(accent: scene.id == selected?.id ? session.accent : .secondary)
                    }.buttonStyle(NodusCardButtonStyle())
                }
            }.padding(10)
        }.background(Color(uiColor: .secondarySystemBackground).opacity(0.48))
    }

    private var compactSelector: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Scene", selection: Binding(get: { selected?.id ?? "" }, set: { selectedId = $0 })) {
                    ForEach(scenes) { Text("\(sceneNumber($0)). \($0.title)").tag($0.id) }
                }.pickerStyle(.menu)
                Spacer()
                if let selected { Text("\(selected.wordCount.formatted()) words").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            Picker("Manuscript pane", selection: $compactPane) {
                Label("Write", systemImage: "text.cursor").tag(0)
                Label("Scene", systemImage: "sidebar.right").tag(1)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Manuscript pane")
            .accessibilityIdentifier("world-manuscript-pane")
        }.padding(.horizontal, NodusSpace.page).padding(.vertical, 8)
    }

    @ViewBuilder
    private var inspector: some View {
        if let selected {
            WorldManuscriptInspector(
                session: session, scene: selected, draft: $draft, tables: $supportTables,
                outbox: outbox, onTextChanged: { row in
                    textRows[selected.id] = row
                    rebuild()
                }
            )
            .accessibilityIdentifier("world-manuscript-inspector")
        } else {
            ContentUnavailableView("No scene selected", systemImage: "sidebar.right")
        }
    }

    private var editor: some View {
        Group {
            if let selected {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selected.title).font(.title2.weight(.semibold))
                        HStack { if let book = selected.bookTitle { NodusChip(book, tint: session.accent, capitalises: false) }; if let chapter = selected.chapterTitle { NodusChip(chapter, tint: .secondary, capitalises: false) }; NodusChip(key: selected.status, tint: session.accent) }
                        if let summary = selected.summary { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    }
                    if let message { Text(message).font(.caption).foregroundStyle(session.accent.nodusReadable) }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    TextEditor(text: $draft)
                        .font(.system(.body, design: .serif)).lineSpacing(5).scrollContentBackground(.hidden)
                        .padding(14).background(Color(uiColor: .secondarySystemBackground).opacity(0.62), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .bottomTrailing) { Text("\(WorldbuildingParity.wordCount(draft).formatted()) words").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).padding(12) }
                }.padding(NodusSpace.page)
            } else if loading { ProgressView().tint(session.accent) }
            else { ContentUnavailableView("No scenes", systemImage: "doc.text", description: Text("Create a scene first; its prose becomes the manuscript.")) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sceneNumber(_ scene: WorldbuildingParity.ManuscriptScene) -> Int { (scenes.firstIndex(of: scene) ?? 0) + 1 }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            let tables = try await worldTables(session, [
                "world_scenes", "world_scene_text", "world_chapter_breaks", "world_manuscript_starts",
                "world_scene_snapshots", "world_threads", "thread_parties", "world_beats",
                "world_rules", "world_questions", "scene_characters", "world_notice_mutes",
            ])
            supportTables = tables
            sceneRows = keyed(tables["world_scenes"] ?? [], "scene_id")
            textRows = keyed(tables["world_scene_text"] ?? [], "scene_id")
            chapterRows = keyed(tables["world_chapter_breaks"] ?? [], "scene_id")
            bookRows = keyed(tables["world_manuscript_starts"] ?? [], "scene_id")
            rebuild()
            if selectedId == nil { selectedId = scenes.first?.id }
            selectDraft()
            if outbox == nil { outbox = await OutboxController.open(session: session) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func rebuild() {
        scenes = WorldbuildingParity.manuscript(
            scenes: Array(sceneRows.values), texts: Array(textRows.values),
            chapters: Array(chapterRows.values), books: Array(bookRows.values)
        )
    }
    private func selectDraft() { draft = selected.map { textRows[$0.id]?.string("text") ?? $0.text } ?? "" }
    private func keyed(_ rows: [Row], _ field: String) -> [String: Row] { Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.string(field).map { ($0, row) } }) }

    private func save() async {
        guard let scene = selected, let outbox else { return }
        saving = true; defer { saving = false }
        let now = ISO8601DateFormatter.nodusFractional.string(from: Date())
        let old = textRows[scene.id]
        let oldText = old?.string("text") ?? ""
        let oldCount = WorldbuildingParity.wordCount(oldText)
        let newCount = WorldbuildingParity.wordCount(draft)
        if oldCount > 80 && newCount < Int(Double(oldCount) * 0.7) { await snapshot(scene: scene, text: oldText, reason: "shrink", outbox: outbox) }
        let row: [String: JSONValue] = [
            "scene_id": .string(scene.id), "text": .string(draft), "word_count": .int(Int64(newCount)),
            "created_at": old?["created_at"] ?? .string(now), "updated_at": .string(now),
        ]
        textRows[scene.id] = Row(row); rebuild()
        _ = await outbox.syncMutation(kind: .upsert, table: .worldSceneText, key: [scene.id], row: row, title: "Save scene \(scene.title)")
        message = outbox.lastError == nil ? String(localized: "Saved to the sync outbox.") : String(localized: "Saved locally; sync will retry.")
    }

    private func snapshot(scene: WorldbuildingParity.ManuscriptScene, text: String, reason: String, outbox: OutboxController) async {
        let id = UUID().uuidString
        let row: [String: JSONValue] = [
            "snapshot_id": .string(id), "scene_id": .string(scene.id), "text": .string(text),
            "word_count": .int(Int64(WorldbuildingParity.wordCount(text))), "reason": .string(reason),
            "created_at": .string(ISO8601DateFormatter.nodusFractional.string(from: Date())),
        ]
        _ = await outbox.syncMutation(kind: .upsert, table: .worldSceneSnapshots, key: [id], row: row, title: "Snapshot \(scene.title)")
    }

    private func saveStructure(chapter: String, book: String, targetWords: Int?) async {
        guard let scene = selected, let outbox else { return }
        let now = ISO8601DateFormatter.nodusFractional.string(from: Date())
        if chapter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chapterRows[scene.id] = nil
            _ = await outbox.syncMutation(kind: .delete, table: .worldChapterBreaks, key: [scene.id], title: "Remove chapter break")
        } else {
            let old = chapterRows[scene.id]
            let row: [String: JSONValue] = ["scene_id": .string(scene.id), "title": .string(chapter), "created_at": old?["created_at"] ?? .string(now), "updated_at": .string(now)]
            chapterRows[scene.id] = Row(row)
            _ = await outbox.syncMutation(kind: .upsert, table: .worldChapterBreaks, key: [scene.id], row: row, title: "Set chapter break")
        }
        if book.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            bookRows[scene.id] = nil
            _ = await outbox.syncMutation(kind: .delete, table: .worldManuscriptStarts, key: [scene.id], title: "Remove book start")
        } else {
            let old = bookRows[scene.id]
            var row: [String: JSONValue] = ["scene_id": .string(scene.id), "title": .string(book), "created_at": old?["created_at"] ?? .string(now), "updated_at": .string(now)]
            if let targetWords { row["target_words"] = .int(Int64(targetWords)) }
            bookRows[scene.id] = Row(row)
            _ = await outbox.syncMutation(kind: .upsert, table: .worldManuscriptStarts, key: [scene.id], row: row, title: "Set manuscript start")
        }
        rebuild(); structureEditor = false
    }
}

/// The same authored context rail as Desktop's manuscript: threads, rules, questions,
/// continuity and recoverable prose operations. iPad keeps it beside the editor; iPhone
/// reaches this exact view through the compact Write/Scene switch rather than losing it.
private struct WorldManuscriptInspector: View {
    @Environment(AISettings.self) private var ai
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let session: SpaceSession
    let scene: WorldbuildingParity.ManuscriptScene
    @Binding var draft: String
    @Binding var tables: [String: [Row]]
    let outbox: OutboxController?
    let onTextChanged: (Row) -> Void

    @State private var creatingKind: String?
    @State private var newThreadTitle = ""
    @State private var reviewRows: [ReviewRow] = []
    @State private var reviewMessage: String?
    @State private var reviewing = false
    @State private var reviewTask: Task<Void, Never>?
    @State private var activeReviewKey: String?
    private var proseBaseRequest: JSONValue { CompanionAcademicGeneration.sourceRequest(kind: "prose", scene: scene.id, language: CompanionAcademicGeneration.language) }
    private var proseDraft: JSONValue {
        .object(["sceneTitle": .string(scene.title), "text": .string(draft), "beats": .array(beats.map { beat in
            let kind = beat.string("thread_kind") ?? "", id = beat.string("thread_id") ?? ""
            let table = kind == "rule" ? "world_rules" : "world_threads", field = kind == "rule" ? "rule_id" : "thread_id"
            let title = (tables[table] ?? []).first { $0.string(field) == id }?.text("title") ?? beat.text("thread_title") ?? id
            return .object(["threadKind": .string(kind), "threadId": .string(id), "threadTitle": .string(title),
                "mark": .string(beat.string("mark") ?? ""), "text": beat.text("text").map(JSONValue.string) ?? .null])
        })])
    }
    private var proseRequest: JSONValue { CompanionAcademicGeneration.sourceRequest(kind: "prose", scene: scene.id, language: CompanionAcademicGeneration.language, draft: proseDraft) }

    private struct ReviewRow: Identifiable {
        let id: String
        let title: String
        let mark: String
        let present: Bool?
        let note: String?
    }

    private var beats: [Row] { (tables["world_beats"] ?? []).filter { $0.string("scene_id") == scene.id } }
    private var castIds: Set<String> {
        Set((tables["scene_characters"] ?? []).filter { $0.string("scene_id") == scene.id }.compactMap { $0.string("person_id") })
    }
    private var partyThreadIds: Set<String> {
        Set((tables["thread_parties"] ?? []).filter { row in
            row.string("party_kind") == "character" && row.string("party_id").map(castIds.contains) == true
        }.compactMap { $0.string("thread_id") })
    }
    private var relevantThreads: [Row] {
        let moved = Set(beats.filter { $0.string("thread_kind") != "rule" }.compactMap { $0.string("thread_id") })
        return (tables["world_threads"] ?? []).filter { row in
            row.string("status") != "archived" && row.string("thread_id").map { moved.contains($0) || partyThreadIds.contains($0) } == true
        }.sorted { ($0.text("title") ?? "") < ($1.text("title") ?? "") }
    }
    private var rules: [Row] {
        let judged = Set(beats.filter { $0.string("thread_kind") == "rule" }.compactMap { $0.string("thread_id") })
        return (tables["world_rules"] ?? []).filter { row in
            row.string("rule_id").map { judged.contains($0) } == true || row.string("status") != "archived"
        }
    }
    private var questions: [Row] {
        (tables["world_questions"] ?? []).filter {
            $0.string("status") == "open" && $0.string("anchor_kind") == "scene" && $0.string("anchor_id") == scene.id
        }
    }
    private var snapshots: [Row] {
        (tables["world_scene_snapshots"] ?? []).filter { $0.string("scene_id") == scene.id }
            .sorted { ($0.string("created_at") ?? "") > ($1.string("created_at") ?? "") }
    }
    private var continuityCount: Int {
        WorldbuildingParity.continuity(
            scenes: tables["world_scenes"] ?? [], threads: tables["world_threads"] ?? [],
            beats: tables["world_beats"] ?? [], rules: tables["world_rules"] ?? [],
            questions: tables["world_questions"] ?? [],
            mutedFingerprints: Set((tables["world_notice_mutes"] ?? []).compactMap { $0.string("fingerprint") })
        ).filter { $0.subjectIds.contains(scene.id) }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !questions.isEmpty {
                    inspectorSection("Open decisions", systemImage: "questionmark.circle") {
                        ForEach(questions, id: \.columns) { question in
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: question.bool("blocking") == true ? "exclamationmark.circle.fill" : "questionmark.circle")
                                    .foregroundStyle(question.bool("blocking") == true ? .orange : session.accent.nodusReadable)
                                Text(question.text("question") ?? "Open question").font(.caption).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if continuityCount > 0 {
                    NodusNotice(
                        tone: .caution, title: "Continuity · \(continuityCount)",
                        message: "This scene participates in active continuity findings. Open Continuity for the full evidence."
                    )
                }
                threadsSection
                rulesSection
                workbenchSection
            }
            .padding(12)
        }
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.35))
        .accessibilityIdentifier("world-manuscript-inspector")
        .accessibilityElement(children: .contain)
    }

    private var threadsSection: some View {
        inspectorSection("What moves here", systemImage: "point.3.connected.trianglepath.dotted") {
            HStack(spacing: 7) {
                creationButton("Conflict", kind: "conflict")
                creationButton("Arc", kind: "arc")
            }
            if let creatingKind {
                HStack(spacing: 6) {
                    TextField(creatingKind == "arc" ? "What changes, and in whom" : "Who wants what against whom", text: $newThreadTitle)
                        .textFieldStyle(.roundedBorder).font(.caption)
                    Button("Create") { Task { await createThread(kind: creatingKind) } }
                        .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent))
                        .disabled(newThreadTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || outbox == nil)
                }
            }
            if relevantThreads.isEmpty {
                Text("Conflicts and arcs involving this scene's cast appear here. Create one and the scene starts counting toward it.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(relevantThreads, id: \.columns) { thread in threadRow(thread) }
            }
        }
    }

    private func creationButton(_ title: LocalizedStringKey, kind: String) -> some View {
        Button { creatingKind = creatingKind == kind ? nil : kind } label: { Label(title, systemImage: "plus") }
            .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
            .frame(maxWidth: .infinity)
            .disabled(outbox == nil)
    }

    private func threadRow(_ thread: Row) -> some View {
        let kind = thread.string("kind") ?? "conflict"
        let id = thread.string("thread_id") ?? ""
        let current = beat(kind: kind, id: id)
        let marks = kind == "arc" ? ["step", "turn"] : ["raise", "turn", "ease", "resolve"]
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                Text(thread.text("title") ?? "Untitled").font(.caption.weight(.semibold))
                Spacer()
                NodusChip(key: kind, tint: session.accent)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 200 : 110), spacing: 5)], spacing: 5) {
                ForEach(marks, id: \.self) { mark in
                    Button(LocalizedStringKey(mark.capitalized)) { Task { await setBeat(kind: kind, id: id, mark: current?.string("mark") == mark ? nil : mark) } }
                        .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle).tint(session.accent)
                        .font(.caption2).lineLimit(1).frame(minHeight: 44).contentShape(Rectangle()).disabled(outbox == nil)
                }
            }
            if let text = current?.text("text") { Text(text).font(.caption2).foregroundStyle(.secondary) }
        }.desktopContentRow(accent: current == nil ? .secondary : session.accent)
    }

    private var rulesSection: some View {
        inspectorSection("Rules in play", systemImage: "lock") {
            if rules.isEmpty { Text("No authored rules are in play.").font(.caption2).foregroundStyle(.secondary) }
            ForEach(rules, id: \.columns) { rule in ruleRow(rule) }
        }
    }

    private func ruleRow(_ rule: Row) -> some View {
        let id = rule.string("rule_id") ?? ""
        let current = beat(kind: "rule", id: id)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                Text(rule.text("title") ?? "Untitled rule").font(.caption.weight(.semibold))
                Spacer()
                Text((rule.string("hardness") ?? "rule").capitalized).font(.caption2).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 200 : 110), spacing: 5)], spacing: 5) {
                ForEach(["obeys", "bends", "breaks", "establishes"], id: \.self) { mark in
                    Button(LocalizedStringKey(mark.capitalized)) { Task { await setBeat(kind: "rule", id: id, mark: current?.string("mark") == mark ? nil : mark) } }
                        .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle).tint(session.accent)
                        .font(.caption2).lineLimit(1).frame(minHeight: 44).contentShape(Rectangle()).disabled(outbox == nil)
                }
            }
            if current?.string("mark") == "breaks" {
                HStack {
                    Text("Price on the page?").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    paidButton("Yes", value: true, beat: current!)
                    paidButton("No", value: false, beat: current!)
                }
            }
        }.desktopContentRow(accent: current == nil ? .secondary : session.accent)
    }

    private func paidButton(_ title: LocalizedStringKey, value: Bool, beat row: Row) -> some View {
        Button(title) { Task { await setPaid(value: row["paid"]?.boolValue == value ? nil : value, row: row) } }
            .buttonStyle(.bordered).tint(value ? session.accent : .orange).font(.caption2).disabled(outbox == nil)
    }

    private var workbenchSection: some View {
        inspectorSection("The written scene", systemImage: "doc.text.magnifyingglass") {
            HStack(spacing: 7) {
                Button { Task { await takeSnapshot(reason: "manual") } } label: { Label("Snapshot", systemImage: "camera") }
                    .buttonStyle(NodusGlassButtonStyle(accent: session.accent)).disabled(outbox == nil)
                Button { reviewTask = Task { defer { reviewTask = nil }; await reviewProse() } } label: {
                    if reviewing { ProgressView() } else { Label("On the page?", systemImage: "sparkles") }
                }
                .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
                .disabled(reviewing || session.isDemo || !session.connection.role.canSendChanges)
            }
            if reviewing { Button("Cancelar revisión") { cancelReview() }.font(.caption) }
            if session.connection.desktopPairingId != nil { CompanionAcademicDownloadButton(session: session, request: proseBaseRequest) }
            Text("La revisión consulta el texto y los latidos actuales de esta escena.").font(.caption2).foregroundStyle(.secondary)
            if let reviewMessage { Text(reviewMessage).font(.caption2).foregroundStyle(.secondary) }
            ForEach(reviewRows) { review in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(review.present == nil ? "·" : review.present == true ? "✓" : "✗") \(review.title) — \(review.mark)")
                        .font(.caption).foregroundStyle(review.present == false ? .orange : .primary)
                    if let note = review.note { Text(note).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            if !snapshots.isEmpty {
                Divider()
                ForEach(snapshots.prefix(5), id: \.columns) { snapshot in
                    HStack(spacing: 7) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.string("created_at") ?? "Snapshot").font(.caption2).lineLimit(1)
                            Text("\((snapshot.int("word_count") ?? 0).formatted()) words · \(snapshot.string("reason") ?? "manual")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") { Task { await restore(snapshot) } }.font(.caption).disabled(outbox == nil)
                    }
                }
            }
        }
        .task(id: "\(scene.id):\(session.companionResultRevision):\(session.companionPublicationRevision)") {
            guard session.connection.desktopPairingId != nil else { return }
            do { if let saved = try await CompanionAcademicGeneration.saved(session: session, request: proseRequest)?.objectValue { applyReview(saved) } }
            catch { reviewMessage = error.localizedDescription }
        }
        .onChange(of: draft) { _, _ in
            if !reviewRows.isEmpty { reviewRows = []; reviewMessage = "El texto ha cambiado. Revisa de nuevo para consultar este borrador." }
        }
        .onChange(of: beats) { _, _ in
            if !reviewRows.isEmpty { reviewRows = []; reviewMessage = "Los latidos han cambiado. Revisa de nuevo para consultar este borrador." }
        }
    }

    private func inspectorSection<Content: View>(
        _ title: LocalizedStringKey, systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: systemImage).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(11)
        .background(Color(uiColor: .systemBackground).opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.18)) }
    }

    private func beat(kind: String, id: String) -> Row? {
        beats.first { $0.string("thread_kind") == kind && $0.string("thread_id") == id }
    }

    private func setBeat(kind: String, id: String, mark: String?) async {
        guard let outbox else { return }
        let key = [kind, id, scene.id]
        if mark == nil {
            tables["world_beats"]?.removeAll {
                $0.string("thread_kind") == kind && $0.string("thread_id") == id && $0.string("scene_id") == scene.id
            }
            _ = await outbox.syncMutation(kind: .delete, table: .worldBeats, key: key, title: "Remove scene beat")
            return
        }
        let now = ISO8601DateFormatter.nodusFractional.string(from: Date())
        var columns = beat(kind: kind, id: id)?.columns ?? [
            "thread_kind": .string(kind), "thread_id": .string(id), "scene_id": .string(scene.id),
            "created_at": .string(now),
        ]
        columns["mark"] = .string(mark!); columns["updated_at"] = .string(now)
        if mark != "breaks" { columns["paid"] = .null }
        upsertLocal(table: "world_beats", row: Row(columns), keyFields: ["thread_kind", "thread_id", "scene_id"])
        _ = await outbox.syncMutation(kind: .upsert, table: .worldBeats, key: key, row: columns, title: "Update scene beat")
    }

    private func setPaid(value: Bool?, row: Row) async {
        guard let outbox, let kind = row.string("thread_kind"), let id = row.string("thread_id") else { return }
        var columns = row.columns
        columns["paid"] = value.map(JSONValue.bool) ?? .null
        columns["updated_at"] = .string(ISO8601DateFormatter.nodusFractional.string(from: Date()))
        upsertLocal(table: "world_beats", row: Row(columns), keyFields: ["thread_kind", "thread_id", "scene_id"])
        _ = await outbox.syncMutation(kind: .upsert, table: .worldBeats, key: [kind, id, scene.id], row: columns, title: "Judge rule cost")
    }

    private func createThread(kind: String) async {
        guard let outbox else { return }
        let title = newThreadTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let id = "wth_\(UUID().uuidString)"
        let now = ISO8601DateFormatter.nodusFractional.string(from: Date())
        let row: [String: JSONValue] = [
            "thread_id": .string(id), "kind": .string(kind), "title": .string(title),
            "title_key": .string(title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()),
            "scope": .string("external"), "status": .string("open"), "origin": .string("author"),
            "created_at": .string(now), "updated_at": .string(now),
        ]
        tables["world_threads", default: []].append(Row(row))
        _ = await outbox.syncMutation(kind: .upsert, table: .worldThreads, key: [id], row: row, title: "Create \(title)")
        for personId in castIds.sorted() {
            let party: [String: JSONValue] = [
                "thread_id": .string(id), "party_kind": .string("character"), "party_id": .string(personId),
                "side": .string(kind == "arc" ? "subject" : "wants"), "created_at": .string(now), "updated_at": .string(now),
            ]
            tables["thread_parties", default: []].append(Row(party))
            _ = await outbox.syncMutation(kind: .upsert, table: .threadParties, key: [id, "character", personId], row: party, title: "Add story-thread participant")
        }
        await setBeat(kind: kind, id: id, mark: kind == "arc" ? "step" : "raise")
        newThreadTitle = ""; creatingKind = nil
    }

    private func takeSnapshot(reason: String) async {
        guard let outbox else { return }
        let id = "wss_\(UUID().uuidString)"
        let row: [String: JSONValue] = [
            "snapshot_id": .string(id), "scene_id": .string(scene.id), "text": .string(draft),
            "word_count": .int(Int64(WorldbuildingParity.wordCount(draft))), "reason": .string(reason),
            "created_at": .string(ISO8601DateFormatter.nodusFractional.string(from: Date())),
        ]
        tables["world_scene_snapshots", default: []].insert(Row(row), at: 0)
        _ = await outbox.syncMutation(kind: .upsert, table: .worldSceneSnapshots, key: [id], row: row, title: "Snapshot \(scene.title)")
    }

    private func restore(_ snapshot: Row) async {
        guard let outbox, let text = snapshot.string("text") else { return }
        await takeSnapshot(reason: "manual")
        draft = text
        let now = ISO8601DateFormatter.nodusFractional.string(from: Date())
        let row: [String: JSONValue] = [
            "scene_id": .string(scene.id), "text": .string(text),
            "word_count": .int(Int64(WorldbuildingParity.wordCount(text))),
            "created_at": .string(now), "updated_at": .string(now),
        ]
        tables["world_scene_text"] = (tables["world_scene_text"] ?? []).filter { $0.string("scene_id") != scene.id } + [Row(row)]
        onTextChanged(Row(row))
        _ = await outbox.syncMutation(kind: .upsert, table: .worldSceneText, key: [scene.id], row: row, title: "Restore \(scene.title)")
    }

    private func reviewProse() async {
        reviewing = true; defer { reviewing = false }
        let request = proseRequest, currentDraft = proseDraft
        let key = "prose-review:\(scene.id):\(UUID().uuidString)"
        do {
            if session.aiExecutionMode == .autonomous, session.connection.desktopPairingId != nil {
                let result = try await CompanionAcademicGeneration(settings: ai).run(session: session, request: request) { reviewMessage = $0 }
                guard let object = result.objectValue else { throw DesktopBridgeError.malformedResponse }
                guard proseDraft == currentDraft else { reviewMessage = "Resultado conservado en Trabajos. El borrador ha cambiado durante la revisión."; return }
                applyReview(object); return
            }
            activeReviewKey = key; defer { activeReviewKey = nil }
            let creation = try await session.client.createSpaceAction(
                idempotencyKey: key,
                kind: .worldbuildingProseReview, payload: ["sceneId": .string(scene.id), "language": .string(CompanionAcademicGeneration.language), "draft": currentDraft],
                inputRevision: session.publishedRevision, executionMode:session.aiExecutionMode.rawValue, in:session.connection.spaceId
            )
            var action = creation.action
            try Task.checkCancellation()
            for _ in 0..<30 where !action.status.isTerminal {
                try await Task.sleep(for: .seconds(2))
                action = try await session.client.spaceAction(id: action.id, in: session.connection.spaceId)
            }
            guard action.status == .applied, let object = action.result?.objectValue else {
                reviewMessage = action.status.isTerminal
                    ? "Desktop could not complete the review: \(action.errorCode ?? action.status.rawValue)."
                    : "Review is still running in Desktop; its result remains visible in Sync Center."
                return
            }
            guard proseDraft == currentDraft else { reviewMessage = "Resultado conservado en Trabajos. El borrador ha cambiado durante la revisión."; return }
            applyReview(object)
        } catch where error.isCancellation {
            if session.connection.desktopPairingId != nil, session.aiExecutionMode == .live {
                await Task {
                    _ = try? await session.client.cancelSpaceAction(id: DesktopBridgeClient.companionActionIdentity(idempotencyKey: key), in: session.connection.spaceId)
                }.value
            }
            reviewMessage = "Cancelación solicitada. Consulta su estado en Trabajos."
        }
        catch { reviewMessage = error.localizedDescription }
    }
    private func cancelReview() {
        reviewTask?.cancel()
        if let key = activeReviewKey, session.connection.desktopPairingId != nil {
            Task {
                do { _ = try await session.client.cancelSpaceAction(id: DesktopBridgeClient.companionActionIdentity(idempotencyKey: key), in: session.connection.spaceId) }
                catch { reviewMessage = error.localizedDescription }
            }
        }
    }

    private func applyReview(_ object: [String: JSONValue]) {
            if object["noMaterial"]?.boolValue == true {
                reviewMessage = "The review needs both authored beats and written prose."
                reviewRows = []
                return
            }
            reviewRows = (object["beats"]?.arrayValue ?? []).compactMap { value in
                guard let row = value.objectValue,
                      let kind = row["threadKind"]?.stringValue,
                      let id = row["threadId"]?.stringValue
                else { return nil }
                let present: Bool? = row["present"]?.isNull == true ? nil : row["present"]?.boolValue
                return ReviewRow(
                    id: "\(kind):\(id)", title: row["threadTitle"]?.stringValue ?? id,
                    mark: row["mark"]?.stringValue ?? "", present: present,
                    note: row["note"]?.isNull == true ? nil : row["note"]?.stringValue
                )
            }
            reviewMessage = reviewRows.isEmpty ? "No hay veredictos legibles para esta escena." : nil
    }

    private func upsertLocal(table: String, row: Row, keyFields: [String]) {
        let key = keyFields.compactMap { row.string($0) }
        tables[table, default: []].removeAll { candidate in keyFields.compactMap { candidate.string($0) } == key }
        tables[table, default: []].append(row)
    }
}

private struct ManuscriptStructureEditor: View {
    @Environment(\.dismiss) private var dismiss
    let scene: WorldbuildingParity.ManuscriptScene
    let accent: Color
    let onSave: (String, String, Int?) -> Void
    @State private var chapter: String
    @State private var book: String
    @State private var target = ""

    init(scene: WorldbuildingParity.ManuscriptScene, accent: Color, onSave: @escaping (String, String, Int?) -> Void) {
        self.scene = scene; self.accent = accent; self.onSave = onSave
        _chapter = State(initialValue: scene.chapterTitle ?? ""); _book = State(initialValue: scene.bookTitle ?? "")
    }
    var body: some View {
        Form {
            Section("Scene") { Text(scene.title) }
            Section("Starts a chapter") { TextField("Chapter title; leave empty for none", text: $chapter) }
            Section("Starts a book") { TextField("Book title; leave empty for none", text: $book); TextField("Target words", text: $target).keyboardType(.numberPad) }
        }
        .navigationTitle("Manuscript structure").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(chapter, book, Int(target)) } }; ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}
