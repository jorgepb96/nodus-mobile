import Foundation
import Testing
@testable import Nodus

@Suite("Report library controls")
struct ReportLibraryControlsTests {
    private struct Entry: Equatable {
        let id: String
        let date: Date?
    }

    @Test("reports can run newest first or oldest first, with unknown dates last")
    func dateOrder() {
        let entries = [
            Entry(id: "middle", date: Date(timeIntervalSince1970: 20)),
            Entry(id: "unknown", date: nil),
            Entry(id: "old", date: Date(timeIntervalSince1970: 10)),
            Entry(id: "new", date: Date(timeIntervalSince1970: 30)),
        ]

        #expect(ReportLibrarySortOrder.newest.ordered(entries, date: \.date).map(\.id)
            == ["new", "middle", "old", "unknown"])
        #expect(ReportLibrarySortOrder.oldest.ordered(entries, date: \.date).map(\.id)
            == ["old", "middle", "new", "unknown"])
    }

    @Test("equal dates keep their list order")
    func stableOrder() {
        let same = Date(timeIntervalSince1970: 20)
        let entries = [Entry(id: "first", date: same), Entry(id: "second", date: same)]

        #expect(ReportLibrarySortOrder.newest.ordered(entries, date: \.date).map(\.id)
            == ["first", "second"])
        #expect(ReportLibrarySortOrder.oldest.ordered(entries, date: \.date).map(\.id)
            == ["first", "second"])
    }

    @Test("the reading filter includes all, read, or unread reports")
    func readingFilter() {
        let readIds: Set<String> = ["read"]
        let isRead: (String) -> Bool = { readIds.contains($0) }

        #expect(ReportLibraryReadFilter.all.includes(id: "read", isRead: isRead))
        #expect(ReportLibraryReadFilter.all.includes(id: "unread", isRead: isRead))
        #expect(ReportLibraryReadFilter.read.includes(id: "read", isRead: isRead))
        #expect(!ReportLibraryReadFilter.read.includes(id: "unread", isRead: isRead))
        #expect(ReportLibraryReadFilter.unread.includes(id: "unread", isRead: isRead))
        #expect(!ReportLibraryReadFilter.unread.includes(id: "read", isRead: isRead))
    }

    @Test("a row without an id is unread because it cannot carry a read mark")
    func missingIdIsUnread() {
        #expect(!ReportLibraryReadFilter.read.includes(id: nil, isRead: { _ in true }))
        #expect(ReportLibraryReadFilter.unread.includes(id: nil, isRead: { _ in true }))
    }
}

/// What a reader's marks survive.
///
/// The read mark is cheap to lose and the bookmark is not: it is the one thing on the phone that
/// says where somebody stopped in a twenty-page report, and a report is reopened days later on a
/// different launch of the app. So every test here reopens the store rather than reading the
/// array it just wrote — an in-memory answer proves nothing about the thing that matters.
@Suite("Report marks")
@MainActor
struct ReportMarksTests {
    private func temporaryRoot() -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("marks-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a report is unread and unmarked until it is marked")
    func nothingIsAssumed() {
        let store = ReportMarks(spaceId: "space-1", root: temporaryRoot())

        #expect(store.isRead("r-1") == false)
        #expect(store.bookmark(for: "r-1") == nil)
        #expect(store.marks.isEmpty)
    }

    @Test("being read outlives the store")
    func readMarkIsWritten() {
        let root = temporaryRoot()
        let store = ReportMarks(spaceId: "space-2", root: root)

        store.setRead("r-1", true)

        ReportMarks.settle()
        let reopened = ReportMarks(spaceId: "space-2", root: root)
        #expect(reopened.isRead("r-1"))
        #expect(reopened.isRead("r-2") == false, "one report's mark is not another's")
    }

    // A mark taken back must not leave `{readAt: null}` behind: the file would otherwise grow by
    // an entry for every report ever opened and unmarked again.
    @Test("taking a mark back leaves nothing on disk")
    func unmarkingRemovesTheEntry() {
        let root = temporaryRoot()
        let store = ReportMarks(spaceId: "space-3", root: root)

        store.setRead("r-1", true)
        store.setRead("r-1", false)

        #expect(store.marks["r-1"] == nil)
        ReportMarks.settle()
        let reopened = ReportMarks(spaceId: "space-3", root: root)
        #expect(reopened.marks.isEmpty)
    }

