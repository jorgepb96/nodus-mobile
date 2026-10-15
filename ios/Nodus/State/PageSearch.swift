import Foundation
import Observation
import SwiftUI

/// Find-in-page: the words that are on this screen, and where the next one is.
///
/// A phone shows a twenty-page report through a five-inch window. The corpus has had a search
/// since the first build, but that one asks the vault a question; this one asks the page in
/// front of you, which is a different question and the only one worth asking while reading —
/// "where does it say that again?"
///
/// It works by registration rather than by scraping: every piece of prose on the page tells the
/// model the text it is *showing* — after the Markdown has been parsed and the citations have
/// been turned into their labels, because that is what the reader can see and therefore what
/// they will look for. Each registration carries a path, and the paths are what put the matches
/// in reading order without anybody measuring a frame: `[2, 3]` comes after `[2, 1]` and before
/// `[3]`, whatever the layout does with them.
///
/// One instance per page, held by `nodusPageFunctions` and handed down the environment, so two
/// screens on a navigation stack search themselves and not each other.
@MainActor
@Observable
final class PageSearch {
    // Releasing an inferred isolated deinit during a synchronous SwiftUI update
    // can hit Swift's TaskLocal StopLookupScope invalid-free on older runtimes
    // (swiftlang/swift#88036). Task cancellation is safe without actor hopping.
    nonisolated deinit { fading?.cancel() }

    /// Whether the find bar is on screen. Closing it clears the query, so coming back to search
    /// starts from nothing rather than from whatever was found an hour ago.
    private(set) var isOpen = false

