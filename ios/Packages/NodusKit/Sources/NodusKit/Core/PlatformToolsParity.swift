import Foundation

/// The shared security boundary used by Browser and Radar. Browser accepts ordinary web
/// navigation, while Radar only polls public HTTPS endpoints: neither surface can be turned
/// into a bridge to files, loopback services or private-network administration pages.
public enum NodusWebURLPolicy {
    private static let blockedHostnames: Set<String> = [
        "localhost", "localhost.localdomain", "ip6-localhost", "ip6-loopback",
    ]

    public static func browserDestination(for input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return URL(string: "https://www.google.com") }
        if let explicit = URL(string: trimmed), explicit.scheme != nil {
            return isAllowedBrowserURL(explicit) ? explicit : nil
        }
        if trimmed.contains(".") && !trimmed.contains(" "),
           let inferred = URL(string: "https://\(trimmed)"), isAllowedBrowserURL(inferred) {
            return inferred
        }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [.init(name: "q", value: trimmed)]
        return components?.url
    }

    public static func isAllowedBrowserURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host?.lowercased(), !isPrivateHost(host) else { return false }
        return url.user == nil && url.password == nil
    }

    public static func isAllowedRadarSource(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && isAllowedBrowserURL(url)
    }

    public static func isPrivateHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if blockedHostnames.contains(normalized) || normalized.hasSuffix(".local") || normalized.hasSuffix(".internal") {
            return true
        }
        if normalized == "::1" || normalized == "0:0:0:0:0:0:0:1" || normalized.hasPrefix("fe80:") || normalized.hasPrefix("fc") || normalized.hasPrefix("fd") {
            return true
        }
        let octets = normalized.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        let a = octets[0], b = octets[1]
        return a == 0 || a == 10 || a == 127 || (a == 169 && b == 254)
            || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
            || (a == 100 && (64...127).contains(b)) || a >= 224
    }
}

public enum RadarFollowType: String, Sendable, Codable, CaseIterable {
    case topic, search, author, journal, paper, rss, website
}

public enum RadarCadence: String, Sendable, Codable, CaseIterable {
    case daily, weekly
}

public struct RadarFollowRecord: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public var type: RadarFollowType
    public var title: String
    public var value: String
    public var cadence: RadarCadence
    public var sourceNames: [String]
    public var enabled: Bool
    public var createdAt: Date

    public init(id: String = UUID().uuidString, type: RadarFollowType, title: String, value: String,
                cadence: RadarCadence = .daily, sourceNames: [String] = [], enabled: Bool = true,
                createdAt: Date = Date()) {
        self.id = id; self.type = type; self.title = title; self.value = value
        self.cadence = cadence; self.sourceNames = sourceNames; self.enabled = enabled; self.createdAt = createdAt
    }
}

public struct RadarUpdateRecord: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let followId: String
    public var followTitle: String
    public var title: String
    public var authors: String
    public var summary: String
    public var source: String
    public var url: URL?
    public var detectedAt: Date
    public var isRead: Bool
    public var savedToLibrary: Bool

    public init(id: String, followId: String, followTitle: String, title: String, authors: String = "",
                summary: String = "", source: String, url: URL? = nil, detectedAt: Date = Date(),
                isRead: Bool = false, savedToLibrary: Bool = false) {
        self.id = id; self.followId = followId; self.followTitle = followTitle; self.title = title
        self.authors = authors; self.summary = summary; self.source = source; self.url = url
        self.detectedAt = detectedAt; self.isRead = isRead; self.savedToLibrary = savedToLibrary
    }

    public var searchableText: String {
        [title, authors, followTitle, source, summary].joined(separator: "\n").localizedLowercase
    }
}

public enum RadarProjection {
    /// Source results are immutable observations. A stable identifier deduplicates the same
    /// paper/feed entry across retries and sources without silently replacing the newer copy.
    public static func merge(_ current: [RadarUpdateRecord], incoming: [RadarUpdateRecord]) -> [RadarUpdateRecord] {
        var values = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        for update in incoming {
            guard let existing = values[update.id] else { values[update.id] = update; continue }
            var winner = update.detectedAt >= existing.detectedAt ? update : existing
            winner.isRead = existing.isRead || update.isRead
            winner.savedToLibrary = existing.savedToLibrary || update.savedToLibrary
            values[update.id] = winner
        }
        return values.values.sorted { $0.detectedAt == $1.detectedAt ? $0.id < $1.id : $0.detectedAt > $1.detectedAt }
    }

    public static func filtered(_ updates: [RadarUpdateRecord], query: String, unreadOnly: Bool) -> [RadarUpdateRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        return updates.filter { (!unreadOnly || !$0.isRead) && (needle.isEmpty || $0.searchableText.contains(needle)) }
    }
}

public enum ToolkitExecution: String, Sendable, Codable { case native, desktop }

public enum ToolkitOperation: String, Sendable, Codable, CaseIterable, Identifiable {
    case mergePDF, imagesToPDF, extractPDFText, checksum, protectPDF, translateText, presentPDF, recognizeText
    case officeToPDF, repairDamagedPDF

    public var id: String { rawValue }
    public var execution: ToolkitExecution {
        switch self {
        case .officeToPDF, .repairDamagedPDF: .desktop
        default: .native
        }
    }

    /// This value is the complete remote command vocabulary. Callers may send object IDs and
    /// output preferences, never local paths or implementation method names.
    public var desktopCommand: String? {
        switch self {
        case .officeToPDF: "docx-to-text"
        case .repairDamagedPDF: "ocr-pdf-searchable"
        default: nil
        }
    }
}

public struct ToolkitDesktopPayload: Sendable, Hashable, Codable {
    public let operation: String
    public let libraryObjectIds: [String]
    public let outputFormat: String

    public init?(operation: ToolkitOperation, libraryObjectIds: [String], outputFormat: String) {
        guard operation.execution == .desktop, let command = operation.desktopCommand,
              !libraryObjectIds.isEmpty,
              libraryObjectIds.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("\\") }),
              ["pdf", "zip"].contains(outputFormat) else { return nil }
        self.operation = command; self.libraryObjectIds = libraryObjectIds; self.outputFormat = outputFormat
    }
}
