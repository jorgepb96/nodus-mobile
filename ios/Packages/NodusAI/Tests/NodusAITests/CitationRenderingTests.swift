import Foundation
import Testing
@testable import NodusAI

@Suite("Citations a reader can read")
struct CitationRenderingTests {
    // The bug this whole file exists for: a report arrived with
    // "(passage/920737fb-4eb1-4033-a5e6-cbc50d05f2be#42)" in the middle of a sentence, which is
    // a primary key where a citation should be.
    @Test("a bare token becomes the source's name, and keeps its destination")
    func namesABareToken() {
        let prose = "La guía deshistoriza la experiencia (nodus://idea/g-0082)."
        let linked = CitationRendering.linking(prose, labels: ["nodus://idea/g-0082": "Arco Blanco, M., 2020"])

        #expect(linked == "La guía deshistoriza la experiencia ([Arco Blanco, M., 2020](nodus://idea/g-0082)).")
        #expect(!linked.contains("(nodus://idea/g-0082)."), "the raw token must not survive as text")
    }

    @Test("a citation already written as a link is left exactly as it is")
    func leavesLinksAlone() {
        let prose = "Como sostiene [Otro nombre](nodus://work/w-1), la autarquía fue una política."
        #expect(CitationRendering.linking(prose, labels: ["nodus://work/w-1": "Arco Blanco, M., 2020"]) == prose)
    }

    // A citation whose source the corpus cannot name is still a citation somebody made. Turning
    // it into "[](nodus://…)" would delete it from the page while pretending to render it.
    @Test("a token with no label keeps its own text")
    func keepsUnlabelledTokens() {
        let prose = "Algo (nodus://gap/x-1)."
        #expect(CitationRendering.linking(prose, labels: ["nodus://gap/x-1": ""]) == prose)
        #expect(CitationRendering.linking(prose, labels: [:]) == prose)
    }

    @Test("every citation on a page is found once, linked or bare")
    func collectsTokens() {
        let prose = "Uno (nodus://idea/a) y [dos](nodus://work/b) y otra vez (nodus://idea/a)."
        #expect(CitationRendering.tokens(in: prose) == ["nodus://idea/a", "nodus://work/b"])
    }

    @Test("prose that has been linked no longer reads as unfinished")
    func knowsWhenItIsDone() {
        #expect(CitationRendering.hasBareToken(in: "Algo (nodus://idea/a)."))
        #expect(!CitationRendering.hasBareToken(in: "Algo ([Autor, 2020](nodus://idea/a))."))
        #expect(!CitationRendering.hasBareToken(in: "Prosa sin citas."))
    }

    @Test("a token names its kind and its record, percent-encoding included")
    func parsesTokens() {
        #expect(CitationRendering.parse("nodus://idea/g-0082")?.kind == "idea")
        #expect(CitationRendering.parse("nodus://passage/920737fb#42")?.id == "920737fb#42")
        #expect(CitationRendering.parse("nodus://work/a%20b")?.id == "a b")
        #expect(CitationRendering.parse("https://example.com/idea/x") == nil)
    }
}

@Suite("How a source is named")
struct WorkCitationTests {
    // Nodus stores "Apellido, Nombre"; a citation wants "Apellido, N." — and the year sits
    // behind a comma rather than in parentheses, because the writer is told to put the whole
    // citation in parentheses and two nested pairs read as a mistake.
    @Test("an inline citation is surname, initial and year")
    func inlineIsAuthorYear() {
        let work = WorkCitation(id: "w-1", authors: ["Arco Blanco, Miguel Ángel"], year: "2020", title: "Hambre de siglos")
        #expect(work.inline == "Arco Blanco, M., 2020")
        #expect("(\(work.inline))" == "(Arco Blanco, M., 2020)")
    }

    @Test("a name written given-first is still read surname-last")
    func readsBothSpellings() {
        #expect(WorkCitation(id: "w", authors: ["Miguel Ángel Arco Blanco"], year: "2020").inline == "Blanco, M., 2020")
    }

    // "Author (2020)" in the middle of academic prose reads as a placeholder. A shortened title
    // is a real citation for a work whose author the corpus never captured.
    @Test("a work with no author is cited by its title, never by a placeholder")
    func fallsBackToTheTitle() {
        let work = WorkCitation(id: "w-2", authors: [], year: "1957", title: "Guía turística de España")
        #expect(work.inline == "Guía turística de España, 1957")
        #expect(WorkCitation(id: "w-3").inline == "w-3")
    }

    @Test("the reference list keeps the parentheses and the full names")
    func bibliographyIsFuller() {
        let work = WorkCitation(id: "w-1", authors: ["Arco Blanco, Miguel Ángel"], year: "2020", title: "Hambre de siglos")
        #expect(work.bibliography == "Arco Blanco, Miguel Ángel (2020). Hambre de siglos")
    }

