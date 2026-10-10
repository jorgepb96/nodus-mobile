import BackgroundTasks
import Foundation
import NodusAI
import NodusKit
import os

/// The three tasks Info.plist permits, and the only code allowed to claim them.
///
/// `BGTaskSchedulerPermittedIdentifiers` has listed these since the app was scaffolded, which
/// is a promise the binary has to keep: an identifier declared and never registered is a
/// capability the app advertises and does not have. Each one exists because something the user
/// starts genuinely outlives the screen they started it on.
///
/// Registration has to finish before the app finishes launching, so it happens in
/// `NodusApp.init()` — not in a `.task` on a view, which runs far too late and makes
/// `BGTaskScheduler` trap.
/// `nonisolated`: `BGTaskScheduler` calls a launch handler on a queue of its own choosing, so
/// nothing here may assume the main actor. The work it dispatches to does.
nonisolated enum BackgroundWork {
    /// A run that was killed halfway carries on from its persisted checkpoint.
    static let deepResearchIdentifier = "com.drakonis96.nodus.ios.deepresearch"
    /// An offline copy the owner has republished under gets refreshed before the user opens it.
    static let mirrorRefreshIdentifier = "com.drakonis96.nodus.ios.mirror-refresh"
    /// Changes the user already pressed send on, but whose network gave out, finish travelling.
    static let mutationFlushIdentifier = "com.drakonis96.nodus.ios.mutation-flush"

    static let identifiers = [deepResearchIdentifier, mirrorRefreshIdentifier, mutationFlushIdentifier]

    /// What the bundle actually permits. `identifiers` and this must be the same set, or a
    /// `submit` fails at runtime on a device and nowhere else — which is why a test compares them.
    static var permittedIdentifiers: [String] {
        Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
    }

    private static let log = Logger(subsystem: "com.drakonis96.nodus.ios", category: "background")

    // MARK: - Registration

    static func registerHandlers() {
        register(mutationFlushIdentifier) { await BackgroundJobs.flushAuthorisedMutations() }
        // Two jobs under one identifier, because Info.plist permits three and asking for a
        // fourth would be advertising a capability this bundle does not have. They belong
        // together anyway: both are "while nobody was looking, what changed at the other end?",
        // both need only the network, and both are hourly work rather than urgent work.
        register(mirrorRefreshIdentifier) {
            let delivered = await BackgroundJobs.confirmDeliveries()
            let mirrors = await BackgroundJobs.refreshStaleMirrors()
            return delivered && mirrors
        }
        register(deepResearchIdentifier) { await BackgroundJobs.resumeDeepResearch() }
    }

    /// `BGTask` is a class Apple never marked `Sendable`, handed to the launch handler on a
    /// queue nobody here chooses. The only thing this app does with it is report completion
    /// once, which `BGTaskScheduler` documents as safe from any thread — so the unchecked
    /// conformance covers exactly one call and no shared mutable state.
    private struct TaskHandle: @unchecked Sendable {
        let task: BGTask
        func complete(success: Bool) { task.setTaskCompleted(success: success) }
    }

    private static func register(_ identifier: String, work: @escaping @Sendable () async -> Bool) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            // Reschedule first. A handler that throws, expires or simply finds nothing to do
            // still has to leave a successor behind, or the identifier goes quiet until the
            // next time the app is opened by hand.
            reschedule(identifier)

            let handle = TaskHandle(task: task)
            let running = Task {
                let finished = await work()
                handle.complete(success: finished)
            }
            // iOS gives no warning before it stops being generous. Cancelling lets the
            // orchestrator's `Task.checkCancellation()` stop between sections, on a checkpoint.
            task.expirationHandler = {
                log.notice("\(identifier, privacy: .public) expired; cancelling")
                running.cancel()
            }
        }
    }

    // MARK: - Scheduling

    /// Ask for all three, each only if it would have something to do.
    ///
    /// Called as the app leaves the foreground. Submitting a task with no work spends the app's
    /// budget with iOS and makes the ones that matter less likely to run.
    @MainActor
    static func scheduleWhatIsPending() async {
        if await BackgroundJobs.hasAuthorisedMutations() { submitProcessing(mutationFlushIdentifier, delay: 120) }
        // Either half of that handler having work is reason enough. A device with no offline
        // copy at all still has a queue whose changes are sitting in a ledger waiting for
        // somebody to open their desktop, and that is precisely the news it cannot get any
        // other way. Two ifs rather than one `||`, because the second question opens a database
        // per space and a device that has already answered yes need not be asked it.
        if BackgroundJobs.hasMirrors() {
            submitProcessing(mirrorRefreshIdentifier, delay: 3600)
        } else if await BackgroundJobs.awaitsDeliveries() {
            submitProcessing(mirrorRefreshIdentifier, delay: 3600)
        }
        if !DeepResearchCheckpointStore.spacesWithUnfinishedRuns().isEmpty {
            submitProcessing(deepResearchIdentifier, delay: 60)
        }
    }

    /// Requested from inside a handler, where asking what is left to do would cost another
    /// round of file and database reads for no benefit: if this run does not finish the work,
    /// the successor finds it; if it does, the successor finds nothing and costs almost nothing.
    private static func reschedule(_ identifier: String) {
        submitProcessing(identifier, delay: identifier == mirrorRefreshIdentifier ? 3600 : 300)
    }

    private static func submitProcessing(_ identifier: String, delay: TimeInterval) {
        let request = BGProcessingTaskRequest(identifier: identifier)
        // Every one of these talks to a Nodus Server; without a network they would wake up only
        // to fail.
        request.requiresNetworkConnectivity = true
        // Not required: a Deep Research run the user is waiting for should not have to wait for
        // a charger, and none of this is heavy enough to earn that condition.
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: delay)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Routine, not exceptional: the simulator has no scheduler at all, and a device
            // refuses when the app is in the foreground or over its budget.
            log.debug("could not submit \(identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    static func cancelAll() {
        BGTaskScheduler.shared.cancelAllTaskRequests()
    }
}

