import NodusKit
import NodusUI
import SwiftUI

/// A citation pointing into the corpus: `nodus://idea/g-8969`.
///
/// The desktop writes these into every piece of generated prose — immersion stations, Deep
/// Research reports, the assistant's answers — and treats them as doors. On the phone they were
/// stripped to their label, so the one thing the reader most wants to do with a citation, which
/// is see what it rests on, was the one thing they could not do.
struct CorpusReference: Identifiable, Hashable {
    /// `idea`, `work`, `passage`, `theme`, `gap` — whatever the scheme carried.
    let kind: String
    /// The record's own identifier: a `global_id`, a `nodus_id`, a `passage_id`.
    let recordId: String

    var id: String { "\(kind)/\(recordId)" }

    init(kind: String, recordId: String) {
        self.kind = Self.canonical(kind)
        self.recordId = recordId
    }

    /// One name per kind, whichever the caller had.
    ///
    /// The citation scheme is singular (`nodus://work/…`) and the lexical search names its
    /// tables (`works/…`). Both reach here, and reading them as two different kinds is how a
    /// search result opened "this citation points outside the corpus" for a work the space
    /// very much publishes.
    private static func canonical(_ raw: String) -> String {
        switch raw.lowercased() {
        case "works": return "work"
        case "ideas": return "idea"
        case "themes": return "theme"
        case "gaps": return "gap"
        case "passages": return "passage"
        case "notes": return "note"
        case "authors": return "author"
        case "persons", "people": return "person"
        case "places": return "place"
        case "events": return "event"
        case let other: return other
        }
    }

    /// A search hit's id is already `kind/id` — the same shape the citation scheme uses.
    init?(hitId: String) {
        let parts = hitId.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        self.init(kind: String(parts[0]), recordId: String(parts[1]))
    }

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "nodus" else { return nil }
        // `nodus://idea/g-8969` parses as host = "idea", path = "/g-8969". A vault-scoped form
        // like `nodus://world/character/prs_7` puts the kind in the first path component, so
        // both shapes are read the same way: everything after the scheme, split on "/".
        let parts = ([url.host] + url.pathComponents)
            .compactMap { $0 }
            .filter { $0 != "/" && !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        let tail = parts.dropFirst().joined(separator: "/")
        self.init(kind: parts[0], recordId: tail.removingPercentEncoding ?? tail)
    }

    /// The collection that can serve it, when there is one.
    var collection: CollectionDescriptor? {
        switch kind {
        case "idea": return Collections["ideas"]
        case "work": return Collections["works"]
        case "passage": return Collections["passages"]
        case "theme": return Collections["themes"]
        case "gap": return Collections["gaps"]
        case "author": return Collections["authors"]
        case "person": return Collections["persons"]
        case "place": return Collections["places"]
        case "event": return Collections["events"]
        default: return nil
        }
    }
}

/// Opens whatever a citation points at.
///
/// Ideas and works have enriched handlers on the server, so they go through the same screens the
/// library reaches; everything else is fetched as a row and rendered by the generic detail view.
/// A kind this build does not know about says so rather than showing an empty page.
struct CorpusReferenceView: View {
    let session: SpaceSession
    let reference: CorpusReference

    var body: some View {
        Group {
            switch reference.kind {
            case "idea":
                IdeaByIdView(session: session, globalId: reference.recordId)
            case "work":
                WorkByIdView(session: session, nodusId: reference.recordId)
            case "note":
                NoteByIdView(session: session, noteId: reference.recordId)
            case "passage":
                PassageByIdView(session: session, id: reference.recordId)
            default:
                if let collection = reference.collection {
                    RowByIdView(session: session, collection: collection, id: reference.recordId)
                } else {
                    ContentUnavailableView(
                        "This citation points outside the corpus",
                        systemImage: "questionmark.circle",
                        description: Text("It refers to a “\(reference.kind)”, which this space does not publish.")
                    )
                }
            }
        }
        // The detail screens carry their own; this covers the loading and the dead end, which
        // otherwise sat on the navigation container's black.
        .nodusPageBackdrop(accent: session.accent)
    }
}

