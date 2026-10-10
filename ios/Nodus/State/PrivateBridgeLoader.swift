import Foundation
import CryptoKit
import NodusKit

struct PrivateBridgeSnapshot: Sendable {
    let tables: [String: [Row]]
    let readFromEncryptedCache: Bool
}

@MainActor
func privateBridgeConnection(_ session: SpaceSession, domain: DesktopBridgeDomain) throws -> (String, DesktopBridgePairing, String) {
    let store = DesktopBridgePairingStore()
    guard let vaultId = session.vaultId else { throw DesktopBridgeError.permissionDenied }
    let candidates = store.pairings().filter {
        $0.vaultIds.contains(vaultId) && $0.domains.contains(domain)
            && (session.connection.desktopPairingId == nil || $0.id == session.connection.desktopPairingId)
    }
    guard candidates.count == 1, let pairing = candidates.first, let token = store.credential(for: pairing) else { throw DesktopBridgeError.permissionDenied }
    return (vaultId, pairing, token)
}

func isPrivateBridgeOffline(_ error: Error) -> Bool {
    guard let transport = error as? URLError else { return false }
    return [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed, .timedOut].contains(transport.code)
}

@MainActor
func loadPrivateBridgeValue(_ session: SpaceSession, method: String, args: [JSONValue]) async throws -> JSONValue {
    guard ["getLibraryReaderDocument", "getGlobalLibraryItem"].contains(method) else { throw DesktopBridgeError.permissionDenied }
    let (vaultId, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
    let cache = try PrivateBridgeCache(pairingId: pairing.id)
    let key = "operation:\(method):" + SHA256.hash(data: try JSONEncoder.nodus.encode(args)).map { String(format: "%02x", $0) }.joined()
    do {
        let value = try await DesktopBridgeClient(pairing: pairing, token: token).operation(vaultId: vaultId, method: method, args: args)
        try await cache.store(JSONEncoder.nodus.encode(value), vaultId: vaultId, domain: .corpus, recordId: key)
        return value
    } catch {
        guard isPrivateBridgeOffline(error), let bytes = try await cache.data(vaultId: vaultId, domain: .corpus, recordId: key) else { throw error }
        return try JSONDecoder.nodus.decode(JSONValue.self, from: bytes)
    }
}

struct PrivateBridgeFileCopy {
    let url: URL
    let descriptor: DesktopBridgeFileDescriptor
    let offline: Bool
}

@MainActor
func loadPrivateBridgeFile(_ session: SpaceSession, kind: DesktopBridgeFileKind, id: String) async throws -> PrivateBridgeFileCopy {
    let (vaultId, pairing, token) = try privateBridgeConnection(session, domain: kind.domain)
    let client = DesktopBridgeClient(pairing: pairing, token: token), cache = try PrivateBridgeCache(pairingId: pairing.id)
    let key = "file:\(kind.rawValue):\(id)"
    var descriptor: DesktopBridgeFileDescriptor, bytes: Data, offline = false
    do {
        descriptor = try await client.fileDescriptor(vaultId: vaultId, kind: kind, id: id)
        if let cached = try? await cache.data(vaultId: vaultId, domain: kind.domain, recordId: "\(key):\(descriptor.sha256)"),
           cached.count == descriptor.byteSize,
           SHA256.hash(data: cached).map({ String(format: "%02x", $0) }).joined() == descriptor.sha256.lowercased() {
            // Revalidate the current grant and descriptor online, then reuse only
            // identical verified bytes. A changed original downloads its new revision.
            bytes = cached
        } else { bytes = try await client.fileData(vaultId: vaultId, descriptor: descriptor) }
        try await cache.store(bytes, vaultId: vaultId, domain: kind.domain, recordId: "\(key):\(descriptor.sha256)")
        try await cache.store(JSONEncoder.nodus.encode(descriptor), vaultId: vaultId, domain: kind.domain, recordId: key)
    } catch {
        guard isPrivateBridgeOffline(error),
              let metadata = try await cache.data(vaultId: vaultId, domain: kind.domain, recordId: key),
              let file = try? JSONDecoder.nodus.decode(DesktopBridgeFileDescriptor.self, from: metadata),
              file.kind == kind, file.id == id,
              let downloaded = try await cache.data(vaultId: vaultId, domain: kind.domain, recordId: "\(key):\(file.sha256)"),
              downloaded.count == file.byteSize,
              SHA256.hash(data: downloaded).map({ String(format: "%02x", $0) }).joined() == file.sha256.lowercased() else { throw error }
        descriptor = file; bytes = downloaded; offline = true
    }
    let folder = URL.temporaryDirectory.appendingPathComponent("Nodus-private-files/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(URL(fileURLWithPath: descriptor.filename).lastPathComponent)
    try bytes.write(to: url, options: [.atomic, .completeFileProtection])
    return PrivateBridgeFileCopy(url: url, descriptor: descriptor, offline: offline)
}

/// Reads a fixed private domain directly from its paired Mac and keeps only an encrypted,
/// complete-file-protection fallback. The caller supplies the table names; Desktop still applies
/// the authoritative per-domain allowlist, so this helper cannot broaden a pairing grant.
@MainActor
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

    let (vaultId, pairing, token) = try privateBridgeConnection(session, domain: domain)

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
                    vaultId: vaultId,
                    domain: domain,
                    table: name,
                    cursor: cursor,
                    limit: 100
                )
                guard !page.hasMore || page.cursor > cursor else { throw DesktopBridgeError.malformedResponse }
                rows.append(contentsOf: page.rows)
                cursor = page.cursor
                if !page.hasMore { break }
            } while true
            try await cache.store(
                JSONEncoder.nodus.encode(rows),
                vaultId: vaultId,
                domain: domain,
                recordId: "table:\(name)"
            )
            result[name] = rows.map(Row.init)
        } catch {
            // A revoked grant, changed certificate or malformed response must remain visible.
            // Only a disconnected transport can use this device's protected offline copy.
            guard isPrivateBridgeOffline(error) else { throw error }
            guard
                let data = try await cache.data(
                    vaultId: vaultId,
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
