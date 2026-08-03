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

    @State private var opened: CorpusReference?
    @Environment(\.nodusReadingStyle) private var reading

    init(_ text: String, accent: Color, session: SpaceSession? = nil, labels: [String: String] = [:]) {
        self.text = text
        self.accent = accent
        self.session = session
        self.labels = labels
    }

    private struct Block: Identifiable {
        let id = UUID()
        let level: Int
        let text: String
    }

    var body: some View {
        // A document breathes; a chat bubble does not. The wider spacing is part of the same
        // decision as the justification, and both arrive with the reading style.
        VStack(alignment: .leading, spacing: reading.justified ? 13 : 9) {
            ForEach(blocks) { block in
                if block.level > 0 {
                    heading(block)
                } else if reading.justified {
                    JustifiedProse(
                        source: Self.linkify(block.text, labels: labels),
                        font: reading.uiFont(.callout),
                        accent: accent,
                        linksLive: session != nil,
                        onOpen: { url in
                            guard let reference = CorpusReference(url) else { return false }
                            opened = reference
                            return true
                        }
                    )
                } else {
                    Text(attributed(block.text))
                        .font(reading.font(.callout))
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The link is handled here rather than by the system: `nodus://` has no handler, so
        // letting it through opens nothing at all.
        .environment(\.openURL, OpenURLAction { url in
            guard session != nil, let reference = CorpusReference(url) else { return .systemAction }
            opened = reference
            return .handled
        })
        .sheet(item: $opened) { reference in
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

    /// A heading, set as the document it belongs to would set one.
    ///
    /// In a report a first-level heading is a part title, and it was `.headline` — one step
    /// above the body and indistinguishable from it three paragraphs later. Uppercase, bold,
    /// two sizes up and with room above it, a reader can find where a section starts by
    /// scrolling past rather than by reading.
    private func heading(_ block: Block) -> some View {
        let isPart = block.level == 1 && reading.justified
        return Text(isPart ? block.text.uppercased() : block.text)
            .font(reading.font(isPart ? .title3 : .headline, weight: .bold))
            .tracking(isPart ? 0.7 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, reading.justified ? (isPart ? 12 : 6) : 3)
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
            if !joined.isEmpty { result.append(Block(level: 0, text: joined)) }
            paragraph = []
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                let heading = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty {
                    flush()
                    result.append(Block(level: min(hashes, 3), text: heading))
                    continue
                }
            }
            paragraph.append(line)
        }
        flush()
        return result
    }

    private func attributed(_ source: String) -> AttributedString {
        guard var parsed = try? AttributedString(
            markdown: Self.linkify(source, labels: labels),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return AttributedString(source)
        }
        for run in parsed.runs where run.link != nil {
            // Kept live when there is a session to open it against, and struck back to plain
            // accent text when there is not: a link that looks live and goes nowhere is worse
            // than one that never claimed to.
            if session == nil { parsed[run.range].link = nil }
            parsed[run.range].foregroundColor = accent
            parsed[run.range].font = reading.font(.callout, weight: .medium)
            parsed[run.range].underlineStyle = session == nil ? nil : .single
        }
        return parsed
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

/// One paragraph, justified.
///
/// SwiftUI's `Text` aligns leading, centre or trailing and has no fourth option: justification
/// is a paragraph-style attribute and `Text` drops paragraph styles on the way in. So a
/// justified paragraph is a `UITextView` — non-editable, non-scrolling, sized by SwiftUI — and
/// everything `Text` was doing is done here explicitly instead of hoped for:
///
/// - The Markdown is parsed once and each run is given a real `UIFont`, because the inline
///   presentation intents an `AttributedString` carries mean nothing to UIKit: converting one
///   directly loses every bold and italic in the report.
/// - A `nodus://` link is coloured, underlined and handed back to the caller on tap. The system
///   has no handler for that scheme, so letting the default action run opens nothing.
/// - Hyphenation is on. Justified prose without it opens rivers of white space down a phone's
///   narrow column, which is worse than the ragged edge it replaced.
private struct JustifiedProse: UIViewRepresentable {
    /// Markdown, already linkified.
    let source: String
    let font: UIFont
    let accent: Color
    let linksLive: Bool
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
        view.attributedText = attributed()
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
                // claimed to, which is the same rule the SwiftUI path follows.
                if linksLive {
                    attributes[.link] = link
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .justified
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.hyphenationFactor = 1
        paragraph.lineHeightMultiple = 1.1
        output.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: output.length))
        return output
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onOpen: (URL) -> Bool
        var linksLive: Bool

        init(onOpen: @escaping (URL) -> Bool, linksLive: Bool) {
            self.onOpen = onOpen
            self.linksLive = linksLive
        }

        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            // nil means "do nothing further": the citation has already been opened here.
            return onOpen(url) ? nil : defaultAction
        }
    }
}