/// A note, which is a resource rather than a collection and so has its own route.
struct NoteByIdView: View {
    let session: SpaceSession
    let noteId: String

    @State private var row: Row?
    @State private var failed = false

    var body: some View {
        Group {
            if let row {
                RowDetailView(session: session, collection: nil, row: row, title: "Notes")
            } else if failed {
                ContentUnavailableView("Could not open", systemImage: "questionmark.circle")
            } else {
                ProgressView().tint(session.accent)
            }
        }
        .task {
            guard row == nil, !failed else { return }
            do { row = try await session.client.note(noteId, in: session.connection.spaceId) }
            catch { failed = true }
        }
    }
}

/// Any collection row, fetched by its id alone.
struct RowByIdView: View {
    let session: SpaceSession
    let collection: CollectionDescriptor
    let id: String

    @State private var row: Row?
    @State private var failed = false

    var body: some View {
        Group {
            if let row {
                RowDetailView(session: session, collection: collection, row: row)
            } else if failed {
                ContentUnavailableView("Could not open", systemImage: "questionmark.circle")
            } else {
                ProgressView().tint(session.accent)
            }
        }
        .task {
            guard row == nil, !failed else { return }
            do { row = try await session.client.item(collection, id: id, in: session.connection.spaceId) }
            catch { failed = true }
        }
    }
}

/// Opens a passage, knowing that the id it was handed might not be one.
///
/// The lexical endpoint identifies every hit with `row.id ?? row.nodus_id ?? row.global_id ??
/// row.passage_id` (`server/lib/core/search.mjs:42`). A passage row has no `id` and does have a
/// `nodus_id`, so a passage found by spelling arrives carrying the id of the *work* it was cut
/// from — and asking the corpus for a passage by that id is a 404 that reads like a broken link
/// rather than like a mismatched vocabulary.
///
/// So: ask for the passage; when the corpus says there is no such passage, ask for the work.
/// One of the two is always the right record, and the day the server sends passage ids here
/// this keeps working without being touched.
struct PassageByIdView: View {
    let session: SpaceSession
    let id: String

    @State private var row: Row?
    @State private var asWork: String?
    @State private var failed = false

    var body: some View {
        Group {
            if let row {
                RowDetailView(session: session, collection: Collections["passages"], row: row)
            } else if let asWork {
                WorkByIdView(session: session, nodusId: asWork)
            } else if failed {
                ContentUnavailableView("Could not open", systemImage: "questionmark.circle")
            } else {
                ProgressView().tint(session.accent)
            }
        }
        .task {
            guard row == nil, asWork == nil, !failed else { return }
            guard let passages = Collections["passages"] else { failed = true; return }
            do {
                row = try await session.client.item(passages, id: id, in: session.connection.spaceId)
            } catch let error as APIError where error.isNotFound {
                asWork = id
            } catch {
                failed = true
            }
        }
    }
}

// MARK: - Prose with corpus citations

/// Prose the way the desktop writes it: Markdown with `nodus://` citations in it.
///
/// Rendered as an `AttributedString` so a citation reads as a citation — its label, in the
/// accent — rather than as a URL in the middle of a sentence. Tapping one opens what it points
/// at, which is what the desktop does and what makes a cited report worth reading on a phone.
struct CorpusProse: View {
    private let text: String
    private let accent: Color
    private let session: SpaceSession?
    /// Token → label, for prose that cites with bare tokens instead of Markdown links. A report
    /// written on this device does exactly that: the model is told to copy the token, and the
    /// catalogue is the only place its label lives.
    private let labels: [String: String]
    /// A tap on a numbered reference — `[3]` — in an answer about a page. Only the report chat
    /// passes one; everywhere else a bracketed number is a bracketed number.
    private let onReference: ((Int) -> Void)?

