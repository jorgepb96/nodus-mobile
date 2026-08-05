import Foundation

/// One question asked of a server, and what came back.
public struct ConnectionCheck: Sendable, Hashable, Identifiable {
    /// The questions, in the order they are worth asking. Each one is only meaningful once the
    /// one before it has passed, which is why a run stops at the first failure rather than
    /// producing six red lines about one sleeping computer.
    public enum Step: String, Sendable, Hashable, CaseIterable {
        case network
        case reachable
        case certificate
        case identity
        case version
        case credential
    }

    public enum Outcome: Sendable, Hashable {
        /// `detail` is data — an interface, a version, a fingerprint — and never a sentence.
        /// The sentences are chosen in the app, where they can be translated.
        case passed(String?)
        case failed(ConnectionFailure)
        /// Not asked, because an earlier answer settled it.
        case skipped
    }

    public let step: Step
    public let outcome: Outcome
    public var id: Step { step }

    public init(step: Step, outcome: Outcome) {
        self.step = step
        self.outcome = outcome
    }

    public var failure: ConnectionFailure? {
        guard case .failed(let failure) = outcome else { return nil }
        return failure
    }

    public var detail: String? {
        guard case .passed(let detail) = outcome else { return nil }
        return detail
    }
}

public extension ConnectionFailure {
    /// The check this failure answers, so a diagnostics screen puts it on the line it belongs
    /// to rather than at the bottom.
    ///
    /// `badAddress` sits under `reachable` because it is the same conclusion reached earlier:
    /// nothing was contacted, and nothing is going to be.
    var step: ConnectionCheck.Step {
        switch self {
        case .noNetwork: return .network
        case .badAddress, .unknownHost, .noAnswer, .unclassified: return .reachable
        case .untrustedCertificate, .insecureBlocked: return .certificate
        case .notNodusServer, .refused: return .identity
        case .versionGap: return .version
        case .credentialRejected: return .credential
        }
    }

    /// The failure as one technical line, for the copyable report and nothing else.
    ///
    /// Deliberately not the sentence shown on screen: that one is written for the person
    /// holding the phone and translated for them. This one is written for whoever runs the
    /// server, in one language, so a report pasted into a message says the same thing to them
    /// wherever the phone that produced it was set.
    var transcript: String {
        switch self {
        case .noNetwork:
            return "this device has no network"
        case .badAddress(let value):
            return "not a usable server address: \(value)"
        case .unknownHost(let host):
            return "\(host) does not resolve from this device"
        case .noAnswer(let host):
            return "nothing answered at \(host)"
        case .notNodusServer(let host, let evidence):
            switch evidence {
            case .status(let status): return "\(host) answered HTTP \(status) where a Nodus Server answers 200"
            case .malformedBody: return "\(host) answered, and not with what a Nodus Server sends"
            case .otherService(let name): return "\(host) is served by “\(name)”"
            }
        case .versionGap(let gap):
            let behind: String
            switch gap.behind {
            case .app: behind = "the app is behind"
            case .server: behind = "the server is behind"
            case .indeterminate: behind = "neither states a comparable release"
            }
            return "app \(gap.appVersion), server \(gap.serverVersion ?? "unstated"), "
                + "snapshot \(snapshotList(gap.appSnapshotVersions)) / \(snapshotList(gap.serverSnapshotVersions)), "
                + "api \(gap.serverAPI) — \(behind)"
        case .untrustedCertificate(let host, let fingerprint):
            return "\(host) presented a certificate this device does not trust"
                + (fingerprint.map { " (SHA-256 \($0))" } ?? "")
        case .insecureBlocked(let host):
            return "iOS refused plain HTTP to \(host)"
        case .credentialRejected(let host):
            return "\(host) no longer accepts this device's credential"
        case .refused(let error):
            return "HTTP \(error.status)" + (error.code.map { " \($0)" } ?? "")
        case .unclassified(let host, let detail):
            return "\(host): \(detail)"
        }
    }
}

/// Snapshot format numbers as a person reads them out: `1, 2`.
private func snapshotList(_ versions: [Int]) -> String {
    versions.map(String.init).joined(separator: ", ")
}

