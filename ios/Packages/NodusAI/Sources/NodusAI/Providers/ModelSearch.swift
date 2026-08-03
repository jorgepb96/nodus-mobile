import Foundation

/// Matching what somebody types against what a provider calls its models.
///
/// A model id is words held together by punctuation — `gemini-2.5-flash`, `gpt-4o-mini`,
/// `google/gemini-2.0-flash-exp:free` — and nobody reproduces that punctuation from memory.
/// A plain `contains` makes the spelling the user's problem: "gemini flash" matches nothing at
/// all, because no id contains that string, and the list looks empty rather than unfiltered.
///
/// So a separator is not a character here, it is a gap. Both sides are cut into words at every
/// separator any provider uses, and a candidate matches when it contains every word of the
/// query — in any order, so "flash gemini" works as well as "gemini flash", and "gemini-flash",
/// "gemini.flash" and "gemini_flash" are all the same query.
public enum ModelSearch {
    /// Everything that separates words in a model id, across every provider's spelling.
    private static let separators = CharacterSet(charactersIn: "-_./\\:,;()[]{}@+|*&#")
        .union(.whitespacesAndNewlines)

    /// `Gemini-2.5-Flash` → `["gemini", "2", "5", "flash"]`.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
    }

    /// Does this candidate match the query? An empty query matches everything.
    ///
    /// - Parameter candidate: the model id, and whatever else should be searchable with it —
    ///   the picker passes the provider's name too, so "openrouter claude" narrows to one
    ///   provider's copy of a model several of them carry.
    public static func matches(query: String, candidate: String) -> Bool {
        let needles = words(query)
        guard !needles.isEmpty else { return true }
        let haystack = words(candidate)
        // "gpt4o", "geminiflash": a query written as one run-on word. Trying it against the
        // glued candidate is what makes that behave like the spaced form, without letting a
        // word match across a gap it was never adjacent to in the spaced case.
        let glued = haystack.joined()
        return needles.allSatisfy { needle in
            haystack.contains { $0.contains(needle) } || glued.contains(needle)
        }
    }
}