    @State private var opened: CorpusReference?
    @Environment(\.nodusReadingStyle) private var reading
    /// The page's find bar, when there is one. Prose is the thing a reader searches, so this is
    /// where the words of a page are declared — after the Markdown and the citations have been
    /// resolved, because what is registered has to be what is on the screen.
    @Environment(PageSearch.self) private var search: PageSearch?
    @Environment(\.nodusSearchPath) private var searchPath

    init(
        _ text: String,
        accent: Color,
        session: SpaceSession? = nil,
        labels: [String: String] = [:],
        onReference: ((Int) -> Void)? = nil
    ) {
        self.text = text
        self.accent = accent
        self.session = session
        self.labels = labels
        self.onReference = onReference
    }

    /// One paragraph or heading. Identified by its position rather than by a fresh `UUID`: the
    /// list is recomputed on every pass of the body, and an identity that changes with it throws
    /// away every `UITextView` on the page — and, now, the anchor the find bar scrolls to.
    private struct Block: Identifiable {
        let id: Int
        let level: Int
        let text: String
    }

    var body: some View {
        // A document breathes; a chat bubble does not. Twenty points between paragraphs rather
        // than thirteen: on a phone the gap between paragraphs is the only cue a reader has that
        // one has ended, because the line lengths are too short for the last line's rag to say
        // it, and the leading inside a paragraph has gone up too.
        VStack(alignment: .leading, spacing: reading.document ? 20 : 9) {
            ForEach(blocks) { block in
                let path = searchPath + [block.id]
                Group {
                    if block.level > 0 {
                        heading(block, path: path)
                    } else if reading.document {
                        DocumentProse(
                            source: Self.linkify(block.text, labels: labels),
                            font: reading.uiFont(.callout),
                            accent: accent,
                            justified: true,
                            linksLive: session != nil,
                            referencesLive: onReference != nil,
                            highlights: search?.highlights(for: path),
                            onOpen: { url in
                                if let number = PageChatReference.number(in: url) {
                                    onReference?(number)
                                    return true
                                }
                                guard let reference = CorpusReference(url) else { return false }
                                opened = reference
                                return true
                            }
                        )
                    } else {
                        Text(attributed(block.text, path: path))
                            .font(reading.font(.callout))
                            .textSelection(.enabled)
                    }
                }
                .nodusRevealed(search?.revealed == path)
                .id(PageSearchAnchor(path: path))
                // A paragraph of a document is a text view, and only it knows where inside
                // itself a word sits. A heading is one line and the page can place it.
                .onAppear { search?.register(path, text: displayed(block), placesItsOwnMatches: placesItsOwnMatches(block)) }
                .onChange(of: block.text) { _, _ in
                    search?.register(path, text: displayed(block), placesItsOwnMatches: placesItsOwnMatches(block))
                }
                .onDisappear { search?.unregister(path) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The link is handled here rather than by the system: `nodus://` has no handler, so
        // letting it through opens nothing at all.
        .environment(\.openURL, OpenURLAction { url in
            if let number = PageChatReference.number(in: url) {
                onReference?(number)
                return .handled
            }
            guard session != nil, let reference = CorpusReference(url) else { return .systemAction }
            opened = reference
            return .handled
        })
        .nodusSheet(item: $opened) { reference in
            if let session {
                NavigationStack {
                    CorpusReferenceView(session: session, reference: reference)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { opened = nil }
                            }
                        }
                }
            }
        }
    }

    /// Whether this block is one of the `DocumentProse` paragraphs, which position their own
    /// matches. The same condition the body branches on, so the two cannot drift.
    private func placesItsOwnMatches(_ block: Block) -> Bool {
        block.level == 0 && reading.document
    }

    /// A heading, set as the document it belongs to would set one.
    ///
    /// In a report a first-level heading is a part title, and it was `.headline` — one step
    /// above the body and indistinguishable from it three paragraphs later. Uppercase, bold,
    /// two sizes up and with room above it, a reader can find where a section starts by
    /// scrolling past rather than by reading.
    private func heading(_ block: Block, path: PageSearch.Path) -> some View {
        // `##`, not just `#`. A Deep Research document opens at level two — the title is the
        // report's own, so its sections are `##` — and keying the part style to level one meant
        // every heading in every published report was set as a minor one. Seen against the
        // demo corpus: "Introduction" and "What the registers omit" arrived at body weight,
        // indistinguishable from the paragraph under them.
        let isPart = block.level <= 2 && reading.document
        let shown = displayed(block)
        var attributed = AttributedString(shown)
        if let highlights = search?.highlights(for: path) {
            attributed.nodusHighlight(highlights, in: shown)
        }
        return Text(attributed)
            .font(reading.font(isPart ? .title3 : .headline, weight: .bold))
            .tracking(isPart ? 0.7 : 0)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A heading belongs to what comes after it, so the space above it is what tells a
            // reader that the previous section has ended. Eight points more than the paragraph
            // gap below it is the least that reads as a break rather than as a wide line.
            .padding(.top, reading.document ? (isPart ? 20 : 10) : 3)
    }

    /// Split into headings and paragraphs before parsing.
    ///
    /// `AttributedString(markdown:)` in inline mode leaves `###` sitting in the text, and its
    /// full mode carries a heading as a presentation intent that `Text` then ignores — so
    /// either way a heading arrives as literal hashes in the middle of the prose. Splitting
    /// first is what makes a heading look like one.
    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []

        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { result.append(Block(id: result.count, level: 0, text: joined)) }
            paragraph = []
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                let heading = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty {
                    flush()
                    result.append(Block(id: result.count, level: min(hashes, 3), text: heading))
                    continue
                }
            }
            paragraph.append(line)
        }
        flush()
        return result
    }

    /// What this block puts on the screen, in plain characters.
    ///
    /// Not the Markdown: a reader looking for "registers" is looking for the word they can see,
    /// and the source they cannot see spells it `**registers**` and spells a citation
    /// `[Arco Blanco (2020)](nodus://idea/g-8969)`. Searching the source would miss the first
    /// and match the second on a URL nobody was shown.
    private func displayed(_ block: Block) -> String {
        guard block.level == 0 else {
            let isPart = block.level <= 2 && reading.document
            return isPart ? block.text.uppercased() : block.text
        }
        guard let parsed = try? AttributedString(
            markdown: Self.linkify(block.text, labels: labels),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return block.text
        }
        return String(parsed.characters)
    }

    private func attributed(_ source: String, path: PageSearch.Path) -> AttributedString {
        guard var parsed = try? AttributedString(
            markdown: Self.linkify(source, labels: labels),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return AttributedString(source)
        }
        for run in parsed.runs where run.link != nil {
            // Kept live when there is somewhere for it to go, and struck back to plain accent
            // text when there is not: a link that looks live and goes nowhere is worse than one
            // that never claimed to. A citation needs a session to open a record against; a
            // numbered reference points at this very page and needs only a handler.
            let isReference = run.link.map { PageChatReference.number(in: $0) != nil } ?? false
            let live = isReference ? onReference != nil : session != nil
            if !live { parsed[run.range].link = nil }
            parsed[run.range].foregroundColor = accent
            parsed[run.range].font = reading.font(.callout, weight: .medium)
            parsed[run.range].underlineStyle = live ? .single : nil
        }
        if let highlights = search?.highlights(for: path) {
            parsed.nodusHighlight(highlights, in: String(parsed.characters))
        }
        return parsed
    }

    /// Whether this app opens the URL itself rather than handing it to the system.
    ///
    /// The two kinds of link the prose makes live: a citation into the corpus, and a numbered
    /// reference pointing back at the page it is drawn on. Everything else — an ordinary web
    /// address in the middle of a paragraph — belongs to whatever the system does with it.
    ///
    /// A predicate rather than a return value from the opening itself, because the one place
    /// that has to answer it, `primaryActionFor`, is asked before anybody has decided to open
    /// anything.
    static func claims(_ url: URL) -> Bool {
        PageChatReference.number(in: url) != nil || CorpusReference(url) != nil
    }

    /// Turns bare `nodus://…` tokens into Markdown links so they are tappable.
    ///
    /// The desktop writes `[Arco Blanco (2020)](nodus://idea/g-8969)` and needs nothing here.
    /// A report generated on the phone writes the bare token in parentheses, because that is
    /// what the citation policy asks the model for — so the token is swapped for its catalogue
    /// label, and a token with no label keeps its own text rather than disappearing.
    static func linkify(_ source: String, labels: [String: String]) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<!\]\()\bnodus://[a-z_]+/[^\s)\]（）]+"#,
            options: [.caseInsensitive]
        ) else { return source }

        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var output = source
        for match in regex.matches(in: source, range: range).reversed() {
            guard let tokenRange = Range(match.range, in: source),
                  let replaceRange = Range(match.range, in: output)
            else { continue }
            let token = String(source[tokenRange])
            let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            let label = labels[trimmed] ?? trimmed
                .replacingOccurrences(of: "nodus://", with: "")
            // Brackets inside a label would close the Markdown link early.
            let safe = label.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            output.replaceSubrange(replaceRange, with: "[\(safe)](\(trimmed))")
        }
        return output
    }
}