    @Test("a report keeps one bookmark, and marking again moves it")
    func onlyOneBookmark() {
        let root = temporaryRoot()
        let store = ReportMarks(spaceId: "space-4", root: root)

        store.setBookmark(
            ReportMarks.Bookmark(path: [1, 1, 0], location: 4, length: 7, snippet: "primera", markedAt: Date()),
            for: "r-1"
        )
        store.setBookmark(
            ReportMarks.Bookmark(path: [3, 1, 2], location: 40, length: 6, snippet: "última", markedAt: Date()),
            for: "r-1"
        )

        ReportMarks.settle()
        let reopened = ReportMarks(spaceId: "space-4", root: root)
        let bookmark = reopened.bookmark(for: "r-1")
        #expect(bookmark?.snippet == "última")
        #expect(bookmark?.path == [3, 1, 2])
    }

    @Test("being read and being bookmarked are independent")
    func theTwoMarksDoNotOverwriteEachOther() {
        let root = temporaryRoot()
        let store = ReportMarks(spaceId: "space-5", root: root)

        store.setBookmark(
            ReportMarks.Bookmark(path: [2, 1, 0], location: 0, length: 5, snippet: "Donde", markedAt: Date()),
            for: "r-1"
        )
        store.setRead("r-1", true)
        store.setRead("r-1", false)

        ReportMarks.settle()
        let reopened = ReportMarks(spaceId: "space-5", root: root)
        #expect(reopened.isRead("r-1") == false)
        #expect(reopened.bookmark(for: "r-1")?.snippet == "Donde", "unmarking as read must not drop the bookmark")
    }

    // Ids are UUIDs on this device but row ids in a vault, and a vault that reissues one would
    // hand the new report somebody else's bookmark.
    @Test("deleting a report forgets everything about it")
    func forgetClearsBoth() {
        let root = temporaryRoot()
        let store = ReportMarks(spaceId: "space-6", root: root)

        store.setRead("r-1", true)
        store.setBookmark(
            ReportMarks.Bookmark(path: [1, 1, 0], location: 0, length: 4, snippet: "Uno", markedAt: Date()),
            for: "r-1"
        )
        store.setRead("r-2", true)
        store.forget("r-1")

        ReportMarks.settle()
        let reopened = ReportMarks(spaceId: "space-6", root: root)
        #expect(reopened.marks["r-1"] == nil)
        #expect(reopened.isRead("r-2"), "another report's mark is untouched")
    }

    @Test("two spaces keep their own marks")
    func marksAreScopedToASpace() {
        let root = temporaryRoot()
        ReportMarks(spaceId: "space-a", root: root).setRead("r-1", true)

        ReportMarks.settle()
        #expect(ReportMarks(spaceId: "space-b", root: root).isRead("r-1") == false)
        #expect(ReportMarks(spaceId: "space-a", root: root).isRead("r-1"))
    }
}

/// The bookmark while a report is open: where it is drawn, and what happens to it when the
/// paragraph it sits in is rewritten under it.
@Suite("Reading bookmark")
@MainActor
struct ReadingBookmarksTests {
    private func bookmarks(_ bookmark: ReportMarks.Bookmark?) -> (ReadingBookmarks, () -> ReportMarks.Bookmark??) {
        var persisted: ReportMarks.Bookmark??
        let object = ReadingBookmarks(bookmark: bookmark) { persisted = $0 }
        return (object, { persisted })
    }

    @Test("only the block the mark is in draws it")
    func placementIsScopedToItsBlock() {
        let (object, _) = bookmarks(
            ReportMarks.Bookmark(path: [2, 1, 3], location: 5, length: 4, snippet: "hola", markedAt: Date())
        )

        #expect(object.placement(for: [2, 1, 3])?.range == NSRange(location: 5, length: 4))
        #expect(object.placement(for: [2, 1, 4]) == nil)
        #expect(object.placement(for: [2, 1]) == nil)
    }

