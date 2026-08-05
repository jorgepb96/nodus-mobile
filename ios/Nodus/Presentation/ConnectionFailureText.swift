import NodusKit
import NodusUI
import SwiftUI

/// What each connection failure is allowed to say, in one place.
///
/// The same failure is read on the space picker, in the connect sheet, on Home and in the
/// diagnostics list. Four wordings of one fact is how every one of these came to be "could not
/// connect" in the first place, so there is one wording and four readers of it.
///
/// `String(localized:)` rather than `LocalizedStringKey` throughout: every sentence here
/// interpolates something — a host, a release number, a fingerprint — and an interpolated key
/// matches nothing in the catalogue. The keys are the literals below with `%@` where the values
/// go, which is what the compiler extracts and what `Localizable.xcstrings` carries.
extension ConnectionFailure {
    /// The short line: what happened.
    var title: String {
        switch self {
        case .noNetwork:
            return String(localized: "No network")
        case .badAddress:
            return String(localized: "That address will not work")
        case .unknownHost(let host):
            return String(localized: "No machine called “\(host)”")
        case .noAnswer(let host):
            return String(localized: "Nobody answers at \(host)")
        case .notNodusServer(let host, _):
            return String(localized: "Something else is at \(host)")
        case .versionGap:
            return String(localized: "This app and that server are different releases")
        case .untrustedCertificate:
            return String(localized: "This device does not trust that certificate")
        case .insecureBlocked:
            return String(localized: "iOS blocked a plain HTTP address")
        case .credentialRejected:
            return String(localized: "Sign in again")
        case .refused:
            return String(localized: "The server said no")
        case .unclassified(let host, _):
            return String(localized: "Could not reach \(host)")
        }
    }

    /// The sentence: what it means and, when it is known, what to do about it.
    var sentence: String {
        switch self {
        case .noNetwork:
            return String(localized: "This device is not on any network right now, so nothing was contacted.")
        case .badAddress:
            return String(localized: "Type just the server's address — the domain, and the port if it has one. No path and no page.")
        case .unknownHost:
            return String(localized: "If the server is on a private network — Tailscale, a VPN, your own Wi-Fi — this device has to be on it too.")
        case .noAnswer:
            return String(localized: "That usually means the computer Nodus lives on is off, asleep, or has the application closed.")
        case .notNodusServer(_, let evidence):
            if case .otherService(let name) = evidence {
                return String(localized: "That address is served by “\(name)”, not by a Nodus Server.")
            }
            return String(localized: "Something answered there, and not the way a Nodus Server answers. Check the address, and the port if the server uses one.")
        case .versionGap(let gap):
            let app = gap.appVersion
            let server = gap.serverVersion ?? String(localized: "an unstated release")
            // The README settles this and the sentence says it out loud: the desktop, the
            // server and this app ship as one release, and where they disagree the server is
            // right. Which of the two to move follows from that, so it is named rather than
            // left as an exercise.
            switch gap.behind {
            case .app:
                return String(localized: "This app is on \(app) and that server on \(server). Where the two disagree the server decides, so this app is the side to update.")
            case .server:
                return String(localized: "This app is on \(app) and that server on \(server). Where the two disagree the server decides, so update Nodus on the computer that serves it.")
            case .indeterminate:
                return String(localized: "This app is on \(app) and that server on \(server). Neither states a release the other can compare against.")
            }
        case .untrustedCertificate:
            return String(localized: "Nodus desktop's basic local-network mode serves HTTPS with a certificate from an authority it generated itself. iOS refuses it until that authority is installed and trusted on this device.")
        case .insecureBlocked:
            return String(localized: "iOS refuses plain HTTP to anything but this device. Use an https:// address.")
        case .credentialRejected:
            return String(localized: "The server no longer accepts this device's credential for this space.")
        case .refused(let error):
            // The server's own sentence, which is the only one that can carry the server's own
            // numbers. Its code is technical and goes in the detail line, not here.
            if let message = error.message, !message.isEmpty { return message }
            return String(localized: "The server refused the request.")
        case .unclassified:
            return String(localized: "This failure has no name yet. The diagnostics screen carries what the system said about it.")
        }
    }

    /// The technical half: a fingerprint, a status, a list of formats.
    ///
    /// It goes under the sentence and never in place of it. Hiding it would make the
    /// diagnostics screen useless to the one person who can fix a certificate; leading with it
    /// is how "Error -1004" happens.
    var detail: String? {
        switch self {
        case .badAddress(let value):
            return value
        case .notNodusServer(_, let evidence):
            if case .status(let status) = evidence { return "HTTP \(status)" }
            return nil
        case .versionGap(let gap):
            let app = gap.appSnapshotVersions.map(String.init).joined(separator: ", ")
            let server = gap.serverSnapshotVersions.map(String.init).joined(separator: ", ")
            return String(localized: "Snapshot formats — this app \(app), that server \(server)")
        case .untrustedCertificate(_, let fingerprint):
            return fingerprint.map { "SHA-256 \($0)" }
        case .refused(let error):
            return error.code.map { "HTTP \(error.status) · \($0)" } ?? "HTTP \(error.status)"
        case .unclassified(_, let detail):
            return detail
        case .noNetwork, .unknownHost, .noAnswer, .insecureBlocked, .credentialRejected:
            return nil
        }
    }

    var systemImage: String {
        switch self {
        case .noNetwork: return "wifi.slash"
        case .badAddress: return "questionmark.circle"
        case .unknownHost: return "network.slash"
        // A sleeping computer, drawn as one. This is the frequent case and the one that is not
        // a fault at all — somebody simply shut their laptop.
        case .noAnswer: return "moon.zzz"
        case .notNodusServer: return "questionmark.app"
        case .versionGap: return "arrow.triangle.2.circlepath"
        case .untrustedCertificate: return "lock.trianglebadge.exclamationmark"
        case .insecureBlocked: return "lock.open"
        case .credentialRejected: return "key.slash"
        case .refused: return "xmark.octagon"
        case .unclassified: return "exclamationmark.triangle"
        }
    }

    /// Caution for the ones that are somebody closing a laptop, blocked for the ones where
    /// something is actually wrong. A shut lid is not an error and should not be painted as one.
    var tone: NodusNotice.Tone {
        switch self {
        case .noAnswer, .untrustedCertificate, .credentialRejected, .noNetwork: return .caution
        default: return .blocked
        }
    }
}

extension ConnectionCheck.Step {
    /// What the check asked, phrased as the thing that is true when it passes.
    var label: String {
        switch self {
        case .network: return String(localized: "This device has a network")
        case .reachable: return String(localized: "Something answers at that address")
        case .certificate: return String(localized: "The certificate")
        case .identity: return String(localized: "It is a Nodus Server")
        case .version: return String(localized: "The two releases agree")
        case .credential: return String(localized: "This device's credential")
        }
    }
}

extension ConnectionCheck {
    /// Spoken by VoiceOver in place of a coloured glyph, which says nothing out loud.
    var spokenOutcome: String {
        switch outcome {
        case .passed: return String(localized: "passed")
        case .failed: return String(localized: "failed")
        case .skipped: return String(localized: "not asked")
        }
    }
}
