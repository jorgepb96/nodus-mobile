import NodusKit
import NodusUI
import SwiftUI
import CryptoKit

enum StudyTeachingWorkspaceMode: String {
    case courses, materials, schedule, calendar, recordings
    case groups, grades, exams, rubrics, units
}

struct StudyTeachingWorkspaceView: View {
    let session: SpaceSession
    let mode: StudyTeachingWorkspaceMode

    var body: some View {
        switch mode {
        case .courses: StudyCoursesWorkspace(session: session)
        case .materials: StudyMaterialsWorkspace(session: session)
        case .schedule: StudyPlannerWorkspace(session: session, calendarOnly: false)
        case .calendar: StudyPlannerWorkspace(session: session, calendarOnly: true)
        case .recordings: PrivateSourceCatalogueView(session: session, kind: .recording, title: "Grabaciones", icon: "waveform")
        case .groups: TeachingGroupsWorkspace(session: session)
        case .grades: TeachingGradebookWorkspace(session: session)
        case .exams: TeachingExamsWorkspace(session: session)
        case .rubrics: TeachingRubricsWorkspace(session: session)
        case .units: TeachingUnitsWorkspace(session: session)
        }
    }
}

private let studyPublicTables = [
    "study_courses", "study_subjects", "study_topics", "study_docs", "study_placements",
    "study_materials", "study_schedule_periods", "study_schedule_cells", "study_calendar_events",
    "study_plans", "study_plan_blocks", "study_goals", "study_questions", "study_flashcards",
    "study_ideas", "study_idea_edges", "teaching_exams", "teaching_exam_questions", "teaching_rubrics",
]

// MARK: - Study catalogue

private struct StudyCourseDocumentTarget: Identifiable {
    let id: String
    var startEditing = false
}

private struct StudyCoursesWorkspace: View {
    @Environment(WorkspaceTabs.self) private var tabs
    @Environment(\.horizontalSizeClass) private var sizeClass
    let session: SpaceSession
    @State private var tables: [String: [Row]] = [:]
    @State private var tablesFromDevice = false
    @State private var query = ""
    @State private var error: String?
    @State private var documentTarget: StudyCourseDocumentTarget?
    @State private var newDocumentPresented = false
    @State private var newDocumentTitle = ""
    @State private var newDocumentKind = "apunte"
    @State private var creating = false
    @State private var creationIssue: String?
    @State private var newlyCreatedDocument: String?
    private let documentKinds = [("apunte", "Apunte"), ("manual", "Manual"), ("libro", "Libro"), ("articulo", "Artículo"),
        ("presentacion", "Presentación"), ("grabacion", "Grabación"), ("transcripcion", "Transcripción"),
        ("banco", "Banco de preguntas"), ("test", "Test"), ("examen", "Examen")]

    private let section = "studyCourses"
    private var compactPresentation: Bool { UIDevice.current.userInterfaceIdiom == .phone || sizeClass != .regular }

