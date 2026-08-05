import Foundation

/// The store that a handful of preferences follow the person into their other devices through.
///
/// `NSUbiquitousKeyValueStore` is iCloud's smallest surface: a kilobyte-sized dictionary, no
/// schema, no account to set up, no network code. It fits exactly what belongs in it — the model
/// chosen for chat, the models pinned, how large a report reads, how the space picker sorts, how
/// Home lays itself out. Setting a model on the iPad and finding the phone still on the old one
/// is a small annoyance repeated forever, and this is the cheapest possible answer to it.
///
/// **What is deliberately not here.** Provider API keys, which are Keychain items and stay on the
/// device that entered them. Space tokens, which are bound to one device and one space by
/// design. The installation id the outbox stamps changes with — two phones claiming to be the
/// same client would break the ledger's idempotency. Whether this device asks for Face ID, which
/// is about this device.
///
/// **Both stores, always.** Every write goes to `UserDefaults` and to iCloud. The local copy is
/// what the app reads on a launch with no network, on a device with no iCloud account, and in
/// tests; the cloud copy is what the other device reads. Neither is the authority on its own.
///
/// **Conflict resolution: the later write wins, and it carries its own timestamp.** Each key `k`
/// has a companion key `k.syncedAt` holding the moment it was written, and both stores hold both.
/// A read compares the two stamps and answers with the newer value; iCloud's own merge policy —
/// last writer to reach the server — is not enough on its own, because it would silently prefer
/// whichever device happened to come back online second. Two consequences worth stating: a device
/// whose clock is badly wrong can win an argument it should have lost, which is the accepted cost
/// of not running a server; and a value that arrives from iCloud is adopted **with the stamp it
/// came with**, never re-stamped, or two devices would hand the same preference back and forth
/// forever, each one newer than the last.
@MainActor
final class SyncedDefaults {
    static let shared = SyncedDefaults()

    private let defaults: UserDefaults
    /// Nil when there is no ubiquitous store to talk to — a test, or a build without the
    /// entitlement. Everything then falls back to `UserDefaults` and the app behaves as it did
    /// before any of this existed.
    private let cloud: (any KeyValueSyncing)?

    private var handlers: [(keys: Set<String>, run: @MainActor () -> Void)] = []

