import NodusKit
import NodusUI
import SwiftUI

/// UIKit recolours SF Symbols used by nested edit-menu actions as monochrome template images,
/// even when they arrive with a palette configuration. Flatten the swatch into an original-mode
/// bitmap first so every highlight colour survives the menu's own rendering pass.
enum ReaderHighlightMenuSwatch {
    static func image(for colour: ReaderAnnotationColor, selected: Bool) -> UIImage? {
        let side: CGFloat = 20
        guard let symbol = UIImage(
            systemName: selected ? "checkmark.circle.fill" : "circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: side, weight: .regular)
        )?.withTintColor(UIColor(colour.color), renderingMode: .alwaysOriginal)
        else { return nil }

        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            .image { _ in
                symbol.draw(in: CGRect(origin: .zero, size: CGSize(width: side, height: side)))
            }
            .withRenderingMode(.alwaysOriginal)
    }
}

/// A zero-delay press tracks a highlighter from the instant it touches the page. A pan gesture
/// waits for UIKit's movement threshold before it begins, by which time a left-to-right stroke
/// can already have crossed the first letter. Retaining the latest precise sample also gives
/// Apple Pencil the drawing-specific location Apple recommends instead of the generic gesture
/// centroid.
final class ReaderHighlightGestureRecognizer: UILongPressGestureRecognizer {
    private var latestPreciseLocation: CGPoint?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        minimumPressDuration = 0
        allowableMovement = .greatestFiniteMagnitude
        numberOfTouchesRequired = 1
        allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
        ]
        cancelsTouchesInView = true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        captureLatestSample(in: touches, event: event)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        captureLatestSample(in: touches, event: event)
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        captureLatestSample(in: touches, event: event)
        super.touchesEnded(touches, with: event)
    }

    func highlighterLocation(in target: UIView) -> CGPoint {
        guard let source = view, let latestPreciseLocation else { return location(in: target) }
        return source.convert(latestPreciseLocation, to: target)
    }

    private func captureLatestSample(in touches: Set<UITouch>, event: UIEvent) {
        guard let source = view, let touch = touches.first else { return }
        let latest = event.coalescedTouches(for: touch)?.last ?? touch
        latestPreciseLocation = latest.preciseLocation(in: source)
    }
}

/// Resolve UIKit's caret boundary to the character whose rendered box is under the tip.
/// `closestPosition(to:)` can name either side of a glyph. The tolerance around neighbouring
/// boxes must therefore be considered only after exact hits; otherwise the next glyph's expanded
/// box can overlap the touched glyph and move the beginning of a stroke forward by one character.
enum ReaderCharacterHitTesting {
    static func index(
        caretOffset: Int,
        textLength: Int,
        point: CGPoint,
        characterBoxes: [Int: CGRect],
        requiresGlyphHit: Bool
    ) -> Int? {
        guard textLength > 0 else { return nil }
        let candidates = [caretOffset - 1, caretOffset].filter { $0 >= 0 && $0 < textLength }

        if let exact = candidates.first(where: { characterBoxes[$0]?.contains(point) == true }) {
            return exact
        }

        let tolerant = candidates.compactMap { candidate -> (Int, CGFloat)? in
            guard let box = characterBoxes[candidate],
                  box.insetBy(dx: -2, dy: -2).contains(point)
            else { return nil }
            return (candidate, squaredDistance(from: point, to: box))
        }
        if let nearest = tolerant.min(by: { $0.1 < $1.1 }) {
            return nearest.0
        }

        if requiresGlyphHit { return nil }
        return min(max(0, caretOffset), textLength - 1)
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

/// A citation pointing into the corpus: `nodus://idea/g-8969`.
///
/// The desktop writes these into every piece of generated prose — immersion stations, Deep
/// Research reports, the assistant's answers — and treats them as doors. On the phone they were
/// stripped to their label, so the one thing the reader most wants to do with a citation, which
/// is see what it rests on, was the one thing they could not do.
struct CorpusReference: Identifiable, Hashable {
    enum Destination: Equatable {
        case idea
        case work
        case note
        case passage
        case debate
        case collection
        case privateSource
        case unsupported
    }

    /// `idea`, `work`, `passage`, `theme`, `gap` — whatever the scheme carried.
    let kind: String
    /// The record's own identifier: a `global_id`, a `nodus_id`, a `passage_id`.
    let recordId: String
    var specialised: SpecialisedCorpusReference? = nil
    var privateSource: PrivateCorpusReference? = nil

    var id: String { "\(kind)/\(recordId)" + (specialised.map { ":\($0.collectionPath):\($0.expectedParentId ?? "")" } ?? "") + (privateSource.map { ":\($0.kind.rawValue):\($0.timestamp ?? 0):\($0.transcriptId ?? "")" } ?? "") }

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
        case "contradictions", "debate", "debates": return "contradiction"
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
        if let target = PrivateCorpusReference(url) {
            kind = url.host?.lowercased() ?? ""; recordId = target.id; privateSource = target
            return
        }
        if let target = SpecialisedCorpusReference(url) {
            kind = url.host?.lowercased() ?? ""; recordId = target.recordId; specialised = target
            return
        }
        // `nodus://idea/g-8969` parses as host = "idea", path = "/g-8969". A vault-scoped form
        // like `nodus://world/character/prs_7` puts the kind in the first path component, so
        // both shapes are read the same way: everything after the scheme, split on "/".
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              let host = components.host, !host.isEmpty else { return nil }
        let encoded = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        let parts = encoded.compactMap { String($0).removingPercentEncoding }
        guard !parts.isEmpty, parts.count == encoded.count else { return nil }
        self.init(kind: host, recordId: parts.joined(separator: "/"))
    }

    /// The collection that can serve it, when there is one.
    var collection: CollectionDescriptor? {
        if let specialised { return Collections[specialised.collectionPath] }
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

    /// The reader that owns this reference kind.
    ///
    /// Contradictions are derived debates, not collection rows. Keeping that distinction here
    /// prevents a valid citation from falling through the collection lookup and being described
    /// as outside the corpus merely because no `contradictions` table exists.
    var destination: Destination {
        if privateSource != nil { return .privateSource }
        switch kind {
        case "idea": return .idea
        case "work": return .work
        case "note": return .note
        case "passage": return .passage
        case "contradiction": return .debate
        default: return collection == nil ? .unsupported : .collection
        }
    }
}

/// The colour carried by a reference label in prose.
///
/// Ideas and authors keep the vault accent readers already associate with citations. A gap and
/// a contradiction carry their own meaning, while every other reference remains on the familiar
/// accent until it has an explicit semantic colour of its own.
enum CorpusReferenceTone: Equatable {
    case accent
    case contradiction
    case gap

    init(_ url: URL) {
        switch CorpusReference(url)?.kind {
        case "contradiction": self = .contradiction
        case "gap": self = .gap
        default: self = .accent
        }
    }

    @MainActor
    func color(accent: Color) -> Color {
        switch self {
        case .accent:
            return accent.nodusReadable
        case .contradiction:
            return .nodusDanger
        case .gap:
            // A true brown rather than caution orange. `nodusSemantic` darkens it for the pale
            // reader and lightens it for the dark reader until it clears the text contrast bar.
            return .nodusSemantic("#92400e")
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
            switch reference.destination {
            case .idea:
                IdeaByIdView(session: session, globalId: reference.recordId)
            case .work:
                WorkByIdView(session: session, nodusId: reference.recordId)
            case .note:
                NoteByIdView(session: session, noteId: reference.recordId)
            case .passage:
                PassageByIdView(session: session, id: reference.recordId)
            case .debate:
                DebateByIdView(session: session, edgeId: reference.recordId)
            case .collection:
                if let collection = reference.collection {
                    RowByIdView(session: session, collection: collection, id: reference.recordId)
                        .sourceCitationTarget(reference.specialised)
                }
            case .privateSource:
                if let source = reference.privateSource {
                    if source.kind == .participant, session.connection.desktopPairingId == nil, let collection = Collections["persons"] {
                        RowByIdView(session: session, collection: collection, id: source.id)
                    } else { PrivateCorpusSourceView(session: session, reference: source) }
                }
            case .unsupported:
                ContentUnavailableView(
                    "This citation points outside the corpus",
                    systemImage: "questionmark.circle",
                    description: Text("It refers to a “\(reference.kind)”, which this space does not publish.")
                )
            }
        }
        // The detail screens carry their own; this covers the loading and the dead end, which
        // otherwise sat on the navigation container's black.
        .nodusPageBackdrop(accent: session.accent)
    }
}

/// Keep a failed link actionable and preserve its actual transport/domain error.
struct CorpusOpenFailure: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("Could not open", systemImage: "questionmark.circle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry", action: retry).frame(minHeight: 44)
        }
    }
}

/// A note, which is a resource rather than a collection and so has its own route.
struct NoteByIdView: View {
    let session: SpaceSession
    let noteId: String

    @State private var row: Row?
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let row {
                RowDetailView(session: session, collection: nil, row: row, title: "Notes")
            } else if let failure {
                CorpusOpenFailure(message: failure) { attempt += 1 }
            } else {
                ProgressView().tint(session.accent)
            }
        }
        .task(id: "\(noteId)|\(session.publishedRevision ?? "local")|\(attempt)") {
            guard row == nil else { return }
            failure = nil
            do {
                let loaded = try await session.client.note(noteId, in: session.connection.spaceId)
                try Task.checkCancellation(); row = loaded
            } catch where error.isCancellation {
            } catch { failure = error.localizedDescription }
        }
    }
}

/// Any collection row, fetched by its id alone.
struct RowByIdView: View {
    let session: SpaceSession
    let collection: CollectionDescriptor
    let id: String
    var sourceReference: SpecialisedCorpusReference? = nil

