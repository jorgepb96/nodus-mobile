import NodusKit
import NodusUI
import SwiftUI

enum StudyTeachingWorkspaceMode: String {
    case courses, materials, schedule, calendar, recordings, graph
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
        case .recordings: StudyRecordingsWorkspace(session: session)
        case .graph: StudyProgressWorkspace(session: session)
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

private struct StudyCoursesWorkspace: View {
    @Environment(WorkspaceTabs.self) private var tabs
    @Environment(\.horizontalSizeClass) private var sizeClass
    let session: SpaceSession
    @State private var tables: [String: [Row]] = [:]
    @State private var query = ""
    @State private var error: String?
    private let section = "studyCourses"

    private var courses: [StudyTeachingParity.Course] {
        let all = StudyTeachingParity.courses(in: tables)
        return query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var active: StudyTeachingParity.Course? { courses.first { $0.id == tabs.activeTabId(in: section) } ?? StudyTeachingParity.courses(in: tables).first { $0.id == tabs.activeTabId(in: section) } }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTabStrip(section: section, catalogueTitle: "Courses", catalogueImage: "graduationcap", accent: session.accent)
            if sizeClass == .regular {
                HStack(spacing: 0) {
                    courseSidebar.frame(width: 292); Divider()
                    if let active { courseDetail(active) } else { catalogue }
                }
            } else if let active { courseDetail(active) } else { catalogue }
        }
        .nodusPageBackdrop(accent: session.accent)
        .accessibilityIdentifier("study-courses-workspace")
        .task(id: session.publishedRevision) { await load() }
    }

    private var courseSidebar: some View {
        VStack(spacing: 0) {
            HStack { Text("COURSES").font(.caption2.bold()).foregroundStyle(.secondary); Spacer(); Image(systemName: "graduationcap").foregroundStyle(session.accent) }.padding(12)
            NodusSearchField(text: $query, prompt: "Find a course", accent: session.accent).padding(.horizontal, 9).padding(.bottom, 8)
            ScrollView { LazyVStack(spacing: 3) { ForEach(courses) { courseRow($0) } }.padding(7) }
        }.background(Color(uiColor: .secondarySystemBackground).opacity(0.48))
    }

