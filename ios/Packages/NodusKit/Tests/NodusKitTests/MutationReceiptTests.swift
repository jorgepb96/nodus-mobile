import Foundation
import Testing
@testable import NodusKit

@Suite("Canonical mutation receipts")
struct MutationReceiptTests {
    private func note(_ id: String, title: String = "Nota") -> Mutation {
        Mutation(id: id, clientId: "device", kind: .upsert, table: .notes, key: [id],
                 row: ["id": .string(id), "title": .string(title)], schemaVersion: 245,
                 createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func receipt(_ json: String) throws -> MutationReceipt {
        try JSONDecoder.nodus.decode(MutationReceipt.self, from: Data(json.utf8))
    }

    private func queue() throws -> (MutationOutbox, URL) {
        let directory = try testDatabaseDirectory(prefix: "nodus-canonical-receipt")
        return (try MutationOutbox(spaceId: "vault", directory: directory), directory)
    }

    @Test("a live canonical write is durable and duplicate receipts announce no second delivery")
    func appliedAndReopened() async throws {
        let (outbox, directory) = try queue(), mutation = note("n-1")
        try await outbox.enqueue(mutation, title: "Nota")
        try await outbox.authorise(ids: [mutation.id])
        let applied = try receipt(#"{"accepted":["n-1"],"duplicate":[],"rejected":[],"applied":["n-1"],"cursor":null}"#)
        #expect(try await outbox.recordReceipt(applied, for: [mutation]).map(\.id) == ["n-1"])
        let reopened = try MutationOutbox(spaceId: "vault", directory: directory)
        #expect(try await reopened.items().first?.state == .delivered)
        #expect(try await reopened.items().first?.deliveredAt != nil)
        let duplicate = try receipt(#"{"accepted":[],"duplicate":["n-1"],"rejected":[],"applied":["n-1"]}"#)
        #expect(try await reopened.recordReceipt(duplicate, for: [mutation]).isEmpty)
        #expect(try await reopened.items().first?.state == .delivered)
    }

    @Test("legacy acceptance remains pending delivery until an explicit application receipt")
    func legacyRecovery() async throws {
        let (outbox, _) = try queue(), mutation = note("n-1")
        try await outbox.enqueue(mutation, title: "Nota")
        try await outbox.authorise(ids: [mutation.id])
        let legacy = try receipt(#"{"accepted":["n-1"],"duplicate":[],"rejected":[],"cursor":null}"#)
        #expect(try await outbox.recordReceipt(legacy, for: [mutation]).isEmpty)
        #expect(try await outbox.items().first?.state == .accepted)
        #expect(try await outbox.markDelivered(upTo: Int.max).isEmpty)
        #expect(try await outbox.acceptedWithoutCursor() == [mutation])
        let confirmed = try receipt(#"{"accepted":[],"duplicate":["n-1"],"rejected":[],"applied":["n-1"]}"#)
        #expect(try await outbox.recordReceipt(confirmed, for: [mutation]).count == 1)
        #expect(try await outbox.acceptedWithoutCursor().isEmpty)
    }

    @Test("mixed outcomes apply only confirmed IDs and retain rejected and unsent changes")
    func mixedBatch() async throws {
        let (outbox, _) = try queue()
        let submitted = [note("applied"), note("relay"), note("refused")], unsent = note("draft")
        for mutation in submitted + [unsent] { try await outbox.enqueue(mutation, title: mutation.id) }
        try await outbox.authorise(ids: submitted.map(\.id))
        let mixed = try receipt(#"{"accepted":["applied","relay"],"duplicate":[],"rejected":[{"id":"refused","reason":"constraint","error_description":"Conflicto real"}],"applied":["applied"],"cursor":7}"#)
        #expect(try await outbox.recordReceipt(mixed, for: submitted).map(\.id) == ["applied"])
        let items = try await outbox.items(), states = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.state) })
        #expect(states == ["applied": .delivered, "relay": .accepted, "refused": .rejected, "draft": .pending])
        #expect(items.first(where: { $0.id == "refused" })?.detail == "Conflicto real")
        #expect(try await outbox.markDelivered(upTo: 6).isEmpty)
        #expect(try await outbox.markDelivered(upTo: 7).map(\.id) == ["relay"])
    }

    @Test("malformed receipts cannot move any item, including another draft or a rejected ID")
    func invalidScope() async throws {
        let (outbox, _) = try queue(), mutation = note("n-1")
        try await outbox.enqueue(mutation, title: "Nota")
        try await outbox.authorise(ids: [mutation.id])
        for json in [
            #"{"accepted":["other"],"duplicate":[],"rejected":[],"applied":["other"]}"#,
            #"{"accepted":["n-1"],"duplicate":["n-1"],"rejected":[]}"#,
            #"{"accepted":[],"duplicate":[],"rejected":[{"id":"n-1","reason":"constraint"}],"applied":["n-1"]}"#,
            #"{"accepted":["n-1"],"duplicate":[],"rejected":[],"applied":["n-1","n-1"]}"#,
            #"{"accepted":[],"duplicate":[],"rejected":[]}"#,
            #"{"accepted":["n-1"],"duplicate":[],"rejected":[],"cursor":-1}"#
        ] {
            let malformed = try receipt(json)
            await #expect(throws: TransportError.self) { try await outbox.recordReceipt(malformed, for: [mutation]) }
            #expect(try await outbox.items().first?.state == .pending)
        }
        await #expect(throws: TransportError.self) {
            try await outbox.recordReceipt(try receipt(#"{"accepted":["n-1"],"duplicate":[],"rejected":[]}"#), for: [mutation, mutation])
        }
    }

    @Test("a late receipt cannot confirm an unauthorised or edited replacement payload")
    func lateReceipt() async throws {
        let (outbox, _) = try queue(), old = note("n-1"), replacement = note("n-1", title: "Nueva edición")
        let applied = try receipt(#"{"accepted":["n-1"],"duplicate":[],"rejected":[],"applied":["n-1"]}"#)
        try await outbox.enqueue(old, title: "Nota")
        await #expect(throws: TransportError.self) { try await outbox.recordReceipt(applied, for: [old]) }
        try await outbox.authorise(ids: [old.id])
        try await outbox.enqueue(replacement, title: "Nueva edición")
        try await outbox.authorise(ids: [replacement.id])
        await #expect(throws: TransportError.self) { try await outbox.recordReceipt(applied, for: [old]) }
        #expect(try await outbox.pending(limit: 10) == [replacement])
    }
}