    private var courses: [StudyTeachingParity.Course] {
        let all = StudyTeachingParity.courses(in: tables)
        return query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var active: StudyTeachingParity.Course? { courses.first { $0.id == tabs.activeTabId(in: section) } ?? StudyTeachingParity.courses(in: tables).first { $0.id == tabs.activeTabId(in: section) } }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTabStrip(section: section, catalogueTitle: "Courses", catalogueImage: "graduationcap", accent: session.accent)
            if !compactPresentation {
                HStack(spacing: 0) {
                    courseSidebar.frame(width: 292); Divider()
                    if let active { courseDetail(active) } else { catalogue }
                }
            } else if let active { courseDetail(active) } else { catalogue }
        }
        .nodusPageBackdrop(accent: session.accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("study-courses-workspace")
        .task(id: session.publishedRevision) { await load() }
        .onChange(of: documentTarget?.id) { _, id in if id == nil { Task { await load() } } }
        .sheet(isPresented: $newDocumentPresented, onDismiss: {
            if let id = newlyCreatedDocument {
                newlyCreatedDocument = nil
                documentTarget = StudyCourseDocumentTarget(id: id, startEditing: true)
            }
        }) {
            NavigationStack {
                Form {
                    TextField("Título", text: $newDocumentTitle).accessibilityIdentifier("study-new-document-title")
                    Picker("Tipo", selection: $newDocumentKind) {
                        ForEach(documentKinds, id: \.0) { kind in Text(kind.1).tag(kind.0) }
                    }
                    if let creationIssue { Text(creationIssue).foregroundStyle(.red) }
                }
                .navigationTitle("Nuevo documento")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { newDocumentPresented = false }.disabled(creating) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { Task { await createDocument() } } label: {
                            if creating { ProgressView() } else { Text("Crear").frame(minWidth: 44, minHeight: 44) }
                        }.disabled(creating).accessibilityIdentifier("study-new-document-create")
                    }
                }
                .interactiveDismissDisabled(creating)
            }.environment(\.nodusHasTabBar, false)
        }
        .nodusSheet(item: $documentTarget) { target in
            NavigationStack {
                StudyEvidenceDocument(session: session, id: target.id, startEditing: target.startEditing)
                    .nodusModalClose(accent: session.accent)
            }
        }
    }

    private var courseSidebar: some View {
        VStack(spacing: 0) {
            HStack { Text("COURSES").font(.caption2.bold()).foregroundStyle(.secondary); Spacer(); Image(systemName: "graduationcap").foregroundStyle(session.accent) }.padding(12)
            NodusSearchField(text: $query, prompt: "Find a course", accent: session.accent).padding(.horizontal, 9).padding(.bottom, 8)
            ScrollView { LazyVStack(spacing: 3) { ForEach(courses) { courseRow($0) } }.padding(7) }
        }.background(Color(uiColor: .secondarySystemBackground).opacity(0.48))
        .accessibilityIdentifier("study-course-sidebar")
    }

    private var catalogue: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                DesktopPageHeader(title: "Study", subtitle: "Courses, subjects, topics and progress", systemImage: "graduationcap", accent: session.accent)
                if compactPresentation { NodusSearchField(text: $query, prompt: "Find a course", accent: session.accent) }
                if let error { NodusNotice(tone: .blocked, title: "Study could not load", message: LocalizedStringKey(error)) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 10)], spacing: 10) {
                    ForEach(courses) { course in Button { open(course) } label: { courseCard(course) }.buttonStyle(NodusCardButtonStyle()).accessibilityIdentifier("study-course-open-\(course.id)") }
                }
            }.padding(NodusSpace.page).frame(maxWidth: 1100).frame(maxWidth: .infinity).nodusTopAnchor()
        }
    }

    private func courseRow(_ course: StudyTeachingParity.Course) -> some View {
        Button { open(course) } label: {
            HStack { Image(systemName: course.icon ?? "graduationcap").foregroundStyle(session.accent).frame(width: 22); VStack(alignment: .leading) { Text(course.name).lineLimit(1); Text("\(StudyTeachingParity.subjects(courseId: course.id, in: tables).count) subjects").font(.caption2).foregroundStyle(.secondary) }; Spacer() }
                .font(.caption).padding(9).background(course.id == active?.id ? session.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("study-course-open-\(course.id)")
    }

    private func courseCard(_ course: StudyTeachingParity.Course) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Image(systemName: course.icon ?? "graduationcap").font(.title2).foregroundStyle(session.accent); Spacer(); if course.favorite { Image(systemName: "star.fill").foregroundStyle(session.accent) } }
            Text(course.name).font(.headline)
            Text(course.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Label("\(StudyTeachingParity.subjects(courseId: course.id, in: tables).count) subjects", systemImage: "books.vertical").font(.caption2).foregroundStyle(.secondary)
        }.desktopContentRow(accent: session.accent)
    }

    private func courseDetail(_ course: StudyTeachingParity.Course) -> some View {
        let subjects = StudyTeachingParity.subjects(courseId: course.id, in: tables)
        let subjectIds = Set(subjects.map(\.id))
        let documents = linkedDocuments(courseId: course.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DesktopPageHeader(title: LocalizedStringKey(course.name), subtitle: "\(course.shortId) · \(subjects.count) subjects", systemImage: course.icon ?? "graduationcap", accent: session.accent)
                Text(course.description).font(.callout).foregroundStyle(.secondary)
                if session.connection.desktopPairingId != nil, session.connection.role.canSendChanges {
                    Button {
                        newDocumentTitle = ""; newDocumentKind = "apunte"; creationIssue = nil
                        newDocumentPresented = true
                    } label: { Label("Nuevo documento", systemImage: "doc.badge.plus").frame(minHeight: 44) }
                    .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent)).accessibilityIdentifier("study-new-document")
                }
                HStack { metric("Subjects", subjects.count, "books.vertical"); metric("Topics", StudyTeachingParity.topics(in: tables).filter { subjectIds.contains($0.subjectId) }.count, "list.bullet.indent"); metric("Documents", documents.count, "doc.text") }
                ForEach(subjects) { subject in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack { Image(systemName: subject.icon ?? "book.closed").foregroundStyle(session.accent); VStack(alignment: .leading) { Text(subject.name).font(.headline); Text(subject.description).font(.caption).foregroundStyle(.secondary) }; Spacer() }
                        let topics = StudyTeachingParity.topics(subjectId: subject.id, in: tables)
                        if !topics.isEmpty { FlowLayout(spacing: 6) { ForEach(topics) { topic in NodusChip(key: topic.name, tint: session.accent) } } }
                    }.desktopContentRow(accent: session.accent)
                }
                if !documents.isEmpty {
                    DesktopSectionHeader(title: "Documents", subtitle: "Placed in this course", systemImage: "doc.text", accent: session.accent)
                    ForEach(documents, id: \.columns) { document in
                        if let id = document.string("id") {
                            Button { documentTarget = StudyCourseDocumentTarget(id: id) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.richtext").foregroundStyle(session.accent)
                                    VStack(alignment: .leading) {
                                        Text(document.text("title") ?? String(localized: "Document")).font(.callout.weight(.medium))
                                        Text(document.text("description") ?? document.text("kind") ?? "").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }.frame(minHeight: 44).desktopContentRow(accent: session.accent)
                            }
                            .buttonStyle(NodusCardButtonStyle())
                            .accessibilityIdentifier("study-course-document-\(id)")
                        }
                    }
                }
            }.padding(NodusSpace.page).frame(maxWidth: 980).frame(maxWidth: .infinity).nodusTopAnchor()
        }.accessibilityElement(children: .contain).accessibilityIdentifier("study-course-detail-\(course.id)")
    }

    private func metric(_ title: LocalizedStringKey, _ value: Int, _ image: String) -> some View { VStack(alignment: .leading, spacing: 5) { Image(systemName: image).foregroundStyle(session.accent); Text("\(value)").font(.title2.bold().monospacedDigit()); Text(title).font(.caption2).foregroundStyle(.secondary) }.desktopContentRow(accent: session.accent).frame(maxWidth: .infinity) }
    private func linkedDocuments(courseId: String) -> [Row] {
        let ids = Set((tables["study_placements"] ?? []).filter {
            $0.string("course_id") == courseId && $0.text("deleted_at") == nil && $0.text("archived_at") == nil
        }.compactMap { $0.string("document_id") })
        return (tables["study_docs"] ?? []).filter {
            ids.contains($0.string("id") ?? "") && $0.text("deleted_at") == nil && $0.text("archived_at") == nil
        }
    }
    private func open(_ course: StudyTeachingParity.Course) { tabs.open(.init(id: course.id, title: course.name, systemImage: course.icon ?? "graduationcap", kind: .document, payload: .reference(kind: "study-course", id: course.id)), in: section) }
    private func overlayDocuments() async throws {
        guard session.connection.desktopPairingId != nil else { return }
        let (vault, pairing, _) = try privateBridgeConnection(session, domain: .corpus)
        guard !pairing.isExpired else { throw DesktopBridgeError.expired }
        let queue = try await CompanionDocumentOutboxes.shared.outbox(pairingId: pairing.id, vaultId: vault, kind: .studyDocument)
        tables = await queue.overlayStudyTables(tables, authoritative: !tablesFromDevice)
    }
    private func createDocument() async {
        guard !creating, let course = active else { return }
        creating = true; defer { creating = false }
        do {
            let (vault, pairing, _) = try privateBridgeConnection(session, domain: .writing)
            guard !pairing.isExpired, pairing.domains.contains(.corpus), session.connection.role.canSendChanges else { throw DesktopBridgeError.permissionDenied }
            let queue = try await CompanionDocumentOutboxes.shared.outbox(pairingId: pairing.id, vaultId: vault, kind: .studyDocument)
            let document = try await queue.createStudyDocument(input: .object(["title": .string(newDocumentTitle), "kind": .string(newDocumentKind),
                "placement": .object(["courseId": .string(course.id)])]))
            guard let id = document.objectValue?["id"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
            tables = await queue.overlayStudyTables(tables, authoritative: !tablesFromDevice)
            newlyCreatedDocument = id; newDocumentPresented = false
            Task { await session.synchronizeCompanionChanges() }
        } catch { creationIssue = error.localizedDescription }
    }
    private func load() async {
        do {
            if session.connection.desktopPairingId != nil, session.mirror == nil {
                let snapshot = try await session.client.snapshot(in: session.connection.spaceId)
                tables = Dictionary(uniqueKeysWithValues: studyPublicTables.map { ($0, snapshot.tables[$0] ?? []) })
                tablesFromDevice = snapshot.fromDevice
            } else {
                tables = try await loadStudyTeachingTables(session, studyPublicTables)
                tablesFromDevice = session.mirror != nil
            }
            try await overlayDocuments()
            error = nil
#if DEBUG
            if ProcessInfo.processInfo.environment["NODUS_SHOW_TAB_DEMO"] == "1", tabs.tabs(in: section).isEmpty {
                StudyTeachingParity.courses(in: tables).prefix(2).forEach(open)
                if let first = StudyTeachingParity.courses(in: tables).first { tabs.activate(first.id, in: section) }
            }
#endif
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Materials and planning

private struct StudyMaterialsWorkspace: View {
    @Environment(WorkspaceTabs.self) private var tabs
    @Environment(\.horizontalSizeClass) private var sizeClass
    let session: SpaceSession
    @State private var tables: [String: [Row]] = [:]
    @State private var query = ""
    @State private var loading = true
    @State private var issue: String?
    private let section = "studyLibrary"
    private var materials: [Row] { (tables["study_materials"] ?? []).filter { query.isEmpty || $0.searchableText.localizedCaseInsensitiveContains(query) } }
    private var active: Row? { (tables["study_materials"] ?? []).first { $0.string("id") == tabs.activeTabId(in: section) } }
    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTabStrip(section: section, catalogueTitle: "Materials", catalogueImage: "books.vertical", accent: session.accent)
            if let active { materialReader(active) } else { catalogue }
        }.nodusPageBackdrop(accent: session.accent).task(id: session.publishedRevision) { await load() }.accessibilityElement(children: .contain)
        .accessibilityIdentifier("study-materials-workspace")
    }
    private var catalogue: some View { ScrollView { VStack(alignment: .leading, spacing: 12) { DesktopPageHeader(title: "Study materials", subtitle: "Documents, reading state and grounded search", systemImage: "books.vertical", accent: session.accent); NodusSearchField(text: $query, prompt: "Search materials", accent: session.accent); if loading { ProgressView("Loading materials…").frame(maxWidth: .infinity).padding(.vertical, 32) }; if let issue { NodusNotice(tone: .blocked, title: "Could not load materials", message: LocalizedStringKey(issue)) }; ForEach(materials, id: \.columns) { row in Button { open(row) } label: { HStack { Image(systemName: previewIcon(row.text("preview_kind"))).font(.title2).foregroundStyle(session.accent); VStack(alignment: .leading) { Text(row.text("title") ?? "Material").font(.headline); Text("\(row.text("read_state") ?? "pending") · \(row.text("index_status") ?? "pending")").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }.desktopContentRow(accent: session.accent) }.buttonStyle(NodusCardButtonStyle()) }; if materials.isEmpty, !loading, issue == nil { ContentUnavailableView("No materials", systemImage: "books.vertical", description: Text("Published study materials will appear here.")) } }.padding(NodusSpace.page).frame(maxWidth: 980).frame(maxWidth: .infinity).nodusTopAnchor() } }
    private func materialReader(_ row: Row) -> some View { ScrollView { VStack(alignment: .leading, spacing: 14) { DesktopPageHeader(title: LocalizedStringKey(row.text("title") ?? "Material"), subtitle: "\(row.text("original_name") ?? "") · \(row.text("read_state") ?? "pending")", systemImage: previewIcon(row.text("preview_kind")), accent: session.accent); NodusNotice(tone: .info, title: "File on demand", message: "Metadata and annotations stay available offline. The primary file downloads through its authenticated object route when requested.", systemImage: "arrow.down.doc"); Text(row.text("description") ?? "No description").font(.body); PrivateFileButton(session: session, kind: .studyMaterial, id: row.string("id") ?? "") }.padding(NodusSpace.page).frame(maxWidth: 900).frame(maxWidth: .infinity).nodusTopAnchor() }.accessibilityIdentifier("study-material-reader") }
    private func open(_ row: Row) { guard let id = row.string("id") else { return }; tabs.open(.init(id: id, title: row.text("title") ?? id, systemImage: previewIcon(row.text("preview_kind")), kind: .document, payload: .row(row)), in: section) }
    private func previewIcon(_ kind: String?) -> String { ["pdf":"doc.richtext", "audio":"waveform", "image":"photo", "presentation":"rectangle.on.rectangle" ][kind ?? ""] ?? "doc.text" }
    private func load() async { loading = true; defer { loading = false }; do { tables = try await loadStudyTeachingTables(session, studyPublicTables); issue = nil } catch { tables = [:]; issue = error.localizedDescription } }
}

private struct StudyPlannerWorkspace: View {
    let session: SpaceSession
    let calendarOnly: Bool
    @State private var tables: [String: [Row]] = [:]
    @State private var loading = true
    @State private var issue: String?
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 14) { DesktopPageHeader(title: calendarOnly ? "Calendar" : "Study plan", subtitle: calendarOnly ? "Assignments, exams and focused sessions" : "Weekly timetable, goals and plan blocks", systemImage: calendarOnly ? "calendar" : "clock", accent: session.accent); if loading { ProgressView("Loading study plan…").frame(maxWidth: .infinity).padding(.vertical, 32) }; if let issue { NodusNotice(tone: .blocked, title: "Could not load the study plan", message: LocalizedStringKey(issue)) }; if !calendarOnly { timetable; goals }; events; if tables.values.allSatisfy(\.isEmpty), !loading, issue == nil { ContentUnavailableView("No scheduled study", systemImage: "calendar", description: Text("Plans, goals and calendar events will appear here.")) } }.padding(NodusSpace.page).frame(maxWidth: 1080).frame(maxWidth: .infinity).nodusTopAnchor() }.nodusPageBackdrop(accent: session.accent).task(id: session.publishedRevision) { await load() }.accessibilityIdentifier(calendarOnly ? "study-calendar-workspace" : "study-schedule-workspace") }
    private var timetable: some View { VStack(alignment: .leading, spacing: 8) { DesktopSectionHeader(title: "Week", subtitle: "Same period grid as Desktop", systemImage: "calendar.day.timeline.left", accent: session.accent); ForEach(tables["study_schedule_cells"] ?? [], id: \.columns) { cell in HStack { Text(weekday(cell.int("weekday") ?? 0)).font(.caption.weight(.semibold)).frame(width: 75, alignment: .leading); Text(period(cell)); Divider(); Text(subject(cell.string("subject_id"))).font(.callout.weight(.medium)); Spacer(); Text(cell.text("room") ?? "").font(.caption).foregroundStyle(.secondary) }.desktopContentRow(accent: session.accent) } } }
    private var goals: some View { VStack(alignment: .leading, spacing: 8) { DesktopSectionHeader(title: "Goals", subtitle: "Progress without silent rescheduling", systemImage: "target", accent: session.accent); ForEach(tables["study_goals"] ?? [], id: \.columns) { goal in VStack(alignment: .leading, spacing: 6) { HStack { Text(goal.text("title") ?? "Goal").font(.callout.weight(.medium)); Spacer(); Text("\(goal.int("current_value") ?? 0)/\(goal.int("target_value") ?? 0) \(goal.text("unit") ?? "")").font(.caption.monospacedDigit()) }; ProgressView(value: Double(goal.int("current_value") ?? 0), total: Double(max(1, goal.int("target_value") ?? 1))).tint(session.accent) }.desktopContentRow(accent: session.accent) } } }
    private var events: some View { VStack(alignment: .leading, spacing: 8) { DesktopSectionHeader(title: "Upcoming", subtitle: "Plans and calendar events", systemImage: "calendar.badge.clock", accent: session.accent); ForEach((tables["study_calendar_events"] ?? []).sorted { ($0.text("starts_at") ?? "") < ($1.text("starts_at") ?? "") }, id: \.columns) { event in HStack { VStack(alignment: .leading) { Text(event.text("title") ?? "Event").font(.callout.weight(.medium)); Text(event.text("notes") ?? event.text("type") ?? "").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(shortDate(event.text("starts_at"))).font(.caption.monospacedDigit()).foregroundStyle(session.accent) }.desktopContentRow(accent: session.accent) } } }
    private func subject(_ id: String?) -> String { (tables["study_subjects"] ?? []).first { $0.string("id") == id }?.text("name") ?? String(localized: "Unassigned") }
    private func period(_ cell: Row) -> String { let row = (tables["study_schedule_periods"] ?? []).first { $0.int("order_idx") == cell.int("period_index") }; return "\(row?.text("start_time") ?? "—")–\(row?.text("end_time") ?? "—")" }
    private func weekday(_ value: Int) -> String { [String(localized: "Monday"), String(localized: "Tuesday"), String(localized: "Wednesday"), String(localized: "Thursday"), String(localized: "Friday"), String(localized: "Saturday"), String(localized: "Sunday")][min(6,max(0,value))] }
    private func shortDate(_ value: String?) -> String { guard let value else { return "" }; return String(value.prefix(10)) }
    private func load() async { loading = true; defer { loading = false }; do { tables = try await loadStudyTeachingTables(session, studyPublicTables); issue = nil } catch { tables = [:]; issue = error.localizedDescription } }
}