/// What each background task actually does.
///
/// Kept apart from the scheduling so it can be reasoned about — and, where it matters, tested —
/// without a `BGTask` in hand. Everything here is `@MainActor` because the pieces it drives
/// (the client, the outbox, the mirror) are actors of their own: this layer only ever awaits.
@MainActor
enum BackgroundJobs {
    private static var spacesDirectory: URL { ConnectionClient.spacesDirectory }

    // MARK: - Mutations

    static func hasAuthorisedMutations() async -> Bool {
        for connection in connectionsWithQueues {
            guard let outbox = try? MutationOutbox(spaceId: connection.storageId, directory: spacesDirectory) else { continue }
            if let count = try? await outbox.authorisedCount(), count > 0 { return true }
        }
        return false
    }

    /// Finish sending what the user already pressed send on.
    ///
    /// Only `authorisedPending` — never `pending`. The Writing screen promises that a change
    /// travels when the user says so, and a background task that sent unauthorised changes
    /// would quietly turn that promise into a lie.
    static func flushAuthorisedMutations() async -> Bool {
        var everythingLanded = true
        for connection in AppModel.syncableConnections() where connection.role.canSendChanges {
            if Task.isCancelled { return false }
            guard MutationOutbox.exists(spaceId: connection.storageId, directory: spacesDirectory) else { continue }
            guard let outbox = try? MutationOutbox(spaceId: connection.storageId, directory: spacesDirectory) else { continue }
            guard let queued = try? await outbox.authorisedPending(limit: connection.desktopPairingId == nil ? 200 : 100), !queued.isEmpty else { continue }
            // Cut by bytes, with the conservative budget rather than the server's: a background
            // window is not the place to spend a round trip on capabilities. Whatever does not
            // fit stays authorised and goes out in the next window or the next flush.
            var batch: [Mutation] = []
            var bytes = 0
            for mutation in queued {
                let size = mutation.encodedSize
                if !batch.isEmpty, bytes + size > MutationLimits.unstated.maxBatchBytes { break }
                bytes += size
                batch.append(mutation)
            }
            if batch.count < queued.count { everythingLanded = false }
            // A locked phone cannot read the token. That is a reason to try again later, not a
            // failure of the change.
            guard let client = ConnectionClient.make(for: connection) else { everythingLanded = false; continue }
            do {
                let receipt = try await client.send(mutations: batch, in: connection.spaceId)
                try await outbox.recordReceipt(receipt, for: batch)
            } catch {
                everythingLanded = false
            }
        }
        return everythingLanded
    }

