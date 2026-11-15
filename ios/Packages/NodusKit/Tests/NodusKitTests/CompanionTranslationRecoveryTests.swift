import Foundation
import Testing
@testable import NodusKit

struct CompanionTranslationRecoveryTests {
    private var request: JSONValue { .object(["entityKind": .string("deep_research"), "entityId": .string("report"),
        "language": .string("es"), "sourceTitle": .string("Real source"), "sourceMarkdown": .string("Full original Markdown"),
        "model": .object(["provider": .string("mac"), "model": .string("research")])]) }
    private func record(_ state: String, request value: JSONValue? = nil, result: JSONValue? = nil) -> DesktopJobLedger.Request {
        .init(id: "f8729c22-9fef-4e06-9c2d-2993c210c881", method: "generateContentTranslation", args: [value ?? request],
              createdAt: Date(), jobId: nil, state: state, issue: "Previous transport issue", result: result)
    }

    @Test func lostAcknowledgementAndReopeningReuseOriginalRequest() {
        for state in ["pending", "accepted", "running", "saved"] {
            let original = record(state)
            for explicit in [true, false] {
                guard case .resume(let resumed) = CompanionTranslationRecovery.decide(request: request, records: [original], savedTranslationId: nil, explicit: explicit) else {
                    Issue.record("A nonterminal request must resume rather than create paid work"); continue
                }
                #expect(resumed.id == original.id)
                #expect(resumed.args == [request])
            }
        }
    }

    @Test func completedResultMustBeRecoveredBeforeExplicitRegeneration() {
        let completed = record("available", result: .object(["id": .string("translation")]))
        for explicit in [true, false] {
            guard case .recover(let recovered) = CompanionTranslationRecovery.decide(request: request, records: [completed], savedTranslationId: nil, explicit: explicit) else {
                Issue.record("An unmaterialised completed translation must be recovered"); continue
            }
            #expect(recovered.result == completed.result)
        }
        guard case .create = CompanionTranslationRecovery.decide(request: request, records: [completed], savedTranslationId: "translation", explicit: true) else {
            Issue.record("A deliberate regeneration after materialising the saved result may create work"); return
        }
        guard case .recover = CompanionTranslationRecovery.decide(request: request, records: [completed], savedTranslationId: "translation", explicit: false) else {
            Issue.record("Reopening can never regenerate a completed translation"); return
        }
    }

    @Test func sourceLanguageModelAndReportChangesRequireNewExplicitIntent() {
        for (key, value) in [("sourceMarkdown", JSONValue.string("Changed Markdown")), ("language", .string("fr")),
                             ("entityId", .string("other-report")), ("sourceTitle", .string("Other title")),
                             ("model", .object(["provider": .string("mac"), "model": .string("other")]))] {
            var changed = request.objectValue!; changed[key] = value
            guard case .none = CompanionTranslationRecovery.decide(request: .object(changed), records: [record("running")], savedTranslationId: nil, explicit: false) else {
                Issue.record("Changed \(key) cannot resume the wrong request on reopening"); continue
            }
            guard case .create = CompanionTranslationRecovery.decide(request: .object(changed), records: [record("running")], savedTranslationId: nil, explicit: true) else {
                Issue.record("Changed \(key) needs its own explicitly requested generation"); continue
            }
        }
    }

    @Test func terminalFailuresRemainVisibleUntilExplicitRetry() {
        for state in ["failed", "interrupted", "cancelled"] {
            guard case .failed(let original) = CompanionTranslationRecovery.decide(request: request, records: [record(state)], savedTranslationId: nil, explicit: false) else {
                Issue.record("Reopening must retain terminal failures"); continue
            }
            #expect(original.issue == "Previous transport issue")
            guard case .create = CompanionTranslationRecovery.decide(request: request, records: [original], savedTranslationId: nil, explicit: true) else {
                Issue.record("A manual retry should use a new id after a terminal result"); continue
            }
        }
    }

    @Test func queuedDeletionCannotBeResurrectedByAutomaticRecovery() {
        let completed = record("available", result: .object(["id": .string("translation")]))
        guard case .none = CompanionTranslationRecovery.decide(request: request, records: [completed], savedTranslationId: nil, explicit: false, pendingDeletion: true) else {
            Issue.record("Automatic recovery must respect the durable delete tombstone"); return
        }
        guard case .create = CompanionTranslationRecovery.decide(request: request, records: [completed], savedTranslationId: nil, explicit: true, pendingDeletion: true) else {
            Issue.record("Translating again after deletion requires a new explicit request"); return
        }
    }

    @Test func encryptedLedgerRetainsLostAcknowledgementAndCompletedTranslationAcrossReopen() async throws {
        let pairing = UUID().uuidString, id = UUID().uuidString
        let directory = URL.temporaryDirectory.appendingPathComponent("nodus-translation-recovery-\(pairing)")
        let keychain = KeychainStore(service: "nodus.tests.translation.\(pairing)")
        defer {
            try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: pairing))
            try? FileManager.default.removeItem(at: directory)
        }
        let cache = try PrivateBridgeCache(pairingId: pairing, directory: directory, keychain: keychain)
        let original = try DesktopJobLedger(cache: cache, vaultId: "vault", data: nil)
        _ = try await original.prepare(id: id, method: "generateContentTranslation", args: [request])
        try await original.disconnected(id: id, issue: "Lost acknowledgement")
        let persisted = try await cache.data(vaultId: "vault", domain: .researchGeneration, recordId: "job-ledger-v1")
        let reopened = try DesktopJobLedger(cache: cache, vaultId: "vault", data: persisted)
        guard case .resume(let retained) = CompanionTranslationRecovery.decide(request: request, records: await reopened.all(), savedTranslationId: nil, explicit: true) else {
            Issue.record("Reopening after a lost acknowledgement must recover the durable request"); return
        }
        #expect(retained.id == id)
        #expect(retained.issue == "Lost acknowledgement")
        try await reopened.update(id: id, job: .init(id: "mac-job", vaultId: "vault", method: "generateContentTranslation",
            state: .available, nextSequence: 0, events: [], result: .object(["id": .string("saved-translation")]), error: nil))
        let completed = try await cache.data(vaultId: "vault", domain: .researchGeneration, recordId: "job-ledger-v1")
        let finished = try DesktopJobLedger(cache: cache, vaultId: "vault", data: completed)
        guard case .recover(let result) = CompanionTranslationRecovery.decide(request: request, records: await finished.all(), savedTranslationId: nil, explicit: true) else {
            Issue.record("An acknowledged result must be retrieved without another provider submission"); return
        }
        #expect(result.id == id)
        #expect(result.result?.objectValue?["id"] == .string("saved-translation"))
        #expect(await finished.all().count == 1)
    }
}
