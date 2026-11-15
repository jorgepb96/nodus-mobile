import NodusKit
import NodusUI
import SwiftUI

/// Complete structured workshop output, presented as touch-friendly sections.
/// Evidence matrices use stacked rows on a phone rather than a wide table.
struct WorkshopDraftSections: View {
    let draft: JSONValue
    let session: SpaceSession
    private var value: [String: JSONValue] { draft.objectValue ?? [:] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let outline = value["outline"]?.arrayValue, !outline.isEmpty {
                DisclosureGroup("Esquema (\(outline.count))") {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(outline.enumerated()), id: \.offset) { _, section in
                            if let body = section.objectValue {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(body["title"]?.stringValue ?? "Sección").font(.headline).fixedSize(horizontal: false, vertical: true)
                                    prose(body["purpose"])
                                    strings(body["keyClaims"], links: false)
                                    strings(body["sources"], links: true)
                                }
                            }
                        }
                    }.padding(.vertical, 12)
                }
            }
            if let matrix = value["matrix"]?.arrayValue, !matrix.isEmpty {
                DisclosureGroup("Matriz de evidencias (\(matrix.count))") {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(matrix.enumerated()), id: \.offset) { _, row in
                            if let body = row.objectValue {
                                VStack(alignment: .leading, spacing: 8) {
                                    if let role = body["role"]?.stringValue { NodusChip(key: role, tint: session.accent) }
                                    prose(body["claim"])
                                    if let citation = body["citation"]?.stringValue, citation.hasPrefix("nodus://") {
                                        CorpusProse("[\(body["sourceLabel"]?.stringValue ?? citation)](\(citation))", accent: session.accent, session: session)
                                    } else { prose(body["sourceLabel"]) }
                                    prose(body["evidence"]); prose(body["notes"])
                                }.padding(12).background(session.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }.padding(.vertical, 12)
                }
            }
            section("Bibliografía", key: "bibliography")
            section("Siguientes pasos", key: "nextSteps")
            section("Limitaciones", key: "limitations")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func prose(_ value: JSONValue?) -> some View {
        if let text = value?.stringValue, !text.isEmpty { CorpusProse(text, accent: session.accent, session: session) }
    }
    @ViewBuilder private func strings(_ value: JSONValue?, links: Bool) -> some View {
        if let values = value?.arrayValue {
            ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                if let text = item.stringValue, !text.isEmpty {
                    CorpusProse(links && text.hasPrefix("nodus://") ? "[\(text)](\(text))" : text, accent: session.accent, session: session)
                }
            }
        }
    }
    @ViewBuilder private func section(_ title: String, key: String) -> some View {
        if let items = value[key]?.arrayValue, !items.isEmpty {
            DisclosureGroup("\(title) (\(items.count))") {
                VStack(alignment: .leading, spacing: 10) { strings(.array(items), links: true) }.padding(.vertical, 12)
            }
        }
    }
}
