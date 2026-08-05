import Foundation

/// What a Nodus Server said when it refused.
///
/// Two error shapes coexist on the wire: the OAuth-style `{error, error_description}` that the
/// machine surfaces use, and a bare `{error: "<message>"}` from the older handlers. Both are
/// decoded here, along with the extra fields some errors carry — `limitBytes` on a 413,
/// `required`/`actual` on a 403, `expected`/`received` on an embedding mismatch, `missing` on
/// a mutation batch whose images have not been uploaded yet.
public struct APIError: Error, Sendable, Hashable {
    public let status: Int
    /// The snake_case machine code, when there is one.
    public let code: String?
    /// The human sentence, or the bare message from the older shape.
    public let message: String?
    /// Everything else the body carried, preserved rather than discarded.
    public let details: [String: JSONValue]
    public let retryAfter: TimeInterval?

    public init(
        status: Int,
        code: String? = nil,
        message: String? = nil,
        details: [String: JSONValue] = [:],
        retryAfter: TimeInterval? = nil
    ) {
        self.status = status
        self.code = code
        self.message = message
        self.details = details
        self.retryAfter = retryAfter
    }

    /// The space exists and the caller may read it, but its owner has never published.
    ///
    /// This is an empty state, not a failure. Treating it as an error is the single easiest
    /// way to make the app lie about a perfectly healthy vault, so it gets its own name and
    /// every screen checks for it.
    public var isNotPublished: Bool { status == 409 && code == "not_published" }

    /// The token is gone, expired, or belongs to a different space.
    ///
    /// A device token scoped to another space answers 401 rather than 403 — deliberately, so
    /// membership cannot be probed by status code (`server/lib/auth.mjs:159-161`). So a 401
    /// never proves the token is invalid in general; it proves it is not valid *here*.
    public var isUnauthorized: Bool { status == 401 }

    public var isForbidden: Bool { status == 403 }
    public var isRateLimited: Bool { status == 429 }
    public var isNotFound: Bool { status == 404 }

    /// On a 403 the server names what the route demanded and what the caller holds — in two
    /// different vocabularies. `required` is a need (`write`), `actual` is a role (`reader`).
    public var requiredNeed: SpaceNeed? { details["required"]?.stringValue.flatMap(SpaceNeed.init(rawValue:)) }
    public var actualRole: SpaceRole? { details["actual"]?.stringValue.flatMap(SpaceRole.init(rawValue:)) }

    /// The ceiling a 413 bumped into, so the message can name it instead of guessing.
    public var limitBytes: Int? { details["limitBytes"]?.intValue ?? details["limit"]?.intValue }

    public static func decode(status: Int, data: Data, headers: [AnyHashable: Any]) -> APIError {
        let retryAfter = (headers["Retry-After"] as? String).flatMap(TimeInterval.init)
            ?? (headers["retry-after"] as? String).flatMap(TimeInterval.init)

        guard
            let object = try? JSONDecoder().decode([String: JSONValue].self, from: data),
            let raw = object["error"]
        else {
            let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return APIError(status: status, message: body?.isEmpty == false ? body : nil, retryAfter: retryAfter)
        }

        let value = raw.stringValue
        let description = object["error_description"]?.stringValue
        var details = object
        details.removeValue(forKey: "error")
        details.removeValue(forKey: "error_description")

        // The bare shape puts a sentence where the machine shape puts a code. A value with a
        // space in it was never a code.
        let looksLikeCode = value.map { !$0.contains(" ") } ?? false
        return APIError(
            status: status,
            code: looksLikeCode ? value : nil,
            message: description ?? value,
            details: details,
            retryAfter: retryAfter
        )
    }
}

extension APIError: LocalizedError {
    public var errorDescription: String? {
        if let message, !message.isEmpty { return message }
        if let code { return code }
        return "HTTP \(status)"
    }
}

/// Failures that never reached a Nodus Server, or that came back malformed.
public extension Error {
    /// A read that was superseded is not a read that failed.
    ///
    /// Pull-to-refresh is where this matters: SwiftUI cancels the task behind `.refreshable`
    /// when the gesture is released early or the view goes away, `URLSession` reports that as
    /// `URLError.cancelled`, and a screen that files every error under one banner then tells
    /// the reader their space could not be read — over a space it is showing them.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let transport = self as? TransportError, transport == .cancelled { return true }
        if let url = self as? URLError, url.code == .cancelled { return true }
        return false
    }
}