    /// Spaces this device can send to and already has a queue for.
    ///
    /// Existence is asked of the filesystem, never by opening one: `MutationOutbox.init` creates
    /// its database, so a speculative open would leave an empty queue behind in every space this
    /// device has ever connected to.
    private static var connectionsWithQueues: [AppModel.Connection] {
        // `syncableConnections`, not `storedConnections`: the example vault is on this device and
        // has no server, so it can hold nothing that could ever be delivered.
        AppModel.syncableConnections().filter {
            $0.role.canSendChanges && MutationOutbox.exists(spaceId: $0.storageId, directory: spacesDirectory)
        }
    }

    /// Whether any space is holding changes whose fate this device could still learn.
    static func awaitsDeliveries() async -> Bool {
        for connection in connectionsWithQueues {
            guard let outbox = try? MutationOutbox(spaceId: connection.storageId, directory: spacesDirectory) else { continue }
            if let waiting = try? await outbox.awaitingDelivery(), waiting > 0 { return true }
            if connection.desktopPairingId != nil, let legacy = try? await outbox.acceptedWithoutCursor(), !legacy.isEmpty { return true }
        }
        return false
    }

    /// Ask each space how far its owner has collected, while nobody is looking.
    ///
    /// The other half of the same question the app asks when it comes back. This is the half
    /// that makes a report land in the vault overnight and be announced before its author has
    /// opened the app — which is the entire point of closing this loop.
    ///
    /// Anything it learns about a credential is deliberately dropped here: a background window
    /// has nowhere to say it, and the foreground pass will find the same thing the moment there
    /// is a screen to say it on.
    static func confirmDeliveries() async -> Bool {
        let connections = connectionsWithQueues
        guard !connections.isEmpty else { return true }
        let directory = spacesDirectory

        let outcome = await MutationDelivery.confirm(for: connections) { connection in
            try? MutationOutbox(spaceId: connection.storageId, directory: directory)
        }
        // `mayAsk: false` — the prompt is only ever shown to an app that is on screen.
        await DeliveryNotice.announce(outcome.landings, mayAsk: false)
        return outcome.everySpaceAnswered
    }

    // MARK: - Mirror

    /// Whether an offline copy exists, asked of the filesystem rather than of `MirrorStore`.
    ///
    /// `MirrorStore.init` creates its database, so opening one to find out whether it exists
    /// would answer "yes" from then on for every space the user never downloaded.
    static func hasMirror(spaceId: String) -> Bool {
        FileManager.default.fileExists(
            atPath: spacesDirectory
                .appendingPathComponent(spaceId, isDirectory: true)
                .appendingPathComponent("mirror.sqlite").path
        )
    }

    static func hasMirrors() -> Bool {
        AppModel.syncableConnections().contains { hasMirror(spaceId: $0.storageId) }
    }

    /// Bring offline copies back up to date, and only ones that already exist.
    ///
    /// Downloading a snapshot for a space whose owner never asked for an offline copy would
    /// spend their bytes on a decision they did not make.
    static func refreshStaleMirrors() async -> Bool {
        var allCurrent = true
        for connection in AppModel.syncableConnections() where hasMirror(spaceId: connection.storageId) {
            if Task.isCancelled { return false }
            guard let store = try? MirrorStore(spaceId: connection.storageId, directory: spacesDirectory),
                  (try? await store.summary()) != nil
            else { continue }
            guard let client = ConnectionClient.make(for: connection) else { allCurrent = false; continue }
            do {
                let revision = try await client.snapshotRevision(in: connection.spaceId) ?? ""
                if try await store.isCurrent(with: revision) { continue }
                let snapshot = try await client.snapshot(in: connection.spaceId)
                _ = try await store.replace(with: snapshot, revision: revision.isEmpty ? (snapshot.revision ?? "") : revision)
            } catch {
                allCurrent = false
            }
        }
        return allCurrent
    }

