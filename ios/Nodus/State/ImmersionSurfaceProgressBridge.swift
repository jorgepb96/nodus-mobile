import Foundation
import NodusKit

/// The shared player and the native reader share one private, durable journal.
/// No iframe operation can bypass revision checks with a direct progress write.
@MainActor final class ImmersionSurfaceProgressBridge {
    private let session: SpaceSession
    private var definitions: [String: JSONValue] = [:]
    init(session: SpaceSession) { self.session = session }
    static let writeMethods: Set<String> = ["setImmersionProgress", "answerImmersionQuestion", "restartImmersionSession"]
    func read(_ value: JSONValue, id: String, client: DesktopBridgeClient, pairing: DesktopBridgePairing, vaultId: String, fetchMacProgress: Bool = true) async throws -> JSONValue {
        guard var definition = value.objectValue, definition["id"]?.stringValue == id, let plan = definition["plan"]?.objectValue else { throw DesktopBridgeError.malformedResponse }
        let source = JSONValue.object(plan)
        // Consultation grants do not imply access to private learning answers.
        definition["progress"] = try encoded(CompanionImmersionProgress.Progress())
        definitions[id] = .object(definition)
        guard pairing.domains.contains(.writing) else { return .object(definition) }
        let revision = try CompanionImmersionProgress.sourceRevision(plan: source)
        let store = try await CompanionImmersionProgressOutboxes.shared.outbox(pairingId: pairing.id, vaultId: vaultId)
        try await store.prepare(sessionId: id, sourceRevision: revision)
        if fetchMacProgress { do {
            let snapshot = try await client.immersionProgress(vaultId: vaultId, sessionId: id)
            guard snapshot.sourceRevision == revision else { throw APIError(status: 409, code: "immersion_plan_changed", message: "El itinerario cambió mientras se abría. Vuelve a abrir la sesión.") }
            try await store.seed(snapshot)
        } catch {
            guard isPrivateBridgeOffline(error) else { throw error }
        } }
        guard let entry = try await store.entry(sessionId: id, sourceRevision: revision) else { throw DesktopBridgeError.malformedResponse }
        definition["progress"] = try encoded(entry.progress)
        definition["mobileSyncState"] = .string(entry.state.rawValue)
        return .object(definition)
    }
    func write(method: String, args: [JSONValue], pairing: DesktopBridgePairing, vaultId: String) async throws -> JSONValue {
        guard !pairing.isExpired, pairing.vaultIds.contains(vaultId), pairing.domains.contains(.writing), session.connection.role.canSendChanges else { throw DesktopBridgeError.permissionDenied }
        let id = method == "answerImmersionQuestion" ? args.first?.objectValue?["sessionId"]?.stringValue : args.first?.stringValue
        guard let id, let definition = definitions[id]?.objectValue, let plan = definition["plan"],
              let parsed = ImmersionPlan(Row(["plan": plan])) else {
            throw APIError(status: 409, code: "immersion_source_required", message: "Abre el recorrido antes de guardar su progreso.")
        }
        let revision = try CompanionImmersionProgress.sourceRevision(plan: plan)
        let store = try await CompanionImmersionProgressOutboxes.shared.outbox(pairingId: pairing.id, vaultId: vaultId)
        if method == "setImmersionProgress", args.count == 2 {
            let progress = try JSONDecoder.nodus.decode(CompanionImmersionProgress.Progress.self, from: JSONEncoder.nodus.encode(args[1]))
            let steps = parsed.stations.count + 4, questionIds = Set((parsed.stations.flatMap(\.quiz) + parsed.exam).map(\.id))
            guard progress.currentStep >= 0, progress.currentStep < steps, progress.furthestStep >= progress.currentStep, progress.furthestStep < steps,
                  progress.completedSteps.allSatisfy({ $0 >= 0 && $0 < steps }), Set(progress.completedSteps).count == progress.completedSteps.count,
                  progress.answers.allSatisfy({ questionIds.contains($0.questionId) && $0.answer.utf16.count <= 10_000 }),
                  Set(progress.answers.map(\.questionId)).count == progress.answers.count else { throw DesktopBridgeError.malformedResponse }
            try await store.navigate(sessionId: id, sourceRevision: revision, progress: progress)
            changed(); return .null
        }
        if method == "restartImmersionSession", args.count == 1 {
            try await store.restart(sessionId: id, sourceRevision: revision)
            var result = definition; result["progress"] = try encoded(CompanionImmersionProgress.Progress())
            changed(); return .object(result)
        }
        if method == "answerImmersionQuestion", args.count == 1, let input = args[0].objectValue,
           let questionId = input["questionId"]?.stringValue, let answer = input["answer"]?.stringValue,
           answer.utf16.count <= 10_000,
           let question = (parsed.stations.flatMap(\.quiz) + parsed.exam).first(where: { $0.id == questionId }) {
            if question.isChoice {
                guard let option = Int(answer), String(option) == answer, question.options.indices.contains(option) else { throw DesktopBridgeError.malformedResponse }
            }
            let record = CompanionImmersionProgress.Answer(questionId: questionId, kind: question.isChoice ? "choice" : "open", answer: answer,
                correct: question.isChoice ? Int(answer) == question.correctIndex : nil, answeredAt: ISO8601DateFormatter().string(from: Date()))
            try await store.answer(sessionId: id, sourceRevision: revision, record: record)
            guard let entry = try await store.entry(sessionId: id, sourceRevision: revision) else { throw DesktopBridgeError.malformedResponse }
            changed(); return .object(["record": try encoded(record), "progress": try encoded(entry.progress)])
        }
        throw DesktopBridgeError.malformedResponse
    }
    private func changed() {
        session.didChangeImmersionProgress()
        Task { await session.synchronizeCompanionChanges() }
    }
    private func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder.nodus.decode(JSONValue.self, from: JSONEncoder.nodus.encode(value))
    }
}