public enum TransportError: Error, Sendable, Equatable {
    case offline
    case cancelled
    case timedOut
    /// Nothing answers to that name.
    ///
    /// Kept apart from `cannotConnect` because the two need opposite things from the user, and
    /// flattening both into one sentence is what made "could not connect" useless: a Nodus
    /// Server usually lives on a private network, and this is the case where the *device* is
    /// not on it.
    case hostNotFound
    /// The name resolves and nothing is listening behind it.
    case cannotConnect
    /// TLS refused: an untrusted, expired or self-signed certificate.
    case certificateRejected
    /// iOS blocked the request for being plain HTTP to something that is not this device.
    case insecureBlocked
    /// The origin is not a valid absolute URL, or carries a path/query the server would reject.
    case badServerURL(String)
    /// A 2xx whose body did not match the documented shape. Carries what was expected.
    case malformedResponse(expected: String)
    case underlying(String)

    /// The one place a `URLError` becomes a Nodus error.
    ///
    /// Static and pure so the mapping can be tested without a network — the cases below are
    /// exactly the ones a user hits while pointing the app at a server for the first time.
    public static func from(_ error: URLError) -> TransportError {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed:
            return .offline
        case .cancelled:
            return .cancelled
        case .timedOut, .networkConnectionLost:
            return .timedOut
        case .cannotFindHost, .dnsLookupFailed:
            return .hostNotFound
        case .cannotConnectToHost:
            return .cannotConnect
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return .certificateRejected
        case .appTransportSecurityRequiresSecureConnection:
            return .insecureBlocked
        default:
            return .underlying(error.localizedDescription)
        }
    }
}

extension TransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .offline: return "No connection."
        case .cancelled: return "Cancelled."
        case .timedOut: return "The server took too long to answer."
        case .hostNotFound:
            return "No machine by that name. If the server is on a private network — Tailscale, a VPN, your own Wi‑Fi — this device has to be on it too."
        case .cannotConnect:
            return "The name resolves, but nothing answered. The server may be stopped, or reachable only from the machine it runs on."
        case .certificateRejected:
            return "The certificate was refused. A Nodus Server needs one this device already trusts."
        case .insecureBlocked:
            return "iOS refuses plain HTTP to anything but this device. Use an https:// address."
        case .badServerURL(let value): return "Not a usable server address: \(value)"
        case .malformedResponse(let expected): return "Unexpected answer from the server (expected \(expected))."
        case .underlying(let value): return value
        }
    }
}

// MARK: - Why the connection failed

/// Why the app could not reach a Nodus Server, decided once and in one place.
///
/// A Nodus Server runs on somebody's own computer. It goes away when that computer sleeps,
/// when it changes network, and when its owner quits the desktop application — and every one
/// of those used to arrive on screen as the same sentence about a connection that could not be
/// made, which is true of all of them and useful for none.
///
/// The cases are exactly the ones a person does something different about: join a network,
/// wake a computer, correct an address, update one of the two sides, trust a certificate, sign
/// in again. `classify` is the only thing that chooses between them; it is pure, and it is
/// tested without a network, because the code a user meets first should not be the code with
/// the least coverage.
///
/// The sentences are *not* here. NodusKit has no string catalogue — a literal returned from
/// this package is English on every phone — so the typed case crosses into the app and the
/// wording is chosen on that side, where it can be translated.
public enum ConnectionFailure: Error, Sendable, Hashable {
    /// This device has no network at all. Nothing was contacted, so nothing else is known.
    case noNetwork
    /// What was typed is not an origin. Nothing was contacted for this one either.
    case badAddress(String)
    /// The name does not resolve. Almost always this device sitting outside the private
    /// network — Tailscale, a VPN, a home Wi-Fi — that the server is only reachable from.
    case unknownHost(host: String)
    /// The address is fine and nothing answered: the frequent one, and the whole reason this
    /// type exists. The computer is off, asleep, or has Nodus desktop closed.
    case noAnswer(host: String)
    /// Something is listening there and it is not a Nodus Server.
    case notNodusServer(host: String, evidence: Impostor)
    /// It is a Nodus Server, and it is not one this build can read.
    case versionGap(VersionGap)
    /// TLS refused. Expected, and recoverable, on the desktop's basic local-network mode: it
    /// serves HTTPS with a certificate from an authority it generated itself.
    case untrustedCertificate(host: String, fingerprint: String?)
    /// iOS blocked plain HTTP to something that is not this device.
    case insecureBlocked(host: String)
    /// The credential this device holds is not accepted here any more.
    case credentialRejected(host: String)
    /// The server answered, understood the request, and said no. Its own sentence is the best
    /// one available and the caller renders it.
    case refused(APIError)
    /// A failure with no name of its own yet. `detail` is the system's own words: they belong
    /// in the diagnostics report, never in the first line on screen.
    case unclassified(host: String, detail: String)

