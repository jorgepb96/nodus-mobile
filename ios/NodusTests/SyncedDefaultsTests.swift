import Foundation
import Testing
@testable import Nodus

/// Two devices arguing about one preference.
///
/// The failure this file is really about is the loop. A value that arrives from iCloud and is
/// then written back looks, to the device it came from, like a newer choice — so it comes back,
/// and back again. Nothing crashes and nothing is lost; the phone just talks to iCloud forever.
/// It cannot be seen in a single-device test, so the fake below plays the part of the other
/// device and counts how many times each side speaks.
@Suite("Synced preferences")
@MainActor
struct SyncedDefaultsTests {
    /// An in-memory ubiquitous store, plus a count of the writes that reached it.
    private nonisolated final class FakeCloud: KeyValueSyncing {
        var contents: [String: Any] = [:]
        private(set) var writes = 0

        func object(forKey key: String) -> Any? { contents[key] }

        func set(_ value: Any?, forKey key: String) {
            writes += 1
            contents[key] = value
        }

        func synchronize() -> Bool { true }
    }

    private func defaults(_ name: String) -> UserDefaults {
        let suite = "nodus.tests.synced.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("a write lands in both stores")
    func writesBothWays() {
        let cloud = FakeCloud()
        let store = SyncedDefaults(defaults: defaults("both"), cloud: cloud)

        store.set(1.45, forKey: "nodus.prefs.readingScale")

        #expect(store.double(forKey: "nodus.prefs.readingScale") == 1.45)
        #expect(cloud.contents["nodus.prefs.readingScale"] as? Double == 1.45)
    }

    @Test("the Home layout survives returning to Home and reopening after an update")
    func homeLayoutIsDurable() {
        let local = defaults("home-layout")
        let first = AppPreferences(store: SyncedDefaults(defaults: local, cloud: nil))

        first.homeLayout = .list
        // Leaving Home can change unrelated preferences, but it must not reset its layout.
        first.spaceOrder = .name
        #expect(first.homeLayout == .list)

        // A new preferences object reads the same persistent domain, as a fresh launch after
        // replacing the app binary does. UserDefaults survives that replacement.
        let reopened = AppPreferences(store: SyncedDefaults(defaults: local, cloud: nil))
        #expect(reopened.homeLayout == .list)

        reopened.homeLayout = .grid
        let openedAgain = AppPreferences(store: SyncedDefaults(defaults: local, cloud: nil))
        #expect(openedAgain.homeLayout == .grid)
    }

    @Test("report ordering and reading filter survive a new app session")
    func reportLibraryControlsAreDurable() {
        let local = defaults("report-library")
        let first = AppPreferences(store: SyncedDefaults(defaults: local, cloud: nil))

        first.reportLibrarySortOrder = .oldest
        first.reportLibraryReadFilter = .unread

        let reopened = AppPreferences(store: SyncedDefaults(defaults: local, cloud: nil))
        #expect(reopened.reportLibrarySortOrder == .oldest)
        #expect(reopened.reportLibraryReadFilter == .unread)

        reopened.reportLibrarySortOrder = .newest
        reopened.reportLibraryReadFilter = .read
        let openedAgain = AppPreferences(store: SyncedDefaults(defaults: local, cloud: nil))
        #expect(openedAgain.reportLibrarySortOrder == .newest)
        #expect(openedAgain.reportLibraryReadFilter == .read)
    }

    // The whole conflict rule in one test: the iPad chose later, so the iPad wins, even though
    // this device has a perfectly good local answer of its own.
    @Test("the later of the two writes is the one that is read")
    func laterWriteWins() {
        let local = defaults("later")
        let cloud = FakeCloud()
        let store = SyncedDefaults(defaults: local, cloud: cloud)

        store.set("list", forKey: "nodus.prefs.homeLayout")
        // The other device, a minute after this one.
        cloud.contents["nodus.prefs.homeLayout"] = "grid"
        cloud.contents["nodus.prefs.homeLayout.syncedAt"] =
            Date().addingTimeInterval(60).timeIntervalSinceReferenceDate

        #expect(store.string(forKey: "nodus.prefs.homeLayout") == "grid")
    }

    @Test("an older write from elsewhere does not overrule what was chosen here")
    func olderWriteLoses() {
        let cloud = FakeCloud()
        let store = SyncedDefaults(defaults: defaults("older"), cloud: cloud)

        store.set("list", forKey: "nodus.prefs.homeLayout")
        cloud.contents["nodus.prefs.homeLayout"] = "grid"
        cloud.contents["nodus.prefs.homeLayout.syncedAt"] =
            Date().addingTimeInterval(-60).timeIntervalSinceReferenceDate

        #expect(store.string(forKey: "nodus.prefs.homeLayout") == "list")
    }

    // The upgrade path. Every device that installs this release already has these preferences in
    // `UserDefaults` and iCloud has nothing, so the empty cloud must not read as "the user chose
    // nothing" — and the promoted value must not outrank a real choice made afterwards anywhere.
    @Test("a preference that predates any of this is sent up, and still loses to a real choice")
    func localValuesArePromotedButRankLast() {
        let local = defaults("promote")
        local.set(1.6, forKey: "nodus.prefs.readingScale")
        let cloud = FakeCloud()
        let store = SyncedDefaults(defaults: local, cloud: cloud)

        #expect(store.double(forKey: "nodus.prefs.readingScale") == 1.6)
        #expect(cloud.contents["nodus.prefs.readingScale"] as? Double == 1.6)

        // Another device makes an actual choice, however long ago.
        cloud.contents["nodus.prefs.readingScale"] = 1.0
        cloud.contents["nodus.prefs.readingScale.syncedAt"] =
            Date(timeIntervalSinceReferenceDate: 1).timeIntervalSinceReferenceDate
        #expect(store.double(forKey: "nodus.prefs.readingScale") == 1.0)
    }

    // A new phone signed into the same iCloud account: nothing local at all, and the preferences
    // are there before the first tap.
    @Test("a device with nothing of its own takes what iCloud holds")
    func freshDeviceAdopts() {
        let local = defaults("fresh")
        let cloud = FakeCloud()
        cloud.contents["nodus.ai.models.v1"] = Data("{}".utf8)
        cloud.contents["nodus.ai.models.v1.syncedAt"] = Date().timeIntervalSinceReferenceDate
        let store = SyncedDefaults(defaults: local, cloud: cloud)

        #expect(store.data(forKey: "nodus.ai.models.v1") == Data("{}".utf8))
        // Kept, so the next launch with no network still has it.
        #expect(local.data(forKey: "nodus.ai.models.v1") == Data("{}".utf8))
    }

    // The loop. Reading a value that came from elsewhere must not put anything on the wire.
    @Test("adopting a value from another device says nothing back to iCloud")
    func adoptingIsSilent() {
        let cloud = FakeCloud()
        cloud.contents["nodus.prefs.spaceOrder"] = "name"
        cloud.contents["nodus.prefs.spaceOrder.syncedAt"] = Date().timeIntervalSinceReferenceDate
        let store = SyncedDefaults(defaults: defaults("silent"), cloud: cloud)

        for _ in 0..<5 { _ = store.string(forKey: "nodus.prefs.spaceOrder") }

        #expect(cloud.writes == 0)
    }

    // The same guarantee one level up, where the loop would actually have happened: the
    // preferences object persists on every `didSet`, and the value it is handed here is not its
    // own decision.
    @Test("preferences taken from another device are not written back out")
    func preferencesDoNotEchoRemoteChanges() async {
        let cloud = FakeCloud()
        let store = SyncedDefaults(defaults: defaults("echo"), cloud: cloud)
        let preferences = AppPreferences(store: store)

        preferences.homeLayout = .list
        let afterOwnChoice = cloud.writes

        cloud.contents["nodus.prefs.homeLayout"] = "grid"
        cloud.contents["nodus.prefs.homeLayout.syncedAt"] =
            Date().addingTimeInterval(60).timeIntervalSinceReferenceDate
        NotificationCenter.default.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            userInfo: [NSUbiquitousKeyValueStoreChangedKeysKey: ["nodus.prefs.homeLayout"]]
        )
        // The observer hands the work to the main actor rather than doing it inside the
        // notification, so the result is one turn of the loop away rather than immediate.
        for _ in 0..<10 where preferences.homeLayout != .grid { await Task.yield() }

        #expect(preferences.homeLayout == .grid)
        #expect(cloud.writes == afterOwnChoice)
    }

    // Without an ubiquitous store — no entitlement, no account, a test — the app has to behave
    // exactly as it did before any of this existed.
    @Test("with no iCloud store at all it is plain UserDefaults")
    func degradesToLocalOnly() {
        let local = defaults("nocloud")
        let store = SyncedDefaults(defaults: local, cloud: nil)

        store.set(true, forKey: "nodus.prefs.scrollToTop")

        #expect(store.bool(forKey: "nodus.prefs.scrollToTop") == true)
        #expect(local.object(forKey: "nodus.prefs.scrollToTop") as? Bool == true)
    }
}
