import CryptoKit
import SwiftUI
import NodusKit

/// Pin an explicitly chosen original/attachment/recording, with its actual file
/// grant. Opening another file never downloads an entire source collection.
struct CompanionFileDownloadButton: View {
    let session: SpaceSession
    let copy: PrivateBridgeFileCopy
    var requiredQueries: [(method: String, args: [JSONValue])] = []
    @State private var saving = false
    @State private var saved = false
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu {
                Button("Conservar 7 días") { save(days: 7) }
                Button("Conservar 30 días") { save(days: 30) }
            } label: {
                if saving { ProgressView() }
                else { Label(saved ? "Descargado para llevar" : "Conservar sin conexión", systemImage: saved ? "checkmark.circle.fill" : "arrow.down.circle") }
            }.frame(minHeight: 44).disabled(saving)
                .accessibilityIdentifier("companion-file-download-\(copy.descriptor.kind.rawValue)-\(copy.descriptor.id)")
            if let issue { Text(issue).font(.caption).foregroundStyle(Color.nodusDanger) }
        }
        .onChange(of: copy.descriptor.sha256) { _, _ in saved = false; issue = nil }
    }
    private func save(days: Int) {
        saving = true; issue = nil
        Task {
            defer { saving = false }
            do {
                try await saveCompanionFileCopy(session, copy: copy, days: days, requiredQueries: requiredQueries)
                saved = true
            } catch { issue = error.localizedDescription }
        }
    }
}

@MainActor
func saveCompanionFileCopy(_ session: SpaceSession, copy: PrivateBridgeFileCopy, days: Int,
    requiredQueries: [(method: String, args: [JSONValue])] = []) async throws {
    guard [7, 30].contains(days) else { throw PrivateBridgeCache.ReadPackError.invalidSelection }
    let descriptor = copy.descriptor
    let (vault, pairing, token) = try privateBridgeConnection(session, domain: descriptor.kind.domain)
    guard !pairing.isExpired else { throw DesktopBridgeError.permissionDenied }
    guard descriptor.byteSize <= PrivateBridgeCache.defaultReadLimitBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
    let size = try copy.url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    guard size == descriptor.byteSize else { throw DesktopBridgeError.malformedResponse }
    let bytes = try Data(contentsOf: copy.url)
    guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == descriptor.sha256.lowercased() else { throw DesktopBridgeError.malformedResponse }
    let cache = try PrivateBridgeCache(pairingId: pairing.id)
    let key = "file:\(descriptor.kind.rawValue):\(descriptor.id)"
    var records: [PrivateBridgeCache.ReadPackRecord] = [
        .init(domain: descriptor.kind.domain, recordId: key, data: try JSONEncoder.nodus.encode(descriptor)),
        .init(domain: descriptor.kind.domain, recordId: "\(key):\(descriptor.sha256)", data: bytes)
    ]
    var selection = [key]
    for query in requiredQueries {
        // Source navigation needs its canonical reader metadata as well as the
        // chosen file. Keep it in the same atomic selection, never a loose LRU.
        guard pairing.domains.contains(.corpus), query.method == "getLibraryReaderDocument" else { throw DesktopBridgeError.permissionDenied }
        let record = try CompanionDocumentOutbox.operationKey(query.method, query.args)
        let data: Data
        if let stored = try await cache.data(vaultId: vault, domain: .corpus, recordId: record) { data = stored }
        else {
            let value = try await DesktopBridgeClient(pairing: pairing, token: token).operation(vaultId: vault, method: query.method, args: query.args)
            guard value.objectValue != nil else { throw DesktopBridgeError.malformedResponse }
            data = try JSONEncoder.nodus.encode(value)
        }
        records.append(.init(domain: .corpus, recordId: record, data: data)); selection.append(record)
    }
    try Task.checkCancellation()
    let id = try PrivateBridgeCache.readPackSelectionId(vaultId: vault, recordIds: selection)
    try await cache.saveReadPack(id: id, vaultId: vault, title: descriptor.filename,
        expiresAt: Date().addingTimeInterval(Double(days) * 86_400), records: records, primaryFile: descriptor)
}
