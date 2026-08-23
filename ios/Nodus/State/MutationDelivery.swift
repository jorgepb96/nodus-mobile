import Foundation
import NodusKit

/// Asking each space how far its owner has collected, and moving the queue on when it has.
///
/// The queue could only ever say "the server has it". The server keeps, per space, how far the
/// owner's desktop has acknowledged its ledger, and it publishes that number in `/me` for
/// exactly this purpose; a send comes back with the sequence it landed at. When the first
/// catches up with the second, the change is out of the ledger and in the owner's own database
/// — which is a different thing from being readable, and the interface says so.
///
/// One pass serves both callers on purpose. The tray runs it when the app comes back and the
/// mirror-refresh task runs it while nobody is looking, and two copies of "which number beats
/// which" is how one of them ends up announcing a delivery that did not happen.
enum MutationDelivery {
    /// Changes that reached the vault on this pass, in one space.
    struct Landing {
        let connection: AppModel.Connection
        let items: [MutationOutbox.Item]
    }

    /// What `/me` said about this device's own token, which until now was read only for the role.
    enum Credential: Equatable {
        /// The server would not accept the token at all. It is not proof the token is dead
        /// everywhere — a token scoped to another space answers 401 too — but it is proof this
        /// device cannot reach *this* space with it any more.
        case rejected
        /// Still good, and running out. A `replica` token has a 180-day sliding expiry that
        /// renews on every call, so this only ever appears for a device that has been away.
        case expiring(Date)
    }

    struct Outcome {
        var landings: [Landing] = []
        /// Only spaces with something to say. A healthy credential is not news.
        var credentials: [String: Credential] = [:]
        /// False when a space could not be asked — no network, a locked phone, a server that
        /// did not answer. The background task reports it so iOS keeps giving it windows.
        var everySpaceAnswered = true
    }

    /// How close to expiry is worth saying out loud.
    ///
    /// Two weeks, because the fix — signing in again — needs the person, their password and a
    /// server they can reach, and a warning that arrives on the day the token dies is a warning
    /// that arrives after the queue has already stopped working.
    static let expiryWarning: TimeInterval = 14 * 24 * 60 * 60

    /// - Parameters:
    ///   - connections: spaces this device can send changes to and already has a queue for.
    ///     Filtered by the caller, because "does a queue exist on disk?" must be asked of the
    ///     filesystem — opening one is what brings it into being.
    ///   - outbox: how to get the queue for a space. A closure rather than a directory so the
    ///     tray can hand over the handles it already holds open instead of paying for four disk
    ///     operations per space on every return to the foreground.
    static func confirm(
        for connections: [AppModel.Connection],
        opening outbox: @Sendable (AppModel.Connection) async -> MutationOutbox?
    ) async -> Outcome {
        var outcome = Outcome()

        for connection in connections {
            guard let queue = await outbox(connection) else { outcome.everySpaceAnswered = false; continue }

            // Swept here rather than inside `markDelivered`, so a change that landed is still in
            // the tray the next time the user looks. This is also the only pass that runs when
            // nothing is queued at all, which is exactly when the sweep has work to do.
            try? await queue.purgeDelivered(
                deliveredBefore: Date().addingTimeInterval(-MutationOutbox.deliveredRetention)
            )

            // Nothing in the ledger with a sequence to compare means nothing to ask about. A
            // device whose whole queue predates the cursor never sends a request at all.
            guard let waiting = try? await queue.awaitingDelivery(), waiting > 0 else { continue }
            // A locked phone cannot read the token. Later, not never.
            guard let client = ConnectionClient.make(for: connection) else {
                outcome.everySpaceAnswered = false
                continue
            }

            do {
                let me = try await client.me()
                if let credential = credential(from: me) {
                    outcome.credentials[connection.spaceId] = credential
                }
                // A server that does not publish the cursor leaves every row exactly where it
                // was, saying what it says today. Nothing is guessed from its silence.
                guard
                    let space = me.spaces.first(where: { $0.id == connection.spaceId }),
                    let cursor = space.mutationCursor
                else { continue }

                let landed = (try? await queue.markDelivered(upTo: cursor)) ?? []
                if !landed.isEmpty {
                    outcome.landings.append(Landing(connection: connection, items: landed))
                }
            } catch let error as APIError where error.isUnauthorized {
                outcome.credentials[connection.spaceId] = .rejected
            } catch {
                outcome.everySpaceAnswered = false
            }
        }

        return outcome
    }

    /// The other thing `/me` knows: how long this device's own credential has left.
    private static func credential(from me: MeResponse) -> Credential? {
        // A `publisher` token from a pairing code carries no expiry at all, which is not a
        // problem to report.
        guard let expiry = me.device?.expiresAt else { return nil }
        if expiry <= Date() { return .rejected }
        guard expiry.timeIntervalSinceNow <= expiryWarning else { return nil }
        return .expiring(expiry)
    }
}
