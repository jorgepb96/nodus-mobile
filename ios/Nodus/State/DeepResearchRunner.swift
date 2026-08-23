import NodusAI
import NodusKit
import Observation
import SwiftUI
import UIKit

/// The executor a space contributes to the app-wide sequential Deep Research queue.
///
/// It used to live in `@State` on the screen that started it. That made the run a property of a
/// view: pop the navigation stack and the progress was gone. Jobs now belong to
/// ``DeepResearchQueue``; this object supplies the live session dependencies for one space.
///
/// Leaving the app is handled in two layers, because iOS gives no single one:
///
/// - a background-task assertion buys the minutes it takes to finish a section or two after the
///   app leaves the screen;
/// - and when that runs out, the checkpoint written after every section is what
///   `BackgroundJobs.resumeDeepResearch` picks up later. Between them, walking away costs the
///   user nothing they had already paid for.
@Observable
@MainActor
final class DeepResearchRunner {
    /// One per space, kept for the life of the process.
    private static var runners: [String: DeepResearchRunner] = [:]

    static func shared(for spaceId: String) -> DeepResearchRunner {
        if let existing = runners[spaceId] { return existing }
        let runner = DeepResearchRunner(spaceId: spaceId)
        runners[spaceId] = runner
        return runner
    }

    let spaceId: String

    private var queue: DeepResearchQueue { .shared }

    private var currentJob: DeepResearchQueueJob? {
        queue.jobs(in: spaceId).first { !$0.status.isFinished }
    }

    var request: DeepResearchRequest? { currentJob?.request }
    var progress: DeepResearchProgress? { currentJob?.progress }
    /// The report is written and saved; what is left is drawing its illustration.
    private(set) var isIllustrating = false
    /// The last report this runner finished, so the screen that started it can show it.
    private(set) var finished: LocalReportStore.Saved?
    /// Why the last run stopped, when it was not because it finished.
    private(set) var failure: String?
    /// The illustration failed but the report did not. Said out loud rather than swallowed —
    /// the picture costs money too.
    private(set) var illustrationFailure: String?

    private var activity: LiveActivityController?
    private var assertion: UIBackgroundTaskIdentifier = .invalid

    var isRunning: Bool { currentJob != nil }

    private init(spaceId: String) {
        self.spaceId = spaceId
    }

    // MARK: - Starting

