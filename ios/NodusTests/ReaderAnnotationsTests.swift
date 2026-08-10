import Foundation
import NodusKit
import Testing
import UIKit
@testable import Nodus

@Suite("Reader annotation anchors")
@MainActor
struct ReaderAnnotationsTests {
    @Test("a mobile selection becomes the same UTF-16 anchor the desktop uses")
    func anchorRoundTrip() throws {
        let blocks = ["Introducción 😀", "La memoria compartida sostiene el archivo."]
        let document = ReaderAnnotationDocument(blocks: blocks)
        let range = (blocks[1] as NSString).range(of: "memoria compartida")
        let anchor = try #require(document.anchor(block: 1, range: range))

        #expect(anchor.endOffset - anchor.startOffset == (anchor.selectedText as NSString).length)
        #expect(anchor.prefix.hasSuffix("Introducción 😀\nLa "))
        #expect(anchor.suffix.hasPrefix(" sostiene"))

        let item = ReaderAnnotation(
            id: "h-1",
            draftId: "r-1",
            kind: .highlight,
            color: .lavender,
            anchor: anchor
        )
        let placement = try #require(document.placements(for: 1, annotations: [item], bookmarkAim: 0).first)
        #expect(placement.range == range)
        #expect((blocks[1] as NSString).substring(with: placement.range) == "memoria compartida")
    }

    @Test("text and context recover an anchor after rendering offsets move")
    func fallbackRecoversMovedText() throws {
        let text = "Preámbulo nuevo. La memoria aparece aquí. La memoria aparece después."
        let document = ReaderAnnotationDocument(blocks: [text])
        let wanted = (text as NSString).range(of: "memoria", options: [], range: NSRange(location: 25, length: 35))
        let anchor = ReaderAnnotationAnchor(
            startOffset: 2,
            endOffset: 9,
            selectedText: "memoria",
            prefix: "aquí. La ",
            suffix: " aparece después."
        )
        let comment = ReaderAnnotation(
            id: "c-1",
            draftId: "r-1",
            kind: .comment,
            anchor: anchor,
            comment: "La segunda aparición."
        )

        let placement = try #require(document.placements(for: 0, annotations: [comment], bookmarkAim: 0).first)
        #expect(placement.range == wanted)
    }

    @Test("a desktop row decodes and returns to the mutation wire without losing fields")
    func wireRoundTrip() throws {
        let row = Row([
            "id": .string("reader-bookmark:r-1:source"),
            "draft_id": .string("r-1"),
            "scope": .string("source"),
            "kind": .string("bookmark"),
            "color": .null,
            "start_offset": .int(4),
            "end_offset": .int(9),
            "selected_text": .string("texto"),
            "prefix": .string("El "),
            "suffix": .string(" sigue"),
            "comment_text": .null,
            "created_at": .string("2026-08-10T00:00:00.000Z"),
            "updated_at": .string("2026-08-10T00:00:00.000Z"),
        ])
        let annotation = try #require(ReaderAnnotation(row: row))

        #expect(annotation.kind == .bookmark)
        #expect(annotation.row["id"]?.stringValue == "reader-bookmark:r-1:source")
        #expect(annotation.row["selected_text"]?.stringValue == "texto")
        #expect(annotation.row["color"]?.isNull == true)
    }

