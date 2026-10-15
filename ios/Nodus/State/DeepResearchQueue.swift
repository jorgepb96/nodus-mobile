import Foundation
import NodusAI
import Observation

enum DeepResearchQueueStatus: String, Codable, Hashable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled

    var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .queued, .running: false
        }
    }
}

struct DeepResearchQueueJob: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let spaceId: String
    let spaceName: String
    let request: DeepResearchRequest
    var status: DeepResearchQueueStatus
    var progress: DeepResearchProgress?
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var savedReportId: String?
    var publicationNote: String?
    var errorMessage: String?

    var title: String { request.objective }
}

struct DeepResearchQueueResult: Sendable {
    let savedReportId: String
    let publicationNote: String
}

/// The single sequential Deep Research lane shared by every space.
///
/// The ledger is persisted independently from any view or session. Executable closures are
/// deliberately not persisted: after a relaunch the matching space runner reattaches a typed
/// executor, while the request and its place in the queue remain intact on disk.
@Observable
@MainActor
final class DeepResearchQueue {
    typealias Executor = @MainActor () async throws -> DeepResearchQueueResult

    static let shared = DeepResearchQueue()

    private(set) var jobs: [DeepResearchQueueJob] = []
    private var executors: [String: Executor] = [:]
    private var driver: Task<Void, Never>?
    private var runningId: String?
    private let file: URL

    init(root: URL = .applicationSupportDirectory) {
        let directory = root.appendingPathComponent("deep-research", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("queue-v1.json")
        reload()
    }

    @discardableResult
    func enqueue(
        id: String = UUID().uuidString,
        spaceId: String,
        spaceName: String,
        request: DeepResearchRequest,
        executor: @escaping Executor
    ) -> String {
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            executors[id] = executor
            if jobs[index].status == .failed || jobs[index].status == .cancelled {
                jobs[index].status = .queued
                jobs[index].errorMessage = nil
                jobs[index].finishedAt = nil
            }
        } else {
            jobs.append(DeepResearchQueueJob(
                id: id,
                spaceId: spaceId,
                spaceName: spaceName,
                request: request,
                status: .queued,
                progress: DeepResearchProgress(phase: .queued, message: String(localized: "Queued"), wordsSoFar: 0),
                createdAt: Date()
            ))
            executors[id] = executor
        }
        persist()
        drive()
        return id
    }

    /// Reconnect a persisted job to the live session that knows how to execute it.
    func attach(jobId: String, executor: @escaping Executor) {
        guard let job = jobs.first(where: { $0.id == jobId }), job.status == .queued else { return }
        executors[jobId] = executor
        drive()
    }

    func update(jobId: String, progress: DeepResearchProgress) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }), jobs[index].status == .running else { return }
        let previousSection = jobs[index].progress?.sectionIndex
        let previousPhase = jobs[index].progress?.phase
        jobs[index].progress = progress
        // Checkpoints are the high-frequency durable progress record. The queue only needs a
        // useful snapshot and avoids rewriting JSON for every streamed token.
        if progress.sectionIndex != previousSection || progress.phase != previousPhase || progress.phase == .done {
            persist()
        }
    }

    func cancel(_ id: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[index].status {
        case .queued:
            jobs[index].status = .cancelled
            jobs[index].finishedAt = Date()
            jobs[index].errorMessage = String(localized: "Cancelled.")
            executors[id] = nil
            persist()
            drive()
        case .running where runningId == id:
            driver?.cancel()
        default:
            break
        }
    }

    func retry(_ id: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status.isFinished else { return }
        jobs[index].status = .queued
        jobs[index].progress = DeepResearchProgress(phase: .queued, message: String(localized: "Waiting to reconnect to the space"), wordsSoFar: 0)
        jobs[index].errorMessage = nil
        jobs[index].finishedAt = nil
        persist()
        drive()
    }

    func remove(_ id: String) {
        guard jobs.first(where: { $0.id == id })?.status != .running else { return }
        jobs.removeAll { $0.id == id }
        executors[id] = nil
        persist()
    }

    func clearFinished() {
        let removed = Set(jobs.filter(\.status.isFinished).map(\.id))
        jobs.removeAll { $0.status.isFinished }
        for id in removed { executors[id] = nil }
        persist()
    }

    /// A BGProcessing task may finish a checkpoint before any window has recreated its space
    /// session. It records the same terminal result in the durable ledger without inventing a
    /// second UI-only job.
    func completeRecovered(jobId: String, savedReportId: String, publicationNote: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[index].status = .completed
        jobs[index].savedReportId = savedReportId
        jobs[index].publicationNote = publicationNote
        jobs[index].finishedAt = Date()
        jobs[index].progress = DeepResearchProgress(phase: .done, message: String(localized: "Completed"), wordsSoFar: jobs[index].progress?.wordsSoFar ?? 0)
        executors[jobId] = nil
        persist()
    }

    func jobs(in spaceId: String) -> [DeepResearchQueueJob] {
        jobs.filter { $0.spaceId == spaceId }
    }

    private func drive() {
        guard driver == nil else { return }
        guard let index = jobs.indices.first(where: {
            jobs[$0].status == .queued && executors[jobs[$0].id] != nil
        }) else { return }

        let id = jobs[index].id
        guard let executor = executors[id] else { return }
        jobs[index].status = .running
        jobs[index].startedAt = jobs[index].startedAt ?? Date()
        jobs[index].progress = DeepResearchProgress(phase: .queued, message: String(localized: "Starting"), wordsSoFar: 0)
        runningId = id
        persist()

        driver = Task { @MainActor in
            do {
                let result = try await executor()
                finish(id, result: result)
            } catch is CancellationError {
                finish(id, cancelled: true, error: String(localized: "Cancelled."))
            } catch {
                finish(id, cancelled: false, error: error.localizedDescription)
            }
        }
    }

    private func finish(_ id: String, result: DeepResearchQueueResult) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = .completed
        jobs[index].progress = DeepResearchProgress(phase: .done, message: String(localized: "Completed"), wordsSoFar: jobs[index].progress?.wordsSoFar ?? 0)
        jobs[index].savedReportId = result.savedReportId
        jobs[index].publicationNote = result.publicationNote
        jobs[index].finishedAt = Date()
        settle(id)
    }

    private func finish(_ id: String, cancelled: Bool, error: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = cancelled ? .cancelled : .failed
        jobs[index].errorMessage = error
        jobs[index].finishedAt = Date()
        settle(id)
    }

    private func settle(_ id: String) {
        executors[id] = nil
        runningId = nil
        driver = nil
        persist()
        drive()
    }

    private func reload() {
        guard let data = try? Data(contentsOf: file),
              var decoded = try? JSONDecoder.nodusQueue.decode([DeepResearchQueueJob].self, from: data)
        else { return }
        guard BetaAIFeatures.autonomousGeneration else { jobs = decoded; return }
        // A process cannot still be executing after relaunch. The request remains queued and
        // the per-section checkpoint ensures already-paid work is not repeated.
        for index in decoded.indices where decoded[index].status == .running {
            decoded[index].status = .queued
            decoded[index].progress = DeepResearchProgress(
                phase: .queued,
                message: String(localized: "Waiting to reconnect to the space"),
                wordsSoFar: decoded[index].progress?.wordsSoFar ?? 0
            )
        }
        jobs = decoded
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder.nodusQueue.encode(jobs) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtection])
    }
}

private extension JSONDecoder {
    static var nodusQueue: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var nodusQueue: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