    private var catalogue: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                DesktopPageHeader(title: "Study", subtitle: "Courses, subjects, topics and progress", systemImage: "graduationcap", accent: session.accent)
                if sizeClass == .compact { NodusSearchField(text: $query, prompt: "Find a course", accent: session.accent) }
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
                    ForEach(documents, id: \.columns) { document in HStack { Image(systemName: "doc.richtext").foregroundStyle(session.accent); VStack(alignment: .leading) { Text(document.text("title") ?? "Document").font(.callout.weight(.medium)); Text(document.text("description") ?? document.text("kind") ?? "").font(.caption2).foregroundStyle(.secondary) }; Spacer() }.desktopContentRow(accent: session.accent) }
                }
            }.padding(NodusSpace.page).frame(maxWidth: 980).frame(maxWidth: .infinity).nodusTopAnchor()
        }.accessibilityIdentifier("study-course-detail-\(course.id)")
    }

    private func metric(_ title: LocalizedStringKey, _ value: Int, _ image: String) -> some View { VStack(alignment: .leading, spacing: 5) { Image(systemName: image).foregroundStyle(session.accent); Text("\(value)").font(.title2.bold().monospacedDigit()); Text(title).font(.caption2).foregroundStyle(.secondary) }.desktopContentRow(accent: session.accent).frame(maxWidth: .infinity) }
    private func linkedDocuments(courseId: String) -> [Row] { let ids = Set((tables["study_placements"] ?? []).filter { $0.string("course_id") == courseId }.compactMap { $0.string("document_id") }); return (tables["study_docs"] ?? []).filter { ids.contains($0.string("id") ?? "") } }
    private func open(_ course: StudyTeachingParity.Course) { tabs.open(.init(id: course.id, title: course.name, systemImage: course.icon ?? "graduationcap", kind: .document, payload: .reference(kind: "study-course", id: course.id)), in: section) }
    private func load() async {
        do {
            tables = try await loadStudyTeachingTables(session, studyPublicTables)
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
    private let section = "studyLibrary"
    private var materials: [Row] { (tables["study_materials"] ?? []).filter { query.isEmpty || $0.searchableText.localizedCaseInsensitiveContains(query) } }
    private var active: Row? { (tables["study_materials"] ?? []).first { $0.string("id") == tabs.activeTabId(in: section) } }
    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTabStrip(section: section, catalogueTitle: "Materials", catalogueImage: "books.vertical", accent: session.accent)
            if let active { materialReader(active) } else { catalogue }
        }.nodusPageBackdrop(accent: session.accent).task(id: session.publishedRevision) { tables = (try? await loadStudyTeachingTables(session, studyPublicTables)) ?? [:] }.accessibilityIdentifier("study-materials-workspace")
    }
    private var catalogue: some View { ScrollView { VStack(alignment: .leading, spacing: 12) { DesktopPageHeader(title: "Study materials", subtitle: "Documents, reading state and grounded search", systemImage: "books.vertical", accent: session.accent); NodusSearchField(text: $query, prompt: "Search materials", accent: session.accent); ForEach(materials, id: \.columns) { row in Button { open(row) } label: { HStack { Image(systemName: previewIcon(row.text("preview_kind"))).font(.title2).foregroundStyle(session.accent); VStack(alignment: .leading) { Text(row.text("title") ?? "Material").font(.headline); Text("\(row.text("read_state") ?? "pending") · \(row.text("index_status") ?? "pending")").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }.desktopContentRow(accent: session.accent) }.buttonStyle(NodusCardButtonStyle()) } }.padding(NodusSpace.page).frame(maxWidth: 980).frame(maxWidth: .infinity).nodusTopAnchor() } }
    private func materialReader(_ row: Row) -> some View { ScrollView { VStack(alignment: .leading, spacing: 14) { DesktopPageHeader(title: LocalizedStringKey(row.text("title") ?? "Material"), subtitle: "\(row.text("original_name") ?? "") · \(row.text("read_state") ?? "pending")", systemImage: previewIcon(row.text("preview_kind")), accent: session.accent); NodusNotice(tone: .info, title: "File on demand", message: "Metadata and annotations stay available offline. The primary file downloads through its authenticated object route when requested.", systemImage: "arrow.down.doc"); Text(row.text("description") ?? "No description").font(.body); HStack { Button { } label: { Label("Open preview", systemImage: "doc.text.magnifyingglass") }.buttonStyle(NodusPrimaryButtonStyle(accent: session.accent)); ShareLink(item: row.text("title") ?? "Material") { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(NodusGlassButtonStyle(accent: session.accent)) } }.padding(NodusSpace.page).frame(maxWidth: 900).frame(maxWidth: .infinity).nodusTopAnchor() }.accessibilityIdentifier("study-material-reader") }
    private func open(_ row: Row) { guard let id = row.string("id") else { return }; tabs.open(.init(id: id, title: row.text("title") ?? id, systemImage: previewIcon(row.text("preview_kind")), kind: .document, payload: .row(row)), in: section) }
    private func previewIcon(_ kind: String?) -> String { ["pdf":"doc.richtext", "audio":"waveform", "image":"photo", "presentation":"rectangle.on.rectangle" ][kind ?? ""] ?? "doc.text" }
}

private struct StudyPlannerWorkspace: View {
    let session: SpaceSession
    let calendarOnly: Bool
    @State private var tables: [String: [Row]] = [:]
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 14) { DesktopPageHeader(title: calendarOnly ? "Calendar" : "Study plan", subtitle: calendarOnly ? "Assignments, exams and focused sessions" : "Weekly timetable, goals and plan blocks", systemImage: calendarOnly ? "calendar" : "clock", accent: session.accent); if !calendarOnly { timetable; goals }; events }.padding(NodusSpace.page).frame(maxWidth: 1080).frame(maxWidth: .infinity).nodusTopAnchor() }.nodusPageBackdrop(accent: session.accent).task(id: session.publishedRevision) { tables = (try? await loadStudyTeachingTables(session, studyPublicTables)) ?? [:] }.accessibilityIdentifier(calendarOnly ? "study-calendar-workspace" : "study-schedule-workspace") }
    private var timetable: some View { VStack(alignment: .leading, spacing: 8) { DesktopSectionHeader(title: "Week", subtitle: "Same period grid as Desktop", systemImage: "calendar.day.timeline.left", accent: session.accent); ForEach(tables["study_schedule_cells"] ?? [], id: \.columns) { cell in HStack { Text(weekday(cell.int("weekday") ?? 0)).font(.caption.weight(.semibold)).frame(width: 75, alignment: .leading); Text(period(cell)); Divider(); Text(subject(cell.string("subject_id"))).font(.callout.weight(.medium)); Spacer(); Text(cell.text("room") ?? "").font(.caption).foregroundStyle(.secondary) }.desktopContentRow(accent: session.accent) } } }
    private var goals: some View { VStack(alignment: .leading, spacing: 8) { DesktopSectionHeader(title: "Goals", subtitle: "Progress without silent rescheduling", systemImage: "target", accent: session.accent); ForEach(tables["study_goals"] ?? [], id: \.columns) { goal in VStack(alignment: .leading, spacing: 6) { HStack { Text(goal.text("title") ?? "Goal").font(.callout.weight(.medium)); Spacer(); Text("\(goal.int("current_value") ?? 0)/\(goal.int("target_value") ?? 0) \(goal.text("unit") ?? "")").font(.caption.monospacedDigit()) }; ProgressView(value: Double(goal.int("current_value") ?? 0), total: Double(max(1, goal.int("target_value") ?? 1))).tint(session.accent) }.desktopContentRow(accent: session.accent) } } }
    private var events: some View { VStack(alignment: .leading, spacing: 8) { DesktopSectionHeader(title: "Upcoming", subtitle: "Plans and calendar events", systemImage: "calendar.badge.clock", accent: session.accent); ForEach((tables["study_calendar_events"] ?? []).sorted { ($0.text("starts_at") ?? "") < ($1.text("starts_at") ?? "") }, id: \.columns) { event in HStack { VStack(alignment: .leading) { Text(event.text("title") ?? "Event").font(.callout.weight(.medium)); Text(event.text("notes") ?? event.text("type") ?? "").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(shortDate(event.text("starts_at"))).font(.caption.monospacedDigit()).foregroundStyle(session.accent) }.desktopContentRow(accent: session.accent) } } }
    private func subject(_ id: String?) -> String { (tables["study_subjects"] ?? []).first { $0.string("id") == id }?.text("name") ?? "Unassigned" }
    private func period(_ cell: Row) -> String { let row = (tables["study_schedule_periods"] ?? []).first { $0.int("order_idx") == cell.int("period_index") }; return "\(row?.text("start_time") ?? "—")–\(row?.text("end_time") ?? "—")" }
    private func weekday(_ value: Int) -> String { ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"][min(6,max(0,value))] }
    private func shortDate(_ value: String?) -> String { guard let value else { return "" }; return String(value.prefix(10)) }
}

private struct StudyProgressWorkspace: View {
    let session: SpaceSession
    @State private var tables: [String: [Row]] = [:]
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 14) { DesktopPageHeader(title: "Learning graph", subtitle: "Subjects, topics and evidence-backed progress", systemImage: "point.3.connected.trianglepath.dotted", accent: session.accent); ForEach(tables["study_performance"] ?? [], id: \.columns) { row in let summary = StudyTeachingParity.summarize(.init(correct: row.int("correct") ?? 0, incorrect: row.int("incorrect") ?? 0, omitted: row.int("omitted") ?? 0, studySeconds: row.int("study_seconds") ?? 0, reviews: row.int("reviews") ?? 0, lapses: row.int("lapses") ?? 0)); VStack(alignment: .leading, spacing: 8) { HStack { Text(row.text("label") ?? "Subject").font(.headline); Spacer(); NodusChip(key: summary.status, tint: tone(summary.mastery)) }; ProgressView(value: summary.mastery).tint(tone(summary.mastery)); HStack { Label("\(summary.attempts) attempts", systemImage: "checklist"); Spacer(); Text(summary.accuracy.map { "\(Int($0 * 100))% accuracy" } ?? "No attempts") }.font(.caption).foregroundStyle(.secondary) }.desktopContentRow(accent: tone(summary.mastery)) } }.padding(NodusSpace.page).frame(maxWidth: 900).frame(maxWidth: .infinity).nodusTopAnchor() }.nodusPageBackdrop(accent: session.accent).task(id: session.publishedRevision) { tables = (try? await loadStudyTeachingTables(session, studyPublicTables + ["study_performance"])) ?? [:] }.accessibilityIdentifier("study-progress-workspace") }
    private func tone(_ mastery: Double) -> Color { mastery >= 0.85 ? .green : mastery >= 0.65 ? session.accent : mastery >= 0.35 ? .orange : .red }
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
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if let bridgeIssue {
                        VStack(alignment: .leading) {
                            NodusNotice(tone: .info, title: "Grades stay on the Mac", message: LocalizedStringKey(bridgeIssue), systemImage: "lock.shield")
                            Button("Pair Desktop Bridge") { pairing = true }
                                .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent))
                        }
                        .padding(NodusSpace.page)
                        .frame(width: 760)
                    } else {
                        metrics
                        gradeHeader
                        ForEach(gradeRows) { gradeRow($0) }
                    }
                }
                .frame(minWidth: 900, minHeight: proxy.size.height, alignment: .topLeading)
            }
        }
        .nodusPageBackdrop(accent: session.accent)
        .task { await load() }
        .nodusSheet(isPresented: $pairing) { DesktopBridgePairingSheet(accent: session.accent) { Task { await load() } } }
        .accessibilityIdentifier("teaching-gradebook-workspace")
    }
    private var header: some View { DesktopPageHeader(title: "Gradebook", subtitle: "Computed locally from a versioned assessment plan", systemImage: "chart.bar", accent: session.accent).padding(NodusSpace.page) }
    private var metrics: some View { let d = StudyTeachingParity.distribution(gradeRows); return HStack { gradeMetric("Evaluated", "\(d.evaluated)"); gradeMetric("Pass rate", d.passRate.map { "\(Int($0*100))%" } ?? "—"); gradeMetric("Mean", d.mean.map { String(format:"%.2f",$0) } ?? "—"); gradeMetric("Median", d.median.map { String(format:"%.2f",$0) } ?? "—") }.padding(.horizontal,NodusSpace.page).padding(.bottom,12) }
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
            ForEach(items) { item in
                let value = row.values[item.id] ?? nil
                cell(value.map { String(format: "%.2f", $0) } ?? "—", 150, false)
            }
            cell(row.finalGrade.map { String(format: "%.2f", $0) } ?? "—", 100, false)
        }
        .overlay(alignment: .bottom) { Divider() }
    }
    private func cell(_ value:String,_ width:CGFloat,_ heading:Bool)->some View { Text(value).font(heading ? .caption.weight(.semibold):.caption).frame(width:width,alignment:.leading).padding(9).overlay(alignment:.trailing){Divider()} }
    private func load() async { do { let roster = try await loadPrivateStudyTables(session, domain:.teachingRoster,names:["teaching_students"]); let grades = try await loadPrivateStudyTables(session,domain:.teachingGrades,names:["teaching_assessment_plans","teaching_assessment_items","teaching_grade_entries","teaching_rubric_evaluations"]); tables=roster.merging(grades){$1}; bridgeIssue=nil } catch { tables=[:]; bridgeIssue=error.localizedDescription } }
}

