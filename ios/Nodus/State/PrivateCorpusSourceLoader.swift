import Foundation
import NodusKit

@MainActor
func loadPrivateCorpusSource(_ session: SpaceSession, reference: PrivateCorpusReference, downloadedOnly: Bool = false,
    progress: @escaping (Int, Int) -> Void = { _, _ in }) async throws -> (CompanionPrivateSourceCopy, Bool) {
#if DEBUG
    if session.connection.desktopPairingId == nil, !downloadedOnly, reference.kind == .recording,
       let copy = try debugPrivateRecordingCopies().first(where: { $0.source.id == reference.id }) { return (copy, false) }
#endif
    let (vault, pairing, token) = try privateBridgeConnection(session, domain: reference.kind.domain)
    guard !pairing.isExpired else { throw DesktopBridgeError.expired }
    let cache = try PrivateBridgeCache(pairingId: pairing.id)
    if downloadedOnly {
        guard let copy = try await CompanionPrivateSourceCopy.downloaded(cache: cache, vaultId: vault, reference: reference) else { throw PrivateCorpusSourceError.notDownloaded }
        return (copy, true)
    }
    let client = DesktopBridgeClient(pairing: pairing, token: token)
    do {
        let source = try await client.privateSource(vaultId: vault, reference: reference)
        let total = source.groups.reduce(0) { $0 + $1.total }
        var rows: [String: [Row]] = [:], loaded = 0
        progress(loaded, total)
        for group in source.groups {
            var items: [Row] = [], cursor = 0
            repeat {
                try Task.checkCancellation()
                let page = try await client.privateSourcePage(vaultId: vault, reference: reference, group: group, cursor: cursor)
                let cursors = page.rows.compactMap { $0.int("_bridge_cursor") }
                guard cursors.count == page.rows.count, cursors.allSatisfy({ $0 > cursor }),
                      zip(cursors, cursors.dropFirst()).allSatisfy({ $0.0 < $0.1 }),
                      page.cursor == (cursors.last ?? cursor), items.count + page.rows.count <= group.total else {
                    throw DesktopBridgeError.malformedResponse
                }
                items.append(contentsOf: page.rows); cursor = page.cursor
                loaded += page.rows.count; progress(loaded, total)
                if !page.hasMore { break }
            } while true
            guard items.count == group.total else { throw DesktopBridgeError.malformedResponse }
            rows[group.key] = items
        }
        // The root, transcript versions, and every related group must belong to
        // one unchanged source before it is shown or saved as a complete copy.
        let current = try await client.privateSource(vaultId: vault, reference: reference)
        guard current.revision == source.revision else { throw PrivateCorpusSourceError.changed }
        return (try CompanionPrivateSourceCopy(source: source, rows: rows, reference: reference), false)
    } catch {
        guard isPrivateBridgeOffline(error),
              let copy = try await CompanionPrivateSourceCopy.downloaded(cache: cache, vaultId: vault, reference: reference) else { throw error }
        return (copy, true)
    }
}

enum PrivateCorpusSourceError: Error, LocalizedError {
    case changed, notDownloaded
    var errorDescription: String? {
        switch self {
        case .changed: "La fuente ha cambiado mientras se cargaba. Vuelve a abrirla para consultar su versión actual."
        case .notDownloaded: "Esta fuente no está descargada. Consérvala desde su lector mientras el Mac está disponible."
        }
    }
}

@MainActor
func savePrivateCorpusSource(_ session: SpaceSession, reference: PrivateCorpusReference,
    copy: CompanionPrivateSourceCopy, days: Int) async throws {
    guard [7, 30].contains(days) else { throw PrivateBridgeCache.ReadPackError.invalidSelection }
    let (vault, pairing, _) = try privateBridgeConnection(session, domain: reference.kind.domain)
    guard !pairing.isExpired else { throw DesktopBridgeError.expired }
    try copy.validate(for: reference)
    let bytes = try JSONEncoder.nodus.encode(copy)
    let index = try JSONEncoder.nodus.encode(CompanionPrivateSourceCopy.CatalogueEntry(source: copy.source))
    guard bytes.count <= PrivateBridgeCache.defaultReadLimitBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
    let cache = try PrivateBridgeCache(pairingId: pairing.id)
    let id = try PrivateBridgeCache.readPackSelectionId(vaultId: vault, recordIds: [reference.recordKey])
    try await cache.saveReadPack(id: id, vaultId: vault, title: copy.source.title,
        expiresAt: Date().addingTimeInterval(Double(days) * 86_400), records: [
            .init(domain: reference.kind.domain, recordId: reference.recordKey, data: bytes),
            .init(domain: reference.kind.domain, recordId: CompanionPrivateSourceCopy.catalogueKey, data: index),
        ])
    session.didChangeCompanionDownloads()
}
