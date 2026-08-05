import Foundation
import Testing
@testable import NodusKit

/// A Nodus Server lives on somebody's own computer, and the computer sleeps.
///
/// Every one of these used to reach the reader as the same sentence about a connection that
/// could not be made: the phone off the Wi-Fi, the desktop quit, a router page answering on the
/// port, a server two releases behind, a certificate the desktop signed itself, a revoked
/// token. Six different things to go and do, one message.
///
/// The classifier is pure precisely so this can be proved with fake answers instead of by
/// arranging for a real server to misbehave in exactly the right way — which for half of these
/// means walking out of Wi-Fi range with a debugger attached.
@Suite("Connection failures")
struct ConnectionFailureTests {
    private let origin = "https://laptop.tail1234.ts.net"
    private let host = "laptop.tail1234.ts.net"
    private let online = NetworkStatus.up(.wifi, isExpensive: false, isConstrained: false)

    private func classify(
        _ error: (any Error)?,
        capabilities: ServerCapabilities? = nil,
        health: ServerHealth? = nil,
        network: NetworkStatus? = nil,
        knock: ConnectionFailure.Knock = .unauthenticated,
        appVersion: String = "3.2.2",
        fingerprint: String? = nil
    ) -> ConnectionFailure? {
        ConnectionFailure.classify(
            error: error,
            capabilities: capabilities,
            health: health,
            origin: origin,
            network: network ?? online,
            knock: knock,
            appVersion: appVersion,
            fingerprint: fingerprint
        )
    }

    // MARK: 1 — no network on this device

    @Test("with no network, nothing is claimed about the server")
    func noNetworkComesFirst() {
        // Whatever URLSession reported, a device with no network has not learned anything
        // about the far end and must not pretend it has.
        #expect(classify(TransportError.cannotConnect, network: .down) == .noNetwork)
        #expect(classify(TransportError.hostNotFound, network: .down) == .noNetwork)
        #expect(classify(TransportError.offline) == .noNetwork)
    }

    @Test("a monitor that did not settle is not treated as an absent network")
    func unknownIsNotDown() {
        // `.unknown` means the doorbell was slow, not that there is no door. Answering "you
        // have no network" on that would be the diagnosis being wrong at step one.
        #expect(classify(TransportError.cannotConnect, network: .unknown) == .noAnswer(host: host))
    }

    // MARK: 2 — the frequent one: nobody is home

    @Test("a stopped or sleeping computer is named as one, and nothing is said about credentials")
    func silenceIsNotACredentialProblem() {
        #expect(classify(TransportError.cannotConnect) == .noAnswer(host: host))
        // A timeout is the same computer, asleep rather than awake with nothing listening.
        // The user does the same thing about either, so they are one case.
        #expect(classify(TransportError.timedOut) == .noAnswer(host: host))

        let transcript = ConnectionFailure.noAnswer(host: host).transcript.lowercased()
        #expect(transcript.contains(host))
        for word in ["credential", "token", "password", "sign in"] {
            #expect(!transcript.contains(word), "a sleeping computer is not a credential problem")
        }
    }

    @Test("a name that does not resolve is the network this device is not on, not a dead server")
    func unknownHostIsItsOwnCase() {
        #expect(classify(TransportError.hostNotFound) == .unknownHost(host: host))
        #expect(ConnectionFailure.unknownHost(host: host) != ConnectionFailure.noAnswer(host: host))
    }

    @Test("the port is part of the name, because a right host on a wrong port reaches nothing")
    func hostCarriesItsPort() {
        let failure = ConnectionFailure.classify(
            error: TransportError.cannotConnect,
            origin: "http://192.168.1.20:7443",
            network: online,
            knock: .unauthenticated,
            appVersion: "3.2.2"
        )
        #expect(failure == .noAnswer(host: "192.168.1.20:7443"))
    }

    // MARK: 3 — something else lives at that address