    /// What answered instead of a Nodus Server.
    public enum Impostor: Sendable, Hashable {
        /// An HTTP status where a Nodus Server always answers 200 — a router page, a reverse
        /// proxy with nothing behind it, a different application on the same port.
        case status(Int)
        /// A 200 whose body is not the shape `/api/v1/capabilities` documents.
        case malformedBody
        /// `/healthz` answered and named somebody else.
        case otherService(String)
    }

    /// Which door was knocked on, because one status means two different things depending.
    public enum Knock: Sendable, Hashable {
        /// `/healthz` or `/api/v1/capabilities`: public, and a Nodus Server never asks for
        /// credentials there. A 401 from one of these is something *else* guarding the
        /// address, not a credential this device should replace.
        case unauthenticated
        /// A route that carried this device's token, where a 401 means what it says.
        case credentialed
    }

    /// Two releases side by side, and which of them is the older one.
    public struct VersionGap: Sendable, Hashable {
        public enum Side: Sendable, Hashable {
            case app
            case server
            /// Neither release number is readable, so only "they differ" can be said.
            case indeterminate
        }

        public let appVersion: String
        /// Nil for a server older than the shared version scheme, which states no version at
        /// all. "Unknown" is the honest thing to show for one.
        public let serverVersion: String?
        public let appSnapshotVersions: [Int]
        public let serverSnapshotVersions: [Int]
        public let serverAPI: String
        public let behind: Side

        public init(
            appVersion: String,
            serverVersion: String?,
            appSnapshotVersions: [Int],
            serverSnapshotVersions: [Int],
            serverAPI: String,
            behind: Side
        ) {
            self.appVersion = appVersion
            self.serverVersion = serverVersion
            self.appSnapshotVersions = appSnapshotVersions
            self.serverSnapshotVersions = serverSnapshotVersions
            self.serverAPI = serverAPI
            self.behind = behind
        }

        public var sharesASnapshotFormat: Bool {
            !Set(appSnapshotVersions).isDisjoint(with: Set(serverSnapshotVersions))
        }

        public var speaksAKnownAPI: Bool { serverAPI == ServerCapabilities.knownAPI }

        /// Whether this is a difference that actually stops the app, as opposed to two release
        /// numbers that merely differ. Only the first is a failure; the second is a caution the
        /// settings screen has shown for a while and should keep showing.
        public var blocks: Bool { !sharesASnapshotFormat || !speaksAKnownAPI }
    }
}

