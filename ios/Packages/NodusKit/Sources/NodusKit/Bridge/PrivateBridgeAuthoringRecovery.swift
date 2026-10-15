import CryptoKit
import Foundation
import Security

/// Revoked reading copies are disposable. Locally authored state remains encrypted and
/// is adopted only after a new pinned link proves the same Mac and owning vaults.
public actor PrivateBridgeAuthoringRecovery {
    public static let shared = PrivateBridgeAuthoringRecovery()
    public struct ExternalRecord: Codable, Sendable {
        let filename: String
        let ciphertextSHA256: String
        let byteCount: Int
    }
    /// Only in-memory snapshots carry this reader; keys and filesystem paths are
    /// never serialized into an archive or exported to another application.
    struct RecordSource: Sendable { let read: @Sendable () throws -> Data }
    public struct Record: Codable, Sendable {
        public let filename: String
        public let vaultId: String?
        public let data: Data
        public let ledger: Bool
        public let writing: Bool
        public let recordId: String?
        public let generationKind: String?
        let external: ExternalRecord?
        var source: RecordSource? = nil
        enum CodingKeys: String, CodingKey { case filename, vaultId, data, ledger, writing, recordId, generationKind, external }
        init(filename: String, vaultId: String?, data: Data, ledger: Bool, writing: Bool, recordId: String?, generationKind: String?, external: ExternalRecord? = nil, source: RecordSource? = nil) {
            self.filename = filename; self.vaultId = vaultId; self.data = data; self.ledger = ledger; self.writing = writing
            self.recordId = recordId; self.generationKind = generationKind; self.external = external; self.source = source
        }
        func materializedData() throws -> Data { try source?.read() ?? data }
        func replacing(data: Data, external: ExternalRecord? = nil, source: RecordSource? = nil) -> Record {
            Record(filename: filename, vaultId: vaultId, data: data, ledger: ledger, writing: writing, recordId: recordId, generationKind: generationKind, external: external, source: source)
        }
    }
    public struct Snapshot: Sendable {
        public let records: [Record]
        public let fingerprints: [String: String]
        let requiredAuthoringFilenames: Set<String>
        init(records: [Record], fingerprints: [String: String], requiredAuthoringFilenames: Set<String>? = nil) {
            self.records = records; self.fingerprints = fingerprints
            self.requiredAuthoringFilenames = requiredAuthoringFilenames ?? Set(records.map(\.filename))
        }
        public func selectingVaults(_ vaults: Set<String>) -> Snapshot {
            Snapshot(records: records.filter { $0.vaultId.map(vaults.contains) ?? false }, fingerprints: fingerprints,
                requiredAuthoringFilenames: requiredAuthoringFilenames)
        }
    }
    public struct Receipt: Sendable {
        let pairingId: String
        let archiveURL: URL
        let digest: String
        let recoveryKeyName: String
        let fingerprints: [String: String]
        let archivedFilenames: Set<String>
        let completeAuthoringInventory: Bool
        var externalFingerprints: [String: String] = [:]
        func validates(pairingId: String, folder: URL) throws -> Bool {
            guard self.pairingId == pairingId, FileManager.default.fileExists(atPath: archiveURL.path),
                  Self.hash(try Data(contentsOf: archiveURL)) == digest else { return false }
            for (filename, expected) in externalFingerprints {
                let records = archiveURL.deletingPathExtension().appendingPathExtension("records")
                guard PrivateBridgeAuthoringRecovery.validFilename(filename),
                      Self.hash(try Data(contentsOf: records.appendingPathComponent(filename))) == expected else { return false }
            }
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
        var records: [Record]
        var adoptedBy: [String: Set<String>] = [:]
        var revoked = false
        var forceReview: Bool? = nil
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
    public static var defaultDirectory: URL {
#if DEBUG
        if let raw = ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_AUTHORING_RECOVERY"], let id = UUID(uuidString: raw) {
            return URL.applicationSupportDirectory.appendingPathComponent("AcceptanceLab/recovery-" + id.uuidString, isDirectory: true)
        }
#endif
        return URL.applicationSupportDirectory.appendingPathComponent("NodusAuthoringRecovery", isDirectory: true)
    }
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
        guard [1, 2].contains(value.version), value.id == id, !value.vaultIds.isEmpty,
              Set(value.records.map(\.filename)).count == value.records.count,
              value.records.allSatisfy({ record in
                  guard Self.validFilename(record.filename) else { return false }
                  if let external = record.external {
                      return value.version == 2 && external.filename == record.filename && external.byteCount >= 0 && external.ciphertextSHA256.count == 64 && record.data.isEmpty
                          && FileManager.default.fileExists(atPath: recordsURL(id).appendingPathComponent(external.filename).path)
                  }
                  return value.version == 1
              }) else { throw RecoveryError.invalidArchive }
        return value
    }
    private func recordsURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".records", isDirectory: true) }
    private func lazyRecord(_ record: Record, archiveID: UUID, resolvedKey: SymmetricKey? = nil) throws -> Record {
        guard let external = record.external else { return record }
        let url = recordsURL(archiveID).appendingPathComponent(external.filename), archiveKey = try resolvedKey ?? key(archiveID)
        return record.replacing(data: Data(), source: RecordSource {
            let ciphertext = try Data(contentsOf: url)
            guard Self.hash(ciphertext) == external.ciphertextSHA256 else { throw RecoveryError.invalidArchive }
            let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: archiveKey)
            guard bytes.count == external.byteCount else { throw RecoveryError.invalidArchive }
            return bytes
        })
    }
    private func write(_ archive: Archive) throws -> Data {
        guard let bytes = try AES.GCM.seal(JSONEncoder.nodus.encode(archive), using: key(archive.id)).combined else { throw RecoveryError.invalidArchive }
        try PrivateBridgeProtectedFile.write(bytes, to: archiveURL(archive.id))
        BackupPolicy.apply(.excluded, to: archiveURL(archive.id)); return bytes
    }
    private func archives() throws -> [Archive] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "authoring" }.map {
            guard let id = UUID(uuidString: $0.deletingPathExtension().lastPathComponent) else { throw RecoveryError.invalidArchive }
            return try read(id)
        }.sorted { $0.createdAt > $1.createdAt }
    }
    public func preserve(snapshot: Snapshot, pairing: DesktopBridgePairing, macDeviceId: String?, forceReview: Bool = false) throws -> Receipt {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        BackupPolicy.apply(.excluded, to: directory)
        let id = UUID(); var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw RecoveryError.recoveryRequired }
        try keychain.set(Data(bytes).base64EncodedString(), for: keyName(id))
        do {
            let archiveKey = try key(id)
            try FileManager.default.createDirectory(at: recordsURL(id), withIntermediateDirectories: false)
            BackupPolicy.apply(.excluded, to: recordsURL(id))
            var saved: [Record] = [], externalHashes: [String: String] = [:]
            for record in snapshot.records {
                guard Self.validFilename(record.filename), externalHashes[record.filename] == nil else { throw RecoveryError.invalidArchive }
                let data = try record.materializedData()
                guard let ciphertext = try AES.GCM.seal(data, using: archiveKey).combined else { throw RecoveryError.invalidArchive }
                try PrivateBridgeProtectedFile.write(ciphertext, to: recordsURL(id).appendingPathComponent(record.filename))
                let hash = Self.hash(ciphertext)
                externalHashes[record.filename] = hash
                saved.append(record.replacing(data: Data(), external: ExternalRecord(filename: record.filename, ciphertextSHA256: hash, byteCount: data.count)))
            }
            let archive = Archive(version: 2, id: id, sourcePairingId: pairing.id, macDeviceId: macDeviceId, fingerprint: pairing.certificateFingerprint,
                                  vaultIds: pairing.vaultIds, createdAt: Date(), records: saved, forceReview: forceReview ? true : nil)
            let encrypted = try write(archive)
            let reopened = try read(id)
            for record in reopened.records { _ = try lazyRecord(record, archiveID: id, resolvedKey: archiveKey).materializedData() }
            return Receipt(pairingId: pairing.id, archiveURL: archiveURL(id), digest: Self.hash(encrypted), recoveryKeyName: keyName(id), fingerprints: snapshot.fingerprints, archivedFilenames: Set(snapshot.records.map(\.filename)), completeAuthoringInventory: snapshot.requiredAuthoringFilenames.isSubset(of: Set(snapshot.records.map(\.filename))), externalFingerprints: externalHashes)
        } catch {
            try? keychain.remove(keyName(id)); try? FileManager.default.removeItem(at: archiveURL(id))
            try? FileManager.default.removeItem(at: recordsURL(id)); throw error
        }
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
                record.generationKind != "legacySurfaceStorage" && record.generationKind != "mutationOutbox" && !previous.contains(record.filename) && (record.vaultId.map { pairing.vaultIds.contains($0) } ?? archive.vaultIds.isSubset(of: pairing.vaultIds))
            }
            guard !selected.isEmpty else { continue }
            let archiveKey = try key(archive.id)
            let lazy = try selected.map { try lazyRecord($0, archiveID: archive.id, resolvedKey: archiveKey) }
            try await cache.adoptAuthoringRecovery(lazy, requiresReview: archive.sourcePairingId != pairing.id || archive.forceReview == true)
            archive.adoptedBy[pairing.id] = previous.union(selected.map(\.filename))
            _ = try write(archive); count += selected.count
        }
        return count
    }
    /// Device-local export remains reachable without any surviving connection or credential.
    public func allSummaries() throws -> [ArchiveInfo] {
        try archives().filter { !$0.records.isEmpty }.map {
            ArchiveInfo(id: $0.id, createdAt: $0.createdAt, recordCount: $0.records.count,
                macIdentityKnown: $0.macDeviceId != nil, adopted: !$0.adoptedBy.isEmpty)
        }
    }
    public func summaries(macDeviceId: String?, pairingId: String) throws -> [ArchiveInfo] {
        try archives().filter { $0.macDeviceId == nil || $0.macDeviceId == macDeviceId }.map {
            ArchiveInfo(id: $0.id, createdAt: $0.createdAt, recordCount: $0.records.count, macIdentityKnown: $0.macDeviceId != nil, adopted: !($0.adoptedBy[pairingId] ?? []).isEmpty)
        }
    }
    /// User-selected export of authored state, not a credential or a private reading cache.
    public func export(id: UUID) throws -> Data {
        var archive = try read(id)
        guard !archive.records.contains(where: { $0.generationKind == "databaseFileChunk" }) else { throw RecoveryError.recoveryRequired }
        let archiveKey = try key(id)
        archive.records = try archive.records.map { record in record.replacing(data: try lazyRecord(record, archiveID: id, resolvedKey: archiveKey).materializedData()) }
        archive.version = 1
        return try JSONEncoder.nodus.encode(archive)
    }
    /// JSON remains the established format for document-only work. Archives with
    /// authored files export a bounded streaming ZIP plus the same structured JSON.
    public func exportFile(id: UUID, progress: Progress? = nil) throws -> PrivateBridgeFileLease {
        var archive = try read(id)
        let archiveKey = try key(id)
        let lazy = try archive.records.map { try lazyRecord($0, archiveID: id, resolvedKey: archiveKey) }
        guard lazy.contains(where: { $0.generationKind == "databaseFile" }) else {
            return try PrivateBridgeFileLease.write(export(id: id), filename: "Nodus-local-work.json")
        }
        var chunks: [String: Record] = [:]
        for record in lazy where record.generationKind == "databaseFileChunk" {
            guard let vault = record.vaultId, let recordId = record.recordId else { throw RecoveryError.invalidArchive }
            chunks[vault + "\u{1f}" + recordId] = record
        }
        var entries: [ZIPArchiveBuilder.StreamingEntry] = [], exportedFiles: [JSONValue] = []
        for record in lazy where record.generationKind == "databaseFile" {
            let transfer = try JSONDecoder.nodus.decode(CompanionDatabaseAttachments.Transfer.self, from: record.materializedData())
            guard record.vaultId == transfer.vaultId else { throw RecoveryError.invalidArchive }
            let complete = transfer.importedBytes == transfer.byteCount
            let filename = String(Self.hash(Data((transfer.vaultId + transfer.id.uuidString).utf8)).prefix(12)) + "-" + transfer.filename + (complete ? "" : ".partial")
            let source = try RecoveryFileReader(transfer: transfer, records: chunks)
            entries.append(.init(filename: filename, byteCount: transfer.importedBytes, read: { try source.read(offset: $0, count: $1) }))
            exportedFiles.append(.object(["recordId": .string(CompanionDatabaseAttachments.recordId(transfer.id)), "vaultId": .string(transfer.vaultId),
                "filename": .string(filename), "bytes": .int(transfer.importedBytes), "complete": .bool(complete)]))
        }
        archive.records = try lazy.filter { $0.generationKind != "databaseFileChunk" }.map { $0.replacing(data: try $0.materializedData()) }
        archive.version = 1
        var document = try JSONDecoder.nodus.decode(JSONValue.self, from: JSONEncoder.nodus.encode(archive)).objectValue!
        document["files"] = .array(exportedFiles)
        let metadata = try JSONEncoder.nodus.encode(JSONValue.object(document))
        entries.append(.init(filename: "Nodus-local-work.json", byteCount: Int64(metadata.count), read: { offset, count in
            metadata.subdata(in: Int(offset)..<(Int(offset) + count))
        }))
        let reservation = try ZIPArchiveBuilder.streamingReservation(entries: entries)
        // Export is explicitly requested authored work, not a reading-cache download.
        // Reserve temporary disk before writing; the encrypted originals remain intact.
        return try PrivateBridgeFileLease.create(filename: "Nodus-local-work.zip", reservedBytes: reservation, limitBytes: Int.max) { url in
            try ZIPArchiveBuilder.buildStreaming(entries: entries, at: url, progress: progress)
        }
    }

    static let savedResultMethods: Set<String> = ["saveMobileAcademicResult", "saveDictionaryGeneratedVersion", "saveStudyImprovementFromMobile", "saveMobileDatabaseResearchReport", "saveWritingWorkshopFromMobile", "saveImmersionGeneratedSession", "saveContentTranslationFromMobile", "saveMobileWorldMapImage", "saveMobileDeepResearchReport", "saveMobileDatabaseGeneratedCell", "saveMobileDatabaseButtonResult"]
    public nonisolated static func publicationForReview(_ request: DesktopJobLedger.Request) throws -> CompanionGenerationPublication? {
        guard request.state == "recoveryReview", let checkpoint = request.checkpoint,
              let fields = checkpoint.objectValue, let original = fields["request"]?.objectValue else { return nil }
        if request.method == "saveMobileDatabaseGeneratedCell" || request.method == "saveMobileDatabaseButtonResult" || fields["recoveryGenerationKind"] == .string("databaseAction") {
            return try CompanionGenerationPublication(databaseAction: CompanionDatabaseActionCheckpoint(checkpoint))
        }
        let kinds = ["saveMobileAcademicResult": "academic", "localAcademicGeneration": "academic", "saveDictionaryGeneratedVersion": "dictionary", "saveStudyImprovementFromMobile": "writing", "saveMobileDatabaseResearchReport": "database", "saveMobileDeepResearchReport": "deepResearch", "saveWritingWorkshopFromMobile": "workshop", "localWorkshopGeneration": "workshop", "saveImmersionGeneratedSession": "immersion", "saveContentTranslationFromMobile": "translation"]
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
        if kind == "databaseAction" {
            let parsed = try CompanionDatabaseActionCheckpoint(value)
            if requiresReview { fields["recoveryReviewRequired"] = .bool(true) }
            let checkpoint = JSONValue.object(fields)
            if let publication = try CompanionGenerationPublication(databaseAction: parsed) {
                return DesktopJobLedger.Request(id: id, method: publication.method, args: publication.args, createdAt: created,
                    jobId: nil, state: requiresReview ? "recoveryReview" : "pending", issue: requiresReview ? "Revisa el resultado antes de guardarlo en el Mac." : nil,
                    checkpointRecordId: recordId, checkpoint: checkpoint)
            }
            return DesktopJobLedger.Request(id: id, method: "localDatabaseAction", args: [], createdAt: created, jobId: nil,
                state: "recoveryReview", issue: "Trabajo anterior conservado para consulta.", checkpointRecordId: recordId, checkpoint: checkpoint)
        }
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
        if record.generationKind == "databaseFile", var fields = value.objectValue {
            fields["recoveryReviewRequired"] = .bool(true)
            return try JSONEncoder.nodus.encode(JSONValue.object(fields))
        }
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
            object["workspaceOrganizationSnapshot"] = nil
            for key in ["records", "studyCommands", "annotationCommands", "workspaceOrganizationCommands"] { if let rows = object[key] { object[key] = blocked(rows) } }
            value = .object(object)
        } else { value = blocked(value) }
        return try JSONEncoder.nodus.encode(value)
    }
}

