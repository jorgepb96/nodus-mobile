import Foundation
import Observation
import SwiftUI

/// What this reader has done with a report: whether they have finished it, and where they
/// stopped.
///
/// Kept apart from the reports themselves, and that is the whole design. The library shows two
/// kinds of report — the ones written on this device, which are files in `LocalReportStore`, and
/// the ones the owner published, which are rows on a server this account may well only be
/// allowed to read. "Which of these have I read?" is asked of the *list*, not of one half of it,
/// so the answer cannot live in either half. It lives here, keyed by whichever id the library
/// already uses for the row.
///
/// It stays on the device. A reading mark is not a fact about the vault and nobody else's copy
/// of the report should acquire one because somebody read it on a phone; there is nothing to
/// send and no permission to ask for. It is deliberately outside `CloudBackup` for the same
/// reason the mirror is: nothing here is irreplaceable, and a report costs a model call per
/// section while a mark costs one press.
@Observable
@MainActor
final class ReportMarks {
    /// Where a reader stopped, so the report can open there.
    ///
    /// Identified twice over, on purpose. The `path` is where the marked words sit in the page's
    /// reading order — the same coordinates the find bar walks — and is what makes reopening a
    /// twenty-page report land on the right paragraph without reading it. The `snippet` is the
    /// words themselves, and it is what keeps the mark honest when the offsets no longer hold:
    /// a report written before its citations were named is repaired the first time it is opened
    /// (`LocalReportReader.nameTheSources`), and naming a source rewrites the paragraph it is
    /// in. Without the text to look for again, that repair would silently move somebody's
    /// bookmark into the middle of a different sentence.
    struct Bookmark: Codable, Hashable {
        let path: [Int]
        /// UTF-16, over the text the block *displays* — after the Markdown was parsed and the
        /// citations became their labels — because that is the string every other part of the
        /// page counts in, and the only one the reader can see.
        let location: Int
        let length: Int
        let snippet: String
        let markedAt: Date

        var range: NSRange { NSRange(location: location, length: length) }
    }

    struct Mark: Codable, Hashable {
        var readAt: Date?
        /// One, never a list. A reading bookmark answers "where was I", and a second one makes
        /// that question ambiguous — so setting a new one moves it rather than adding to it.
        var bookmark: Bookmark?

        var isEmpty: Bool { readAt == nil && bookmark == nil }
    }

    private(set) var marks: [String: Mark] = [:]

    private let file: URL

    /// One store per space, shared by the library and by every reader opened from it.
    ///
    /// The same argument as `LocalReportStore.shared(for:)`: the screen that marks a report read
    /// is not the screen that has to stop showing it as unread, and two instances over one file
    /// are two answers to the same question until both are reloaded.
    private static var stores: [String: ReportMarks] = [:]

    static func shared(for spaceId: String) -> ReportMarks {
        if let existing = stores[spaceId] { return existing }
        let store = ReportMarks(spaceId: spaceId)
        stores[spaceId] = store
        return store
    }

