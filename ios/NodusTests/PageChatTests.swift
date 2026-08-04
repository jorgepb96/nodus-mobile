import Foundation
import NodusAI
import Testing
@testable import Nodus

/// The report chat's one hard rule: a number a reader can tap has to point at a paragraph that
/// exists. The model is asked for that in the prompt; these are what make it true.
@Suite("Report chat")
struct PageChatTests {
    @Test("the passages an answer cites come back in the order they were used")
    func referencedInOrder() {
        let prose = "It says so in [3], and again in [1]. Also [3] once more."
        #expect(PageChatPrompt.referenced(in: prose, count: 5) == [3, 1])
    }

    /// A model that cites passage 40 of a nine-passage report has invented a door. It is taken
    /// out rather than drawn, which is the same bargain `CitationValidator` strikes with corpus
    /// tokens: the prompt gets it right most of the time, this makes it true.
    @Test("a number the document does not have is struck out")
    func unknownReferencesGo() {
        let prose = "As [2] argues, unlike [40]."
        let cleaned = PageChatPrompt.dropUnknownReferences(prose, count: 9)
        #expect(cleaned == "As [2] argues, unlike .")
        #expect(PageChatPrompt.referenced(in: cleaned, count: 9) == [2])
    }

    @Test("a reference becomes a link the prose can hand back on tap")
    func linkified() {
        let linked = PageChatPrompt.linkifyReferences("See [2].", count: 4)
        #expect(linked == "See [2](nodusref://2).")
        let url = try? #require(URL(string: "nodusref://2"))
        #expect(PageChatReference.number(in: url ?? URL(fileURLWithPath: "/")) == 2)
    }

    /// The prose also carries `[label](nodus://idea/g-1)` citations, and a Markdown link opens
    /// with the same bracket. Turning one of those into a reference would break every corpus
    /// citation in the answer.
    @Test("a corpus citation is not mistaken for a passage number")
    func markdownLinksSurvive() {
        let prose = "[Arco Blanco (2020)](nodus://idea/g-8969) and [2] agree."
        let linked = PageChatPrompt.linkifyReferences(prose, count: 3)
        #expect(linked.contains("[Arco Blanco (2020)](nodus://idea/g-8969)"))
        #expect(linked.contains("[2](nodusref://2)"))
        #expect(PageChatPrompt.dropUnknownReferences(prose, count: 3) == prose)
    }

    @Test("a link that is not a reference is not read as one")
    func otherSchemes() throws {
        let idea = try #require(URL(string: "nodus://idea/g-8969"))
        #expect(PageChatReference.number(in: idea) == nil)
        let malformed = try #require(URL(string: "nodusref://north"))
        #expect(PageChatReference.number(in: malformed) == nil)
    }

    /// The document goes into the payload numbered and in reading order — that is the whole
    /// contract between what the model is shown and what a tap can reach.
    @Test("the document reaches the model numbered, in reading order, under its budget")
    func questionCarriesTheDocument() {
        let passages = [
            PageChatPassage(number: 1, path: [0], text: "The registers open in 1876."),
            PageChatPassage(number: 2, path: [1, 0], text: "The correspondence disagrees."),
        ]
        let prompt = PageChatPrompt.question(
            "What do they disagree about?",
            title: "The parish registers",
            passages: passages,
            catalog: CitationCatalog(entries: [])
        )
        #expect(prompt.contains("[1] The registers open in 1876."))
        #expect(prompt.contains("[2] The correspondence disagrees."))
        let first = try? #require(prompt.range(of: "[1] The"))
        let second = try? #require(prompt.range(of: "[2] The"))
        if let first, let second { #expect(first.lowerBound < second.lowerBound) }
    }

    @Test("a document past the budget is cut, and the cut is admitted")
    func budgetIsHonest() {
        let passages = (1...50).map {
            PageChatPassage(number: $0, path: [$0], text: String(repeating: "palabra ", count: 40))
        }
        let prompt = PageChatPrompt.question(
            "…", title: "Long", passages: passages, catalog: CitationCatalog(entries: []), budget: 1_000
        )
        #expect(prompt.contains("El documento continúa"))
        #expect(!prompt.contains("[50]"))
    }

    @MainActor
    @Test("revealing a passage scrolls to it and marks it, and only if it is on the page")
    func revealing() {
        let search = PageSearch()
        search.register([2], text: "A paragraph long enough to be a passage worth citing.")
        search.register([1], text: "An earlier paragraph, also long enough to be worth citing.")

        // Numbered in reading order, not in registration order.
        #expect(search.passages().map(\.path) == [[1], [2]])

        search.reveal([2])
        #expect(search.revealed == [2])
        #expect(search.scrollTarget?.path == [2])

        // A path the page never registered points nowhere, and says so by doing nothing.
        search.reveal([9])
        #expect(search.revealed == [2])
    }

    @MainActor
    @Test("a label too short to be a passage is not offered as one")
    func shortEntriesAreNotPassages() {
        let search = PageSearch()
        search.register([0], text: "Sources")
        search.register([1], text: "A paragraph long enough to be worth pointing at by number.")
        #expect(search.passages().map(\.path) == [[1]])
    }

    /// The conversation belongs to the report, and to that report alone.
    @MainActor
    @Test("each report has its own conversation, and closing it forgets it")
    func storesAreKeyedByReport() {
        let first = PageChatStore.shared(for: "report-a")
        #expect(PageChatStore.shared(for: "report-a") === first)
        #expect(PageChatStore.shared(for: "report-b") !== first)

        first.draft = "half-written"
        PageChatStore.forget("report-a")
        #expect(PageChatStore.shared(for: "report-a").draft.isEmpty)
    }
}