private struct StudyRecordingsWorkspace: View {
    @Environment(WorkspaceTabs.self) private var tabs
    let session: SpaceSession
    @State private var tables:[String:[Row]]=[:]
    @State private var issue:String?
    @State private var pairing=false
    private let section="studyRecordings"
    private var active:Row?{(tables["study_recordings"] ?? []).first{$0.string("id")==tabs.activeTabId(in:section)}}
    var body:some View { VStack(spacing:0){WorkspaceTabStrip(section:section,catalogueTitle:"Recordings",catalogueImage:"waveform",accent:session.accent); if let active{reader(active)}else{catalogue}}.nodusPageBackdrop(accent:session.accent).task{await load()}.nodusSheet(isPresented:$pairing){DesktopBridgePairingSheet(accent:session.accent){Task{await load()}}}.accessibilityIdentifier("study-recordings-workspace") }
    private var catalogue:some View { ScrollView{VStack(alignment:.leading,spacing:12){DesktopPageHeader(title:"Recordings",subtitle:"Private audio, transcripts and markers",systemImage:"waveform",accent:session.accent); if let issue{NodusNotice(tone:.info,title:"Direct Mac connection required",message:LocalizedStringKey(issue),systemImage:"lock.shield");Button("Pair Desktop Bridge"){pairing=true}.buttonStyle(NodusPrimaryButtonStyle(accent:session.accent))};ForEach(tables["study_recordings"] ?? [],id:\.columns){row in Button{open(row)}label:{HStack{Image(systemName:"waveform.circle.fill").font(.title2).foregroundStyle(session.accent);VStack(alignment:.leading){Text(row.text("title") ?? "Recording").font(.headline);Text("\(duration(row.int("duration_seconds") ?? 0)) · \(row.text("processing_status") ?? "pending")").font(.caption).foregroundStyle(.secondary)};Spacer();Image(systemName:"chevron.right").foregroundStyle(.secondary)}.desktopContentRow(accent:session.accent)}.buttonStyle(NodusCardButtonStyle())}}.padding(NodusSpace.page).frame(maxWidth:900).frame(maxWidth:.infinity).nodusTopAnchor()} }
    private func reader(_ recording:Row)->some View { let transcript=(tables["study_transcripts"] ?? []).first{$0.string("recording_id")==recording.string("id")};let markers=(tables["study_audio_markers"] ?? []).filter{$0.string("recording_id")==recording.string("id")};return ScrollView{VStack(alignment:.leading,spacing:14){DesktopPageHeader(title:LocalizedStringKey(recording.text("title") ?? "Recording"),subtitle:"\(duration(recording.int("duration_seconds") ?? 0)) · private",systemImage:"waveform",accent:session.accent);NodusNotice(tone:.info,title:"End-to-end private route",message:"Audio metadata and transcript were read from the paired Mac. Nothing is relayed through the Nodus cloud.",systemImage:"lock.shield.fill");ForEach(markers,id:\.columns){marker in HStack{Text(duration(Int(marker.double("seconds") ?? 0))).font(.caption.monospacedDigit()).foregroundStyle(session.accent);Text(marker.text("label") ?? "Marker");Spacer()}.desktopContentRow(accent:session.accent)};DesktopSectionHeader(title:"Transcript",subtitle:transcript?.text("kind") ?? "Not available",systemImage:"text.quote",accent:session.accent);Text(transcript?.text("content_markdown") ?? "No transcript").font(.body).textSelection(.enabled)}.padding(NodusSpace.page).frame(maxWidth:900).frame(maxWidth:.infinity).nodusTopAnchor()} }
    private func open(_ row:Row){guard let id=row.string("id")else{return};tabs.open(.init(id:id,title:row.text("title") ?? id,systemImage:"waveform",kind:.document,payload:.row(row)),in:section)}
    private func duration(_ seconds:Int)->String{"\(seconds/60):\(String(format:"%02d",seconds%60))"}
    private func load()async{do{tables=try await loadPrivateStudyTables(session,domain:.studyRecordings,names:["study_recordings","study_transcripts","study_transcript_segments","study_audio_markers"]);issue=nil}catch{tables=[:];issue=error.localizedDescription}}
}