// MARK: - Private Teaching and recordings

private struct TeachingGroupsWorkspace: View {
    let session: SpaceSession
    @State private var tables: [String: [Row]] = [:]
    @State private var bridgeIssue: String?
    @State private var pairing = false
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 14) { DesktopPageHeader(title: "Groups", subtitle: "Private roster · direct Mac connection only", systemImage: "person.3", accent: session.accent); privacyBanner; ForEach(tables["teaching_groups"] ?? [], id: \.columns) { group in VStack(alignment: .leading, spacing: 9) { HStack { Text(group.text("name") ?? "Group").font(.headline); Spacer(); CountBadge(count: students(group.string("id")).count, accent: session.accent) }; ForEach(students(group.string("id"))) { student in HStack { Circle().fill(session.accent.opacity(0.16)).frame(width: 34,height:34).overlay { Text(student.displayName.prefix(1)).font(.caption.bold()).foregroundStyle(session.accent) }; VStack(alignment: .leading) { Text(student.displayName).font(.callout.weight(.medium)); Text(student.pseudonymCode).font(.caption2.monospaced()).foregroundStyle(.secondary) }; Spacer(); if !student.comments.isEmpty { Image(systemName: "text.bubble").foregroundStyle(.secondary) } }.padding(.vertical, 3) } }.desktopContentRow(accent: session.accent) } }.padding(NodusSpace.page).frame(maxWidth: 920).frame(maxWidth: .infinity).nodusTopAnchor() }.nodusPageBackdrop(accent: session.accent).task { await load() }.nodusSheet(isPresented: $pairing) { DesktopBridgePairingSheet(accent: session.accent) { Task { await load() } } }.accessibilityIdentifier("teaching-groups-workspace") }
    @ViewBuilder
    private var privacyBanner: some View {
        if let bridgeIssue {
            NodusNotice(tone: .info, title: "Pair the owner Mac", message: LocalizedStringKey(bridgeIssue), systemImage: "lock.shield")
            Button { pairing = true } label: {
                Label("Pair Desktop Bridge", systemImage: "macbook.and.iphone")
            }
            .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent))
        } else {
            NodusNotice(tone: .info, title: "Private Bridge", message: "Names, comments and roster rows came directly from the paired Mac and never from Cloudflare.", systemImage: "lock.shield.fill")
        }
    }
    private func students(_ group: String?) -> [StudyTeachingParity.Student] { StudyTeachingParity.students(in: (tables["teaching_students"] ?? []).filter { $0.string("group_id") == group }) }
    private func load() async { do { tables = try await loadPrivateStudyTables(session, domain: .teachingRoster, names: ["teaching_groups","teaching_students"]); bridgeIssue = nil } catch { tables = [:]; bridgeIssue = error.localizedDescription } }
}

