import Foundation
import NodusKit
import Observation
import SwiftUI

/// The six colours shared byte-for-byte with the desktop reader contract.
enum ReaderAnnotationColor: String, CaseIterable, Identifiable, Sendable {
    case yellow, rose, blue, mint, lavender, peach

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .yellow: "Yellow"
        case .rose: "Rose"
        case .blue: "Blue"
        case .mint: "Mint"
        case .lavender: "Lavender"
        case .peach: "Peach"
        }
    }

    var labelKey: String.LocalizationValue {
        switch self {
        case .yellow: "Yellow"
        case .rose: "Rose"
        case .blue: "Blue"
        case .mint: "Mint"
        case .lavender: "Lavender"
        case .peach: "Peach"
        }
    }

    var color: Color {
        switch self {
        case .yellow: Color(red: 0.99, green: 0.90, blue: 0.54)
        case .rose: Color(red: 1.00, green: 0.80, blue: 0.83)
        case .blue: Color(red: 0.75, green: 0.86, blue: 1.00)
        case .mint: Color(red: 0.73, green: 0.97, blue: 0.82)
        case .lavender: Color(red: 0.87, green: 0.84, blue: 1.00)
        case .peach: Color(red: 1.00, green: 0.84, blue: 0.67)
        }
    }
}

struct ReaderAnnotationAnchor: Hashable, Sendable {
    let startOffset: Int
    let endOffset: Int
    let selectedText: String
    let prefix: String
    let suffix: String
}

struct ReaderAnnotation: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case highlight, comment, bookmark }

    let id: String
    let draftId: String
    let scope: String
    let kind: Kind
    let color: ReaderAnnotationColor?
    let anchor: ReaderAnnotationAnchor
    let comment: String?
    let createdAt: Date
    let updatedAt: Date

    init?(row: Row) {
        guard
            let id = row.text("id"),
            let draftId = row.text("draft_id"),
            let scope = row.text("scope"),
            let rawKind = row.text("kind"),
            let kind = Kind(rawValue: rawKind),
            let start = row.int("start_offset"),
            let end = row.int("end_offset"),
            let selected = row.string("selected_text"),
            start >= 0,
            end > start,
            (selected as NSString).length == end - start
        else { return nil }

        let color = row.text("color").flatMap(ReaderAnnotationColor.init(rawValue:))
        if kind == .highlight, color == nil { return nil }
        let comment = row.text("comment_text")
        if kind == .comment, comment == nil { return nil }

        self.id = id
        self.draftId = draftId
        self.scope = scope
        self.kind = kind
        self.color = color
        anchor = ReaderAnnotationAnchor(
            startOffset: start,
            endOffset: end,
            selectedText: selected,
            prefix: row.string("prefix") ?? "",
            suffix: row.string("suffix") ?? ""
        )
        self.comment = comment
        createdAt = row.date("created_at") ?? .distantPast
        updatedAt = row.date("updated_at") ?? createdAt
    }

    init(
        id: String,
        draftId: String,
        scope: String = "source",
        kind: Kind,
        color: ReaderAnnotationColor? = nil,
        anchor: ReaderAnnotationAnchor,
        comment: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.draftId = draftId
        self.scope = scope
        self.kind = kind
        self.color = color
        self.anchor = anchor
        self.comment = comment
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var row: [String: JSONValue] {
        let timestamp = ISO8601DateFormatter.nodusFractional
        return [
            "id": .string(id),
            "draft_id": .string(draftId),
            "scope": .string(scope),
            "kind": .string(kind.rawValue),
            "color": color.map { .string($0.rawValue) } ?? .null,
            "start_offset": .int(Int64(anchor.startOffset)),
            "end_offset": .int(Int64(anchor.endOffset)),
            "selected_text": .string(anchor.selectedText),
            "prefix": .string(String(anchor.prefix.suffix(64))),
            "suffix": .string(String(anchor.suffix.prefix(64))),
            "comment_text": comment.map(JSONValue.string) ?? .null,
            "created_at": .string(timestamp.string(from: createdAt)),
            "updated_at": .string(timestamp.string(from: updatedAt)),
        ]
    }
}

/// Plain-text coordinates for the independently rendered paragraphs in one report.
/// JavaScript and NSString both count UTF-16, which makes these anchors portable.
struct ReaderAnnotationDocument {
    struct Placement: Identifiable, Equatable {
        let annotation: ReaderAnnotation
        let range: NSRange
        /// Only the first fragment gets a marginal comment/bookmark icon.
        let beginsHere: Bool
        let aim: Int