    @Test("a status a Nodus Server never gives to a public route is somebody else answering")
    func anotherServiceByStatus() {
        let notFound = APIError(status: 404, message: "Cannot GET /api/v1/capabilities")
        #expect(classify(notFound) == .notNodusServer(host: host, evidence: .status(404)))
        #expect(classify(APIError(status: 502)) == .notNodusServer(host: host, evidence: .status(502)))
    }

    @Test("a public route that asks who is calling is a proxy, not a credential to replace")
    func authOnAPublicRouteIsNotOurs() {
        // `/healthz` and `/capabilities` are unauthenticated on every Nodus Server. Anything
        // that challenges them sits in front of — or instead of — the server, and minting this
        // device a new token would not touch it.
        #expect(classify(APIError(status: 401), knock: .unauthenticated)
                == .notNodusServer(host: host, evidence: .status(401)))
        #expect(classify(APIError(status: 403), knock: .unauthenticated)
                == .notNodusServer(host: host, evidence: .status(403)))
    }

    @Test("a 200 that is not the documented shape is somebody else too")
    func anotherServiceByBody() {
        let malformed = TransportError.malformedResponse(expected: "ServerCapabilities")
        #expect(classify(malformed) == .notNodusServer(host: host, evidence: .malformedBody))
    }

    @Test("when /healthz names itself, the message can name it back")
    func anotherServiceNamesItself() {
        let health = ServerHealth(ok: true, service: "grafana", version: "10.2.0")
        #expect(classify(TransportError.malformedResponse(expected: "ServerCapabilities"), health: health)
                == .notNodusServer(host: host, evidence: .otherService("grafana")))
        // A named impostor beats a bare status, because it is the better evidence.
        #expect(classify(APIError(status: 404), health: health)
                == .notNodusServer(host: host, evidence: .otherService("grafana")))
    }

    @Test("a server too old to name itself is not accused of being an impostor")
    func silenceAboutTheNameIsNotEvidence() {
        // Servers before the shared version scheme answer /healthz with `ok` and nothing else.
        let health = ServerHealth(ok: true, service: nil, version: nil)
        #expect(health.namesAnotherService == nil)
        #expect(classify(TransportError.malformedResponse(expected: "x"), health: health)
                == .notNodusServer(host: host, evidence: .malformedBody))
        #expect(ServerHealth(ok: true, service: "nodus-server").namesAnotherService == nil)
    }

    // MARK: 4 — a Nodus Server this build cannot read

    @Test("a server publishing only a newer snapshot format names the app as the one behind")
    func appIsBehind() throws {
        let future = try Fixtures.capabilities(version: "4.0.0", snapshotVersions: [3])
        let failure = classify(nil, capabilities: future)
        let gap = try #require(failure?.versionGapValue)
        #expect(gap.behind == .app)
        #expect(gap.blocks)
        // Both numbers, because a screen that names one of the two is a screen that cannot be
        // read out over the phone to whoever runs the server.
        #expect(gap.appVersion == "3.2.2")
        #expect(gap.serverVersion == "4.0.0")
        #expect(!gap.sharesASnapshotFormat)
    }

    @Test("a server on an API generation this build does not address is a gap even with a shared format")
    func unknownAPIGeneration() throws {
        let capabilities = try Fixtures.capabilities(api: "v2", version: "9.0.0", snapshotVersions: [1, 2])
        let gap = try #require(classify(nil, capabilities: capabilities)?.versionGapValue)
        #expect(gap.sharesASnapshotFormat)
        #expect(!gap.speaksAKnownAPI)
        #expect(gap.blocks, "every path this client builds is /api/v1/…")
        #expect(gap.behind == .app)
    }

    @Test("an older server is named as the older one")
    func serverIsBehind() throws {
        let old = try Fixtures.capabilities(api: "v0", version: "3.0.0", snapshotVersions: [1])
        let gap = try #require(classify(nil, capabilities: old)?.versionGapValue)
        #expect(gap.behind == .server)
        #expect(gap.serverVersion == "3.0.0")
        #expect(gap.appVersion == "3.2.2")
    }

    @Test("a server that states no version at all is still placed by its snapshot formats")
    func snapshotFormatsDecideWithoutAReleaseNumber() throws {
        let unstated = try Fixtures.capabilities(version: nil, snapshotVersions: [3, 4])
        let gap = ConnectionFailure.gap(between: unstated, appVersion: "3.2.2")
        #expect(gap.serverVersion == nil)
        #expect(gap.behind == .app, "publishing only formats this build cannot read places it ahead")
    }

    @Test("two releases that merely differ are not a failed connection")
    func aDifferentReleaseIsNotABrokenOne() throws {
        // The settings screen has said "these are different releases" for a while and should
        // keep saying it. It is a caution, not a reason to refuse to open the space.
        let older = try Fixtures.capabilities(version: "3.1.0", snapshotVersions: [1, 2])
        #expect(classify(nil, capabilities: older) == nil)
        let gap = ConnectionFailure.gap(between: older, appVersion: "3.2.2")
        #expect(gap.behind == .server)
        #expect(!gap.blocks)
    }

    @Test("a server this build understands produces no failure at all")
    func agreementIsSilent() throws {
        let matching = try Fixtures.capabilities(version: "3.2.2", snapshotVersions: [1, 2])
        #expect(classify(nil, capabilities: matching) == nil)
    }

    @Test("release numbers are ordered, and refused when they are not numbers")
    func versionOrdering() {
        #expect(NodusVersion.compare("3.2.2", "3.2.10") == .orderedAscending)
        #expect(NodusVersion.compare("3.2", "3.2.0") == .orderedSame)
        #expect(NodusVersion.compare("4.0.0", "3.9.9") == .orderedDescending)
        // Half-parsing "3.2.2-rc1" to 3.2 would claim it is older than the release it precedes.
        #expect(NodusVersion.compare("3.2.2-rc1", "3.2.2") == nil)
        #expect(NodusVersion.compare("?", "3.2.2") == nil)
    }

    // MARK: 5 — the certificate

    @Test("a refused certificate says so, and carries the fingerprint that lets it be compared")
    func certificateCarriesItsFingerprint() {
        let failure = classify(TransportError.certificateRejected, fingerprint: "AB CD EF")
        #expect(failure == .untrustedCertificate(host: host, fingerprint: "AB CD EF"))
        #expect(ConnectionFailure.untrustedCertificate(host: host, fingerprint: "AB CD EF")
            .transcript.contains("AB CD EF"))
    }

    @Test("a certificate is judged before the network, because the network did not cause it")
    func certificateOutranksTheNetwork() {
        // iOS refuses a certificate by looking at the certificate, not at the route to it.
        // Sending somebody to check their Wi-Fi over one sends them the wrong way.
        #expect(classify(TransportError.certificateRejected, network: .down)
                == .untrustedCertificate(host: host, fingerprint: nil))
        #expect(classify(TransportError.insecureBlocked, network: .down) == .insecureBlocked(host: host))
        #expect(classify(TransportError.badServerURL("nodus.example.org/space/12"), network: .down)
                == .badAddress("nodus.example.org/space/12"))
    }

    // MARK: 6 — the credential, which already worked

    @Test("a 401 on a route that carried the token is the credential, and only there")
    func credentialRejected() {
        #expect(classify(APIError(status: 401, code: "invalid_token"), knock: .credentialed)
                == .credentialRejected(host: host))
    }

    @Test("a refusal the server explained is passed through rather than renamed")
    func refusalsKeepTheirOwnWords() throws {
        let forbidden = APIError(status: 403, code: "forbidden", details: ["required": .string("write")])
        let failure = try #require(classify(forbidden, knock: .credentialed))
        guard case .refused(let carried) = failure else {
            Issue.record("a 403 is a server refusal, not a connection failure")
            return
        }
        #expect(carried.requiredNeed == .write)
        #expect(classify(APIError(status: 429), knock: .credentialed)?.step == .identity)
    }

    // MARK: the ones that are not failures

    @Test("a cancelled read is not a failure and must never paint a notice")
    func cancellationIsSilent() {
        // Pull-to-refresh let go of early, or a screen that went away mid-request. Nothing
        // failed and nothing changed.
        #expect(classify(TransportError.cancelled) == nil)
        #expect(classify(CancellationError()) == nil)
        #expect(classify(URLError(.cancelled)) == nil)
    }

    @Test("a failure with no name keeps the system's words out of the first line")
    func unclassifiedKeepsItsDetailForTheReport() {
        let failure = classify(TransportError.underlying("The operation couldn’t be completed."))
        #expect(failure == .unclassified(host: host, detail: "The operation couldn’t be completed."))
    }

    @Test("every failure lands on the check that answers it")
    func failuresKnowTheirStep() {
        #expect(ConnectionFailure.noNetwork.step == .network)
        #expect(ConnectionFailure.noAnswer(host: host).step == .reachable)
        #expect(ConnectionFailure.unknownHost(host: host).step == .reachable)
        #expect(ConnectionFailure.untrustedCertificate(host: host, fingerprint: nil).step == .certificate)
        #expect(ConnectionFailure.notNodusServer(host: host, evidence: .malformedBody).step == .identity)
        #expect(ConnectionFailure.credentialRejected(host: host).step == .credential)
    }
}

