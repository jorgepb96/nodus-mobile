import Foundation

/// What a device backup should carry off this phone, file by file.
///
/// iOS backs up the whole container except `Library/Caches` and whatever is explicitly excluded,
/// so "kept" is the default and every exception has to be argued. Two very different kinds of
/// file sit side by side under `spaces/<id>/`. Some of them exist nowhere else in the world —
/// a conversation with the vault, a Deep Research report that cost one model call per section,
/// the checkpoint of a run that has not finished. Others are a copy of somebody else's
/// publication and can be fetched again in one tap. Losing the first kind on a new phone is
/// unrepairable; carrying the second kind into every nightly backup is a hundred megabytes of
/// somebody's iCloud plan spent on data the app would rather re-download.
///
/// The decisions live here rather than at each call site for two reasons: adding a store should
/// mean adding a case and arguing for it, and a test can read this list back off a real disk and
/// notice when somebody changes an answer without meaning to.
public enum BackupPolicy: Sendable {
    public enum Decision: Sendable, Equatable {
        /// Restored onto the next device. The default, and what everything gets unless there is
        /// a reason.
        case backedUp
        /// Left out of the backup. Only ever for data the app can rebuild from the server.
        case excluded
    }

    /// Everything this app writes inside one space's directory.
    ///
    /// A `String` raw value because it is also the name on disk: the two cannot drift apart if
    /// there is only one of them.
    public enum Item: String, CaseIterable, Sendable {
        /// The offline copy of the publication. Tens of thousands of rows and an FTS index of
        /// them — by far the largest thing the app stores, and the only one that is a copy.
        case mirror = "mirror.sqlite"
        /// Notes written and reports sent that have not reached the server yet. Not a copy of
        /// anything: until the ledger accepts them they exist on this device alone.
        case outbox = "outbox.sqlite"
        /// Conversations with the vault. Every turn cost a retrieval and a model call, and no
        /// server has ever seen them.
        case chats
        /// Reports generated here, with their illustrations. The most expensive bytes the app
        /// holds — a report the user never sent to the vault has no other copy anywhere.
        case reports
        /// A run that stopped part-way. Losing it costs one completion per section already
        /// written, which is money, not just time.
        case deepResearchCheckpoint = "deep-research-checkpoint.json"

        public var decision: Decision {
            switch self {
            case .mirror:
                // The one exclusion, and the reason this type exists. `BGTask` refresh already
                // re-downloads it, `SpaceSettingsView` offers the same thing by hand, and the
                // app is honest about a mirror being absent — it says "download for offline
                // use" rather than pretending the corpus is gone.
                return .excluded
            case .outbox, .chats, .reports, .deepResearchCheckpoint:
                return .backedUp
            }
        }

        /// SQLite may leave a write-ahead log and a shared-memory file beside the database.
        /// Excluding the database and not those would put the tail of a hundred-megabyte
        /// corpus in the backup anyway, so a decision applies to the whole set.
        var companions: [String] {
            switch self {
            case .mirror, .outbox: return ["\(rawValue)-wal", "\(rawValue)-shm"]
            case .chats, .reports, .deepResearchCheckpoint: return []
            }
        }
    }

    /// Marks one file or folder, if it is there.
    ///
    /// Silent about a path that does not exist: a space that has never opened a chat has no
    /// `chats` folder, and that is the normal case rather than a failure.
    public static func apply(_ decision: Decision, to url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = decision == .excluded
        try? target.setResourceValues(values)
    }

    /// What the filesystem currently says, which is the only answer that counts.
    ///
    /// Nil means there is no file to have an opinion about. Worth distinguishing: reading the
    /// resource value of a path that does not exist answers `false` rather than failing, so
    /// without this check "never written" and "deliberately kept" are the same answer.
    public static func decision(at url: URL) -> Decision? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]),
              let excluded = values.isExcludedFromBackup
        else { return nil }
        return excluded ? .excluded : .backedUp
    }

    /// Applies every decision to every space on disk.
    ///
    /// Run on each launch rather than only where a file is created, because the app shipped for
    /// a year before any of this existed: a phone upgrading to this release already has a
    /// mirror that nobody ever marked, and it would stay in the backup forever if the only
    /// place the policy were applied were the code path that first writes the file.
    ///
    /// Cheap enough to be unconditional — a handful of `setxattr` calls per space — but still
    /// worth keeping off the main thread, which is why every caller wraps it in a task.
    public static func apply(toSpacesDirectory directory: URL) {
        let spaces = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for space in spaces {
            guard (try? space.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            apply(inSpace: space)
        }
    }

    /// The same sweep over one space's folder.
    public static func apply(inSpace directory: URL) {
        for item in Item.allCases {
            let decision = item.decision
            apply(decision, to: directory.appendingPathComponent(item.rawValue))
            for companion in item.companions {
                apply(decision, to: directory.appendingPathComponent(companion))
            }
        }
    }
}
