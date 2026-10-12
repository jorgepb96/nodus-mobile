import CryptoKit
import Foundation
import Security

/// Revoked reading copies are disposable. Locally authored state remains encrypted and
/// is adopted only after a new pinned link proves the same Mac and owning vaults.
public actor PrivateBridgeAuthoringRecovery {
    public static let shared = PrivateBridgeAuthoringRecovery()
    public struct Record: Codable, Sendable {
        public let filename: String
        public let vaultId: String?
        public let data: Data
        public let ledger: Bool
        public let writing: Bool
        public let recordId: String?
        public let generationKind: String?
    }
    public struct Snapshot: Sendable {
        public let records: [Record]
        public let fingerprints: [String: String]
    }
    public struct Receipt: Sendable {
        let pairingId: String
        let archiveURL: URL
        let digest: String
        let recoveryKeyName: String
        let fingerprints: [String: String]
        func validates(pairingId: String, folder: URL) throws -> Bool {
            guard self.pairingId == pairingId, FileManager.default.fileExists(atPath: archiveURL.path),
                  Self.hash(try Data(contentsOf: archiveURL)) == digest else { return false }
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "bridgecache" && !$0.lastPathComponent.hasPrefix("read-") }
            return files.count == fingerprints.count && files.allSatisfy { url in
                (try? Self.hash(Data(contentsOf: url))) == fingerprints[url.lastPathComponent]
            }
        }
        private static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    }
    public struct ArchiveInfo: Identifiable, Sendable {
        public let id: UUID
        public let createdAt: Date
        public let recordCount: Int
        public let macIdentityKnown: Bool
        public let adopted: Bool
    }
    private struct Archive: Codable {
        var version = 1
        let id: UUID
        let sourcePairingId: String
        let macDeviceId: String?
        let fingerprint: String
        let vaultIds: Set<String>
        let createdAt: Date
        let records: [Record]
        var adoptedBy: [String: Set<String>] = [:]
        var revoked = false
    }
    public enum RecoveryError: Error, LocalizedError {
        case unclassifiedWork, recoveryRequired, revokedWrites, invalidArchive, activeGeneration
        public var errorDescription: String? {
            switch self {
            case .unclassifiedWork: "Hay trabajo local de una versión anterior que debe recuperarse antes de desvincular este Mac. No se ha borrado."
            case .recoveryRequired: "No se ha podido conservar todo el trabajo local. La conexión sigue disponible y no se ha borrado ningún borrador."
            case .revokedWrites: "Este enlace se está cerrando. El trabajo guardado se conserva para recuperarlo al volver a enlazar."
            case .activeGeneration: "Hay una generación en curso. Espera a que se guarde su resultado antes de desvincular o reemplazar este enlace."
            case .invalidArchive: "No se ha podido abrir el archivo de trabajo conservado. El original sigue guardado."
            }
        }
    }
    public static var defaultDirectory: URL { URL.applicationSupportDirectory.appendingPathComponent("NodusAuthoringRecovery", isDirectory: true) }
    private let directory: URL
    private let keychain: KeychainStore
    public init(directory: URL = PrivateBridgeAuthoringRecovery.defaultDirectory, keychain: KeychainStore = KeychainStore()) {
        self.directory = directory; self.keychain = keychain
    }
    private func keyName(_ id: UUID) -> String { "private-bridge-authoring-recovery-\(id.uuidString)" }
    private func archiveURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".authoring") }
    private func key(_ id: UUID) throws -> SymmetricKey {
        guard let encoded = keychain.value(for: keyName(id)), let bytes = Data(base64Encoded: encoded), bytes.count == 32 else { throw RecoveryError.invalidArchive }
        return SymmetricKey(data: bytes)
    }
    private func read(_ id: UUID) throws -> Archive {
        let value = try JSONDecoder.nodus.decode(Archive.self, from: AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: archiveURL(id))), using: key(id)))
        guard value.version == 1, value.id == id, !value.vaultIds.isEmpty,
              value.records.allSatisfy({ Self.validFilename($0.filename) }) else { throw RecoveryError.invalidArchive }
        return value
    }
    private func write(_ archive: Archive) throws -> Data {
        guard let bytes = try AES.GCM.seal(JSONEncoder.nodus.encode(archive), using: key(archive.id)).combined else { throw RecoveryError.invalidArchive }
        try bytes.write(to: archiveURL(archive.id), options: [.atomic, .completeFileProtection])
        BackupPolicy.apply(.excluded, to: archiveURL(archive.id)); return bytes
    }
    private func archives() throws -> [Archive] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "authoring" }.map {
            guard let id = UUID(uuidString: $0.deletingPathExtension().lastPathComponent) else { throw RecoveryError.invalidArchive }
            return try read(id)
        }.sorted { $0.createdAt > $1.createdAt }
    }
    public func preserve(snapshot: Snapshot, pairing: DesktopBridgePairing, macDeviceId: String?) throws -> Receipt {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        BackupPolicy.apply(.excluded, to: directory)
        let id = UUID(); var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw RecoveryError.recoveryRequired }
        try keychain.set(Data(bytes).base64EncodedString(), for: keyName(id))
        do {
            let archive = Archive(id: id, sourcePairingId: pairing.id, macDeviceId: macDeviceId, fingerprint: pairing.certificateFingerprint,
                                  vaultIds: pairing.vaultIds, createdAt: Date(), records: snapshot.records)
            let encrypted = try write(archive)
            _ = try read(id) // Readback proves the complete archive and its key before destructive revocation.
            return Receipt(pairingId: pairing.id, archiveURL: archiveURL(id), digest: Self.hash(encrypted), recoveryKeyName: keyName(id), fingerprints: snapshot.fingerprints)
        } catch { try? keychain.remove(keyName(id)); try? FileManager.default.removeItem(at: archiveURL(id)); throw error }
    }
    public func completeRevocation(_ receipt: Receipt) throws {
        guard let id = UUID(uuidString: receipt.archiveURL.deletingPathExtension().lastPathComponent), receipt.archiveURL == archiveURL(id) else { throw RecoveryError.invalidArchive }
        var archive = try read(id)
        guard archive.sourcePairingId == receipt.pairingId else { throw RecoveryError.invalidArchive }
        archive.revoked = true; _ = try write(archive)
    }
    public func discard(_ receipt: Receipt) throws {
        guard let id = UUID(uuidString: receipt.archiveURL.deletingPathExtension().lastPathComponent), receipt.archiveURL == archiveURL(id) else { throw RecoveryError.invalidArchive }
        try FileManager.default.removeItem(at: archiveURL(id)); try keychain.remove(keyName(id))
    }
    /// A new grant does not inherit permission to automatically replay old scoped receipts.
    @discardableResult
    public func adopt(pairing: DesktopBridgePairing, macDeviceId: String, cache: PrivateBridgeCache) async throws -> Int {
        guard !pairing.isExpired, pairing.domains.contains(.writing) else { return 0 }
        var count = 0
        for var archive in try archives() where archive.revoked && archive.macDeviceId == macDeviceId && archive.fingerprint == pairing.certificateFingerprint {
            let previous = archive.adoptedBy[pairing.id] ?? []
            let selected = archive.records.filter { record in
                !previous.contains(record.filename) && (record.vaultId.map { pairing.vaultIds.contains($0) } ?? archive.vaultIds.isSubset(of: pairing.vaultIds))
            }
            guard !selected.isEmpty else { continue }
            try await cache.adoptAuthoringRecovery(selected, requiresReview: archive.sourcePairingId != pairing.id)
            archive.adoptedBy[pairing.id] = previous.union(selected.map(\.filename))
            _ = try write(archive); count += selected.count
        }
        return count
    }
    public func summaries(macDeviceId: String?, pairingId: String) throws -> [ArchiveInfo] {
        try archives().filter { $0.macDeviceId == nil || $0.macDeviceId == macDeviceId }.map {
            ArchiveInfo(id: $0.id, createdAt: $0.createdAt, recordCount: $0.records.count, macIdentityKnown: $0.macDeviceId != nil, adopted: !($0.adoptedBy[pairingId] ?? []).isEmpty)
        }
    }
    /// User-selected export of authored state, not a credential or a private reading cache.
    public func export(id: UUID) throws -> Data { try JSONEncoder.nodus.encode(read(id)) }
    static let savedResultMethods: Set<String> = ["saveMobileAcademicResult", "saveDictionaryGeneratedVersion", "saveStudyImprovementFromMobile", "saveMobileDatabaseResearchReport", "saveWritingWorkshopFromMobile", "saveImmersionGeneratedSession", "saveContentTranslationFromMobile", "saveMobileWorldMapImage"]
    public nonisolated static func publicationForReview(_ request: DesktopJobLedger.Request) throws -> CompanionGenerationPublication? {
        guard request.state == "recoveryReview", let checkpoint = request.checkpoint,
              let fields = checkpoint.objectValue, let original = fields["request"]?.objectValue else { return nil }
        let kinds = ["saveMobileAcademicResult": "academic", "localAcademicGeneration": "academic", "saveDictionaryGeneratedVersion": "dictionary", "saveStudyImprovementFromMobile": "writing", "saveMobileDatabaseResearchReport": "database", "saveWritingWorkshopFromMobile": "workshop", "localWorkshopGeneration": "workshop", "saveImmersionGeneratedSession": "immersion", "saveContentTranslationFromMobile": "translation"]
        guard let kind = kinds[request.method] ?? fields["recoveryGenerationKind"]?.stringValue, let entity = kind == "dictionary" ? original["entryId"]?.stringValue : fields["entityKey"]?.stringValue else { return nil }
        return try CompanionGenerationPublication(kind: kind, entity: entity, checkpoint: checkpoint)
    }
    public nonisolated static func canReviewResult(_ request: DesktopJobLedger.Request) -> Bool {
        guard request.state == "recoveryReview", request.checkpoint != nil else { return false }
        if savedResultMethods.contains(request.method), !request.args.isEmpty { return true }
        return (try? publicationForReview(request)) != nil
    }
    private nonisolated static func completeCheckpoint(_ value: JSONValue, kind: String, entity: String) -> JSONValue {
        guard var fields = value.objectValue else { return value }
        fields["recoveryGenerationKind"] = .string(kind)
        if fields["state"] != .string("saved"), fields["state"] != .string("available") {
            var saved = fields; saved["state"] = .string("saved")
            if (try? CompanionGenerationPublication(kind: kind, entity: entity, checkpoint: .object(saved))) != nil { fields = saved }
        }
        return .object(fields)
    }
    nonisolated static func recoveredRequest(_ record: Record, requiresReview: Bool) throws -> DesktopJobLedger.Request? {
        guard let kind = record.generationKind, let recordId = record.recordId,
              var fields = try JSONDecoder.nodus.decode(JSONValue.self, from: record.data).objectValue,
              let id = fields["id"]?.stringValue, UUID(uuidString: id) != nil else { return nil }
        let created = fields["createdAt"].flatMap { Row(["date": $0]).date("date") } ?? Date()
        var value = JSONValue.object(fields)
        let publication: CompanionGenerationPublication?
        if kind == "worldMap" {
            guard let input = try CompanionWorldMapGenerationCheckpoint(value).publicationInput else { return nil }
            if requiresReview { fields["recoveryReviewRequired"] = .bool(true) }
            return DesktopJobLedger.Request(id: id, method: "saveMobileWorldMapImage", args: [input], createdAt: created,
                jobId: nil, state: requiresReview ? "recoveryReview" : "pending", issue: requiresReview ? "Revisa el resultado antes de guardarlo en el Mac." : nil,
                checkpointRecordId: recordId, checkpoint: .object(fields))
        }
        let entity = kind == "dictionary" ? fields["request"]?.objectValue?["entryId"]?.stringValue : fields["entityKey"]?.stringValue
        guard let entity else { return nil }
        value = completeCheckpoint(value, kind: kind, entity: entity)
        if requiresReview, var object = value.objectValue { object["recoveryReviewRequired"] = .bool(true); value = .object(object) }
        publication = try? CompanionGenerationPublication(kind: kind, entity: entity, checkpoint: value)
        if let publication {
            return DesktopJobLedger.Request(id: id, method: publication.method, args: publication.args, createdAt: created, jobId: nil,
                state: requiresReview ? "recoveryReview" : "pending", issue: requiresReview ? "Revisa el resultado antes de guardarlo en el Mac." : nil,
                checkpointRecordId: recordId, checkpoint: value)
        }
        // Partial paid responses remain visible, but cannot start or publish a provider job.
        guard fields["raw"]?.stringValue?.isEmpty == false || fields["markdown"]?.stringValue?.isEmpty == false || fields["preview"] != nil else { return nil }
        return DesktopJobLedger.Request(id: id, method: "recoveredLocalResult", args: [], createdAt: created, jobId: nil,
            state: "recoveryReview", issue: "Resultado anterior conservado para consulta.", checkpointRecordId: recordId, checkpoint: value)
    }
    static func validFilename(_ name: String) -> Bool { name.hasPrefix("work-") && name.count == 81 && name.hasSuffix(".bridgecache") && name.dropFirst(5).prefix(64).allSatisfy(\.isHexDigit) }
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func reviewed(_ record: Record) throws -> Data {
        var value = try JSONDecoder.nodus.decode(JSONValue.self, from: record.data)
        func checkpoint(_ value: JSONValue, method: String? = nil) -> JSONValue {
            guard var fields = value.objectValue, fields["id"]?.stringValue != nil, fields["request"]?.objectValue != nil else { return value }
            fields["recoveryReviewRequired"] = .bool(true)
            let kind = record.generationKind ?? fields["kind"]?.stringValue
            let entity = kind == "dictionary" ? fields["request"]?.objectValue?["entryId"]?.stringValue : fields["entityKey"]?.stringValue
            if let kind, let entity { return completeCheckpoint(.object(fields), kind: kind, entity: entity) }
            return .object(fields)
        }
        if !record.writing && !record.ledger { return try JSONEncoder.nodus.encode(checkpoint(value)) }
        func blocked(_ rows: JSONValue) -> JSONValue {
            guard let entries = rows.objectValue else { return rows }
            return .object(entries.mapValues { row in
                guard var fields = row.objectValue, fields["state"] != nil else { return row }
                if record.ledger, let saved = fields["checkpoint"] { fields["checkpoint"] = checkpoint(saved) }
                let acknowledged = fields["state"] == .string("available") || (!record.ledger && fields["state"] == .string("saved"))
                if !acknowledged && fields["cancelled"] != .bool(true) {
                    fields["state"] = .string(record.ledger ? "recoveryReview" : "blocked")
                    fields["issue"] = .string("Trabajo recuperado. Revisa los cambios antes de enviarlos con esta conexión.")
                }
                return .object(fields)
            })
        }
        if record.ledger { value = blocked(value) }
        else if var object = value.objectValue, object["records"] != nil {
            for key in ["records", "studyCommands", "annotationCommands", "workspaceOrganizationCommands"] { if let rows = object[key] { object[key] = blocked(rows) } }
            value = .object(object)
        } else { value = blocked(value) }
        return try JSONEncoder.nodus.encode(value)
    }
}
