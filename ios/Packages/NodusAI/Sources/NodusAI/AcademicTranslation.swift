import Foundation

/// Academic copies keep every citation target, number and document structure.
/// Validation precedes persistence; an incomplete or altered response is never a result.
public enum AcademicTranslation {
    public enum Failure: Error, LocalizedError, Equatable {
        case empty, protectedContent, numbers, tables, headings, oversizedBlock
        public var errorDescription: String? {
            switch self {
            case .empty: "The translation is empty. The saved copy was preserved."
            case .protectedContent: "The translation changed a citation, link, formula or code. The saved copy was preserved."
            case .numbers: "The translation changed numbers or dates. The saved copy was preserved."
            case .tables: "The translation changed a table. The saved copy was preserved."
            case .headings: "The translation changed the document structure. The saved copy was preserved."
            case .oversizedBlock: "A protected block is too large to translate safely. The saved copy was preserved."
            }
        }
    }

    public static func validate(source: String, translated: String) throws {
        guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.empty }
        func protected(_ text: String) -> [String] {
            captures(#"!?\[[^\]\n]*\]\(([^\s)]+)(?:\s+[^)]*)?\)"#, text, group: 1)
                + captures(#"(?:https?://|nodus://)[^\s)\]"<>]+"#, text)
                + captures(#"```[^\n]*\n[\s\S]*?```|`[^`\n]+`|\$\$[\s\S]*?\$\$|(?<!\$)\$[^$\n]+\$(?!\$)"#, text)
        }
        guard protected(source).sorted() == protected(translated).sorted() else { throw Failure.protectedContent }
        let numberPattern = #"\p{N}+(?:[.,:/-]\p{N}+)*"#
        guard captures(numberPattern, source).sorted() == captures(numberPattern, translated).sorted() else { throw Failure.numbers }
        func tableColumns(_ text: String) -> [Int] {
            text.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("|") && $0.trimmingCharacters(in: .whitespaces).hasSuffix("|") }
                .map { $0.replacingOccurrences(of: #"\|"#, with: "").filter { $0 == "|" }.count }
        }
        guard tableColumns(source) == tableColumns(translated) else { throw Failure.tables }
        guard captures(#"(?m)^(#{1,6})\s"#, source, group: 1) == captures(#"(?m)^(#{1,6})\s"#, translated, group: 1) else { throw Failure.headings }
    }

    public static func translate(
        source: String, language: String,
        completion: @Sendable (String, String) async throws -> String
    ) async throws -> String {
        let system = """
        Translate academic Markdown faithfully into \(language). Return only Markdown.
        Preserve heading levels, paragraph boundaries, lists, table columns, quotations and bibliography.
        Copy every URL, nodus:// citation target, number, date, code and formula exactly.
        Do not summarize, add or omit content. Do not spell out digits or convert words to digits:
        translate 'años sesenta' as 'sixties', never '1960s'. Keep numeric tokens byte-identical.
        """
        var result = ""
        for part in try chunks(source) {
            try Task.checkCancellation()
            if part.verbatim { result += part.separator + part.text; continue }
            var translated = try await completion(system, part.text)
            do { try validate(source: part.text, translated: translated) }
            catch let error as Failure {
                // One bounded repair, using the original source, never the invalid copy.
                translated = try await completion(system + "\nThe previous attempt failed validation: \(error). Preserve every protected element exactly.", part.text)
                try validate(source: part.text, translated: translated)
            }
            result += part.separator + translated
        }
        try validate(source: source, translated: result)
        return result
    }

    private struct Part { var text: String; let separator: String; let verbatim: Bool }
    private static func chunks(_ source: String) throws -> [Part] {
        var parts: [Part] = [], current = "", separator = "", fence: String?
        var verbatim = false
        func flush() {
            if !current.isEmpty { parts.append(Part(text: current, separator: separator, verbatim: verbatim)); current = ""; separator = ""; verbatim = false }
        }
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let activeFence = fence {
                current += "\n" + line
                if trimmed.hasPrefix(activeFence) { fence = nil }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") || trimmed == "$$" {
                if !current.isEmpty { flush(); separator = "\n" }
                current = line; verbatim = true
                fence = trimmed == "$$" ? "$$" : String(trimmed.prefix { $0 == trimmed.first })
            } else if trimmed.isEmpty {
                if !current.isEmpty { flush(); separator = "\n\n" } else { separator += "\n" }
            } else {
                if verbatim { flush(); separator = "\n" }
                current += (current.isEmpty ? "" : "\n") + line
            }
        }
        flush()
        // Keep tables and long paragraphs intact. Ordinary paragraphs are packed to
        // a small response budget; protected code and formulas never reach a provider.
        var packed: [Part] = []
        for part in parts {
            guard part.verbatim || part.text.count <= 16_000 else { throw Failure.oversizedBlock }
            if !part.verbatim, let last = packed.last, !last.verbatim,
               last.text.count + part.separator.count + part.text.count <= 4_500 {
                packed[packed.count - 1].text += part.separator + part.text
            } else { packed.append(part) }
        }
        return packed
    }

    private static func captures(_ pattern: String, _ text: String, group: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { preconditionFailure("Invalid translation validation pattern") }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: group), in: text).map { String(text[$0]) }
        }
    }
}
