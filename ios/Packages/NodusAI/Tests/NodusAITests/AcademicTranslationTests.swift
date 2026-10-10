import Foundation
import Testing
@testable import NodusAI

@Suite("Academic translation integrity")
struct AcademicTranslationTests {
    private let source = "# Informe\n\nEn 1964, 25 años. [Fuente](nodus://work/abc123).\n\n| Año | Valor |\n|---|---|\n| 1964 | 37 |\n\n$$x=2$$"

    @Test("translated prose preserves source targets, dates, formulas and tables")
    func preserved() throws {
        try AcademicTranslation.validate(source: source, translated: source.replacingOccurrences(of: "Informe", with: "Report").replacingOccurrences(of: "años", with: "years").replacingOccurrences(of: "Fuente", with: "Source"))
    }

    @Test("altered protected elements fail before a copy can be saved")
    func corrupted() {
        #expect(throws: AcademicTranslation.Failure.protectedContent) { try AcademicTranslation.validate(source: source, translated: source.replacingOccurrences(of: "abc123", with: "abc124")) }
        #expect(throws: AcademicTranslation.Failure.numbers) { try AcademicTranslation.validate(source: source, translated: source.replacingOccurrences(of: "25 años", with: "26 years")) }
        #expect(throws: AcademicTranslation.Failure.headings) { try AcademicTranslation.validate(source: source, translated: source.replacingOccurrences(of: "# Informe", with: "## Report")) }
        #expect(throws: AcademicTranslation.Failure.tables) { try AcademicTranslation.validate(source: source, translated: source.replacingOccurrences(of: "| Año | Valor |", with: "| Year | Value | Extra |")) }
        #expect(throws: AcademicTranslation.Failure.empty) { try AcademicTranslation.validate(source: source, translated: " ") }
    }

    @Test("long documents retain paragraph boundaries and opaque blocks without provider edits")
    func chunked() async throws {
        let opaque = "```swift\nlet year = 1964\n\nlet count = 25\n```"
        let original = Array(repeating: String(repeating: "Texto académico. ", count: 100), count: 12).joined(separator: "\n\n") + "\n\n" + opaque + "\n\n$$\nx=37\n$$"
        let provider = TranslationProbe()
        let result = try await AcademicTranslation.translate(source: original, language: "English") { system, input in
            await provider.record(system, input); return input
        }
        #expect(result == original)
        let requests = await provider.inputs
        #expect(requests.count > 1)
        #expect(requests.allSatisfy { !$0.contains("let year") && !$0.contains("x=37") && $0.count <= 4_500 })
    }

    @Test("invalid responses get one bounded repair and never return an incomplete copy")
    func boundedRepair() async throws {
        let provider = TranslationProbe()
        await #expect(throws: AcademicTranslation.Failure.numbers) {
            try await AcademicTranslation.translate(source: "En 1964", language: "English") { system, input in
                await provider.record(system, input); return "In 1965"
            }
        }
        #expect(await provider.inputs.count == 2)
    }

    @Test("an altered first attempt can be repaired using the original source")
    func repaired() async throws {
        let provider = TranslationProbe()
        let result = try await AcademicTranslation.translate(source: "En 1964", language: "English") { system, input in
            let count = await provider.record(system, input)
            return count == 1 ? "In 1965" : "In 1964"
        }
        #expect(result == "In 1964")
        #expect(await provider.inputs == ["En 1964", "En 1964"])
    }
}

private actor TranslationProbe {
    var inputs: [String] = []
    @discardableResult func record(_ system: String, _ input: String) -> Int { inputs.append(input); return inputs.count }
}