/// Keeps at most one decoded 512 KiB chunk while ZIPFoundation asks for 64 KiB
/// blocks. Each chunk and the complete original hash are checked before sharing.
private final class RecoveryFileReader: @unchecked Sendable {
    private let lock = NSLock()
    private let transfer: CompanionDatabaseAttachments.Transfer
    private let chunks: [PrivateBridgeAuthoringRecovery.Record]
    private var cachedIndex = -1
    private var cached = Data()
    private var offset: Int64 = 0
    private var sha = SHA256()
    init(transfer: CompanionDatabaseAttachments.Transfer, records: [String: PrivateBridgeAuthoringRecovery.Record]) throws {
        self.transfer = transfer
        if transfer.byteCount == 0, let expected = transfer.sha256 {
            guard expected == PrivateBridgeAuthoringRecovery.hash(Data()) else { throw PrivateBridgeAuthoringRecovery.RecoveryError.invalidArchive }
        }
        chunks = try transfer.chunkHashes.indices.map { index in
            guard let record = records[transfer.vaultId + "\u{1f}" + CompanionDatabaseAttachments.chunkId(transfer.id, index)] else { throw PrivateBridgeAuthoringRecovery.RecoveryError.invalidArchive }
            return record
        }
    }
    func read(offset: Int64, count: Int) throws -> Data {
        try lock.withLock {
            guard offset == self.offset, count >= 0, Int64(count) <= transfer.importedBytes - offset else { throw PrivateBridgeAuthoringRecovery.RecoveryError.invalidArchive }
            var result = Data(), position = offset
            while result.count < count {
                let index = Int(position / Int64(CompanionDatabaseAttachments.chunkBytes))
                if cachedIndex != index {
                    let object = try JSONDecoder.nodus.decode(CompanionDatabaseAttachments.Chunk.self, from: chunks[index].materializedData())
                    guard object.version == 1, object.id == transfer.id, object.index == index,
                          let bytes = Data(base64Encoded: object.bytes), bytes.base64EncodedString() == object.bytes,
                          bytes.count == min(CompanionDatabaseAttachments.chunkBytes, Int(transfer.byteCount - Int64(index) * Int64(CompanionDatabaseAttachments.chunkBytes))),
                          PrivateBridgeAuthoringRecovery.hash(bytes) == transfer.chunkHashes[index] else { throw PrivateBridgeAuthoringRecovery.RecoveryError.invalidArchive }
                    cached = bytes; cachedIndex = index
                }
                let start = Int(position % Int64(CompanionDatabaseAttachments.chunkBytes)), length = min(count - result.count, cached.count - start)
                guard length > 0 else { throw PrivateBridgeAuthoringRecovery.RecoveryError.invalidArchive }
                result.append(cached.subdata(in: start..<(start + length))); position += Int64(length)
            }
            sha.update(data: result); self.offset = position
            if position == transfer.byteCount, let expected = transfer.sha256 {
                guard sha.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw PrivateBridgeAuthoringRecovery.RecoveryError.invalidArchive }
            }
            return result
        }
    }
}
