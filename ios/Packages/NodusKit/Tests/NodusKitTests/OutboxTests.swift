import Foundation
import Testing
@testable import NodusKit

/// The queue, and the one distinction the background flush rests on.
///
/// The Writing screen promises that a change travels when the user presses send. A background
/// task exists to finish a send the network cut short — not to start one. That difference is
/// the `authorised` flag, and everything here tests it, because getting it wrong would mean a
/// note written on a plane leaving the device without anybody asking.
@Suite("Mutation outbox authorisation")
struct MutationOutboxAuthorisationTests {
    private func makeOutbox(directory: URL? = nil) throws -> (MutationOutbox, URL) {
        let folder = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("nodus-outbox-\(UUID().uuidString)")
        return (try MutationOutbox(spaceId: "space-under-test", directory: folder), folder)
    }

    private func note(_ id: String, title: String = "Una nota") -> Mutation {
        Mutation(
            id: id,
            clientId: "client-1",
            kind: .upsert,
            table: .notes,
            key: [id],
            row: ["id": .string(id), "title": .string(title), "content": .string("Cuerpo")],
            schemaVersion: 245
        )
    }

    @Test("a queued change waits behind the send button")
    func queuedChangesAreNotAuthorised() async throws {
        let (outbox, _) = try makeOutbox()
        try await outbox.enqueue(note("n-1"), title: "Una nota")
        try await outbox.enqueue(note("n-2"), title: "Otra nota")

        #expect(try await outbox.pending(limit: 10).count == 2)
        #expect(try await outbox.authorisedCount() == 0)
        #expect(try await outbox.authorisedPending(limit: 10).isEmpty,
                "nothing may travel on its own before the user has pressed send")
    }

    @Test("pressing send authorises what is pending, and nothing else")
    func authorisingCoversPendingOnly() async throws {
        let (outbox, _) = try makeOutbox()
        try await outbox.enqueue(note("n-1"), title: "Primera")
        try await outbox.enqueue(note("n-2"), title: "Segunda")
        try await outbox.enqueue(note("n-3"), title: "Tercera")
        try await outbox.markAccepted(["n-3"])

        let covered = try await outbox.authorisePending()
        #expect(covered == 2, "the accepted change is already gone; authorising it would mean nothing")
        #expect(try await outbox.authorisedCount() == 2)
        #expect(Set(try await outbox.authorisedPending(limit: 10).map(\.id)) == ["n-1", "n-2"])
    }

    @Test("editing an authorised change puts it back behind the button")
    func reEnqueueingRevokesAuthorisation() async throws {
        let (outbox, _) = try makeOutbox()
        try await outbox.enqueue(note("n-1", title: "Primer intento"), title: "Primer intento")
        try await outbox.authorisePending()
        #expect(try await outbox.authorisedCount() == 1)

        // Same id, new content: this is the user changing their mind, not the queue retrying.
        try await outbox.enqueue(note("n-1", title: "Segundo intento"), title: "Segundo intento")
        #expect(try await outbox.authorisedCount() == 0)
        #expect(try await outbox.pending(limit: 10).count == 1)
    }

    @Test("accepting a change takes it out of what the background flush would send")
    func acceptedChangesLeaveTheQueue() async throws {
        let (outbox, _) = try makeOutbox()
        try await outbox.enqueue(note("n-1"), title: "Una nota")
        try await outbox.authorisePending()
        try await outbox.markAccepted(["n-1"])

        #expect(try await outbox.authorisedCount() == 0)
        #expect(try await outbox.authorisedPending(limit: 10).isEmpty)
        let counts = try await outbox.counts()
        #expect(counts.accepted == 1)
        #expect(counts.pending == 0)
    }

    // The column was added after the queue already existed on devices, so the migration is an
    // ALTER guarded by a column check. Reopening the same database is what would break if the
    // guard were wrong, and it is the exact thing every launch does.
    @Test("reopening a queue that already exists runs the migration again without complaint")
    func migrationIsIdempotent() async throws {
        let (first, folder) = try makeOutbox()
        try await first.enqueue(note("n-1"), title: "Una nota")
        try await first.authorisePending()

        let (second, _) = try makeOutbox(directory: folder)
        #expect(try await second.authorisedCount() == 1)
        #expect(try await second.authorisedPending(limit: 10).map(\.id) == ["n-1"])
    }

    // The whole reason `authorise(ids:)` exists. Sending a report is an act on one document, and
    // a control on that document must not release a note the user chose to keep.
    @Test("authorising by name leaves everything else waiting")
    func authorisingByNameIsScoped() async throws {
        let (outbox, _) = try makeOutbox()
        try await outbox.enqueue(note("n-1"), title: "Una nota que se queda")
        try await outbox.enqueue(note("r-1"), title: "Un informe que se envía")

        let covered = try await outbox.authorise(ids: ["r-1"])
        #expect(covered == 1)
        #expect(try await outbox.authorisedPending(limit: 10).map(\.id) == ["r-1"])
        #expect(try await outbox.authorisedCount() == 1,
                "the note the user did not press send on must still be waiting")
    }

    @Test("authorising a change that already left covers nothing")
    func authorisingByNameSkipsAccepted() async throws {
        let (outbox, _) = try makeOutbox()
        try await outbox.enqueue(note("n-1"), title: "Una nota")
        try await outbox.markAccepted(["n-1"])

        #expect(try await outbox.authorise(ids: ["n-1"]) == 0)
        #expect(try await outbox.authorise(ids: []) == 0)
        #expect(try await outbox.authorisedCount() == 0)
    }

    // A tray that shows every vault has to ask every space whether it has a queue. Asking must
    // not be the thing that gives it one.
    @Test("asking whether a queue exists does not create it")
    func existsDoesNotCreateTheDatabase() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodus-outbox-\(UUID().uuidString)")

        #expect(MutationOutbox.exists(spaceId: "space-under-test", directory: folder) == false)
        #expect(FileManager.default.fileExists(atPath: folder.path) == false,
                "the probe must not bring the folder into being either")

        let (outbox, _) = try makeOutbox(directory: folder)
        try await outbox.enqueue(note("n-1"), title: "Una nota")
        #expect(MutationOutbox.exists(spaceId: "space-under-test", directory: folder))
        #expect(MutationOutbox.exists(spaceId: "another-space", directory: folder) == false)
    }
}
