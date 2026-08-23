import Foundation
import NodusAI
import Testing
@testable import Nodus

@Suite("Deep Research queue")
@MainActor
struct DeepResearchQueueTests {
    @Test("jobs run sequentially and keep their stable report ids")
    func sequentialExecution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DeepResearchQueue(root: root)
        var events: [String] = []

        queue.enqueue(id: "job-1", spaceId: "a", spaceName: "Alpha", request: request("First report")) {
            events.append("start-1")
            try await Task.sleep(for: .milliseconds(40))
            events.append("end-1")
            return DeepResearchQueueResult(savedReportId: "job-1", publicationNote: "local")
        }
        queue.enqueue(id: "job-2", spaceId: "b", spaceName: "Beta", request: request("Second report")) {
            events.append("start-2")
            events.append("end-2")
            return DeepResearchQueueResult(savedReportId: "job-2", publicationNote: "vault")
        }

        await waitUntil { queue.jobs.allSatisfy(\.status.isFinished) }
        #expect(events == ["start-1", "end-1", "start-2", "end-2"])
        #expect(queue.jobs.map(\.status) == [.completed, .completed])
        #expect(queue.jobs.map(\.savedReportId) == ["job-1", "job-2"])
    }

    @Test("relaunch turns interrupted work back into queued work")
    func relaunchRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DeepResearchQueue(root: root)

        queue.enqueue(id: "running", spaceId: "a", spaceName: "Alpha", request: request("Interrupted report")) {
            try await Task.sleep(for: .seconds(5))
            return DeepResearchQueueResult(savedReportId: "running", publicationNote: "local")
        }
        queue.enqueue(id: "waiting", spaceId: "b", spaceName: "Beta", request: request("Waiting report")) {
            DeepResearchQueueResult(savedReportId: "waiting", publicationNote: "local")
        }

        #expect(queue.jobs.map(\.status) == [.running, .queued])
        let restored = DeepResearchQueue(root: root)
        #expect(restored.jobs.map(\.status) == [.queued, .queued])
        #expect(restored.jobs.map(\.id) == ["running", "waiting"])
        queue.cancel("running")
    }

    @Test("a queued cancellation never invokes its executor")
    func queuedCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DeepResearchQueue(root: root)
        var secondRan = false

        queue.enqueue(id: "blocker", spaceId: "a", spaceName: "Alpha", request: request("Running report")) {
            try await Task.sleep(for: .seconds(5))
            return DeepResearchQueueResult(savedReportId: "blocker", publicationNote: "local")
        }
        queue.enqueue(id: "cancel-me", spaceId: "a", spaceName: "Alpha", request: request("Queued report")) {
            secondRan = true
            return DeepResearchQueueResult(savedReportId: "cancel-me", publicationNote: "local")
        }

        queue.cancel("cancel-me")
        #expect(queue.jobs.last?.status == .cancelled)
        #expect(!secondRan)
        queue.cancel("blocker")
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 where !predicate() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func request(_ objective: String) -> DeepResearchRequest {
        DeepResearchRequest(objective: objective, model: ModelRef(provider: .openai, model: "test-model"))
    }
}
