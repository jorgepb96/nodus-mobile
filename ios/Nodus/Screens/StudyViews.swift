import NodusKit
import NodusUI
import SwiftUI

/// The weekly timetable, from `study_schedule_periods` and `study_schedule_cells`.
///
/// Both are published for study and teaching vaults, so this works for a student looking up
/// where to be and for a teacher checking the same thing. It needs the offline copy: the two
/// tables have no REST collection, and the API cannot filter by a column even where it does.
struct ScheduleView: View {
    let session: SpaceSession

    @State private var periods: [Row] = []
    @State private var cells: [Row] = []
    @State private var subjects: [String: Row] = [:]
    @State private var isLoading = true
    @State private var needsMirror = false
    @State private var error: String?

    private let days = [String(localized: "Monday"), String(localized: "Tuesday"), String(localized: "Wednesday"), String(localized: "Thursday"), String(localized: "Friday"), String(localized: "Saturday"), String(localized: "Sunday")]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DesktopPageHeader(
                    title: "Timetables",
                    subtitle: "Weekly periods, subjects and rooms",
                    systemImage: "calendar",
                    accent: session.accent
                )
                if needsMirror {
                    NodusNotice(
                        tone: .info,
                        title: "The offline copy is needed",
                        message: "The timetable travels in the publication but has no API route. Download it and it appears instantly.",
                        systemImage: "internaldrive"
                    )
                    Button {
                        Task { await session.downloadMirror(); await load() }
                    } label: {
                        Label("Download for offline use", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent))
                } else if isLoading {
                    ProgressView().tint(session.accent).frame(maxWidth: .infinity).padding(.top, 50)
                } else if let error {
                    NodusNotice(tone: .blocked, title: "Could not load the timetable", message: LocalizedStringKey(error))
                } else if periods.isEmpty {
                    ContentUnavailableView(
                        "No timetable",
                        systemImage: "calendar",
                        description: Text("This publication carries no time slots.")
                    )
                } else {
                    ForEach(activeDays, id: \.self) { day in
                        daySection(day)
                    }
                }
            }
            .padding(NodusSpace.page)
        }
        .navigationTitle("Timetables")
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        // The offline copy is the only source this screen has, and once one exists the screen
        // had no way to ask for a newer one: a republished timetable stayed invisible, or —
        // worse — a copy taken before the timetable was published kept saying the publication
        // carries no time slots. Pulling down fetches the copy again.
        .refreshable {
            await session.downloadMirror()
            await load()
        }
        .task(id: session.mirrorSummary?.revision) { await load() }
    }

    /// Only days that actually have something in them: a timetable with an empty Saturday
    /// should not spend a screenful saying so.
    private var activeDays: [Int] {
        let used = Set(cells.compactMap { $0.int("weekday") })
        return (0..<7).filter { used.contains($0) }
    }

    private func daySection(_ day: Int) -> some View {
        let dayCells = cells
            .filter { $0.int("weekday") == day }
            .sorted { ($0.int("period_index") ?? 0) < ($1.int("period_index") ?? 0) }

        return VStack(alignment: .leading, spacing: 8) {
            Text(days[min(day, 6)])
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 0) {
                ForEach(Array(dayCells.enumerated()), id: \.offset) { index, cell in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(periodLabel(cell))
                                .font(.caption.weight(.medium).monospacedDigit())
                                .foregroundStyle(session.accent)
                            if let room = cell.text("room") ?? cell.text("location") {
                                Text(room).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 96, alignment: .leading)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(subjectName(cell)).font(.callout)
                            if let note = cell.text("note") ?? cell.text("group_name") {
                                Text(note).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 9)
                    if index < dayCells.count - 1 { Divider().opacity(0.3) }
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nodusGlass(NodusGlass(.thin, tint: session.accent))
        }
    }

    private func periodLabel(_ cell: Row) -> String {
        guard let index = cell.int("period_index") else { return "—" }
        let period = periods.first { $0.int("order_idx") == index || $0.int("index") == index }
        if let start = period?.text("start_time"), let end = period?.text("end_time") {
            return "\(start)–\(end)"
        }
        return "\(index + 1).ª"
    }

    private func subjectName(_ cell: Row) -> String {
        if let id = cell.string("subject_id"), let subject = subjects[id] {
            // `String(localized:)`, not a literal: this is a computed value handed to `Text`,
            // and a literal here ships in one language whatever the phone is set to. These two
            // were Spanish, on a screen the rest of which translates.
            return subject.text("name") ?? subject.text("title") ?? String(localized: "Subject")
        }
        return cell.text("label") ?? cell.text("title") ?? String(localized: "Unassigned")
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let mirror = session.mirror else {
            needsMirror = true
            return
        }
        needsMirror = false
        do {
            periods = try await mirror.allRows(table: "study_schedule_periods")
            cells = try await mirror.allRows(table: "study_schedule_cells")
            let subjectRows = try await mirror.allRows(table: "study_subjects")
        // `id`, not `subject_id`. Every study and teaching table names its primary key `id`
        // (migrations.ts:1573 onwards) — the same mistake that once made nine collections
        // unopenable, still alive here: the dictionary was always empty, so every cell in
        // every timetable said "Unassigned" over a subject the publication carried.
        // `subject_id` is kept as a fallback for a row that really does name itself that way.
            subjects = Dictionary(subjectRows.compactMap { row in
                (row.string("id") ?? row.string("subject_id")).map { ($0, row) }
            }, uniquingKeysWith: { first, _ in first })
            error = nil
        } catch {
            periods = []; cells = []; subjects = [:]
            self.error = error.localizedDescription
        }
    }
}

