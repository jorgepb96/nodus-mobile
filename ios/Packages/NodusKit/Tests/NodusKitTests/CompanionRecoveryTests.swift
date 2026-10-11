import Foundation
import Testing
@testable import NodusKit

@Suite("Companion recovery and source downloads")
struct CompanionRecoveryTests {
    private let identity = "d4a7d1c3-5d55-41b8-8f01-2bd1c37dddef"
    private var work: JSONValue { .object(["source": .object(["kind": .string("matrix"), "authorId": .string("a"), "themeId": .string("t")]), "model": .object(["provider": .string("phone"), "model": .string("model")])]) }
    @Test("only a matching unfinished request resumes its paid result")
    func explicitAttemptPolicy() {
        let checkpoint: JSONValue = .object(["id": .string(identity), "request": work, "state": .string("saved"), "raw": .string("paid response")])
        #expect(CompanionGenerationRecovery.resumeAcademic(checkpoint: checkpoint, work: work, receiptState: "pending"))
        #expect(CompanionGenerationRecovery.resumeAcademic(checkpoint: checkpoint, work: work, receiptState: nil))
        for state in ["failed", "interrupted", "cancelled", "available"] {
            #expect(!CompanionGenerationRecovery.resumeAcademic(checkpoint: checkpoint, work: work, receiptState: state))
        }
        #expect(!CompanionGenerationRecovery.resumeAcademic(checkpoint: checkpoint, work: .null, receiptState: "pending"))
    }
    @Test("an unparseable paid response survives an explicit new attempt without becoming a job")
    func archiveBeforeRetry() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PrivateBridgeCache(pairingId: UUID().uuidString, directory: directory, keychain: KeychainStore(service: "nodus.recovery.\(UUID().uuidString)"))
        let ledger = try DesktopJobLedger(cache: cache, vaultId: "vault", data: nil)
        let checkpoint: JSONValue = .object(["id": .string(identity), "request": work, "raw": .string("unparseable but paid"), "state": .string("failed")])
        try await ledger.archiveAcademicCheckpoint(recordId: "record", checkpoint: checkpoint)
        let data = try await cache.data(vaultId: "vault", domain: .researchGeneration, recordId: "job-ledger-v1")
        let reopened = try DesktopJobLedger(cache: cache, vaultId: "vault", data: data)
        let saved = try #require(await reopened.all().first)
        #expect(saved.method == "localAcademicGeneration")
        #expect(saved.checkpoint?.objectValue?["raw"] == .string("unparseable but paid"))
        #expect(saved.state == "failed")
        #expect(!DesktopBridgeClient.jobMethods.contains(saved.method))
        try await reopened.archiveAcademicCheckpoint(recordId: "record", checkpoint: checkpoint)
        #expect(await reopened.all().count == 1)
    }
    private func map(statement: String = "statement", child: String = "outside-ai") -> JSONValue {
        .object(["generatedAt": .string("old"), "root": .object(["id": .string("random"), "ideaId": .string("seed"), "statement": .string(statement), "children": .array([
            .object(["id": .string("another-random"), "ideaId": .string(child), "children": .array([])])
        ])])])
    }
    @Test("map download epochs ignore presentation identities and retain every actual idea")
    func structuralCoverage() throws {
        let original = map()
        var changed = try #require(original.objectValue)
        changed["generatedAt"] = .string("new")
        var root = try #require(changed["root"]?.objectValue); root["id"] = .string("different")
        changed["root"] = .object(root)
        #expect(try CompanionArgumentDownload.semanticMap(original) == CompanionArgumentDownload.semanticMap(.object(changed)))
        #expect(try CompanionArgumentDownload.ideaIDs(original) == ["seed", "outside-ai"])
        #expect(try CompanionArgumentDownload.semanticMap(original) != CompanionArgumentDownload.semanticMap(map(statement: "updated")))
        #expect(try CompanionArgumentDownload.semanticMap(original) != CompanionArgumentDownload.semanticMap(map(child: "changed-neighbour")))
    }
}