    @Test("all six pastel identifiers match the desktop contract")
    func paletteContract() {
        #expect(ReaderAnnotationColor.allCases.map(\.rawValue) == [
            "yellow", "rose", "blue", "mint", "lavender", "peach",
        ])
    }

    @Test("the highlight menu uses six original-colour raster swatches")
    func menuSwatchesKeepTheirColours() throws {
        let traits = UITraitCollection(userInterfaceStyle: .dark)
        let images = ReaderAnnotationColor.allCases.map {
            ReaderHighlightMenuSwatch.image(for: $0, selected: false, traits: traits)
        }

        #expect(images.allSatisfy { $0.renderingMode == .alwaysOriginal })
        #expect(images.allSatisfy { $0.cgImage != nil })
        let encoded = try images.map { try #require($0.pngData()) }
        #expect(Set(encoded).count == ReaderAnnotationColor.allCases.count)
    }

    @Test("the highlighter toggle preserves the independently selected colour")
    func highlighterControls() {
        let annotations = ReaderAnnotations(draftId: "r-1", isWritable: true)
        #expect(annotations.selectedColor == .yellow)
        #expect(annotations.fixedColor == nil)

        annotations.selectedColor = .mint
        annotations.toggleHighlighter()
        #expect(annotations.fixedColor == .mint)

        annotations.toggleHighlighter()
        #expect(annotations.fixedColor == nil)
        #expect(annotations.selectedColor == .mint)
    }

    @Test("an existing highlight keeps its anchor when its colour changes")
    func changesHighlightColor() throws {
        let annotations = ReaderAnnotations(draftId: "r-1", isWritable: true)
        let anchor = ReaderAnnotationAnchor(
            startOffset: 4,
            endOffset: 9,
            selectedText: "texto",
            prefix: "El ",
            suffix: " sigue"
        )
        let original = ReaderAnnotation(
            id: "h-1",
            draftId: "r-1",
            kind: .highlight,
            color: .yellow,
            anchor: anchor
        )

        annotations.updateHighlightColor(original, color: .blue)

        let changed = try #require(annotations.items.first)
        #expect(changed.id == original.id)
        #expect(changed.anchor == anchor)
        #expect(changed.color == .blue)
    }

    @Test("a continuous highlighter includes both endpoints in either direction")
    func continuousHighlightRange() {
        #expect(ReaderHighlightStroke.range(from: 4, through: 9) == NSRange(location: 4, length: 6))
        #expect(ReaderHighlightStroke.range(from: 9, through: 4) == NSRange(location: 4, length: 6))
        #expect(ReaderHighlightStroke.range(from: 7, through: 7) == NSRange(location: 7, length: 1))
    }

    @Test("references split a highlight instead of receiving ink")
    func highlightSkipsReferences() throws {
        let text = NSMutableAttributedString(string: "Antes Idea después")
        let reference = (text.string as NSString).range(of: "Idea")
        text.addAttribute(
            .nodusReference,
            value: try #require(URL(string: "nodus://idea/i-1")),
            range: reference
        )

        let ranges = ReaderHighlightSegments.ranges(
            in: NSRange(location: 0, length: text.length),
            excludingReferencesIn: text
        )

        #expect(ranges == [
            NSRange(location: 0, length: reference.location),
            NSRange(location: NSMaxRange(reference), length: text.length - NSMaxRange(reference)),
        ])
        #expect(ReaderHighlightSegments.ranges(in: reference, excludingReferencesIn: text).isEmpty)
    }

    @Test("the newest side wins while delivered mobile changes await cleanup")
    func optimisticOverlayConverges() throws {
        let old = Date(timeIntervalSince1970: 1_000)
        let middle = Date(timeIntervalSince1970: 2_000)
        let newest = Date(timeIntervalSince1970: 3_000)
        let anchor = ReaderAnnotationAnchor(
            startOffset: 0,
            endOffset: 5,
            selectedText: "Texto",
            prefix: "",
            suffix: " sigue"
        )
        let published = ReaderAnnotation(
            id: "h-1",
            draftId: "r-1",
            kind: .highlight,
            color: .blue,
            anchor: anchor,
            createdAt: old,
            updatedAt: newest
        )
        let staleMobile = ReaderAnnotation(
            id: "h-1",
            draftId: "r-1",
            kind: .highlight,
            color: .rose,
            anchor: anchor,
            createdAt: old,
            updatedAt: middle
        )
        let oldUpsert = Mutation(
            id: "mut-upsert",
            clientId: "phone",
            kind: .upsert,
            table: .writingDraftAnnotations,
            key: ["h-1"],
            row: staleMobile.row,
            schemaVersion: 127,
            createdAt: middle
        )
        let oldDelete = Mutation(
            id: "mut-delete",
            clientId: "phone",
            kind: .delete,
            table: .writingDraftAnnotations,
            key: ["h-1"],
            schemaVersion: 127,
            createdAt: middle
        )

        var result = ReaderAnnotations.merged(
            remote: [published],
            mutations: [oldUpsert, oldDelete],
            draftId: "r-1",
            scope: "source"
        )
        #expect(result.first?.color == .blue, "a later desktop edit must not be hidden for 24 hours")

        let freshDelete = Mutation(
            id: "mut-delete-new",
            clientId: "phone",
            kind: .delete,
            table: .writingDraftAnnotations,
            key: ["h-1"],
            schemaVersion: 127,
            createdAt: newest.addingTimeInterval(1)
        )
        result = ReaderAnnotations.merged(
            remote: [published],
            mutations: [freshDelete],
            draftId: "r-1",
            scope: "source"
        )
        #expect(result.isEmpty, "a newer local deletion stays optimistic until publication")
    }
}
