import NodusKit
import Observation
import SwiftUI

/// One open space: its client, what it published, and the menu that follows from that.
///
/// The menu is not a fixed list per vault type. It is derived from `counts` on the space
/// header, because a vault type says what a corpus *could* contain and the publication says
/// what it does. A teaching vault whose owner published no exams should not show an Exams tab
/// that is always empty.
@Observable
@MainActor
final class SpaceSession {
    let connection: AppModel.Connection
    let client: NodusClient

    private(set) var overview: SpaceOverview?
    /// Why the space could not be read, classified rather than described.
    ///
    /// It used to be `error.localizedDescription`, which for the ordinary case — a laptop that
    /// went to sleep — is "Could not connect to the server." on a screen that has just failed
    /// to connect to a server.
    private(set) var loadFailure: ConnectionFailure?
    private(set) var isPublished = true
    private(set) var isLoading = false
    /// The revision every server-backed screen is currently showing.
    ///
    /// A publication is immutable, so this one value invalidates every REST response derived
    /// from it. Views key their loading task to it: when the desktop publishes a change, the
    /// open list or document asks for the same route again and its ETag supplies the new body.
    private(set) var publishedRevision: String?

    /// Serialises the cheap HEAD probes from the foreground loop and the scene activation
    /// hook. Returning to the app commonly fires both at once; asking twice adds no freshness.
    private var isCheckingPublishedContent = false

    /// Told to `AppModel` so the space picker can say the same thing this screen says.
    private let onFailure: (ConnectionFailure) -> Void

    /// The vault's embedding identity, read once by probing the semantic endpoint. Nil until
    /// probed, `.none` when the vault has no published vectors.
    private(set) var embedding: EmbeddingProbeResult = .unknown

    /// The offline copy, when one has been downloaded.
    private(set) var mirror: MirrorStore?
    private(set) var mirrorSummary: MirrorStore.Summary?
    private(set) var mirrorProgress: MirrorProgress = .absent
    private let mirrorDirectory: URL

    var accent: Color { connection.accent }
    var vaultType: VaultType? { overview?.vault?.type ?? connection.vaultType }

    private init(
        connection: AppModel.Connection,
        client: NodusClient,
        // Defaulted because a corpus held on this device has no connection to fail: the example
        // vault opens or the build is broken, and neither is something the space picker can
        // offer a way out of.
        onFailure: @escaping (ConnectionFailure) -> Void = { _ in }
    ) {
        self.connection = connection
        self.client = client
        self.onFailure = onFailure
        // Application Support, not Caches: the mirror is what the app falls back to on a plane,
        // and the system is free to delete Caches whenever it likes.
        mirrorDirectory = URL.applicationSupportDirectory.appendingPathComponent("spaces", isDirectory: true)
        names = CorpusNames(client: client, spaceId: connection.spaceId)
    }

    convenience init(
        connection: AppModel.Connection,
        token: String,
        cacheDirectory: URL,
        onUnauthorized: @escaping @Sendable () async -> Void,
        onFailure: @escaping (ConnectionFailure) -> Void = { _ in }
    ) {
        self.init(
            connection: connection,
            client: NodusClient(
                address: ServerAddress(trusted: connection.origin),
                token: token,
                cache: ResponseCache(directory: cacheDirectory)
            ),
            onFailure: onFailure
        )
        Task { [client] in await client.setUnauthorizedHandler(onUnauthorized) }
    }

    /// The example vault: the same session over a client that answers from this device.
    ///
    /// Deliberately not a second `SpaceSession`. Every screen the demo is meant to show reads
    /// through this object, and a parallel one would be two of everything — two loaders, two
    /// mirrors, two ideas of what a section is — drifting apart from the first release after
    /// this one. What differs is where the answers come from, and that is one object further
    /// down: no token, because there is nobody to authorise; no revocation handler, because
    /// nothing can answer 401.
    convenience init(demo connection: AppModel.Connection, corpus: LocalCorpus, cacheDirectory: URL) {
        self.init(
            connection: connection,
            client: NodusClient(
                local: corpus,
                address: ServerAddress(trusted: connection.origin),
                cache: ResponseCache(directory: cacheDirectory)
            )
        )
    }

