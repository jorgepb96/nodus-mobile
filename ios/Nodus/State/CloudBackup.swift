import Foundation
import Observation

/// An optional copy, in the user's own iCloud, of the things that exist only on this phone.
///
/// The device backup handles the ordinary case — a new phone restored from the old one comes back
/// with its conversations and its reports. This is for the cases it does not: a restore that skips
/// the app's container, two devices used at once, a phone that is lost rather than replaced. A
/// Deep Research report costs one model call per section; losing one is not an inconvenience, it
/// is money the user cannot get back.
///
/// **Off unless asked for, and that is not a formality.** An update that quietly started
/// uploading somebody's research would be a change to what the app is, made on their behalf. With
/// the switch off nothing here so much as constructs a CloudKit container — `transport` is not
/// made until the first time it is needed, which is what the test of that name checks.
///
/// **What travels.** Conversations (`ChatHistoryStore`) and reports generated on this device
/// (`LocalReportStore`), each as the file already on disk. Nothing else. Not provider API keys,
/// which stay in this device's Keychain and which `ConnectView` promises never leave it. Not
/// space tokens, which the server binds to one device on purpose. Not the offline mirror, which
/// is somebody else's publication and one tap re-downloads.
///
/// **Where it goes.** The private database of the user's own iCloud account. No Nodus server sees
/// any of it, and no other iCloud user can.
///
/// **How two devices disagree.** Every record carries the moment it was last written, and the
/// later one wins. A record that arrives older than the local file is not applied, and the local
/// file is queued to go up instead. Deleting deletes in both places; a delete that could not be
/// sent is remembered and retried, because an orphan in iCloud would come back on the next fetch
/// and undo a deletion the user meant.
///
/// A singleton, unlike the other state objects the root view owns, because the two stores that
/// feed it are not views: `LocalReportStore` is reached through a static cache and a
/// `ChatHistoryStore` is made by whichever screen needs one. It is also put in the environment,
/// so a settings screen reads it the way it reads everything else.
@Observable
@MainActor
final class CloudBackup {
    // Mobile 0.1.0 synchronises only through the linked Mac. Keep legacy CloudKit
    // code and local files recoverable, without opening or deleting cloud records.
    static let shared = CloudBackup(allowSync: false)

    enum Kind: String, Sendable, CaseIterable {
        case chat, report

        /// The CloudKit record type. Spelled out rather than derived from the case name: this is
        /// a schema somebody's account already holds, and renaming a Swift case must not silently
        /// orphan every record written under the old name.
        var recordType: String {
            switch self {
            case .chat: return "Conversation"
            case .report: return "Report"
            }
        }

        func fileURL(spaceId: String, id: String, root: URL) -> URL {
            switch self {
            case .chat: return ChatHistoryStore.fileURL(spaceId: spaceId, id: id, root: root)
            case .report: return LocalReportStore.fileURL(spaceId: spaceId, id: id, root: root)
            }
        }

        func directory(spaceId: String, root: URL) -> URL {
            switch self {
            case .chat: return ChatHistoryStore.directory(spaceId: spaceId, root: root)
            case .report: return LocalReportStore.directory(spaceId: spaceId, root: root)
            }
        }
    }

    enum Status: Equatable {
        case off
        case working
        case ready(Date?)
        case failed(String)
    }

    private(set) var isEnabled: Bool
    private(set) var status: Status
    /// When the last fetch finished. Screens that hold their own store watch this and read the
    /// folder again, which is how a report written on the iPad appears in an open library.
    private(set) var lastFetchedAt: Date?

    private let defaults: UserDefaults
    private let root: URL
    private let makeTransport: @Sendable () -> any CloudRecordTransport
    private let allowSync: Bool
    private var transport: (any CloudRecordTransport)?

