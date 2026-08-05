import Foundation
import NodusKit

/// The example vault the app carries inside itself.
///
/// The first screen of this app asks for a server address. Somebody who installs it with no
/// Nodus Server to point it at sees a form and nothing else — and that somebody includes
/// whoever reviews it for the App Store, who has no vault, no desktop and no account, and who
/// is asked to judge an app that will not show them a single screen of what it does.
///
/// So one corpus ships in the bundle: `Resources/demo-space.json.gz`, a published snapshot in
/// the format `NodusClient.snapshot(in:)` reads off the wire, built by
/// `ios/scripts/make-demo-snapshot.mjs` from public-domain works. Opening it imports the
/// snapshot into a mirror of its own and hands the session a client that answers from that
/// mirror (`LocalCorpus`). Nothing is fetched, nothing is stored anywhere else, and no socket
/// is opened — which is what makes it work in aeroplane mode on a device that has never seen a
/// Nodus Server.
enum DemoSpace {
    /// Where the demo claims to come from.
    ///
    /// Not a URL anything could reach, and deliberately not one `ServerAddress(validating:)`
    /// would accept: it is an identity, not an address, and it is what tells the rest of the
    /// app that this connection has no server behind it. Everything else about the demo —
    /// whether it needs a credential, whether a background task may touch it — is read from
    /// this one value rather than from a stored flag, so a connection saved by an older build
    /// cannot decode as a demo by accident and a demo cannot lose the mark by being persisted.
    static let origin = "nodus-demo://this-device"

    /// The space id, which is also the directory its mirror lives in. Prefixed so it can never
    /// collide with a server-issued UUID.
    static let spaceId = "nodus-demo-space"

    /// What the card on the picker says.
    ///
    /// Rebuilt from the catalogue every time the list is read rather than trusted from
    /// `UserDefaults`, so the demo does not stay in whatever language the phone was in the
    /// first time it was opened.
    static var spaceName: String { String(localized: "Example vault") }
    static var serverName: String { String(localized: "On this device") }

    /// The languages a corpus was built for, and the one to fall back to.
    ///
    /// Matched against `Bundle.main.preferredLocalizations`, which is what iOS already resolved
    /// for the interface: a phone set to French runs this app in English and gets the English
    /// corpus, and the two agree without this having to repeat the resolution.
    private static let corpusLanguages = ["en", "es"]
    private static let fallbackLanguage = "en"

    static var language: String {
        let preferred = Bundle.main.preferredLocalizations.first.map { String($0.prefix(2)) }
        return corpusLanguages.contains(preferred ?? "") ? preferred! : fallbackLanguage
    }

    /// The published bytes, exactly as they were compiled in.
    ///
    /// One snapshot per language rather than one carrying both. A corpus is not chrome: the
    /// idea a reader opens has a statement, a development and a work summary, and half a screen
    /// of English under a Spanish heading reads as an unfinished app rather than as a corpus in
    /// another language. The two files are twelve kilobytes each.
    static func archive() throws -> Data {
        guard let url = Bundle.main.url(forResource: "demo-space.\(language)", withExtension: "json.gz")
            ?? Bundle.main.url(forResource: "demo-space.\(fallbackLanguage)", withExtension: "json.gz")
        else {
            throw DemoUnavailable.missingResource
        }
        return try Data(contentsOf: url)
    }

    enum DemoUnavailable: LocalizedError {
        case missingResource

        var errorDescription: String? {
            String(localized: "This build carries no example vault.")
        }
    }

    /// Everything an open demo session needs, with its mirror imported and current.
    ///
    /// The import is skipped when the mirror already holds this revision, which is the ordinary
    /// case after the first launch. Two things make it stale, and the revision catches both
    /// without either being special-cased: a newer build carrying a newer corpus, and the phone
    /// being switched to a language whose corpus is a different document.
    static func prepare() async throws -> (connection: AppModel.Connection, corpus: LocalCorpus) {
        let archive = try archive()
        let snapshot = try SnapshotDownload.read(archive)
        let revision = snapshot.revision ?? ""

        let mirror = try await MirrorStore.open(spaceId: spaceId, directory: ConnectionClient.spacesDirectory)
        if try await !mirror.isCurrent(with: revision) {
            try await mirror.replace(with: snapshot, revision: revision)
        }

        let corpus = LocalCorpus(
            space: LocalCorpus.Space(
                id: spaceId,
                name: spaceName,
                description: String(localized: "A small corpus of public-domain works, so the app has something to show without a server.")
            ),
            mirror: mirror,
            archive: archive
        )
        return (connection(from: snapshot), corpus)
    }

    /// A connection like any other, except that it holds no credential and names no server.
    ///
    /// `.reader` is not a placeholder: the demo really is read-only, and the role is what makes
    /// the app say so on Home and keep the send queue off a vault that has nowhere to send to.
    static func connection(from snapshot: SnapshotDownload? = nil) -> AppModel.Connection {
        AppModel.Connection(
            origin: origin,
            spaceId: spaceId,
            spaceName: spaceName,
            serverName: serverName,
            role: .reader,
            vaultType: snapshot?.vault?.type ?? .academic,
            vaultName: snapshot?.vault?.name
        )
    }

    /// The stored connection with its display names taken from the catalogue again.
    static func refreshed(_ connection: AppModel.Connection) -> AppModel.Connection {
        var copy = connection
        copy.spaceName = spaceName
        copy.serverName = serverName
        return copy
    }

    /// Everything the demo left on disk.
    ///
    /// Its mirror is a whole SQLite database in Application Support, and forgetting a demo that
    /// leaves one behind is not forgetting it. Deleted by directory rather than by
    /// `MirrorStore.drop()`, which empties the tables and keeps the file.
    static func removeStoredData() {
        try? FileManager.default.removeItem(
            at: ConnectionClient.spacesDirectory.appendingPathComponent(spaceId, isDirectory: true)
        )
    }
}
