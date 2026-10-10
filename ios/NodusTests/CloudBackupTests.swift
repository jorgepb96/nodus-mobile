import Foundation
import Testing
@testable import Nodus

/// The optional copy of chats and reports in the user's own iCloud.
///
/// Three things here are worth a test rather than a reading. That the feature is genuinely inert
/// when it is off — not "makes no requests" but "never builds a container", which is the only
/// version of that promise a user could check. That a device with the newer copy of a report
/// keeps it: last-write-wins is one line to write and the wrong way round half the time it is
/// written. And that a deletion is a deletion, because a conversation that comes back after being
/// thrown away is the single worst thing this feature could do.
@Suite("Cloud backup")
@MainActor
struct CloudBackupTests {
    @Test("mobile companion never enables legacy cloud sync or deletes existing cloud data")
    func companionKeepsCloudInert() async throws {
        let store = defaults("companion")
        store.set(true, forKey: "nodus.cloud.enabled")
        let ledger = Ledger()
        let backup = CloudBackup(defaults: store, root: try temporaryRoot(), makeTransport: {
            ledger.madeTransports += 1; return FakeTransport()
        })
        #expect(!backup.isEnabled)
        await backup.setEnabled(true)
        await backup.refresh()
        #expect(!backup.isEnabled)
        #expect(backup.status == .off)
        #expect(ledger.madeTransports == 0)
        #expect(store.bool(forKey: "nodus.cloud.enabled"), "Disabling this release's transport does not erase legacy records or preferences.")
    }
    /// Counts how many times a transport was asked for.
    ///
    /// `@unchecked Sendable` and a plain `var`: the factory that touches it is called from
    /// `connection()`, which is main-actor isolated, and so is every assertion below.
    private nonisolated final class Ledger: @unchecked Sendable {
        var madeTransports = 0
    }

    private actor FakeTransport: CloudRecordTransport {
        private(set) var calls: [String] = []
        private(set) var saved: [CloudDocument] = []
        private(set) var deleted: [String] = []
        private(set) var removedEverything = false
        private var staged: [CloudChanges] = []
        private var refuseDeletes = false

        func stage(_ changes: CloudChanges) { staged.append(changes) }
        func setRefusingDeletes(_ refuse: Bool) { refuseDeletes = refuse }

        func prepare() async throws { calls.append("prepare") }

        func save(_ documents: [CloudDocument]) async throws {
            calls.append("save")
            saved.append(contentsOf: documents)
        }

        func delete(_ recordNames: [String]) async throws {
            calls.append("delete")
            if refuseDeletes { throw CloudBackupFailure.noAccount }
            deleted.append(contentsOf: recordNames)
        }

        func changes(since token: Data?) async throws -> CloudChanges {
            calls.append("changes")
            return staged.isEmpty ? CloudChanges(token: Data("t".utf8)) : staged.removeFirst()
        }

        func removeEverything() async throws {
            calls.append("removeEverything")
            removedEverything = true
        }
    }