    private enum Key {
        // Plain `UserDefaults`, deliberately not `SyncedDefaults`. Switching this on is a
        // decision about one device's data leaving it, and having that decision arrive on the
        // user's other phone by itself would be the app turning the feature on for them.
        static let enabled = "nodus.cloud.enabled"
        static let token = "nodus.cloud.token"
        static let needsFullPush = "nodus.cloud.needsFullPush"
        static let pendingDeletions = "nodus.cloud.pendingDeletions"
    }

    init(
        defaults: UserDefaults = .standard,
        root: URL = .applicationSupportDirectory,
        allowSync: Bool = false,
        makeTransport: @escaping @Sendable () -> any CloudRecordTransport = { CloudKitTransport() }
    ) {
        self.defaults = defaults
        self.root = root
        self.makeTransport = makeTransport
        self.allowSync = allowSync
        isEnabled = allowSync && defaults.bool(forKey: Key.enabled)
        status = isEnabled ? .ready(nil) : .off
    }

    // MARK: - The switch

    func setEnabled(_ wanted: Bool) async {
        guard allowSync else { return }
        guard wanted != isEnabled else { return }
        isEnabled = wanted
        defaults.set(wanted, forKey: Key.enabled)
        wanted ? await start() : await stop()
    }

    private func start() async {
        status = .working
        do {
            try await connection().prepare()
            // Fetch first, always. This device may be the second one to be switched on, and
            // sending everything it has before looking would overwrite records written on the
            // first with whatever this one happens to hold.
            try await fetch()
            try await sendEverything()
            status = .ready(lastFetchedAt)
        } catch {
            status = .failed(error.localizedDescription)
            defaults.set(true, forKey: Key.needsFullPush)
        }
    }

    /// Switching off is not "stop uploading". It is "take back what was uploaded".
    private func stop() async {
        status = .working
        try? await connection().removeEverything()
        defaults.removeObject(forKey: Key.token)
        defaults.removeObject(forKey: Key.needsFullPush)
        defaults.removeObject(forKey: Key.pendingDeletions)
        transport = nil
        status = .off
    }

    // MARK: - One record at a time

    /// A file has just been written; put it in iCloud too.
    ///
    /// Returns immediately. Nothing the user does waits on the network, and a save that could not
    /// be uploaded is not a save that failed — it is one that will go up with the next full pass.
    func record(
        _ kind: Kind,
        spaceId: String,
        id: String,
        document: URL,
        illustration: URL? = nil,
        illustrationName: String? = nil,
        updatedAt: Date
    ) {
        guard isEnabled else { return }
        let payload = CloudDocument(
            name: Self.recordName(kind, spaceId: spaceId, id: id),
            type: kind.recordType,
            spaceId: spaceId,
            localId: id,
            updatedAt: updatedAt,
            document: document,
            illustration: illustration,
            illustrationName: illustrationName
        )
        Task { await send([payload]) }
    }

    /// A file has just been deleted; delete the copy too.
    func forget(_ kind: Kind, spaceId: String, id: String) {
        guard isEnabled else { return }
        let name = Self.recordName(kind, spaceId: spaceId, id: id)
        Task { await deleteRemotely([name]) }
    }

    // MARK: - Whole passes

