import Foundation

/// What a citation says on the page.
///
/// The model is asked to copy a `nodus://` token, because a token is the only thing that can be
/// checked against the corpus. A token is not, however, a citation: a reader who meets
/// `(nodus://passage/920737fb-4eb1-4033-a5e6-cbc50d05f2be#42)` in the middle of a sentence has
/// been handed a database key. The desktop never shows one — it hands the writer
/// `[Arco Blanco, M. (2020)](nodus://idea/g-8969)`, a label and a destination together
/// (`electron/ai/deepResearchCore.ts:1809`).
///
/// This is that, done at assembly instead of in the prompt. Asking a model to copy a whole
/// Markdown link unchanged is a request it fails often enough that the desktop keeps six regexes
/// to repair the shapes it invents; asking it for a bare token and writing the link here is the
/// same document with none of that.
public enum CitationRendering {
    /// Every `nodus://` citation in the prose, in the order it appears, without duplicates.
    ///
    /// Reads links as well as bare tokens, so a report written before assembly did the linking
    /// can be relabelled from what is on its own page.
    public static func tokens(in prose: String) -> [String] {
        let range = NSRange(prose.startIndex..<prose.endIndex, in: prose)
        var seen = Set<String>()
        var found: [String] = []
        for match in anyToken.matches(in: prose, range: range) {
            guard let tokenRange = Range(match.range(at: 1), in: prose) else { continue }
            let token = trim(String(prose[tokenRange]))
            if seen.insert(token).inserted { found.append(token) }
        }
        return found
    }

    /// Whether the prose still carries a citation nobody has named.
    ///
    /// What tells a report written before assembly did the linking from one written after it,
    /// which is the difference between a page of author-year citations and a page of ids.
    public static func hasBareToken(in prose: String) -> Bool {
        let range = NSRange(prose.startIndex..<prose.endIndex, in: prose)
        return bareToken.firstMatch(in: prose, range: range) != nil
    }

    /// The kind and id a token names, for a citation met on a page rather than in a catalogue.
    public static func parse(_ token: String) -> (kind: String, id: String)? {
        guard let rest = token.range(of: "nodus://").map({ String(token[$0.upperBound...]) }) else { return nil }
        let parts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        let id = String(parts[1])
        return (String(parts[0]), id.removingPercentEncoding ?? id)
    }

    /// Turn bare tokens into Markdown links carrying the label a reader reads.
    ///
    /// A token already inside a link is left exactly as it is: relabelling it would fight
    /// whatever wrote it. A token with no label keeps its own text rather than vanishing —
    /// a citation nobody could name is still a citation somebody made.
    public static func linking(_ prose: String, labels: [String: String]) -> String {
        let range = NSRange(prose.startIndex..<prose.endIndex, in: prose)
        var output = prose
        for match in bareToken.matches(in: prose, range: range).reversed() {
            guard
                let tokenRange = Range(match.range, in: prose),
                let replaceRange = Range(match.range, in: output)
            else { continue }
            let token = trim(String(prose[tokenRange]))
            guard let label = labels[token], !label.isEmpty else { continue }
            output.replaceSubrange(replaceRange, with: "[\(safe(label))](\(token))")
        }
        return output
    }

    /// Brackets inside a label would close the Markdown link early.
    private static func safe(_ label: String) -> String {
        label
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func trim(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
    }

    /// A citation anywhere: linked or bare.
    private static let anyToken = try! NSRegularExpression(
        pattern: #"(nodus://[a-z_]+/[^\s)\]（）]+)"#,
        options: [.caseInsensitive]
    )

    /// A citation that is not already the target of a Markdown link.
    private static let bareToken = try! NSRegularExpression(
        pattern: #"(?<!\]\()nodus://[a-z_]+/[^\s)\]（）]+"#,
        options: [.caseInsensitive]
    )
}

// MARK: - Sources

/// One work, as a citation names it.
///
/// Held apart from `CitationCatalog.Entry` because a work is what a citation *resolves to*: an
/// idea and a passage both cite the book they came out of, and three tokens pointing at the same
/// volume are one entry in a bibliography.
public struct WorkCitation: Sendable, Codable, Hashable {
    public let id: String
    public let authors: [String]
    public let year: String?
    public let title: String?

    public init(id: String, authors: [String] = [], year: String? = nil, title: String? = nil) {
        self.id = id
        self.authors = authors
        self.year = year
        self.title = title
    }

