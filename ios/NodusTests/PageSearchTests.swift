import Foundation
import Testing
@testable import Nodus

/// Find-in-page, asked the questions a reader asks of it.
///
/// The model is the whole of the feature that can be tested without a screen: what counts as a
/// match, what order the matches come in, and what "next" does at the end of the list. The
/// painting is `AttributedString` work and the scrolling is a `ScrollViewProxy`; both take the
/// ranges these produce and neither can make them right.
@Suite("Find in page")
@MainActor
struct PageSearchTests {
    private func page(_ blocks: [(PageSearch.Path, String)]) -> PageSearch {
        let search = PageSearch()
        for (path, text) in blocks { search.register(path, text: text) }
        return search
    }

    @Test("a page with nothing registered offers no search at all")
    func emptyPage() {
        let search = PageSearch()
        #expect(!search.hasContent)
        search.query = "anything"
        #expect(search.matches.isEmpty)
    }

    /// The order is the document's, not the dictionary's. Paths are what make that true without
    /// anybody measuring a frame, and a hash of them would put section nine before section two.
    @Test("matches come back in reading order, whatever order they registered in")
    func readingOrder() {
        let search = page([
            ([2, 1], "the archive again"),
            ([0], "the archive"),
            ([1, 3], "archive"),
            ([1, 1], "an archive here"),
        ])
        search.query = "archive"
        #expect(search.matches.map(\.path) == [[0], [1, 1], [1, 3], [2, 1]])
    }

    @Test("a path sorts before the one that starts with it")
    func pathOrdering() {
        #expect(PageSearch.precedes([1], [1, 0]))
        #expect(PageSearch.precedes([1, 9], [2]))
        #expect(!PageSearch.precedes([2], [1, 9]))
    }

    /// A phone keyboard makes the accent the harder half of "análisis" to reach, and a reader
    /// hunting a word in their own report should not have to spell it the way the model did.
    @Test("case and accents do not stop a match")
    func blindToCaseAndAccents() {
        let search = page([([0], "El análisis de la Memoria histórica")])
        search.query = "analisis"
        #expect(search.matches.count == 1)
        search.query = "MEMORIA"
        #expect(search.matches.count == 1)
    }

    @Test("every occurrence in a paragraph is its own match")
    func repeatedInOneBlock() {
        let search = page([([0], "war, and war, and war again")])
        search.query = "war"
        #expect(search.matches.count == 3)
        #expect(search.matches.allSatisfy { $0.path == [0] })
        // Distinct places, in the order they are read.
        let starts = search.matches.map(\.location)
        #expect(starts == starts.sorted())
        #expect(Set(starts).count == 3)
    }

    @Test("a block hands back its own matches and nobody else's")
    func groupedByBlock() {
        let search = page([([0], "a note"), ([1], "another note about a note")])
        search.query = "note"
        #expect(search.highlights(for: [0])?.ranges.count == 1)
        #expect(search.highlights(for: [1])?.ranges.count == 2)
        #expect(search.highlights(for: [9]) == nil)
        // The active one is the first, and it belongs to the first block alone.
        #expect(search.highlights(for: [0])?.active != nil)
        #expect(search.highlights(for: [1])?.active == nil)
    }

    @Test("typing goes to the first match without being asked")
    func typingAims() {
        let search = page([([0], "nothing here"), ([4], "the word")])
        search.query = "word"
        #expect(search.activeIndex == 0)
        #expect(search.scrollTarget?.path == [4])
    }

    /// Wrapping rather than stopping: the count beside the buttons already says where you are,
    /// and a button that goes dead at match twelve of twelve reads as broken.
    @Test("next walks the matches and comes back round")
    func walkingWraps() {
        let search = page([([0], "one"), ([1], "one"), ([2], "one")])
        search.query = "one"
        #expect(search.activeIndex == 0)

        search.next()
        #expect(search.activeIndex == 1)
        #expect(search.scrollTarget?.path == [1])

        search.next()
        search.next()
        #expect(search.activeIndex == 0)

        search.previous()
        #expect(search.activeIndex == 2)
    }

    /// Two "next"es onto the same paragraph are two requests to scroll. Without the nonce the
    /// second one is the same value as the first and the page does not move.
    @Test("asking twice for the same block is two requests")
    func targetIsNotSwallowed() {
        let search = page([([0], "one one")])
        search.query = "one"
        let first = search.scrollTarget
        search.next()
        #expect(search.scrollTarget?.path == first?.path)
        #expect(search.scrollTarget != first)
    }

    @Test("a block that goes away takes its matches with it")
    func unregistering() {
        let search = page([([0], "the corpus"), ([1], "the corpus again")])
        search.query = "corpus"
        #expect(search.matches.count == 2)

        search.unregister([1])
        #expect(search.matches.count == 1)
        #expect(search.hasContent)

        search.unregister([0])
        #expect(search.matches.isEmpty)
        #expect(!search.hasContent)
    }

    @Test("a block that arrives while a search is out joins it")
    func registeringDuringASearch() {
        let search = page([([0], "the corpus")])
        search.query = "corpus"
        #expect(search.matches.count == 1)

        search.register([1], text: "the corpus, later")
        #expect(search.matches.count == 2)
        // The reader was looking at the first one and still is.
        #expect(search.activeIndex == 0)
    }

    @Test("closing the bar forgets what was being looked for")
    func closing() {
        let search = page([([0], "something")])
        search.open()
        search.query = "some"
        #expect(!search.matches.isEmpty)

        search.close()
        #expect(!search.isOpen)
        #expect(search.query.isEmpty)
        #expect(search.matches.isEmpty)
        #expect(search.highlights(for: [0]) == nil)
    }

    @Test("whitespace on its own is not a search")
    func blankQuery() {
        let search = page([([0], "a page with spaces in it")])
        search.query = "   "
        #expect(search.matches.isEmpty)
    }

    /// The ranges are handed to `NSAttributedString`, which counts UTF-16. A page with an emoji
    /// on it is where a character count would quietly paint the wrong word.
    @Test("a range lands on the word it was found in, past an emoji")
    func utf16Ranges() {
        let text = "🌍 the archive"
        let found = PageSearch.ranges(of: "archive", in: text)
        #expect(found.count == 1)
        if let range = found.first {
            #expect((text as NSString).substring(with: range) == "archive")
        }
    }
}
