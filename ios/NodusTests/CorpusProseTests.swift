import Foundation
import NodusKit
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

    @Test("a contradiction citation routes to its published debate")
    func contradictionRoutesToDebate() throws {
        let singular = try #require(CorpusReference(URL(string: "nodus://contradiction/edge-42")!))
        let plural = CorpusReference(kind: "contradictions", recordId: "edge-42")

        #expect(singular.kind == "contradiction")
        #expect(singular.recordId == "edge-42")
        #expect(singular.destination == .debate)
        #expect(plural.destination == .debate)
    }

    @Test("a published debate retains both positions and their evidence")
    func debateCitationKeepsSourceMaterial() {
        let row = Row([
            "relation": .string("contradicts"),
            "basis": .string("inferred"),
            "confidence": .double(0.9),
            "tension": .string("The positions disagree."),
            "sideA": .object([
                "label": .string("Representation and reality"),
                "statement": .string("Tourism photography idealises its subjects."),
                "works": .array([.object([
                    "evidence": .array([.object([
                        "quote": .string("The official image concealed material hardship."),
                        "location": .string("p. 619"),
                        "kind": .string("explicit"),
                    ])]),
                ])]),
            ]),
            "sideB": .object([
                "label": .string("Photography as critique"),
                "statement": .string("Documentary photography exposed social reality."),
                "works": .array([]),
            ]),
        ])

        let debate = DebateCitation(row)

        #expect(debate.relation == "contradicts")
        #expect(debate.basis == "inferred")
        #expect(debate.confidence == 0.9)
        #expect(debate.sideA.label == "Representation and reality")
        #expect(debate.sideB.label == "Photography as critique")
        #expect(debate.sideA.copyText == "Tourism photography idealises its subjects.")
        #expect(debate.sideB.copyText == "Documentary photography exposed social reality.")
        #expect(debate.evidence.count == 1)
        #expect(debate.evidence[0].quote == "The official image concealed material hardship.")
        #expect(debate.evidence[0].location == "p. 619")
        #expect(debate.evidence[0].side == "A")
    }

    @Test("copying a claim falls back to its visible label when no statement was published")
    func claimCopyFallsBackToLabel() {
        let side = DebateCitation.Side(.object(["label": .string("Photography as critique")]))

        #expect(side.copyText == "Photography as critique")
    }
}
