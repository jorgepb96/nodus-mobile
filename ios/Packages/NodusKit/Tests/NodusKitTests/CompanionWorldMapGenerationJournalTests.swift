import Foundation
import Testing
@testable import NodusKit

@Suite("Durable device map provider work") struct CompanionWorldMapGenerationJournalTests {
    private func accepted(model: String = "gemini-image", revision: String = String(repeating: "a", count: 64)) throws -> CompanionWorldMapGenerationCheckpoint {
        try .init(.object(["version":.int(1),"id":.string(UUID().uuidString),"request":.object(["mapId":.string("map"),"mode":.string("create"),"style":.string("parchment"),"extra":.string("a river")]),"revision":.string(revision),"model":.object(["provider":.string("gemini"),"model":.string(model)]),"state":.string("accepted"),"createdAt":.string(ISO8601DateFormatter().string(from: Date()))]))
    }
    @Test("Accepted and running intents cannot become incomplete publication jobs") func partial() throws {
        let first = try accepted(), running = try first.changing(state: .running)
        #expect(first.publication == nil); #expect(running.publication == nil)
        #expect(throws: DesktopBridgeError.self) { try first.changing(state: .saved) }
        #expect(try first.scope != accepted(model: "other").scope)
        #expect(try first.scope != accepted(revision: String(repeating: "b", count: 64)).scope)
    }
    @Test("A failed or cancelled new step retains an already received paid image") func retainedImage() throws {
        let first = try accepted(), image = Data("paid image result".utf8)
        let saved = try first.changing(state: .saved, bytes: image, mime: "image/png")
        #expect(saved.publication?.objectValue?["requestId"] == .string(first.id))
        for state in [CompanionWorldMapGenerationCheckpoint.State.failed,.cancelled,.interrupted] {
            let next = try saved.changing(state: state, error: "Transport stopped")
            #expect(next.publication == saved.publication)
        }
    }
    @Test("The encrypted journal reopens running intent then exact image without a Mac") func reopen() async throws {
        let pairing = UUID().uuidString
        let directory = URL.temporaryDirectory.appendingPathComponent("nodus-map-journal-\(pairing)")
        let keychain = KeychainStore(service: "nodus.tests.map.journal.\(pairing)")
        defer { try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: pairing)); try? FileManager.default.removeItem(at: directory) }
        let cache = try PrivateBridgeCache(pairingId: pairing, directory: directory, keychain: keychain)
        let journal = try await CompanionWorldMapGenerationJournal(cache: cache, vault: "vault")
        let first = try accepted(), running = try first.changing(state: .running)
        try await journal.put(first); try await journal.put(running)
        let reopened = try await CompanionWorldMapGenerationJournal(cache: cache, vault: "vault")
        #expect(try await reopened.load(scope: first.scope)?.state == .running)
        #expect(try await reopened.load(scope: first.scope)?.id == first.id)
        let saved = try running.changing(state: .saved, bytes: Data("exact downloaded-source result".utf8), mime: "image/png")
        try await reopened.put(saved)
        let finished = try await CompanionWorldMapGenerationJournal(cache: cache, vault: "vault")
        #expect(try await finished.load(scope: first.scope)?.publication == saved.publication)
        #expect(await finished.summaries().first?.objectValue?["bytes"] == nil)
        #expect(await finished.summaries().count == 1)
        let otherVault = try await CompanionWorldMapGenerationJournal(cache: cache, vault: "other-vault")
        #expect(try await otherVault.load(scope: first.scope) == nil)
    }
    private actor ProviderGate {
        var calls = 0
        var continuation: CheckedContinuation<(data: Data, mime: String), Never>?
        func draw() async -> (data: Data, mime: String) {
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        func started() -> Bool { continuation != nil }
        func count() -> Int { calls }
        func finish() { continuation?.resume(returning: (Data("paid result after observer closes".utf8),"image/png")); continuation = nil }
    }
    private func started(_ gate: ProviderGate) async throws {
        for _ in 0..<1000 { if await gate.started() { return }; try await Task.sleep(for: .milliseconds(1)) }
        throw APIError(status: 408, code: "fixture_timeout", message: "Provider gate did not start")
    }
    @Test("Closing an observer and reopening the same scope shares one paid provider call") func observerDoesNotCancelProvider() async throws {
        let pairing = UUID().uuidString, directory = URL.temporaryDirectory.appendingPathComponent("nodus-map-provider-\(pairing)")
        let keychain = KeychainStore(service: "nodus.tests.map.provider.\(pairing)")
        defer { try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: pairing)); try? FileManager.default.removeItem(at: directory) }
        let cache = try PrivateBridgeCache(pairingId: pairing, directory: directory, keychain: keychain)
        let journal = try await CompanionWorldMapGenerationJournal(cache: cache, vault: "vault")
        let intent = try accepted(), gate = ProviderGate()
        let first = Task { try await journal.perform(accepted: intent) { await gate.draw() } }
        try await started(gate)
        #expect(try await journal.load(scope: intent.scope)?.state == .running)
        first.cancel() // Exactly a dismissed sheet's observer, not cancel(scope:).
        let second = try #require(await journal.observer(scope: intent.scope))
        await gate.finish()
        let result = try await first.value, reopenedResult = try await second.value
        #expect(result.id == intent.id); #expect(reopenedResult.id == intent.id)
        #expect(await gate.count() == 1)
        let afterRestart = try await CompanionWorldMapGenerationJournal(cache: cache, vault: "vault")
        #expect(try await afterRestart.load(scope: intent.scope)?.publication == result.publication)
    }
    @Test("Explicit cancellation retains a late provider image without making a publication") func explicitCancellation() async throws {
        let pairing = UUID().uuidString, directory = URL.temporaryDirectory.appendingPathComponent("nodus-map-cancel-\(pairing)")
        let keychain = KeychainStore(service: "nodus.tests.map.cancel.\(pairing)")
        defer { try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: pairing)); try? FileManager.default.removeItem(at: directory) }
        let cache = try PrivateBridgeCache(pairingId: pairing, directory: directory, keychain: keychain)
        let journal = try await CompanionWorldMapGenerationJournal(cache: cache, vault: "vault")
        let intent = try accepted(), gate = ProviderGate()
        let task = Task { try await journal.perform(accepted: intent) { await gate.draw() } }
        try await started(gate); await journal.cancel(scope: intent.scope); await gate.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
        let saved = try #require(try await journal.load(scope: intent.scope))
        #expect(saved.state == .cancelled)
        #expect(saved.publication?.objectValue?["bytes"] != nil)
        #expect(await gate.count() == 1)
    }

}