public extension ConnectionFailure {
    /// The whole classifier: one failure, chosen from everything that is known about one
    /// attempt to reach a server.
    ///
    /// Returns nil when there is nothing to report — a cancelled read, or a probe that
    /// succeeded against a server this build understands. Every argument is a value, so the
    /// order the cases are checked in can be pinned by a test rather than reproduced by hand
    /// against a real server that is misbehaving in exactly the right way.
    ///
    /// - Parameters:
    ///   - error: what the request threw, if it threw.
    ///   - capabilities: what `/api/v1/capabilities` answered, if it answered.
    ///   - health: what `/healthz` answered, if it answered. Only used to sharpen "something
    ///     else is at this address" into naming the something else.
    ///   - network: whether this device has a network at all, measured before knocking.
    ///   - fingerprint: the leaf certificate seen during a handshake that was then refused.
    static func classify(
        error: (any Error)?,
        capabilities: ServerCapabilities? = nil,
        health: ServerHealth? = nil,
        origin: String,
        network: NetworkStatus,
        knock: Knock,
        appVersion: String,
        fingerprint: String? = nil
    ) -> ConnectionFailure? {
        let host = Self.host(of: origin)

        if let error {
            // A read that was superseded is not a read that failed, and it must not be allowed
            // to paint a notice over a screen that is working.
            if error.isCancellation { return nil }

            if let transport = error as? TransportError {
                switch transport {
                // Checked before the network, and deliberately: nothing was contacted for
                // this one, so "no network" would be a true statement about the wrong thing.
                case .badServerURL(let value):
                    return .badAddress(value)
                // Also before the network. iOS refuses these two by looking at the address and
                // the certificate, not at the route to them, and telling somebody to check
                // their Wi-Fi when the certificate is the problem sends them the wrong way.
                case .certificateRejected:
                    return .untrustedCertificate(host: host, fingerprint: fingerprint)
                case .insecureBlocked:
                    return .insecureBlocked(host: host)
                default:
                    break
                }
            }

            // From here on, everything is a statement about a network this device may not
            // have. If it does not, that is the only true thing to say.
            if network == .down { return .noNetwork }

            if let transport = error as? TransportError {
                switch transport {
                case .offline:
                    return .noNetwork
                case .hostNotFound:
                    return .unknownHost(host: host)
                // Both are silence. A refused connection is a computer that is awake with
                // nothing listening; a timeout is one that is asleep or behind a tunnel that
                // no longer goes anywhere. The user does the same thing about either.
                case .cannotConnect, .timedOut:
                    return .noAnswer(host: host)
                case .malformedResponse:
                    return .notNodusServer(host: host, evidence: Self.namedImpostor(from: health) ?? .malformedBody)
                case .underlying(let detail):
                    return .unclassified(host: host, detail: detail)
                case .badServerURL, .certificateRejected, .insecureBlocked, .cancelled:
                    break // Settled above.
                }
            }

            if let api = error as? APIError {
                switch knock {
                case .credentialed where api.isUnauthorized:
                    return .credentialRejected(host: host)
                // A Nodus Server answers its public routes without ever asking who is calling.
                // Anything that does ask is a proxy or an appliance in front of — or instead
                // of — the server, and replacing this device's credential would not touch it.
                case .unauthenticated where api.isUnauthorized || api.isForbidden:
                    return .notNodusServer(host: host, evidence: .status(api.status))
                default:
                    break
                }
                // A public route that a Nodus Server serves, answered by something that has
                // never heard of it.
                if api.isNotFound || api.status == 400 || (500...599).contains(api.status) {
                    return .notNodusServer(host: host, evidence: Self.namedImpostor(from: health) ?? .status(api.status))
                }
                return .refused(api)
            }

            return .unclassified(host: host, detail: error.localizedDescription)
        }

        // Nothing failed. The remaining way to be unreachable is to be a server this build
        // cannot read, which only the capabilities answer can say.
        if let health, let other = health.namesAnotherService, capabilities == nil {
            return .notNodusServer(host: host, evidence: .otherService(other))
        }
        if let capabilities {
            let gap = Self.gap(between: capabilities, appVersion: appVersion)
            if gap.blocks { return .versionGap(gap) }
        }
        return nil
    }

    /// The two releases side by side, whether or not the difference blocks anything.
    ///
    /// Snapshot formats decide who is behind whenever they can: they are the thing that
    /// actually breaks, and they are ordered, so a server publishing only format 1 against a
    /// build that reads only 3 names the server without either release number being readable.
    /// The release numbers settle the rest, and when neither is a number the gap is real and
    /// unattributed — which is more honest than guessing at whose side to blame.
    static func gap(between capabilities: ServerCapabilities, appVersion: String) -> VersionGap {
        let app = SnapshotFormat.supportedVersions.sorted()
        let server = capabilities.snapshotVersions.sorted()
        let serverVersion = capabilities.server.version ?? capabilities.version

        var behind = VersionGap.Side.indeterminate
        if let serverHighest = server.max(), let appLowest = app.min(), serverHighest < appLowest {
            behind = .server
        } else if let serverLowest = server.min(), let appHighest = app.max(), serverLowest > appHighest {
            behind = .app
        } else if let serverVersion, let order = NodusVersion.compare(appVersion, serverVersion) {
            switch order {
            case .orderedAscending: behind = .app
            case .orderedDescending: behind = .server
            case .orderedSame: behind = .indeterminate
            }
        }

        return VersionGap(
            appVersion: appVersion,
            serverVersion: serverVersion,
            appSnapshotVersions: app,
            serverSnapshotVersions: server,
            serverAPI: capabilities.api,
            behind: behind
        )
    }

    /// The host, with its port when it has one — a right name on a wrong port is a real way to
    /// reach nothing, and a message that hides the port cannot say so.
    static func host(of origin: String) -> String {
        guard let components = URLComponents(string: origin), let host = components.host, !host.isEmpty else {
            return origin
        }
        guard let port = components.port else { return host }
        return "\(host):\(port)"
    }

    /// `/healthz` naming somebody else is the best evidence there is, so it wins over the
    /// status code whenever it exists.
    private static func namedImpostor(from health: ServerHealth?) -> Impostor? {
        health?.namesAnotherService.map(Impostor.otherService)
    }
}