    /// Catch up with the other devices, and hand over anything they have not seen.
    func refresh() async {
        guard isEnabled else { return }
        status = .working
        do {
            try await drainPendingDeletions()
            try await fetch()
            if defaults.bool(forKey: Key.needsFullPush) {
                try await sendEverything()
                defaults.set(false, forKey: Key.needsFullPush)
            }
            status = .ready(lastFetchedAt)
        } catch CloudBackupFailure.zoneGone {
            // Somebody wiped this app's iCloud data — from another device, or from Settings.
            // Nothing local is lost; the next pass rebuilds the zone and uploads it all again.
            defaults.removeObject(forKey: Key.token)
            defaults.set(true, forKey: Key.needsFullPush)
            status = .failed(CloudBackupFailure.zoneGone.localizedDescription ?? "")
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func fetch() async throws {
        var more = true
        while more {
            let changes = try await connection().changes(since: defaults.data(forKey: Key.token))
            apply(changes)
            if let token = changes.token { defaults.set(token, forKey: Key.token) }
            more = changes.moreComing
        }
        lastFetchedAt = Date()
        // The library and any open chat read their folders again. Without this a report that
        // just arrived is on disk and invisible until the app is killed.
        LocalReportStore.reloadAll()
    }

    private func apply(_ changes: CloudChanges) {
        for incoming in changes.changed {
            guard let (kind, spaceId, id) = Self.parse(incoming.name) else { continue }
            let destination = kind.fileURL(spaceId: spaceId, id: id, root: root)
            if let mine = localChangeDate(kind, spaceId: spaceId, id: id), mine >= incoming.updatedAt {
                // This device holds the newer copy. Not applying it is half the answer; the
                // other half is making sure iCloud stops being wrong about it.
                if mine > incoming.updatedAt { defaults.set(true, forKey: Key.needsFullPush) }
                continue
            }
            guard let document = incoming.document else { continue }
            try? FileManager.default.createDirectory(
                at: kind.directory(spaceId: spaceId, root: root),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.moveItem(at: document, to: destination)
            // Same protection class as everything the stores write: readable by a background
            // task that resumes a run while the phone is locked, and unreadable before first
            // unlock.
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: destination.path
            )
            if let illustration = incoming.illustration, let name = incoming.illustrationName {
                let beside = kind.directory(spaceId: spaceId, root: root).appendingPathComponent(name)
                try? FileManager.default.removeItem(at: beside)
                try? FileManager.default.moveItem(at: illustration, to: beside)
            }
        }

        for name in changes.deleted {
            guard let (kind, spaceId, id) = Self.parse(name) else { continue }
            removeLocally(kind, spaceId: spaceId, id: id)
        }
    }

    /// Everything on this device, in batches.
    ///
    /// Batched because each record carries the whole document as an asset, and CloudKit refuses a
    /// request that is too large by rejecting the lot rather than the last one in.
    private func sendEverything() async throws {
        let documents = everythingOnDisk()
        for batch in stride(from: 0, to: documents.count, by: 20) {
            let slice = Array(documents[batch..<min(batch + 20, documents.count)])
            try await connection().save(slice)
        }
    }

    private func send(_ documents: [CloudDocument]) async {
        do {
            try await connection().save(documents)
            status = .ready(lastFetchedAt)
        } catch {
            // Remembered rather than retried here: the retry has to happen after a fetch, or a
            // device that was offline while another one wrote would push its stale copy over the
            // newer one. `refresh()` does them in that order.
            defaults.set(true, forKey: Key.needsFullPush)
            status = .failed(error.localizedDescription)
        }
    }

    private func deleteRemotely(_ names: [String]) async {
        do {
            try await connection().delete(names)
        } catch {
            // A deletion that never reaches iCloud is worse than one that is late: the record is
            // still there, and the next fetch would bring the file back.
            var pending = defaults.stringArray(forKey: Key.pendingDeletions) ?? []
            pending.append(contentsOf: names)
            defaults.set(Array(Set(pending)), forKey: Key.pendingDeletions)
            status = .failed(error.localizedDescription)
        }
    }

    private func drainPendingDeletions() async throws {
        let pending = defaults.stringArray(forKey: Key.pendingDeletions) ?? []
        guard !pending.isEmpty else { return }
        try await connection().delete(pending)
        defaults.removeObject(forKey: Key.pendingDeletions)
    }

    // MARK: - The disk

    private func everythingOnDisk() -> [CloudDocument] {
        let spacesDirectory = root.appendingPathComponent("spaces", isDirectory: true)
        let spaces = (try? FileManager.default.contentsOfDirectory(
            at: spacesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        var documents: [CloudDocument] = []
        for space in spaces {
            guard (try? space.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let spaceId = space.lastPathComponent
            for kind in Kind.allCases {
                let folder = kind.directory(spaceId: spaceId, root: root)
                let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                for file in files where file.pathExtension == "json" {
                    let id = file.deletingPathExtension().lastPathComponent
                    guard let updatedAt = localChangeDate(kind, spaceId: spaceId, id: id) else { continue }
                    let illustrationName = kind == .report ? illustrationName(spaceId: spaceId, id: id) : nil
                    documents.append(CloudDocument(
                        name: Self.recordName(kind, spaceId: spaceId, id: id),
                        type: kind.recordType,
                        spaceId: spaceId,
                        localId: id,
                        updatedAt: updatedAt,
                        document: file,
                        illustration: illustrationName.map { folder.appendingPathComponent($0) },
                        illustrationName: illustrationName
                    ))
                }
            }
        }
        return documents
    }

    /// When this device last changed its copy, read from the file rather than from a store.
    ///
    /// Nil when there is no file, which is how "iCloud has something I have never seen" is told
    /// apart from "iCloud has an older version of something I hold".
    private func localChangeDate(_ kind: Kind, spaceId: String, id: String) -> Date? {
        guard let data = try? Data(contentsOf: kind.fileURL(spaceId: spaceId, id: id, root: root)) else { return nil }
        switch kind {
        case .chat:
            return try? JSONDecoder.nodusReports.decode(ChatHistoryStore.Conversation.self, from: data).updatedAt
        case .report:
            return (try? JSONDecoder.nodusReports.decode(LocalReportStore.Saved.self, from: data))?.lastChangedAt
        }
    }

    private func illustrationName(spaceId: String, id: String) -> String? {
        guard let data = try? Data(contentsOf: Kind.report.fileURL(spaceId: spaceId, id: id, root: root)) else { return nil }
        return (try? JSONDecoder.nodusReports.decode(LocalReportStore.Saved.self, from: data))?.imageFile
    }

    private func removeLocally(_ kind: Kind, spaceId: String, id: String) {
        if kind == .report, let name = illustrationName(spaceId: spaceId, id: id) {
            try? FileManager.default.removeItem(
                at: kind.directory(spaceId: spaceId, root: root).appendingPathComponent(name)
            )
        }
        try? FileManager.default.removeItem(at: kind.fileURL(spaceId: spaceId, id: id, root: root))
    }

    // MARK: - Names

    /// `kind~space~id`, with both components percent-encoded.
    ///
    /// Reversible on purpose, and that is the whole design. CloudKit reports a deletion as a
    /// record name and nothing else — no type, no fields, because the record is gone. A hashed
    /// name would leave the app holding an identifier it cannot turn back into a file, so a
    /// conversation deleted on the iPad would stay on the phone forever. Percent-encoding keeps
    /// the name inside the ASCII CloudKit allows while staying an exact round trip.
    static func recordName(_ kind: Kind, spaceId: String, id: String) -> String {
        "\(kind.rawValue)~\(encode(spaceId))~\(encode(id))"
    }

    static func parse(_ name: String) -> (kind: Kind, spaceId: String, id: String)? {
        let parts = name.split(separator: "~", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let kind = Kind(rawValue: String(parts[0])),
              let spaceId = String(parts[1]).removingPercentEncoding,
              let id = String(parts[2]).removingPercentEncoding
        else { return nil }
        return (kind, spaceId, id)
    }

    private static func encode(_ value: String) -> String {
        // `.alphanumerics` rather than a URL character set: everything else, `~` and `%`
        // included, becomes `%XX`, so the separator can never appear inside a component and the
        // split above cannot be fooled by a space id that contains one.
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    // MARK: - Transport

    /// Made on first use, never before.
    ///
    /// This is what "with the switch off, not one call to CloudKit" rests on: every caller checks
    /// `isEnabled` first, so with the feature off nothing here ever runs and no container is
    /// constructed.
    private func connection() -> any CloudRecordTransport {
        if let transport { return transport }
        let made = makeTransport()
        transport = made
        return made
    }
}
