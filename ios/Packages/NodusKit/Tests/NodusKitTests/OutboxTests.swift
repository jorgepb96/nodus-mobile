import Foundation
import GRDB
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

/// The fourth state: a change the owner's desktop has actually collected.
///
/// `accepted` means the server is holding it, which is the answer to a question nobody asked —
/// what the author wants to know is whether it reached the vault. The server publishes how far
/// the owner has acknowledged, the receipt says where the change landed, and the whole feature
/// is the comparison of those two numbers. Everything here is about being wrong in the safe
/// direction when either number is missing.
@Suite("Mutation outbox delivery")
struct MutationOutboxDeliveryTests {
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

    /// The shape `ReportDraft` writes on the phone, down to the one value the corpus route
    /// filters a Deep Research report on.
    private func report(_ id: String, objective: String = "Un informe") -> Mutation {
        Mutation(
            id: id,
            clientId: "client-1",
            kind: .upsert,
            table: .writingSavedDrafts,
            key: [id],
            row: [
                "id": .string(id),
                "title": .string(objective),
                "brief_json": .string(#"{"kind":"deep_research","objective":"\#(objective)"}"#),
                "draft_json": .string("{}"),
            ],
            schemaVersion: 245
        )
    }

    @Test("a change becomes delivered when the owner's cursor passes the one its receipt gave")
    func cursorPassingMarksDelivered() async throws {
        let (outbox, _) = try makeOutbox()
        try await outbox.enqueue(note("n-1"), title: "Primera")
        try await outbox.enqueue(note("n-2"), title: "Segunda")
        try await outbox.markAccepted(["n-1"], cursor: 7)
        try await outbox.markAccepted(["n-2"], cursor: 9)

        // The owner has collected as far as 7. The second change is still in the ledger.
        let landed = try await outbox.markDelivered(upTo: 7)
        #expect(landed.map(\.id) == ["n-1"])
        #expect(landed.first?.state == .delivered)
        #expect(landed.first?.deliveredAt != nil)

        var counts = try await outbox.counts()
        #expect(counts.delivered == 1)
        #expect(counts.accepted == 1)

        try await outbox.markDelivered(upTo: 12)
        counts = try await outbox.counts()
        #expect(counts.delivered == 2)
        #expect(counts.accepted == 0)
    }

    // Said twice is worse than not said at all: this is what a notification is raised from, and
    // a foreground check follows a background one on every single launch.
    @Test("a delivery is reported once, on the pass that discovers it")
    func deliveryIsAnnouncedOnlyOnce() async throws {
        let (outbox, _) = try makeOutbox()
        try await outbox.enqueue(note("n-1"), title: "Una nota")
        try await outbox.markAccepted(["n-1"], cursor: 3)

        #expect(try await outbox.markDelivered(upTo: 5).count == 1)
        #expect(try await outbox.markDelivered(upTo: 5).isEmpty)
        #expect(try await outbox.markDelivered(upTo: 900).isEmpty)
    }

    // The decision the whole feature rests on. A server that publishes no cursor gives receipts
    // with none either, and inventing one — most temptingly zero — would report every queued
    // change delivered the moment it was sent.
    @Test("a change sent to a server that publishes no cursor stays on the server")
    func withoutACursorNothingIsEverDelivered() async throws {
        let (outbox, _) = try makeOutbox()
        try await outbox.enqueue(note("n-1"), title: "Una nota")
        try await outbox.markAccepted(["n-1"], cursor: nil)

        #expect(try await outbox.awaitingDelivery() == 0, "there is nothing here to compare")
        #expect(try await outbox.markDelivered(upTo: Int.max).isEmpty)
        let counts = try await outbox.counts()
        #expect(counts.accepted == 1)
        #expect(counts.delivered == 0)
    }

    @Test("only changes the server acknowledged are waiting on the owner")
    func awaitingDeliveryCountsTheLedgerOnly() async throws {
        let (outbox, _) = try makeOutbox()
        try await outbox.enqueue(note("n-1"), title: "Sin enviar")
        try await outbox.enqueue(note("n-2"), title: "En el ledger")
        try await outbox.enqueue(note("n-3"), title: "Rechazada")
        try await outbox.markAccepted(["n-2"], cursor: 4)
        try await outbox.markRejected([(id: "n-3", reason: "constraint", detail: nil)])

        #expect(try await outbox.awaitingDelivery() == 1)
        try await outbox.markDelivered(upTo: 4)
        #expect(try await outbox.awaitingDelivery() == 0, "a delivered change is no longer waiting")
    }

    // Re-sending a report reuses its row id so the desktop updates its copy instead of keeping
    // two. The queue row is replaced with it, and a cursor inherited from the previous send
    // would call the new attempt delivered before it had gone anywhere.
    @Test("re-queueing an id that had already landed forgets where it landed")
    func reEnqueueingClearsTheCursor() async throws {
        let (outbox, _) = try makeOutbox()
        try await outbox.enqueue(note("n-1", title: "Primer intento"), title: "Primer intento")
        try await outbox.markAccepted(["n-1"], cursor: 2)
        try await outbox.markDelivered(upTo: 2)
        #expect(try await outbox.counts().delivered == 1)

        try await outbox.enqueue(note("n-1", title: "Segundo intento"), title: "Segundo intento")
        let counts = try await outbox.counts()
        #expect(counts.pending == 1)
        #expect(counts.delivered == 0)
        #expect(try await outbox.markDelivered(upTo: 2).isEmpty, "it has not been sent again yet")
    }

    // What decides whether a delivery is worth a notification. A three-word note is not; twenty
    // minutes of Deep Research is.
    @Test("a report says what kind of thing it is and a note does not")
    func reportsCarryTheirKind() async throws {
        let (outbox, _) = try makeOutbox()
        try await outbox.enqueue(report("r-1", objective: "El comercio atlántico"), title: "El comercio atlántico")
        try await outbox.enqueue(note("n-1"), title: "Una nota")
        try await outbox.markAccepted(["r-1", "n-1"], cursor: 5)

        let landed = try await outbox.markDelivered(upTo: 5)
        #expect(landed.first(where: { $0.id == "r-1" })?.entityKind == "deep_research")
        #expect(landed.first(where: { $0.id == "n-1" })?.entityKind == nil)
    }

    @Test("a delivered change is swept only once it has had time to be seen")
    func purgingSparesRecentDeliveries() async throws {
        let (outbox, _) = try makeOutbox()
        try await outbox.enqueue(note("n-1"), title: "Una nota")
        try await outbox.markAccepted(["n-1"], cursor: 1)
        try await outbox.markDelivered(upTo: 1)

        #expect(try await outbox.purgeDelivered(deliveredBefore: Date().addingTimeInterval(-3600)) == 0)
        #expect(try await outbox.counts().delivered == 1)

        #expect(try await outbox.purgeDelivered(deliveredBefore: Date().addingTimeInterval(3600)) == 1)
        #expect(try await outbox.items().isEmpty)
    }

    /// A queue in the shape the last release left on somebody's phone: no `cursor`, no
    /// `delivered_at`, no `entity_kind`, and rows in all three states it knew about.
    private func writeQueueFromTheLastRelease(at folder: URL) throws {
        let spaceFolder = folder.appendingPathComponent("space-under-test", isDirectory: true)
        try FileManager.default.createDirectory(at: spaceFolder, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: spaceFolder.appendingPathComponent("outbox.sqlite").path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE outbox (
                    id TEXT PRIMARY KEY,
                    tbl TEXT NOT NULL,
                    title TEXT NOT NULL,
                    state TEXT NOT NULL,
                    detail TEXT,
                    payload TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    sent_at TEXT
                );
                CREATE INDEX outbox_state ON outbox (state, created_at);
                ALTER TABLE outbox ADD COLUMN authorised INTEGER NOT NULL DEFAULT 0;
                """)
            for (id, state, authorised) in [("n-1", "pending", 1), ("n-2", "accepted", 1), ("n-3", "rejected", 0)] {
                let payload = try JSONEncoder.nodus.encode(note(id))
                try db.execute(sql: """
                    INSERT INTO outbox (id, tbl, title, state, detail, payload, created_at, sent_at, authorised)
                    VALUES (?, 'notes', ?, ?, NULL, ?, '2026-01-01T10:00:00.000Z', NULL, ?)
                    """, arguments: [id, "Nota \(id)", state, String(data: payload, encoding: .utf8), authorised])
            }
        }
    }

    @Test("a queue from the last release opens with everything in it")
    func migratingAnExistingQueueLosesNothing() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodus-outbox-\(UUID().uuidString)")
        try writeQueueFromTheLastRelease(at: folder)

        let (outbox, _) = try makeOutbox(directory: folder)
        let counts = try await outbox.counts()
        #expect(counts.pending == 1)
        #expect(counts.accepted == 1)
        #expect(counts.rejected == 1)
        #expect(counts.delivered == 0)
        #expect(try await outbox.items().count == 3)
        // The flag the background flush rests on survived the ALTERs.
        #expect(try await outbox.authorisedPending(limit: 10).map(\.id) == ["n-1"])

        // And the change that was already in the ledger stays there: it was sent before the app
        // recorded where it landed, so nothing can say whether the owner has collected it.
        #expect(try await outbox.awaitingDelivery() == 0)
        #expect(try await outbox.markDelivered(upTo: Int.max).isEmpty)
    }
}