private struct TeachingGradebookWorkspace: View {
    let session: SpaceSession
    @State private var tables: [String: [Row]] = [:]
    @State private var bridgeIssue: String?
    @State private var pairing = false
    private var students: [StudyTeachingParity.Student] { StudyTeachingParity.students(in: tables["teaching_students"] ?? []) }
    private var items: [StudyTeachingParity.AssessmentItem] { StudyTeachingParity.assessmentItems(in: tables["teaching_assessment_items"] ?? []) }
    private var gradeRows: [StudyTeachingParity.GradebookRow] { StudyTeachingParity.gradebook(students: students, items: items, entries: StudyTeachingParity.gradeEntries(in: tables["teaching_grade_entries"] ?? [])) }
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if let bridgeIssue {
                        VStack(alignment: .leading) {
                            NodusNotice(tone: .info, title: "Grades stay on the Mac", message: LocalizedStringKey(bridgeIssue), systemImage: "lock.shield")
                            Button("Pair Desktop Bridge") { pairing = true }
                                .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent))
                        }
                        .padding(NodusSpace.page)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        metrics
                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 0) {
                                gradeHeader
                                ForEach(gradeRows) { gradeRow($0) }
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minWidth: proxy.size.width, alignment: .leading)
                        }
                        .accessibilityIdentifier("teaching-gradebook-table")
                    }
                }
                .frame(width: proxy.size.width, alignment: .leading)
                .frame(minHeight: proxy.size.height, alignment: .topLeading)
            }
        }
        .nodusPageBackdrop(accent: session.accent)
        .task { await load() }
        .nodusSheet(isPresented: $pairing) { DesktopBridgePairingSheet(accent: session.accent) { Task { await load() } } }
        .accessibilityIdentifier("teaching-gradebook-workspace")
    }
    private var header: some View { DesktopPageHeader(title: "Gradebook", subtitle: "Computed locally from a versioned assessment plan", systemImage: "chart.bar", accent: session.accent).padding(NodusSpace.page) }
    private var metrics: some View { let d = StudyTeachingParity.distribution(gradeRows); return LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], alignment: .leading, spacing: 12) { gradeMetric("Evaluated", "\(d.evaluated)"); gradeMetric("Pass rate", d.passRate.map { "\(Int($0*100))%" } ?? "—"); gradeMetric("Mean", d.mean.map { String(format:"%.2f",$0) } ?? "—"); gradeMetric("Median", d.median.map { String(format:"%.2f",$0) } ?? "—") }.padding(.horizontal,NodusSpace.page).padding(.bottom,12) }
    private func gradeMetric(_ title: LocalizedStringKey, _ value: String) -> some View { VStack(alignment:.leading){Text(value).font(.title2.bold().monospacedDigit());Text(title).font(.caption).foregroundStyle(.secondary)}.desktopContentRow(accent:session.accent).frame(maxWidth:.infinity) }
    private var gradeHeader: some View { HStack(spacing:0) { cell("Student",220,true); ForEach(items) { cell($0.name,150,true) }; cell("Final",100,true) }.background(Color(uiColor:.secondarySystemBackground)) }
    private func gradeRow(_ row: StudyTeachingParity.GradebookRow) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading) {
                Text(row.student.displayName).font(.caption.weight(.medium))
                Text(row.student.pseudonymCode).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            .frame(width: 220, alignment: .leading)
            .padding(9)
            .overlay(alignment: .trailing) { columnSeparator }
            ForEach(items) { item in
                let value = row.values[item.id] ?? nil
                cell(value.map { String(format: "%.2f", $0) } ?? "—", 150, false)
            }
            cell(row.finalGrade.map { String(format: "%.2f", $0) } ?? "—", 100, false)
        }
        .overlay(alignment: .bottom) { Divider() }
    }
    private func cell(_ value:String,_ width:CGFloat,_ heading:Bool)->some View { Text(value).font(heading ? .caption.weight(.semibold):.caption).frame(width:width,alignment:.leading).padding(9).overlay(alignment:.trailing){columnSeparator} }
    private var columnSeparator: some View {
        Rectangle().fill(Color.secondary.opacity(0.22)).frame(width: 1)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
    private func load() async { do { let roster = try await loadPrivateStudyTables(session, domain:.teachingRoster,names:["teaching_students"]); let grades = try await loadPrivateStudyTables(session,domain:.teachingGrades,names:["teaching_assessment_plans","teaching_assessment_items","teaching_grade_entries","teaching_rubric_evaluations"]); tables=roster.merging(grades){$1}; bridgeIssue=nil } catch { tables=[:]; bridgeIssue=error.localizedDescription } }
}

