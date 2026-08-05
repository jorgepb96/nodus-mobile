import CloudKit
import Foundation

/// One document on its way to or from the user's own iCloud.
///
/// A document rather than a row: what travels is the file the app already wrote — a
/// conversation's JSON, a report's JSON and its illustration — not a re-modelled version of it.
/// That keeps one format on disk and in the cloud, so a record written by a newer build decodes
/// on an older one under exactly the rules `ChatHistoryStore` and `LocalReportStore` already
/// document, and a field added later cannot mean one thing locally and another remotely.
struct CloudDocument: Sendable, Equatable {
    /// The record's name, which is `kind~space~id` with both components percent-encoded.
    let name: String
    let type: String
    let spaceId: String
    let localId: String
    /// What the last-write-wins comparison is made on.
    let updatedAt: Date
    let document: URL
    let illustration: URL?
    /// The filename the illustration has beside its report, so the copy that lands on the other
    /// device is the one the report's own `imageFile` points at.
    let illustrationName: String?
}

/// What one round of asking iCloud "what changed?" came back with.
struct CloudChanges: Sendable {
    struct Incoming: Sendable {
        let name: String
        let updatedAt: Date
        let document: URL?
        let illustration: URL?
        let illustrationName: String?
    }

    var changed: [Incoming] = []
    /// Record names. Turning one back into a file is `CloudBackup`'s job, which is why the name
    /// is reversible rather than a hash.
    var deleted: [String] = []
    var token: Data?
    /// CloudKit pages its answers; the caller keeps asking until this is false.
    var moreComing = false
}

/// Everything this app asks of CloudKit, and nothing else.
///
/// Named as a protocol so the policy above it can be tested without an iCloud account, a network
/// or a signed build — and, more to the point, so "with the switch off nothing is sent" is a
/// thing a test can assert rather than a thing somebody reads in a diff and believes.
nonisolated protocol CloudRecordTransport: Sendable {
    /// Make sure there is somewhere to write. Also where a missing or restricted iCloud account
    /// is discovered, which is the common failure and deserves its own sentence.
    func prepare() async throws
    func save(_ documents: [CloudDocument]) async throws
    func delete(_ recordNames: [String]) async throws
    func changes(since token: Data?) async throws -> CloudChanges
    /// Everything this app ever uploaded, gone. What switching the feature off means.
    func removeEverything() async throws
}

/// Why a sync could not happen, in words a person can act on.
enum CloudBackupFailure: LocalizedError, Equatable {
    case noAccount
    case restricted
    /// The zone is not there any more — the user wiped this app's iCloud data from Settings, or
    /// another device turned the feature off. Not an error the user has to do anything about.
    case zoneGone

    var errorDescription: String? {
        switch self {
        case .noAccount:
            return String(localized: "Sign in to iCloud on this device to use this.")
        case .restricted:
            return String(localized: "iCloud is restricted on this device.")
        case .zoneGone:
            return String(localized: "The copy in iCloud was removed from another device.")
        }
    }
}

