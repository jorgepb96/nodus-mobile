import NodusKit
import NodusUI
import SwiftUI

struct HypothesisLabMobileView: View {
    let session: SpaceSession

    @State private var tables: [String: [Row]] = [:]
    @State private var objective = ""
    @State private var mode: AcademicHypothesisMode = .exploratory
    @State private var candidates: [AcademicHypothesisCandidate] = []
    @State private var selectedId: String?
    @State private var loading = true
    @State private var actionStatus: String?
    @State private var error: String?

    private var selected: AcademicHypothesisCandidate? {
        candidates.first { $0.id == selectedId } ?? candidates.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                DesktopPageHeader(
                    title: "Hypothesis Lab",
                    subtitle: "Grounded candidates generated from published gaps, ideas and debates",
                    systemImage: "flask",
                    accent: session.accent
                )
                VStack(alignment: .leading, spacing: 10) {
                    Text("Research objective").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextEditor(text: $objective)
                        .frame(minHeight: 72)
                        .padding(8)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.separator.opacity(0.5)))
                    HStack {
                        Menu {
                            Picker("Mode", selection: $mode) {
                                ForEach(AcademicHypothesisMode.allCases) { value in Text(value.title).tag(value) }
                            }
                        } label: { Label(mode.title, systemImage: "slider.horizontal.3") }
                            .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
                        Spacer()
                        Button { generate() } label: { Label("Generate candidates", systemImage: "sparkles") }
                            .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent))
                            .disabled(loading || tables.isEmpty)
                    }
                }
                .desktopContentRow(accent: session.accent)

                if let error { NodusNotice(tone: .blocked, title: "Hypothesis Lab unavailable", message: LocalizedStringKey(error)) }
                if let actionStatus { NodusNotice(tone: .info, title: "Desktop action", message: LocalizedStringKey(actionStatus)) }

                if candidates.isEmpty, !loading {
                    ContentUnavailableView(
                        "No grounded candidate yet", systemImage: "flask",
                        description: Text("Publish at least one research gap or change the objective, then generate candidates.")
                    ).padding(.vertical, 36)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                        ForEach(candidates) { candidate in
                            Button { selectedId = candidate.id } label: {
                                HypothesisCandidateCard(candidate: candidate, selected: selected?.id == candidate.id, accent: session.accent)
                            }.buttonStyle(NodusCardButtonStyle())
                        }
                    }
                    if let selected { hypothesisDossier(selected) }
                }
            }
            .padding(NodusSpace.page)
            .frame(maxWidth: 1120).frame(maxWidth: .infinity)
            .nodusTopAnchor()
        }
        .nodusPageBackdrop(accent: session.accent)
        .accessibilityIdentifier("academic-hypothesis")
        .task(id: session.publishedRevision) { await load() }
    }

    @ViewBuilder private func hypothesisDossier(_ candidate: AcademicHypothesisCandidate) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(candidate.title).font(.title3.weight(.semibold))
                    HStack { NodusChip(key: candidate.maturity, tint: session.accent); NodusChip(key: "\(candidate.score)/100", tint: .green) }
                }
                Spacer()
                Button { Task { await saveToNotes(candidate) } } label: { Label("Save to Notes", systemImage: "note.text.badge.plus") }
                    .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
                    .disabled(session.isDemo || !session.canAuthor)
            }
            Text(candidate.hypothesis).font(.headline)
            Text(candidate.rationale).font(.subheadline).foregroundStyle(.secondary)
            dossierList("Variables", candidate.variables, icon: "function")
            dossierList("Predictions", candidate.predictions, icon: "arrow.triangle.branch")
            dossierList("Counterarguments", candidate.counterArguments, icon: "scale.3d")
            dossierList("Methods", candidate.methods, icon: "wrench.and.screwdriver")
            dossierList("Next steps", candidate.nextSteps, icon: "checklist")
            VStack(alignment: .leading, spacing: 7) {
                Label("Grounded evidence", systemImage: "link").font(.subheadline.weight(.semibold))
                ForEach(candidate.evidence) { evidence in
                    HStack(alignment: .top, spacing: 9) {
                        NodusChip(key: evidence.kind, tint: evidence.role == "contrast" ? .red : session.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(evidence.label).font(.caption).lineLimit(3)
                            Text("\(evidence.role) · \(evidence.refId)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .desktopContentRow(accent: session.accent)
    }

    @ViewBuilder private func dossierList(_ title: String, _ values: [String], icon: String) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Text("• \(value)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func load() async {
        loading = true
        do {
            tables = try await session.client.snapshot(in: session.connection.spaceId).tables
            if objective.isEmpty { objective = session.overview?.vault?.name ?? "the published corpus" }
            generate(); error = nil
        } catch { self.error = error.localizedDescription }
        loading = false
    }

    private func generate() {
        candidates = AcademicHypothesisProjection.generate(from: tables, objective: objective, mode: mode)
        selectedId = candidates.first?.id
    }

    private func saveToNotes(_ candidate: AcademicHypothesisCandidate) async {
        let markdown = """
        # \(candidate.title)

        ## Hypothesis
        \(candidate.hypothesis)

        ## Rationale
        \(candidate.rationale)

        ## Variables
        \(candidate.variables.map { "- \($0)" }.joined(separator: "\n"))

        ## Predictions
        \(candidate.predictions.map { "- \($0)" }.joined(separator: "\n"))

        ## Counterarguments
        \(candidate.counterArguments.map { "- \($0)" }.joined(separator: "\n"))

        ## Evidence
        \(candidate.evidence.map { "- [\($0.kind)] \($0.label) (`\($0.refId)`)" }.joined(separator: "\n"))
        """
        do {
            let key = "hypothesis-note:\(candidate.id):\(session.publishedRevision ?? "local")"
            let result = try await session.client.createSpaceAction(
                idempotencyKey: key, kind: .hypothesisSaveToNotes,
                payload: ["title": .string(candidate.title), "markdown": .string(markdown), "hypothesisId": .string(candidate.id)],
                inputRevision: session.publishedRevision, executionMode:session.aiExecutionMode.rawValue, in:session.connection.spaceId
            )
            actionStatus = result.action.receiptMessage
        } catch { self.error = error.localizedDescription }
    }
}

private struct HypothesisCandidateCard: View {
    let candidate: AcademicHypothesisCandidate
    let selected: Bool
    let accent: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { NodusChip(key: candidate.maturity, tint: accent); Spacer(); Text("\(candidate.score)").font(.caption.monospacedDigit()) }
            Text(candidate.title).font(.headline).lineLimit(2)
            Text(candidate.hypothesis).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            Label("\(candidate.evidence.count) grounded references", systemImage: "link").font(.caption2).foregroundStyle(.secondary)
        }
        .desktopContentRow(accent: selected ? accent : .secondary)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? accent.opacity(0.65) : .clear, lineWidth: 1.5))
    }
}

