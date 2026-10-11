import CryptoKit
import Foundation

/// Private learning progress is authored work. It travels only through the
/// owning Mac's writing grant, never through a published corpus snapshot.
public enum CompanionImmersionProgress {
    public struct Answer: Codable, Sendable, Equatable {
        public let questionId: String, kind: String, answer: String, answeredAt: String
        public let correct: Bool?
        public let assessment: JSONValue?
        public init(questionId: String, kind: String, answer: String, correct: Bool?, answeredAt: String) {
            self.questionId = questionId; self.kind = kind; self.answer = answer; self.correct = correct
            self.answeredAt = answeredAt; assessment = nil
        }
        private enum CodingKeys: String, CodingKey { case questionId, kind, answer, answeredAt, correct, assessment }
        public func encode(to encoder: any Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            try box.encode(questionId, forKey: .questionId); try box.encode(kind, forKey: .kind)
            try box.encode(answer, forKey: .answer); try box.encode(answeredAt, forKey: .answeredAt)
            try box.encode(correct, forKey: .correct); try box.encode(assessment, forKey: .assessment)
        }
    }
    public struct Progress: Codable, Sendable, Equatable {
        public var currentStep = 0, furthestStep = 0
        public var completedSteps: [Int] = []
        public var answers: [Answer] = []
        public var startedAt: String?, finishedAt: String?
        public init() { startedAt = nil; finishedAt = nil }
        private enum CodingKeys: String, CodingKey { case currentStep, furthestStep, completedSteps, answers, startedAt, finishedAt }
        public func encode(to encoder: any Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            try box.encode(currentStep, forKey: .currentStep); try box.encode(furthestStep, forKey: .furthestStep)
            try box.encode(completedSteps, forKey: .completedSteps); try box.encode(answers, forKey: .answers)
            try box.encode(startedAt, forKey: .startedAt); try box.encode(finishedAt, forKey: .finishedAt)
        }
    }
    public struct Snapshot: Codable, Sendable, Equatable {
        public let version: Int, sessionId: String, sourceRevision: String, progressRevision: String
        public let progress: Progress
        public func validate(sessionId expected: String) throws {
            guard version == 1, sessionId == expected, Self.hash(sourceRevision), Self.hash(progressRevision),
                  progress.currentStep >= 0, progress.furthestStep >= progress.currentStep,
                  Set(progress.completedSteps).count == progress.completedSteps.count, progress.completedSteps.allSatisfy({ $0 >= 0 }),
                  Set(progress.answers.map(\.questionId)).count == progress.answers.count,
                  progress.answers.allSatisfy({ !$0.questionId.isEmpty && ["open","choice"].contains($0.kind) && $0.answer.count <= 10_000 }) else { throw DesktopBridgeError.malformedResponse }
        }
        private static func hash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
    }
    public struct Receipt: Codable, Sendable { public let id: String, snapshot: Snapshot }
    public struct Request: Codable, Sendable, Equatable {
        public let version: Int, id: String, sourceRevision: String
        public let expectedProgressRevision: String?
        public let progress: Progress
        private enum CodingKeys: String, CodingKey { case version, id, sourceRevision, expectedProgressRevision, progress }
        public func encode(to encoder: any Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            try box.encode(version, forKey: .version); try box.encode(id, forKey: .id); try box.encode(sourceRevision, forKey: .sourceRevision)
            try box.encode(expectedProgressRevision, forKey: .expectedProgressRevision); try box.encode(progress, forKey: .progress)
        }
    }
    /// Same length-prefixed UTF-8 fields as Desktop. No JSON key-order or
    /// slash-escaping assumptions enter the cross-platform source identity.
    public static func sourceRevision(plan value: JSONValue) throws -> String {
        guard let plan = value.objectValue, let minutes = plan["minutes"]?.intValue,
              let stations = plan["stations"]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
        let questions = stations.flatMap { $0.objectValue?["quiz"]?.arrayValue ?? [] }
            + (plan["exam"]?.objectValue?["questions"]?.arrayValue ?? [])
        var parts = ["nodus:immersion-progress-plan:1", plan["topic"]?.stringValue ?? "", plan["title"]?.stringValue ?? "",
            plan["language"]?.stringValue ?? "", plan["generatedAt"]?.stringValue ?? "", String(minutes), String(stations.count)]
        parts += stations.map { $0.objectValue?["id"]?.stringValue ?? "" }; parts.append(String(questions.count))
        for value in questions {
            guard let question = value.objectValue, let id = question["id"]?.stringValue, !id.isEmpty,
                  let kind = question["kind"]?.stringValue, ["open","choice"].contains(kind) else { throw DesktopBridgeError.malformedResponse }
            let options = question["options"]?.arrayValue ?? []
            parts += [id, kind, question["question"]?.stringValue ?? "", String(options.count),
                (question["correctIndex"]?.intValue).map { String($0) } ?? "", question["explanation"]?.stringValue ?? "", question["expected"]?.stringValue ?? ""]
            parts += options.map { $0.stringValue ?? "" }
        }
        var hash = SHA256()
        for part in parts { hash.update(data: Data("\(part.utf8.count):".utf8)); hash.update(data: Data(part.utf8)) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public actor CompanionImmersionProgressOutbox {
    public enum State: String, Codable, Sendable { case saved, pending, conflict, blocked }
    public struct Entry: Sendable {
        public let progress: CompanionImmersionProgress.Progress
        public let state: State
        public let issue: String?
        public let remote: CompanionImmersionProgress.Snapshot?
        public let hasMacBaseline: Bool
    }
    private struct Sending: Codable { let request: CompanionImmersionProgress.Request, generation: Int }
    private struct Record: Codable {
        let sourceRevision: String
        var targetSessionId: String?
        var draft: CompanionImmersionProgress.Progress
        var baselineRevision: String?
        var generation: Int
        var sending: Sending?
        var state: State
        var issue: String?
        var remote: CompanionImmersionProgress.Snapshot?
    }
    private let cache: PrivateBridgeCache, vaultId: String
    private var records: [String: Record]
    private var synchronizing = false
    public private(set) var revision = 0
    static let storageKey = "companion-immersion-progress-v1"
    init(cache: PrivateBridgeCache, vaultId: String, data: Data?) throws {
        self.cache = cache; self.vaultId = vaultId
        records = try data.map { try JSONDecoder.nodus.decode([String: Record].self, from: $0) } ?? [:]
    }
    public func entry(sessionId: String, sourceRevision: String) throws -> Entry? {
        guard let record = records[key(sessionId)] else { return nil }
        guard record.sourceRevision == sourceRevision else { throw APIError(status: 409, code: "immersion_plan_changed", message: "El itinerario ha cambiado. Tus respuestas anteriores siguen conservadas en este dispositivo.") }
        return .init(progress: record.draft, state: record.state, issue: record.issue, remote: record.remote, hasMacBaseline: record.baselineRevision != nil)
    }
    public func seed(_ snapshot: CompanionImmersionProgress.Snapshot) async throws {
        try snapshot.validate(sessionId: snapshot.sessionId)
        let identity = key(snapshot.sessionId)
        if let current = records[identity], current.state != .saved { return }
        if let current = records[identity], current.sourceRevision == snapshot.sourceRevision,
           current.baselineRevision == snapshot.progressRevision, current.draft == snapshot.progress { return }
        records[identity] = Record(sourceRevision: snapshot.sourceRevision, targetSessionId: snapshot.sessionId, draft: snapshot.progress,
            baselineRevision: snapshot.progressRevision, generation: 0, sending: nil, state: .saved, issue: nil, remote: nil)
        try await persist()
    }
    public static func localSessionKey(publicationId: String) -> String { "local-immersion:\(publicationId)" }
    public func prepare(sessionId: String, sourceRevision: String, publicationId: String? = nil) async throws {
        if try entry(sessionId: sessionId, sourceRevision: sourceRevision) != nil { return }
        if let publicationId, sessionId != Self.localSessionKey(publicationId: publicationId) { throw DesktopBridgeError.malformedResponse }
        records[sessionId] = Record(sourceRevision: sourceRevision, targetSessionId: publicationId == nil ? sessionId : nil,
            draft: .init(), baselineRevision: nil, generation: 0, sending: nil, state: .saved, issue: nil, remote: nil)
        try await persist()
    }
    /// Only the owning generation ledger's canonical receipt supplies this ID.
    /// Pending phone generation never sends progress to the job UUID as a session.
    public func associate(publicationId: String, sessionId: String, sourceRevision: String) async throws {
        let identity = Self.localSessionKey(publicationId: publicationId)
        guard var record = records[identity] else { return }
        guard !sessionId.isEmpty else { throw DesktopBridgeError.malformedResponse }
        if record.targetSessionId == sessionId, record.sourceRevision == sourceRevision { return }
        if record.sourceRevision != sourceRevision {
            record.state = .blocked; record.issue = "El itinerario confirmado difiere de la copia usada para responder. Tus respuestas permanecen conservadas."
        } else {
            guard record.targetSessionId == nil || record.targetSessionId == sessionId else { throw DesktopBridgeError.malformedResponse }
            record.targetSessionId = sessionId
        }
        records[identity] = record; try await persist()
    }
    private func key(_ sessionId: String) -> String {
        records.keys.sorted().first { $0.hasPrefix("local-immersion:") && records[$0]?.targetSessionId == sessionId } ?? sessionId
    }
    public func answer(sessionId: String, sourceRevision: String, record answer: CompanionImmersionProgress.Answer) async throws {
        var record = try writable(sessionId: sessionId, sourceRevision: sourceRevision)
        record.draft.answers.removeAll { $0.questionId == answer.questionId }; record.draft.answers.append(answer)
        record.draft.startedAt = record.draft.startedAt ?? answer.answeredAt
        try await save(sessionId: sessionId, record: record)
    }
    public func step(sessionId: String, sourceRevision: String, index: Int, completed: Bool, finished: Bool = false) async throws {
        guard index >= 0 else { throw DesktopBridgeError.malformedResponse }
        var record = try writable(sessionId: sessionId, sourceRevision: sourceRevision)
        record.draft.currentStep = index; record.draft.furthestStep = max(record.draft.furthestStep, index)
        record.draft.startedAt = record.draft.startedAt ?? ISO8601DateFormatter().string(from: Date())
        if completed { record.draft.completedSteps = Array(Set(record.draft.completedSteps + [index])).sorted() }
        if finished { record.draft.finishedAt = record.draft.finishedAt ?? ISO8601DateFormatter().string(from: Date()) }
        try await save(sessionId: sessionId, record: record)
    }
    public func restart(sessionId: String, sourceRevision: String) async throws {
        var record = try writable(sessionId: sessionId, sourceRevision: sourceRevision)
        record.draft = .init(); try await save(sessionId: sessionId, record: record)
    }
    /// Renderer navigation may carry an older answer array. Responses are
    /// authored through `answer`; only an explicit restart clears them.
    public func navigate(sessionId: String, sourceRevision: String, progress: CompanionImmersionProgress.Progress) async throws {
        var record = try writable(sessionId: sessionId, sourceRevision: sourceRevision)
        record.draft.currentStep = progress.currentStep
        record.draft.furthestStep = max(record.draft.furthestStep, progress.furthestStep)
        record.draft.completedSteps = Array(Set(record.draft.completedSteps + progress.completedSteps)).sorted()
        record.draft.startedAt = record.draft.startedAt ?? progress.startedAt
        record.draft.finishedAt = record.draft.finishedAt ?? progress.finishedAt
        try await save(sessionId: sessionId, record: record)
    }
    public func retry(sessionId: String) async throws {
        let identity = key(sessionId)
        guard var record = records[identity], record.state == .blocked else { return }
        record.state = .pending; record.issue = nil; records[identity] = record; try await persist()
    }
    private func writable(sessionId: String, sourceRevision: String) throws -> Record {
        _ = try entry(sessionId: sessionId, sourceRevision: sourceRevision)
        return records[key(sessionId)] ?? Record(sourceRevision: sourceRevision, targetSessionId: sessionId, draft: .init(), baselineRevision: nil,
            generation: 0, sending: nil, state: .saved, issue: nil, remote: nil)
    }
    private func save(sessionId: String, record: Record) async throws {
        var next = record; next.generation += 1
        if next.state == .saved { next.state = .pending }; next.issue = next.state == .pending ? nil : next.issue
        records[key(sessionId)] = next; try await persist()
    }
    /// Only explicit review may replace the baseline after concurrent Mac work.
    public func resolve(sessionId: String, keepPhone: Bool) async throws {
        let identity = key(sessionId)
        guard var record = records[identity], record.state == .conflict, let remote = record.remote,
              remote.sourceRevision == record.sourceRevision else { throw DesktopBridgeError.malformedResponse }
        record.baselineRevision = remote.progressRevision; record.sending = nil; record.remote = nil; record.issue = nil
        record.generation += 1
        if keepPhone { record.state = .pending } else { record.draft = remote.progress; record.state = .saved }
        records[identity] = record; try await persist()
    }
    public func synchronize(send: @Sendable (String, CompanionImmersionProgress.Request) async throws -> CompanionImmersionProgress.Receipt) async throws {
        guard !synchronizing else { return }; synchronizing = true; defer { synchronizing = false }
        for sessionId in records.keys.sorted() {
            while var record = records[sessionId], record.state == .pending, let target = record.targetSessionId {
                if record.sending == nil {
                    record.sending = Sending(request: .init(version: 1, id: UUID().uuidString, sourceRevision: record.sourceRevision,
                        expectedProgressRevision: record.baselineRevision, progress: record.draft), generation: record.generation)
                    records[sessionId] = record; try await persist()
                }
                let sending = record.sending!
                do {
                    let receipt = try await send(target, sending.request)
                    try receipt.snapshot.validate(sessionId: target)
                    guard receipt.id == sending.request.id, receipt.snapshot.sourceRevision == record.sourceRevision,
                          var latest = records[sessionId] else { throw DesktopBridgeError.malformedResponse }
                    latest.baselineRevision = receipt.snapshot.progressRevision; latest.sending = nil; latest.issue = nil; latest.remote = nil
                    if latest.generation == sending.generation { latest.draft = receipt.snapshot.progress; latest.state = .saved }
                    records[sessionId] = latest; try await persist()
                } catch {
                    guard var latest = records[sessionId] else { throw error }
                    if let api = error as? APIError, api.code == "immersion_progress_conflict", let value = api.details["remote"] {
                        let remote = try JSONDecoder.nodus.decode(CompanionImmersionProgress.Snapshot.self, from: JSONEncoder.nodus.encode(value))
                        try remote.validate(sessionId: target)
                        guard remote.sourceRevision == latest.sourceRevision else { throw DesktopBridgeError.malformedResponse }
                        latest.remote = remote; latest.state = .conflict
                    } else if error is CancellationError || Self.transportLoss(error) { throw error }
                    else { latest.state = .blocked }
                    latest.issue = error.localizedDescription; records[sessionId] = latest; try await persist(); break
                }
            }
        }
    }
    private func persist() async throws {
        try await cache.store(JSONEncoder.nodus.encode(records), vaultId: vaultId, domain: .writing, recordId: Self.storageKey)
        revision += 1
    }
    private static func transportLoss(_ error: any Error) -> Bool {
        if let error = error as? APIError { return error.status >= 500 || error.isRateLimited }
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet,.networkConnectionLost,.cannotConnectToHost,.cannotFindHost,.dnsLookupFailed,.timedOut,.cancelled].contains(error.code)
    }
}

public actor CompanionImmersionProgressOutboxes {
    public static let shared = CompanionImmersionProgressOutboxes()
    private var stores: [String: Task<CompanionImmersionProgressOutbox, any Error>] = [:]
    public func outbox(pairingId: String, vaultId: String) async throws -> CompanionImmersionProgressOutbox {
        let key = "\(pairingId)|\(vaultId)"
        if let task = stores[key] { return try await task.value }
        let task = Task {
            let cache = try PrivateBridgeCache(pairingId: pairingId)
            return try await CompanionImmersionProgressOutbox(cache: cache, vaultId: vaultId,
                data: cache.data(vaultId: vaultId, domain: .writing, recordId: CompanionImmersionProgressOutbox.storageKey))
        }
        stores[key] = task
        do { return try await task.value } catch { stores[key] = nil; throw error }
    }
    public func forget(pairingId: String) { for key in stores.keys.filter({ $0.hasPrefix("\(pairingId)|") }) { stores[key] = nil } }
}