    init(defaults: UserDefaults = .standard, cloud: (any KeyValueSyncing)? = NSUbiquitousKeyValueStore.default) {
        self.defaults = defaults
        self.cloud = cloud
        guard cloud != nil else { return }
        // `object: nil` rather than the store: the notification is posted by the shared store,
        // and pinning the observer to an injected fake would silence it in exactly the case the
        // tests care about.
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            let changed = Set((note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]) ?? [])
            Task { @MainActor in self?.absorb(changed) }
        }
        // Asking once at launch is what makes a preference set on the iPad while this phone was
        // in a pocket arrive at all: without it the first read of the session would answer from
        // whatever iCloud last happened to push.
        cloud?.synchronize()
    }

    // MARK: - Reading

    func bool(forKey key: String) -> Bool? { value(forKey: key) as? Bool }
    func double(forKey key: String) -> Double? { value(forKey: key) as? Double }
    func string(forKey key: String) -> String? { value(forKey: key) as? String }
    func data(forKey key: String) -> Data? { value(forKey: key) as? Data }

    /// The newer of the two copies, and the moment where a key first travels.
    ///
    /// The promotion in the middle is the upgrade path. This app kept these preferences in
    /// `UserDefaults` for its whole life, so on the launch that first runs this code every device
    /// has a local value and iCloud has nothing. Sending it up — stamped `distantPast`, so it
    /// loses to the first deliberate choice made on any device — means the iPad's settings are
    /// not silently replaced by an empty cloud, and it happens once per key rather than on every
    /// read, because after it the cloud is no longer empty.
    private func value(forKey key: String) -> Any? {
        let local = defaults.object(forKey: key)
        guard let cloud else { return local }

        guard let remote = cloud.object(forKey: key) else {
            if let local { write(local, forKey: key, at: .distantPast, to: .cloudOnly) }
            return local
        }
        guard local != nil else {
            adopt(remote, forKey: key, stampedAt: cloud.object(forKey: Self.stampKey(key)) as? Double ?? 0)
            return remote
        }
        return stamp(in: cloud, forKey: key) > stamp(in: defaults, forKey: key) ? remote : local
    }

    // MARK: - Writing

    func set(_ value: Bool, forKey key: String) { write(value, forKey: key, at: Date(), to: .both) }
    func set(_ value: Double, forKey key: String) { write(value, forKey: key, at: Date(), to: .both) }
    func set(_ value: String, forKey key: String) { write(value, forKey: key, at: Date(), to: .both) }
    func set(_ value: Data, forKey key: String) { write(value, forKey: key, at: Date(), to: .both) }

    private enum Destination { case both, cloudOnly }

    private func write(_ value: Any, forKey key: String, at when: Date, to destination: Destination) {
        let stamp = when.timeIntervalSinceReferenceDate
        if destination == .both {
            defaults.set(value, forKey: key)
            defaults.set(stamp, forKey: Self.stampKey(key))
        }
        cloud?.set(value, forKey: key)
        cloud?.set(stamp, forKey: Self.stampKey(key))
    }

    /// Take a value that came from iCloud, keeping the stamp it arrived with.
    ///
    /// Re-stamping here is the one mistake that turns a sync into a loop: this device would look
    /// newer than the device that actually made the choice, push, and be answered in kind.
    private func adopt(_ value: Any, forKey key: String, stampedAt stamp: Double) {
        defaults.set(value, forKey: key)
        defaults.set(stamp, forKey: Self.stampKey(key))
    }

    // MARK: - Changes from elsewhere

    /// Ask to be told when one of `keys` changed on another device.
    ///
    /// Registered for the app's lifetime — both callers are objects the root view holds — so
    /// there is nothing to unregister and no token to hand back.
    func onExternalChange(of keys: Set<String>, run: @escaping @MainActor () -> Void) {
        handlers.append((keys: keys, run: run))
    }

    private func absorb(_ changed: Set<String>) {
        guard let cloud else { return }
        // The notification names the keys, including the `.syncedAt` companions. Both halves are
        // copied down before anybody is told, so a handler that re-reads sees a consistent pair.
        for key in changed where !key.hasSuffix(Self.stampSuffix) {
            guard let remote = cloud.object(forKey: key) else {
                defaults.removeObject(forKey: key)
                defaults.removeObject(forKey: Self.stampKey(key))
                continue
            }
            let stamp = cloud.object(forKey: Self.stampKey(key)) as? Double ?? 0
            guard stamp > self.stamp(in: defaults, forKey: key) else { continue }
            adopt(remote, forKey: key, stampedAt: stamp)
        }
        for handler in handlers where !handler.keys.isDisjoint(with: changed) {
            handler.run()
        }
    }

    // MARK: - Stamps

    private static let stampSuffix = ".syncedAt"
    private static func stampKey(_ key: String) -> String { key + stampSuffix }

    private func stamp(in store: UserDefaults, forKey key: String) -> Double {
        store.object(forKey: Self.stampKey(key)) as? Double ?? 0
    }

    private func stamp(in store: any KeyValueSyncing, forKey key: String) -> Double {
        store.object(forKey: Self.stampKey(key)) as? Double ?? 0
    }
}

/// The two calls this file makes on iCloud's key-value store, named so a test can stand in for it.
///
/// `NSUbiquitousKeyValueStore` already has all three with these signatures, so the conformance
/// below is empty. `nonisolated` for the same reason: the class it stands in for is Foundation's
/// and belongs to no actor, and this module defaults to the main one. Not `Sendable`, and it does
/// not need to be — everything that touches it is on the main actor, where the preferences it
/// holds are read and written anyway.
nonisolated protocol KeyValueSyncing: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KeyValueSyncing {}