    func sourceCitationTarget(_ value: SpecialisedCorpusReference?) -> RowByIdView {
        var copy = self; copy.sourceReference = value; return copy
    }

    @State private var row: Row?
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let row {
                RowDetailView(session: session, collection: collection, row: row)
            } else if let failure {
                CorpusOpenFailure(message: failure) { attempt += 1 }
            } else {
                ProgressView().tint(session.accent)
            }
        }
        .task(id: "\(id)|\(session.publishedRevision ?? "local")|\(session.companionDownloadRevision)|\(attempt)") {
            failure = nil
            do {
                let loaded = try await session.client.item(collection, id: id, in: session.connection.spaceId)
                guard sourceReference?.accepts(loaded) != false else { throw SpecialisedCorpusReference.ReadError.sourceMismatch }
                try Task.checkCancellation(); row = loaded
            } catch where error.isCancellation {
            } catch { row = nil; failure = error.localizedDescription }
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
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let row {
                RowDetailView(session: session, collection: Collections["passages"], row: row)
            } else if let asWork {
                WorkByIdView(session: session, nodusId: asWork)
            } else if let failure {
                CorpusOpenFailure(message: failure) { attempt += 1 }
            } else {
                ProgressView().tint(session.accent)
            }
        }
        .task(id: "\(id)|\(session.publishedRevision ?? "local")|\(attempt)") {
            guard row == nil, asWork == nil else { return }
            failure = nil
            guard let passages = Collections["passages"] else {
                failure = String(localized: "Passages are not available in this vault."); return
            }
            do {
                let loaded = try await session.client.item(passages, id: id, in: session.connection.spaceId)
                try Task.checkCancellation(); row = loaded
            } catch let error as APIError where error.isNotFound {
                guard !Task.isCancelled else { return }
                asWork = id
            } catch where error.isCancellation {
            } catch {
                failure = error.localizedDescription
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
    private let accent: Color
    private let session: SpaceSession?
    /// A tap on a numbered reference — `[3]` — in an answer about a page. Only the report chat
    /// passes one; everywhere else a bracketed number is a bracketed number.
    private let onReference: ((Int) -> Void)?

    /// What this prose has asked to show, and the question it has asked.
    ///
    /// An object rather than two `@State` properties, and nothing in `body` reads it. That is the
    /// whole point: every paragraph `body` hands to SwiftUI is a `UITextView` that has to be laid
    /// out and measured again, and a `@State` that `body` reads makes opening or closing a
    /// citation pay for all of it. Pressing "Done" hid that — the work happened while the sheet
    /// still covered the screen. Swiping the sheet down did not, because then the same work lands
    /// in the middle of the dismissal, which is exactly the pause a reader saw.
    @State private var presenting = Presentation()
    @Environment(\.nodusReadingStyle) private var reading
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// The page's find bar, when there is one. Prose is the thing a reader searches, so this is
    /// where the words of a page are declared — after the Markdown and the citations have been
    /// resolved, because what is registered has to be what is on the screen.
    @Environment(PageSearch.self) private var search: PageSearch?
    /// The open report's reading bookmark, when this prose is inside one. Optional, so an
    /// immersion station or a chat bubble keeps the plain selection menu it always had.
    @Environment(ReadingBookmarks.self) private var bookmarks: ReadingBookmarks?
    /// Server-backed highlights, comments and bookmark for a published report.
    /// Optional keeps ordinary prose and local-only reports on their existing path.
    @Environment(ReaderAnnotations.self) private var readerAnnotations: ReaderAnnotations?
    /// The report's own conversation, when this page has one. Optional for the same reason the
    /// bookmark is: prose that has nothing to ask about keeps the plain selection menu.
    @Environment(PageChatInvite.self) private var chat: PageChatInvite?
    @Environment(\.nodusSearchPath) private var searchPath

    /// The sheet and the dialog this prose can put up, held where `body` cannot see them.
    @MainActor
    @Observable
    final class Presentation {
        var reference: CorpusReference?
        /// Whether the reader has pressed on their own bookmark and is being asked about
        /// removing it.
        var isRemovingBookmark = false
    }

    init(
        _ text: String,
        accent: Color,
        session: SpaceSession? = nil,
        labels: [String: String] = [:],
        onReference: ((Int) -> Void)? = nil
    ) {
        self.accent = accent
        self.session = session
        self.onReference = onReference
        // The text and the labels are not kept: everything that reads them is done here. What
        // survives is `blocks`, which is what they were for.
        blocks = Self.prepare(text, labels: labels)
    }

    /// The prose, split into blocks and linkified, once.
    ///
    /// Held rather than computed, and that is the whole of a stutter this screen had. `body` runs
    /// again for every paragraph on the page whenever anything on it changes — a bookmark placed,
    /// a citation's sheet opening, that sheet closing — and not one of those changes a word of
    /// the prose. Splitting the section and running the citation regex over every paragraph on
    /// each of those passes measured about 3.3 ms for a twenty-section report on a Mac, which on
    /// a phone is a dropped frame or two: exactly the "it hesitates and then catches up" this was
    /// reported as.
    ///
    /// `init` is where it belongs, and not by luck. SwiftUI does not call `init` again when
    /// observation invalidates a view — it re-runs `body` on the value the parent already built —
    /// so the work now happens when the report itself changes, which is when it has something new
    /// to say. It also makes every `DocumentProse` compare equal on the way in: the source string
    /// handed to it is now the same instance each pass, so the identity check that decides whether
    /// to reparse the Markdown short-circuits instead of walking two copies of a paragraph.
    private let blocks: [Block]

    /// Uses the same block identities as the rendered reader, so an evidence
    /// jump opens the cited paragraph rather than the start of a long document.
    func anchor(containing text: String, path: [Int] = []) -> PageSearchAnchor? {
        let needle = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !needle.isEmpty, let block = blocks.first(where: {
            $0.text.split(whereSeparator: \.isWhitespace).joined(separator: " ").range(of: needle, options: .caseInsensitive) != nil
        }) else { return nil }
        return PageSearchAnchor(path: path + [block.id])
    }

    /// One paragraph or heading. Identified by its position rather than by a fresh `UUID`: an
    /// identity that changed with each pass would throw away every `UITextView` on the page — and
    /// the anchor the find bar scrolls to with them.
    private struct Block: Identifiable {
        let id: Int
        let level: Int
        let text: String
        /// The same text with every bare `nodus://` token already turned into a Markdown link.
        /// For a heading, which carries no citations, this is the text itself.
        let source: String
    }

    /// Split into headings and paragraphs, then linkify each. See `blocks` for why this runs
    /// where it does.
    private static func prepare(_ text: String, labels: [String: String]) -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []

        func append(level: Int, text: String) {
            result.append(
                Block(
                    id: result.count,
                    level: level,
                    text: text,
                    source: level == 0 ? linkify(text, labels: labels) : text
                )
            )
        }

        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { append(level: 0, text: joined) }
            paragraph = []
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                let heading = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty {
                    flush()
                    append(level: min(hashes, 3), text: heading)
                    continue
                }
            }
            paragraph.append(line)
        }
        flush()
        return result
    }

    var body: some View {
        let displayedBlocks = blocks.map(displayed)
        let annotationDocument = ReaderAnnotationDocument(blocks: displayedBlocks)
        // On iPad the report is deliberately wider than its prose. Those otherwise empty
        // margins are annotation rails: the text keeps its readable measure while comments
        // and bookmarks sit beside it instead of taking thirty points out of every marked
        // paragraph. A compact-width reader keeps the old edge treatment because there is no
        // spare column to spend.
        let annotationRail = reading.document && horizontalSizeClass == .regular
            ? ReportLayout.annotationRail
            : 0
        // A document breathes; a chat bubble does not. Twenty points between paragraphs rather
        // than thirteen: on a phone the gap between paragraphs is the only cue a reader has that
        // one has ended, because the line lengths are too short for the last line's rag to say
        // it, and the leading inside a paragraph has gone up too.
        VStack(alignment: .leading, spacing: reading.document ? 20 : 9) {
            ForEach(blocks) { block in
                let path = searchPath + [block.id]
                let placements = readerAnnotations.map {
                    annotationDocument.placements(
                        for: block.id,
                        annotations: $0.items,
                        bookmarkAim: $0.bookmarkAim
                    )
                } ?? []
                Group {
                    if block.level > 0 {
                        heading(block, path: path)
                    } else if reading.document {
                        DocumentProse(
                            source: block.source,
                            font: reading.uiFont(.callout, dynamicTypeSize: dynamicTypeSize),
                            accent: accent,
                            justified: horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize,
                            linksLive: session != nil,
                            referencesLive: onReference != nil,
                            highlights: search?.highlights(for: path),
                            readerAnnotations: placements,
                            annotationRailWidth: annotationRail,
                            // A paragraph of a document is the only thing on the page that can
                            // be selected by the word, which is why the bookmark lives here and
                            // not on a heading or a bibliography entry.
                            bookmark: bookmarks?.placement(for: path),
                            // Whether the *report* has one, which is not the same question as
                            // whether this paragraph does: a reader marking section five has to
                            // be told they are moving the mark out of section one, and only the
                            // page knows that.
                            reportHasBookmark: readerAnnotations?.bookmark != nil || bookmarks?.bookmark != nil,
                            fixedHighlighter: readerAnnotations?.fixedColor,
                            selectedHighlightColor: readerAnnotations?.selectedColor,
                            onHighlight: readerAnnotations.flatMap { annotations in
                                guard annotations.isWritable else { return nil }
                                return { ranges, color in
                                    let anchors = ranges.compactMap {
                                        annotationDocument.anchor(block: block.id, range: $0)
                                    }
                                    annotations.addHighlights(anchors, color: color)
                                }
                            },
                            onChangeHighlightColor: readerAnnotations.flatMap { annotations in
                                guard annotations.isWritable else { return nil }
                                return { annotation, color in
                                    annotations.updateHighlightColor(annotation, color: color)
                                }
                            },
                            onDeleteHighlight: readerAnnotations.flatMap { annotations in
                                guard annotations.isWritable else { return nil }
                                return { annotation in annotations.delete(annotation) }
                            },
                            onComment: readerAnnotations.flatMap { annotations in
                                guard annotations.isWritable else { return nil }
                                return { range in
                                    guard let anchor = annotationDocument.anchor(block: block.id, range: range) else { return }
                                    annotations.beginComment(anchor)
                                }
                            },
                            onMark: readerAnnotations.flatMap { annotations in
                                guard annotations.isWritable else { return nil }
                                return { range, _ in
                                    guard let anchor = annotationDocument.anchor(block: block.id, range: range) else { return }
                                    annotations.setBookmark(anchor)
                                }
                            } ?? bookmarks.map { marks in
                                { range, snippet in marks.set(path: path, range: range, snippet: snippet) }
                            },
                            // Beside the bookmark, and on the same terms: a report you can mark
                            // your place in is a report you can ask about, and the passage under
                            // your finger is the one you want to ask about.
                            onAsk: chat.map { invite in
                                { selection in invite.ask(about: selection) }
                            },
                            onTapBookmark: bookmarks == nil || readerAnnotations != nil ? nil : { [presenting] in
                                presenting.isRemovingBookmark = true
                            },
                            onOpenAnnotation: readerAnnotations.map { annotations in
                                { id in annotations.open(id) }
                            },
                            onOpen: { [presenting] url in
                                if let number = PageChatReference.number(in: url) {
                                    onReference?(number)
                                    return true
                                }
                                guard let reference = CorpusReference(url) else { return false }
                                presenting.reference = reference
                                return true
                            }
                        )
                    } else {
                        Text(attributed(block.source, path: path))
                            .font(reading.font(.callout, dynamicTypeSize: dynamicTypeSize))
                            .textSelection(.enabled)
                    }
                }
                .nodusRevealed(search?.revealed == path)
                .id(PageSearchAnchor(path: path))
                // A paragraph of a document is a text view, and only it knows where inside
                // itself a word sits. A heading is one line and the page can place it.
                .onAppear {
                    let text = displayed(block)
                    search?.register(path, text: text, placesItsOwnMatches: placesItsOwnMatches(block))
                    // The first mobile bookmark format was local and block-based. Once
                    // this paragraph is available, translate it to the shared UTF-16
                    // document anchor and remove the legacy copy after the synced row is
                    // created. Existing readers therefore keep their place across upgrade.
                    if let readerAnnotations,
                       readerAnnotations.isWritable,
                       readerAnnotations.bookmark == nil,
                       let legacy = bookmarks?.placement(for: path),
                       let anchor = annotationDocument.anchor(block: block.id, range: legacy.range) {
                        readerAnnotations.setBookmark(anchor)
                        bookmarks?.clear()
                    }
                    if readerAnnotations == nil { bookmarks?.reconcile(path: path, displayed: text) }
                }
                .onChange(of: block.text) { _, _ in
                    let text = displayed(block)
                    search?.register(path, text: text, placesItsOwnMatches: placesItsOwnMatches(block))
                    // The report was rewritten under the mark — its citations were named. The
                    // words are looked for again rather than the offsets being trusted.
                    if readerAnnotations == nil { bookmarks?.reconcile(path: path, displayed: text) }
                }
                .onDisappear { search?.unregister(path) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The link is handled here rather than by the system: `nodus://` has no handler, so
        // letting it through opens nothing at all.
        .environment(\.openURL, OpenURLAction { [presenting] url in
            if let number = PageChatReference.number(in: url) {
                onReference?(number)
                return .handled
            }
            guard url.scheme?.lowercased() == "nodus" else { return .systemAction }
            guard session != nil, let reference = CorpusReference(url) else { return .discarded }
            presenting.reference = reference
            return .handled
        })
        // Behind the prose rather than on it, and that is the point: what a sheet's coming and
        // going invalidates is this small view, not the paragraphs it is drawn over.
        .background {
            ProseSheets(
                session: session,
                presenting: presenting,
                removeBookmark: { [bookmarks] in bookmarks?.clear() }
            )
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
            .font(reading.font(isPart ? .title3 : .headline, weight: .bold, dynamicTypeSize: dynamicTypeSize))
            .tracking(isPart ? 0.7 : 0)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, reading.document && horizontalSizeClass == .regular
                ? ReportLayout.annotationRail
                : 0)
            // A heading belongs to what comes after it, so the space above it is what tells a
            // reader that the previous section has ended. Eight points more than the paragraph
            // gap below it is the least that reads as a break rather than as a wide line.
            .padding(.top, reading.document ? (isPart ? 20 : 10) : 3)
    }

    /// What this block puts on the screen, in plain characters.
    ///
    /// Not the Markdown: a reader looking for "registers" is looking for the word they can see,
    /// and the source they cannot see spells it `**registers**` and spells a citation
    /// `[Arco Blanco (2020)](nodus://idea/g-8969)`. Searching the source would miss the first
    /// and match the second on a URL nobody was shown.
    ///
    /// Called when a block appears and when its text changes, not on every pass — which is why
    /// it can afford to parse the Markdown while `body` cannot.
    private func displayed(_ block: Block) -> String {
        guard block.level == 0 else {
            let isPart = block.level <= 2 && reading.document
            return isPart ? block.text.uppercased() : block.text
        }
        guard let parsed = try? AttributedString(
            markdown: block.source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return block.text
        }
        return String(parsed.characters)
    }

    private func attributed(_ source: String, path: PageSearch.Path) -> AttributedString {
        guard var parsed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return AttributedString(source)
        }
        for run in parsed.runs where run.link != nil {
            guard let link = run.link else { continue }
            // Kept live when there is somewhere for it to go, and struck back to plain accent
            // text when there is not: a link that looks live and goes nowhere is worse than one
            // that never claimed to. A citation needs a session to open a record against; a
            // numbered reference points at this very page and needs only a handler.
            let isReference = PageChatReference.number(in: link) != nil
            let live = isReference ? onReference != nil : session != nil
            if !live { parsed[run.range].link = nil }
            parsed[run.range].foregroundColor = CorpusReferenceTone(link).color(accent: accent)
            parsed[run.range].font = reading.font(.callout, weight: .medium, dynamicTypeSize: dynamicTypeSize)
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
    /// Compiled once. `NSRegularExpression` is immutable and documented as safe to use from
    /// several threads, which is what `nonisolated(unsafe)` is asserting here — the alternative,
    /// building it per call, was a fifth of the cost of preparing a report's prose.
    nonisolated private static let citation = try? NSRegularExpression(
        pattern: #"(?<!\]\()\bnodus://[a-z_]+/[^\s)\]（）]+"#,
        options: [.caseInsensitive]
    )

    static func linkify(_ source: String, labels: [String: String]) -> String {
        guard let regex = citation else { return source }

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

/// Everything the prose can put over the page, and nothing that the prose itself has to redraw.
///
/// It exists to be the only view invalidated when a citation opens or closes. A sheet dismissed
/// by a swipe hands SwiftUI its state change halfway through the dismissal animation, and
/// whatever that change invalidates is laid out again on the main thread while the sheet is still
/// moving — which for a section of a report is every paragraph in it, measured again. Here that is
/// a `Color.clear`.
private struct ProseSheets: View {
    let session: SpaceSession?
    let presenting: CorpusProse.Presentation
    let removeBookmark: () -> Void

    var body: some View {
        // Both values are read here, and that read is the whole of why the sheet opens at all.
        // A `Binding`'s getter runs inside the presentation machinery, which is outside the
        // scope `@Observable` tracks — so handing the modifier `$presenting.reference` and
        // nothing else never made this view depend on the property, and tapping a citation set
        // it while nothing redrew. Measured, not reasoned: a probe logged the reference being
        // assigned and this body never running. `@State` hides the trap, because SwiftUI's own
        // storage invalidates the view whether or not anybody read it.
        let reference = presenting.reference
        let isRemovingBookmark = presenting.isRemovingBookmark

        return Color.clear
            .nodusSheet(
                item: Binding(get: { reference }, set: { presenting.reference = $0 })
            ) { reference in
                if let session {
                    NavigationStack {
                        CorpusReferenceView(session: session, reference: reference)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Done") { presenting.reference = nil }
                                }
                            }
                    }
                    // A source is opened from the middle of a paragraph and closed to get back
                    // to it, which is a round trip to the top of the screen for a glance.
                    .nodusModalClose(accent: session.accent)
                }
            }
            // Pressing the mark asks rather than removes. It is one tap inside a paragraph a
            // reader is also selecting, scrolling and tapping citations in, and losing the place
            // you saved to a mistimed touch is not a mistake this screen can undo for you.
            .confirmationDialog(
                "Remove the reading bookmark?",
                isPresented: Binding(
                    get: { isRemovingBookmark },
                    set: { presenting.isRemovingBookmark = $0 }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove the bookmark", role: .destructive) { removeBookmark() }
                Button("Keep it", role: .cancel) {}
            }
    }
}

/// The one paragraph on the screen that is holding a selection.
///
/// A `UITextView` keeps its selection until something takes it away, and nothing did. Two
/// paragraphs of a report are two text views, so selecting in one and then tapping in another
/// left the first one still marked — and worse, the tap that should have opened a citation went
/// into dismissing the edit menu instead, which reads exactly like a link that does not work.
///
/// Global rather than per page, because the thing it models is: only one selection can exist in
/// an application at a time. Weak, so a paragraph that scrolls away and is released takes its
/// entry with it rather than being resurrected by a stale pointer.
@MainActor
enum ProseSelection {
    private static weak var holder: UITextView?

    /// This paragraph now holds the selection. Any other one lets go of its own.
    static func began(in view: UITextView) {
        if let holder, holder !== view { holder.clearSelection() }
        holder = view
    }

    static func ended(in view: UITextView) {
        if holder === view { holder = nil }
    }

    /// Let go of whatever is selected. Called by every page that shows prose, on any tap.
    static func clear() {
        holder?.clearSelection()
        holder = nil
    }
}

extension UITextView {
    /// Drop the selection and stop being the first responder.
    ///
    /// Both halves are needed. Clearing the range alone leaves the text view first responder,
    /// so the edit menu can come back on a touch that was meant for something else; resigning
    /// alone leaves the highlight painted on a paragraph nobody is acting on.
    func clearSelection() {
        guard selectedTextRange != nil || isFirstResponder else { return }
        selectedTextRange = nil
        resignFirstResponder()
    }
}

/// A tap anywhere on a page of prose, which is what lets a selection go.
///
/// UIKit rather than SwiftUI, and that is not a preference. A `simultaneousGesture` on the
/// scrolling container was tried first and it stopped citations opening at all: SwiftUI arbitrates
/// its own gestures against a `UIViewRepresentable`'s recognizers by delaying the touch, and a
/// `UITextView` decides whether a touch is a link tap in that same moment. A recognizer added to
/// the scroll view itself, told to cancel nothing and delay nothing, sees every tap and takes
/// none of them.
///
/// Installed once per scroll view, from whichever paragraph appears in it first.
final class ProseSelectionClearer: UITapGestureRecognizer, UIGestureRecognizerDelegate {
    static func install(on scrollView: UIScrollView) {
        let existing = scrollView.gestureRecognizers ?? []
        guard !existing.contains(where: { $0 is ProseSelectionClearer }) else { return }
        scrollView.addGestureRecognizer(ProseSelectionClearer())
    }

    private init() {
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(fired))
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    @objc private func fired() {
        MainActor.assumeIsolated { ProseSelection.clear() }
    }

    /// Only touches that land on something that is not prose.
    ///
    /// A touch on a paragraph is the text view's business, and it already does the right thing
    /// with it: a tap collapses the selection, a long press makes one. This recognizer took
    /// those touches too at first, and with them went the long press — selecting a word stopped
    /// working entirely on every report. What is left for it is the case UIKit genuinely does
    /// not cover, because nothing there takes first responder: the card around the paragraph,
    /// the space between two sections, the margin down either side.
    ///
    /// The whole chain up, not `touch.view` alone. A touch inside a `UITextView` is delivered to
    /// one of its own layout subviews, so asking whether the hit view *is* a text view answers
    /// no for every touch that lands on a word — which is exactly the check that let this
    /// recognizer go on eating long presses after it was supposed to have stopped.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var candidate = touch.view
        while let view = candidate {
            if view is UITextView { return false }
            candidate = view.superview
        }
        return true
    }

    /// And when it does take one, it shares. It observes; it never wins.
    func gestureRecognizer(
        _ recognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
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

    /// The view controller owning this view, used for UIKit's own reference-library sheet.
    var enclosingViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
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
    @Environment(\.nodusResidentRouteActive) private var routeActive
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
    /// Persistent server-backed marks intersecting this paragraph.
    var readerAnnotations: [ReaderAnnotationDocument.Placement] = []
    /// Spare space on each side of an iPad paragraph. The right-hand rail holds the controls;
    /// the matching left rail keeps the text column centred at the same readable width.
    var annotationRailWidth: CGFloat = 0
    /// The reading bookmark, when it sits in this paragraph.
    var bookmark: ReadingBookmarks.Placement?
    /// Whether the report has a bookmark anywhere, which is what decides whether marking a
    /// selection is adding one or moving the one that exists.
    var reportHasBookmark = false
    /// A colour chosen in the report toolbar. While present, a stable selection is
    /// committed as a highlight without turning the highlighter off.
    var fixedHighlighter: ReaderAnnotationColor?
    /// The toolbar's current colour, whether continuous highlighting is on or off. The manual
    /// selection action uses this directly, so it never needs a second colour submenu.
    var selectedHighlightColor: ReaderAnnotationColor?
    var onHighlight: (([NSRange], ReaderAnnotationColor) -> Void)?
    var onChangeHighlightColor: ((ReaderAnnotation, ReaderAnnotationColor) -> Void)?
    var onDeleteHighlight: ((ReaderAnnotation) -> Void)?
    var onComment: ((NSRange) -> Void)?
    /// Called with the selected range and the words in it. Nil where the page keeps no
    /// bookmark, and that absence is what removes the menu item rather than dimming it.
    var onMark: ((NSRange, String) -> Void)?
    /// Called with the selected words when the reader asks about them. Nil where the page has no
    /// conversation to put them in.
    var onAsk: ((String) -> Void)?
    /// A press that landed on the mark itself.
    var onTapBookmark: (() -> Void)?
    var onOpenAnnotation: ((String) -> Void)?
    let onOpen: (URL) -> Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.accessibilityElementsHidden = !routeActive
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
        // Pressing the mark, and pressing a citation.
        //
        // Three things keep this from being the reason a citation stops opening, and it needed
        // all three: `cancelsTouchesInView = false` so the touch still reaches the text view, a
        // delegate that declines every touch except one landing on something this recognizer
        // answers for, and a delegate that says yes to recognising alongside the text view's own
        // recognizers.
        //
        // The middle one is the one that was missing, and it is not belt-and-braces. A tap
        // recognizer on a `UITextView` competes with the recognizer UIKit uses to decide that a
        // touch was a link tap, and competing was enough: for a fortnight every citation in
        // every report simply did nothing when pressed, on a page where nothing else had
        // changed. Declining the touch outright means that on ordinary prose — no mark and no
        // source under the finger — this recognizer is not in the fight at all.
        let press = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        press.cancelsTouchesInView = false
        press.delaysTouchesEnded = false
        press.delegate = context.coordinator
        view.addGestureRecognizer(press)

        // A saved highlight opens an edit-menu ribbon at the exact pressed point. UIKit keeps
        // this source point inside the visible window, including beside screen and popover
        // edges, which is the same positioning contract as the selection menu.
        let editMenu = UIEditMenuInteraction(delegate: context.coordinator)
        view.addInteraction(editMenu)
        context.coordinator.highlightMenu = editMenu

        // When the toolbar highlighter is active, a stroke is ink: finger and Pencil both paint
        // the range immediately as they move. The recognizer stays disabled in ordinary reading,
        // so scrolling, selecting and opening citations are unchanged until the reader explicitly
        // turns the tool on.
        let stroke = ReaderHighlightGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.highlighted(_:))
        )
        stroke.delegate = context.coordinator
        stroke.isEnabled = false
        view.addGestureRecognizer(stroke)
        context.coordinator.strokeHighlighter = stroke

        // Supported iPads report Pencil hover through the ordinary hover recognizer. Restrict it
        // to Pencil so a trackpad pointer does not masquerade as a drawing tool, and preview only
        // the mark that touching down would make — hover itself never changes the document.
        let hoverMarker = UIView()
        hoverMarker.isHidden = true
        hoverMarker.isUserInteractionEnabled = false
        hoverMarker.layer.cornerRadius = 3
        hoverMarker.accessibilityElementsHidden = true
        view.addSubview(hoverMarker)
        context.coordinator.pencilHoverMarker = hoverMarker

        let pencilHover = UIHoverGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.pencilHovered(_:))
        )
        pencilHover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        pencilHover.cancelsTouchesInView = false
        pencilHover.isEnabled = false
        view.addGestureRecognizer(pencilHover)
        context.coordinator.pencilHover = pencilHover
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.accessibilityElementsHidden = !routeActive
        context.coordinator.onOpen = onOpen
        context.coordinator.linksLive = linksLive
        context.coordinator.onMark = onMark
        context.coordinator.onAsk = onAsk
        context.coordinator.onTapBookmark = onTapBookmark
        context.coordinator.onHighlight = onHighlight
        context.coordinator.onChangeHighlightColor = onChangeHighlightColor
        context.coordinator.onDeleteHighlight = onDeleteHighlight
        context.coordinator.onComment = onComment
        context.coordinator.onOpenAnnotation = onOpenAnnotation
        context.coordinator.fixedHighlighter = fixedHighlighter
        context.coordinator.selectedHighlightColor = selectedHighlightColor
        let highlighterEnabled = fixedHighlighter != nil && onHighlight != nil
        context.coordinator.strokeHighlighter?.isEnabled = highlighterEnabled
        context.coordinator.pencilHover?.isEnabled = highlighterEnabled
        if !highlighterEnabled {
            context.coordinator.hidePencilHoverPreview()
        }
        context.coordinator.readerAnnotations = readerAnnotations
        context.coordinator.annotationRailWidth = annotationRailWidth
        context.coordinator.bookmark = bookmark?.range
        context.coordinator.reportHasBookmark = reportHasBookmark

        let hasMarginMarker = readerAnnotations.contains {
            $0.beginsHere && ($0.annotation.kind == .comment || $0.annotation.kind == .bookmark)
        }
        let wantedLeftInset = annotationRailWidth
        let wantedRightInset = annotationRailWidth > 0 ? annotationRailWidth : (hasMarginMarker ? CGFloat(30) : 0)
        if view.textContainerInset.left != wantedLeftInset || view.textContainerInset.right != wantedRightInset {
            view.textContainerInset.left = wantedLeftInset
            view.textContainerInset.right = wantedRightInset
            view.invalidateIntrinsicContentSize()
        }

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
            // A citation is not a `.link` any more, so it is not a text item and VoiceOver would
            // never find it. Named actions on the paragraph are the better trade anyway: one
            // rotor gesture lists every source the paragraph rests on, by its own label, rather
            // than asking somebody to land on a word inside a justified line.
            view.accessibilityCustomActions = Self.openings(in: context.coordinator.base, using: context.coordinator)
        }
        // Typing in the find bar changes every paragraph on the page, so the one thing it must
        // not do is reparse them: the highlights and the bookmark go on a copy of what was
        // already built.
        let marked = bookmark?.range
        if rebuilt || context.coordinator.painted != highlights || context.coordinator.marked != marked
            || context.coordinator.paintedAnnotations != readerAnnotations {
            context.coordinator.painted = highlights
            context.coordinator.marked = marked
            context.coordinator.paintedAnnotations = readerAnnotations
            view.attributedText = painted(context.coordinator.base)
        }

        DispatchQueue.main.async { context.coordinator.updateMarginMarkers(in: view) }

        // The word, not the paragraph. Deferred by a turn of the run loop because the frame this
        // measurement is against is the one SwiftUI is still deciding: `updateUIView` runs before
        // the layout that gives the paragraph its height, and a rect converted through a stale
        // frame lands somewhere else on the page.
        if let highlights, let active = highlights.active, highlights.aim != context.coordinator.aimed {
            context.coordinator.aimed = highlights.aim
            DispatchQueue.main.async { Self.bringIntoView(active, of: view) }
        }

        // Opening a report where the reader left it. The same machinery as walking onto a
        // match, and for the same reason: the page can only scroll to a paragraph as a whole,
        // and in a paragraph taller than the screen that says nothing about where the mark is.
        if let bookmark, bookmark.aim != context.coordinator.aimedBookmark {
            context.coordinator.aimedBookmark = bookmark.aim
            DispatchQueue.main.async { Self.bringIntoView(bookmark.range, of: view) }
        }
        if let syncedBookmark = readerAnnotations.first(where: { $0.annotation.kind == .bookmark }),
           syncedBookmark.aim != context.coordinator.aimedSyncedBookmark {
            context.coordinator.aimedSyncedBookmark = syncedBookmark.aim
            DispatchQueue.main.async { Self.bringIntoView(syncedBookmark.range, of: view) }
        }

        // The page's own "let go of the selection" tap, hung off the scroll view the first time
        // a paragraph of this page is on screen. Deferred a turn for the same reason the scroll
        // above is: SwiftUI updates a representable before putting it in the hierarchy, so the
        // walk up to the scroll view finds nothing from here.
        if !context.coordinator.installedClearer {
            context.coordinator.installedClearer = true
            DispatchQueue.main.async {
                if let scrollView = view.enclosingScrollView {
                    ProseSelectionClearer.install(on: scrollView)
                    // With the tool on, a finger drag belongs to the highlighter rather than the
                    // enclosing page. When it is off this recognizer is disabled and fails
                    // immediately, so the same relationship adds no delay to ordinary scrolling.
                    if let stroke = context.coordinator.strokeHighlighter {
                        scrollView.panGestureRecognizer.require(toFail: stroke)
                    }
                }
            }
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

    /// The paragraph with the search's marks and the reading bookmark on it, or exactly what was
    /// built when it has neither.
    ///
    /// The bookmark goes on first, so a word that is both marked and being searched for shows
    /// the search: the find bar is a thing happening now, and the bookmark will still be there
    /// when it closes.
    private func painted(_ base: NSAttributedString) -> NSAttributedString {
        let searched = highlights?.ranges ?? []
        guard !searched.isEmpty || bookmark != nil || !readerAnnotations.isEmpty else { return base }
        let output = NSMutableAttributedString(attributedString: base)
        let whole = NSRange(location: 0, length: output.length)
        for placement in readerAnnotations {
            guard let range = placement.range.intersection(whole), range.length > 0 else { continue }
            switch placement.annotation.kind {
            case .highlight:
                if let color = placement.annotation.color {
                    for segment in ReaderHighlightSegments.ranges(in: range, excludingReferencesIn: base) {
                        output.addAttribute(
                            .backgroundColor,
                            value: UIColor(color.color).withAlphaComponent(0.62),
                            range: segment
                        )
                    }
                }
            case .comment:
                let style = NSUnderlineStyle.single.union(.patternDot).rawValue
                output.addAttribute(.underlineStyle, value: style, range: range)
                output.addAttribute(.underlineColor, value: UIColor.secondaryLabel, range: range)
            case .bookmark:
                output.addAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, range: range)
                output.addAttribute(.underlineColor, value: UIColor(Color.nodusBookmarkRule), range: range)
            }
        }
        if let bookmark, let clamped = bookmark.range.intersection(whole), clamped.length > 0 {
            output.addAttribute(.backgroundColor, value: UIColor(Color.nodusBookmark), range: clamped)
            output.addAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, range: clamped)
            output.addAttribute(.underlineColor, value: UIColor(Color.nodusBookmarkRule), range: clamped)
        }
        for range in searched {
            guard let clamped = range.intersection(whole), clamped.length > 0 else { continue }
            let colour = range == highlights?.active ? Color.nodusFindActive : Color.nodusFindMatch
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
                attributes[.foregroundColor] = UIColor(CorpusReferenceTone(link).color(accent: accent))
                if CorpusProse.claims(link) { attributes[.nodusReference] = link }
                // A link that looks live and goes nowhere is worse than one that never
                // claimed to, which is the same rule the SwiftUI path follows — and the same
                // split between a citation, which needs a session, and a numbered reference,
                // which needs only somebody listening.
                let live = PageChatReference.number(in: link) != nil ? referencesLive : linksLive
                if live {
                    // The two are drawn identically and reach UIKit differently. An ordinary
                    // web address stays a `.link`, because everything the system does with one
                    // — the menu, the preview, opening it — is right. A citation carries this
                    // app's own key instead, and that is what makes a press on it *immediate*:
                    // a `.link` is a text item, and a text item is tinted grey under the finger
                    // and only acted on once UIKit has satisfied itself that the touch was a tap
                    // rather than the opening of a double tap. That wait is the whole of the
                    // delay a reader saw between pressing a source and its opening.
                    attributes[CorpusProse.claims(link) ? .nodusCitation : .link] = link
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

    /// One named action per citation in the paragraph, for a reader who cannot aim at a word.
    private static func openings(
        in text: NSAttributedString,
        using coordinator: Coordinator
    ) -> [UIAccessibilityCustomAction]? {
        var actions: [UIAccessibilityCustomAction] = []
        text.enumerateAttribute(.nodusCitation, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let url = value as? URL else { return }
            let label = text.attributedSubstring(from: range).string
            actions.append(
                UIAccessibilityCustomAction(name: String(localized: "Open \(label)")) { [weak coordinator] _ in
                    guard let coordinator else { return false }
                    return MainActor.assumeIsolated { coordinator.onOpen(url) }
                }
            )
        }
        return actions.isEmpty ? nil : actions
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
        var onOpen: (URL) -> Bool
        var linksLive: Bool
        /// Where a selection goes when the reader marks it. Nil where the page keeps no
        /// bookmark, which is what leaves the ordinary selection menu alone.
        var onMark: ((NSRange, String) -> Void)?
        /// Where a selection goes when the reader asks about it. Nil for the same reason, and
        /// separately: a page can have a bookmark and no conversation, or the other way round.
        var onAsk: ((String) -> Void)?
        var onHighlight: (([NSRange], ReaderAnnotationColor) -> Void)?
        var onChangeHighlightColor: ((ReaderAnnotation, ReaderAnnotationColor) -> Void)?
        var onDeleteHighlight: ((ReaderAnnotation) -> Void)?
        var onComment: ((NSRange) -> Void)?
        /// A press that landed inside the mark.
        var onTapBookmark: (() -> Void)?
        var onOpenAnnotation: ((String) -> Void)?
        var fixedHighlighter: ReaderAnnotationColor?
        var selectedHighlightColor: ReaderAnnotationColor?
        var readerAnnotations: [ReaderAnnotationDocument.Placement] = []
        var annotationRailWidth: CGFloat = 0
        /// Where the mark sits in this paragraph, when it is in this one at all.
        var bookmark: NSRange?
        /// Whether the report has one anywhere. A paragraph that does not hold the mark still
        /// has to say "move" rather than "add" — there is only ever one.
        var reportHasBookmark = false
        /// What the text view was last built from, so an unrelated update costs nothing.
        var identity: Identity?
        /// The parsed paragraph, before the search painted anything on it.
        var base = NSAttributedString()
        /// The marks currently on screen, so a keystroke that changes nothing here changes
        /// nothing here.
        var painted: PageSearch.Highlights?
        /// And the bookmark that is currently painted, for the same reason.
        var marked: NSRange?
        var paintedAnnotations: [ReaderAnnotationDocument.Placement] = []
        /// The last request this paragraph brought a match into view for.
        var aimed = 0
        /// The same, for the reading bookmark. Separate counters because the two are separate
        /// requests: closing the find bar must not scroll the page back to the bookmark.
        var aimedBookmark = 0
        var aimedSyncedBookmark = 0
        weak var strokeHighlighter: ReaderHighlightGestureRecognizer?
        weak var pencilHover: UIHoverGestureRecognizer?
        weak var pencilHoverMarker: UIView?
        weak var highlightMenu: UIEditMenuInteraction?
        private var strokeAnchor: Int?
        private var strokeBaseline: NSAttributedString?
        private var activeHighlight: ReaderAnnotationDocument.Placement?
        private var selectionUsesPointer = false
        private var expandsNextPointerSelectionMenu = false
        private var marginButtons: [UIButton] = []
        /// Whether this paragraph has already gone looking for its scroll view to hang the
        /// page's selection-clearing tap off. Once per paragraph, not once per update.
        var installedClearer = false

        init(onOpen: @escaping (URL) -> Bool, linksLive: Bool) {
            self.onOpen = onOpen
            self.linksLive = linksLive
        }

        /// What a reader can do with the words they have selected: keep this passage, or ask
        /// about it.
        ///
        /// Added to the system's own items rather than replacing them: copy, look up, share and
        /// translate are what a reader expects of selected text, and a report is a document
        /// people quote from as much as they navigate.
        ///
        /// Second, straight after Copy, and as glyphs alone. Both of those are about the one row
        /// the reader actually sees: the edit menu opens collapsed, with room for three or four
        /// items and a chevron for the rest, and appending these to the end put them behind that
        /// chevron — two taps for the actions this screen adds, which is exactly the navigation
        /// they exist to remove. A `.small` palette renders each action as its icon, so two of
        /// them cost less width than one labelled item and Look Up and Translate stay where a
        /// reader expects to find them.
        ///
        /// Each appears only where the page can honestly do it, so prose outside a report — a
        /// chat bubble, an immersion station — keeps the plain menu it always had. Returning
        /// `nil` would mean "no menu at all", so that case hands the suggested actions back
        /// untouched.
        @available(iOS 26.0, *)
        func textView(
            _ textView: UITextView,
            editMenuForTextInRanges ranges: [NSValue],
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard let range = ranges.first?.rangeValue else {
                return UIMenu(children: suggestedActions)
            }
            return self.textView(
                textView,
                editMenuForTextIn: range,
                suggestedActions: suggestedActions
            )
        }

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard range.length > 0 else { return UIMenu(children: suggestedActions) }
            let text = (textView.text as NSString).substring(with: range)
            var ours: [UIMenuElement] = []

            // The system presents Copy as the only labelled item in an otherwise icon-sized
            // ribbon. Provide the same operation as the first glyph so it no longer consumes a
            // third of the visible row, while keeping its full spoken name for VoiceOver.
            let copy = UIAction(title: "", image: UIImage(systemName: "doc.on.doc")) { _ in
                MainActor.assumeIsolated {
                    UIPasteboard.general.string = text
                    textView.clearSelection()
                }
            }
            copy.accessibilityLabel = String(localized: "Copy")
            copy.accessibilityIdentifier = "nodus-selection-copy"
            ours.append(copy)

            let highlightable = ReaderHighlightSegments.ranges(
                in: range,
                excludingReferencesIn: textView.attributedText
            )
            if let onHighlight, let colour = selectedHighlightColor, !highlightable.isEmpty {
                // Pastel ink is right on the page and almost invisible as a tiny glyph over the
                // light edit-menu material. Keep the pen itself in the dynamic label colour and
                // retain the chosen pastel as the symbol's secondary layer where SF Symbols
                // provides one.
                let symbol = UIImage.SymbolConfiguration(paletteColors: [
                    UIColor.label,
                    UIColor(colour.color),
                ])
                let image = UIImage(systemName: "highlighter", withConfiguration: symbol)?
                    .withRenderingMode(.alwaysOriginal)
                let highlight = UIAction(title: "", image: image) { _ in
                    MainActor.assumeIsolated {
                        onHighlight(highlightable, colour)
                        textView.clearSelection()
                    }
                }
                highlight.accessibilityLabel = String(localized: "Highlight")
                    + ": " + colour.localizedLabel
                highlight.accessibilityIdentifier = "nodus-selection-highlight"
                ours.append(highlight)
            }

            if let onComment {
                let comment = UIAction(title: "", image: UIImage(systemName: "text.bubble")) { _ in
                    MainActor.assumeIsolated {
                        onComment(range)
                        textView.clearSelection()
                    }
                }
                comment.accessibilityLabel = String(localized: "Add comment")
                comment.accessibilityIdentifier = "nodus-selection-comment"
                ours.append(comment)
            }

            if let onMark {
                // "Move" rather than "Add" when there is already one, because there is only ever
                // one bookmark and a reader who is not told that will look for the old one. Asked
                // of the report and not of this paragraph: the mark being moved is usually in a
                // different section from the words being selected. The title is still set even
                // though the palette hides it: it is what VoiceOver reads, and what the item
                // falls back to if the system ever lays this menu out fully.
                let title = reportHasBookmark
                    ? String(localized: "Move the bookmark here")
                    : String(localized: "Reading bookmark")
                let mark = UIAction(
                    title: "",
                    image: UIImage(systemName: reportHasBookmark ? "bookmark.fill" : "bookmark")
                ) { _ in
                    MainActor.assumeIsolated {
                        onMark(range, text)
                        // The selection has served its purpose, and leaving it up puts the
                        // system's handles over the mark the reader has just made.
                        textView.clearSelection()
                    }
                }
                // Spoken rather than shown. The title is empty on purpose — see above — and this
                // is the only thing left for VoiceOver to read, so it carries the whole meaning.
                mark.accessibilityLabel = title
                mark.accessibilityIdentifier = "nodus-selection-bookmark"
                ours.append(mark)
            }

            if let onAsk {
                // The passage goes into the report's conversation as a quotation, so the question
                // the reader then types is already about something. Asking about a paragraph used
                // to mean opening the chat from the wheel and describing the paragraph — from a
                // document that was right there.
                let ask = UIAction(title: "", image: UIImage(systemName: "bubble.left.and.bubble.right")) { _ in
                    MainActor.assumeIsolated {
                        onAsk(text)
                        textView.clearSelection()
                    }
                }
                ask.accessibilityLabel = String(localized: "Ask about this")
                ask.accessibilityIdentifier = "nodus-selection-ask"
                ours.append(ask)

                // Keep the system dictionary one tap away too. It follows the report-chat icon
                // in the visible palette, matching the order in which a reader decides whether
                // to ask the corpus or simply look up the selected words.
                let lookUp = UIAction(title: "", image: UIImage(systemName: "book.pages")) { _ in
                    MainActor.assumeIsolated {
                        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !term.isEmpty, let presenter = textView.enclosingViewController else { return }
                        textView.clearSelection()
                        presenter.present(UIReferenceLibraryViewController(term: term), animated: true)
                    }
                }
                lookUp.accessibilityLabel = String(localized: "Look Up")
                lookUp.accessibilityIdentifier = "nodus-selection-lookup"
                ours.append(lookUp)
            }

            let palette = UIMenu(title: "", options: .displayInline, preferredElementSize: .small, children: ours)

            // The non-editable text view's standard edit group contains Copy. Its icon above is
            // the replacement, not an additional way to copy, so remove the labelled group and
            // leave Look Up, Translate, Share and the rest of the system's suggestions intact.
            var children = suggestedActions.filter { element in
                (element as? UIMenu)?.identifier != .standardEdit
            }
            children.insert(palette, at: 0)
            let selectionMenu = UIMenu(children: children)

            // UIKit can present a secondary click through either its own text-selection
            // interaction or our installed edit interaction. Both must use the same ribbon.
            guard selectionUsesPointer, let interaction = highlightMenu else { return selectionMenu }
            if expandsNextPointerSelectionMenu {
                expandsNextPointerSelectionMenu = false
                return selectionMenu
            }
            let rect = textView.selectedTextRange.map { textView.firstRect(for: $0) } ?? .zero
            return compactPointerSelectionMenu(
                selectionMenu, in: textView, interaction: interaction,
                sourcePoint: CGPoint(x: rect.midX, y: rect.midY)
            )
        }

        private func compactPointerSelectionMenu(
            _ selectionMenu: UIMenu,
            in textView: UITextView,
            interaction: UIEditMenuInteraction,
            sourcePoint: CGPoint
        ) -> UIMenu {
            guard let palette = selectionMenu.children.first as? UIMenu else { return selectionMenu }
            // An explicit action keeps system suggestions out of the initial context popover.
            // Re-presenting through our interaction makes them reachable from either UIKit path.
            let more = UIAction(title: "", image: UIImage(systemName: "ellipsis")) { [weak self, weak interaction, weak textView] _ in
                guard let self, let interaction, let textView else { return }
                expandsNextPointerSelectionMenu = true
                interaction.dismissMenu()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak interaction, weak textView] in
                    guard let interaction, let textView, textView.selectedRange.length > 0 else {
                        self?.expandsNextPointerSelectionMenu = false
                        return
                    }
                    interaction.presentEditMenu(with: UIEditMenuConfiguration(
                        identifier: "pointer-selection-more" as NSString,
                        sourcePoint: sourcePoint
                    ))
                }
            }
            more.accessibilityLabel = String(localized: "More actions")
            more.accessibilityIdentifier = "nodus-selection-more"
            let primary = palette.children.filter {
                ($0 as? UIAction)?.accessibilityIdentifier != "nodus-selection-lookup"
            }
            return UIMenu(children: [UIMenu(
                title: "", options: .displayInline, preferredElementSize: .small,
                children: primary + [more]
            )])
        }

        /// Which paragraph is holding a selection, so any other one can let go of its own.
        func textViewDidChangeSelection(_ textView: UITextView) {
#if DEBUG
            if ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_READER_INPUT"] == "1" {
                NSLog("NodusReaderInput selection length=%ld firstResponder=%d", textView.selectedRange.length, textView.isFirstResponder ? 1 : 0)
            }
