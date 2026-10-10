import Foundation

/// What an account may do in one space.
///
/// The level is re-read from the memberships on every single request
/// (`server/lib/auth.mjs:151`), so a downgrade takes effect on the caller's next call even
/// with a token they already hold. The client therefore treats a cached role as a hint for
/// laying out the UI, never as permission — the server is asked, always.
public enum SpaceRole: String, Sendable, Hashable, Codable, Comparable, CaseIterable {
    case reader
    case writer
    case owner

    private var rank: Int {
        switch self {
        case .reader: return 0
        case .writer: return 1
        case .owner: return 2
        }
    }

    public static func < (lhs: SpaceRole, rhs: SpaceRole) -> Bool { lhs.rank < rhs.rank }

    public var canSendChanges: Bool { satisfies(.write) }
    public var canDrainLedger: Bool { satisfies(.own) }

    /// The server's own `can(role, need)` (`server/lib/roles.mjs:31-38`).
    public func satisfies(_ need: SpaceNeed) -> Bool { rank >= need.rank }
}

/// What a route demands, which is *not* spelled the way a role is.
///
/// `server/lib/roles.mjs` keeps two ranked vocabularies side by side: memberships hold a role
/// (`reader`/`writer`/`owner`) and routes declare a need (`read`/`write`/`own`). A 403 body
/// reports one of each — `{required: "write", actual: "reader"}` — so a client that decodes
/// both fields as the same type silently loses `required`, and the resulting message tells
/// the user nothing about what the route actually wanted.
public enum SpaceNeed: String, Sendable, Hashable, Codable, CaseIterable {
    case read
    case write
    case own

    var rank: Int {
        switch self {
        case .read: return 0
        case .write: return 1
        case .own: return 2
        }
    }

    /// The lowest role that satisfies this need, for a message that can name a way forward.
    public var lowestSufficientRole: SpaceRole {
        switch self {
        case .read: return .reader
        case .write: return .writer
        case .own: return .owner
        }
    }
}

/// The nine vault types, transcribed from `shared/vaultTypes.ts:21-30`.
///
/// The server publishes the type in the space header so a client can pick a menu, but it
/// never gates a route on it. A vault with no people simply has no rows in `persons`.
public enum VaultType: String, Sendable, Hashable, Codable, CaseIterable {
    case academic
    case primarySources = "primary_sources"
    case testimonios
    case databases
    case docencia
    case estudio
    case genealogy
    case prosopography
    case worldbuilding

    /// The accent, matching `VAULT_TYPE_COLORS` in `shared/vaultTypes.ts:283-293` exactly.
    /// Kept as a hex string here so NodusKit stays free of SwiftUI; NodusUI turns it into a
    /// `Color`.
    public var accentHex: String {
        switch self {
        case .academic, .primarySources: return "#6366f1"
        case .testimonios: return "#0891b2"
        case .databases: return "#b30333"
        case .docencia: return "#ea580c"
        case .estudio: return "#0f766e"
        case .genealogy: return "#ca8a04"
        case .prosopography: return "#2563eb"
        case .worldbuilding: return "#7c3aed"
        }
    }

    public var families: Set<VaultFamily> {
        switch self {
        case .academic, .primarySources, .testimonios: return [.academic]
        case .genealogy, .prosopography: return [.records, .academic]
        case .worldbuilding: return [.records, .academic]
        case .estudio: return [.study, .academic]
        case .docencia: return [.study, .teaching, .academic]
        case .databases: return [.databases]
        }
    }
}

/// One space as the server describes it in `/auth/login` and `/me`.
public struct SpaceSummary: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    public let role: SpaceRole
    /// The published vault descriptor. Absent until the owner publishes for the first time.
    public let vault: VaultDescriptor?
    public let updatedAt: Date?
    public let revision: String?
    public let schemaVersion: Int?
    public let hasSnapshot: Bool
    /// How far into this space's ledger the owner's desktop has acknowledged.
    ///
    /// The server publishes it so a client can tell "the server is holding this" apart from
    /// "the owner has collected it": a device keeps the `cursor` its own POST came back with,
    /// and this is the number that eventually catches up with it.
    ///
    /// Nil means the server does not publish it, and nil is emphatically not zero. Reading a
    /// silence as a cursor of zero would leave every queued change permanently undelivered,
    /// and defaulting it the other way would report deliveries that never happened.
    public let mutationCursor: Int?

    public init(
        id: String,
        name: String,
        description: String? = nil,
        role: SpaceRole,
        vault: VaultDescriptor? = nil,
        updatedAt: Date? = nil,
        revision: String? = nil,
        schemaVersion: Int? = nil,
        hasSnapshot: Bool = false,
        mutationCursor: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.role = role
        self.vault = vault
        self.updatedAt = updatedAt
        self.revision = revision
        self.schemaVersion = schemaVersion
        self.hasSnapshot = hasSnapshot
        self.mutationCursor = mutationCursor
    }
}