// MARK: - Published Teaching authoring

private struct TeachingExamsWorkspace:View{
    @Environment(WorkspaceTabs.self)private var tabs;let session:SpaceSession;@State private var tables:[String:[Row]]=[:];private let section="teachingExams";private var active:Row?{(tables["teaching_exams"] ?? []).first{$0.string("id")==tabs.activeTabId(in:section)}}
    var body:some View{VStack(spacing:0){WorkspaceTabStrip(section:section,catalogueTitle:"Exams",catalogueImage:"note.text",accent:session.accent);if let active{exam(active)}else{catalogue}}.nodusPageBackdrop(accent:session.accent).task(id:session.publishedRevision){tables=(try? await loadStudyTeachingTables(session,studyPublicTables)) ?? [:]}.accessibilityIdentifier("teaching-exams-workspace")}
    private var catalogue:some View{ScrollView{VStack(alignment:.leading,spacing:12){DesktopPageHeader(title:"Exams",subtitle:"Papers, sections, questions and answer keys",systemImage:"note.text",accent:session.accent);ForEach(tables["teaching_exams"] ?? [],id:\.columns){row in Button{open(row)}label:{HStack{Image(systemName:"doc.text").font(.title2).foregroundStyle(session.accent);VStack(alignment:.leading){Text(row.text("title") ?? "Exam").font(.headline);Text("\(questions(row).count) questions · \(points(row),specifier:"%.0f") points").font(.caption).foregroundStyle(.secondary)};Spacer();Image(systemName:"chevron.right").foregroundStyle(.secondary)}.desktopContentRow(accent:session.accent)}.buttonStyle(NodusCardButtonStyle())}}.padding(NodusSpace.page).frame(maxWidth:900).frame(maxWidth:.infinity).nodusTopAnchor()}}
    private func exam(_ row:Row)->some View{ScrollView{VStack(alignment:.leading,spacing:12){DesktopPageHeader(title:LocalizedStringKey(row.text("title") ?? "Exam"),subtitle:"\(questions(row).count) questions · answer key available",systemImage:"doc.text",accent:session.accent);ForEach(Array(questions(row).enumerated()),id:\.element.columns){index,q in VStack(alignment:.leading,spacing:7){HStack(alignment:.top){Text("\(index+1).").font(.headline.monospacedDigit()).foregroundStyle(session.accent);Text(q.text("prompt") ?? "Question").font(.headline);Spacer();Text("\(q.double("points") ?? 0,specifier:"%.0f") pt").font(.caption).foregroundStyle(.secondary)};if let solution=q.text("solution"){VStack(alignment:.leading){Label("Answer key",systemImage:"key").font(.caption.weight(.semibold)).foregroundStyle(session.accent);Text(solution).font(.callout)}.padding(9).background(session.accent.opacity(0.08),in:RoundedRectangle(cornerRadius:8))}}.desktopContentRow(accent:session.accent)}}.padding(NodusSpace.page).frame(maxWidth:940).frame(maxWidth:.infinity).nodusTopAnchor()}}
    private func questions(_ exam:Row)->[Row]{(tables["teaching_exam_questions"] ?? []).filter{$0.string("exam_id")==exam.string("id")}.sorted{($0.int("position") ?? 0)<($1.int("position") ?? 0)}};private func points(_ exam:Row)->Double{questions(exam).reduce(0){$0+($1.double("points") ?? 0)}};private func open(_ row:Row){guard let id=row.string("id")else{return};tabs.open(.init(id:id,title:row.text("title") ?? id,systemImage:"doc.text",kind:.document,payload:.row(row)),in:section)}
}

