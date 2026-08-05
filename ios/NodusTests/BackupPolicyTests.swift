import Foundation
import NodusKit
import Testing

/// Which of this device's files a backup carries.
///
/// The two mistakes this guards against are opposite and both silent. Excluding a chat or a
/// report means a new phone comes back without work that exists nowhere else and cost real money
/// to produce — and nobody finds out until the restore, when it is far too late. Including the
/// mirror means every backup carries a copy of somebody else's publication, which the app can
/// re-download in one tap. Neither shows up as a failure anywhere, which is exactly why the
/// answers are asserted rather than left to whoever next adds a store.
@Suite("Backup policy")
struct BackupPolicyTests {
    private func temporarySpace() throws -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A space folder with one of everything the app writes.
    private func populate(_ space: URL) throws {
        for item in BackupPolicy.Item.allCases {
            let url = space.appendingPathComponent(item.rawValue)
            switch item {
            case .chats, .reports:
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try Data("{}".utf8).write(to: url.appendingPathComponent("one.json"))
            case .mirror, .outbox, .deepResearchCheckpoint:
                try Data("x".utf8).write(to: url)
            }
        }
        // SQLite's sidecars, which carry the tail of whatever the database holds.
        try Data("x".utf8).write(to: space.appendingPathComponent("mirror.sqlite-wal"))
        try Data("x".utf8).write(to: space.appendingPathComponent("mirror.sqlite-shm"))
    }

    private func excluded(_ url: URL) throws -> Bool {
        let decision = try #require(BackupPolicy.decision(at: url), "\(url.lastPathComponent) has no answer at all")
        return decision == .excluded
    }

    // The list itself, so that changing an answer is a change to a test rather than a line
    // somebody reads past in a diff.
    @Test("the mirror is the only thing left out of a backup")
    func onlyTheMirrorIsExcluded() {
        let excluded = BackupPolicy.Item.allCases.filter { $0.decision == .excluded }
        #expect(excluded == [.mirror])
        #expect(BackupPolicy.Item.chats.decision == .backedUp)
        #expect(BackupPolicy.Item.reports.decision == .backedUp)
        #expect(BackupPolicy.Item.outbox.decision == .backedUp)
        #expect(BackupPolicy.Item.deepResearchCheckpoint.decision == .backedUp)
    }

    // Asked of the filesystem rather than of the table above: the decision that counts is the
    // one written on the file, and a sweep that quietly failed would pass any test of the enum.
    @Test("the sweep marks what is on disk, and marks it the way the policy says")
    func sweepMarksEveryFile() throws {
        let space = try temporarySpace()
        try populate(space)

        BackupPolicy.apply(inSpace: space)

        #expect(try excluded(space.appendingPathComponent("mirror.sqlite")))
        #expect(try excluded(space.appendingPathComponent("mirror.sqlite-wal")))
        #expect(try excluded(space.appendingPathComponent("mirror.sqlite-shm")))
        #expect(try excluded(space.appendingPathComponent("outbox.sqlite")) == false)
        #expect(try excluded(space.appendingPathComponent("chats")) == false)
        #expect(try excluded(space.appendingPathComponent("reports")) == false)
        #expect(try excluded(space.appendingPathComponent("deep-research-checkpoint.json")) == false)
    }

    // A phone that has been carrying an unmarked mirror since before any of this existed.
    @Test("a mirror that was already on disk gets excluded on the next sweep")
    func sweepRepairsAnOlderInstall() throws {
        let root = try temporarySpace()
        let space = root.appendingPathComponent("space-1", isDirectory: true)
        try FileManager.default.createDirectory(at: space, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: space.appendingPathComponent("mirror.sqlite"))

        #expect(try excluded(space.appendingPathComponent("mirror.sqlite")) == false)
        BackupPolicy.apply(toSpacesDirectory: root)
        #expect(try excluded(space.appendingPathComponent("mirror.sqlite")))
    }

    // The wiring, not the table. `MirrorStore.init` is the one line every process that touches a
    // mirror goes through, so the mark has to happen there and not only in the launch sweep.
    @Test("opening a mirror is enough to keep it out of the backup")
    func openingAMirrorExcludesIt() async throws {
        let root = try temporarySpace()
        let store = try await MirrorStore.open(spaceId: "space-1", directory: root)
        let file = await store.fileURL
        #expect(try excluded(file))
    }

    // A space that never opened a chat has no `chats` folder, and that is the normal case.
    @Test("a sweep over a space with nothing in it does nothing and says nothing")
    func sweepToleratesAnEmptySpace() throws {
        let space = try temporarySpace()
        BackupPolicy.apply(inSpace: space)
        #expect(BackupPolicy.decision(at: space.appendingPathComponent("chats")) == nil)
    }
}