/// What the publication says about the vault behind a space.
public struct VaultDescriptor: Sendable, Hashable, Codable {
    public let id: String?
    public let name: String?
    public let type: VaultType?

    public init(id: String? = nil, name: String?, type: VaultType?) {
        self.id = id
        self.name = name
        self.type = type
    }

    private enum CodingKeys: String, CodingKey { case id, name, type }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        // An unknown type must not fail the whole space: a server ahead of this build may
        // publish a vault kind this app has never heard of, and the corpus is still readable.
        type = try container.decodeIfPresent(String.self, forKey: .type).flatMap(VaultType.init(rawValue:))
    }
}

public struct UserSummary: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let email: String
    /// Server-wide role: `admin` or `member`. Distinct from the per-space `SpaceRole`.
    public let role: String

    public init(id: String, email: String, role: String) {
        self.id = id
        self.email = email
        self.role = role
    }
}

public struct ServerInfo: Sendable, Hashable, Codable {
    public let name: String
    public let publicUrl: String?
    public let language: String?
    /// The release the server is running. Optional because a server older than the shared
    /// version scheme does not send it — and "unknown" is the honest thing to show for one.
    public let version: String?

    public init(name: String, publicUrl: String?, language: String?, version: String? = nil) {
        self.name = name
        self.publicUrl = publicUrl
        self.language = language
        self.version = version
    }
}

/// This build of the app, as Info.plist declares it.
///
/// The desktop, the server and this app ship as one release and carry one number; a screen
/// that shows this beside the server's is what turns a compatibility problem into something a
/// person can read out loud instead of something they have to reproduce.
public enum NodusVersion {
    public static let current: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }()

    /// Order two releases, or refuse to.
    ///
    /// Dot-separated integers, most significant first, missing places read as zero — the shape
    /// the three parts are actually numbered in. Nil when either side is not that shape: a
    /// server older than the shared version scheme states no version at all, and inventing an
    /// order for "unknown" would name the wrong side as the one to update.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let left = places(in: lhs), let right = places(in: rhs) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let one = index < left.count ? left[index] : 0
            let other = index < right.count ? right[index] : 0
            guard one != other else { continue }
            return one < other ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    private static func places(in value: String) -> [Int]? {
        let segments = value.trimmingCharacters(in: .whitespaces).split(separator: ".")
        guard !segments.isEmpty else { return nil }
        let numbers = segments.compactMap { Int($0) }
        // All of them or none: "3.2.2-rc1" is a release this comparison has no opinion about,
        // and half-parsing it to 3.2 would claim it is older than the release it precedes.
        guard numbers.count == segments.count else { return nil }
        return numbers
    }
}

