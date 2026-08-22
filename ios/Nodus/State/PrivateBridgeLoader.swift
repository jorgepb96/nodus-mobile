import Foundation
import NodusKit

struct PrivateBridgeSnapshot: Sendable {
    let tables: [String: [Row]]
    let readFromEncryptedCache: Bool
}

/// Reads a fixed private domain directly from its paired Mac and keeps only an encrypted,
/// complete-file-protection fallback. The caller supplies the table names; Desktop still applies
/// the authoritative per-domain allowlist, so this helper cannot broaden a pairing grant.
func loadPrivateBridgeTables(
    _ session: SpaceSession,
    domain: DesktopBridgeDomain,
    names: [String],
    fixture: [String: [Row]] = [:]
) async throws -> PrivateBridgeSnapshot {
    if !fixture.isEmpty {
        return PrivateBridgeSnapshot(
            tables: Dictionary(uniqueKeysWithValues: names.map { ($0, fixture[$0] ?? []) }),
            readFromEncryptedCache: false
        )
    }

    let store = DesktopBridgePairingStore()
    guard
        let pairing = store.pairings().first(where: {
            $0.vaultIds.contains(session.connection.spaceId) && $0.domains.contains(domain)
        }),
        let token = store.credential(for: pairing)
    else { throw DesktopBridgeError.permissionDenied }

    let cache = try PrivateBridgeCache(pairingId: pairing.id)
    let client = DesktopBridgeClient(pairing: pairing, token: token)
    var result: [String: [Row]] = [:]
    var usedCache = false

    for name in names {
        do {
            var rows: [[String: JSONValue]] = []
            var cursor = 0
            repeat {
                let page = try await client.records(
                    vaultId: session.connection.spaceId,
                    domain: domain,
                    table: name,
                    cursor: cursor,
                    limit: 100
                )
                rows.append(contentsOf: page.rows)
                cursor = page.cursor
                if !page.hasMore { break }
            } while true
            try await cache.store(
                JSONEncoder.nodus.encode(rows),
                vaultId: session.connection.spaceId,
                domain: domain,
                recordId: "table:\(name)"
            )
            result[name] = rows.map(Row.init)
        } catch {
            guard
                let data = try await cache.data(
                    vaultId: session.connection.spaceId,
                    domain: domain,
                    recordId: "table:\(name)"
                ),
                let rows = try? JSONDecoder.nodus.decode([[String: JSONValue]].self, from: data)
            else { throw error }
            result[name] = rows.map(Row.init)
            usedCache = true
        }
    }
    return PrivateBridgeSnapshot(tables: result, readFromEncryptedCache: usedCache)
}