// MARK: - Published Teaching authoring

private struct TeachingExamsWorkspace: View {
    @Environment(WorkspaceTabs.self) private var tabs
    let session: SpaceSession
    @State private var tables: [String: [Row]] = [:]
    @State private var loading = true
    @State private var issue: String?
    private let section = "teachingExams"
    private var exams: [Row] { tables["teaching_exams"] ?? [] }
    private var active: Row? { exams.first { $0.string("id") == tabs.activeTabId(in: section) } }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTabStrip(section: section, catalogueTitle: "Exams", catalogueImage: "note.text", accent: session.accent)
            if let active { exam(active) } else { catalogue }
        }
        .nodusPageBackdrop(accent: session.accent)
        .task(id: session.publishedRevision) { await load() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("teaching-exams-workspace")
    }

    private var catalogue: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                DesktopPageHeader(title: "Exams", subtitle: "Papers, sections, questions and answer keys", systemImage: "note.text", accent: session.accent)
                if loading { ProgressView("Loading exams…").frame(maxWidth: .infinity).padding(.vertical, 32) }
                if let issue { NodusNotice(tone: .blocked, title: "Could not load exams", message: LocalizedStringKey(issue)) }
                ForEach(exams, id: \.columns) { row in
                    Button { open(row) } label: {
                        HStack {
                            Image(systemName: "doc.text").font(.title2).foregroundStyle(session.accent)
                            VStack(alignment: .leading) {
                                Text(row.text("title") ?? String(localized: "Exam")).font(.headline)
                                Text("\(questions(row).count) questions · \(points(row), specifier: "%.0f") points").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.desktopContentRow(accent: session.accent)
                    }.buttonStyle(NodusCardButtonStyle())
                }
                if exams.isEmpty, !loading, issue == nil {
                    ContentUnavailableView("No exams", systemImage: "note.text", description: Text("Published exams will appear here."))
                }
            }.padding(NodusSpace.page).frame(maxWidth: 900).frame(maxWidth: .infinity).nodusTopAnchor()
        }
    }

    private func exam(_ row: Row) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                DesktopPageHeader(title: LocalizedStringKey(row.text("title") ?? "Exam"), subtitle: "\(questions(row).count) questions · answer key available", systemImage: "doc.text", accent: session.accent)
                ForEach(Array(questions(row).enumerated()), id: \.element.columns) { index, question in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .top) {
                            Text("\(index + 1).").font(.headline.monospacedDigit()).foregroundStyle(session.accent)
                            Text(question.text("prompt") ?? String(localized: "Question")).font(.headline)
                            Spacer()
                            Text("\(question.double("points") ?? 0, specifier: "%.0f") pt").font(.caption).foregroundStyle(.secondary)
                        }
                        if let solution = question.text("solution") {
                            VStack(alignment: .leading) {
                                Label("Answer key", systemImage: "key").font(.caption.weight(.semibold)).foregroundStyle(session.accent)
                                Text(solution).font(.callout)
                            }.padding(9).background(session.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }.desktopContentRow(accent: session.accent)
                }
            }.padding(NodusSpace.page).frame(maxWidth: 940).frame(maxWidth: .infinity).nodusTopAnchor()
        }
    }

    private func questions(_ exam: Row) -> [Row] { (tables["teaching_exam_questions"] ?? []).filter { $0.string("exam_id") == exam.string("id") }.sorted { ($0.int("position") ?? 0) < ($1.int("position") ?? 0) } }
    private func points(_ exam: Row) -> Double { questions(exam).reduce(0) { $0 + ($1.double("points") ?? 0) } }
    private func open(_ row: Row) { guard let id = row.string("id") else { return }; tabs.open(.init(id: id, title: row.text("title") ?? id, systemImage: "doc.text", kind: .document, payload: .row(row)), in: section) }
    private func load() async { loading = true; defer { loading = false }; do { tables = try await loadStudyTeachingTables(session, studyPublicTables); issue = nil } catch { tables = [:]; issue = error.localizedDescription } }
}

