import NodusKit
import NodusUI
import SwiftUI

/// The argument map: one idea, and the argument that grows out of it.
///
/// The desktop offers two modes — an AI trace and a structural one built from the real edges.
/// This is the structural one, because it needs no model, no key and no money: the server
/// already serves the ego graph, and the tree is arithmetic over it
/// (`ArgumentMapBuilder.structural`). What the model would add is a gloss, and a gloss is the
/// part a phone can most easily do without.
struct ArgumentMapView: View {
    let session: SpaceSession
    /// Set when the map was opened from a specific idea rather than from the seed picker.
    var seed: ArgumentSeed?

    @State private var chosen: ArgumentSeed?
    @State private var map: ArgumentMap?
    @State private var expanded: Set<String> = []
    @State private var levels: [[String]] = []
    @State private var revealedLevels = 1
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        Group {
            if let map {
                mapBody(map)
            } else if isLoading {
                ProgressView().tint(session.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView {
                    Label("Could not draw the map", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else {
                ArgumentSeedPicker(session: session) { picked in
                    chosen = picked
                    Task { await build(picked) }
                }
            }
        }
        .navigationTitle("Argument map")
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .toolbar {
            if map != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        map = nil
                        chosen = nil
                        expanded = []
                        revealedLevels = 1
                    } label: {
                        Image(systemName: "arrow.triangle.branch")
                    }
                    .tint(session.accent)
                    .accessibilityLabel("Another seed")
                }
            }
        }
        .task(id: session.publishedRevision) {
            if let chosen {
                await build(chosen)
                return
            }
            guard map == nil, let seed, chosen == nil else { return }
            chosen = seed
            await build(seed)
        }
    }

    // MARK: The map