/// Flashcards, one at a time, tap to turn over.
///
/// A study deck is the one thing on a phone that beats the desktop, so it gets a real card
/// rather than a list row: full width, the answer hidden until asked for, and a swipe to move
/// on. Review state is not published — the desktop keeps the SRS schedule — so this is
/// reading and self-testing, not scheduling, and the screen does not pretend otherwise.
struct FlashcardsView: View {
    let session: SpaceSession

    @State private var cards: [Row] = []
    @State private var index = 0
    @State private var revealed = false
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            DesktopPageHeader(
                title: "Flashcards",
                subtitle: "Review the cards published from Desktop",
                systemImage: "rectangle.on.rectangle",
                accent: session.accent
            )

            if isLoading {
                ProgressView().tint(session.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                NodusNotice(tone: .blocked, title: "Could not load", message: LocalizedStringKey(error))
                    .frame(maxHeight: .infinity, alignment: .top)
            } else if cards.isEmpty {
                ContentUnavailableView("No flashcards", systemImage: "rectangle.on.rectangle")
                    .frame(maxHeight: .infinity)
            } else {
                Text("\(index + 1) of \(cards.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                card(cards[index])
                    .onTapGesture { withAnimation(NodusMotion.press) { revealed.toggle() } }

                HStack(spacing: 14) {
                    Button {
                        move(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(NodusGlassIconButtonStyle(accent: session.accent))
                    .disabled(index == 0)

                    Button {
                        withAnimation(NodusMotion.press) { revealed.toggle() }
                    } label: {
                        Text(revealed ? "Hide" : "Show answer").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent))

                    Button {
                        move(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(NodusGlassIconButtonStyle(accent: session.accent))
                    .disabled(index >= cards.count - 1)
                }

                Text("Nodus desktop keeps the review schedule; here you can review, not reschedule.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)

                Spacer(minLength: 0)
            }
        }
        .padding(NodusSpace.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Flashcards")
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .task(id: session.publishedRevision) { await load() }
    }

    private func card(_ row: Row) -> some View {
        VStack(spacing: 14) {
            Text(row.text("front") ?? "—")
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)

            if revealed {
                Divider().opacity(0.4)
                Text(row.text("back") ?? "—")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                Image(systemName: "hand.tap")
                    .font(.title3)
                    .foregroundStyle(session.accent.opacity(0.6))
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, minHeight: 260)
        .nodusGlass(NodusGlass(.prominent, tint: session.accent, interactive: true),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    withAnimation(NodusMotion.press) {
                        move(by: value.translation.width < 0 ? 1 : -1)
                    }
                }
        )
    }

    private func move(by delta: Int) {
        let next = index + delta
        guard next >= 0, next < cards.count else { return }
        index = next
        revealed = false
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let collection = Collections["study-flashcards"] else { return }
        do {
            cards = try await session.client.allItems(collection, in: session.connection.spaceId)
        } catch let apiError as APIError where apiError.isNotPublished {
            cards = []
        } catch where error.isCancellation {
            // Superseded or let go of. Nothing failed, so nothing is reported.
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A complete question catalogue with stable identities, native filters and original dossiers.
struct QuestionBankView: View {
    let session: SpaceSession
    @State private var questions: [Row] = []
    @State private var query = ""
    @State private var revealed = Set<String>()
    @State private var status = ""
    @State private var difficulty = ""
    @State private var questionType = ""
    @State private var favoritesOnly = false
    @State private var isLoading = true
    @State private var error: String?
    private struct Entry: Identifiable { let id: String; let row: Row }
    private var filtered: [Entry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return questions.compactMap { row in
            guard let id = row.string("id"), needle.isEmpty || row.searchableText.lowercased().contains(needle),
                  status.isEmpty || row.string("status") == status,
                  difficulty.isEmpty || row.string("difficulty") == difficulty,
                  questionType.isEmpty || (row.string("question_type") ?? row.string("type")) == questionType,
                  !favoritesOnly || row["favorite"]?.boolValue == true else { return nil }
            return Entry(id: id, row: row)
        }
    }
    var body: some View {
        List {
            ForEach(filtered) { entry in
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.row.text("prompt") ?? entry.row.text("title") ?? String(localized: "Question"))
                        .font(.callout.weight(.medium)).lineLimit(5).fixedSize(horizontal: false, vertical: true)
                    FlowLayout(spacing: 8) {
                        ForEach(["question_type", "difficulty", "cognitive_level", "status"], id: \.self) { key in
                            if let text = entry.row.text(key) { NodusChip(StudyOriginalMetadata.label(text), tint: session.accent, capitalises: false) }
                        }
                        if entry.row["favorite"]?.boolValue == true { Image(systemName: "star.fill").foregroundStyle(session.accent).accessibilityLabel("Favorita") }
                    }
                    if revealed.contains(entry.id) {
                        if let answer = (entry.row.embeddedJSON("answer_json") ?? entry.row.embeddedJSON("answer"))?.objectValue {
                            CorpusProse(StudyChatQuestionContent.answerText(answer), accent: session.accent, session: session)
                        } else if let text = entry.row.text("answer") ?? entry.row.text("solution") { CorpusProse(text, accent: session.accent, session: session) }
                        if let explanation = entry.row.text("explanation") { CorpusProse(explanation, accent: session.accent, session: session) }
                    }
                    HStack(spacing: 20) {
                        Button(revealed.contains(entry.id) ? "Ocultar respuesta" : "Mostrar respuesta") {
                            if revealed.contains(entry.id) { revealed.remove(entry.id) } else { revealed.insert(entry.id) }
                        }.frame(minHeight: 44).buttonStyle(.borderless)
                        NavigationLink {
                            if session.connection.desktopPairingId != nil {
                                StudyChatOriginalView(kind: "question", id: entry.id, session: session)
                            } else { RowDetailView(session: session, collection: Collections["study-questions"], row: entry.row) }
                        } label: { Label("Abrir", systemImage: "arrow.up.right.square").frame(minHeight: 44) }
                        .buttonStyle(.borderless)
                    }.font(.subheadline)
                }.padding(.vertical, 8).listRowBackground(Color.clear)
            }
            if isLoading { ProgressView("Loading questions…").frame(maxWidth: .infinity).listRowBackground(Color.clear) }
            if let error {
                NodusNotice(tone: .blocked, title: "Could not load questions", message: LocalizedStringKey(error)).listRowBackground(Color.clear)
                Button("Retry") { Task { await load() } }.frame(minHeight: 44).listRowBackground(Color.clear)
            }
            if filtered.isEmpty, !isLoading, error == nil {
                ContentUnavailableView(questions.isEmpty ? "No questions" : "Sin coincidencias", systemImage: "checklist").listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden).nodusDismissesKeyboard().listStyle(.plain)
        .listRowSeparatorTint(Color.nodusTertiaryText.opacity(0.45))
        .navigationTitle("Question bank").navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 9) {
                NodusSearchField(text: $query, prompt: "Filter questions", accent: session.accent)
                HStack {
                    Text("\(filtered.count) de \(questions.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Picker("Estado", selection: $status) { Text("Todos").tag(""); ForEach(values("status"), id: \.self) { Text(StudyOriginalMetadata.label($0)).tag($0) } }
                        Picker("Dificultad", selection: $difficulty) { Text("Todas").tag(""); ForEach(values("difficulty"), id: \.self) { Text(StudyOriginalMetadata.label($0)).tag($0) } }
                        Picker("Tipo", selection: $questionType) { Text("Todos").tag(""); ForEach(values("question_type"), id: \.self) { Text(StudyOriginalMetadata.label($0)).tag($0) } }
                        Toggle("Solo favoritas", isOn: $favoritesOnly)
                        Button("Restablecer filtros") { status = ""; difficulty = ""; questionType = ""; favoritesOnly = false }
                    } label: { Label("Filtros", systemImage: "line.3.horizontal.decrease").frame(minHeight: 44) }
                }
            }.padding(.horizontal, NodusSpace.page).padding(.vertical, 6)
                .background(Color(uiColor: .systemBackground).opacity(0.97))
        }
        .task(id: session.publishedRevision) { await load() }
    }
    private func values(_ key: String) -> [String] { Set(questions.compactMap { $0.text(key) }).sorted() }
    private func load() async {
        isLoading = true; defer { isLoading = false }
        guard let collection = Collections["study-questions"] else { error = "El catálogo de preguntas no está disponible."; return }
        do { questions = try await session.client.allItems(collection, in: session.connection.spaceId); error = nil }
        catch where error.isCancellation {}
        catch { self.error = error.localizedDescription }
    }
}