extension UIView {
    /// The scroll view this view is inside, when it is inside one.
    ///
    /// Only ever asked once the view is on the screen. Asking from `updateUIView` answers nothing:
    /// SwiftUI updates a representable before it puts it in the hierarchy, so the walk runs out of
    /// superviews — which is what makes anything hung off the scroll view from there silently do
    /// nothing at all.
    var enclosingScrollView: UIScrollView? {
        var candidate = superview
        while let current = candidate {
            if let scrollView = current as? UIScrollView { return scrollView }
            candidate = current.superview
        }
        return nil
    }
}

/// One paragraph of a document.
///
/// A `UITextView` rather than a `Text` — non-editable, non-scrolling, sized by SwiftUI — because
/// leading is a paragraph-style attribute and `Text` drops paragraph styles on the way in.
/// SwiftUI's `lineSpacing` adds points between lines without telling the layout what the line
/// height *is*, which is not the same thing and does not scale with the reader's text size.
/// Everything `Text` was doing is done here explicitly instead of hoped for:
///
/// - The Markdown is parsed once and each run is given a real `UIFont`, because the inline
///   presentation intents an `AttributedString` carries mean nothing to UIKit: converting one
///   directly loses every bold and italic in the report.
/// - A `nodus://` link is coloured, underlined and handed back to the caller on tap. The system
///   has no handler for that scheme, so letting the default action run opens nothing.
/// - A document is set justified at a line height of 1.3, which is what a report asked to look
///   like a report wants: both margins straight, the way the desktop sets the same prose and the
///   way the PDF it exports comes out. Hyphenation stays off — it was tried, and breaking a word
///   on most lines of a twenty-page report costs more than the white it saves — so a narrow
///   measure pays for its straight right edge in word spacing rather than in broken words.
/// - The find bar's highlights are painted on top rather than parsed in: the Markdown is the
///   expensive half and it does not change while somebody types in the search field.
private struct DocumentProse: UIViewRepresentable {
    /// Markdown, already linkified.
    let source: String
    let font: UIFont
    let accent: Color
    /// Both margins straight. Set for a document; a chat bubble is never justified.
    let justified: Bool
    /// Whether a `nodus://` citation has a session to be opened against.
    let linksLive: Bool
    /// Whether a `nodusref://` number has a handler to be given back to. Separate, because a
    /// reference points at the page it is drawn on and needs no corpus at all.
    var referencesLive = false
    /// What the page's search wants painted on this paragraph, if anything.
    let highlights: PageSearch.Highlights?
    let onOpen: (URL) -> Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isScrollEnabled = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.adjustsFontForContentSizeCategory = false
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onOpen = onOpen
        context.coordinator.linksLive = linksLive