    // MARK: - Deep Research

    /// Carry on any run that was killed halfway.
    ///
    /// The sections already written are kept; only the ones the run never reached are paid for
    /// again. If the phone is locked the provider key cannot be read, and the right answer is to
    /// come back later rather than to fail the run.
    static func resumeDeepResearch() async -> Bool {
        let unfinished = DeepResearchCheckpointStore.spacesWithUnfinishedRuns()
        guard !unfinished.isEmpty else { return true }

        let connections = AppModel.syncableConnections()
        let settings = AISettings()
        var allFinished = true

        for (spaceId, checkpoint) in unfinished {
            if Task.isCancelled { return false }
            guard let connection = connections.first(where: { $0.storageId == spaceId }),
                  let client = ConnectionClient.make(for: connection)
            else { allFinished = false; continue }
            let mode = UserDefaults.standard.string(forKey: "ai-execution-mode:\(connection.id)").flatMap(AIExecutionMode.init(rawValue:))
                ?? (connection.desktopPairingId == nil ? .autonomous : .live)
            guard mode == .autonomous else { allFinished = false; continue }
            // Presence, not value: the key itself is read inside the provider client.
            guard settings.hasKey(for: checkpoint.request.model.provider) else { allFinished = false; continue }

            let retrieval = CorpusRetrieval(
                client: client,
                spaceId: connection.spaceId,
                embeddings: EmbeddingService(keyProvider: settings.keyProvider),
                identity: await reachableEmbedding(client: client, spaceId: connection.spaceId, settings: settings)
            )
            let orchestrator = DeepResearchOrchestrator(
                deps: DeepResearchWiring.deps(
                    retrieval: retrieval,
                    provider: ProviderClient(keyProvider: settings.keyProvider),
                    // The same naming the foreground gets. A report finished by a background
                    // task is the same document, and it would be a strange one that cited raw
                    // ids only because the app happened to be closed when it ended.
                    citations: CorpusCitations(client: client, spaceId: connection.spaceId)
                )
            )

            do {
                let report = try await orchestrator.run(
                    checkpoint.request,
                    resuming: checkpoint,
                    onCheckpoint: { progress in
                        DeepResearchCheckpointStore.save(progress, spaceId: spaceId)
                    }
                )
                let queued = DeepResearchQueue.shared.jobs(in: spaceId).first {
                    !$0.status.isFinished && $0.request == checkpoint.request
                }
                let reportId = queued?.id ?? UUID().uuidString
                LocalReportStore.shared(for: spaceId).save(
                    report,
                    mode: checkpoint.request.mode,
                    model: checkpoint.request.model,
                    id: reportId
                )
                if queued != nil {
                    DeepResearchQueue.shared.completeRecovered(
                        jobId: reportId,
                        savedReportId: reportId,
                        publicationNote: String(localized: "Saved locally; publication will resume when the space opens.")
                    )
                }
                DeepResearchCheckpointStore.clear(spaceId: spaceId)
            } catch {
                // The checkpoint stays exactly where it was, so the next attempt starts from the
                // last section that was actually paid for.
                allFinished = false
            }
        }
        return allFinished
    }

    /// The vault's embedding identity, but only when this device could ever match it.
    private static func reachableEmbedding(
        client: NodusClient,
        spaceId: String,
        settings: AISettings
    ) async -> EmbeddingIdentity? {
        guard let identity = try? await client.publishedEmbeddingIdentity(in: spaceId) else { return nil }
        let probe = EmbeddingProbeResult.published(identity)
        guard probe.isReachableFromPhone else { return nil }
        return identity
    }
}