    /// Whether this is the bundled example vault rather than a space on a server.
    var isDemo: Bool { connection.isDemo }

    // MARK: - Offline mirror

    enum MirrorProgress: Equatable {
        case absent
        case downloading
        case importing
        /// Held locally and matching the server's current revision.
        case current(rows: Int, tables: Int)
        /// Held locally, but the owner has republished since.
        case stale(rows: Int)
        case failed(String)
    }

    /// Opens an existing mirror without downloading anything.
    func loadMirror() async {
        guard mirror == nil else { return }
        do {
            let store = try await MirrorStore.open(spaceId: connection.spaceId, directory: mirrorDirectory)
            guard let summary = try await store.summary() else { return }
            mirror = store
            mirrorSummary = summary
            await refreshBrowsableTables()
            await names.preload(from: store)
            await refreshMirrorFreshness()
        } catch {
            mirrorProgress = .failed(error.localizedDescription)
        }
    }

    /// Asks the server for its revision only. A HEAD carries it with no body at all, so
    /// discovering a mirror is current costs one round trip rather than a whole snapshot.
    func refreshMirrorFreshness() async {
        guard let mirror, let summary = mirrorSummary else { return }
        do {
            let revision = try await client.snapshotRevision(in: connection.spaceId)
            let current = try await mirror.isCurrent(with: revision ?? "")
            let counts = try await mirror.tableCounts()
            mirrorProgress = current
                ? .current(rows: counts.values.reduce(0, +), tables: counts.count)
                : .stale(rows: summary.totalRows)
        } catch let error as APIError where error.isNotPublished {
            mirrorProgress = .stale(rows: summary.totalRows)
        } catch {
            // Offline is the normal case for a mirror check. Holding the last known state is
            // more useful than reporting a failure the user cannot act on.
            let counts = (try? await mirror.tableCounts()) ?? [:]
            mirrorProgress = .current(rows: counts.values.reduce(0, +), tables: counts.count)
        }
    }

    func downloadMirror() async {
        mirrorProgress = .downloading
        do {
            let snapshot = try await client.snapshot(in: connection.spaceId)
            let revision = try await client.snapshotRevision(in: connection.spaceId)
                ?? snapshot.revision
                ?? overview?.space.revision
                ?? ""
            mirrorProgress = .importing
            let store: MirrorStore
            if let mirror {
                store = mirror
            } else {
                store = try await MirrorStore.open(spaceId: connection.spaceId, directory: mirrorDirectory)
            }
            let summary = try await store.replace(with: snapshot, revision: revision)
            mirror = store
            mirrorSummary = summary
            await refreshBrowsableTables()
            await names.preload(from: store)
            mirrorProgress = .current(rows: summary.totalRows, tables: summary.counts.count)
        } catch let error as APIError where error.isNotPublished {
            mirrorProgress = .failed("This space has no publication to download yet.")
        } catch {
            mirrorProgress = .failed(error.localizedDescription)
        }
    }

    func removeMirror() async {
        guard let mirror else { return }
        try? await mirror.drop()
        self.mirror = nil
        mirrorSummary = nil
        mirrorOnlyTables = []
        mirrorProgress = .absent
    }

    var hasMirror: Bool { mirror != nil }