        // Parsing the Markdown and building the runs is the expensive part, and SwiftUI calls
        // this for any change anywhere in the tree — a scroll, a sheet, the size control being
        // pressed on a *different* section. Only the five inputs below can change what the
        // paragraph *says*, so anything else costs one comparison instead of a reparse.
        let identity = Identity(
            source: source,
            size: font.pointSize,
            accent: accent,
            justified: justified,
            linksLive: linksLive,
            referencesLive: referencesLive
        )
        let rebuilt = context.coordinator.identity != identity
        if rebuilt {
            context.coordinator.identity = identity
            context.coordinator.base = attributed()
        }
        // Typing in the find bar changes every paragraph on the page, so the one thing it must
        // not do is reparse them: the highlights go on a copy of what was already built.
        guard rebuilt || context.coordinator.painted != highlights else { return }
        context.coordinator.painted = highlights
        view.attributedText = painted(context.coordinator.base)

        // The word, not the paragraph. Deferred by a turn of the run loop because the frame this
        // measurement is against is the one SwiftUI is still deciding: `updateUIView` runs before
        // the layout that gives the paragraph its height, and a rect converted through a stale
        // frame lands somewhere else on the page.
        if let highlights, let active = highlights.active, highlights.aim != context.coordinator.aimed {
            context.coordinator.aimed = highlights.aim
            DispatchQueue.main.async { Self.bringIntoView(active, of: view) }
        }
    }

    /// Puts one match in the middle of the screen.
    ///
    /// A paragraph of a report is a single text view, and the page around it can only scroll to
    /// the paragraph as a whole — which for a paragraph taller than the screen says nothing about
    /// where the word is, and for two matches in the same paragraph says the same thing twice.
    /// The text view is the one object that knows where a character sits, so it is the one that
    /// answers.
    private static func bringIntoView(_ range: NSRange, of view: UITextView) {
        guard
            let scrollView = view.enclosingScrollView,
            let start = view.position(from: view.beginningOfDocument, offset: range.location),
            let end = view.position(from: start, offset: range.length),
            let textRange = view.textRange(from: start, to: end)
        else { return }
        let rect = view.firstRect(for: textRange)
        guard !rect.isNull, !rect.isInfinite else { return }

        // A scroll view lays its subviews out in content coordinates, so this is already the
        // position on the page rather than on the screen.
        let onPage = view.convert(rect, to: scrollView).midY
        let inset = scrollView.adjustedContentInset
        let visible = scrollView.bounds.height - inset.top - inset.bottom
        let wanted = onPage - inset.top - visible / 2

        // The ends of a document cannot be centred, and asking for it would leave the page
        // hanging in its rubber band.
        let lowest = -inset.top
        let highest = max(lowest, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
        let offset = CGPoint(x: scrollView.contentOffset.x, y: min(max(wanted, lowest), highest))
        guard abs(offset.y - scrollView.contentOffset.y) > 0.5 else { return }
        scrollView.setContentOffset(offset, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    struct Identity: Equatable {
        let source: String
        let size: CGFloat
        let accent: Color
        let justified: Bool
        let linksLive: Bool
        let referencesLive: Bool
    }

    /// The paragraph with the search's marks on it, or exactly what was built when there are none.
    private func painted(_ base: NSAttributedString) -> NSAttributedString {
        guard let highlights, !highlights.ranges.isEmpty else { return base }
        let output = NSMutableAttributedString(attributedString: base)
        let whole = NSRange(location: 0, length: output.length)
        for range in highlights.ranges {
            guard let clamped = range.intersection(whole), clamped.length > 0 else { continue }
            let colour = range == highlights.active ? Color.nodusFindActive : Color.nodusFindMatch
            output.addAttribute(.backgroundColor, value: UIColor(colour), range: clamped)
        }
        return output
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        // A `UITextView` has no useful intrinsic width, so the proposal decides it and the
        // height is measured against it. Without this the paragraph collapses to one line.
        guard let width = proposal.width, width > 0, width < .infinity else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(onOpen: onOpen, linksLive: linksLive) }

    private func attributed() -> NSAttributedString {
        let parsed = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)

        let output = NSMutableAttributedString()
        for run in parsed.runs {
            var runFont = font
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    runFont = .monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular)
                } else {
                    var traits: UIFontDescriptor.SymbolicTraits = []
                    if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                    if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                    if !traits.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                        runFont = UIFont(descriptor: descriptor, size: font.pointSize)
                    }
                }
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: runFont,
                .foregroundColor: UIColor.label,
            ]
            if let link = run.link {
                attributes[.foregroundColor] = UIColor(accent)
                // A link that looks live and goes nowhere is worse than one that never
                // claimed to, which is the same rule the SwiftUI path follows — and the same
                // split between a citation, which needs a session, and a numbered reference,
                // which needs only somebody listening.
                let live = PageChatReference.number(in: link) != nil ? referencesLive : linksLive
                if live {
                    attributes[.link] = link
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }

        let paragraph = NSMutableParagraphStyle()
        // Justified for a document, `.natural` for everything else. `.natural` is the one that
        // is right for Arabic and Hebrew as well as for Spanish; `.justified` straightens both
        // margins in all of them, which is what a report is asked to look like and what the
        // same prose looks like on the desktop and in the PDF it exports.
        paragraph.alignment = justified ? .justified : .natural
        paragraph.lineBreakMode = .byWordWrapping
        // Still nought. Justification on a phone's measure pays in word spacing, and that is
        // the cheaper of the two prices: hyphenation here broke a word on most lines.
        paragraph.hyphenationFactor = 0
        paragraph.lineHeightMultiple = 1.3
        output.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: output.length))
        return output
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onOpen: (URL) -> Bool
        var linksLive: Bool
        /// What the text view was last built from, so an unrelated update costs nothing.
        var identity: Identity?
        /// The parsed paragraph, before the search painted anything on it.
        var base = NSAttributedString()
        /// The marks currently on screen, so a keystroke that changes nothing here changes
        /// nothing here.
        var painted: PageSearch.Highlights?
        /// The last request this paragraph brought a match into view for.
        var aimed = 0

        init(onOpen: @escaping (URL) -> Bool, linksLive: Bool) {
            self.onOpen = onOpen
            self.linksLive = linksLive
        }

        /// What should happen if this citation is activated — which is not the same question as
        /// "has it been activated", and answering the second one here is what made a scroll that
        /// began on a citation open it.
        ///
        /// UIKit asks this the moment a finger lands on a text item, before it can possibly know
        /// whether that finger is tapping or about to drag the page away; it then runs the action
        /// it was handed only if the touch turns out to be a tap. So the opening goes *inside* the
        /// returned action rather than beside it, and a finger that came down on a citation and
        /// kept moving now scrolls the report, as it does everywhere else on the page.
        ///
        /// Measured rather than reasoned: with a probe in this method, the delegate call was
        /// logged before the scroll view's own recognizers had seen `touchesBegan` at all — which
        /// is also why nothing that watches the scroll (its `isDragging`, its `contentOffset`, a
        /// recognizer on it) can help. At the moment of the question there is nothing to observe.
        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            // A link this app has nothing to do with — an ordinary `https://` in the prose —
            // keeps the system's behaviour, and that decision is safe to take now because it
            // reads the URL and nothing else.
            guard case .link(let url) = textItem.content, CorpusProse.claims(url) else {
                return defaultAction
            }
            return UIAction(title: "") { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.onOpen(url) }
            }
        }

        /// No menu on a citation.
        ///
        /// The system's own is "Open / Copy / Share" over the raw `nodus://idea/g-8969`, which is
        /// an internal address: sharing it sends somebody a string that does nothing, and Open
        /// hands the scheme to a system that has no handler for it — so the first item of the
        /// menu is the one that cannot work. A citation does one thing, and a tap does it.
        ///
        /// Only reachable since the opening moved into the tap: before, the press opened the
        /// citation before the menu could be asked for.
        func textView(
            _ textView: UITextView,
            menuConfigurationFor textItem: UITextItem,
            defaultMenu: UIMenu
        ) -> UITextItem.MenuConfiguration? {
            guard case .link(let url) = textItem.content, CorpusProse.claims(url) else {
                return UITextItem.MenuConfiguration(menu: defaultMenu)
            }
            return nil
        }
    }
}