/// `GET /api/v1/capabilities` — public, unauthenticated, and the first call the app makes.
///
/// Every ceiling here is read rather than hard-coded. A server configured with a different
/// `NODUS_MAX_ASSET_BYTES` is a supported deployment, not a bug to work around.
public struct ServerCapabilities: Sendable, Hashable, Codable {
    public let api: String
    /// The release the server is running, beside `server.version` so either shape answers.
    /// Optional: a server older than the shared version scheme sends neither.
    public let version: String?
    public let server: ServerInfo
    public let snapshotVersions: [Int]
    public let assets: Bool
    /// Rich documents from the published Global Library can be downloaded independently of
    /// the snapshot. Optional so a pre-4.2 server keeps decoding.
    public let libraryDocuments: Bool?
    public let mutations: Bool
    /// The wire shape used for collaborative page updates.
    public let documentUpdates: String?
    /// Large binary payloads travel in resumable chunks rather than through mutations.
    public let sharedBlobs: SharedBlobCapabilities?
    public let vectors: Bool
    public let resources: [String: String]
    public let maxAssetBytes: Int
    public let maxSpaceAssetBytes: Int
    public let maxSnapshotBytes: Int
    public let maxSnapshotJsonBytes: Int
    public let maxLibraryPackageBytes: Int?
    public let maxSpaceLibraryBytes: Int?
    public let maxMutationBatch: Int
    /// One change, one request full of them, and the queue a space may hold undelivered.
    ///
    /// Optional because servers before 3.2.1 publish none of them, and that silence is exactly
    /// why a Deep Research report could only discover the ceiling by being refused by it. A nil
    /// means "this server will not say", and every caller has to keep working without it.
    public let maxMutationBytes: Int?
    public let maxMutationBatchBytes: Int?
    public let maxLedgerBytes: Int?
    /// `sse` on servers that can wake replicas as soon as the ledger changes.
    public let mutationEvents: String?
    public let presence: PresenceCapabilities?
    /// Typed work that the owner Desktop may claim. Nil on older servers.
    public let spaceActions: SpaceActionCapabilities?
    /// Account-global immutable Library sync, deliberately separate from a space publication.
    public let accountLibrarySync: AccountLibrarySyncCapabilities?
    /// Discovery only. A cloud server must always publish `relay == false`; private data is
    /// fetched from the Mac named by a local pairing, never through this origin.
    public let desktopBridge: DesktopBridgeCapabilities?

    /// The OAuth protected-resource identifier for `/api/v1`.
    ///
    /// `/mcp` and `/api/v1` are two separate protected resources over one origin, and a token
    /// minted for one is refused by the other (`server/lib/auth.mjs:76`). Getting this wrong
    /// produces a 401 that looks like bad credentials and is not.
    public var apiResource: String? { resources["api"] }
    public var mcpResource: String? { resources["mcp"] }

    /// This build understands snapshot format versions 1 and 2.
    public var supportsAnyKnownSnapshotVersion: Bool {
        snapshotVersions.contains { SnapshotFormat.supportedVersions.contains($0) }
    }

    /// The API generation this build speaks. Every path in `NodusClient` is `/api/v1/…`, so a
    /// server that answers with any other generation is one this build cannot address at all,
    /// however recent its release number happens to be.
    public static let knownAPI = "v1"

    public var speaksAKnownAPI: Bool { api == Self.knownAPI }

    public var supportsDocumentUpdates: Bool { documentUpdates == "content-addressed-binary" }
    public var supportsSharedBlobs: Bool { sharedBlobs?.transport == "resumable-chunks" }
    public var supportsMutationEvents: Bool { mutationEvents == "sse" }
    public var supportsPresence: Bool { presence?.transport == "ephemeral-sse" }
    public var supportsSpaceActions: Bool { spaceActions?.schemaVersion == 1 }
    public var supportsAccountLibrarySync: Bool { accountLibrarySync?.schemaVersion == 1 }
    public var guaranteesPrivateBridge: Bool { desktopBridge?.relay == false && desktopBridge?.transport == "private-tls" }
}

public struct SpaceActionCapabilities: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let statuses: [String]
}

public struct AccountLibrarySyncCapabilities: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let immutableVersions: Bool
    public let objects: String
    public let maxRecordBatch: Int
}

public struct DesktopBridgeCapabilities: Sendable, Hashable, Codable {
    public let `protocol`: String
    public let relay: Bool
    public let transport: String
}

public struct SharedBlobCapabilities: Sendable, Hashable, Codable {
    public let transport: String
    public let chunkBytes: Int
    public let maxBytes: Int
}

public struct PresenceCapabilities: Sendable, Hashable, Codable {
    public let transport: String
    public let ttlSeconds: Int
}

public enum SnapshotFormat {
    public static let identifier = "nodus.server-snapshot"
    public static let supportedVersions: Set<Int> = [1, 2]
    public static let contentType = "application/vnd.nodus.snapshot+json"
}

/// The single-use ticket from `POST /auth/login`, good for five minutes.
public struct LoginTicket: Sendable, Hashable {
    public let ticket: String
    public let expiresIn: TimeInterval
    public let user: UserSummary
    public let spaces: [SpaceSummary]
    public let server: ServerInfo
}

/// The credential from `POST /auth/device`, stored in the Keychain and scoped to one space.
public struct DeviceCredential: Sendable, Hashable {
    public let token: String
    public let spaceId: String
    public let spaceName: String
    public let role: SpaceRole
    public let vault: VaultDescriptor?
    public let capabilities: ServerCapabilities?
}