    private func refreshBrowsableTables() async {
        guard let mirror else { mirrorOnlyTables = []; return }
        let browsable = (try? await mirror.browsableTables()) ?? [:]
        mirrorOnlyTables = browsable
            .filter { Collections.byTable[$0.key] == nil }
            .map { (table: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    /// Tables the publication carried that no REST route can list.
    ///
    /// For a worldbuilding vault this is most of the corpus — scenes, articles, factions,
    /// threads, character profiles. They are reachable only because the snapshot carries them.
    ///
    /// Filtered by `browsableTables()`, which measures whether a table's rows have titles at
    /// all. Half a published corpus is join tables with two foreign keys and nothing to show,
    /// and listing those gives screens of "Untitled" under names like "Thread Parties".
    private(set) var mirrorOnlyTables: [(table: String, count: Int)] = []

    /// Resolves the ids inside relations into names. Populated from the mirror when there is
    /// one, and by request otherwise.
    let names: CorpusNames


    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            // The first call after a space is opened is a knock at an address as much as it is
            // a read: it is where a computer that has gone to sleep since last time gets
            // discovered, and the session's own 30 s is half a minute of spinner to say so.
            // Later refreshes are against a server that has already answered, and keep it.
            let isFirstKnock = overview == nil
            let loaded = try await client.space(connection.spaceId, timeout: isFirstKnock ? 4 : nil)
            overview = loaded
            publishedRevision = loaded.space.revision
            isPublished = overview?.hasBeenPublished ?? false
            loadFailure = nil
        } catch let error as APIError where error.isNotPublished {
            // Not a failure: the owner has not published yet. The shell shows an empty state
            // that says so, rather than an error that suggests something is broken.
            isPublished = false
            loadFailure = nil
        } catch where error.isCancellation {
            // A pull-to-refresh that was let go of, or a screen that went away mid-request.
            // Nothing failed and nothing changed, so the last good read stands.
        } catch {
            // The network is only measured once something has already gone wrong, and briefly:
            // it is spent on top of the timeout that already elapsed. This is a credentialed
            // route, so a 401 here really is this device's token and not a proxy guarding a
            // public one.
            let network = await NetworkReachability.current(within: 0.5)
            let failure = ConnectionFailure.classify(
                error: error,
                origin: connection.origin,
                network: network,
                knock: .credentialed,
                appVersion: NodusVersion.current
            )
            loadFailure = failure
            if let failure { onFailure(failure) }
        }
    }

    // MARK: - Live publication refresh

    /// Checks whether the desktop has published a newer corpus and invalidates the open UI.
    ///
    /// The probe carries no snapshot body. A full mirror is downloaded only for somebody who
    /// explicitly keeps one, because mirror-only worldbuilding tables have no REST route from
    /// which they could otherwise refresh. Ordinary screens revalidate their own small route.
    func refreshPublishedContent() async {
        guard !isDemo, !isCheckingPublishedContent else { return }
        isCheckingPublishedContent = true
        defer { isCheckingPublishedContent = false }

        do {
            let revision = try await client.snapshotRevision(in: connection.spaceId)
            let publicationChanged = revision != publishedRevision
            let mirrorNeedsRefresh = mirror != nil && mirrorSummary?.revision != revision
            guard publicationChanged || mirrorNeedsRefresh else { return }

            // Publish the invalidation before the secondary reads. An open document can fetch
            // its new rows in parallel with the overview and an optional offline mirror.
            if publicationChanged { publishedRevision = revision }
            async let overviewRefresh: Void = publicationChanged ? load() : ()
            if mirrorNeedsRefresh {
                async let mirrorRefresh: Void = downloadMirror()
                _ = await (overviewRefresh, mirrorRefresh)
            } else {
                await overviewRefresh
            }
        } catch let error as APIError where error.isNotPublished {
            // A cleared publication is also a state change. `load()` turns it into the shell's
            // existing unpublished empty state rather than presenting it as a connection error.
            if publishedRevision != nil {
                publishedRevision = nil
                await load()
            }
        } catch where error.isCancellation {
            // The shell went away or the app was suspended. Nothing failed.
        } catch {
            // Live refresh is opportunistic. The last coherent publication remains readable,
            // and the ordinary screen loaders still surface actionable connection failures.
        }
    }

    /// Keeps an open space close to the desktop without moving snapshot bytes on every tick.
    /// SwiftUI cancels this task when the shell closes; iOS suspends it with the app.
    func monitorPublishedContent(every interval: Duration = .seconds(5)) async {
        while !Task.isCancelled {
            await refreshPublishedContent()
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }

    /// Ask the space which embedding it was indexed with, so the search screen can say what it
    /// needs instead of silently returning nothing.
    func probeEmbedding() async {
        guard case .unknown = embedding else { return }
        do {
            if let identity = try await client.publishedEmbeddingIdentity(in: connection.spaceId) {
                embedding = .published(identity)
            } else {
                embedding = .noVectors
            }
        } catch {
            embedding = .unavailable(error.localizedDescription)
        }
    }

    /// Collections that exist in the data but are not offered as a section of their own.
    ///
    /// Passages are read from the idea that cites them — that is where they mean something,
    /// and it is how the desktop shows them. A flat list of 5 803 quotations in snapshot order
    /// is not something anyone browses.
    ///
    /// The calendar and the goals are excluded for the same reason and a sharper one: the API
    /// has no sort, so a calendar listed as a collection arrives in snapshot order, which for
    /// dates is no order at all. Both have a screen that reads them properly — the agenda and
    /// the goals — and offering the raw list beside it would be offering the worse of the two.
    private static let notBrowsedDirectly: Set<String> = ["passages", "study-calendar", "study-goals"]

    /// The collections the Home board can show, in the order the menu shows them.
    ///
    /// Before the overview arrives, use the vault type already saved with the connection to
    /// keep the board structurally complete. The eventual overview replaces these candidates
    /// with the collections the publication actually populated. Without that provisional list,
    /// a slow first request made Home look half empty and then inserted a grid several seconds
    /// later.
    var sections: [CollectionDescriptor] {
        let candidates: [CollectionDescriptor]
        if let overview {
            candidates = overview.populatedCollections.filter {
                !Self.notBrowsedDirectly.contains($0.path)
            }
        } else if isPublished, let vaultType {
            candidates = Self.anticipatedSections(for: vaultType)
        } else {
            return []
        }

        guard let vaultType else { return candidates }
        // Order by the vault's own families first; anything else it happens to have published
        // still appears, just after. Hiding a published table because the type did not predict
        // it would be a lie about the corpus.
        let families = vaultType.families
        return candidates.sorted { lhs, rhs in
            let left = lhs.families.isDisjoint(with: families) ? 1 : 0
            let right = rhs.families.isDisjoint(with: families) ? 1 : 0
            if left != right { return left < right }
            return indexOf(lhs) < indexOf(rhs)
        }
    }

    /// The best complete board available before the server has supplied its row counts.
    ///
    /// Families are deliberately only a provisional signal. Once the overview arrives, its
    /// populated tables win, including any the vault type did not predict.
    static func anticipatedSections(for vaultType: VaultType) -> [CollectionDescriptor] {
        Collections.all.filter {
            !Self.notBrowsedDirectly.contains($0.path)
                && !$0.families.isDisjoint(with: vaultType.families)
        }
    }

    private func indexOf(_ collection: CollectionDescriptor) -> Int {
        Collections.all.firstIndex(of: collection) ?? Int.max
    }

    /// Nil means the server has not supplied this count yet; it must not be presented as zero.
    func count(of collection: CollectionDescriptor) -> Int? {
        overview?.count(of: collection)
    }

    /// Whether this space published anything the Debates screen could show. Debates are
    /// derived from edges, so the signal is edges, not a table of its own.
    var hasDebates: Bool { (overview?.counts["edges"] ?? 0) > 0 }
    var hasNotes: Bool { (overview?.counts["notes"] ?? 0) > 0 }
    var hasDeepResearch: Bool { (overview?.counts["writing_saved_drafts"] ?? 0) > 0 }
    var hasImmersion: Bool { (overview?.counts["immersion_sessions"] ?? 0) > 0 }
}

enum EmbeddingProbeResult: Equatable {
    case unknown
    /// The vault has vectors, indexed with this identity.
    case published(EmbeddingIdentity)
    /// The owner published no vectors at all. Search is lexical, and that is not a fault.
    case noVectors
    case unavailable(String)

    /// Whether an iOS client could ever produce a matching query vector.
    ///
    /// `ollama`, `lmstudio` and `nodus` are the desktop's own runtimes; a phone cannot reach
    /// or run any of them, so a vault indexed with one is honestly lexical-only here.
    var isReachableFromPhone: Bool {
        guard case .published(let identity) = self else { return false }
        return ["openai", "gemini", "openrouter"].contains(identity.provider)
    }
}