/// Everything one diagnosis found, and the text of it.
///
/// The text is assembled once, at construction, with every secret this device holds struck out
/// of it — and the secrets themselves are not kept. A report cannot leak a token because it
/// never holds one, and that is a property of the type rather than of its call sites.
public struct ConnectionReport: Sendable, Hashable {
    public let origin: String
    public let appVersion: String
    public let checks: [ConnectionCheck]
    /// The report as text, ready for the clipboard.
    public let plainText: String

    /// - Parameter redacting: values that must never appear, whatever a server echoed back.
    ///   Nothing in this file ever puts one there; passing them anyway is what makes "it does
    ///   not leak the token" a thing a test can prove rather than a thing to be careful about.
    public init(origin: String, appVersion: String, checks: [ConnectionCheck], redacting secrets: [String] = []) {
        self.origin = origin
        self.appVersion = appVersion
        self.checks = checks
        self.plainText = Self.redact(secrets, in: Self.compose(origin: origin, appVersion: appVersion, checks: checks))
    }

    /// The first thing that went wrong, which is the one worth saying out loud.
    public var failure: ConnectionFailure? {
        checks.compactMap(\.failure).first
    }

    public func check(_ step: ConnectionCheck.Step) -> ConnectionCheck? {
        checks.first { $0.step == step }
    }

    /// Wide enough for the longest thing that will ever be put in the column.
    ///
    /// `padding(toLength:)` truncates as readily as it pads, so a width chosen by hand turns
    /// "certificate" into "certific" — in the one artifact whose whole job is to be read by
    /// somebody who was not there.
    private static let column: Int = {
        let labels = ConnectionCheck.Step.allCases.map(\.rawValue.count) + ["server", "app"].map(\.count)
        return (labels.max() ?? 0) + 2
    }()

    private static func padded(_ label: String) -> String {
        label.padding(toLength: column, withPad: " ", startingAt: 0)
    }