    private func temporaryRoot() throws -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func defaults(_ name: String) -> UserDefaults {
        let suite = "nodus.tests.cloud.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// A conversation on disk, written the way `ChatHistoryStore` writes one.
    @discardableResult
    private func writeChat(_ id: String, in root: URL, spaceId: String, updatedAt: Date, text: String) throws -> URL {
        let directory = ChatHistoryStore.directory(spaceId: spaceId, root: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let conversation = ChatHistoryStore.Conversation(
            id: id,
            title: text,
            messages: [],
            createdAt: updatedAt,
            updatedAt: updatedAt,
            isArchived: false
        )
        let url = directory.appendingPathComponent("\(id).json")
        try JSONEncoder.nodusReports.encode(conversation).write(to: url)
        return url
    }

    /// The same thing, but somewhere else — standing in for what iCloud hands back.
    private func stagedChat(_ id: String, spaceId: String, updatedAt: Date, text: String) throws -> URL {
        let scratch = try temporaryRoot()
        return try writeChat(id, in: scratch, spaceId: spaceId, updatedAt: updatedAt, text: text)
    }

    private func chatTitle(_ id: String, in root: URL, spaceId: String) -> String? {
        let url = ChatHistoryStore.fileURL(spaceId: spaceId, id: id, root: root)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.nodusReports.decode(ChatHistoryStore.Conversation.self, from: data).title
    }

    // The acceptance criterion, asked the only way it can be asked from inside the app: not "no
    // requests were made" but "nothing was ever built to make one with".
    @Test("with the switch off nothing so much as opens a connection")
    func offMeansOff() async throws {
        let root = try temporaryRoot()
        let ledger = Ledger()
        let backup = CloudBackup(
            defaults: defaults("off"),
            root: root,
            allowSync: true,
            makeTransport: { ledger.madeTransports += 1; return FakeTransport() }
        )

        #expect(backup.isEnabled == false)
        #expect(backup.status == .off)

        let file = try writeChat("c-1", in: root, spaceId: "s-1", updatedAt: Date(), text: "Hola")
        backup.record(.chat, spaceId: "s-1", id: "c-1", document: file, updatedAt: Date())
        backup.forget(.report, spaceId: "s-1", id: "r-1")
        await backup.refresh()
        for _ in 0..<5 { await Task.yield() }

        #expect(ledger.madeTransports == 0)
    }

    // Reversible, because CloudKit reports a deletion as a record name and nothing else. A name
    // that cannot be turned back into a file is a deletion that never arrives.
    @Test("a record name survives a round trip, however odd the ids are")
    func recordNamesRoundTrip() throws {
        let cases: [(CloudBackup.Kind, String, String)] = [
            (.chat, "space-1", "A1B2-C3"),
            (.report, "vault~with~tildes", "id with spaces"),
            (.chat, "acentuación/ñ", "%50"),
        ]
        for (kind, spaceId, id) in cases {
            let name = CloudBackup.recordName(kind, spaceId: spaceId, id: id)
            let parsed = try #require(CloudBackup.parse(name))
            #expect(parsed.kind == kind)
            #expect(parsed.spaceId == spaceId)
            #expect(parsed.id == id)
        }
    }

    // Order matters and is not a detail: a second device switched on would otherwise send its own
    // list before looking, and overwrite what the first one wrote.
    @Test("switching on looks before it speaks")
    func enablingFetchesBeforeItSends() async throws {
        let root = try temporaryRoot()
        try writeChat("c-1", in: root, spaceId: "s-1", updatedAt: Date(), text: "Hola")
        let fake = FakeTransport()
        let backup = CloudBackup(defaults: defaults("order"), root: root, allowSync: true, makeTransport: { fake })

        await backup.setEnabled(true)

        let calls = await fake.calls
        let firstFetch = try #require(calls.firstIndex(of: "changes"))
        let firstSave = try #require(calls.firstIndex(of: "save"))
        #expect(firstFetch < firstSave)
        #expect(await fake.saved.count == 1)
        #expect(await fake.saved.first?.localId == "c-1")
    }

    @Test("a newer copy from another device replaces this one")
    func newerIncomingWins() async throws {
        let root = try temporaryRoot()
        try writeChat("c-1", in: root, spaceId: "s-1", updatedAt: Date(timeIntervalSince1970: 1_000), text: "Vieja")
        let arriving = try stagedChat("c-1", spaceId: "s-1", updatedAt: Date(timeIntervalSince1970: 2_000), text: "Nueva")

        let fake = FakeTransport()
        await fake.stage(CloudChanges(
            changed: [.init(
                name: CloudBackup.recordName(.chat, spaceId: "s-1", id: "c-1"),
                updatedAt: Date(timeIntervalSince1970: 2_000),
                document: arriving,
                illustration: nil,
                illustrationName: nil
            )],
            token: Data("t".utf8)
        ))
        let backup = CloudBackup(defaults: defaults("newer"), root: root, allowSync: true, makeTransport: { fake })

        await backup.setEnabled(true)

        #expect(chatTitle("c-1", in: root, spaceId: "s-1") == "Nueva")
    }

    // The half of last-write-wins that is easy to get backwards. Losing an answer that was
    // written here because another device holds an older one is the failure this prevents.
    @Test("an older copy from another device is refused, and this one is queued to replace it")
    func olderIncomingLoses() async throws {
        let root = try temporaryRoot()
        try writeChat("c-1", in: root, spaceId: "s-1", updatedAt: Date(timeIntervalSince1970: 3_000), text: "Nueva")
        let arriving = try stagedChat("c-1", spaceId: "s-1", updatedAt: Date(timeIntervalSince1970: 1_000), text: "Vieja")

        let fake = FakeTransport()
        await fake.stage(CloudChanges(
            changed: [.init(
                name: CloudBackup.recordName(.chat, spaceId: "s-1", id: "c-1"),
                updatedAt: Date(timeIntervalSince1970: 1_000),
                document: arriving,
                illustration: nil,
                illustrationName: nil
            )],
            token: Data("t".utf8)
        ))
        let store = defaults("older")
        let backup = CloudBackup(defaults: store, root: root, allowSync: true, makeTransport: { fake })

        await backup.setEnabled(true)

        #expect(chatTitle("c-1", in: root, spaceId: "s-1") == "Nueva")
        // Not enough to keep it: iCloud is still wrong, so the next pass has to correct it.
        #expect(store.bool(forKey: "nodus.cloud.needsFullPush"))
    }

    @Test("a conversation deleted on another device goes from this one too")
    func remoteDeletionsArrive() async throws {
        let root = try temporaryRoot()
        try writeChat("c-1", in: root, spaceId: "s-1", updatedAt: Date(), text: "Hola")

        let fake = FakeTransport()
        await fake.stage(CloudChanges(
            deleted: [CloudBackup.recordName(.chat, spaceId: "s-1", id: "c-1")],
            token: Data("t".utf8)
        ))
        let backup = CloudBackup(defaults: defaults("deleted"), root: root, allowSync: true, makeTransport: { fake })

        await backup.setEnabled(true)

        #expect(chatTitle("c-1", in: root, spaceId: "s-1") == nil)
    }

    // "Optional and reversible" means the copy goes away, not that the app stops adding to it.
    @Test("switching off takes back what was uploaded, and leaves the device alone")
    func disablingRemovesTheCopy() async throws {
        let root = try temporaryRoot()
        try writeChat("c-1", in: root, spaceId: "s-1", updatedAt: Date(), text: "Hola")
        let fake = FakeTransport()
        let store = defaults("disable")
        let backup = CloudBackup(defaults: store, root: root, allowSync: true, makeTransport: { fake })

        await backup.setEnabled(true)
        await backup.setEnabled(false)

        #expect(await fake.removedEverything)
        #expect(backup.status == .off)
        #expect(store.data(forKey: "nodus.cloud.token") == nil)
        // The conversation itself is untouched. Turning the copy off is not throwing anything
        // away.
        #expect(chatTitle("c-1", in: root, spaceId: "s-1") == "Hola")
    }

    // A deletion that never reached iCloud would come back as a file on the next fetch, which is
    // the one outcome this feature must never produce.
    @Test("a deletion that could not be sent is remembered and sent later")
    func failedDeletionsAreRetried() async throws {
        let root = try temporaryRoot()
        let fake = FakeTransport()
        let store = defaults("retry")
        let backup = CloudBackup(defaults: store, root: root, allowSync: true, makeTransport: { fake })
        await backup.setEnabled(true)

        await fake.setRefusingDeletes(true)
        backup.forget(.chat, spaceId: "s-1", id: "c-1")
        let name = CloudBackup.recordName(.chat, spaceId: "s-1", id: "c-1")
        for _ in 0..<20 where store.stringArray(forKey: "nodus.cloud.pendingDeletions") == nil {
            await Task.yield()
        }
        #expect(store.stringArray(forKey: "nodus.cloud.pendingDeletions") == [name])

        await fake.setRefusingDeletes(false)
        await backup.refresh()

        #expect(await fake.deleted == [name])
        #expect(store.stringArray(forKey: "nodus.cloud.pendingDeletions") == nil)
    }
}
