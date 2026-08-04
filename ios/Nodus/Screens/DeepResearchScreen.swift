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
    @State private var wantsIllustration = false
    @State private var imageStyle: DecorativeImageStyle = .fallback
    /// A run that stopped before its last section. Kept so the sections already paid for are
    /// not thrown away by a screen that was dismissed or a phone that ran out of patience.
    @State private var unfinished: DeepResearchCheckpoint?
    @Environment(AppPreferences.self) private var preferences

    /// The run itself, which belongs to the space rather than to this screen: leaving here does
    /// not stop it, and coming back finds it exactly where it got to.
    private var runner: DeepResearchRunner { DeepResearchRunner.shared(for: session.connection.spaceId) }

    private var report: DeepResearchReport? { runner.finished?.report }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                if let saved = runner.finished {
                    reportView(saved)
                } else if let progress = runner.progress {
                    DeepResearchProgressCard(
                        objective: runner.request?.objective ?? objective,
                        progress: progress,
                        isIllustrating: runner.isIllustrating,
                        accent: session.accent,
                        onCancel: { runner.cancel() }
                    )
                } else {
                    if let unfinished { resumeNotice(unfinished) }
                    form
                }

                if let failure = runner.failure {
                    NodusNotice(tone: .blocked, title: "The report failed", message: LocalizedStringKey(failure))
                }
                if let note = runner.illustrationFailure {
                    NodusNotice(
                        tone: .caution,
                        title: "The report has no illustration",
                        message: LocalizedStringKey(note),
                        systemImage: "photo"
                    )
                }
            }
            .padding(NodusSpace.page)
            .frame(maxWidth: ReportLayout.measure)
            .frame(maxWidth: .infinity)
            .nodusTopAnchor()
        }
        // A finished report is a document and is set as one; the form that starts it is not.
        .nodusReadingStyle(ReadingStyle(scale: preferences.readingScale, document: report != nil))
        .nodusScrollToTop(accent: session.accent)
        .nodusDismissesKeyboard()
        .navigationTitle("Deep Research")
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .task {
            guard !runner.isRunning, runner.finished == nil else { return }
            readCheckpoint()
        }
        // A run that has just stopped is the moment the offer to carry on matters most, and the
        // run no longer belongs to this screen — so the checkpoint is re-read when it ends
        // rather than only when the screen is opened.
        .onChange(of: runner.isRunning) { _, running in
            if !running, runner.finished == nil { readCheckpoint() }
        }
        .toolbar {
            if runner.finished != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New") { runner.clearFinished() }
                }
            }
        }
    }

    // MARK: Resuming

    /// The sections a stopped run already paid for, if there are any.
    private func readCheckpoint() {
        let saved = DeepResearchCheckpointStore.load(spaceId: session.connection.spaceId)
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
                    DeepResearchCheckpointStore.clear(spaceId: session.connection.spaceId)
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

            Text((mode ?? defaultMode).explanation)
                .font(.caption).foregroundStyle(.secondary)

            Picker("Length", selection: $length) {
                ForEach(DeepResearchLength.allCases, id: \.self) { option in
                    Text(LocalizedStringKey(option.label)).tag(option)
                }
            }
            .pickerStyle(.menu)
            .tint(session.accent)

            // The desktop's own second control beside the length (`DeepResearchView.tsx:59-66`).
            // Length says how many pages; this says how they are divided, and the two are not
            // the same question — eight pages in four sections is a different document from
            // eight pages in ten.
            Picker("Sections", selection: $sections) {
                ForEach(DeepResearchSectionChoice.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.menu)
            .tint(session.accent)

            illustrationControls

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
            .disabled(objective.trimmingCharacters(in: .whitespaces).count < 8 || ai.model(for: .deepResearch) == nil)
        }
        .padding(16)
        .nodusGlass(NodusGlass(.regular, tint: session.accent))
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

    // MARK: Report

    private func reportView(_ saved: LocalReportStore.Saved) -> some View {
        let report = saved.report
        return VStack(alignment: .leading, spacing: 16) {
            if let url = local.imageURL(for: saved) {
                LocalReportImage(url: url)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(report.objective).font(.title3.weight(.semibold))
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
        sections = DeepResearchSectionChoice(limit: checkpoint.request.sectionLimit)
        unfinished = nil
        runner.start(checkpoint.request, resuming: checkpoint, session: session, ai: ai)
    }

    private func start() {
        guard let model = ai.model(for: .deepResearch) else { return }
        unfinished = nil
        // No `sentReportId` to clear: whether a report has been sent is now a fact on the saved
        // record rather than a piece of this screen's memory, which is what lets the library
        // and a reopened report agree with the button.
        runner.start(
            DeepResearchRequest(
                objective: objective.trimmingCharacters(in: .whitespacesAndNewlines),
                language: Prompts.interfaceLanguage,
                targetLength: length,
                sectionLimit: sections.limit,
                mode: mode ?? defaultMode,
                model: model,
                illustration: wantsIllustration && ai.model(for: .image) != nil ? imageStyle : nil
            ),
            session: session,
            ai: ai
        )
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
