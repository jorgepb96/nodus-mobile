import Foundation
import Testing
@testable import NodusKit

struct GenerationActionIntentStoreTests {
    @Test func lostAcknowledgementReusesIntentAndExplicitCompletedRegenerationGetsFreshKey() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = try GenerationActionIntentStore.scope(kind: .authorSynthesisGenerate,
            payload: ["authorId": .string("private-author")], revision: "revision", mode: "live")
        let first = try GenerationActionIntentStore(directory: directory)
        let key = try await first.prepare(scope: scope)
        let reopened = try GenerationActionIntentStore(directory: directory)
        #expect(try await reopened.prepare(scope: scope) == key)
        try await reopened.acknowledge(scope: scope, key: key, terminal: false)
        #expect(try await reopened.prepare(scope: scope) == key)
        try await reopened.acknowledge(scope: scope, key: "another-request", terminal: true)
        #expect(try await reopened.prepare(scope: scope) == key)
        try await reopened.acknowledge(scope: scope, key: key, terminal: true)
        let finished = try GenerationActionIntentStore(directory: directory)
        #expect(try await finished.prepare(scope: scope) != key)
        let stored = try String(contentsOf: directory.appendingPathComponent("generation-action-intents.json"), encoding: .utf8)
        #expect(!stored.contains("private-author"), "Only hashed scopes and opaque keys are persisted")
    }

    @Test func sourceRevisionModelCellAndExecutionModeCannotResumeWrongGeneration() throws {
        let payload: [String: JSONValue] = ["authorId": .string("a"), "themeId": .string("t"), "model": .object(["provider": .string("mac"), "model": .string("first")])]
        let first = try GenerationActionIntentStore.scope(kind: .authorsMatrixGenerate, payload: payload, revision: "r", mode: "live")
        var changedModel = payload; changedModel["model"] = .object(["provider": .string("mac"), "model": .string("other")])
        var changedCell = payload; changedCell["themeId"] = .string("other")
        #expect(try GenerationActionIntentStore.scope(kind: .authorsMatrixGenerate, payload: changedModel, revision: "r", mode: "live") != first)
        #expect(try GenerationActionIntentStore.scope(kind: .authorsMatrixGenerate, payload: changedCell, revision: "r", mode: "live") != first)
        #expect(try GenerationActionIntentStore.scope(kind: .authorsMatrixGenerate, payload: payload, revision: "new", mode: "live") != first)
        #expect(try GenerationActionIntentStore.scope(kind: .authorsMatrixGenerate, payload: payload, revision: "r", mode: "autonomous") != first)
    }

    @Test func concurrentEntitiesAndMigratedPendingLedgerKeysSurviveReopen() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GenerationActionIntentStore(directory: directory)
        async let first = store.prepare(scope: "scope-a", preferredKey: "ios:legacy:pending")
        async let second = store.prepare(scope: "scope-b")
        let keys = try await (first, second)
        let reopened = try GenerationActionIntentStore(directory: directory)
        #expect(try await reopened.prepare(scope: "scope-a") == keys.0)
        #expect(try await reopened.prepare(scope: "scope-b") == keys.1)
        #expect(keys.0 != keys.1)
    }

    @Test func corruptJournalIsErrorRatherThanNewPaidIntent() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("generation-action-intents.json")
        try Data("damaged journal".utf8).write(to: file)
        #expect(throws: (any Error).self) { try GenerationActionIntentStore(directory: directory) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "damaged journal")
    }
}