private struct TeachingRubricsWorkspace:View{let session:SpaceSession;@State private var tables:[String:[Row]]=[:];@State private var selected:String?;private var rubrics:[StudyTeachingParity.Rubric]{StudyTeachingParity.rubrics(in:tables["teaching_rubrics"] ?? [])};private var active:StudyTeachingParity.Rubric?{rubrics.first{$0.id==(selected ?? rubrics.first?.id)}}
    var body:some View{HStack(spacing:0){VStack(alignment:.leading,spacing:8){Text("RUBRICS").font(.caption2.bold()).foregroundStyle(.secondary).padding(12);ForEach(rubrics){rubric in Button{selected=rubric.id}label:{Text(rubric.title).font(.caption).frame(maxWidth:.infinity,alignment:.leading).padding(9).background(rubric.id==active?.id ? session.accent.opacity(0.14):.clear,in:RoundedRectangle(cornerRadius:8))}.buttonStyle(.plain)}}.frame(width:260).background(Color(uiColor:.secondarySystemBackground).opacity(0.48));Divider();if let active{rubric(active)}else{ContentUnavailableView("No rubrics",systemImage:"tablecells")}}.nodusPageBackdrop(accent:session.accent).task(id:session.publishedRevision){tables=(try? await loadStudyTeachingTables(session,studyPublicTables)) ?? [:]}.accessibilityIdentifier("teaching-rubrics-workspace")}
    private func rubric(_ rubric:StudyTeachingParity.Rubric)->some View{ScrollView([.horizontal,.vertical]){VStack(alignment:.leading,spacing:12){DesktopPageHeader(title:LocalizedStringKey(rubric.title),subtitle:"\(rubric.criteria.count) criteria · scale \(String(format: "%.0f", rubric.scaleMax))",systemImage:"tablecells",accent:session.accent);Text(rubric.description).font(.callout).foregroundStyle(.secondary);VStack(spacing:0){HStack(spacing:0){Text("Criterion").frame(width:200,alignment:.leading);ForEach(rubric.levels){Text($0.label).frame(width:190,alignment:.leading)}}.font(.caption.bold()).padding(9).background(Color(uiColor:.secondarySystemBackground));ForEach(rubric.criteria){criterion in HStack(spacing:0){VStack(alignment:.leading){Text(criterion.label).font(.caption.weight(.semibold));Text("Weight \(criterion.weight,specifier:"%.0f")").font(.caption2).foregroundStyle(.secondary)}.frame(width:200,alignment:.leading);ForEach(rubric.levels){level in Text(criterion.descriptors[level.id] ?? "—").font(.caption).frame(width:190,alignment:.leading)}}.padding(9).overlay(alignment:.bottom){Divider()}}}}.padding(NodusSpace.page).nodusTopAnchor()}}
}

