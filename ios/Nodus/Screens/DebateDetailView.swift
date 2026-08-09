import NodusKit
import NodusUI
import SwiftUI

/// The published shape behind a contradiction citation.
///
/// A contradiction is an edge, but the mobile corpus publishes it through the derived
/// `debates` resource. The endpoint includes both positions and their evidence; flattening it
/// to a generic field list would reduce those objects to "5 fields" and hide the very source a
/// reader opened the citation to inspect.
struct DebateCitation {
    struct Side {
        let label: String
        let statement: String?

        init(_ value: JSONValue?) {
            let object = value?.objectValue ?? [:]
            let statement = Self.text(object["statement"])
            self.label = Self.text(object["label"]) ?? statement ?? "—"
            self.statement = statement == self.label ? nil : statement
        }

        private static func text(_ value: JSONValue?) -> String? {
            guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return nil }
            return text
        }
    }

    struct Evidence {
        let quote: String
        let location: String?
        let kind: String?
        let side: String?
    }

    let relation: String
    let basis: String?
    let confidence: Double?
    let tension: String?
    let sideA: Side
    let sideB: Side
    let evidence: [Evidence]

    init(_ row: Row) {
        relation = row.text("relation") ?? "contradicts"
        basis = row.text("basis")
        confidence = row.double("confidence")
        tension = row.text("tension") ?? row.text("explanation")
        sideA = Side(row["sideA"])
        sideB = Side(row["sideB"])

        let nested = Self.evidence(in: row["sideA"], side: "A")
            + Self.evidence(in: row["sideB"], side: "B")
        evidence = nested.isEmpty ? Self.evidence(values: row["evidence"]?.arrayValue ?? [], side: nil) : nested
    }

    private static func evidence(in side: JSONValue?, side label: String) -> [Evidence] {
        let works = side?.objectValue?["works"]?.arrayValue ?? []
        return works.flatMap { work in
            evidence(values: work.objectValue?["evidence"]?.arrayValue ?? [], side: label)
        }
    }

    private static func evidence(values: [JSONValue], side: String?) -> [Evidence] {
        values.compactMap { value in
            guard let object = value.objectValue,
                  let quote = text(object["quote"] ?? object["text"])
            else { return nil }
            return Evidence(
                quote: quote,
                location: text(object["location"] ?? object["page_label"]),
                kind: text(object["kind"] ?? object["basis"]),
                side: side
            )
        }
    }

    private static func text(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }
}

/// Resolves a `nodus://contradiction/<edge-id>` against the same debate endpoint used by the
/// mobile Debates section. This works against a server publication and against the offline demo
/// corpus because both implement `NodusClient.debate`.
struct DebateByIdView: View {
    let session: SpaceSession
    let edgeId: String

    private enum Problem: Equatable { case missing, failed }

    @State private var row: Row?
    @State private var problem: Problem?

    var body: some View {
        Group {
            if let row {
                DebateCitationView(debate: DebateCitation(row), accent: session.accent)
            } else if problem == .missing {
                ContentUnavailableView(
                    "Cited contradiction not found",
                    systemImage: "questionmark.circle",
                    description: Text("The published corpus no longer contains this contradiction.")
                )
            } else if problem == .failed {
                ContentUnavailableView(
                    "Could not open",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The contradiction could not be loaded from this space.")
                )
            } else {
                ProgressView().tint(session.accent)
            }
        }
        .navigationTitle("Cited source")
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .task {
            guard row == nil, problem == nil else { return }
            do {
                row = try await session.client.debate(edgeId, in: session.connection.spaceId)
            } catch let error as APIError where error.isNotFound {
                problem = .missing
            } catch where error.isCancellation {
                // The sheet closed while the source was loading.
            } catch {
                problem = .failed
            }
        }
    }
}

private struct DebateCitationView: View {
    let debate: DebateCitation
    let accent: Color

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                heading
                positions
                if !debate.evidence.isEmpty { evidence }
            }
            .padding(NodusSpace.page)
            .nodusTopAnchor()
        }
        .nodusPageFunctions(accent: accent)
        .nodusHidesBottomBar()
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                NodusChip(
                    localizedRelation,
                    tint: SemanticTone.relation(debate.relation, fallback: accent)
                )
                if let basis = debate.basis {
                    NodusChip(key: basis, tint: basis == "explicit" ? .green : .orange)
                }
                if let confidence = debate.confidence {
                    NodusChip(
                        String(localized: "Confidence \(confidence.formatted(.number.precision(.fractionLength(2))))"),
                        tint: accent.nodusReadable,
                        capitalises: false
                    )
                }
            }
            Text("Cited contradiction")
                .font(.title3.weight(.semibold))
            if let tension = debate.tension {
                Text(tension)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(NodusSpace.cardPadding)
        .nodusGlass(NodusGlass(.regular, tint: accent))
    }

    private var positions: some View {
        VStack(alignment: .leading, spacing: 9) {
            NodusSectionLabel("Positions")
            VStack(alignment: .leading, spacing: 14) {
                side(debate.sideA, label: "A")
                HStack(spacing: 10) {
                    Divider()
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(SemanticTone.relation("contradicts", fallback: accent))
                    Divider()
                }
                side(debate.sideB, label: "B")
            }
            .padding(NodusSpace.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nodusGlass(NodusGlass(.thin, tint: accent))
        }
    }

    private func side(_ side: DebateCitation.Side, label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            NodusChip(label, tint: accent.nodusReadable, capitalises: false)
            Text(side.label)
                .font(.headline)
                .textSelection(.enabled)
            if let statement = side.statement {
                Text(statement)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var evidence: some View {
        VStack(alignment: .leading, spacing: 9) {
            NodusSectionLabel("Evidence", count: debate.evidence.count)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(debate.evidence.enumerated()), id: \.offset) { index, item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("“\(item.quote)”")
                            .font(.callout)
                            .italic()
                            .textSelection(.enabled)
                            .padding(.leading, 11)
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(SemanticTone.relation("contradicts", fallback: accent).opacity(0.65))
                                    .frame(width: 2)
                            }
                        HStack(spacing: 6) {
                            if let side = item.side {
                                NodusChip(side, tint: accent.nodusReadable, capitalises: false)
                            }
                            if let location = item.location {
                                NodusChip(location, tint: .nodusSecondaryText, capitalises: false)
                            }
                            if let kind = item.kind {
                                NodusChip(key: kind, tint: accent.nodusReadable)
                            }
                        }
                    }
                    .padding(.vertical, 10)
                    if index < debate.evidence.count - 1 { Divider().opacity(0.35) }
                }
            }
            .padding(.horizontal, NodusSpace.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nodusGlass(NodusGlass(.thin, tint: accent))
        }
    }

    private var localizedRelation: String {
        let key = RowDetailView.relationLabel(debate.relation)
        return Bundle.main.localizedString(forKey: key, value: debate.relation, table: nil)
    }
}
