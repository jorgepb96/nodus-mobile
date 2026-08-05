import Foundation
import NodusKit
import Observation

/// Everything this device has queued, in every vault, in one list.
///
/// The queue used to be a screen inside a space, which meant a change was only visible from the
/// space it belonged to — and to see whether anything at all was waiting you had to open each
/// vault in turn and look. That is the wrong shape for a thing whose whole job is to answer
/// "has my work left this phone yet?". The queue is a property of the device, not of a vault.
///
/// Each entry keeps the connection it came from rather than a copy of its name, because the
/// connection is also where the colour lives: `Connection.accent` is computed from the vault
/// type and needs no session, no network and no snapshot.
@Observable
@MainActor
final class GlobalOutbox {
    struct Entry: Identifiable, Hashable {
        let connection: AppModel.Connection
        let item: MutationOutbox.Item

        /// Item ids are unique inside one space's queue and nowhere else; the pair is what is
        /// unique across a list that spans every space.
        var id: String { "\(connection.id)|\(item.id)" }

        static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.id == rhs.id && lhs.item.state == rhs.item.state }
        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
            hasher.combine(item.state)
        }
    }

    private(set) var entries: [Entry] = []
    private(set) var pending = 0
    private(set) var accepted = 0
    private(set) var rejected = 0
    private(set) var delivered = 0
    private(set) var isRefreshing = false
    private(set) var isSending = false
    /// Set per space rather than globally: five vaults are five separate journeys, and one
    /// aeroplane-mode failure should not present itself as "the queue is broken".
    private(set) var failures: [String: String] = [:]
    /// What the delivery check learned about this device's own credentials, per space. Only
    /// spaces with something wrong appear.
    private(set) var credentials: [String: MutationDelivery.Credential] = [:]
    private var isConfirming = false

    /// Opened queues, kept. Reopening SQLite on every refresh is four disk operations per space
    /// per appearance, and this view is meant to be cheap enough to reach for.
    private var opened: [String: MutationOutbox] = [:]

    private var directory: URL { ConnectionClient.spacesDirectory }

    var hasAnything: Bool { !entries.isEmpty }

    /// The connections whose queue exists on disk. Asked of the filesystem, never by opening
    /// one: `MutationOutbox.init` creates the database, so a speculative open would leave an
    /// empty queue behind in every space this device has ever connected to.
    private var writableConnections: [AppModel.Connection] {
        AppModel.storedConnections().filter { $0.role.canSendChanges }
    }

    private var connectionsWithQueues: [AppModel.Connection] {
        writableConnections.filter { MutationOutbox.exists(spaceId: $0.spaceId, directory: directory) }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var collected: [Entry] = []
        var counts = (pending: 0, accepted: 0, rejected: 0, delivered: 0)

        for connection in connectionsWithQueues {
            guard let outbox = await outbox(for: connection) else { continue }
            let items = (try? await outbox.items()) ?? []
            collected.append(contentsOf: items.map { Entry(connection: connection, item: $0) })
            if let spaceCounts = try? await outbox.counts() {
                counts.pending += spaceCounts.pending
                counts.accepted += spaceCounts.accepted
                counts.rejected += spaceCounts.rejected
                counts.delivered += spaceCounts.delivered
            }
        }

        // Flat and chronological rather than grouped by vault. This is a list you come to in
        // order to see the newest thing you did; the accent bar and the space's name on each row
        // say where a change is going without turning the list into a set of sections that are
        // usually one row long.
        entries = collected.sorted { $0.item.createdAt > $1.item.createdAt }
        pending = counts.pending
        accepted = counts.accepted
        rejected = counts.rejected
        delivered = counts.delivered
    }

    /// Ask every space whether its owner has collected what this device sent, then refresh.
    ///
    /// Run when the app comes back and when the user pulls the tray down, and nowhere else. A
    /// change reaches the vault when somebody opens their desktop, which is not an event a
    /// phone can be sitting and waiting for: polling in a loop would spend a battery to learn
    /// nothing on nearly every attempt.
    func confirmDeliveries() async {
        guard !isConfirming else { return }
        isConfirming = true
        defer { isConfirming = false }

        let outcome = await MutationDelivery.confirm(for: connectionsWithQueues) { connection in
            await outbox(for: connection)
        }
        credentials = outcome.credentials
        await refresh()
        // After the refresh, so the tray is already showing what the notification talks about
        // by the time it can be tapped.
        await DeliveryNotice.announce(outcome.landings, mayAsk: true)
    }

    /// Send every space's queue, and report per space.
    func sendEverything() async {
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }

        failures = [:]
        for connection in connectionsWithQueues {
            await deliver(connection)
        }
        await refresh()
    }

    func send(spaceId: String) async {
        guard !isSending, let connection = connectionsWithQueues.first(where: { $0.spaceId == spaceId }) else { return }
        isSending = true
        defer { isSending = false }

        failures[spaceId] = nil
        await deliver(connection)
        await refresh()
    }

    func discard(_ entry: Entry) async {
        guard let outbox = await outbox(for: entry.connection) else { return }
        try? await outbox.remove(entry.item.id)
        await refresh()
    }

    private func deliver(_ connection: AppModel.Connection) async {
        guard let outbox = await outbox(for: connection) else { return }
        guard let count = try? await outbox.counts().pending, count > 0 else { return }
        // A locked phone cannot read the token. In the foreground that will not happen, but it
        // is a reason to try again rather than a reason to crash.
        guard let client = ConnectionClient.make(for: connection) else {
            failures[connection.spaceId] = "This device could not read its key for this space."
            return
        }
        do {
            // Pressing send is the authorisation, recorded before the first request: a send cut
            // off by a dead lift leaves behind changes the background task may finish.
            try await outbox.authorisePending()
            try await OutboxDelivery.send(from: outbox, using: client, in: connection.spaceId)
        } catch let error as APIError where error.isForbidden {
            failures[connection.spaceId] = error.requiredNeed == .write
                ? "Your access to this space is read only."
                : error.localizedDescription
        } catch {
            failures[connection.spaceId] = error.localizedDescription
        }
    }

    private func outbox(for connection: AppModel.Connection) async -> MutationOutbox? {
        if let existing = opened[connection.spaceId] { return existing }
        // `open`, never `init`: the initialiser runs four synchronous disk operations on the
        // caller's thread, and every caller here is a view on the main actor.
        guard let outbox = try? await MutationOutbox.open(spaceId: connection.spaceId, directory: directory) else { return nil }
        opened[connection.spaceId] = outbox
        return outbox
    }
}