    @Test("asking to go back to the mark is a new request every time")
    func aimingIsNonced() {
        let (object, _) = bookmarks(
            ReportMarks.Bookmark(path: [1], location: 0, length: 3, snippet: "uno", markedAt: Date())
        )
        let first = object.placement(for: [1])?.aim

        object.aimAtBookmark()
        object.aimAtBookmark()

        #expect(object.placement(for: [1])?.aim != first)
        #expect(object.placement(for: [1])?.aim == (first ?? 0) + 2)
    }

    @Test("marking a selection replaces whatever was marked, and is written down")
    func settingReplacesAndPersists() {
        let (object, persisted) = bookmarks(
            ReportMarks.Bookmark(path: [1], location: 0, length: 3, snippet: "uno", markedAt: Date())
        )

        object.set(path: [4, 1, 2], range: NSRange(location: 12, length: 6), snippet: "  la mar\n ")

        #expect(object.bookmark?.path == [4, 1, 2])
        // Trimmed and flattened: a selection that caught a newline could never be found again
        // in the single line the paragraph is registered as.
        #expect(object.bookmark?.snippet == "la mar")
        #expect(persisted()??.snippet == "la mar")
    }

    @Test("clearing is written down too")
    func clearingPersists() {
        let (object, persisted) = bookmarks(
            ReportMarks.Bookmark(path: [1], location: 0, length: 3, snippet: "uno", markedAt: Date())
        )

        object.clear()

        #expect(object.bookmark == nil)
        #expect(persisted() == .some(nil), "the removal reaches the store rather than only the screen")
    }

    // The reason the snippet is stored at all. A report written before its citations were
    // resolved is repaired the first time it is opened, and naming a source moves every
    // character after it in that paragraph.
    @Test("a paragraph rewritten under the mark moves the mark, not the reader")
    func reconcileFollowsTheWords() {
        let original = "Ver (nodus://idea/g-1) sobre la escasez."
        let repaired = "Ver (Arco Blanco, 2020) sobre la escasez."
        let range = (original as NSString).range(of: "la escasez")
        let (object, persisted) = bookmarks(
            ReportMarks.Bookmark(
                path: [1, 1, 0],
                location: range.location,
                length: range.length,
                snippet: "la escasez",
                markedAt: Date()
            )
        )

        object.reconcile(path: [1, 1, 0], displayed: repaired)

        let moved = try! #require(object.bookmark)
        #expect((repaired as NSString).substring(with: moved.range) == "la escasez")
        #expect(moved.location != range.location, "the offset really did have to move")
        #expect(persisted()??.location == moved.location)
    }

    @Test("a paragraph whose words are gone keeps the mark where it was")
    func reconcileDoesNotGuess() {
        let (object, persisted) = bookmarks(
            ReportMarks.Bookmark(path: [1], location: 4, length: 6, snippet: "escasez", markedAt: Date())
        )

        object.reconcile(path: [1], displayed: "Otra cosa entera.")

        #expect(object.bookmark?.location == 4, "a mark that cannot be found is left alone, not moved somewhere")
        #expect(persisted() == nil, "and nothing is written")
    }

    @Test("a paragraph that still matches is not rewritten")
    func reconcileIsQuietWhenNothingMoved() {
        let text = "Ver la escasez."
        let range = (text as NSString).range(of: "la escasez")
        let (object, persisted) = bookmarks(
            ReportMarks.Bookmark(
                path: [1],
                location: range.location,
                length: range.length,
                snippet: "la escasez",
                markedAt: Date()
            )
        )

        object.reconcile(path: [1], displayed: text)

        #expect(persisted() == nil, "an unchanged paragraph must not rewrite the file on every appearance")
    }

    @Test("a long passage is cut for a label rather than wrapped")
    func labelIsShortened() {
        let long = String(repeating: "palabra ", count: 40)

        let label = ReadingBookmarks.label(long, limit: 20)

        #expect(label.count == 21)
        #expect(label.hasSuffix("…"))
        #expect(ReadingBookmarks.label("  corto  ", limit: 20) == "corto")
    }
}
