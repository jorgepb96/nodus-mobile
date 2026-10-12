import NodusKit
import NodusUI
import SwiftUI

/// Recorded kinship can be consulted as focused relatives or as a complete,
/// pannable pedigree. Both use the same authenticated/offline corpus reads.
struct FamilyTreeView: View {
    let session: SpaceSession
    /// Where to start. Nil opens on whoever has the most relatives, which is nearly always the
    /// person the vault is actually about.
    var rootPersonId: String?

    @State private var focus: Row?
    @State private var parents: [Row] = []
    @State private var children: [Row] = []
    @State private var partners: [Row] = []
    @State private var siblings: [Row] = []
    @State private var people: [String: Row] = [:]
    @State private var relationships: [Row] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var history: [String] = []
    @State private var query = ""
    @State private var showPedigree = false
    @State private var ancestorsAbove = true
    @State private var paternalVisible = true
    @State private var maternalVisible = true
    @State private var paternalColor = Color.blue
    @State private var maternalColor = Color.pink
    @State private var zoom = 1.0

    private var projection: FamilyTreeProjection {
        FamilyTreeProjection(people: Array(people.values), relationships: relationships)
    }

    /// REST rows become available as soon as the publication changes; portrait assets become
    /// available after the optional mirror has finished importing that same revision.
    private var loadID: String {
        "\(session.publishedRevision ?? "unpublished"):\(session.mirrorSummary?.revision ?? "no-mirror")"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let error {
                    NodusNotice(tone: .blocked, title: "Could not build the tree", message: LocalizedStringKey(error))
                }

                if isLoading, focus == nil {
                    ProgressView().tint(session.accent).padding(.top, 60)
                } else if let focus {
                    treeControls
                    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { searchResults }
                    if showPedigree {
                        pedigree
                        focusCard(focus)
                    } else {
                        generation(parents, title: "Parents", icon: "arrow.up")
                        focusCard(focus)
                        if !partners.isEmpty {
                            generation(partners, title: "Partner", icon: "heart")
                        }
                        if !siblings.isEmpty {
                            generation(siblings, title: "Siblings", icon: "arrow.left.and.right")
                        }
                        generation(children, title: "Children", icon: "arrow.down")

                        if parents.isEmpty, children.isEmpty, partners.isEmpty, siblings.isEmpty {
                            Text("This person has no relationships recorded in the publication.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .padding(.top, 12)
                        }
                    }
                } else if !isLoading {
                    ContentUnavailableView(
                        "No people",
                        systemImage: "person.2",
                        description: Text("This publication carries no people or relationships.")
                    )
                }
            }
            .padding(16)
        }
        .nodusHidesBottomBar()
        .navigationTitle("Family tree")
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .toolbar {
            if !history.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        guard let previous = history.popLast() else { return }
                        refocus(on: previous, remember: false)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .tint(session.accent)
                }
            }
        }
        .task(id: loadID) { await load() }
        .accessibilityIdentifier("genealogy-family-tree")
    }

    // MARK: Pieces

    private var treeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            NodusSearchField(text: $query, prompt: "Find a person", accent: session.accent, isBusy: false)
                .accessibilityIdentifier("family-tree-search")
            Picker("Tree view", selection: $showPedigree) {
                Text("Relatives").tag(false)
                Text("Pedigree").tag(true)
            }.pickerStyle(.segmented).accessibilityIdentifier("family-tree-mode")
            if showPedigree {
                DisclosureGroup("Tree controls") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Orientation", selection: $ancestorsAbove) {
                            Text("Ancestors above").tag(true)
                            Text("Descendants above").tag(false)
                        }.pickerStyle(.segmented).accessibilityIdentifier("family-tree-orientation")
                        Toggle("Paternal branch", isOn: $paternalVisible).accessibilityIdentifier("family-tree-paternal-visible")
                        ColorPicker("Paternal branch color", selection: $paternalColor, supportsOpacity: false)
                            .accessibilityIdentifier("family-tree-paternal-color")
                        Toggle("Maternal branch", isOn: $maternalVisible).accessibilityIdentifier("family-tree-maternal-visible")
                        ColorPicker("Maternal branch color", selection: $maternalColor, supportsOpacity: false)
                            .accessibilityIdentifier("family-tree-maternal-color")
                        HStack {
                            Text("Zoom")
                            Slider(value: $zoom, in: 0.6...1.8, step: 0.1).accessibilityIdentifier("family-tree-zoom")
                            Text(zoom, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit())
                        }
                        Button("Reset view") {
                            zoom = 1; ancestorsAbove = true; paternalVisible = true; maternalVisible = true
                            paternalColor = .blue; maternalColor = .pink
                        }.accessibilityIdentifier("family-tree-reset")
                    }.padding(.top, 8)
                }
                HStack {
                    Label("Parent", systemImage: "arrow.up").foregroundStyle(.secondary)
                    Label("Partner", systemImage: "heart").foregroundStyle(.pink)
                    Label("Siblings", systemImage: "arrow.left.and.right").foregroundStyle(.orange)
                }.font(.caption2).foregroundStyle(.secondary)
                Text("Dashed parent lines indicate adoption.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 8) {
            let results = projection.search(query)
            if results.isEmpty { Text("No matches").foregroundStyle(.secondary) }
            ForEach(results, id: \.self) { id in
                if let person = people[id] {
                    Button { refocus(on: id, remember: true); query = "" } label: { relativeChip(person) }
                        .buttonStyle(.plain).accessibilityIdentifier("family-tree-search-result-\(id)")
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Each person in the recorded component appears once. Two-axis scrolling keeps
    /// every generation reachable without squeezing names to fit a phone screen.
    private var pedigree: some View {
        let source = projection
        let nodes = source.pedigree(focus: focus?.string("person_id") ?? "")
            .filter { $0.visible(paternal: paternalVisible, maternal: maternalVisible) }
        let layout = source.layout(focus: focus?.string("person_id") ?? "")
        let visibleIds = Set(nodes.map(\.id))
        let cardWidth = 156.0 * zoom, cardHeight = 132.0 * zoom
        let gap = 28.0 * zoom
        let width = max(320, layout.width * zoom + gap * 2)
        let height = max(120, layout.height * zoom + gap * 2)
        let points = Dictionary(uniqueKeysWithValues: layout.nodes.filter { visibleIds.contains($0.id) }.map { node in
            let y = ancestorsAbove ? node.y : layout.height - 132 - node.y
            return (node.id, CGPoint(x: gap + node.x * zoom, y: gap + y * zoom))
        })
        return ScrollViewReader { reader in
            VStack(alignment: .leading, spacing: 8) {
                Button("Center on focus person") {
                    if let id = focus?.string("person_id") { withAnimation { reader.scrollTo(id, anchor: .center) } }
                }.font(.caption).accessibilityIdentifier("family-tree-center")
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Canvas { context, _ in
                            for edge in source.edges {
                                guard let from = points[edge.from], let to = points[edge.to] else { continue }
                                var line = Path()
                                line.move(to: CGPoint(x: from.x + cardWidth / 2, y: from.y + cardHeight / 2))
                                line.addLine(to: CGPoint(x: to.x + cardWidth / 2, y: to.y + cardHeight / 2))
                                let color: Color = edge.kind == .spouse ? .pink : edge.kind == .sibling ? .orange : .secondary
                                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: edge.adoptive ? [6, 4] : []))
                            }
                        }.frame(width: width, height: height).accessibilityHidden(true)
                        ForEach(nodes) { node in
                            if let person = people[node.id], let point = points[node.id] {
                                Button { refocus(on: node.id, remember: true) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(person.text("display_name") ?? "Sin nombre").font(.footnote.weight(.semibold)).lineLimit(2)
                                        if let years = lifespan(person) { Text(years).font(.caption2).lineLimit(1) }
                                        if node.branches.contains(.paternal) { Text("Paternal branch").font(.caption2).foregroundStyle(paternalColor) }
                                        if node.branches.contains(.maternal) { Text("Maternal branch").font(.caption2).foregroundStyle(maternalColor) }
                                        if source.edges.contains(where: { $0.adoptive && $0.to == node.id && points[$0.from] != nil }) {
                                            Text("Adoptive").font(.caption2)
                                        }
                                    }
                                    .frame(width: 140, height: 116, alignment: .leading).padding(8)
                                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(node.id == focus?.string("person_id") ? session.accent : branchColor(node.branches), lineWidth: 2) }
                                    .scaleEffect(zoom, anchor: .topLeading)
                                    .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
                                }
                                .buttonStyle(.plain).id(node.id)
                                .accessibilityIdentifier("family-tree-person-\(node.id)")
                                .position(x: point.x + cardWidth / 2, y: point.y + cardHeight / 2)
                            }
                        }
                    }.frame(width: width, height: height)
                }
                .frame(height: min(480, height))
                .accessibilityIdentifier("family-tree-pedigree")
                .onAppear {
                    if let id = focus?.string("person_id") { reader.scrollTo(id, anchor: .center) }
                }
                .onChange(of: focus?.string("person_id")) { _, id in
                    if let id { reader.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func branchColor(_ branches: Set<FamilyTreeProjection.Branch>) -> Color {
        if branches.contains(.paternal) && branches.contains(.maternal) { return session.accent }
        if branches.contains(.paternal) { return paternalColor }
        if branches.contains(.maternal) { return maternalColor }
        return Color.secondary.opacity(0.5)
    }

    private func focusCard(_ person: Row) -> some View {
        VStack(spacing: 10) {
            if let portrait = portraitHash(for: person) {
                AssetImage(session: session, hash: portrait)
                    .frame(width: 96, height: 96)
                    .clipShape(Circle())
                    .overlay { Circle().strokeBorder(session.accent.opacity(0.6), lineWidth: 2) }
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 74))
                    .foregroundStyle(session.accent.opacity(0.55))
            }

            Text(person.text("display_name") ?? "Sin nombre")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            if let lifespan = lifespan(person) {
                Text(lifespan).font(.footnote).foregroundStyle(.secondary)
            }

            NavigationLink {
                RowDetailView(session: session, collection: Collections["persons"], row: person)
            } label: {
                Label("Open the full record", systemImage: "person.text.rectangle")
                    .font(.caption)
            }
            .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .nodusGlass(NodusGlass(.prominent, tint: session.accent))
    }

    /// `LocalizedStringKey`, not `String`. The four headings of the tree — Parents, Partner,
    /// Siblings, Children — reached `Label` as values, so they stayed English on a Spanish
    /// phone however complete the catalogue was.
    private func generation(_ rows: [Row], title: LocalizedStringKey, icon: String) -> some View {
        Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(title, systemImage: icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    // Wrapping rather than a row: three siblings fit, seven do not, and a
                    // horizontal scroller hides the ones that matter.
                    FlowLayout(spacing: 8) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, person in
                            Button {
                                guard let id = person.string("person_id") else { return }
                                refocus(on: id, remember: true)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    relativeChip(person)
                                    if let selected = focus?.string("person_id"), let id = person.string("person_id"),
                                       projection.isAdoptive(between: selected, and: id) {
                                        Label("Adoptive", systemImage: "person.2").font(.caption2).padding(.horizontal, 11)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func relativeChip(_ person: Row) -> some View {
        HStack(spacing: 8) {
            if let hash = portraitHash(for: person) {
                AssetImage(session: session, hash: hash)
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.circle")
                    .font(.title3)
                    .foregroundStyle(session.accent.opacity(0.75))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(person.text("display_name") ?? "Sin nombre")
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                if let years = lifespan(person) {
                    Text(years).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .nodusGlass(NodusGlass(.thin, tint: session.accent, interactive: true),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Data

    private func lifespan(_ person: Row) -> String? {
        // Genealogy stores these as display strings — "c. 1850", "antes de 1900" — because that
        // is what the sources say. Parsing them into dates would invent a precision the record
        // does not have.
        let birth = person.text("birth_date")
        let death = person.text("death_date")
        guard birth != nil || death != nil else { return nil }
        return "\(birth ?? "?") – \(death ?? "?")"
    }

    private func portraitHash(for person: Row) -> String? {
        guard let id = person.string("person_id") else { return nil }
        return portraitHashes[id]
    }

    @State private var portraitHashes: [String: String] = [:]

    private func load() async {
        let currentFocusId = focus?.string("person_id")
        isLoading = true
        defer { isLoading = false }
        do {
            guard let persons = Collections["persons"], let links = Collections["relationships"] else {
                throw DesktopBridgeError.malformedResponse
            }
            let allPeople = try await session.client.allItems(persons, in: session.connection.spaceId)
            let allRelationships = try await session.client.allItems(links, in: session.connection.spaceId)
            people = Dictionary(allPeople.compactMap { row in
                row.string("person_id").map { ($0, row) }
            }, uniquingKeysWith: { first, _ in first })
            relationships = allRelationships

            portraitHashes = [:]
            if let mirror = session.mirror {
                let portraits = try await mirror.allRows(table: "person_portraits")
                for row in portraits {
                    guard let id = row.string("person_id"), let asset = try? await mirror.portrait(personId: id) else { continue }
                    portraitHashes[id] = asset.hash
                }
            }

            let preferred = currentFocusId ?? rootPersonId
            let start = preferred.flatMap { people[$0] == nil ? nil : $0 } ?? mostConnectedPerson()
            history.removeAll { people[$0] == nil }
            if let start { refocus(on: start, remember: false) }
            else { focus = nil; parents = []; children = []; partners = []; siblings = [] }
            error = nil
        } catch where error.isCancellation {
            // Superseded or let go of. Nothing failed, so nothing is reported.
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func mostConnectedPerson() -> String? { projection.defaultFocus }

    private func refocus(on personId: String, remember: Bool) {
        guard let selected = people[personId] else { return }
        if remember, let current = focus?.string("person_id"), current != personId { history.append(current) }
        focus = selected
        let source = projection
        parents = resolve(source.parents(of: personId))
        children = resolve(source.children(of: personId))
        partners = resolve(source.partners(of: personId))
        siblings = resolve(source.siblings(of: personId))
    }

    private func resolve(_ ids: [String]) -> [Row] { ids.compactMap { people[$0] } }
}