    /// What is being looked for. Typing recomputes and jumps to the first match, the way a
    /// browser's find does — the alternative is typing a word and then pressing a second button
    /// to be shown where it is.
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            recompute(keepingActive: false)
        }
    }

    /// Every match on the page, in reading order.
    private(set) var matches: [Match] = []
    /// Which of them is the one being looked at.
    private(set) var activeIndex = 0
    /// Set every time the active match moves, including when it moves to the same block twice —
    /// the nonce is what makes the second "next" scroll at all.
    private(set) var scrollTarget: Target?
    /// Whether anything on this page registered text at all. Screens that are lists of rows
    /// never do, and they get no find button rather than one that can never find anything.
    private(set) var hasContent = false

    /// The matches of one block, so a paragraph can paint its own without walking the page's.
    private(set) var grouped: [Path: [NSRange]] = [:]

    /// A block being pointed at from somewhere else — an answer that cited it — marked for long
    /// enough to be found by eye and then let go of. Not a selection: nothing is being acted on,
    /// and a mark that stayed would have to be dismissed.
    private(set) var revealed: Path?
    /// Cancels the fade when a second reference is tapped before the first one has finished.
    @ObservationIgnored private var fading: Task<Void, Never>?

    /// Path → the text that block is showing. Deliberately not observed: it changes a hundred
    /// times while a report appears, and nothing in a view's body reads it.
    @ObservationIgnored private var entries: [Path: String] = [:]

    /// The blocks that bring their own matches into view. Not observed, for the same reason.
    @ObservationIgnored private var positioning: Set<Path> = []

    /// Where a piece of text sits in the page's reading order.
    ///
    /// A path rather than a number so a section can be numbered without knowing how many
    /// paragraphs the section before it turned out to have.
    typealias Path = [Int]

    struct Match: Hashable {
        let path: Path
        let location: Int
        let length: Int

        var range: NSRange { NSRange(location: location, length: length) }
    }

    /// The block to bring into view, and a nonce so asking twice is two requests.
    struct Target: Equatable {
        let path: Path
        let nonce: Int
    }

    /// What one block needs to draw: all of its matches, and which one is the active one.
    struct Highlights: Equatable {
        let ranges: [NSRange]
        let active: NSRange?
        /// The nonce of the request that made this block the active one, and nought when it is
        /// not. Carried so a block that positions its own matches is told to aim again when the
        /// reader presses "next" onto a match it is already showing — otherwise the second press
        /// changes nothing here and the page does not move.
        let aim: Int
    }

    // MARK: The bar

    func open() {
        isOpen = true
    }

    func close() {
        isOpen = false
        query = ""
    }

    // MARK: Registration

    /// What this block is showing, in the words the reader can see.
    ///
    /// `placesItsOwnMatches` is declared by prose that can put a *word* on the screen rather than
    /// a block — one paragraph of a document, which is a text view and knows its own layout.
    func register(_ path: Path, text: String, placesItsOwnMatches: Bool = false) {
        if placesItsOwnMatches { positioning.insert(path) }
        guard entries[path] != text else { return }
        entries[path] = text
        hasContent = true
        if !query.isEmpty { recompute(keepingActive: true) }
    }

    func unregister(_ path: Path) {
        positioning.remove(path)
        guard entries.removeValue(forKey: path) != nil else { return }
        hasContent = !entries.isEmpty
        if !query.isEmpty { recompute(keepingActive: true) }
    }

    // MARK: Being pointed at

    /// Everything the page is showing, numbered in reading order.
    ///
    /// This is what the report chat puts in front of the model: the text a reader can see, in
    /// the order they see it, so an answer can point at a paragraph by number. Very short
    /// entries are left out — a two-word label is not a passage anybody cites.
    func passages(minimumLength: Int = 24) -> [(path: Path, text: String)] {
        entries.keys
            .sorted(by: Self.precedes)
            .compactMap { path in
                guard let text = entries[path], text.count >= minimumLength else { return nil }
                return (path, text)
            }
    }

    /// Bring a block into view and mark it for a moment.
    func reveal(_ path: Path, for seconds: Double = 2.4) {
        guard entries[path] != nil else { return }
        scrollTarget = Target(path: path, nonce: (scrollTarget?.nonce ?? 0) + 1)
        revealed = path
        fading?.cancel()
        fading = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.revealed = nil
        }
    }

    // MARK: Walking the matches

    var activeMatch: Match? {
        guard matches.indices.contains(activeIndex) else { return nil }
        return matches[activeIndex]
    }

    /// The next one down, wrapping round at the end. Wrapping rather than stopping because the
    /// count beside the buttons already says where you are, and a button that stops working at
    /// match twelve of twelve reads as broken.
    func next() {
        guard !matches.isEmpty else { return }
        activeIndex = (activeIndex + 1) % matches.count
        aim()
    }

    func previous() {
        guard !matches.isEmpty else { return }
        activeIndex = (activeIndex + matches.count - 1) % matches.count
        aim()
    }

    /// What this block should paint, or nothing when it holds no match.
    func highlights(for path: Path) -> Highlights? {
        guard let ranges = grouped[path], !ranges.isEmpty else { return nil }
        let active = activeMatch
        let holdsActive = active?.path == path
        return Highlights(
            ranges: ranges,
            active: holdsActive ? active?.range : nil,
            // Only the block being aimed at carries the nonce, so pressing "next" repaints one
            // paragraph rather than every paragraph that happens to contain the word.
            aim: holdsActive ? scrollTarget?.nonce ?? 0 : 0
        )
    }

    /// Whether the block at `path` brings its own match into view.
    ///
    /// A paragraph of a document is one `UITextView`, and it is the only thing on the page that
    /// knows where inside itself a word sits. Where it says so, the page must not also scroll to
    /// the paragraph as a whole: a paragraph taller than the screen has no single right position,
    /// and two matches inside one paragraph are the same position, which is why walking onto the
    /// second one used to move nothing at all.
    ///
    /// Only while there is something found in it. Being pointed at by an answer — `reveal` — is a
    /// request to show the paragraph, not a word inside it, and that one the page still serves.
    func placesItsOwnMatches(_ path: Path) -> Bool {
        positioning.contains(path) && grouped[path] != nil
    }

    // MARK: Finding

    private func recompute(keepingActive: Bool) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            matches = []
            grouped = [:]
            activeIndex = 0
            return
        }

        var found: [Match] = []
        var byPath: [Path: [NSRange]] = [:]
        for path in entries.keys.sorted(by: Self.precedes) {
            guard let text = entries[path] else { continue }
            let ranges = Self.ranges(of: needle, in: text)
            guard !ranges.isEmpty else { continue }
            byPath[path] = ranges
            found.append(contentsOf: ranges.map { Match(path: path, location: $0.location, length: $0.length) })
        }

        matches = found
        grouped = byPath
        if keepingActive {
            activeIndex = min(activeIndex, max(0, found.count - 1))
        } else {
            activeIndex = 0
            // Typing lands on the first match rather than waiting to be told to.
            aim()
        }
    }

    private func aim() {
        guard let match = activeMatch else { return }
        scrollTarget = Target(path: match.path, nonce: (scrollTarget?.nonce ?? 0) + 1)
    }

    /// Case- and accent-blind, because a reader looking for "análisis" types "analisis" as often
    /// as not, and a phone keyboard makes the accent the harder of the two to reach.
    nonisolated static func ranges(of needle: String, in text: String) -> [NSRange] {
        let haystack = text as NSString
        var found: [NSRange] = []
        var start = 0
        while start < haystack.length {
            let remaining = NSRange(location: start, length: haystack.length - start)
            let hit = haystack.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: remaining
            )
            guard hit.location != NSNotFound, hit.length > 0 else { break }
            found.append(hit)
            start = hit.location + hit.length
        }
        return found
    }

    /// Reading order: the same rule a table of contents uses, one number at a time.
    nonisolated static func precedes(_ lhs: Path, _ rhs: Path) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right {
            return left < right
        }
        return lhs.count < rhs.count
    }
}

// MARK: - Where a view sits on the page

/// The scroll anchor of one registered block, so the find bar can bring it into view.
struct PageSearchAnchor: Hashable {
    let path: PageSearch.Path
}

private struct PageSearchPathKey: EnvironmentKey {
    static let defaultValue: PageSearch.Path = []
}

extension EnvironmentValues {
    var nodusSearchPath: PageSearch.Path {
        get { self[PageSearchPathKey.self] }
        set { self[PageSearchPathKey.self] = newValue }
    }
}

extension View {
    /// Places this subtree at `index` among its siblings, for find-in-page.
    ///
    /// Nesting composes: a section marked `2` whose third paragraph marks itself `3` is `[2, 3]`,
    /// and every screen that never calls this is simply not searchable, which is the right
    /// answer for a list of rows.
    func nodusSearchOrder(_ index: Int) -> some View {
        transformEnvironment(\.nodusSearchPath) { $0.append(index) }
    }
}