    /// Begin a run, or carry on one that stopped.
    ///
    /// Everything the run needs is taken now — the client, the key reader, the model — rather
    /// than held as a reference to the session, because the session belongs to a screen and this
    /// outlives every screen there is.
    func start(
        _ request: DeepResearchRequest,
        resuming checkpoint: DeepResearchCheckpoint? = nil,
        session: SpaceSession,
        ai: AISettings
    ) {
        finished = nil
        failure = nil
        illustrationFailure = nil
        isIllustrating = false

        let jobId = UUID().uuidString
        queue.enqueue(
            id: jobId,
            spaceId: spaceId,
            spaceName: session.connection.spaceName,
            request: request
        ) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.execute(
                jobId: jobId,
                request: request,
                resuming: checkpoint,
                session: session,
                ai: ai
            )
        }
    }

    /// Reattach every persisted queued request for this space after a relaunch.
    ///
    /// Only the matching request consumes the checkpoint. A second request that had never
    /// started must not inherit the first report's already-written sections.
    func attachPending(session: SpaceSession, ai: AISettings) {
        let checkpoint = DeepResearchCheckpointStore.load(spaceId: spaceId)
        for job in queue.jobs(in: spaceId) where job.status == .queued {
            let resume = checkpoint.flatMap { $0.request == job.request ? $0 : nil }
            queue.attach(jobId: job.id) { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.execute(
                    jobId: job.id,
                    request: job.request,
                    resuming: resume,
                    session: session,
                    ai: ai
                )
            }
        }
    }

    private func execute(
        jobId: String,
        request: DeepResearchRequest,
        resuming checkpoint: DeepResearchCheckpoint?,
        session: SpaceSession,
        ai: AISettings
    ) async throws -> DeepResearchQueueResult {
        failure = nil
        illustrationFailure = nil

        let spaceId = self.spaceId
        let store = LocalReportStore.shared(for: spaceId)
        let keyProvider = ai.keyProvider
        let imageModel = ai.model(for: .image)
        let client = session.client
        let identity = semanticIdentity(session)

        let orchestrator = DeepResearchOrchestrator(
            deps: DeepResearchWiring.deps(
                retrieval: CorpusRetrieval(
                    client: client,
                    spaceId: spaceId,
                    embeddings: EmbeddingService(keyProvider: keyProvider),
                    identity: identity
                ),
                provider: ProviderClient(keyProvider: keyProvider),
                citations: CorpusCitations(client: client, spaceId: spaceId)
            )
        )

        // The island is where a run this long belongs: it outlives the screen that started it,
        // and the phone should be able to say what it is doing without being unlocked.
        let activity = LiveActivityController(
            kind: .deepResearch,
            title: request.objective,
            accentHex: session.vaultType?.accentHex ?? VaultType.academic.accentHex,
            spaceName: session.connection.spaceName
        )
        activity.start()
        self.activity = activity
        beginAssertion()

        defer {
            self.activity = nil
            self.isIllustrating = false
            self.endAssertion()
        }

        do {
            let report = try await orchestrator.run(
                    request,
                    resuming: checkpoint,
                    // Written after every section, on whichever thread finished it. This is the
                    // persisted state Info.plist has always claimed a run resumes from, and the
                    // difference between an interrupted run and a wasted one.
                    onCheckpoint: { reached in
                        DeepResearchCheckpointStore.save(reached, spaceId: spaceId)
                    },
                    onProgress: { update in
                        Task { @MainActor in
                            DeepResearchQueue.shared.update(jobId: jobId, progress: update)
                            activity.update(
                                phase: update.phase.rawValue,
                                detail: update.sectionTitle ?? update.message,
                                fraction: update.fraction,
                                step: update.sectionIndex.map { $0 + 1 },
                                stepCount: update.sectionTotal
                            )
                        }
                    }
            )
                // Saved before anything else can go wrong. A run is one model call per section
                // and losing it to a dismissed screen means paying for it twice.
                //
                // The whole `ModelRef`, not just its name: sending the report to the vault needs
                // the provider too, and a record that kept only the label could never be turned
                // back into a sendable row.
            let saved = store.save(report, mode: request.mode, model: request.model, id: jobId)
            DeepResearchCheckpointStore.clear(spaceId: spaceId)
            self.finished = saved

            let publicationNote = await self.publishIfAllowed(
                saved,
                request: request,
                session: session,
                store: store
            )

            if let style = request.illustration {
                await self.illustrate(
                    saved,
                    style: style,
                    with: imageModel,
                    describedBy: request.model,
                    keyProvider: keyProvider,
                    into: store
                )
            }
            activity.finish()
            return DeepResearchQueueResult(savedReportId: saved.id, publicationNote: publicationNote)
        } catch is CancellationError {
                // Deliberately kept: cancelling stops the spending, it does not throw away the
                // sections already written. The screen offers to carry on from here.
                self.stopped(with: String(localized: "Cancelled."), activity: activity, note: "Cancelled")
            throw CancellationError()
        } catch DeepResearchError.cancelled {
            self.stopped(with: String(localized: "Cancelled."), activity: activity, note: "Cancelled")
            throw CancellationError()
        } catch DeepResearchError.emptyCorpus {
            DeepResearchCheckpointStore.clear(spaceId: spaceId)
            let message = String(localized: "Nothing citable was found for that objective in this space.")
            self.stopped(with: message, activity: activity, note: "No citable material")
            throw DeepResearchRunFailure(message: message)
        } catch {
            self.stopped(with: error.localizedDescription, activity: activity, note: error.localizedDescription)
            throw error
        }
    }

    private func stopped(with message: String, activity: LiveActivityController, note: String) {
        failure = message
        activity.finish(failure: note)
    }

    // MARK: - Cancelling

    /// Stop paying for sections. Everything already written stays on disk as a checkpoint, and
    /// the screen offers to carry on from there.
    func cancel() {
        guard let id = currentJob?.id else { return }
        queue.cancel(id)
    }

    private func publishIfAllowed(
        _ saved: LocalReportStore.Saved,
        request: DeepResearchRequest,
        session: SpaceSession,
        store: LocalReportStore
    ) async -> String {
        guard session.connection.role.canSendChanges else {
            return String(localized: "Kept locally: this access is read only.")
        }
        guard let controller = await OutboxController.open(session: session) else {
            return String(localized: "Kept locally: the vault outbox is unavailable.")
        }
        guard let sent = await controller.sendReport(
            saved.report,
            mode: saved.mode,
            model: request.model,
            language: request.language,
            rowId: saved.vaultRowId ?? saved.id
        ) else {
            return controller.lastError ?? String(localized: "Kept locally and waiting for publication.")
        }
        store.markSent(saved.id, outboxId: sent.outboxId, vaultRowId: sent.rowId)
        return String(localized: "Saved locally and queued for the vault.")
    }

    /// Forget the report this runner is holding, so the screen it started on goes back to its
    /// form. The report itself is on disk and in the library; this only clears the hand-off.
    func clearFinished() {
        finished = nil
        failure = nil
        illustrationFailure = nil
    }

    // MARK: - The illustration

    /// Draw the report a cover, the way the desktop does: a text model describes one scene from
    /// what was written, and an image model draws that scene in the chosen style.
    ///
    /// A failure here is reported and then let go. The report is the thing that cost a model call
    /// per section; refusing to keep it because its decoration failed would be absurd.
    private func illustrate(
        _ saved: LocalReportStore.Saved,
        style: DecorativeImageStyle,
        with imageModel: ModelRef?,
        describedBy textModel: ModelRef,
        keyProvider: @escaping @Sendable (AIProvider) -> String?,
        into store: LocalReportStore
    ) async {
        guard let imageModel else {
            illustrationFailure = String(localized: "No image model is chosen, so the report has no illustration.")
            return
        }
        isIllustrating = true
        defer { isIllustrating = false }

        do {
            let scene = try await ProviderClient(keyProvider: keyProvider).complete(ChatRequest(
                model: textModel,
                messages: [
                    .init(role: .system, content: Prompts.visualContextSystem),
                    .init(role: .user, content: Prompts.visualContext(for: saved.report)),
                ],
                temperature: 0.2,
                maxTokens: 200
            ))
            let image = try await ImageService(keyProvider: keyProvider).generate(
                prompt: style.imagePrompt(scene: scene),
                with: imageModel
            )
            if let illustrated = store.attach(image, to: saved.id) { finished = illustrated }
        } catch {
            illustrationFailure = error.localizedDescription
        }
    }

    // MARK: - Leaving the app

    /// Ask iOS for the time to carry on after the app stops being on screen.
    ///
    /// When the assertion expires it must be ended — an app that ignores the warning is killed —
    /// but the run is deliberately *not* cancelled: it will be frozen with the app, and its
    /// checkpoint is what the background task resumes from later.
    private func beginAssertion() {
        guard assertion == .invalid else { return }
        assertion = UIApplication.shared.beginBackgroundTask(withName: "deep-research") { [weak self] in
            self?.endAssertion()
        }
    }

    private func endAssertion() {
        guard assertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(assertion)
        assertion = .invalid
    }

    private func semanticIdentity(_ session: SpaceSession) -> EmbeddingIdentity? {
        guard case .published(let identity) = session.embedding, session.embedding.isReachableFromPhone else { return nil }
        return identity
    }
}

private struct DeepResearchRunFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