/// The copyable report.
///
/// It goes to the clipboard and from there to whoever runs the server, which is exactly the
/// path along which a secret would travel furthest.
@Suite("Connection report")
struct ConnectionReportTests {
    @Test("the token never reaches the clipboard, even if a server echoes it back")
    func secretsAreStruckOut() {
        let token = "ndt_9f2c41ab7e5d4c0198aa3b77e1d05f6c"
        // A server, or something pretending to be one, that puts the Authorization header it
        // received into its own error message. Nothing in the app does this; the report is
        // written so that it would not matter if something did.
        let echoed = APIError(status: 400, message: "unexpected header Bearer \(token)")
        let report = ConnectionReport(
            origin: "https://laptop.tail1234.ts.net",
            appVersion: "3.2.2",
            checks: [
                .init(step: .network, outcome: .passed("Wi-Fi")),
                .init(step: .reachable, outcome: .passed("healthy")),
                .init(step: .identity, outcome: .failed(.refused(echoed))),
                .init(step: .credential, outcome: .failed(.unclassified(host: "h", detail: "sent \(token)"))),
            ],
            redacting: [token]
        )
        #expect(!report.plainText.contains(token))
        #expect(report.plainText.contains("⟨redacted⟩"))
        // The report is still a report: striking the secret out must not take the diagnosis
        // with it.
        #expect(report.plainText.contains("laptop.tail1234.ts.net"))
        #expect(report.plainText.contains("3.2.2"))
    }