private struct TeachingRubricsWorkspace: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let session: SpaceSession
    @State private var tables: [String: [Row]] = [:]
    @State private var selected: String?
    @State private var loading = true
    @State private var issue: String?
    private var rubrics: [StudyTeachingParity.Rubric] { StudyTeachingParity.rubrics(in: tables["teaching_rubrics"] ?? []) }
    private var active: StudyTeachingParity.Rubric? { rubrics.first { $0.id == selected } }
    private var compactPresentation: Bool { UIDevice.current.userInterfaceIdiom == .phone || sizeClass != .regular }

    var body: some View {
        Group {
            if compactPresentation {
                if let active { rubric(active, showsBackButton: true) } else { rubricList }
            } else {
                HStack(spacing: 0) { rubricList.frame(width: 260); Divider(); if let active { rubric(active) } else { emptyDetail } }
            }
        }
        .nodusPageBackdrop(accent: session.accent)
        .task(id: session.publishedRevision) { await load() }
        .accessibilityIdentifier("teaching-rubrics-workspace")
    }

    private var rubricList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if compactPresentation { DesktopPageHeader(title: "Rubrics", subtitle: "Criteria, levels and descriptors", systemImage: "tablecells", accent: session.accent) }
                else { Text("RUBRICS").font(.caption2.bold()).foregroundStyle(.secondary) }
                if loading { ProgressView("Loading rubrics…").frame(maxWidth: .infinity).padding(.vertical, 32) }
                if let issue { NodusNotice(tone: .blocked, title: "Could not load rubrics", message: LocalizedStringKey(issue)) }
                ForEach(rubrics) { rubric in
                    Button { selected = rubric.id } label: {
                        HStack { Text(rubric.title).font(.callout); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                            .desktopContentRow(accent: session.accent)
                    }.buttonStyle(NodusCardButtonStyle()).accessibilityIdentifier("teaching-rubric-open-\(rubric.id)")
                }
                if rubrics.isEmpty, !loading, issue == nil { ContentUnavailableView("No rubrics", systemImage: "tablecells") }
            }.padding(compactPresentation ? NodusSpace.page : 12).nodusTopAnchor()
        }.background(Color(uiColor: .secondarySystemBackground).opacity(0.48))
    }

    private var emptyDetail: some View { ContentUnavailableView("Select a rubric", systemImage: "tablecells", description: Text("Choose a rubric to inspect its criteria.")) }

    private func rubric(_ rubric: StudyTeachingParity.Rubric, showsBackButton: Bool = false) -> some View {
        ScrollView(compactPresentation ? .vertical : [.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 12) {
                if showsBackButton { Button { selected = nil } label: { Label("Rubrics", systemImage: "chevron.left") }.buttonStyle(NodusGlassButtonStyle(accent: session.accent)) }
                DesktopPageHeader(title: LocalizedStringKey(rubric.title), subtitle: "\(rubric.criteria.count) criteria · scale \(String(format: "%.0f", rubric.scaleMax))", systemImage: "tablecells", accent: session.accent)
                Text(rubric.description).font(.callout).foregroundStyle(.secondary)
                if compactPresentation {
                    ForEach(rubric.criteria) { criterion in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(criterion.label).font(.headline).textSelection(.enabled)
                            Text("Weight \(criterion.weight, specifier: "%.0f")").font(.caption).foregroundStyle(.secondary)
                            ForEach(rubric.levels) { level in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(level.label).font(.subheadline.weight(.semibold)).foregroundStyle(session.accent.nodusReadable)
                                    Text(criterion.descriptors[level.id] ?? "—").font(.body).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityIdentifier("teaching-rubric-descriptor-\(criterion.id)-\(level.id)")
                            }
                        }.desktopContentRow(accent: session.accent)
                    }
                } else {
                  VStack(spacing: 0) {
                    HStack(spacing: 0) { Text("Criterion").frame(width: 200, alignment: .leading); ForEach(rubric.levels) { Text($0.label).frame(width: 190, alignment: .leading) } }
                        .font(.caption.bold()).padding(9).background(Color(uiColor: .secondarySystemBackground))
                    ForEach(rubric.criteria) { criterion in
                        HStack(spacing: 0) {
                            VStack(alignment: .leading) { Text(criterion.label).font(.caption.weight(.semibold)); Text("Weight \(criterion.weight, specifier: "%.0f")").font(.caption2).foregroundStyle(.secondary) }.frame(width: 200, alignment: .leading)
                            ForEach(rubric.levels) { level in Text(criterion.descriptors[level.id] ?? "—").font(.caption).frame(width: 190, alignment: .leading) }
                        }.padding(9).overlay(alignment: .bottom) { Divider() }
                    }
                  }
                }
            }.padding(NodusSpace.page).nodusTopAnchor()
        }
    }

    private func load() async { loading = true; defer { loading = false }; do { tables = try await loadStudyTeachingTables(session, studyPublicTables); issue = nil; if !compactPresentation { selected = selected ?? rubrics.first?.id } } catch { tables = [:]; issue = error.localizedDescription } }
}

private struct DesktopSectionHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let systemImage: String
    let accent: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }
}

