import Foundation

/// Enforces the citation contract on prose a model just wrote.
///
/// The rule, ported from `electron/ai/deepResearchClient.ts:88-92`: every citation must be a
/// token from the catalogue, copied exactly, and anything else is removed at assembly. The
/// desktop states it as a policy in the prompt; a policy in a prompt is a request, so it is
/// also enforced here, where it is a guarantee.
///
/// Removing rather than flagging is deliberate. A sentence whose only support is an invented
/// source is a sentence with no support, and leaving the citation in place — even marked —
/// puts a reference in a document that does not exist.
public enum CitationValidator {
    public struct Result: Sendable {
        /// The prose with unknown citations removed.
        public let prose: String
        /// Tokens that were in the catalogue.
        public let accepted: [String]
        /// Tokens the model invented.
        public let rejected: [String]
    }

    /// Matches `nodus://kind/id`, with or without surrounding parentheses.
    private static let pattern = try! NSRegularExpression(
        pattern: #"\(?\s*(nodus://[a-z_]+/[^\s)（）]+)\s*\)?"#,
        options: [.caseInsensitive]
    )

    /// A whole Markdown link whose destination is a citation: `[Autor (2005)](nodus://work/x)`.
    ///
    /// The writer is asked for a bare token, but a model that has seen a bibliography in its
    /// life sometimes writes the link instead. Matching it first is what makes an *invented*
    /// one disappear completely: taking out only the URL would leave `[Autor (2005)]()` on the
    /// page — a source that does not exist, still named, and now unopenable.
    private static let linked = try! NSRegularExpression(
        pattern: #"\[([^\]]*)\]\(\s*(nodus://[a-z_]+/[^\s)（）]+)\s*\)"#,
        options: [.caseInsensitive]
    )

    public static func validate(prose: String, against catalog: CitationCatalog) -> Result {
        let unlinked = stripInventedLinks(from: prose, catalog: catalog)
        let prose = unlinked.prose
        let range = NSRange(prose.startIndex..<prose.endIndex, in: prose)
        let matches = pattern.matches(in: prose, range: range)

        var accepted: [String] = []
        var rejected: [String] = []
        var output = prose
        // Back to front, so each replacement leaves the earlier offsets valid.
        for match in matches.reversed() {
            guard
                let tokenRange = Range(match.range(at: 1), in: prose),
                let wholeRange = Range(match.range, in: output)
            else { continue }
            let token = String(prose[tokenRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))

            if catalog.contains(token) {
                accepted.append(token)
            } else {
                rejected.append(token)
                output.replaceSubrange(wholeRange, with: "")
            }
        }

        return Result(
            prose: tidy(output),
            accepted: Array(accepted.reversed()),
            rejected: unlinked.rejected + Array(rejected.reversed())
        )
    }

    /// Take out every Markdown link that points at a citation.
    ///
    /// A link the catalogue knows is unwrapped to its bare token, which is the shape everything
    /// downstream is written against and which assembly relabels from the corpus rather than
    /// from whatever name the model chose. A link the catalogue does not know goes entirely,
    /// label and all.
    private static func stripInventedLinks(
        from prose: String,
        catalog: CitationCatalog
    ) -> (prose: String, rejected: [String]) {
        let range = NSRange(prose.startIndex..<prose.endIndex, in: prose)
        var output = prose
        var rejected: [String] = []
        for match in linked.matches(in: prose, range: range).reversed() {
            guard
                let tokenRange = Range(match.range(at: 2), in: prose),
                let wholeRange = Range(match.range, in: output)
            else { continue }
            let token = String(prose[tokenRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            if catalog.contains(token) {
                output.replaceSubrange(wholeRange, with: token)
            } else {
                rejected.append(token)
                output.replaceSubrange(wholeRange, with: "")
            }
        }
        return (output, rejected.reversed())
    }

    /// Removing a citation leaves doubled spaces and stranded punctuation behind.
    private static func tidy(_ text: String) -> String {
        text
            .replacingOccurrences(of: #" +"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" +([.,;:])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