    /// - Parameter root: where the `spaces` folder lives. Application Support everywhere except
    ///   in tests, which need a directory they can throw away. Not routed through
    ///   `shared(for:)`, which is a cache keyed on the space alone and would hand a second test
    ///   the first one's file.
    init(spaceId: String, root: URL = .applicationSupportDirectory) {
        let directory = root
            .appendingPathComponent("spaces", isDirectory: true)
            .appendingPathComponent(spaceId, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("reading-marks.json")
        reload()
    }

    /// One file for the whole space rather than one per report.
    ///
    /// A mark is two dates and a sentence; a hundred of them is a few kilobytes read once when
    /// the library appears. A file each would turn drawing that list into a hundred `stat` calls
    /// for no benefit at all — which is the opposite of the argument `LocalReportStore` makes,
    /// where each file is a whole report and reading them all is exactly what must not happen.
    func reload() {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder.nodusReports.decode([String: Mark].self, from: data)
        else {
            marks = [:]
            return
        }
        marks = decoded
    }

    func mark(for id: String) -> Mark { marks[id] ?? Mark() }

    func isRead(_ id: String) -> Bool { marks[id]?.readAt != nil }

    func bookmark(for id: String) -> Bookmark? { marks[id]?.bookmark }

    /// Mark a report read, or take the mark back. Returns what the report now stands at.
    @discardableResult
    func setRead(_ id: String, _ read: Bool, at when: Date = Date()) -> Mark {
        update(id) { $0.readAt = read ? when : nil }
    }

    @discardableResult
    func setBookmark(_ bookmark: Bookmark?, for id: String) -> Mark {
        update(id) { $0.bookmark = bookmark }
    }

    /// Forget everything about a report that no longer exists.
    ///
    /// Called when one is deleted. A mark left behind is not merely clutter: report ids are
    /// UUIDs on this device but row ids in a vault, and a vault that reissues one would hand
    /// the new report somebody else's bookmark.
    func forget(_ id: String) {
        guard marks.removeValue(forKey: id) != nil else { return }
        write()
    }

    @discardableResult
    private func update(_ id: String, _ change: (inout Mark) -> Void) -> Mark {
        var mark = marks[id] ?? Mark()
        change(&mark)
        // An empty mark is an absent one. Keeping `{readAt: null, bookmark: null}` on disk would
        // grow the file by one entry for every report ever opened and marked back.
        if mark.isEmpty {
            marks.removeValue(forKey: id)
        } else {
            marks[id] = mark
        }
        write()
        return mark
    }

    private func write() {
        guard let data = try? JSONEncoder.nodusReports.encode(marks) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

// MARK: - The bookmark, while a report is on screen

/// The reading bookmark of the report currently open: what it is, and what pressing on it does.
///
/// One per reader and handed down the environment, exactly like `PageSearch` — a report and a
/// dossier pushed on top of it are two pages, and only one of them has a bookmark. Everything
/// that draws prose reads it as an *optional*, so a screen that never provides one shows no
/// bookmark affordance at all rather than an inert one.
@Observable
@MainActor
final class ReadingBookmarks {
    private(set) var bookmark: ReportMarks.Bookmark?

    /// Bumped every time the reader asks for the mark to be brought into view, so asking twice
    /// is two requests. The same nonce trick `PageSearch.Target` uses, and for the same reason:
    /// a paragraph that is already showing the mark must still be told to aim again.
    private(set) var aim = 0

    /// Where the change is written. Held rather than performed here because this object knows
    /// about one page and `ReportMarks` knows about a space.
    private let persist: (ReportMarks.Bookmark?) -> Void

    init(bookmark: ReportMarks.Bookmark?, persist: @escaping (ReportMarks.Bookmark?) -> Void) {
        self.bookmark = bookmark
        self.persist = persist
    }

    /// The mark a given block has to draw, if any, and whether it is being aimed at.
    ///
    /// The `aim` is carried only by the block that holds the mark, so asking the page to go back
    /// to it repaints one paragraph rather than every paragraph on the screen.
    struct Placement: Equatable {
        let range: NSRange
        let aim: Int
    }

    func placement(for path: [Int]) -> Placement? {
        guard let bookmark, bookmark.path == path else { return nil }
        return Placement(range: bookmark.range, aim: aim)
    }

    /// Replace whatever was marked with this. There is only ever one.
    func set(path: [Int], range: NSRange, snippet: String) {
        let next = ReportMarks.Bookmark(
            path: path,
            location: range.location,
            length: range.length,
            snippet: Self.trimmed(snippet),
            markedAt: Date()
        )
        bookmark = next
        persist(next)
    }

    func clear() {
        guard bookmark != nil else { return }
        bookmark = nil
        persist(nil)
    }

    /// Ask the page to bring the mark back into view.
    func aimAtBookmark() {
        guard bookmark != nil else { return }
        aim += 1
    }

    /// Correct a mark whose paragraph has been rewritten under it.
    ///
    /// Reports are repaired in place the first time they are opened — the citations that were
    /// raw ids become their sources' names — and that moves every character after the first
    /// citation in the paragraph. The words are searched for again in the text the block now
    /// shows; when they are still there the offsets are updated, and when they are not the mark
    /// is left exactly where it was rather than guessing. Guessing is the one outcome worth
    /// avoiding: a bookmark that opens the wrong sentence is worse than one that opens a
    /// slightly wrong position in the right one.
    func reconcile(path: [Int], displayed: String) {
        guard let bookmark, bookmark.path == path, !bookmark.snippet.isEmpty else { return }
        let text = displayed as NSString
        let current = bookmark.range
        if current.location + current.length <= text.length,
           text.substring(with: current) == bookmark.snippet {
            return
        }
        let found = text.range(of: bookmark.snippet)
        guard found.location != NSNotFound else { return }
        let moved = ReportMarks.Bookmark(
            path: path,
            location: found.location,
            length: found.length,
            snippet: bookmark.snippet,
            markedAt: bookmark.markedAt
        )
        self.bookmark = moved
        persist(moved)
    }

    /// What the mark is shown as when the words themselves are not on screen. Long selections
    /// are cut rather than wrapped: this is a label on a control, not the passage itself.
    static func label(_ snippet: String, limit: Int = 90) -> String {
        let text = trimmed(snippet)
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    /// Selections arrive with whatever whitespace the finger caught. Newlines in particular
    /// would otherwise make the mark impossible to find again in a single-line paragraph.
    private static func trimmed(_ snippet: String) -> String {
        snippet
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