private struct TeachingUnitsWorkspace: View {
    let session: SpaceSession
    @State private var tables: [String: [Row]] = [:]
    @State private var loading = true
    @State private var issue: String?
    private var units: [Row] { (tables["study_docs"] ?? []).filter { $0.text("kind") == "unit" } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DesktopPageHeader(title: "Unit design", subtitle: "Inquiry, learning sequence, assessment and materials", systemImage: "safari", accent: session.accent)
                if loading { ProgressView("Loading units…").frame(maxWidth: .infinity).padding(.vertical, 32) }
                if let issue { NodusNotice(tone: .blocked, title: "Could not load units", message: LocalizedStringKey(issue)) }
                ForEach(units, id: \.columns) { unit in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(unit.text("title") ?? String(localized: "Unit")).font(.title2.bold())
                        Text(unit.text("description") ?? "").font(.callout).foregroundStyle(.secondary)
                        Text(unit.text("content_markdown") ?? "").font(.body).textSelection(.enabled)
                        HStack { Label("Learning sequence", systemImage: "list.number"); Spacer(); Label("Assessment linked", systemImage: "checkmark.seal") }.font(.caption).foregroundStyle(session.accent)
                    }.desktopContentRow(accent: session.accent)
                }
                if units.isEmpty, !loading, issue == nil { ContentUnavailableView("No units", systemImage: "safari", description: Text("Published teaching units will appear here.")) }
            }.padding(NodusSpace.page).frame(maxWidth: 940).frame(maxWidth: .infinity).nodusTopAnchor()
        }
        .nodusPageBackdrop(accent: session.accent)
        .task(id: session.publishedRevision) { await load() }
        .accessibilityIdentifier("teaching-units-workspace")
    }
    private func load() async { loading = true; defer { loading = false }; do { tables = try await loadStudyTeachingTables(session, studyPublicTables); issue = nil } catch { tables = [:]; issue = error.localizedDescription } }
}

// MARK: - Bridge pairing and loaders

struct DesktopBridgePairingSheet: View {
    let accent: Color
    var initialLink: String = ""
    var onAdvanced: (() -> Void)? = nil
    let onPaired: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var origin = "https://"
    @State private var fingerprint = ""
    @State private var code = ""
    @State private var link = ""
    @State private var scanning = false
    @State private var working = false
    @State private var error: String?
    @State private var offer: DesktopPairingOffer?
    @State private var connectAfterDiscovery = false
    @State private var resumingPending = false
    @State private var discovery = PairingDiscovery()
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.nodusDanger)
                            .accessibilityIdentifier("pairing-error")
                    }
                }
                Section {
                    Text("Open Settings → Mobile connection in Nodus on your Mac. Enter its code or scan its QR to connect your entire workspace.")
                        .font(.callout).foregroundStyle(.secondary)
                    if resumingPending {
                        Text("A connection is pending. Tap Connect to continue without a new code.")
                            .font(.callout).accessibilityIdentifier("pairing-pending-notice")
                    }
                    Button("Scan QR", systemImage: "qrcode.viewfinder") { scanning = true }.accessibilityIdentifier("pairing-scan-qr")
                        .disabled(working || discovery.searching)
                    TextField("Pairing code", text: $code).textInputAutocapitalization(.characters)
                        .autocorrectionDisabled().accessibilityIdentifier("pairing-code")
                        .focused($codeFocused).submitLabel(.go)
                        .onSubmit { requestConnection() }
                        .onChange(of: code) { _, value in
                            if let offer, value.filter({ $0.isLetter || $0.isNumber }).uppercased() != offer.code.filter({ $0.isLetter || $0.isNumber }).uppercased() {
                                self.offer = nil; fingerprint = ""; error = nil
                                resumingPending = false
                            }
                        }
                        .disabled(working || discovery.searching)
                    Button("Connect in real time", systemImage: "link", action: requestConnection)
                        .accessibilityIdentifier("pairing-find-mac")
                        .disabled(working || discovery.searching || code.filter { $0.isLetter || $0.isNumber }.count != 10)
                    if working { ProgressView("Connecting to Nodus…") }
                    if discovery.searching { ProgressView("Looking for your Mac…") }
                    if let discoveryError = discovery.error {
                        Text(discoveryError).foregroundStyle(Color.nodusDanger).accessibilityIdentifier("pairing-discovery-error")
                    }
                    DisclosureGroup("Use a pairing link") {
                        TextField("Pairing link from Nodus", text: $link, axis: .vertical)
                        .lineLimit(1...3)
                        .accessibilityIdentifier("pairing-link")
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: link) { _, value in readOffer(value) }
                    }.disabled(working || discovery.searching)
                    Text("Keep Nodus open on your Mac and use the same network or a VPN such as Tailscale. Live uses the models configured on your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let offer {
                    Section("Mac and vaults") {
                        Label(offer.deviceName ?? "Nodus", systemImage: "desktopcomputer")
                        if offer.renewalPairingId != nil {
                            Text("Renewing the existing connection preserves its vaults, permissions and local data.")
                                .accessibilityIdentifier("pairing-renewal-notice")
                        }
                        Text("\(offer.vaults?.count ?? 0) linked vaults")
                        DisclosureGroup("Workspace details") {
                            ForEach(offer.vaults ?? []) { vault in Label(vault.name, systemImage: "books.vertical") }
                            ForEach(offer.domains.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { domain in
                                Text(pairingDomainLabel(domain)).accessibilityIdentifier("pairing-domain-\(domain.rawValue)")
                            }
                        }
                        Text(offer.expiresAt, style: .relative)
                    }
                }
                if let onAdvanced {
                    Section {
                        Button("Advanced connection · Server or Cloud", action: onAdvanced)
                            .accessibilityIdentifier("pairing-advanced-connection").disabled(working || discovery.searching)
                    }
                }
            }
            .nodusDismissesKeyboard()
            .navigationTitle("Link Nodus")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if offer != nil {
                        Button("Connect") { Task { await pair() } }.accessibilityIdentifier("pairing-confirm")
                            .disabled(working || origin.count < 9 || fingerprint.isEmpty || code.isEmpty)
                    }
                }
            }
        }
        .tint(accent)
        .onAppear {
            if !initialLink.isEmpty { link = initialLink; readOffer(initialLink) }
            else if offer == nil, let pending = DesktopBridgePairingStore().pendingOffers().first {
                accept(pending); resumingPending = true
            }
        }
        .onChange(of: discovery.offer?.id) { _, _ in
            if let found = discovery.offer {
                accept(found)
                if connectAfterDiscovery { connectAfterDiscovery = false; Task { await pair() } }
            }
        }
        .onDisappear { discovery.stop() }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                PairingQRScanner { value in
                    link = value; scanning = false; readOffer(value)
                    if offer != nil { Task { await pair() } }
                }
                .navigationTitle("Scan QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { scanning = false }.accessibilityIdentifier("pairing-close-scanner")
                    }
                }
            }
            .dynamicTypeSize(textSize)
        }
    }

    private func readOffer(_ value: String) {
        do {
            let offer = try DesktopPairingOffer.read(value)
            accept(offer)
        } catch { offer = nil; fingerprint = ""; self.error = error.localizedDescription }
    }

    private func requestConnection() {
        guard !working, !discovery.searching, code.filter({ $0.isLetter || $0.isNumber }).count == 10 else { return }
        if offer != nil { Task { await pair() } }
        else { connectAfterDiscovery = true; findMac() }
    }

    private func findMac() {
        codeFocused = false
        discovery.search(code: code)
    }

    private func accept(_ offer: DesktopPairingOffer) {
        self.offer = offer; origin = offer.origins.first ?? ""; fingerprint = offer.certificateFingerprint; code = offer.code; error = nil
    }

    private func pair() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            guard let offer else { throw DesktopBridgeError.malformedResponse }
            let result = try await DesktopBridgeClient.pair(
                offer: offer,
                deviceId: UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString,
                deviceName: UIDevice.current.name
            )
            try await model.connectDesktop(pairing: result.pairing, token: result.token, expectedMacId: offer.macDeviceId)
            guard model.openLinkedDesktopWorkspace(pairingId: result.pairing.id) else { throw DesktopBridgeError.malformedResponse }
            onPaired()
            dismiss()
        } catch {
            if error is URLError {
                let pending = offer.map { active in DesktopBridgePairingStore().pendingOffers().contains { $0.id == active.id } } ?? false
                resumingPending = pending
                self.error = pending
                    ? String(localized: "The connection was interrupted. Your request is saved. Keep Nodus open and tap Connect to continue.")
                    : String(localized: "Your Mac could not be reached. Keep Nodus open and check that both devices use the same network or VPN.")
            } else if let bridgeError = error as? DesktopBridgeError {
                switch bridgeError {
                case .expired:
                    resumingPending = false
                    self.error = String(localized: "This code has expired. Generate a new code in Mobile connection on your Mac.")
                case .certificateMismatch:
                    self.error = String(localized: "Your Mac's connection identity has changed. Generate a new code in Nodus to link it again.")
                case .permissionDenied, .credentialRevoked:
                    resumingPending = false
                    self.error = String(localized: "This connection is no longer available. Generate a new code on your Mac.")
                case .invalidOrigin, .invalidFingerprint:
                    self.error = String(localized: "This pairing link is invalid. Generate a new code or QR in Nodus on your Mac.")
                case .malformedResponse:
                    self.error = String(localized: "Nodus returned a response that could not be read. Please try again.")
                case .locked:
                    self.error = String(localized: "Unlock this device to continue the connection.")
                }
            } else { self.error = error.localizedDescription }
        }
    }
}

