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

/// Explicit selected reads never consult the Mac or disposable query caches.
@MainActor
func downloadedCollection(_ session: SpaceSession, path: String) async throws -> CompanionCollectionCopy {
    let (vault, pairing, _) = try privateBridgeConnection(session, domain: .corpus)
    guard !pairing.isExpired else { throw DesktopBridgeError.expired }
    let cache = try PrivateBridgeCache(pairingId: pairing.id)
    guard let copy = try await CompanionCollectionCopy.downloaded(cache: cache, vaultId: vault, path: path)
    else { throw CompanionCollectionCopy.CopyError.dossierNotDownloaded }
    return copy
}

/// Combine independent selected downloads without including disposable,
/// previously consulted catalogues. Newer copies win for a repeated identity.
func companionDownloadedCatalogue(_ cache: PrivateBridgeCache, vaultId: String, method: String) async throws -> JSONValue? {
    guard ["listWritingWorkshopDrafts", "listImmersionSessions"].contains(method) else { return nil }
    let copies = try await cache.downloadedData(vaultId: vaultId, domain: .corpus,
        recordId: CompanionDocumentOutbox.operationKey(method, []))
    guard !copies.isEmpty else { return nil }
    var ids = Set<String>(), rows: [JSONValue] = []
    for bytes in copies {
        guard let items = try JSONDecoder.nodus.decode(JSONValue.self, from: bytes).arrayValue else { throw DesktopBridgeError.malformedResponse }
        for item in items {
            guard let id = item.objectValue?["id"]?.stringValue, !id.isEmpty else { throw DesktopBridgeError.malformedResponse }
            if ids.insert(id).inserted { rows.append(item) }
        }
    }
    return .array(rows)
}

func companionDictionaryCopy(_ session: SpaceSession) async throws -> JSONValue {
    let (vault, pairing, _) = try privateBridgeConnection(session, domain: .corpus)
    guard !pairing.isExpired else { throw DesktopBridgeError.permissionDenied }
    let copies = try await PrivateBridgeCache(pairingId: pairing.id).downloadedData(vaultId: vault, domain: .corpus, recordId: "companion:dictionary:v1")
    guard !copies.isEmpty else { return .null }
    var ids = Set<String>(), entries: [JSONValue] = []
    for bytes in copies {
        let copy = try JSONDecoder.nodus.decode(JSONValue.self, from: bytes)
        guard copy.objectValue?["version"]?.intValue == 1, let items = copy.objectValue?["entries"]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
        for item in items {
            guard let id = item.objectValue?["detail"]?.objectValue?["entry"]?.objectValue?["id"]?.stringValue,
                  !id.isEmpty, item.objectValue?["evidence"]?.arrayValue != nil, item.objectValue?["versions"]?.arrayValue != nil else { throw DesktopBridgeError.malformedResponse }
            if ids.insert(id).inserted { entries.append(item) }
        }
    }
    return .object(["version": .int(1), "entries": .array(entries)])
}

func companionCitationVerification(_ cache: PrivateBridgeCache, vaultId: String, refs: JSONValue) async throws -> JSONValue? {
    guard let refs = refs.arrayValue, refs.count <= 10_000 else { throw DesktopBridgeError.malformedResponse }
    let copies = try await cache.downloadedData(vaultId: vaultId, domain: .corpus, recordId: "companion:citations:v1")
    guard !copies.isEmpty else { return nil }
    var known: [String: JSONValue] = [:]
    for bytes in copies {
        guard let map = try JSONDecoder.nodus.decode(JSONValue.self, from: bytes).objectValue,
              map.values.allSatisfy({ if case .bool = $0 { return true }; return false }) else { throw DesktopBridgeError.malformedResponse }
        for (key, value) in map where known[key] == nil { known[key] = value }
    }
    var result: [String: JSONValue] = [:]
    for ref in refs {
        guard let kind = ref.objectValue?["kind"]?.stringValue, ["idea", "work", "gap", "contradiction", "passage"].contains(kind),
              let id = ref.objectValue?["id"]?.stringValue, !id.isEmpty else { throw DesktopBridgeError.malformedResponse }
        let key = "\(kind):\(id)"
        // An undownloaded source cannot be vouched for on this device.
        result[key] = known[key] ?? .bool(false)
    }
    return .object(result)
}

@MainActor
func loadPrivateBridgeValue(_ session: SpaceSession, method: String, args: [JSONValue], downloadedOnly: Bool = false) async throws -> JSONValue {
    guard ["getLibraryReaderDocument", "getGlobalLibraryItem", "getMobileDossierFiles", "getMobileWorldMapReadSource"].contains(method) else { throw DesktopBridgeError.permissionDenied }
    let (vaultId, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
    guard !pairing.isExpired else { throw DesktopBridgeError.expired }
    if method == "getMobileDossierFiles", args.first?.objectValue?["collection"] == .string("archive-items"), !pairing.domains.contains(.primarySourceFiles) { throw DesktopBridgeError.permissionDenied }
    let cache = try PrivateBridgeCache(pairingId: pairing.id)
    let key = try CompanionDocumentOutbox.operationKey(method, args)
    if downloadedOnly {
        guard let data = try await cache.downloadedData(vaultId: vaultId, domain: .corpus, recordId: key).first else {
            throw APIError(status: 409, code: "dossier_resources_not_downloaded", message: "Esta descarga no incluye el catálogo de originales. Actualízala con Nodus conectado para elegir los archivos que quieras llevar.")
        }
        return try JSONDecoder.nodus.decode(JSONValue.self, from: data)
    }
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
    let lease: PrivateBridgeFileLease
}

@MainActor
func loadPrivateBridgeFile(_ session: SpaceSession, kind: DesktopBridgeFileKind, id: String, downloadedOnly: Bool = false) async throws -> PrivateBridgeFileCopy {
    let (vaultId, pairing, token) = try privateBridgeConnection(session, domain: kind.domain)
    let client = DesktopBridgeClient(pairing: pairing, token: token), cache = try PrivateBridgeCache(pairingId: pairing.id)
    let key = "file:\(kind.rawValue):\(id)"
    if downloadedOnly {
        guard !pairing.isExpired else { throw DesktopBridgeError.expired }
        guard let metadata = try await cache.downloadedData(vaultId: vaultId, domain: kind.domain, recordId: key).first else { throw PrivateCorpusSourceError.notDownloaded }
        let file = try JSONDecoder.nodus.decode(DesktopBridgeFileDescriptor.self, from: metadata)
        guard file.kind == kind, file.id == id, file.byteSize <= PrivateBridgeCache.defaultReadLimitBytes,
              let bytes = try await cache.downloadedData(vaultId: vaultId, domain: kind.domain, recordId: "\(key):\(file.sha256)").first,
              bytes.count == file.byteSize, SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == file.sha256.lowercased() else { throw DesktopBridgeError.malformedResponse }
        let lease = try PrivateBridgeFileLease.write(bytes, filename: file.filename)
        return PrivateBridgeFileCopy(url: lease.url, descriptor: file, offline: true, lease: lease)
    }
    var descriptor: DesktopBridgeFileDescriptor, bytes: Data, offline = false
    do {
        descriptor = try await client.fileDescriptor(vaultId: vaultId, kind: kind, id: id)
        guard descriptor.byteSize <= PrivateBridgeCache.defaultReadLimitBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
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
    let lease = try PrivateBridgeFileLease.write(bytes, filename: descriptor.filename)
    return PrivateBridgeFileCopy(url: lease.url, descriptor: descriptor, offline: offline, lease: lease)
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
    if session.connection.desktopPairingId == nil, !fixture.isEmpty {
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
