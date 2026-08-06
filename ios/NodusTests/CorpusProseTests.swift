import Foundation
import Testing
@testable import Nodus

/// Turning the citations the desktop writes into links a reader can press.
///
/// The regular expression behind this is compiled once and shared by every paragraph of every
/// report on the screen, which is the whole point — building it per call was a fifth of the cost
/// of preparing a report's prose. A shared `NSRegularExpression` is only safe because it is
/// immutable, so the tests that matter most here are the ones that call it repeatedly and expect
/// the same answer every time.
@Suite("Corpus prose")
struct CorpusProseTests {
    private let labels = [
        "nodus://idea/g-8969": "Arco Blanco (2020)",
        "nodus://work/w-1": "Mill (1859)",
    ]

    @Test("a bare token becomes a link wearing its source's name")
    func bareTokensAreNamed() {
        let linked = CorpusProse.linkify("Ver (nodus://idea/g-8969) sobre la escasez.", labels: labels)

        #expect(linked == "Ver ([Arco Blanco (2020)](nodus://idea/g-8969)) sobre la escasez.")
    }

    @Test("a token with no label keeps its own text rather than disappearing")
    func unknownTokensSurvive() {
        let linked = CorpusProse.linkify("Ver nodus://idea/g-0000 aquí.", labels: labels)

        #expect(linked == "Ver [idea/g-0000](nodus://idea/g-0000) aquí.")
    }

    // The desktop already writes Markdown links. Rewriting one would nest a link inside a link
    // and put the raw address on screen.
    @Test("a citation that is already a link is left alone")
    func existingLinksAreUntouched() {
        let source = "Ver [Arco Blanco (2020)](nodus://idea/g-8969) sobre la escasez."

        #expect(CorpusProse.linkify(source, labels: labels) == source)
    }

    @Test("prose with no citation in it comes back unchanged")
    func plainProseIsUnchanged() {
        let source = "La escasez de la posguerra no fue solamente el resultado de una economía arrasada."

        #expect(CorpusProse.linkify(source, labels: labels) == source)
    }

    @Test("several citations in one paragraph are all named")
    func severalTokens() {
        let linked = CorpusProse.linkify(
            "Uno (nodus://idea/g-8969) y dos (nodus://work/w-1).",
            labels: labels
        )

        #expect(linked == "Uno ([Arco Blanco (2020)](nodus://idea/g-8969)) y dos ([Mill (1859)](nodus://work/w-1)).")
    }

    // The one that guards the shared expression. A regex that carried state between calls — or a
    // lazily built one that raced — would show up here and nowhere else, because every other test
    // in this file calls it once.
    @Test("the same paragraph linkifies the same way however often it is asked")
    func repeatedCallsAgree() {
        let source = "Ver (nodus://idea/g-8969) y también (nodus://work/w-1)."
        let first = CorpusProse.linkify(source, labels: labels)

        for _ in 0..<200 {
            #expect(CorpusProse.linkify(source, labels: labels) == first)
        }
    }

    // Brackets in a source's name would close the Markdown link early and leave the rest of it
    // on the page as text.
    @Test("brackets in a label cannot break the link they are inside")
    func bracketsInLabelsAreDefused() {
        let linked = CorpusProse.linkify(
            "Ver (nodus://idea/g-8969).",
            labels: ["nodus://idea/g-8969": "Arco [sic] Blanco"]
        )

        #expect(linked == "Ver ([Arco (sic) Blanco](nodus://idea/g-8969)).")
    }
}
