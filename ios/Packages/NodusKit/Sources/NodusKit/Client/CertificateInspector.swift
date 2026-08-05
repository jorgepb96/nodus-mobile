import CryptoKit
import Foundation

/// One certificate, as a person could compare it against the one their computer is showing
/// them.
public struct CertificateEvidence: Sendable, Hashable {
    /// SHA-256 of the leaf certificate's DER, in grouped uppercase hex — the form every tool
    /// that prints a fingerprint prints it in, so the two can be read side by side.
    public let fingerprint: String
    /// What the certificate says it is for. Nil when it carries no common name at all.
    public let subject: String?

    public init(fingerprint: String, subject: String?) {
        self.fingerprint = fingerprint
        self.subject = subject
    }
}

/// Watches a TLS handshake without ever changing its outcome.
///
/// The desktop's basic local-network mode serves HTTPS with a certificate from an authority it
/// generated itself, so "this device does not trust that certificate" is the *expected* first
/// answer there, and the way out is to install that authority — for which the user has to be
/// able to compare its fingerprint with the one Nodus desktop is showing them. iOS offers no
/// way to read a certificate back out of a `URLError`, so it is taken here, at the one moment
/// it exists on the wire.
///
/// Every path returns `.performDefaultHandling`. This observes and records; a certificate iOS
/// refuses stays refused, and nothing in this file is a trust decision.
///
/// `@unchecked Sendable` over a lock, because `URLSession` calls its delegate on a queue of its
/// own and a delegate callback cannot await its way into an actor.
public final class CertificateInspector: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String: CertificateEvidence] = [:]

    public override init() { super.init() }

    /// What was presented by a host, if anything was.
    public func evidence(for host: String) -> CertificateEvidence? {
        lock.lock()
        defer { lock.unlock() }
        return seen[host.lowercased()]
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if let evidence = Self.leaf(of: trust) {
            lock.lock()
            seen[challenge.protectionSpace.host.lowercased()] = evidence
            lock.unlock()
        }
        completionHandler(.performDefaultHandling, nil)
    }

    private static func leaf(of trust: SecTrust) -> CertificateEvidence? {
        guard
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = chain.first
        else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: der)
        return CertificateEvidence(
            fingerprint: fingerprint(of: digest),
            subject: SecCertificateCopySubjectSummary(leaf) as String?
        )
    }

    static func fingerprint(of digest: SHA256Digest) -> String {
        digest.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

public extension URLSession {
    /// A probe session that also keeps the certificate it was shown.
    ///
    /// Built per diagnosis rather than shared: a `URLSession` retains its delegate until it is
    /// invalidated, and the inspector is meaningful only for the one run that created it.
    /// Callers must call `finishTasksAndInvalidate()` when the run is over, or the session and
    /// its delegate outlive the screen that asked for them.
    static func nodusProbe(observing inspector: CertificateInspector) -> URLSession {
        URLSession(configuration: .nodusProbe, delegate: inspector, delegateQueue: nil)
    }
}
