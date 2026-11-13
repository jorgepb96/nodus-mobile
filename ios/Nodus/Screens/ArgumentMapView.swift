import NodusKit
import NodusUI
import SwiftUI

/// The Argument Map catalogue and its closeable maps use the same workspace contract as
/// Desktop. Selecting another seed opens beside the current tree instead of destroying it.
struct ArgumentMapView: View {
    @Environment(WorkspaceTabs.self) private var workspaceTabs

    let session: SpaceSession
    /// Set when the workspace was opened from a specific idea rather than its catalogue.
    var seed: ArgumentSeed?

    var body: some View {
        Group {
            if session.connection.desktopPairingId != nil {
                SharedDesktopSurface(session: session, surface: .argument, initialArgumentSeed: seed?.id)
                    .id(seed?.id ?? "argument-catalogue")
            } else { legacyWorkspace }
        }
    }

    private var legacyWorkspace: some View {
        VStack(spacing: 0) {
            WorkspaceTabStrip(
                section: "argument",
                catalogueTitle: "Argument map",
                catalogueImage: "arrow.triangle.branch",
                accent: session.accent
            )
            ZStack {
                ArgumentSeedPicker(session: session, onPick: open)
                    .opacity(workspaceTabs.activeTabId(in: "argument") == nil ? 1 : 0)
                    .allowsHitTesting(workspaceTabs.activeTabId(in: "argument") == nil)
                    .accessibilityHidden(workspaceTabs.activeTabId(in: "argument") != nil)

                ForEach(workspaceTabs.tabs(in: "argument")) { tab in
                    if case .argumentSeed(let id, let label) = tab.payload {
                        ArgumentMapDocumentView(
                            session: session,
                            seed: ArgumentSeed(id: id, label: label),
                            onBackToCatalogue: { workspaceTabs.activateCatalog(in: "argument") }
                        )
                        .opacity(workspaceTabs.activeTabId(in: "argument") == tab.id ? 1 : 0)
                        .allowsHitTesting(workspaceTabs.activeTabId(in: "argument") == tab.id)
                        .accessibilityHidden(workspaceTabs.activeTabId(in: "argument") != tab.id)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-argument")
        .task(id: seed?.id) {
            if let seed { open(seed) }
        }
    }

    private func open(_ seed: ArgumentSeed) {
        workspaceTabs.open(
            WorkspaceTab(
                id: "argument:\(seed.id)",
                title: seed.label,
                systemImage: "arrow.triangle.branch",
                kind: .argumentMap,
                payload: .argumentSeed(id: seed.id, label: seed.label)
            ),
            in: "argument"
        )
    }
}

/// The argument map: one idea, and the argument that grows out of it.
///
/// The legacy publication reader builds the structural tree without a provider.
/// Paired companion routes use the shared Desktop renderer and both execution modes.
private struct ArgumentMapDocumentView: View {
    let session: SpaceSession
    let seed: ArgumentSeed
    let onBackToCatalogue: () -> Void

    @State private var map: ArgumentMap?
    @State private var expanded: Set<String> = []
    @State private var levels: [[String]] = []
    @State private var revealedLevels = 1
    @State private var isLoading = false
    @State private var error: String?
    @State private var mapTextSize = 1
    @State private var mapWidth: CGFloat = 860
    @State private var remoteState: String?

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
                ProgressView().tint(session.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Argument map")
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .toolbar {
            if map != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onBackToCatalogue()
                    } label: {
                        Image(systemName: "arrow.triangle.branch")
                    }
                    .tint(session.accent)
                    .accessibilityLabel("Another seed")
                }
            }
        }
        .task(id: session.publishedRevision) {
            await build(seed)
        }
    }

    // MARK: The map

    private func mapBody(_ map: ArgumentMap) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                header(map)
                displayControls
                if !levels.isEmpty { branchControls }
                ArgumentBlockTree(
                    block: map.root,
                    depth: 0,
                    expanded: $expanded,
                    accent: session.accent,
                    session: session
                )
            }
            .padding(NodusSpace.page)
            .frame(maxWidth: mapWidth)
            .frame(maxWidth: .infinity)
            .environment(\.dynamicTypeSize, mapTextSize == 0 ? .small : (mapTextSize == 2 ? .large : .medium))
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
            if let remoteState { Text(remoteState).font(.caption2).foregroundStyle(.secondary) }
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
    private var branchControls: some View {
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

    private var displayControls: some View {
        HStack(spacing: NodusSpace.card) {
            HStack(spacing: 0) {
                Button { mapTextSize = max(0, mapTextSize - 1) } label: { Image(systemName: "textformat.size.smaller").frame(width: 44, height: 44) }
                Divider().frame(height: 24)
                Button { mapTextSize = min(2, mapTextSize + 1) } label: { Image(systemName: "textformat.size.larger").frame(width: 44, height: 44) }
            }.reportActionSurface(accent: session.accent)
            HStack(spacing: 0) {
                Button { mapWidth = max(560, mapWidth - 100) } label: { Image(systemName: "arrow.left.and.line.vertical.and.arrow.right").frame(width: 44, height: 44) }
                Divider().frame(height: 24)
                Button { mapWidth = min(1180, mapWidth + 100) } label: { Image(systemName: "arrow.right.and.line.vertical.and.arrow.left").frame(width: 44, height: 44) }
            }.reportActionSurface(accent: session.accent)
            Button { Task { await generateAI() } } label: { Label("AI trace", systemImage: "wand.and.stars") }
                .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
                .disabled(session.isDemo || !session.canAuthor)
            Spacer(minLength: 0)
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

    private func generateAI() async {
        do {
            let result = try await session.client.createSpaceAction(
                idempotencyKey: "ios:argument-ai:\(session.connection.spaceId):\(seed.id):\(session.publishedRevision ?? "local")",
                kind: .argumentMapGenerate,
                payload: ["request": .object(["seedIdeaId": .string(seed.id), "mode": .string("ai")])],
                inputRevision: session.publishedRevision,
                executionMode:session.aiExecutionMode.rawValue, in:session.connection.spaceId
            )
            remoteState = result.action.receiptMessage
        } catch { remoteState = error.localizedDescription }
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

/// Desktop's ranked catalogue of grounded hubs. Search, the connection floor and the debate
/// bonus are local views over the server's canonical route projection, not a second ranking
/// assembled from a truncated Ideas page.
private struct ArgumentSeedPicker: View {
    let session: SpaceSession
    let onPick: (ArgumentSeed) -> Void

    @State private var query = ""
    @State private var routes: [ArgumentRouteSuggestion] = []
    @State private var minimumConnections = 2
    @State private var debateBonus = true
    @State private var order: RouteOrder = .recommended
    @State private var isLoading = false
    @State private var error: String?

    private enum RouteOrder: String, CaseIterable {
        case recommended, connections, debates, confidence, label
    }

    private var visible: [ArgumentRouteSuggestion] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = routes.enumerated().filter { _, route in
            route.degree >= minimumConnections && (needle.isEmpty || "\(route.label)\n\(route.statement)".lowercased().contains(needle))
        }

        // The server already returns the canonical recommended ranking. Keeping that order
        // avoids an expensive search for every comparison when a vault has thousands of hubs.
        if order == .recommended, debateBonus {
            return filtered.map(\.element)
        }

        return filtered.sorted { left, right in
            let lhs = left.element
            let rhs = right.element

            switch order {
            case .connections:
                if lhs.degree != rhs.degree { return lhs.degree > rhs.degree }
            case .debates:
                if lhs.debateCount != rhs.debateCount { return lhs.debateCount > rhs.debateCount }
                if lhs.degree != rhs.degree { return lhs.degree > rhs.degree }
            case .confidence:
                if lhs.avgConfidence != rhs.avgConfidence { return lhs.avgConfidence > rhs.avgConfidence }
                if lhs.degree != rhs.degree { return lhs.degree > rhs.degree }
            case .label:
                let comparison = lhs.label.localizedCaseInsensitiveCompare(rhs.label)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .recommended:
                if lhs.degree != rhs.degree { return lhs.degree > rhs.degree }
                if lhs.avgConfidence != rhs.avgConfidence { return lhs.avgConfidence > rhs.avgConfidence }
            }

            return left.offset < right.offset
        }
        .map(\.element)
    }

    var body: some View {
        List {
            Text("Ranked from the real idea graph. Rejected links are excluded before connectivity and debate scores are calculated.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            if let error {
                NodusNotice(tone: .blocked, title: "Could not load the ideas", message: LocalizedStringKey(error))
                    .listRowBackground(Color.clear)
            }

            if isLoading, routes.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().tint(session.accent)
                    Text("Ranking grounded hubs…")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(visible) { route in
                Button { onPick(ArgumentSeed(id: route.ideaId, label: route.label)) } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(route.label).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                            Spacer()
                            if route.debateCount > 0 { NodusChip("\(route.debateCount) debates", tint: .nodusCaution, capitalises: false) }
                        }
                        Text(route.statement).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        HStack(spacing: 12) {
                            Label("\(route.degree)", systemImage: "link")
                            Text(route.avgConfidence, format: .percent.precision(.fractionLength(0)))
                            ForEach(route.topRelations.prefix(2)) { NodusChip(RowDetailView.relationLabel($0.type), tint: session.accent.nodusReadable) }
                        }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        if !route.neighborLabels.isEmpty {
                            Text(route.neighborLabels.joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).listRowBackground(Color.clear)
                .accessibilityIdentifier("argument-route-\(route.ideaId)")
            }

            if visible.isEmpty, !isLoading, error == nil {
                ContentUnavailableView("No grounded hubs", systemImage: "arrow.triangle.branch", description: Text("Lower the connection floor or change the search."))
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .nodusDismissesKeyboard()
        .listStyle(.plain)
        .listRowSeparatorTint(Color.nodusTertiaryText.opacity(0.45))
        .safeAreaInset(edge: .top) {
            VStack(spacing: 9) {
                DesktopPageHeader(
                    title: "Argument map",
                    subtitle: "Grounded hubs ranked by connections and debate",
                    systemImage: "square.3.layers.3d",
                    accent: session.accent
                )
                NodusSearchField(text: $query, prompt: "Search ranked hubs", accent: session.accent, isBusy: isLoading)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        connectionFloor.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 8)
                        debateToggle
                        orderMenu
                    }
                    VStack(spacing: 8) {
                        connectionFloor
                        HStack(spacing: 8) {
                            debateToggle
                            Spacer(minLength: 8)
                            orderMenu
                        }
                    }
                }
            }
            .padding(.horizontal, NodusSpace.page)
            .padding(.vertical, 9)
            .background(Color(uiColor: .systemBackground).opacity(0.97))
        }
        .task(id: session.publishedRevision) { await load() }
    }

    private var connectionFloor: some View {
        Stepper("Minimum \(minimumConnections) links", value: $minimumConnections, in: 0...20)
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var debateToggle: some View {
        Toggle("Debate bonus", isOn: $debateBonus)
            .font(.caption)
            .fixedSize()
    }

    private var orderMenu: some View {
        Menu {
            Picker("Order", selection: $order) {
                Text("Recommended").tag(RouteOrder.recommended)
                Text("Connections").tag(RouteOrder.connections)
                Text("Debates").tag(RouteOrder.debates)
                Text("Confidence").tag(RouteOrder.confidence)
                Text("Label").tag(RouteOrder.label)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .buttonStyle(NodusGlassIconButtonStyle(accent: session.accent))
        .accessibilityLabel("Order argument routes")
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await session.client.argumentRoutes(in: session.connection.spaceId)
            guard !Task.isCancelled else { return }
            routes = loaded
            error = nil
#if DEBUG
            if ProcessInfo.processInfo.environment["NODUS_SHOW_TAB_DEMO"] == "1" {
                for route in loaded.prefix(2) { onPick(ArgumentSeed(id: route.ideaId, label: route.label)) }
            }
#endif
        } catch where error.isCancellation {} catch { self.error = error.localizedDescription }
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
        case .root: return String(localized: "seed")
        case .supports: return String(localized: "supports")
        case .refutes: return String(localized: "refutes")
        case .contradicts: return String(localized: "contradicts")
        case .extends: return String(localized: "extends")
        case .refines: return String(localized: "refines")
        case .appliesTo: return String(localized: "applies to")
        case .sharesMethod: return String(localized: "shares method")
        case .preconditionOf: return String(localized: "precondition of")
        case .measuresSame: return String(localized: "measures the same")
        case .variantOf: return String(localized: "variant of")
        case .related: return String(localized: "related")
        }
    }

    static func type(_ type: String) -> String {
        switch type {
        case "theme": return String(localized: "theme")
        case "claim": return String(localized: "claim")
        case "finding": return String(localized: "finding")
        case "construct": return String(localized: "construct")
        case "method": return String(localized: "method")
        case "framework": return String(localized: "framework")
        default: return type
        }
    }
}
