import CryptoKit
import Foundation
import NodusKit

/// Keeps legacy data intact until its owner chooses a destination. Published/private
/// corpora and authorised outboxes are never inferred from an unlabelled folder.
@MainActor
enum ConnectionStorage {
    struct LegacyData { let reports: Int; let chats: Int }
    enum RecoveryError: LocalizedError {
        case unsafeFile, malformedDocument
        var errorDescription: String? {
            switch self {
            case .unsafeFile: "No se puede recuperar un archivo con una ruta no segura."
            case .malformedDocument: "Un documento antiguo no tiene un formato válido. Se conserva la copia original."
            }
        }
    }

    static func prepare(for connection: AppModel.Connection, root: URL = .applicationSupportDirectory) throws {
        try SpaceStorageIdentity(connectionID: connection.id).prepare(
            in: root.appendingPathComponent("spaces", isDirectory: true), legacySpaceID: connection.spaceId)
    }

    private static func legacyFolder(_ connection: AppModel.Connection, root: URL) -> URL? {
        let id = connection.spaceId
        guard !id.isEmpty, ![".", ".."].contains(id), !id.contains("/"), !id.contains("\\"), !id.hasPrefix("c2-") else { return nil }
        let folder = root.appendingPathComponent("spaces", isDirectory: true).appendingPathComponent(id, isDirectory: true)
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    static func legacyData(for connection: AppModel.Connection, root: URL = .applicationSupportDirectory) -> LegacyData? {
        guard let folder = legacyFolder(connection, root: root) else { return nil }
        func count(_ kind: String) -> Int {
            ((try? FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent(kind), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }.count
        }
        let value = LegacyData(reports: count("reports"), chats: count("chats"))
        return value.reports + value.chats > 0 ? value : nil
    }

    /// The settings confirmation is the attribution. Copies receive new local IDs and
    /// reports lose old publication IDs, so recovery cannot overwrite another vault's row.
    /// Fingerprint receipts make repeating the recovery safe; originals remain untouched.
    @discardableResult
    static func recoverLocalDocuments(for connection: AppModel.Connection, root: URL = .applicationSupportDirectory) throws -> Int {
        try prepare(for: connection, root: root)
        guard let source = legacyFolder(connection, root: root) else { return 0 }
        let target = root.appendingPathComponent("spaces", isDirectory: true).appendingPathComponent(connection.storageId, isDirectory: true)
        let receiptURL = target.appendingPathComponent("legacy-recovery-receipts.json")
        var receipts: [String: String] = [:]
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            receipts = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: receiptURL))
        }
        var recovered = 0
        for kind in ["reports", "chats"] {
            let folder = source.appendingPathComponent(kind, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path),
               try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw RecoveryError.unsafeFile }
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
            for file in files where file.pathExtension == "json" {
                guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw RecoveryError.unsafeFile }
                let bytes = try Data(contentsOf: file)
                let fingerprint = kind + ":" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                if receipts[fingerprint] != nil { continue }
                guard var object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], object["id"] is String else { throw RecoveryError.malformedDocument }
                let hex = SHA256.hash(data: Data((connection.storageId + ":" + fingerprint).utf8)).map { String(format: "%02x", $0) }.joined()
                let short = String(hex.prefix(32)), cuts = [8, 12, 16, 20]
                let id = short.enumerated().map { (cuts.contains($0.offset) ? "-" : "") + String($0.element) }.joined()
                object["id"] = id
                let destination = target.appendingPathComponent(kind, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                if kind == "reports" {
                    guard (try? JSONDecoder.nodus.decode(LocalReportStore.Saved.self, from: bytes)) != nil else { throw RecoveryError.malformedDocument }
                    for key in ["sentAt", "outboxId", "vaultRowId"] { object.removeValue(forKey: key) }
                    if let image = object["imageFile"] as? String {
                        guard !image.contains("/"), !image.contains("\\"), ![".", ".."].contains(image) else { throw RecoveryError.unsafeFile }
                        let original = folder.appendingPathComponent(image)
                        guard try original.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw RecoveryError.unsafeFile }
                        let name = id + "." + original.pathExtension
                        try Data(contentsOf: original).write(to: destination.appendingPathComponent(name), options: .atomic)
                        object["imageFile"] = name
                    }
                } else {
                    guard (try? JSONDecoder.nodus.decode(ChatHistoryStore.Conversation.self, from: bytes)) != nil else { throw RecoveryError.malformedDocument }
                }
                let output = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
                try output.write(to: destination.appendingPathComponent(id + ".json"), options: .atomic)
                receipts[fingerprint] = id
                try JSONEncoder().encode(receipts).write(to: receiptURL, options: .atomic)
                recovered += 1
            }
        }
        LocalReportStore.reloadAll()
        return recovered
    }
}