        var id: String { "\(annotation.id):\(range.location):\(range.length)" }
    }

    let blocks: [String]
    private let starts: [Int]
    private let text: NSString

    init(blocks: [String]) {
        self.blocks = blocks
        var starts: [Int] = []
        var joined = ""
        for (index, block) in blocks.enumerated() {
            if index > 0 { joined += "\n" }
            starts.append((joined as NSString).length)
            joined += block
        }
        self.starts = starts
        text = joined as NSString
    }

    func anchor(block index: Int, range: NSRange) -> ReaderAnnotationAnchor? {
        guard blocks.indices.contains(index) else { return nil }
        let block = blocks[index] as NSString
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= block.length else { return nil }
        let start = starts[index] + range.location
        let end = start + range.length
        return ReaderAnnotationAnchor(
            startOffset: start,
            endOffset: end,
            selectedText: block.substring(with: range),
            prefix: text.substring(with: NSRange(location: max(0, start - min(64, start)), length: min(64, start))),
            suffix: text.substring(with: NSRange(location: end, length: min(64, text.length - end)))
        )
    }

    func placements(
        for blockIndex: Int,
        annotations: [ReaderAnnotation],
        bookmarkAim: Int
    ) -> [Placement] {
        guard blocks.indices.contains(blockIndex) else { return [] }
        let blockRange = NSRange(location: starts[blockIndex], length: (blocks[blockIndex] as NSString).length)
        return annotations.compactMap { annotation in
            guard let resolved = resolve(annotation.anchor), let overlap = resolved.intersection(blockRange), overlap.length > 0 else {
                return nil
            }
            return Placement(
                annotation: annotation,
                range: NSRange(location: overlap.location - blockRange.location, length: overlap.length),
                beginsHere: overlap.location == resolved.location,
                aim: annotation.kind == .bookmark ? bookmarkAim : 0
            )
        }
    }

    private func resolve(_ anchor: ReaderAnnotationAnchor) -> NSRange? {
        let direct = NSRange(location: anchor.startOffset, length: anchor.endOffset - anchor.startOffset)
        if direct.location >= 0, NSMaxRange(direct) <= text.length,
           text.substring(with: direct) == anchor.selectedText {
            return direct
        }

        let needle = anchor.selectedText as NSString
        guard needle.length > 0 else { return nil }
        var search = NSRange(location: 0, length: text.length)
        var best: (range: NSRange, score: Double)?
        while search.length >= needle.length {
            let found = text.range(of: anchor.selectedText, options: [], range: search)
            if found.location == NSNotFound { break }
            var score = -min(1, Double(abs(found.location - anchor.startOffset)) / Double(max(1, text.length)))
            if !anchor.prefix.isEmpty {
                let prefix = anchor.prefix as NSString
                if found.location >= prefix.length,
                   text.substring(with: NSRange(location: found.location - prefix.length, length: prefix.length)) == anchor.prefix {
                    score += 2
                }
            }
            if !anchor.suffix.isEmpty {
                let suffix = anchor.suffix as NSString
                let after = NSMaxRange(found)
                if after + suffix.length <= text.length,
                   text.substring(with: NSRange(location: after, length: suffix.length)) == anchor.suffix {
                    score += 2
                }
            }
            if best == nil || score > best!.score { best = (found, score) }
            let next = found.location + max(1, found.length)
            search = NSRange(location: next, length: max(0, text.length - next))
        }
        return best?.range
    }
}

/// The UTF-16 range covered by a highlighter stroke, in either drawing direction.
/// Kept outside UIKit so the gesture and its persisted desktop-compatible anchor cannot disagree
/// about whether the character under the tip belongs to the mark.
enum ReaderHighlightStroke {
    static func range(from anchor: Int, through index: Int) -> NSRange {
        let lower = min(anchor, index)
        return NSRange(location: lower, length: max(anchor, index) - lower + 1)
    }
}