#endif
            if let range = textView.selectedTextRange, !range.isEmpty {
                ProseSelection.began(in: textView)
            } else {
                ProseSelection.ended(in: textView)
            }
        }

        /// Dragging a finger or Pencil across the report behaves like a physical highlighter.
        /// The pastel background is repainted on every movement, while the annotation itself is
        /// written exactly once when the stroke ends. This makes the feedback immediate without
        /// filling the sync ledger with every intermediate range.
        @objc func highlighted(_ recognizer: ReaderHighlightGestureRecognizer) {
            guard let textView = recognizer.view as? UITextView,
                  let colour = fixedHighlighter,
                  let onHighlight
            else {
                cancelHighlightStroke(in: recognizer.view as? UITextView)
                return
            }

            switch recognizer.state {
            case .began:
                hidePencilHoverPreview()
                guard let index = Self.characterIndex(
                    at: recognizer.highlighterLocation(in: textView),
                    in: textView
                ) else {
                    recognizer.isEnabled = false
                    recognizer.isEnabled = true
                    return
                }
                ProseSelection.clear()
                strokeAnchor = index
                strokeBaseline = NSAttributedString(attributedString: textView.attributedText)
                preview(ReaderHighlightStroke.range(from: index, through: index), colour: colour, in: textView)

            case .changed:
                guard let anchor = strokeAnchor,
                      let index = Self.characterIndex(
                          at: recognizer.highlighterLocation(in: textView),
                          in: textView
                      )
                else { return }
                preview(ReaderHighlightStroke.range(from: anchor, through: index), colour: colour, in: textView)

            case .ended:
                guard let anchor = strokeAnchor,
                      let index = Self.characterIndex(
                          at: recognizer.highlighterLocation(in: textView),
                          in: textView
                      )
                else {
                    cancelHighlightStroke(in: textView)
                    return
                }
                let range = ReaderHighlightStroke.range(from: anchor, through: index)
                preview(range, colour: colour, in: textView)
                let segments = strokeBaseline.map {
                    ReaderHighlightSegments.ranges(in: range, excludingReferencesIn: $0)
                } ?? []
                strokeAnchor = nil
                strokeBaseline = nil
                MainActor.assumeIsolated {
                    onHighlight(segments, colour)
                }

            case .cancelled, .failed:
                cancelHighlightStroke(in: textView)

            default:
                break
            }
        }

        /// Show the colour and exact glyph that a supported Apple Pencil will mark on contact.
        /// The system preference is available from iPadOS 17.5; older supported releases show
        /// the preview because they offer no per-user switch to consult.
        @objc func pencilHovered(_ recognizer: UIHoverGestureRecognizer) {
            guard let textView = recognizer.view as? UITextView,
                  let marker = pencilHoverMarker,
                  let colour = fixedHighlighter,
                  onHighlight != nil
            else {
                hidePencilHoverPreview()
                return
            }
            if #available(iOS 17.5, *), !UIPencilInteraction.prefersHoverToolPreview {
                hidePencilHoverPreview()
                return
            }

            switch recognizer.state {
            case .began, .changed:
                let point = recognizer.location(in: textView)
                guard let index = Self.characterIndex(at: point, in: textView, requiresGlyphHit: true),
                      !Self.isWhitespace(at: index, in: textView),
                      let glyph = Self.box(ofCharacterAt: index, in: textView)
                else {
                    hidePencilHoverPreview()
                    return
                }
                marker.backgroundColor = UIColor(colour.color).withAlphaComponent(0.48)
                marker.frame = glyph.insetBy(dx: -1.5, dy: 1.5)
                marker.isHidden = false
                textView.bringSubviewToFront(marker)

            case .ended, .cancelled, .failed:
                hidePencilHoverPreview()

            default:
                break
            }
        }

        func hidePencilHoverPreview() {
            pencilHoverMarker?.isHidden = true
        }

        /// Paint only the visual preview. The baseline already includes saved annotations and
        /// search results, so moving backwards restores everything the temporary stroke crossed.
        private func preview(_ range: NSRange, colour: ReaderAnnotationColor, in textView: UITextView) {
            guard let strokeBaseline, NSMaxRange(range) <= strokeBaseline.length else { return }
            let shown = NSMutableAttributedString(attributedString: strokeBaseline)
            for segment in ReaderHighlightSegments.ranges(in: range, excludingReferencesIn: strokeBaseline) {
                shown.addAttribute(
                    .backgroundColor,
                    value: UIColor(colour.color).withAlphaComponent(0.62),
                    range: segment
                )
            }
            textView.attributedText = shown
        }

        private func cancelHighlightStroke(in textView: UITextView?) {
            if let textView, let strokeBaseline { textView.attributedText = strokeBaseline }
            strokeAnchor = nil
            strokeBaseline = nil
        }

        /// `closestPosition` returns a caret boundary. Prefer the glyph actually under the tip
        /// and fall back to the closest valid character for the gaps between words and lines.
        private static func characterIndex(
            at point: CGPoint,
            in textView: UITextView,
            requiresGlyphHit: Bool = false
        ) -> Int? {
            let length = textView.attributedText.length
            guard length > 0, let position = textView.closestPosition(to: point) else { return nil }
            let offset = textView.offset(from: textView.beginningOfDocument, to: position)
            let boxes: [Int: CGRect] = Dictionary(
                uniqueKeysWithValues: [offset - 1, offset].compactMap { index -> (Int, CGRect)? in
                    guard index >= 0, index < length,
                          let box = box(ofCharacterAt: index, in: textView)
                    else { return nil }
                    return (index, box)
                }
            )
            return ReaderCharacterHitTesting.index(
                caretOffset: offset,
                textLength: length,
                point: point,
                characterBoxes: boxes,
                requiresGlyphHit: requiresGlyphHit
            )
        }

        private static func isWhitespace(at index: Int, in textView: UITextView) -> Bool {
            guard index >= 0, index < textView.attributedText.length else { return true }
            let value = (textView.attributedText.string as NSString).substring(with: NSRange(location: index, length: 1))
            return value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
        }

        /// A press inside the prose: on the marked words, or on a citation.
        ///
        /// Both are answered here rather than by UIKit, and the citation is the reason. A tap on
        /// a text item is deliberately not instantaneous — UIKit tints it and waits — and a
        /// source that takes a beat to open after visibly acknowledging the press reads as the
        /// app hesitating. Nothing here waits for anything.
        @objc func pressed(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? UITextView else { return }
            // A tap that ends a selection is ending a selection. Opening whatever happened to be
            // under the finger as well would take the reader off the page they were quoting.
            guard view.selectedTextRange?.isEmpty ?? true else { return }
            let point = recognizer.location(in: view)
            if onTapBookmark != nil, hitsBookmark(in: view, at: point) {
                MainActor.assumeIsolated { onTapBookmark?() }
                return
            }
            if let annotation = annotation(at: point, in: view) {
                if annotation.annotation.kind == .highlight {
                    presentHighlightMenu(for: annotation, at: point)
                } else {
                    MainActor.assumeIsolated { onOpenAnnotation?(annotation.annotation.id) }
                }
                return
            }
            guard let url = Self.citation(at: point, in: view) else { return }
            MainActor.assumeIsolated { _ = onOpen(url) }
        }

        private func presentHighlightMenu(
            for placement: ReaderAnnotationDocument.Placement,
            at point: CGPoint
        ) {
            guard let highlightMenu else { return }
            activeHighlight = placement
            let configuration = UIEditMenuConfiguration(
                identifier: placement.annotation.id as NSString,
                sourcePoint: point
            )
            highlightMenu.presentEditMenu(with: configuration)
        }

        func editMenuInteraction(
            _ interaction: UIEditMenuInteraction,
            menuFor configuration: UIEditMenuConfiguration,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
#if DEBUG
            if ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_READER_INPUT"] == "1", let view = interaction.view as? UITextView {
                NSLog("NodusReaderInput custom-menu length=%ld firstResponder=%d", view.selectedRange.length, view.isFirstResponder ? 1 : 0)
            }
