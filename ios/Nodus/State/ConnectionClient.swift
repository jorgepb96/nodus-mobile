import Foundation
import NodusKit

/// A client for a stored connection, whether or not that space is the one on screen.
///
/// `AppModel.session` is singular: one space is open at a time, and its `SpaceSession` owns the
/// only client anything else could borrow. That is right for a screen and wrong for everything
/// that works across spaces — the background flush, and the queue that shows every vault at
/// once. Both need to talk to a space nobody has opened.
///
/// It lives here rather than inside `BackgroundJobs` because two callers is the point at which
/// a private helper becomes a shared one, and because a second copy of "how a token becomes a
/// client" is how one of them ends up pointed at the wrong cache.
enum ConnectionClient {
    private static let keychain = KeychainStore()

    static var spacesDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("spaces", isDirectory: true)
    }

    private static var cacheDirectory: URL {
        URL.cachesDirectory.appendingPathComponent("nodus-http", isDirectory: true)
    }

    /// - Returns: nil when this device holds no token for the space, which on a locked phone
    ///   means "not right now" rather than "never" — the Keychain item is protected until first
    ///   unlock, and a background task can run before that.
    static func make(for connection: AppModel.Connection) -> NodusClient? {
        guard let token = keychain.value(for: KeychainStore.deviceTokenKey(
            origin: connection.origin,
            spaceId: connection.spaceId
        )) else { return nil }
        return NodusClient(
            address: ServerAddress(trusted: connection.origin),
            token: token,
            cache: ResponseCache(directory: cacheDirectory)
        )
    }
}

/// Sending what a queue holds, once, in one place.
///
/// The foreground flush and the tray's per-space send are the same act, and they were about to
/// become two loops that both had to remember that a duplicate is a success and that a batch
/// short of the limit is the last one. One of them would eventually stop remembering.
enum OutboxDelivery {
    /// Drain a queue's pending changes.
    ///
    /// Authorisation is deliberately not done here: whether the user has pressed send is a
    /// question about intent, and this is the part that only knows about the wire.
    ///
    /// - Throws: whatever the client threw. Nothing is marked that the server did not answer
    ///   for, so a thrown error leaves the queue exactly where it was.
    static func send(
        from outbox: MutationOutbox,
        using client: NodusClient,
        in spaceId: String,
        maxBatch: Int = 200
    ) async throws {
        while true {
            let batch = try await outbox.pending(limit: maxBatch)
            guard !batch.isEmpty else { return }

            let receipt = try await client.send(mutations: batch, in: spaceId)
            // A duplicate is a success: the first attempt landed and the retry found it already
            // there. Treating it as a failure would leave items stuck forever.
            try await outbox.markAccepted(receipt.accepted + receipt.duplicate)
            try await outbox.markRejected(receipt.rejected.map { (id: $0.id, reason: $0.reason) })

            if receipt.accepted.isEmpty, receipt.duplicate.isEmpty, !receipt.rejected.isEmpty { return }
            if batch.count < maxBatch { return }
        }
    }
}