    @Test("a passage names the work its id was cut from")
    func passageImpliesItsWork() {
        let passage = CitationCatalog.Entry(
            token: "nodus://passage/920737fb-4eb1-4033-a5e6-cbc50d05f2be#42",
            kind: "passage",
            id: "920737fb-4eb1-4033-a5e6-cbc50d05f2be#42",
            label: "…"
        )
        #expect(passage.impliedWorkId == "920737fb-4eb1-4033-a5e6-cbc50d05f2be")

        let idea = CitationCatalog.Entry(token: "nodus://idea/g-1", kind: "idea", id: "g-1", label: "…")
        #expect(idea.impliedWorkId == nil, "an idea's work lives in a table, not in its id")

        // A vault whose passages are keyed some other way must say "ask the corpus", not
        // "the work is this passage". Splitting on an absent "#" returns the whole id, which
        // made every such citation a 404 and left it on the page as a raw identifier.
        let elsewhere = CitationCatalog.Entry(token: "nodus://passage/p-w-01-1", kind: "passage", id: "p-w-01-1", label: "…")
        #expect(elsewhere.impliedWorkId == nil)
    }
}

@Suite("Assembly names the sources")
struct CitationAssemblyTests {
    private var request: DeepResearchRequest {
        DeepResearchRequest(
            objective: "La guía turística como operación narrativa",
            targetLength: .concise,
            model: ModelRef(provider: .anthropic, model: "claude-test")
        )
    }

    private func source(_ tokens: [String]) -> CitationCatalog {
        CitationCatalog(entries: tokens.map { token in
            let parsed = CitationRendering.parse(token)!
            return CitationCatalog.Entry(token: token, kind: parsed.kind, id: parsed.id, label: "Material \(parsed.id)")
        })
    }

    @Test("a finished report cites by name, not by id")
    func rewritesTheProse() async throws {
        let catalog = source(["nodus://idea/g-0082", "nodus://passage/920737fb#42"])
        let orchestrator = DeepResearchOrchestrator(deps: DeepResearchDeps(
            buildCatalog: { _ in catalog },
            retrieveForSection: { _, _ in catalog },
            plan: { _, _, _, _ in ["Única"] },
            writeSection: { _, _, _, _, _, _ in
                "Una selección narrativa (nodus://passage/920737fb#42) que deshistoriza (nodus://idea/g-0082)."
            },
            describeCitations: { cited in
                let work = WorkCitation(id: "920737fb", authors: ["Arco Blanco, Miguel Ángel"], year: "2020", title: "Hambre de siglos")
                return CitationLabelling(
                    inline: Dictionary(uniqueKeysWithValues: cited.map { ($0.token, $0.kind == "passage" ? "\(work.inline), p. 42" : work.inline) }),
                    references: [.init(token: "nodus://work/920737fb", kind: "work", id: "920737fb", label: work.bibliography)]
                )
            }
        ))
        let report = try await orchestrator.run(request)

        let prose = report.sections[0].prose
        #expect(prose.contains("[Arco Blanco, M., 2020, p. 42](nodus://passage/920737fb#42)"))
        #expect(prose.contains("[Arco Blanco, M., 2020](nodus://idea/g-0082)"))
        #expect(!CitationRendering.hasBareToken(in: prose), "no citation is left as a bare id")

        // The bibliography of a report that cited no work token directly. Before this, it was
        // empty: a report resting entirely on ideas and passages listed no sources at all.
        #expect(report.references.map(\.label) == ["Arco Blanco, Miguel Ángel (2020). Hambre de siglos"])
    }

    @Test("a work first met in a later section still reaches the bibliography")
    func keepsSectionOnlySources() async throws {
        let global = source(["nodus://idea/g-1"])
        let extra = source(["nodus://work/w-late"])
        let orchestrator = DeepResearchOrchestrator(deps: DeepResearchDeps(
            buildCatalog: { _ in global },
            retrieveForSection: { title, _ in title == "Segunda" ? extra : global },
            plan: { _, _, _, _ in ["Primera", "Segunda"] },
            writeSection: { _, title, _, _, _, _ in
                title == "Segunda"
                    ? "Aquí aparece una obra nueva (nodus://work/w-late)."
                    : "Aquí solo una idea (nodus://idea/g-1)."
            }
        ))
        let report = try await orchestrator.run(request)
        #expect(report.references.map(\.id) == ["w-late"])
    }

    // A model that writes the whole Markdown link is not doing what it was asked, but it is
    // doing something recognisable. What it must never be able to do is name a source that
    // does not exist.
    @Test("an invented citation written as a link disappears with its label")
    func stripsInventedLinks() {
        let result = CitationValidator.validate(
            prose: "Real [Autor](nodus://idea/g-1) e inventada [Nadie (1999)](nodus://work/no-existe).",
            against: source(["nodus://idea/g-1"])
        )
        #expect(result.accepted == ["nodus://idea/g-1"])
        #expect(result.rejected == ["nodus://work/no-existe"])
        #expect(!result.prose.contains("Nadie"))
        #expect(!result.prose.contains("no-existe"))
        #expect(result.prose.contains("nodus://idea/g-1"))
    }

    @Test("a chosen section count is a ceiling with one section of grace")
    func sectionCeilingHasGrace() {
        let six = DeepResearchLimits.sectionPlan(pages: 9...14, requested: 6)
        #expect(six.target == 6)
        #expect(six.hardCap == 7, "the desktop's SECTION_GRACE, so the material can ask for one more")

        let ten = DeepResearchLimits.sectionPlan(pages: 15...20, requested: 10)
        #expect(ten == (target: 10, hardCap: 11))
    }
}