    private static func compose(origin: String, appVersion: String, checks: [ConnectionCheck]) -> String {
        var lines = [
            "Nodus connection report",
            padded("server") + origin,
            padded("app") + appVersion,
        ]
        for check in checks {
            let label = padded(check.step.rawValue)
            switch check.outcome {
            case .passed(let detail):
                lines.append(label + "ok" + (detail.map { " · \($0)" } ?? ""))
            case .failed(let failure):
                lines.append(label + "FAILED · \(failure.transcript)")
            case .skipped:
                lines.append(label + "not asked")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A secret shorter than eight characters is ignored: striking every "1" out of a report
    /// would destroy the report to protect something that was never a secret.
    private static func redact(_ secrets: [String], in text: String) -> String {
        secrets.reduce(text) { partial, secret in
            guard secret.count >= 8 else { return partial }
            return partial.replacingOccurrences(of: secret, with: "⟨redacted⟩")
        }
    }
}

/// The checks, run in order, against one address.
///
/// This is the diagnostics screen's whole engine, and it lives here rather than in a view for
/// the same reason the classifier does: it is the part that has to be right, and a view is the
/// hardest possible place to test one.
public enum ConnectionDiagnostics {
    /// - Parameter token: this device's credential for the space, used for the last check and
    ///   for nothing else. It reaches the report only as something to strike out.
    public static func run(
        address: ServerAddress,
        token: String? = nil,
        appVersion: String = NodusVersion.current,
        cacheDirectory: URL
    ) async -> ConnectionReport {
        var outcomes: [ConnectionCheck.Step: ConnectionCheck.Outcome] = [:]
        let host = ConnectionFailure.host(of: address.origin)

        func report() -> ConnectionReport {
            ConnectionReport(
                origin: address.origin,
                appVersion: appVersion,
                checks: ConnectionCheck.Step.allCases.map {
                    ConnectionCheck(step: $0, outcome: outcomes[$0] ?? .skipped)
                },
                redacting: [token].compactMap { $0 }
            )
        }

        // 1 — this device. Nothing is contacted until this answers, because every sentence
        // after it would be a claim about a network that is not there.
        let network = await NetworkReachability.current()
        guard network != .down else {
            outcomes[.network] = .failed(.noNetwork)
            return report()
        }
        outcomes[.network] = .passed(describe(network))

        let inspector = CertificateInspector()
        let session = URLSession.nodusProbe(observing: inspector)
        // The session retains its delegate until it is told not to, and both are meaningful
        // only for this run.
        defer { session.finishTasksAndInvalidate() }
        let client = NodusClient(
            address: address,
            token: token,
            session: session,
            cache: ResponseCache(directory: cacheDirectory)
        )

        func classify(_ error: any Error, _ knock: ConnectionFailure.Knock, health: ServerHealth? = nil) -> ConnectionFailure {
            ConnectionFailure.classify(
                error: error,
                health: health,
                origin: address.origin,
                network: network,
                knock: knock,
                appVersion: appVersion,
                fingerprint: inspector.evidence(for: host)?.fingerprint
            ) ?? .unclassified(host: host, detail: error.localizedDescription)
        }

        // 2 — is anything there? `/healthz` is the liveness probe and asks for nothing, so an
        // answer of any shape at all — even a 404 from somebody else's web server — settles
        // this question in the affirmative and leaves the next one to say what answered.
        var health: ServerHealth?
        do {
            let answer = try await client.health()
            health = answer
            outcomes[.reachable] = .passed(answer.version.map { "healthy · v\($0)" } ?? "healthy")
        } catch let error as TransportError {
            switch error {
            case .malformedResponse:
                outcomes[.reachable] = .passed("answered, with something else")
            default:
                let failure = classify(error, .unauthenticated)
                outcomes[failure.step] = .failed(failure)
                // A refused certificate proves the machine is there: the handshake got far
                // enough for it to present one.
                if failure.step == .certificate, inspector.evidence(for: host) != nil {
                    outcomes[.reachable] = .passed("answered the handshake")
                }
                return report()
            }
        } catch {
            outcomes[.reachable] = .passed("answered, with something else")
        }

        // 3 — the certificate, said out loud on every https address rather than only when it
        // fails. A fingerprint is only useful if you can read it before you need it.
        if let evidence = inspector.evidence(for: host) {
            outcomes[.certificate] = .passed(evidence.subject.map { "\($0) · SHA-256 \(evidence.fingerprint)" }
                ?? "SHA-256 \(evidence.fingerprint)")
        } else if address.isInsecure {
            outcomes[.certificate] = .passed("not encrypted")
        }

        // 4 — is it a Nodus Server? This is the app's own first call against a new address,
        // and the one whose answer every ceiling is read from.
        let capabilities: ServerCapabilities
        do {
            capabilities = try await client.capabilities(timeout: 8)
            outcomes[.identity] = .passed(
                [capabilities.server.name, "api \(capabilities.api)"].joined(separator: " · ")
            )
        } catch {
            let failure = classify(error, .unauthenticated, health: health)
            outcomes[failure.step] = .failed(failure)
            return report()
        }

        // 5 — one release, three parts. When they disagree the server is right.
        let gap = ConnectionFailure.gap(between: capabilities, appVersion: appVersion)
        if gap.blocks {
            outcomes[.version] = .failed(.versionGap(gap))
            return report()
        }
        outcomes[.version] = .passed(
            "app \(gap.appVersion) · server \(gap.serverVersion ?? "unstated") · snapshot "
                + gap.serverSnapshotVersions.map(String.init).joined(separator: ", ")
        )

        // 6 — the credential, which the app already handles well and which belongs in the list
        // so that a report of a working connection says so about every part of it.
        guard token != nil else { return report() }
        do {
            let me = try await client.me()
            outcomes[.credential] = .passed(me.device.map { "accepted · \($0.kind)" } ?? "accepted")
        } catch {
            let failure = classify(error, .credentialed)
            outcomes[failure.step] = .failed(failure)
        }
        return report()
    }

    private static func describe(_ status: NetworkStatus) -> String {
        guard case .up(let interface, let expensive, let constrained) = status else { return "unknown" }
        var parts: [String] = []
        switch interface {
        case .wifi: parts.append("Wi-Fi")
        case .cellular: parts.append("cellular")
        case .wired: parts.append("wired")
        case .other: parts.append("other")
        }
        if expensive { parts.append("metered") }
        if constrained { parts.append("low data mode") }
        return parts.joined(separator: " · ")
    }
}