#endif
            // The installed highlight interaction also receives some secondary clicks on
            // selected prose. Delegate to the same builder used by UIKit's text interaction.
            if activeHighlight == nil,
               let textView = interaction.view as? UITextView,
               textView.selectedRange.length > 0 {
                return self.textView(
                    textView,
                    editMenuForTextIn: textView.selectedRange,
                    suggestedActions: suggestedActions
                )
            }

            guard let placement = activeHighlight else { return nil }
            let annotation = placement.annotation
            var actions: [UIMenuElement] = []

            if let onChangeHighlightColor {
                let colors = ReaderAnnotationColor.allCases.map { colour in
                    let image = ReaderHighlightMenuSwatch.image(
                        for: colour,
                        selected: annotation.color == colour
                    )
                    let action = UIAction(title: colour.localizedLabel, image: image) { _ in
                        MainActor.assumeIsolated { onChangeHighlightColor(annotation, colour) }
                    }
                    action.accessibilityLabel = String(localized: "Change highlight color")
                        + ": " + colour.localizedLabel
                    return action
                }
                let colorMenu = UIMenu(
                    title: "",
                    image: UIImage(systemName: "paintpalette"),
                    children: colors
                )
                colorMenu.accessibilityLabel = String(localized: "Change highlight color")
                actions.append(colorMenu)
            }

            let copy = UIAction(title: "", image: UIImage(systemName: "doc.on.doc")) { _ in
                MainActor.assumeIsolated { UIPasteboard.general.string = annotation.anchor.selectedText }
            }
            copy.accessibilityLabel = String(localized: "Copy")
            actions.append(copy)

            if let onAsk {
                let ask = UIAction(title: "", image: UIImage(systemName: "quote.bubble")) { _ in
                    MainActor.assumeIsolated { onAsk(annotation.anchor.selectedText) }
                }
                ask.accessibilityLabel = String(localized: "Quote in chat")
                actions.append(ask)
            }

            if let onComment {
                let comment = UIAction(title: "", image: UIImage(systemName: "text.bubble")) { _ in
                    MainActor.assumeIsolated { onComment(placement.range) }
                }
                comment.accessibilityLabel = String(localized: "Add comment")
                actions.append(comment)
            }

            if let onDeleteHighlight {
                let delete = UIAction(
                    title: "",
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { _ in
                    MainActor.assumeIsolated { onDeleteHighlight(annotation) }
                }
                delete.accessibilityLabel = String(localized: "Delete highlight")
                actions.append(delete)
            }

            return UIMenu(
                title: "",
                options: .displayInline,
                preferredElementSize: .small,
                children: actions
            )
        }

        func editMenuInteraction(
            _ interaction: UIEditMenuInteraction,
            willDismissMenuFor configuration: UIEditMenuConfiguration,
            animator: UIEditMenuInteractionAnimating
        ) {
            animator.addCompletion { [weak self] in self?.activeHighlight = nil }
        }

        /// The citation under this point, when the point really is on one.
        ///
        /// `closestPosition(to:)` names a caret position rather than a character: a tap on the
        /// right half of a glyph answers with the index *after* it, and a tap in the white beyond
        /// the end of a line answers with the last character on that line. So both sides of the
        /// boundary are asked, and the answer only counts if the point falls inside that
        /// character's own box — which is what stops the blank end of a line that happens to
        /// finish on a source from opening it.
        static func citation(at point: CGPoint, in view: UITextView) -> URL? {
            guard let text = view.attributedText, text.length > 0,
                  let position = view.closestPosition(to: point)
            else { return nil }
            let offset = view.offset(from: view.beginningOfDocument, to: position)
            for index in [offset, offset - 1] where index >= 0 && index < text.length {
                guard let url = text.attribute(.nodusCitation, at: index, effectiveRange: nil) as? URL,
                      let box = box(ofCharacterAt: index, in: view),
                      box.insetBy(dx: -1, dy: 0).contains(point)
                else { continue }
                return url
            }
            return nil
        }

        private static func box(ofCharacterAt index: Int, in view: UITextView) -> CGRect? {
            guard let start = view.position(from: view.beginningOfDocument, offset: index),
                  let end = view.position(from: start, offset: 1),
                  let range = view.textRange(from: start, to: end)
            else { return nil }
            let rect = view.firstRect(for: range)
            return rect.isNull || rect.isInfinite ? nil : rect
        }

        /// Whether a point in this paragraph is on the marked words.
        ///
        /// Hit-tested twice, because `closestPosition(to:)` answers for a tap anywhere in the
        /// paragraph — it is the *closest* position, not the one under the finger. So the
        /// character it names has to be inside the mark, and the point has to be on that
        /// character's own line. Without the second test, tapping the blank end of a short last
        /// line three paragraphs' worth of leading below the mark counts as pressing it.
        private func hitsBookmark(in view: UITextView, at point: CGPoint) -> Bool {
            guard let bookmark, bookmark.length > 0 else { return false }
            guard let position = view.closestPosition(to: point) else { return false }
            let index = view.offset(from: view.beginningOfDocument, to: position)
            guard NSLocationInRange(index, bookmark) else { return false }
            let caret = view.caretRect(for: position)
            return point.y >= caret.minY - 2 && point.y <= caret.maxY + 2
        }

        private func annotation(at point: CGPoint, in view: UITextView) -> ReaderAnnotationDocument.Placement? {
            guard onOpenAnnotation != nil, let position = view.closestPosition(to: point) else { return nil }
            let offset = view.offset(from: view.beginningOfDocument, to: position)
            // UIKit returns a caret boundary, so the pressed glyph can be immediately before
            // or after it. Requiring the glyph box also prevents whitespace at line ends from
            // opening an annotation that merely happens to be the closest text.
            for index in [offset, offset - 1] where index >= 0 {
                guard let box = Self.box(ofCharacterAt: index, in: view),
                      box.insetBy(dx: -1, dy: 0).contains(point),
                      view.attributedText.attribute(.nodusReference, at: index, effectiveRange: nil) == nil
                else { continue }
                if let placement = readerAnnotations
                    .filter({ $0.range.length > 0 && NSLocationInRange(index, $0.range) })
                    .sorted(by: { $0.range.length < $1.range.length })
                    .first {
                    return placement
                }
            }
            return nil
        }

        func updateMarginMarkers(in view: UITextView) {
            marginButtons.forEach { $0.removeFromSuperview() }
            marginButtons = []
            guard view.bounds.width > 0, onOpenAnnotation != nil else { return }

            var lastY = -CGFloat.greatestFiniteMagnitude
            for placement in readerAnnotations
                .filter({ $0.beginsHere && ($0.annotation.kind == .comment || $0.annotation.kind == .bookmark) })
                .sorted(by: { $0.range.location < $1.range.location }) {
                guard let start = view.position(from: view.beginningOfDocument, offset: placement.range.location),
                      let end = view.position(from: start, offset: max(1, placement.range.length)),
                      let range = view.textRange(from: start, to: end)
                else { continue }
                let rect = view.firstRect(for: range)
                guard !rect.isNull, !rect.isInfinite else { continue }
                let button = UIButton(type: .system)
                let isBookmark = placement.annotation.kind == .bookmark
                button.setImage(UIImage(systemName: isBookmark ? "bookmark.fill" : "text.bubble.fill"), for: .normal)
                button.tintColor = isBookmark ? UIColor(Color.nodusBookmarkRule) : .secondaryLabel
                button.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.82)
                button.layer.cornerRadius = 10
                let y = max(rect.midY - 10, lastY + 22)
                lastY = y
                let x = annotationRailWidth > 0
                    ? view.bounds.width - annotationRailWidth + (annotationRailWidth - 20) / 2
                    : view.bounds.width - 22
                button.frame = CGRect(x: max(0, x), y: y, width: 20, height: 20)
                button.accessibilityLabel = isBookmark
                    ? String(localized: "Reading bookmark")
                    : String(localized: "Open comment")
                let id = placement.annotation.id
                button.addAction(UIAction { [weak self] _ in
                    MainActor.assumeIsolated { self?.onOpenAnnotation?(id) }
                }, for: .touchUpInside)
                view.addSubview(button)
                marginButtons.append(button)
            }
        }

        // MARK: This recognizer, kept out of everything else's way

        /// Take the touch only when it is on something this paragraph answers for.
        ///
        /// Declining is what matters. A tap recognizer on a `UITextView` competes with the ones
        /// UIKit uses to select a word and to decide a touch was a link tap, and merely not
        /// cancelling the touch was not enough: while this recognizer accepted every touch, no
        /// citation in any report opened at all. On ordinary prose it now never enters the
        /// arbitration — and on the two things it does claim, the mark and a citation, it is the
        /// only one that wants them.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            selectionUsesPointer = touch.type == .indirectPointer