private struct DesktopSectionHeader: View {
    let title: LocalizedStringKey
    let subtitle: String
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

private struct TeachingUnitsWorkspace:View{let session:SpaceSession;@State private var tables:[String:[Row]]=[:];var body:some View{ScrollView{VStack(alignment:.leading,spacing:14){DesktopPageHeader(title:"Unit design",subtitle:"Inquiry, learning sequence, assessment and materials",systemImage:"safari",accent:session.accent);ForEach((tables["study_docs"] ?? []).filter{$0.text("kind")=="unit"},id:\.columns){unit in VStack(alignment:.leading,spacing:10){Text(unit.text("title") ?? "Unit").font(.title2.bold());Text(unit.text("description") ?? "").font(.callout).foregroundStyle(.secondary);Text(unit.text("content_markdown") ?? "").font(.body).textSelection(.enabled);HStack{Label("Learning sequence",systemImage:"list.number");Spacer();Label("Assessment linked",systemImage:"checkmark.seal")}.font(.caption).foregroundStyle(session.accent)}.desktopContentRow(accent:session.accent)}}.padding(NodusSpace.page).frame(maxWidth:940).frame(maxWidth:.infinity).nodusTopAnchor()}.nodusPageBackdrop(accent:session.accent).task(id:session.publishedRevision){tables=(try? await loadStudyTeachingTables(session,studyPublicTables)) ?? [:]}.accessibilityIdentifier("teaching-units-workspace")}}

// MARK: - Bridge pairing and loaders

struct DesktopBridgePairingSheet: View {
    let accent: Color
    let onPaired: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var origin = "https://"
    @State private var fingerprint = ""
    @State private var code = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Offer from Nodus Desktop") {
                    TextField("https://mac.local:4545", text: $origin)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                    TextField("SHA-256 certificate fingerprint", text: $fingerprint)
                        .textInputAutocapitalization(.characters).font(.caption.monospaced())
                    TextField("Pairing code", text: $code).textInputAutocapitalization(.characters)
                }
                Section {
                    NodusNotice(
                        tone: .info, title: "Direct HTTPS only",
                        message: "The certificate is pinned before the first request. Pairing never creates a cloud relay and grants only the vaults and private domains shown on the Mac.",
                        systemImage: "lock.shield"
                    )
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Pair Desktop Bridge")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair") { Task { await pair() } }
                        .disabled(working || origin.count < 9 || fingerprint.isEmpty || code.isEmpty)
                }
            }
        }
        .tint(accent)
    }

    private func pair() async {
        working = true
        defer { working = false }
        do {
            let result = try await DesktopBridgeClient.pair(
                origin: origin, certificateFingerprint: fingerprint, code: code,
                deviceId: UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString,
                deviceName: UIDevice.current.name
            )
            try DesktopBridgePairingStore().save(result.pairing, token: result.token)
            onPaired()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

@MainActor
private func loadStudyTeachingTables(_ session:SpaceSession,_ names:[String])async throws->[String:[Row]]{let fixture=debugStudyTeachingFixture();if !fixture.isEmpty{return Dictionary(uniqueKeysWithValues:names.map{($0,fixture[$0] ?? [])})};if let mirror=session.mirror{var result:[String:[Row]]=[:];for name in names{result[name]=try await mirror.allRows(table:name)};return result};let snapshot=try await session.client.snapshot(in:session.connection.spaceId);return Dictionary(uniqueKeysWithValues:names.map{($0,snapshot.tables[$0] ?? [])})}

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
