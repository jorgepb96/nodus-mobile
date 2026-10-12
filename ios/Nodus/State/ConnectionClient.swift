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

    static func companionDocuments(for connection: AppModel.Connection, kind: CompanionDocumentOutbox.Kind = .workspaceNote) async throws -> (DesktopBridgeClient, CompanionDocumentOutbox)? {
        guard connection.role.canSendChanges, let id = connection.desktopPairingId, let vaultId = connection.vaultId else { return nil }
        let store = DesktopBridgePairingStore()
        guard let pairing = store.pairings().first(where: { $0.id == id }), !pairing.isExpired,
              pairing.vaultIds.contains(vaultId), pairing.domains.contains(.writing),
              kind != .studyDocument || pairing.domains.contains(.corpus),
              let token = store.credential(for: pairing) else { return nil }
        let documents = try await CompanionDocumentOutboxes.shared.outbox(pairingId: id, vaultId: vaultId, kind: kind)
        return (DesktopBridgeClient(pairing: pairing, token: token), documents)
    }
    static func companionChat(for connection: AppModel.Connection) throws -> DesktopBridgeClient {
        guard let id = connection.desktopPairingId,let vaultId = connection.vaultId else { throw DesktopBridgeError.permissionDenied }
        let store = DesktopBridgePairingStore()
        guard let pairing = store.pairings().first(where:{$0.id == id}),!pairing.isExpired,pairing.vaultIds.contains(vaultId),pairing.domains.contains(.corpus),let token = store.credential(for:pairing) else { throw DesktopBridgeError.permissionDenied }
        return DesktopBridgeClient(pairing:pairing,token:token)
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
        return make(for: connection, token: token, pairings: DesktopBridgePairingStore().pairings())
    }

    /// Foreground and background clients must use the same Mac/vault route.
    /// Losing a private pairing must never fall through to a Server API on the
    /// same address, or send queued content using a different connection mode.
    static func make(for connection: AppModel.Connection, token: String,
                     pairings: [DesktopBridgePairing], cacheDirectory directory: URL? = nil) -> NodusClient? {
        guard !token.isEmpty else { return nil }
        var bridge: DesktopBridgeClient?
        if let pairingId = connection.desktopPairingId {
            guard let pairing = pairings.first(where: { $0.id == pairingId }),
                  let vaultId = connection.vaultId, pairing.vaultIds.contains(vaultId),
                  !pairing.isExpired else { return nil }
            bridge = DesktopBridgeClient(pairing: pairing, token: token)
        }
        return NodusClient(address: ServerAddress(trusted: connection.origin), token: token,
            cache: ResponseCache(directory: directory ?? cacheDirectory), desktopBridge: bridge, vaultId: connection.vaultId)
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
        limits: MutationLimits = .unstated
    ) async throws {
        let maximumBatch = min(limits.maxBatch, await client.maximumMutationBatch)
        while true {
            let queued = try await outbox.authorisedPending(limit: maximumBatch)
            guard !queued.isEmpty else { return }

            // Cut by bytes, not by count. One Deep Research report is a quarter of a megabyte,
            // so a queue of them makes a request no count of rows would have predicted, and
            // the whole request is refused together when it does not fit.
            var batch: [Mutation] = []
            var bytes = 0
            for mutation in queued {
                let size = mutation.encodedSize
                // Always take the first, so a change bigger than a whole request is still
                // attempted rather than blocking everything queued behind it forever.
                if !batch.isEmpty, bytes + size > limits.maxBatchBytes { break }
                bytes += size
                batch.append(mutation)
            }

            let receipt = try await client.send(mutations: batch, in: spaceId)
            // A duplicate is a success: the first attempt landed and the retry found it already
            // there. Treating it as a failure would leave items stuck forever.
            //
            // The cursor is kept with them. It is where this batch came to rest in the ledger,
            // and the only number the space's own `mutationCursor` can later be measured
            // against to say the owner has collected it.
            try await outbox.recordReceipt(receipt, for: batch)

            if receipt.accepted.isEmpty, receipt.duplicate.isEmpty, !receipt.rejected.isEmpty { return }
            // Drained only when a short read was also sent whole. Testing the batch alone would
            // stop early every time bytes ran out before rows did, leaving the rest queued with
            // nothing to start it again.
            if batch.count == queued.count, queued.count < maximumBatch { return }
        }
    }
}