    /// What goes in the middle of a sentence: `Arco Blanco, M., 2020`.
    ///
    /// A comma rather than the parentheses the desktop uses (`deepResearchCore.ts:1889`). The
    /// citation policy asks the writer to put the token in brackets of its own, so a
    /// parenthesised year lands inside them — `(Arco Blanco, M. (2020))` — and two nested pairs
    /// in a line of prose read as a mistake. With a comma the same sentence closes as
    /// `(Arco Blanco, M., 2020)`, which is what an academic reader expects to see.
    public var inline: String {
        // A shortened title is a real citation for a work whose author the corpus never
        // captured; "Author" in the middle of academic prose reads as a placeholder, which is
        // the same judgement `deepResearchCore.ts:1876` makes.
        let name = Self.shortName(authors.first) ?? Self.clip(title) ?? id
        guard let year else { return name }
        return "\(name), \(year)"
    }

    /// What goes in the reference list: the parentheses belong here.
    public var bibliography: String {
        let names = authors.isEmpty
            ? nil
            : (authors.count > 3 ? "\(authors[0]) et al." : authors.joined(separator: "; "))
        let head = [names, year.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        let body = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.isEmpty { return body ?? id }
        guard let body, !body.isEmpty else { return head }
        return "\(head). \(body)"
    }

    /// Nodus stores a name as `Apellido, Nombre`; a citation wants `Apellido, N.`.
    ///
    /// A port of `authorYearLabel` (`electron/ai/deepResearchCore.ts:1878-1889`), including its
    /// tolerance for the other spelling: a name with no comma is read as given-names-first and
    /// its last word taken as the surname.
    static func shortName(_ raw: String?) -> String? {
        guard let cleaned = raw?.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces), !cleaned.isEmpty
        else { return nil }

        let surname: String
        let given: String
        if let comma = cleaned.firstIndex(of: ",") {
            surname = String(cleaned[cleaned.startIndex..<comma]).trimmingCharacters(in: .whitespaces)
            given = String(cleaned[cleaned.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        } else {
            let words = cleaned.split(separator: " ")
            surname = words.last.map(String.init) ?? cleaned
            given = words.dropLast().joined(separator: " ")
        }
        guard !surname.isEmpty else { return cleaned }
        guard let initial = given.first(where: { $0.isLetter }) else { return surname }
        return "\(surname), \(initial.uppercased())."
    }

    private static func clip(_ text: String?, to limit: Int = 42) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit)) + "…"
    }
}

/// What a finished report knows about the citations it really used.
public struct CitationLabelling: Sendable {
    /// Token → the label that replaces it in the prose.
    public var inline: [String: String]
    /// The bibliography, in the order the works were first cited.
    public var references: [CitationCatalog.Entry]

    public init(inline: [String: String], references: [CitationCatalog.Entry]) {
        self.inline = inline
        self.references = references
    }

    /// What a run with nothing but its own catalogue can say.
    ///
    /// Used by the tests and by any wiring that cannot reach the corpus: each token keeps the
    /// name the catalogue gave it; works and specialised records form the references.
    public static func plain(_ cited: [CitationCatalog.Entry]) -> CitationLabelling {
        CitationLabelling(
            inline: Dictionary(cited.map { ($0.token, $0.shortLabel) }, uniquingKeysWith: { first, _ in first }),
            references: cited.filter { !["idea", "passage", "gap", "theme"].contains($0.kind) }
        )
    }
}

public extension CitationCatalog.Entry {
    /// The work this citation rests on, as far as the token itself can say.
    ///
    /// A passage id is `<nodus_id>#<chunk>` (`electron/db/passagesRepo.ts:39`), so a passage
    /// names its work even when the row it came from is long gone — which is what lets a report
    /// saved months ago be relabelled from what is written on its own page.
    var impliedWorkId: String? {
        if let workId { return workId }
        switch kind {
        case "work": return id
        case "passage":
            // Only when the id really is one. `split` on an absent separator hands back the
            // whole string, so a vault that keys its passages some other way had every passage
            // citation looked up as a work with its own id — a 404, and a citation that stayed
            // a raw id on the page. The caller asks the corpus itself when this is nil.
            guard let hash = id.firstIndex(of: "#"), hash > id.startIndex else { return nil }
            return String(id[id.startIndex..<hash])
        default: return nil
        }
    }

    /// The entry's own name, cut to something that can sit inside a sentence.
    ///
    /// Empty when the entry has no name of its own — a citation reconstructed from a token on a
    /// page, whose source the corpus could not be made to say. `linking` leaves those alone, and
    /// a bare token the reader can still tap beats a primary key dressed up as a citation.
    var shortLabel: String {
        let cleaned = label
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count <= 60 ? cleaned : String(cleaned.prefix(60)) + "…"
    }
}