/// The pieces of a requested highlight that are prose rather than a corpus reference.
/// A single gesture may cross several citations, so it can produce several independently
/// anchored highlights while the reference labels themselves remain untouched.
enum ReaderHighlightSegments {
    static func ranges(in proposed: NSRange, excludingReferencesIn text: NSAttributedString) -> [NSRange] {
        let whole = NSRange(location: 0, length: text.length)
        guard let proposed = proposed.intersection(whole), proposed.length > 0 else { return [] }

        var ranges: [NSRange] = []
        var cursor = proposed.location
        let end = NSMaxRange(proposed)
        text.enumerateAttribute(.nodusReference, in: proposed) { value, effective, _ in
            guard value != nil, let excluded = effective.intersection(proposed) else { return }
            if cursor < excluded.location {
                ranges.append(NSRange(location: cursor, length: excluded.location - cursor))
            }
            cursor = max(cursor, NSMaxRange(excluded))
        }
        if cursor < end { ranges.append(NSRange(location: cursor, length: end - cursor)) }
        return ranges.filter { $0.length > 0 }
    }
}

/// Server rows plus this device's persistent optimistic mutation overlay.
@Observable
@MainActor
final class ReaderAnnotations {
    enum Presentation: Identifiable {
        case comment(ReaderAnnotation)
        case newComment(ReaderAnnotationAnchor)
        case bookmark(ReaderAnnotation)

        var id: String {
            switch self {
            case .comment(let item), .bookmark(let item): item.id
            case .newComment(let anchor): "new:\(anchor.startOffset):\(anchor.endOffset)"
            }
        }
    }

    let draftId: String
    let scope: String
    let isWritable: Bool
    private(set) var items: [ReaderAnnotation] = []
    private(set) var error: String?
    /// The colour used by both the selection action and continuous highlighting.
    /// Turning the highlighter off must not forget it: the toolbar's colour control is a
    /// choice, while the highlighter button is only a mode toggle.
    var selectedColor: ReaderAnnotationColor = .yellow
    var highlighterEnabled = false
    var fixedColor: ReaderAnnotationColor? { highlighterEnabled ? selectedColor : nil }
    var presentation: Presentation?
    private(set) var bookmarkAim = 0

    private var remote: [ReaderAnnotation] = []
    private var outbox: OutboxController?
    private struct WaitingMutation {
        let kind: Mutation.Kind
        let rowId: String
        let row: [String: JSONValue]?
        let title: String
    }
    private var waiting: [WaitingMutation] = []

    init(draftId: String, scope: String = "source", isWritable: Bool) {
        self.draftId = draftId
        self.scope = scope
        self.isWritable = isWritable
    }

    var bookmark: ReaderAnnotation? { items.first { $0.kind == .bookmark } }

    func toggleHighlighter() {
        guard isWritable else { return }
        highlighterEnabled.toggle()
    }

    func load(rows: [Row], session: SpaceSession) async {
        remote = rows.compactMap(ReaderAnnotation.init(row:)).filter { $0.draftId == draftId && $0.scope == scope }
        if isWritable, outbox == nil {
            if let opened = await OutboxController.open(session: session) {
                outbox = opened
                let queued = waiting
                waiting = []
                // Persist selections made while the queue was opening before rebuilding the
                // optimistic layer. Otherwise a fast legacy-bookmark migration can disappear
                // for one render between the in-memory edit and the SQLite write.
                for mutation in queued { await transmitNow(mutation) }
            }
        }
        await rebuild()
    }

    func addHighlight(_ anchor: ReaderAnnotationAnchor, color: ReaderAnnotationColor) {
        guard isWritable else { return }
        let item = ReaderAnnotation(
            id: UUID().uuidString,
            draftId: draftId,
            scope: scope,
            kind: .highlight,
            color: color,
            anchor: anchor
        )
        upsert(item, title: String(localized: "Highlight in Deep Research"))
    }

    func updateHighlightColor(_ annotation: ReaderAnnotation, color: ReaderAnnotationColor) {
        guard isWritable, annotation.kind == .highlight, annotation.color != color else { return }
        let item = ReaderAnnotation(
            id: annotation.id,
            draftId: annotation.draftId,
            scope: annotation.scope,
            kind: .highlight,
            color: color,
            anchor: annotation.anchor,
            createdAt: annotation.createdAt,
            updatedAt: Date()
        )
        upsert(item, title: String(localized: "Highlight in Deep Research"))
    }

    func setBookmark(_ anchor: ReaderAnnotationAnchor) {
        guard isWritable else { return }
        let id = "reader-bookmark:\(draftId):\(scope)"
        let created = bookmark?.createdAt ?? Date()
        let item = ReaderAnnotation(
            id: id,
            draftId: draftId,
            scope: scope,
            kind: .bookmark,
            anchor: anchor,
            createdAt: created
        )
        upsert(item, title: String(localized: "Reading bookmark"))
    }

    func beginComment(_ anchor: ReaderAnnotationAnchor) {
        guard isWritable else { return }
        presentation = .newComment(anchor)
    }

