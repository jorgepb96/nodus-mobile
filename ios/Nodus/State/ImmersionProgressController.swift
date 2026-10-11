import Foundation
import NodusKit
import Observation

@MainActor @Observable
final class ImmersionProgressController {
    private let session: SpaceSession
    private let sessionId: String
    private let publicationId: String?
    private let sourceRevision: String
    let totalSteps: Int
    private var outbox: CompanionImmersionProgressOutbox?
    private(set) var progress = CompanionImmersionProgress.Progress()
    private(set) var state = CompanionImmersionProgressOutbox.State.saved
    private(set) var remote: CompanionImmersionProgress.Snapshot?
    private(set) var issue: String?
    private(set) var loading = true
    private(set) var saving = false
    private(set) var offline = false
    private(set) var canSync = false

    init(session: SpaceSession, sessionId: String, plan: ImmersionPlan, publicationId: String? = nil) throws {
        self.session = session; self.publicationId = publicationId
        self.sessionId = publicationId.map { CompanionImmersionProgressOutbox.localSessionKey(publicationId: $0) } ?? sessionId
        sourceRevision = try CompanionImmersionProgress.sourceRevision(plan: plan.source)
        totalSteps = plan.stations.count + 4
    }
    func load() async {
        loading = true; issue = nil; offline = false; canSync = false
        defer { loading = false }
        do {
            let vault = session.vaultId ?? session.connection.spaceId
            let pairingId = session.connection.desktopPairingId ?? "reader-progress:\(session.connection.storageId)"
            let store = try await CompanionImmersionProgressOutboxes.shared.outbox(pairingId: pairingId, vaultId: vault)
            outbox = store
            try await store.prepare(sessionId: sessionId, sourceRevision: sourceRevision, publicationId: publicationId)
            await reloadLocal()
            if let (client, _) = try await ConnectionClient.companionDocuments(for: session.connection) {
                canSync = true
                if let publicationId {
                    let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairingId, vaultId: vault)
                    if let result = await ledger.all().first(where: { $0.id == publicationId && $0.method == "saveImmersionGeneratedSession" && $0.state == "available" }),
                       let id = result.result?.objectValue?["id"]?.stringValue,
                       let plan = result.result?.objectValue?["plan"], let revision = try? CompanionImmersionProgress.sourceRevision(plan: plan) {
                        try await store.associate(publicationId: publicationId, sessionId: id, sourceRevision: revision)
                    }
                } else {
                    do {
                        let snapshot = try await client.immersionProgress(vaultId: vault, sessionId: sessionId)
                        guard snapshot.sourceRevision == sourceRevision else { throw APIError(status: 409, code: "immersion_plan_changed", message: "El itinerario cambió en el Mac. Vuelve a abrir su versión actual antes de sincronizar las respuestas.") }
                        try await store.seed(snapshot)
                    } catch {
                        guard isPrivateBridgeOffline(error) else { throw error }; offline = true
                    }
                }
                await reloadLocal()
            }
        } catch is CancellationError { }
        catch { issue = error.localizedDescription }
    }
    func reloadLocal() async {
        guard let outbox else { return }
        do {
            if let entry = try await outbox.entry(sessionId: sessionId, sourceRevision: sourceRevision) {
                progress = entry.progress; state = entry.state; remote = entry.remote; issue = entry.issue
            }
        } catch { issue = error.localizedDescription }
    }
    func answer(_ question: ImmersionPlan.Question, value: String) async {
        guard let outbox, !loading, !saving, value.utf16.count <= 10_000 else { return }
        saving = true; defer { saving = false }
        do {
            let choice = Int(value)
            let record = CompanionImmersionProgress.Answer(questionId: question.id, kind: question.isChoice ? "choice" : "open",
                answer: value, correct: question.isChoice ? choice == question.correctIndex : nil,
                answeredAt: ISO8601DateFormatter().string(from: Date()))
            try await outbox.answer(sessionId: sessionId, sourceRevision: sourceRevision, record: record)
            await reloadLocal(); await synchronize()
        } catch { issue = error.localizedDescription }
    }
    func visit(index: Int, completed: Bool = false, finished: Bool = false) async {
        guard index >= 0, index < totalSteps else { return }
        if progress.currentStep == index, progress.startedAt != nil, !completed, !finished { return }
        guard let outbox, !loading, !saving else { return }
        saving = true; defer { saving = false }
        do {
            try await outbox.step(sessionId: sessionId, sourceRevision: sourceRevision, index: index, completed: completed, finished: finished)
            await reloadLocal(); await synchronize()
        } catch { issue = error.localizedDescription }
    }
    func resolve(keepPhone: Bool) async {
        guard let outbox, !saving else { return }
        saving = true; defer { saving = false }
        do {
            try await outbox.resolve(sessionId: sessionId, keepPhone: keepPhone)
            await reloadLocal(); await synchronize()
        } catch { issue = error.localizedDescription }
    }
    func restart() async {
        guard let outbox, !loading, !saving else { return }
        saving = true; defer { saving = false }
        do {
            try await outbox.restart(sessionId: sessionId, sourceRevision: sourceRevision)
            await reloadLocal(); await synchronize()
        } catch { issue = error.localizedDescription }
    }
    func retry() async {
        guard let outbox, !loading, !saving else { return }
        saving = true; defer { saving = false }
        do { try await outbox.retry(sessionId: sessionId); await reloadLocal(); await synchronize() }
        catch { issue = error.localizedDescription }
    }
    private func synchronize() async {
        guard canSync else { return }
        await session.synchronizeCompanionChanges(); await reloadLocal()
    }
}