    @Test("a report holds no key of any kind, because none of them is ever handed to it")
    func noProviderKeysAnywhere() {
        // Provider keys live in this device's keychain and are read into a provider client and
        // nowhere else. The diagnostics path never asks for one, so the strongest statement
        // available is structural: a report is built from checks, and a check carries a step,
        // an outcome and data the classifier produced.
        let report = ConnectionReport(
            origin: "https://laptop.tail1234.ts.net",
            appVersion: "3.2.2",
            checks: ConnectionCheck.Step.allCases.map { .init(step: $0, outcome: .passed(nil)) }
        )
        for marker in ["sk-", "Bearer", "Authorization", "apiKey"] {
            #expect(!report.plainText.contains(marker))
        }
    }

    @Test("a secret too short to be one is not struck out, or the report would be shredded")
    func shortValuesAreLeftAlone() {
        let report = ConnectionReport(
            origin: "https://a.example",
            appVersion: "3.2.2",
            checks: [.init(step: .network, outcome: .passed("Wi-Fi"))],
            redacting: ["a", "3.2"]
        )
        #expect(report.plainText.contains("3.2.2"))
    }

    @Test("a version gap reads out both releases and which of them is the older")
    func versionGapIsReadableAloud() throws {
        let gap = ConnectionFailure.gap(
            between: try Fixtures.capabilities(version: "4.0.0", snapshotVersions: [3]),
            appVersion: "3.2.2"
        )
        let line = ConnectionFailure.versionGap(gap).transcript
        #expect(line.contains("3.2.2"))
        #expect(line.contains("4.0.0"))
        #expect(line.contains("behind"))
    }

