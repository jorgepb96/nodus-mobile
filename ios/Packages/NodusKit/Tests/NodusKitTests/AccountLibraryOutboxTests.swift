import Foundation
import Testing
@testable import NodusKit

@Suite("Account Library offline outbox")
struct AccountLibraryOutboxTests {
    private func makeOutbox() throws -> (AccountLibraryOutbox, URL) {
        let directory = try testDatabaseDirectory(prefix: "nodus-account-library-outbox")
        return (try AccountLibraryOutbox(accountId: "owner@example.test", directory: directory), directory)
    }

    @Test("immutable versions and typed commands survive reopening")
    func survivesReopening() async throws {
        let (outbox, directory) = try makeOutbox()
        let version = LibraryRecordVersion(
            recordId: "record-1",
            versionId: "version-1",
            hlc: "2026-08-22T10:00:00.000Z-000001-phone",
            deviceId: "phone",
            payload: ["title": .string("A portable library")]
        )
        #expect(try await outbox.enqueue(.record(version), title: "A portable library"))
        #expect(try await outbox.enqueue(.command(.init(
            id: "command-1",
            idempotencyKey: "import-record-1",
            kind: .import,
            payload: ["recordId": .string("record-1")]
        )), title: "Import"))

        let reopened = try AccountLibraryOutbox(accountId: "owner@example.test", directory: directory)
        let items = try await reopened.items()
        #expect(items.map(\.id) == ["version-1", "command-1"])
        #expect(try await reopened.pendingCount() == 2)
    }

    @Test("repeating an ID cannot create a second operation")
    func idempotentEnqueue() async throws {
        let (outbox, _) = try makeOutbox()
        let first = LibraryRecordVersion(
            recordId: "record-1",
            versionId: "stable-version",
            hlc: "001",
            payload: ["title": .string("first")]
        )
        let second = LibraryRecordVersion(
            recordId: "record-1",
            versionId: "stable-version",
            hlc: "002",
            payload: ["title": .string("must not overwrite")]
        )
        #expect(try await outbox.enqueue(.record(first), title: "First"))
        #expect(try await outbox.enqueue(.record(second), title: "Second") == false)
        let items = try await outbox.items()
        #expect(items.count == 1)
        #expect(items.first?.title == "First")
    }

    @Test("cancel and retry are explicit state transitions")
    func cancellationAndRetry() async throws {
        let (outbox, _) = try makeOutbox()
        let command = AccountLibraryOutbox.QueuedCommand(
            id: "command-1",
            idempotencyKey: "zotero-1",
            kind: .zoteroSync,
            payload: [:]
        )
        try await outbox.enqueue(.command(command), title: "Zotero")
        try await outbox.cancel(id: command.id)
        #expect(try await outbox.items().first?.state == .cancelled)
        try await outbox.retry(id: command.id)
        #expect(try await outbox.items().first?.state == .pending)
    }
}