#if DEBUG
            if ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_READER_INPUT"] == "1", let view = recognizer.view {
                let point = touch.location(in: view)
                NSLog("NodusReaderInput touch type=%ld x=%.1f y=%.1f", touch.type.rawValue, point.x, point.y)
            }
#endif
            if recognizer === strokeHighlighter {
                return (touch.type == .direct || touch.type == .pencil)
                    && fixedHighlighter != nil
                    && onHighlight != nil
            }
            guard let view = recognizer.view as? UITextView else { return false }
            let point = touch.location(in: view)
            if onTapBookmark != nil, hitsBookmark(in: view, at: point) { return true }
            if annotation(at: point, in: view) != nil { return true }
            return Coordinator.citation(at: point, in: view) != nil
        }

        /// And when it does take one, it shares. Belt to the braces above: a touch on the mark
        /// is not a touch the text view should stop hearing about.
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            if recognizer === strokeHighlighter || other === strokeHighlighter { return false }
            return true
        }

        /// The two methods that answer for text items, and a citation is no longer one.
        ///
        /// Both are kept, and both still refuse the case they were written for: a `nodus://`
        /// address must never reach the system. Its menu is "Open / Copy / Share" over
        /// `nodus://idea/g-8969` — an internal address, so sharing it sends somebody a string
        /// that does nothing and Open hands a scheme to a system with no handler for it. Since
        /// the citation now carries this app's own attribute instead of `.link`, neither method
        /// should see one at all; they refuse anyway, because a paragraph built by some future
        /// path that still sets `.link` would otherwise offer exactly that menu.
        ///
        /// What does reach them is an ordinary `https://` in the prose, which keeps every bit of
        /// the system's behaviour.
        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            guard case .link(let url) = textItem.content, CorpusProse.claims(url) else {
                return defaultAction
            }
            return UIAction(title: "") { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.onOpen(url) }
            }
        }

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

extension NSAttributedString.Key {
    /// Any reference label, live or not. Highlighter ink treats it as a gap in the prose.
    static let nodusReference = NSAttributedString.Key("NodusReference")

    /// A citation into the corpus, drawn like a link and opened by this app rather than by UIKit.
    ///
    /// Deliberately not `.link`. UIKit treats a link as a *text item*: it tints it grey under the
    /// finger, waits to see whether the touch becomes a double tap, and only then runs the action
    /// — which is the right behaviour for a web address and the wrong one for a footnote in the
    /// document you are reading. Under this key the same URL is invisible to that machinery, so
    /// the paragraph's own tap recognizer opens it on the spot.
    static let nodusCitation = NSAttributedString.Key("NodusCitation")
}