private func pairingDomainLabel(_ domain: DesktopBridgeDomain) -> String {
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

@MainActor
private func loadStudyTeachingTables(_ session:SpaceSession,_ names:[String])async throws->[String:[Row]]{let fixture=debugStudyTeachingFixture();if session.connection.desktopPairingId == nil, !fixture.isEmpty{return Dictionary(uniqueKeysWithValues:names.map{($0,fixture[$0] ?? [])})};if let mirror=session.mirror{var result:[String:[Row]]=[:];for name in names{result[name]=try await mirror.allRows(table:name)};return result};let snapshot=try await session.client.snapshot(in:session.connection.spaceId);return Dictionary(uniqueKeysWithValues:names.map{($0,snapshot.tables[$0] ?? [])})}

@MainActor
private func loadPrivateStudyTables(_ session:SpaceSession,domain:DesktopBridgeDomain,names:[String])async throws->[String:[Row]]{
    try await loadPrivateBridgeTables(session, domain: domain, names: names, fixture: debugStudyTeachingFixture()).tables
}

private func debugStudyTeachingFixture() -> [String: [Row]] {
#if DEBUG
    guard
        let override = ProcessInfo.processInfo.environment["NODUS_VAULT_TYPE_OVERRIDE"],
        ["estudio", "docencia", "study", "teaching"].contains(override),
        let url = Bundle.main.url(forResource: "study-teaching-fixture", withExtension: "json"),
        let data = try? Data(contentsOf: url),
        let object = try? JSONDecoder().decode([String: JSONValue].self, from: data)
    else { return [:] }
    return object.compactMapValues { $0.arrayValue?.compactMap { $0.objectValue.map(Row.init) } }
#else
    return [:]
#endif
}

/// The screenshot fixture exercises the same addressed reader as the real Mac.
/// It is unavailable in Release and never acts as a fallback for failed grants.
func debugPrivateRecordingCopies() throws -> [CompanionPrivateSourceCopy] {
#if DEBUG
    let tables = debugStudyTeachingFixture()
    return try (tables["study_recordings"] ?? []).map { root in
        guard let id = root.string("id") else { throw DesktopBridgeError.malformedResponse }
        let reference = try PrivateCorpusReference(kind: .recording, id: id)
        let transcripts = (tables["study_transcripts"] ?? []).filter { $0.string("recording_id") == id }
        let transcriptIds = Set(transcripts.compactMap { $0.string("id") })
        let owned: [String: [Row]] = ["transcripts": transcripts,
            "segments": (tables["study_transcript_segments"] ?? []).filter { $0.string("transcript_id").map(transcriptIds.contains) == true },
            "markers": (tables["study_audio_markers"] ?? []).filter { $0.string("recording_id") == id }]
        let rows = owned.mapValues { records in records.enumerated().map { ordinal, row in
            var row = row; row.columns["_bridge_cursor"] = .int(Int64(ordinal + 1))
            if let seconds = row.columns["seconds"], row.columns["t_seconds"] == nil { row.columns["t_seconds"] = seconds }
            return row
        } }
        func digest(_ value: JSONValue) throws -> String {
            SHA256.hash(data: try JSONEncoder.nodus.encode(value)).map { String(format: "%02x", $0) }.joined()
        }
        let groups: [JSONValue] = try reference.kind.groups.map { key in
            let records = JSONValue.array((rows[key] ?? []).map { .object($0.columns) })
            return .object(["key": .string(key), "title": .string(key), "total": .int(Int64(rows[key]?.count ?? 0)), "revision": .string(try digest(records))])
        }
        let json: JSONValue = .object(["version": .int(1), "kind": .string(reference.kind.rawValue), "id": .string(id),
            "root": .object(root.columns), "groups": .array(groups), "revision": .string(try digest(.object(root.columns)))])
        let source = try JSONDecoder.nodus.decode(PrivateCorpusSource.self, from: JSONEncoder.nodus.encode(json))
        return try CompanionPrivateSourceCopy(source: source, rows: rows, reference: reference)
    }
#else
    return []
#endif
}