    private func mapBody(_ map: ArgumentMap) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                header(map)
                if !levels.isEmpty { controls }
                ArgumentBlockTree(
                    block: map.root,
                    depth: 0,
                    expanded: $expanded,
                    accent: session.accent,
                    session: session
                )
            }
            .padding(NodusSpace.page)
        }
        // A map is a document too, and the four tabs under it are four ways to lose your place
        // in a tree you have just spent six taps unfolding.
        .nodusHidesBottomBar()
    }

    private func header(_ map: ArgumentMap) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(map.seedLabel)
                .font(.headline)
                .lineLimit(4)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Label("\(map.blockCount)", systemImage: "square.stack.3d.up")
                Label("\(map.seedDegree)", systemImage: "link")
                if map.seedDebates > 0 {
                    Label("\(map.seedDebates)", systemImage: "bolt.horizontal")
                        .foregroundStyle(Color.nodusCaution)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // The map is drawn from the neighbourhood the server sent, and the server caps it.
            // Saying so keeps a partial argument from reading as the whole one.
            if map.truncated {
                Text("Drawn from the \(map.ideaCount) closest ideas. This space has more; the map is a real part of the argument, not all of it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(NodusSpace.cardPadding)
        .nodusGlass(NodusGlass(.regular, tint: session.accent))
    }

    /// The two controls, outside the card rather than inside it.
    ///
    /// They used to be the last row of the header card, in the same glass and the same weight as
    /// the three counts above them, so "Unfold a level" and "Collapse" read as two more facts
    /// about the map rather than as the only two things on the screen you can do to it. Out on
    /// the page, filled and outlined in the accent, they are unmistakably controls — and the two
    /// of them are now the only accent-filled objects on this screen, which is the point.
    private var controls: some View {
        HStack(spacing: NodusSpace.card) {
            Button {
                revealLevel()
            } label: {
                Label("Unfold a level", systemImage: "plus.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
            .disabled(revealedLevels >= levels.count)

            Button {
                withAnimation(NodusMotion.standard) {
                    expanded = []
                    revealedLevels = 0
                }
            } label: {
                Label("Collapse", systemImage: "arrow.down.right.and.arrow.up.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
            .disabled(expanded.isEmpty)
        }
    }

    /// Open one more level of the tree, everywhere at once.
    ///
    /// The levels are contiguous by construction — a block only reaches depth d when every
    /// ancestor above it has children — so revealing level n never leaves an orphan expanded
    /// under a collapsed parent.
    private func revealLevel() {
        guard revealedLevels < levels.count else { return }
        withAnimation(NodusMotion.standard) {
            expanded.formUnion(levels[revealedLevels])
            revealedLevels += 1
        }
    }

    private func build(_ seed: ArgumentSeed) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let graph = try await session.client.ideaGraph(
                seed.id,
                in: session.connection.spaceId,
                depth: ArgumentMapBuilder.maxDepth,
                limit: 400
            )
            guard let built = ArgumentMapBuilder.structural(from: graph, seedId: seed.id) else {
                error = String(localized: "This idea is not in the published graph.")
                return
            }
            map = built
            levels = built.expandableIdsByDepth
            // Open the seed, and only the seed. A map that arrives fully unfolded is a wall.
            expanded = Set(levels.first ?? [])
            revealedLevels = 1
        } catch where error.isCancellation {
            // Superseded or let go of. Nothing failed, so nothing is reported.
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The idea a map grows from.
struct ArgumentSeed: Identifiable, Hashable {
    let id: String
    let label: String

    init?(_ row: Row) {
        guard let id = row.string("global_id") else { return nil }
        self.id = id
        label = row.text("label") ?? row.text("statement") ?? id
    }

    init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// Choosing where the argument starts.
///
/// The desktop ranks hubs by connectivity over the whole graph; a phone holds no such index, so
/// this asks the corpus instead — the same search the Ideas section uses — and says plainly
/// that it is a search rather than a ranking.
private struct ArgumentSeedPicker: View {
    let session: SpaceSession
    let onPick: (ArgumentSeed) -> Void

    @State private var query = ""
    @State private var rows: [Row] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        List {
            // An ordinary row rather than a section footer: a footer keeps the list's own
            // opaque backing, which over the accent backdrop drew as a black band across the
            // one sentence this screen most wants read.
            Text("The map grows from one idea, following the relations the analysis found: what supports it, what refines it, and what argues against it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            if let error {
                NodusNotice(tone: .blocked, title: "Could not load the ideas", message: LocalizedStringKey(error))
                    .listRowBackground(Color.clear)
            }

            // A screen whose only content is a sentence about what the map does, held for as
            // long as a corpus of ten thousand ideas takes to answer, reads as a screen that
            // has failed. It is fetching; it should say so.
            if isLoading, rows.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().tint(session.accent)
                    Text("Reading the ideas in this space…")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if let seed = ArgumentSeed(row) {
                    Button {
                        onPick(seed)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(seed.label).font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            if let statement = row.text("statement"), statement != seed.label {
                                Text(statement).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .listRowBackground(Color.clear)
                }
            }

            if rows.isEmpty, !isLoading, error == nil {
                ContentUnavailableView("No ideas", systemImage: "lightbulb")
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .nodusDismissesKeyboard()
        .listStyle(.plain)
        .listRowSeparatorTint(Color.nodusTertiaryText.opacity(0.45))
        .safeAreaInset(edge: .top) {
            NodusSearchField(
                text: $query,
                prompt: "Find the idea to start from",
                accent: session.accent,
                isBusy: isLoading
            )
        }
        .onChange(of: query) { _, _ in schedule() }
        .task(id: session.publishedRevision) {
            let current = query.trimmingCharacters(in: .whitespacesAndNewlines)
            await load(current.isEmpty ? nil : current)
        }
    }

    private func schedule() {
        searchTask?.cancel()
        let current = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            await load(current.isEmpty ? nil : current)
        }
    }

    private func load(_ text: String?) async {
        guard let ideas = Collections["ideas"] else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await session.client.list(ideas, in: session.connection.spaceId, query: text, limit: 60)
            guard !Task.isCancelled else { return }
            rows = page.items
            error = nil
        } catch is CancellationError {
            // Superseded.
        } catch where error.isCancellation {
            // Superseded or let go of. Nothing failed, so nothing is reported.
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One block and, when it is open, its branch.
private struct ArgumentBlockTree: View {
    let block: ArgumentBlock
    let depth: Int
    @Binding var expanded: Set<String>
    let accent: Color
    let session: SpaceSession

    private var isExpanded: Bool { expanded.contains(block.id) }
    private var relationAccent: Color { SemanticTone.relation(block.relation.rawValue, fallback: accent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            card

            if !block.children.isEmpty, isExpanded {
                // Only the wrapper animates. Animating the card itself scale-corrects its own
                // text, which leaves a collapsed card stretched to the height the whole branch
                // used to take — the same trap the desktop hit.
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(block.children) { child in
                        ArgumentBlockTree(
                            block: child,
                            depth: depth + 1,
                            expanded: $expanded,
                            accent: accent,
                            session: session
                        )
                    }
                }
                // A wider indent and a real line, in the colour of the edge the branch hangs
                // from. A one-point hairline in `.quaternary` at a fourteen-point indent is
                // invisible at arm's length, which left three levels of a tree looking like one
                // list of cards that happened to start at slightly different places.
                .padding(.leading, 18)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(relationAccent.opacity(0.45))
                        .frame(width: 2)
                        .padding(.vertical, 2)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 9) {
            // The relation, as a stripe. It is the whole reason a branch is where it is.
            Capsule()
                .fill(relationAccent)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    NodusChip(
                        key: ArgumentLabels.type(block.type),
                        tint: SemanticTone.ideaType(block.type, fallback: accent)
                    )
                    if block.relation != .root {
                        NodusChip(
                            key: ArgumentLabels.relation(block.relation),
                            tint: relationAccent,
                            systemImage: "arrow.turn.right.up"
                        )
                    }
                }

                Text(block.label)
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)

                // The seed carries its statement; the branches carry the edge that put them
                // there. Showing every statement turns the map into a wall of prose.
                if depth == 0, !block.statement.isEmpty {
                    Text(block.statement).font(.caption).foregroundStyle(.secondary)
                }

                if block.relation != .root || block.hiddenChildren > 0 { metadata }
            }

            Spacer(minLength: 0)

            if !block.children.isEmpty {
                Button {
                    withAnimation(NodusMotion.standard) {
                        if isExpanded { expanded.remove(block.id) } else { expanded.insert(block.id) }
                    }
                } label: {
                    // The count of what is under here belongs *on* the control that opens it,
                    // not floated in the corner of the card below the text: the two were
                    // separate before, so a reader had to connect a number in the bottom right
                    // with a plus button in the top right to learn that pressing one revealed
                    // the other.
                    VStack(spacing: 1) {
                        Image(systemName: isExpanded ? "minus" : "plus")
                            .font(.caption.weight(.bold))
                        if block.descendantCount > 0, !isExpanded {
                            Text("\(block.descendantCount)")
                                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        }
                    }
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent.nodusReadable)
                .accessibilityLabel(isExpanded ? "Collapse the branch" : "Unfold the branch")
            }
        }
        .padding(11)
        // No accent border. Every block in a hundred-and-sixty-block tree wore one, which is
        // the clearest case in the app of an outline that told a reader nothing: the stripe on
        // the left already says what kind of block this is.
        .nodusGlass(NodusGlass(.thin, tint: accent), in: NodusRadius.controlShape)
    }

    /// The three numbers on one line, as tags.
    ///
    /// They used to be a sentence in `caption2` ("confidence 0.82 · 3 derivations"), a second
    /// line in `tertiary` for the links not drawn, and a floating number in the card's bottom
    /// corner — three typographic treatments for three facts of exactly the same weight, on a
    /// card whose subject is one line of text above them.
    private var metadata: some View {
        // A wrapping layout rather than an `HStack`: three chips of text that grows with Dynamic
        // Type do not fit across a card that is already indented three levels deep, and a row
        // that overflows clips its last chip rather than dropping to a second line.
        FlowLayout(spacing: 5) {
            if block.relation != .root {
                NodusChip(String(format: "%.2f", block.confidence), tint: .nodusSecondaryText)
            }
            if !block.children.isEmpty {
                NodusChip(
                    String(localized: "\(block.children.count) derivations"),
                    tint: .nodusSecondaryText
                )
            }
            if block.hiddenChildren > 0 {
                NodusChip(
                    String(localized: "+\(block.hiddenChildren) not drawn"),
                    tint: .nodusTertiaryText
                )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Confidence \(String(format: "%.2f", block.confidence))"))
    }
}

/// The words for a relation and an idea type, matching the desktop's own.
enum ArgumentLabels {
    static func relation(_ relation: ArgumentRelation) -> String {
        switch relation {
        case .root: return "seed"
        case .supports: return "supports"
        case .refutes: return "refutes"
        case .contradicts: return "contradicts"
        case .extends: return "extends"
        case .refines: return "refines"
        case .appliesTo: return "applies to"
        case .sharesMethod: return "shares method"
        case .preconditionOf: return "precondition of"
        case .measuresSame: return "measures the same"
        case .variantOf: return "variant of"
        case .related: return "related"
        }
    }

    static func type(_ type: String) -> String {
        switch type {
        case "theme": return "theme"
        case "claim": return "claim"
        case "finding": return "finding"
        case "construct": return "construct"
        case "method": return "method"
        case "framework": return "framework"
        default: return type
        }
    }
}