/// The real thing: one custom zone in the user's private database.
///
/// **Private, and only private.** Everything here goes to `privateCloudDatabase`, which is the
/// user's own iCloud storage. No Nodus server is involved, Apple's servers hold the bytes, and
/// nobody but the account holder can read them. That is the whole promise the settings screen
/// makes in one sentence, and it is kept by this line rather than by the sentence.
///
/// **A custom zone rather than the default one.** Not a preference: the default zone cannot be
/// asked what changed since last time. A custom zone can, which is what makes a deletion on the
/// iPad reach the phone at all — without it the phone would only ever learn about records that
/// still exist, and a conversation deleted on one device would come back on the other.
actor CloudKitTransport: CloudRecordTransport {
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let container: CKContainer
    private var zoneIsReady = false

    /// Where downloaded assets are copied to before anybody looks at them.
    ///
    /// CloudKit hands back a temporary file it is free to delete once the fetch is done, so the
    /// bytes are taken out of its hands immediately rather than at whatever moment the policy
    /// layer gets round to them.
    private let scratch: URL

    init(containerIdentifier: String = "iCloud.com.drakonis96.nodus.ios") {
        container = CKContainer(identifier: containerIdentifier)
        database = container.privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: "DeviceData", ownerName: CKCurrentUserDefaultName)
        scratch = URL.temporaryDirectory.appendingPathComponent("nodus-cloud", isDirectory: true)
    }

    func prepare() async throws {
        switch try await container.accountStatus() {
        case .available:
            break
        case .restricted:
            throw CloudBackupFailure.restricted
        case .noAccount, .couldNotDetermine, .temporarilyUnavailable:
            throw CloudBackupFailure.noAccount
        @unknown default:
            throw CloudBackupFailure.noAccount
        }
        guard !zoneIsReady else { return }
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        zoneIsReady = true
    }

    func save(_ documents: [CloudDocument]) async throws {
        guard !documents.isEmpty else { return }
        try await prepare()
        let records = documents.map { document -> CKRecord in
            let record = CKRecord(
                recordType: document.type,
                recordID: CKRecord.ID(recordName: document.name, zoneID: zoneID)
            )
            record["spaceId"] = document.spaceId
            record["localId"] = document.localId
            record["updatedAt"] = document.updatedAt
            record["document"] = CKAsset(fileURL: document.document)
            if let illustration = document.illustration {
                record["illustration"] = CKAsset(fileURL: illustration)
            }
            if let name = document.illustrationName {
                record["illustrationName"] = name
            }
            return record
        }
        // `.allKeys`, which overwrites whatever the server holds without arguing about change
        // tags. Safe because of the order the policy layer works in: a full upload only ever
        // happens after a fetch, so nothing this device sends is older than what it received,
        // and a single-record save carries something the user wrote here, seconds ago.
        let result = try await database.modifyRecords(
            saving: records,
            deleting: [],
            savePolicy: .allKeys,
            atomically: false
        )
        for outcome in result.saveResults.values {
            if case .failure(let error) = outcome { throw error }
        }
    }

    func delete(_ recordNames: [String]) async throws {
        guard !recordNames.isEmpty else { return }
        try await prepare()
        let ids = recordNames.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        let result = try await database.modifyRecords(saving: [], deleting: ids, atomically: false)
        for outcome in result.deleteResults.values {
            // A record that is already gone is the outcome that was wanted, not a failure: two
            // devices deleting the same conversation is a thing that happens.
            if case .failure(let error) = outcome, (error as? CKError)?.code != .unknownItem {
                throw error
            }
        }
    }

    func changes(since token: Data?) async throws -> CloudChanges {
        try await prepare()
        do {
            return try await fetch(since: token.flatMap(Self.decodeToken))
        } catch let error as CKError where error.code == .changeTokenExpired {
            // The server has forgotten how far this device had got — it prunes tokens after a
            // while. Asking again from nothing is the documented recovery, and it costs one
            // extra pass over records the device mostly already has.
            return try await fetch(since: nil)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            zoneIsReady = false
            throw CloudBackupFailure.zoneGone
        }
    }

    private func fetch(since token: CKServerChangeToken?) async throws -> CloudChanges {
        let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
        var changes = CloudChanges()
        changes.moreComing = result.moreComing
        changes.token = Self.encodeToken(result.changeToken)
        changes.deleted = result.deletions.map(\.recordID.recordName)
        for modification in result.modificationResultsByID.values {
            guard let record = try? modification.get().record else { continue }
            changes.changed.append(CloudChanges.Incoming(
                name: record.recordID.recordName,
                updatedAt: record["updatedAt"] as? Date ?? .distantPast,
                document: try take(record["document"] as? CKAsset, named: "\(record.recordID.recordName).json"),
                illustration: try take(record["illustration"] as? CKAsset, named: "\(record.recordID.recordName).asset"),
                illustrationName: record["illustrationName"] as? String
            ))
        }
        return changes
    }

    /// Copy a downloaded asset somewhere this app controls, before CloudKit takes it back.
    private func take(_ asset: CKAsset?, named name: String) throws -> URL? {
        guard let source = asset?.fileURL else { return nil }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let destination = scratch.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    func removeEverything() async throws {
        _ = try? await database.modifyRecordZones(saving: [], deleting: [zoneID])
        zoneIsReady = false
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Tokens

    private static func encodeToken(_ token: CKServerChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func decodeToken(_ data: Data) -> CKServerChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }
}