    func saveNewComment(_ anchor: ReaderAnnotationAnchor, body: String) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isWritable, !text.isEmpty else { return }
        let item = ReaderAnnotation(
            id: UUID().uuidString,
            draftId: draftId,
            scope: scope,
            kind: .comment,
            anchor: anchor,
            comment: text
        )
        presentation = nil
        upsert(item, title: String(localized: "Comment in Deep Research"))
    }

    func updateComment(_ annotation: ReaderAnnotation, body: String) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isWritable, annotation.kind == .comment, !text.isEmpty else { return }
        let item = ReaderAnnotation(
            id: annotation.id,
            draftId: annotation.draftId,
            scope: annotation.scope,
            kind: .comment,
            anchor: annotation.anchor,
            comment: text,
            createdAt: annotation.createdAt,
            updatedAt: Date()
        )
        presentation = nil
        upsert(item, title: String(localized: "Comment in Deep Research"))
    }

    func open(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        switch item.kind {
        // A highlight is handled by the contextual ribbon anchored to the pressed words.
        case .highlight: break
        case .comment: presentation = .comment(item)
        case .bookmark: presentation = .bookmark(item)
        }
    }

    func delete(_ annotation: ReaderAnnotation) {
        guard isWritable else { return }
        items.removeAll { $0.id == annotation.id }
        presentation = nil
        let title: String
        switch annotation.kind {
        case .highlight: title = String(localized: "Delete highlight")
        case .comment: title = String(localized: "Delete comment")
        case .bookmark: title = String(localized: "Delete reading bookmark")
        }
        enqueueSync(.init(kind: .delete, rowId: annotation.id, row: nil, title: title))
    }

    func aimAtBookmark() {
        guard bookmark != nil else { return }
        bookmarkAim += 1
    }

    func dismissError() { error = nil }

    private func upsert(_ annotation: ReaderAnnotation, title: String) {
        items.removeAll { $0.id == annotation.id }
        items.append(annotation)
        sort()
        enqueueSync(.init(kind: .upsert, rowId: annotation.id, row: annotation.row, title: title))
    }

    private func enqueueSync(_ mutation: WaitingMutation) {
        guard outbox != nil else {
            waiting.append(mutation)
            return
        }
        transmit(mutation)
    }

    private func transmit(_ mutation: WaitingMutation) {
        Task { [weak self] in
            await self?.transmitNow(mutation)
        }
    }

    private func transmitNow(_ mutation: WaitingMutation) async {
        guard let outbox else { return }
        _ = await outbox.syncReaderAnnotation(
            kind: mutation.kind,
            rowId: mutation.rowId,
            row: mutation.row,
            title: mutation.title
        )
        error = outbox.lastError
        // Accepted and offline mutations remain in the optimistic overlay. Rejected rows do
        // not, so this also rolls back a server-refused edit to the last published value.
        await rebuild()
    }

    private func rebuild() async {
        let mutations: [Mutation]
        if let outbox {
            mutations = await outbox.retainedReaderAnnotationMutations()
        } else {
            mutations = []
        }
        items = Self.merged(remote: remote, mutations: mutations, draftId: draftId, scope: scope)
        sort()
    }

    /// Apply the durable mobile overlay with the same newest-write-wins rule as the desktop.
    /// Delivered mutations remain in the outbox briefly, but a later desktop edit from a new
    /// snapshot must be allowed to supersede them immediately rather than waiting for cleanup.
    static func merged(
        remote: [ReaderAnnotation],
        mutations: [Mutation],
        draftId: String,
        scope: String
    ) -> [ReaderAnnotation] {
        var merged = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        for mutation in mutations {
            switch mutation.kind {
            case .upsert:
                guard let row = mutation.row,
                      let annotation = ReaderAnnotation(row: Row(row)),
                      annotation.draftId == draftId,
                      annotation.scope == scope
                else { continue }
                if let published = merged[annotation.id], published.updatedAt > annotation.updatedAt { continue }
                merged[annotation.id] = annotation
            case .delete:
                guard let id = mutation.key.first else { continue }
                if let published = merged[id], published.updatedAt > mutation.createdAt { continue }
                merged[id] = nil
            }
        }
        return Array(merged.values)
    }

    private func sort() {
        items.sort {
            if $0.anchor.startOffset != $1.anchor.startOffset { return $0.anchor.startOffset < $1.anchor.startOffset }
            return $0.createdAt < $1.createdAt
        }
    }
}