    @Test("every check is named in full, not padded down to a stump")
    func labelsSurviveTheColumn() {
        let report = ConnectionReport(
            origin: "https://a.example",
            appVersion: "3.2.2",
            checks: ConnectionCheck.Step.allCases.map { .init(step: $0, outcome: .passed(nil)) }
        )
        for step in ConnectionCheck.Step.allCases {
            #expect(report.plainText.contains(step.rawValue), "“\(step.rawValue)” was cut short")
        }
    }

    @Test("the first failure is the one the report leads with")
    func theFirstFailureIsTheHeadline() {
        let report = ConnectionReport(
            origin: "https://laptop.tail1234.ts.net",
            appVersion: "3.2.2",
            checks: [
                .init(step: .network, outcome: .passed("Wi-Fi")),
                .init(step: .reachable, outcome: .failed(.noAnswer(host: "laptop.tail1234.ts.net"))),
                .init(step: .identity, outcome: .skipped),
            ]
        )
        #expect(report.failure == .noAnswer(host: "laptop.tail1234.ts.net"))
        #expect(report.plainText.contains("not asked"), "a check that never ran says so")
    }
}

/// The one check that contacts nothing, and the one that could still hold up a screen.
@Suite("Reachability")
struct NetworkReachabilityTests {
    @Test("the monitor answers inside its bound rather than waiting on a path that never comes")
    func neverHangs() async {
        // This is asked *after* a request has already spent its timeout, and the budget for
        // saying "the computer may be asleep" is five seconds in total. A monitor that waits
        // for a path update that never arrives — a simulator with no interface, a device
        // mid-handover — would spend the rest of it on its own.
        let started = ContinuousClock.now
        _ = await NetworkReachability.current(within: 0.3)
        #expect(started.duration(to: .now) < .seconds(2))
    }

    @Test("a bound of zero still answers")
    func zeroBoundAnswers() async {
        // Not a case any caller passes, and the arithmetic that clamps it is the arithmetic
        // that would produce a negative sleep and resume nothing at all.
        let status = await NetworkReachability.current(within: 0)
        #expect(status == .down || status == .unknown || status.interface != nil)
    }
}

private extension ConnectionFailure {
    var versionGapValue: VersionGap? {
        guard case .versionGap(let gap) = self else { return nil }
        return gap
    }
}

/// Server answers, made up rather than recorded, so every branch can be reached.
enum Fixtures {
    static func capabilities(
        api: String = "v1",
        version: String? = "3.2.2",
        snapshotVersions: [Int] = [1, 2],
        serverName: String = "Nodus Server"
    ) throws -> ServerCapabilities {
        let stated = version.map { "\"\($0)\"" } ?? "null"
        let json = """
        {
          "api": "\(api)",
          "version": \(stated),
          "server": {"name": "\(serverName)", "publicUrl": null, "language": "en", "version": \(stated)},
          "snapshotVersions": \(snapshotVersions),
          "assets": true,
          "mutations": true,
          "vectors": true,
          "resources": {"api": "https://example.org/api/v1", "mcp": "https://example.org/mcp"},
          "maxAssetBytes": 8388608,
          "maxSpaceAssetBytes": 268435456,
          "maxSnapshotBytes": 134217728,
          "maxSnapshotJsonBytes": 268435456,
          "maxMutationBatch": 200
        }
        """
        return try JSONDecoder.nodus.decode(ServerCapabilities.self, from: Data(json.utf8))
    }
}
