import NodusKit
import NodusUI
import SwiftUI

/// The published Immersion catalogue uses the same gallery grammar as Deep Research: a clear
/// workspace heading, one search-and-sort row, and equivalent list/grid cards. The sessions
/// keep private progress separate from the published plan.
struct ImmersionLibraryView: View {
    let session: SpaceSession

    @State private var rows: [Row] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var query = ""
    @AppStorage("immersion.gallery-view") private var galleryView = "list"
    @AppStorage("immersion.gallery-sort") private var gallerySort = "newest"

    private var visible: [Row] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result = rows.filter { row in
            guard !needle.isEmpty else { return true }
            return [row.text("title"), row.text("topic"), row.text("language")]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(needle) }
        }
        switch gallerySort {
        case "oldest":
            result.sort { immersionDate($0) < immersionDate($1) }
        case "title":
            result.sort {
                immersionTitle($0).localizedCaseInsensitiveCompare(immersionTitle($1)) == .orderedAscending
            }
        default:
            result.sort { immersionDate($0) > immersionDate($1) }
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                workspaceHeader
                if let error {
                    NodusNotice(
                        tone: .caution,
                        title: "Immersion sessions are unavailable",
                        message: LocalizedStringKey(error)
                    )
                }
                galleryControls
                gallery
            }
            .padding(NodusSpace.page)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
            .nodusTopAnchor()
        }
        .nodusDismissesKeyboard()
        .navigationTitle("Immersion")
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .task(id: session.publishedRevision) { await load() }
        .refreshable { await load() }
    }

    private var workspaceHeader: some View {
        DesktopPageHeader(
            title: "Immersion",
            subtitle: "Guided paths grounded in the current corpus",
            systemImage: "scope",
            accent: session.accent
        )
    }

    private var galleryControls: some View {
        VStack(spacing: 10) {
            NodusSearchField(text: $query, prompt: "Filter sessions", accent: session.accent, isBusy: isLoading)
            HStack(spacing: 8) {
                Menu {
                    Picker("Sort sessions", selection: $gallerySort) {
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

                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var gallery: some View {
        if isLoading, rows.isEmpty {
            ProgressView("Loading sessions…")
                .tint(session.accent)
                .frame(maxWidth: .infinity, minHeight: 300)
        } else if visible.isEmpty {
            ContentUnavailableView(
                query.isEmpty ? "No sessions" : "No matches",
                systemImage: "scope",
                description: Text(query.isEmpty ? "Published immersion sessions will appear here." : "Change the search or sort order.")
            )
            .frame(maxWidth: .infinity, minHeight: 300)
        } else if galleryView == "grid" {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                ForEach(visible, id: \.columns) { row in galleryCell(row, grid: true) }
            }
        } else {
            LazyVStack(spacing: 8) {
                ForEach(visible, id: \.columns) { row in galleryCell(row, grid: false) }
            }
        }
    }

    private func galleryCell(_ row: Row, grid: Bool) -> some View {
        NavigationLink {
            ImmersionView(
                session: session,
                sessionId: row.string("id") ?? "",
                title: immersionTitle(row)
            )
        } label: {
            ImmersionGalleryCard(row: row, grid: grid, session: session)
        }
        .buttonStyle(.plain)
        .disabled(row.string("id") == nil)
    }

    private var sortLabel: String {
        switch gallerySort {
        case "oldest": String(localized: "Oldest")
        case "title": String(localized: "Title")
        default: String(localized: "Newest")
        }
    }

    private func immersionTitle(_ row: Row) -> String {
        row.text("title") ?? row.text("topic") ?? String(localized: "Session")
    }

    private func immersionDate(_ row: Row) -> Date {
        row.date("updated_at") ?? row.date("created_at") ?? .distantPast
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            rows = try await session.client.immersionSessions(
                in: session.connection.spaceId,
                limit: 100
            ).items
            error = nil
        } catch let apiError as APIError where apiError.isNotPublished {
            rows = []
            error = nil
        } catch where error.isCancellation {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ImmersionGalleryCard: View {
    let row: Row
    let grid: Bool
    let session: SpaceSession

    private var accent: Color { session.accent }
    private var stats: [String: JSONValue] {
        ((row.embeddedJSON("stats") ?? row["stats"])?.objectValue) ?? [:]
    }

    var body: some View {
        Group {
            if grid {
                VStack(alignment: .leading, spacing: 0) {
                    cover.frame(maxWidth: .infinity).frame(height: 142).clipped()
                    details.padding(14)
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    cover.frame(width: 96, height: 58).clipped()
                    details
                    Spacer(minLength: 0)
                }
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity, minHeight: grid ? 224 : 78, alignment: .topLeading)
        .nodusGlass(NodusGlass(.regular, tint: accent))
        .contentShape(Rectangle())
    }

    private var cover: some View {
        ZStack {
            LinearGradient(
                colors: [accent.opacity(0.2), accent.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            NodusIcon(name: "scope", size: grid ? 30 : 20, weight: .medium)
                .foregroundStyle(accent.opacity(0.7))
            if let hash = (row.embeddedJSON("image") ?? row["image"])?.objectValue?["hash"]?.stringValue {
                AssetImage(session: session, hash: hash)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: grid ? 16 : 9, style: .continuous))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.text("title") ?? row.text("topic") ?? String(localized: "Session"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(grid ? 3 : 2)
            if let topic = row.text("topic"), topic != row.text("title") {
                Text(topic).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 10) {
                if let stations = stats["stations"]?.intValue { Label(stations.formatted(), systemImage: "flag") }
                if let works = stats["works"]?.intValue { Label(works.formatted(), systemImage: "books.vertical") }
                if let minutes = row.int("minutes") { Label("\(minutes) min", systemImage: "clock") }
                if let date = row.date("updated_at") ?? row.date("created_at") {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An immersion session, read as the study route it is.
///
/// The published plan is a whole itinerary — an overview, stations with prose and quizzes,
/// a contrast table of who argues what, the open frontiers of the corpus, and a final exam.
/// Until now the app opened it through the generic row viewer, which showed the plan as one
/// enormous JSON column: technically the data, and unreadable.
///
/// `progress_json` is deliberately never published (`server/lib/routes/corpus.mjs`), so this
/// private progress synchronizes separately through the paired Mac's writing grant.
struct ImmersionView: View {
    let session: SpaceSession
    let sessionId: String
    let title: String
    var localPlan: ImmersionPlan? = nil
    var publicationId: String? = nil

    @State private var plan: ImmersionPlan?
    @State private var error: String?
    @State private var progressController: ImmersionProgressController?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error {
                    NodusNotice(tone: .blocked, title: "Could not open the session", message: LocalizedStringKey(error))
                } else if let plan {
                    // The numbers are the reading order the find bar walks: an itinerary is
                    // read from its overview down to its frontiers, whatever the layout does.
                    header(plan).nodusSearchOrder(1)
                    if let progressController {
                        ImmersionProgressStatus(controller: progressController, questions: plan.stations.flatMap(\.quiz) + plan.exam,
                            totalSteps: plan.stations.count + 4, accent: session.accent)
                    }
                    if !plan.overview.isEmpty {
                        card(title: "Overview", icon: "text.alignleft") {
                            CorpusProse(plan.overview, accent: session.accent, session: session)
                        }
                        .nodusSearchOrder(2)
                        if let progressController { ImmersionStepControl(controller: progressController, index: 0, accent: session.accent) }
                    }
                    stations(plan).nodusSearchOrder(3)
                    if !plan.keyTerms.isEmpty { keyTerms(plan).nodusSearchOrder(4) }
                    if !plan.contrasts.isEmpty { contrasts(plan).nodusSearchOrder(5) }
                    if let progressController { ImmersionStepControl(controller: progressController, index: plan.stations.count + 1, label: "Marcar contraste como leído", accent: session.accent) }
                    if !plan.frontiers.isEmpty { frontiers(plan).nodusSearchOrder(6) }
                    if let progressController { ImmersionStepControl(controller: progressController, index: plan.stations.count + 2, label: "Marcar fronteras como leídas", accent: session.accent) }
                    if !plan.exam.isEmpty { examLink(plan) }
                } else {
                    ProgressView().tint(session.accent).frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(16)
            .nodusTopAnchor()
        }
        .nodusPageFunctions(accent: session.accent)
        .navigationTitle("Immersion")
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .task(id: session.publishedRevision) { await load() }
        .onChange(of: session.companionImmersionProgressRevision) { _, _ in Task { await progressController?.reloadLocal() } }
    }

    // MARK: Pieces

    private func header(_ plan: ImmersionPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PageText(plan.title.isEmpty ? title : plan.title, order: 0).font(.title3.weight(.semibold))
            if !plan.topic.isEmpty {
                PageText(plan.topic, order: 1).font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if plan.minutes > 0 { Label("\(plan.minutes) min", systemImage: "clock") }
                Label("\(plan.stations.count)", systemImage: "flag")
                if plan.quizCount > 0 { Label("\(plan.quizCount)", systemImage: "checklist") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .nodusGlass(NodusGlass(.regular, tint: session.accent))
    }

    private func stations(_ plan: ImmersionPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stations").font(.subheadline.weight(.semibold))
            ForEach(Array(plan.stations.enumerated()), id: \.element.id) { index, station in
                NavigationLink {
                    ImmersionStationView(session: session, station: station, number: index + 1, progressController: progressController)
                } label: {
                    HStack(alignment: .top, spacing: 11) {
                            Text("\(index + 1)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .frame(width: 24, height: 24)
                            .background(session.accent.opacity(0.18), in: Circle())
                            .foregroundStyle(session.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            PageText(station.title, order: 0).font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !station.question.isEmpty {
                                PageText(station.question, order: 1)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            HStack(spacing: 10) {
                                if station.minutes > 0 { Label("\(station.minutes) min", systemImage: "clock") }
                                if !station.quiz.isEmpty { Label("\(station.quiz.count)", systemImage: "checklist") }
                                if !station.citations.isEmpty { Label("\(station.citations.count)", systemImage: "text.quote") }
                            }
                            .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(13)
                    .nodusGlass(NodusGlass(.thin, tint: session.accent, interactive: true))
                }
                .buttonStyle(.plain)
                .nodusSearchOrder(index)
            }
        }
    }

    private func keyTerms(_ plan: ImmersionPlan) -> some View {
        card(title: "Key terms", icon: "character.book.closed") {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(plan.keyTerms.enumerated()), id: \.element.term) { index, term in
                    VStack(alignment: .leading, spacing: 2) {
                        PageText(term.term, order: 0).font(.caption.weight(.semibold))
                        PageText(term.definition, order: 1).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .nodusSearchOrder(index)
                }
            }
        }
    }

    /// Who argues what, station by station.
    ///
    /// The desktop draws this as a matrix of authors × stations. A phone has no room for a
    /// table that wide, so the same cells are read down instead of across — by station, then by
    /// author — which loses the side-by-side glance and keeps every position intact.
    private func contrasts(_ plan: ImmersionPlan) -> some View {
        card(title: "Positions in contrast", icon: "person.2") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(plan.contrasts.enumerated()), id: \.element.stationId) { index, row in
                    VStack(alignment: .leading, spacing: 6) {
                        PageText(row.question, order: 0).font(.caption.weight(.semibold))
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { cellIndex, cell in
                            VStack(alignment: .leading, spacing: 2) {
                                PageText(cell.author, order: 0)
                                    .font(.caption2.weight(.medium)).foregroundStyle(session.accent)
                                PageText(cell.stance, order: 1).font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .nodusSearchOrder(cellIndex + 1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .nodusSearchOrder(index)
                }
            }
        }
    }

    private func frontiers(_ plan: ImmersionPlan) -> some View {
        card(title: "Open frontiers", icon: "questionmark.diamond") {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(plan.frontiers.enumerated()), id: \.offset) { index, frontier in
                    VStack(alignment: .leading, spacing: 2) {
                        PageText(frontier.statement, order: 0).font(.caption)
                        if let detail = frontier.detail, !detail.isEmpty {
                            PageText(detail, order: 1).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .nodusSearchOrder(index)
                }
            }
        }
    }

    private func examLink(_ plan: ImmersionPlan) -> some View {
        NavigationLink {
            ImmersionQuizView(
                title: String(localized: "Final exam"),
                questions: plan.exam,
                feynman: plan.feynman,
                accent: session.accent, controller: progressController, stepIndex: plan.stations.count + 3, finalExam: true
            )
        } label: {
            HStack {
                Label("Final exam", systemImage: "graduationcap")
                Spacer()
                Text("\(plan.exam.count)").font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(15)
            .nodusGlass(NodusGlass(.regular, tint: session.accent, interactive: true))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func card<Content: View>(title: LocalizedStringKey, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(session.accent)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .nodusGlass(NodusGlass(.thin, tint: session.accent))
    }

    private func load() async {
        do {
            let loaded: ImmersionPlan
            if let localPlan { loaded = localPlan }
            else {
                let detail = try await session.client.immersionSession(sessionId, in: session.connection.spaceId)
                guard let parsed = ImmersionPlan(detail) else { throw DesktopBridgeError.malformedResponse }; loaded = parsed
            }
            try Task.checkCancellation(); plan = loaded; error = nil
            let controller = try ImmersionProgressController(session: session, sessionId: sessionId, plan: loaded, publicationId: publicationId)
            progressController = controller; await controller.load()
        } catch where error.isCancellation {
            // Superseded or let go of. Nothing failed, so nothing is reported.
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - One station

private struct ImmersionStationView: View {
    let session: SpaceSession
    let station: ImmersionPlan.Station
    let number: Int
    var progressController: ImmersionProgressController?

    private var accent: Color { session.accent }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Station \(number)").font(.caption).foregroundStyle(accent)
                    PageText(station.title, order: 0).font(.title3.weight(.semibold))
                    if !station.question.isEmpty {
                        PageText(station.question, order: 1).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .nodusGlass(NodusGlass(.regular, tint: accent))
                .nodusSearchOrder(1)

                if !station.context.isEmpty {
                    block("Why this matters", "map") { CorpusProse(station.context, accent: accent, session: session) }
                        .nodusSearchOrder(2)
                }
                if !station.synthesis.isEmpty {
                    block("Synthesis", "text.alignleft") { CorpusProse(station.synthesis, accent: accent, session: session) }
                        .nodusSearchOrder(3)
                }
                if !station.takeaways.isEmpty {
                    block("What to take away", "checkmark.circle") {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(Array(station.takeaways.enumerated()), id: \.offset) { index, line in
                                HStack(alignment: .top, spacing: 7) {
                                    Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(accent)
                                        .padding(.top, 6)
                                    PageText(line, order: index).font(.callout)
                                }
                            }
                        }
                    }
                    .nodusSearchOrder(4)
                }
                if !station.positions.isEmpty {
                    block("Who argues what", "person.2") {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(Array(station.positions.enumerated()), id: \.offset) { index, position in
                                VStack(alignment: .leading, spacing: 2) {
                                    PageText(position.name, order: 0)
                                        .font(.caption.weight(.semibold)).foregroundStyle(accent)
                                    PageText(position.position, order: 1)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .nodusSearchOrder(index)
                            }
                        }
                    }
                    .nodusSearchOrder(5)
                }
                if !station.citations.isEmpty {
                    block("Sources", "text.quote") {
                        VStack(alignment: .leading, spacing: 11) {
                            ForEach(Array(station.citations.enumerated()), id: \.offset) { index, citation in
                                VStack(alignment: .leading, spacing: 3) {
                                    if let url = citation.targetURL, let reference = CorpusReference(url) {
                                        NavigationLink { CorpusReferenceView(session: session, reference: reference) } label: {
                                            Label(citation.reference, systemImage: "text.quote").font(.caption.weight(.medium))
                                                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
                                        }.tint(accent)
                                    } else { PageText(citation.reference, order: 0).font(.caption2.weight(.medium)).foregroundStyle(accent) }
                                    if !citation.text.isEmpty {
                                        CorpusProse("“\(citation.text)”", accent: accent, session: session)
                                    }
                                    if !citation.commentary.isEmpty { CorpusProse(citation.commentary, accent: accent, session: session) }
                                    if !citation.whyItMatters.isEmpty { CorpusProse(citation.whyItMatters, accent: accent, session: session) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .nodusSearchOrder(index)
                            }
                        }
                    }
                    .nodusSearchOrder(6)
                }
                if !station.quiz.isEmpty {
                    NavigationLink {
                        ImmersionQuizView(title: String(localized: "Check yourself"), questions: station.quiz, feynman: nil, accent: accent,
                            controller: progressController, stepIndex: number)
                    } label: {
                        HStack {
                            Label("Check yourself", systemImage: "checklist")
                            Spacer()
                            Text("\(station.quiz.count)").font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(15)
                        .nodusGlass(NodusGlass(.regular, tint: accent, interactive: true))
                    }
                    .buttonStyle(.plain)
                }
                if let progressController { ImmersionStepControl(controller: progressController, index: number, accent: accent) }
            }
            .padding(16)
            .nodusTopAnchor()
        }
        .nodusPageFunctions(accent: accent)
        .nodusHidesBottomBar()
        .navigationTitle(station.title)
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: accent)
        .task(id: progressController?.loading) { await progressController?.visit(index: number) }
    }

    @ViewBuilder
    private func block<Content: View>(_ title: LocalizedStringKey, _ icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(accent)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .nodusGlass(NodusGlass(.thin, tint: accent))
    }
}

// MARK: - Quiz

/// Private reflections and factual choice results persist before reconnection.
private struct ImmersionQuizView: View {
    let title: String
    let questions: [ImmersionPlan.Question]
    let feynman: String?
    let accent: Color
    var controller: ImmersionProgressController?
    var stepIndex = 0
    var finalExam = false

    @State private var chosen: [String: Int] = [:]
    @State private var revealed: Set<String> = []
    @State private var responses: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let controller { ImmersionProgressStatus(controller: controller, questions: questions, totalSteps: controller.totalSteps, accent: accent) }
                if let feynman, !feynman.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Explain it out loud", systemImage: "quote.bubble")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(accent)
                        Text(feynman).font(.callout)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .nodusGlass(NodusGlass(.regular, tint: accent))
                }

                ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                    questionCard(question, number: index + 1)
                }

                if let controller {
                    ImmersionStepControl(controller: controller, index: stepIndex, label: finalExam ? "Finalizar recorrido" : "Marcar cuestionario como completado", finished: finalExam, accent: accent)
                }
                Text("Las respuestas abiertas son reflexiones privadas. Se guardan literalmente y no se envían a un modelo ni se evalúan automáticamente.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        }
        .nodusHidesBottomBar()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: accent)
        .task { restoreAnswers() }
        .task(id: controller?.loading) { await controller?.visit(index: stepIndex) }
        .onChange(of: controller?.progress) { _, _ in restoreAnswers() }
    }

    private func questionCard(_ question: ImmersionPlan.Question, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(number). \(question.question)").font(.callout.weight(.medium))

            if question.isChoice {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    Button {
                        Task { await controller?.answer(question, value: String(index)) }
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: mark(question, index))
                                .foregroundStyle(tint(question, index))
                            Text(option).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(9)
                        .background(tint(question, index).opacity(revealed.contains(question.id) ? 0.12 : 0.04),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(controller == nil || controller?.loading == true || controller?.saving == true)
                }
            } else {
                TextField("Escribe tu reflexión", text: Binding(get: { responses[question.id] ?? "" }, set: { responses[question.id] = $0 }), axis: .vertical)
                    .lineLimit(4...12).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("immersion-answer-\(question.id)")
                Button("Guardar reflexión") { Task { await controller?.answer(question, value: responses[question.id] ?? "") } }
                    .frame(minHeight: 44).disabled(controller == nil || controller?.loading == true || controller?.saving == true || (responses[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (responses[question.id] ?? "").utf16.count > 10_000)
                Button {
                    if revealed.contains(question.id) { revealed.remove(question.id) } else { revealed.insert(question.id) }
                } label: {
                    Label(revealed.contains(question.id) ? "Hide the answer" : "Show the answer",
                          systemImage: revealed.contains(question.id) ? "eye.slash" : "eye")
                        .font(.caption)
                }
                .buttonStyle(NodusGlassButtonStyle(accent: accent))

                if revealed.contains(question.id), !question.expected.isEmpty {
                    Text(question.expected).font(.caption).foregroundStyle(.secondary)
                }
            }

            if revealed.contains(question.id), !question.explanation.isEmpty {
                Text(question.explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .nodusGlass(NodusGlass(.thin, tint: accent))
    }

    private func restoreAnswers() {
        chosen = [:]
        revealed.subtract(Set(questions.filter(\.isChoice).map(\.id)))
        for record in controller?.progress.answers ?? [] {
            if record.kind == "choice", let index = Int(record.answer) { chosen[record.questionId] = index; revealed.insert(record.questionId) }
            else if responses[record.questionId] == nil { responses[record.questionId] = record.answer }
        }
    }

    private func mark(_ question: ImmersionPlan.Question, _ index: Int) -> String {
        guard revealed.contains(question.id) else { return "circle" }
        if index == question.correctIndex { return "checkmark.circle.fill" }
        return chosen[question.id] == index ? "xmark.circle.fill" : "circle"
    }

    private func tint(_ question: ImmersionPlan.Question, _ index: Int) -> Color {
        guard revealed.contains(question.id) else { return .secondary }
        if index == question.correctIndex { return .green }
        return chosen[question.id] == index ? .red : .secondary
    }
}

private struct ImmersionStepControl: View {
    let controller: ImmersionProgressController
    let index: Int
    var label: LocalizedStringKey = "Marcar lectura como completada"
    var finished = false
    let accent: Color
    private var completed: Bool { controller.progress.completedSteps.contains(index) }
    var body: some View {
        Button {
            Task { await controller.visit(index: index, completed: true, finished: finished) }
        } label: {
            Label(completed ? "Lectura completada" : label, systemImage: completed ? "checkmark.circle.fill" : "checkmark.circle")
                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
        }
        .buttonStyle(NodusGlassButtonStyle(accent: accent))
        .disabled(controller.loading || controller.saving || completed)
        .accessibilityIdentifier("immersion-complete-step-\(index)")
    }
}

private struct ImmersionProgressStatus: View {
    let controller: ImmersionProgressController
    let questions: [ImmersionPlan.Question]
    let totalSteps: Int
    let accent: Color
    @State private var restarting = false
    private var status: LocalizedStringKey {
        if controller.loading { return "Cargando progreso privado…" }
        if controller.state == .conflict { return "El progreso cambió en el Mac" }
        if controller.state == .blocked { return "Progreso conservado · sincronización bloqueada" }
        if controller.state == .pending { return controller.canSync ? "Guardado en este dispositivo · pendiente de sincronizar" : "Guardado en este dispositivo" }
        return controller.canSync && !controller.offline ? "Progreso guardado" : "Guardado en este dispositivo"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(status, systemImage: controller.state == .conflict ? "exclamationmark.arrow.triangle.2.circlepath" : "checkmark.circle")
                .font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            ProgressView(value: Double(controller.progress.completedSteps.count), total: Double(totalSteps)).tint(accent)
            Text("\(controller.progress.completedSteps.count) de \(totalSteps) pasos completados · \(controller.progress.answers.count) respuestas guardadas")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let issue = controller.issue { Text(issue).font(.caption).foregroundStyle(Color.nodusDanger).fixedSize(horizontal: false, vertical: true) }
            if let remote = controller.remote, controller.state == .conflict {
                DisclosureGroup("Comparar respuestas") {
                    Text("Este dispositivo").font(.headline)
                    Text("Pasos completados: \(controller.progress.completedSteps.map { String($0 + 1) }.joined(separator: ", "))").font(.caption)
                    answerList(controller.progress.answers)
                    Text("Mac · \(remote.progress.completedSteps.count) pasos completados").font(.headline)
                    Text("Pasos completados: \(remote.progress.completedSteps.map { String($0 + 1) }.joined(separator: ", "))").font(.caption)
                    answerList(remote.progress.answers)
                }
                Button("Conservar mi progreso del móvil") { Task { await controller.resolve(keepPhone: true) } }.frame(minHeight: 44)
                Button("Usar el progreso del Mac") { Task { await controller.resolve(keepPhone: false) } }.frame(minHeight: 44)
                Text("La elección se guarda antes de sincronizar. Un nuevo cambio simultáneo vuelve a requerir revisión.").font(.caption).foregroundStyle(.secondary)
            } else {
                if controller.state == .blocked { Button("Reintentar sincronización") { Task { await controller.retry() } }.frame(minHeight: 44) }
                Button("Volver a empezar") { restarting = true }.frame(minHeight: 44).disabled(controller.loading || controller.saving)
            }
        }
        .disabled(controller.saving)
        .padding(14).nodusGlass(NodusGlass(.thin, tint: accent))
        .confirmationDialog("Se reiniciarán los pasos y respuestas de este recorrido", isPresented: $restarting, titleVisibility: .visible) {
            Button("Reiniciar recorrido", role: .destructive) { Task { await controller.restart() } }
        }
        .accessibilityIdentifier("immersion-private-progress")
    }
    @ViewBuilder private func answerList(_ answers: [CompanionImmersionProgress.Answer]) -> some View {
        if answers.isEmpty { Text("Sin respuestas guardadas").foregroundStyle(.secondary) }
        ForEach(answers, id: \.questionId) { answer in
            let question = questions.first { $0.id == answer.questionId }
            VStack(alignment: .leading, spacing: 6) {
                Text(question?.question ?? answer.questionId).font(.caption.weight(.semibold))
                if answer.kind == "choice", let index = Int(answer.answer), let question, question.options.indices.contains(index) {
                    Text(question.options[index]).font(.caption)
                } else { Text(answer.answer).font(.caption) }
            }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
        }
    }
}
