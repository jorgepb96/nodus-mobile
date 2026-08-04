import NodusKit
import NodusUI
import SwiftUI

/// What a study or teaching vault has on, day by day.
///
/// Two tables carry a moment in time — `study_calendar_events` and `study_plan_blocks` — and
/// they answer the same question, so they are read together and shown together. A calendar
/// entry is a fixed appointment; a plan block is time the planner set aside. Both belong on
/// the same day, distinguished by their mark rather than by living on separate screens.
///
/// The timetable is deliberately not here. It is a *weekly* shape with no dates in it at all,
/// and folding a repeating grid into a list of days would invent occurrences the vault never
/// recorded.
struct AgendaView: View {
    let session: SpaceSession

    @State private var agenda: StudyAgenda?
    @State private var window: Window = .ahead
    @State private var isLoading = true
    @State private var error: String?

    enum Window: String, CaseIterable, Identifiable {
        case ahead
        case past
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .ahead: return "What is coming"
            case .past: return "What has been"
            }
        }

        /// A window either side of now. Bounded on both ends on purpose: an unbounded agenda
        /// over a vault with three years of planning is a list nobody scrolls to the end of.
        func range(from now: Date) -> (from: Date, to: Date) {
            switch self {
            case .ahead: return (now.addingTimeInterval(-86_400), now.addingTimeInterval(86_400 * 60))
            case .past: return (now.addingTimeInterval(-86_400 * 90), now)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Window", selection: $window) {
                    ForEach(Window.allCases) { value in
                        Text(value.label).tag(value)
                    }
                }
                .pickerStyle(.segmented)

                if let error {
                    NodusNotice(tone: .blocked, title: "Could not load the agenda", message: LocalizedStringKey(error))
                } else if isLoading {
                    ProgressView().tint(session.accent).frame(maxWidth: .infinity).padding(.top, 50)
                } else if let agenda, agenda.isEmpty {
                    ContentUnavailableView(
                        window == .ahead ? "Nothing ahead" : "Nothing behind",
                        systemImage: "calendar",
                        description: Text(window == .ahead
                            ? "No event or planned block in the next two months."
                            : "No event or planned block in the last three months.")
                    )
                    .padding(.top, 30)
                } else if let agenda {
                    ForEach(days(of: agenda), id: \.key) { day in
                        daySection(day, in: agenda)
                    }
                    if agenda.hasMore {
                        Text("Only the first entries of this window are shown.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .nodusTopAnchor()
        }
        .nodusPageFunctions(accent: session.accent)
        .navigationTitle("Agenda")
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .task(id: window) { await load() }
        .refreshable { await load() }
    }

    // MARK: Grouping

    /// One entry on the agenda, whichever table it came from.
    struct Entry: Identifiable {
        enum Kind { case event, block }
        let kind: Kind
        let row: Row
        let start: Date
        var id: String { "\(kind == .event ? "e" : "b"):\(row.string("id") ?? UUID().uuidString)" }
    }

    struct Day {
        let key: String
        let date: Date
        let entries: [Entry]
    }

    private func days(of agenda: StudyAgenda) -> [Day] {
        let entries = agenda.events.compactMap { entry(from: $0, kind: .event) }
            + agenda.blocks.compactMap { entry(from: $0, kind: .block) }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.start) }
        return grouped
            .map { Day(key: ISO8601DateFormatter().string(from: $0.key), date: $0.key, entries: $0.value.sorted { $0.start < $1.start }) }
            // Coming up reads forwards; what has been reads backwards, most recent first.
            .sorted { window == .ahead ? $0.date < $1.date : $0.date > $1.date }
    }

    private func entry(from row: Row, kind: Entry.Kind) -> Entry? {
        guard let start = row.date("starts_at") else { return nil }
        return Entry(kind: kind, row: row, start: start)
    }

    // MARK: Rendering

    private func daySection(_ day: Day, in agenda: StudyAgenda) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: day.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.subheadline.weight(.semibold))
                if Calendar.current.isDateInToday(day.date) {
                    Text("Today")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(session.accent)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(session.accent.opacity(0.16), in: Capsule())
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(day.entries.enumerated()), id: \.offset) { index, item in
                    row(item, in: agenda)
                    if index < day.entries.count - 1 { Divider().opacity(0.35) }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nodusGlass(NodusGlass(.thin, tint: session.accent))
        }
    }

    private func row(_ item: Entry, in agenda: StudyAgenda) -> some View {
        let subject = agenda.subject(item.row.string("subject_id"))
        // An event is `completed`; a block has a `status`, and its done value is `completed`
        // too (`shared/studyPlanner.ts:3` — planned | completed | skipped).
        let done = item.row.bool("completed") == true || item.row.text("status") == "completed"
        return HStack(alignment: .top, spacing: 11) {
            VStack(spacing: 3) {
                Image(systemName: item.kind == .event ? "calendar" : "timer")
                    .font(.caption)
                    .foregroundStyle(session.accent)
                Text(verbatim: item.row.bool("all_day") == true
                    ? String(localized: "All day")
                    : item.start.formatted(date: .omitted, time: .shortened))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 54)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.row.text("title") ?? "—")
                    .font(.subheadline)
                    .strikethrough(done, color: .secondary)
                    .foregroundStyle(done ? .secondary : .primary)
                HStack(spacing: 6) {
                    if let name = subject?.name {
                        Text(verbatim: name).font(.caption2).foregroundStyle(session.accent)
                    }
                    if let minutes = item.row.int("duration_minutes"), minutes > 0 {
                        Text("\(minutes) min").font(.caption2).foregroundStyle(.secondary)
                    }
                    // Only the calendar's kind, and only because it is a closed vocabulary
                    // that can be translated. A block's `type` is a free string in the schema
                    // (`shared/studyPlanner.ts:3`), so printing it would put whatever the
                    // planner happened to write, in whatever language, beside translated text.
                    if let kind = Self.eventLabel(item.row.text("event_type")) {
                        Text(kind).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if let notes = item.row.text("notes") {
                    Text(verbatim: notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }

    /// The four kinds a study calendar entry can be (`shared/studyPlanner.ts:1`). Anything
    /// else is a value this app does not know the words for, and is left unsaid rather than
    /// printed raw beside translated text.
    static func eventLabel(_ type: String?) -> LocalizedStringKey? {
        switch type {
        case "exam": return "Exam"
        case "assignment": return "Assignment"
        case "class": return "Class"
        case "session": return "Study session"
        default: return nil
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let range = window.range(from: Date())
        do {
            agenda = try await session.client.studyAgenda(
                in: session.connection.spaceId,
                from: range.from,
                to: range.to,
                limit: PageBounds.maxLimit
            )
            error = nil
        } catch where error.isCancellation {
            // Superseded or let go of. Nothing failed, so nothing is reported.
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The goals a study vault set itself, and how far along they are.
///
/// `current_value` is the vault's own count, not this app's: the phone reads a number the
/// desktop keeps and never advances it, because progress is earned by studying rather than by
/// looking at a screen.
struct GoalsView: View {
    let session: SpaceSession

    @State private var goals: [Row] = []
    @State private var isLoading = true
    @State private var error: String?

    private var open: [Row] { goals.filter { $0.bool("completed") != true } }
    private var done: [Row] { goals.filter { $0.bool("completed") == true } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error {
                    NodusNotice(tone: .blocked, title: "Could not load", message: LocalizedStringKey(error))
                } else if isLoading {
                    ProgressView().tint(session.accent).frame(maxWidth: .infinity).padding(.top, 50)
                } else if goals.isEmpty {
                    ContentUnavailableView(
                        "No goals",
                        systemImage: "target",
                        description: Text("This publication carries no goal.")
                    )
                    .padding(.top, 30)
                } else {
                    if !open.isEmpty { group("In progress", open) }
                    if !done.isEmpty { group("Met", done) }
                }
            }
            .padding(16)
            .nodusTopAnchor()
        }
        .nodusPageFunctions(accent: session.accent)
        .navigationTitle("Goals")
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .task { if goals.isEmpty { await load() } }
        .refreshable { await load() }
    }

    private func group(_ title: LocalizedStringKey, _ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    goal(row)
                    if index < rows.count - 1 { Divider().opacity(0.35) }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nodusGlass(NodusGlass(.thin, tint: session.accent))
        }
    }

    private func goal(_ row: Row) -> some View {
        let target = row.double("target_value") ?? 0
        let current = row.double("current_value") ?? 0
        // A target of zero is not a goal at zero per cent; it is a goal with no target, and a
        // progress bar would be inventing a denominator.
        let fraction = target > 0 ? min(1, max(0, current / target)) : nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: row.text("title") ?? "—").font(.subheadline)
                Spacer(minLength: 6)
                Text(verbatim: "\(Self.number(current)) / \(Self.number(target)) \(row.text("unit") ?? "")")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let fraction {
                ProgressView(value: fraction).tint(session.accent)
            }
            HStack(spacing: 8) {
                if let period = Self.periodLabel(row.text("period")) {
                    Text(period).font(.caption2).foregroundStyle(session.accent.opacity(0.85))
                }
                if let starts = row.date("starts_at") {
                    Text(verbatim: starts.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
    }

    /// The three periods a goal can run over (`shared/studyPlanner.ts:6`).
    static func periodLabel(_ period: String?) -> LocalizedStringKey? {
        switch period {
        case "daily": return "Daily"
        case "weekly": return "Weekly"
        case "monthly": return "Monthly"
        default: return nil
        }
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let collection = Collections["study-goals"] else { return }
        do {
            goals = try await session.client.list(collection, in: session.connection.spaceId, limit: PageBounds.maxLimit).items
            error = nil
        } catch where error.isCancellation {
            // Superseded or let go of. Nothing failed, so nothing is reported.
        } catch {
            self.error = error.localizedDescription
        }
    }
}