struct ReadingPathMobileView: View {
    let session: SpaceSession

    @State private var tables: [String: [Row]] = [:]
    @State private var strategy: AcademicReadingStrategy = .researchRelevance
    @State private var brief = ""
    @State private var includeRead = true
    @State private var limit = 72
    @State private var plan: AcademicReadingPlan?
    @State private var loading = true
    @State private var error: String?

    private var projectionID: String { "\(strategy.rawValue)|\(brief)|\(includeRead)|\(limit)|\(tables.count)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                DesktopPageHeader(
                    title: "Reading path",
                    subtitle: "A ranked, phased route through the same published academic graph as Desktop",
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                    accent: session.accent
                )
                controls
                if let error { NodusNotice(tone: .blocked, title: "Could not build the reading path", message: LocalizedStringKey(error)) }
                if loading && tables.isEmpty { HStack { Spacer(); ProgressView().tint(session.accent); Spacer() }.padding(40) }
                else if let plan, plan.shownWorks > 0 { planView(plan) }
                else { ContentUnavailableView("No readings available", systemImage: "books.vertical", description: Text("Publish works or include already-read material.")) }
            }
            .padding(NodusSpace.page)
            .frame(maxWidth: 1080).frame(maxWidth: .infinity)
            .nodusTopAnchor()
        }
        .nodusPageBackdrop(accent: session.accent)
        .accessibilityIdentifier("academic-reading-path")
        .task(id: session.publishedRevision) { await load() }
        .task(id: projectionID) { rebuild() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Menu {
                    Picker("Strategy", selection: $strategy) {
                        ForEach(AcademicReadingStrategy.allCases) { value in Text(value.title).tag(value) }
                    }
                } label: { Label(strategy.title, systemImage: "slider.horizontal.3") }
                    .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
                Toggle("Include read", isOn: $includeRead).font(.caption).toggleStyle(.switch)
                Spacer()
                Stepper("\(limit)", value: $limit, in: 18...180, step: 18).font(.caption.monospacedDigit())
            }
            TextField("Research brief or concepts to prioritise", text: $brief, axis: .vertical)
                .textFieldStyle(.plain).padding(10)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.separator.opacity(0.5)))
        }
        .desktopContentRow(accent: session.accent)
    }

    @ViewBuilder private func planView(_ plan: AcademicReadingPlan) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], spacing: 8) {
            metric("Corpus", plan.totalWorks, "books.vertical")
            metric("In path", plan.shownWorks, "list.number")
            metric("Read", plan.readCount, "checkmark.circle")
            metric("Analysed", plan.analyzedCount, "sparkles")
        }
        ForEach(Array(plan.phases.enumerated()), id: \.element.id) { index, phase in
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text("\(index + 1)").font(.headline.monospacedDigit()).foregroundStyle(session.accent.nodusReadable)
                        .frame(width: 28, height: 28).background(session.accent.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phase.title).font(.headline)
                        Text(phase.objective).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(); CountBadge(count: phase.entries.count, accent: session.accent.nodusReadable)
                }
                ForEach(phase.entries) { entry in readingRow(entry) }
            }
            .desktopContentRow(accent: session.accent)
        }
    }

    private func readingRow(_ entry: AcademicReadingEntry) -> some View {
        Group {
            if let row = (tables["works"] ?? []).first(where: { $0.string("nodus_id") == entry.id }), let collection = Collections["works"] {
                NavigationLink { RowDetailView(session: session, collection: collection, row: row) } label: { readingLabel(entry) }
                    .buttonStyle(.plain)
            } else { readingLabel(entry) }
        }
    }

    private func readingLabel(_ entry: AcademicReadingEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(entry.priority)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(session.accent.nodusReadable)
                .frame(width: 34, height: 30).background(session.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(([entry.authors.prefix(2).joined(separator: ", "), entry.year.map(String.init)].compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text(entry.reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer()
            if entry.read { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Read") }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
    }

    private func metric(_ label: String, _ value: Int, _ icon: String) -> some View {
        HStack { Image(systemName: icon).foregroundStyle(session.accent.nodusReadable); VStack(alignment: .leading) { Text("\(value)").font(.headline.monospacedDigit()); Text(label).font(.caption2).foregroundStyle(.secondary) }; Spacer() }
            .desktopContentRow(accent: session.accent)
    }

    private func load() async {
        loading = true
        do { tables = try await session.client.snapshot(in: session.connection.spaceId).tables; error = nil; rebuild() }
        catch { self.error = error.localizedDescription }
        loading = false
    }

    private func rebuild() {
        guard !tables.isEmpty else { return }
        plan = AcademicReadingProjection.build(from: tables, strategy: strategy, researchBrief: brief, includeRead: includeRead, limit: limit)
    }
}

private extension AcademicHypothesisMode {
    var title: String {
        switch self { case .exploratory: String(localized: "Exploratory"); case .causal: String(localized: "Causal"); case .comparative: String(localized: "Comparative"); case .methodological: String(localized: "Methodological"); case .intervention: String(localized: "Intervention") }
    }
}

private extension AcademicReadingStrategy {
    var title: String {
        switch self {
        case .researchRelevance: String(localized: "Research relevance")
        case .gaps: String(localized: "Research gaps")
        case .foundational: String(localized: "Foundational")
        case .recent: String(localized: "Recent")
        case .connectedAuthors: String(localized: "Connected authors")
        case .bridges: String(localized: "Conceptual bridges")
        }
    }
}
