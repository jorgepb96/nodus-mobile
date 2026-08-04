import NodusKit
import NodusUI
import SwiftUI

/// An immersion session, read as the study route it is.
///
/// The published plan is a whole itinerary — an overview, stations with prose and quizzes,
/// a contrast table of who argues what, the open frontiers of the corpus, and a final exam.
/// Until now the app opened it through the generic row viewer, which showed the plan as one
/// enormous JSON column: technically the data, and unreadable.
///
/// `progress_json` is deliberately never published (`server/lib/routes/corpus.mjs`), so this
/// screen reads a route rather than resuming one. Answers tapped here stay on the phone.
struct ImmersionView: View {
    let session: SpaceSession
    let sessionId: String
    let title: String

    @State private var plan: ImmersionPlan?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error {
                    NodusNotice(tone: .blocked, title: "Could not open the session", message: LocalizedStringKey(error))
                } else if let plan {
                    // The numbers are the reading order the find bar walks: an itinerary is
                    // read from its overview down to its frontiers, whatever the layout does.
                    header(plan).nodusSearchOrder(1)
                    if !plan.overview.isEmpty {
                        card(title: "Overview", icon: "text.alignleft") {
                            CorpusProse(plan.overview, accent: session.accent, session: session)
                        }
                        .nodusSearchOrder(2)
                    }
                    stations(plan).nodusSearchOrder(3)
                    if !plan.keyTerms.isEmpty { keyTerms(plan).nodusSearchOrder(4) }
                    if !plan.contrasts.isEmpty { contrasts(plan).nodusSearchOrder(5) }
                    if !plan.frontiers.isEmpty { frontiers(plan).nodusSearchOrder(6) }
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
        .task { await load() }
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
                    ImmersionStationView(session: session, station: station, number: index + 1)
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
                accent: session.accent
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
        guard plan == nil else { return }
        do {
            let detail = try await session.client.immersionSession(sessionId, in: session.connection.spaceId)
            plan = ImmersionPlan(detail)
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
                                    PageText(citation.reference, order: 0)
                                        .font(.caption2.weight(.medium)).foregroundStyle(accent)
                                    if !citation.text.isEmpty {
                                        PageText("“\(citation.text)”", order: 1)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
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
                        ImmersionQuizView(title: String(localized: "Check yourself"), questions: station.quiz, feynman: nil, accent: accent)
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
            }
            .padding(16)
            .nodusTopAnchor()
        }
        .nodusPageFunctions(accent: accent)
        .nodusHidesBottomBar()
        .navigationTitle(station.title)
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: accent)
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

/// Questions, answered on the phone and nowhere else.
///
/// Nothing here is sent anywhere: `progress_json` is not published, so a session cannot be
/// resumed from a phone and pretending otherwise would be the dishonest part.
private struct ImmersionQuizView: View {
    let title: String
    let questions: [ImmersionPlan.Question]
    let feynman: String?
    let accent: Color

    @State private var chosen: [String: Int] = [:]
    @State private var revealed: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
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

                Text("Answers stay on this device. An immersion session's progress is never published, so nothing here travels back to the vault.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        }
        .nodusHidesBottomBar()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: accent)
    }

    private func questionCard(_ question: ImmersionPlan.Question, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(number). \(question.question)").font(.callout.weight(.medium))

            if question.isChoice {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    Button {
                        chosen[question.id] = index
                        revealed.insert(question.id)
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
                }
            } else {
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
