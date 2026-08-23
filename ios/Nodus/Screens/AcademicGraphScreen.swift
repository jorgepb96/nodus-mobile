import NodusKit
import NodusUI
import SwiftUI

/// Desktop's two academic graph lenses over the exact rows carried by the publication.
/// Simulation is portable and deterministic; Metal only draws the immutable result.
struct AcademicGraphView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    let session: SpaceSession

    @State private var tables: [String: [Row]] = [:]
    @State private var graph = AcademicGraph(lens: .ideas, nodes: [], edges: [])
    @State private var positions: [String: AcademicGraphPoint] = [:]
    @State private var lens: AcademicGraphLens = .ideas
    @State private var layout: AcademicGraphLayoutMode = .force
    @State private var query = ""
    @State private var minimumWeight = 0.0
    @State private var selectedId: String?
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var liveDrag: CGSize = .zero
    @GestureState private var liveMagnification: CGFloat = 1
    @State private var loading = true
    @State private var error: String?
    @State private var projectionGeneration = 0
    @State private var layoutEngine = AcademicGraphLayoutEngine()

    private var projectionID: String {
        "\(session.publishedRevision ?? "local")|\(lens.rawValue)|\(layout.rawValue)|\(minimumWeight)|\(query)|\(projectionGeneration)"
    }

    private var selectedNode: AcademicGraphNode? {
        graph.nodes.first { $0.id == selectedId }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            if let error {
                NodusNotice(tone: .blocked, title: "Could not load the graph", message: LocalizedStringKey(error))
                    .padding(.horizontal, NodusSpace.page)
            }
            if loading && tables.isEmpty {
                Spacer(); ProgressView().tint(session.accent); Spacer()
            } else if graph.nodes.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No graph published" : "No matching nodes",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Adjust the lens or confidence threshold, or publish graph analysis from Desktop.")
                )
                .frame(maxHeight: .infinity)
            } else if sizeClass == .regular {
                HStack(spacing: 0) {
                    graphCanvas
                    Divider()
                    inspector.frame(width: 310)
                }
            } else {
                VStack(spacing: 0) {
                    graphCanvas.frame(minHeight: 330)
                    Divider()
                    inspector.frame(maxHeight: 310)
                }
            }
        }
        .nodusPageBackdrop(accent: session.accent)
        .accessibilityIdentifier("academic-graph")
        .task(id: session.publishedRevision) { await load() }
        .task(id: projectionID) { await rebuild() }
    }

    private var controls: some View {
        VStack(spacing: 9) {
            DesktopPageHeader(
                title: "Graph",
                subtitle: loading ? "Building the published network…" : "\(graph.nodes.count) nodes · \(graph.edges.count) grounded relations",
                systemImage: "point.3.connected.trianglepath.dotted",
                accent: session.accent
            )
            HStack(spacing: 8) {
                NodusSearchField(text: $query, prompt: "Find a node", accent: session.accent, isBusy: loading)
                Menu {
                    Picker("Lens", selection: $lens) {
                        Label("Ideas", systemImage: "lightbulb").tag(AcademicGraphLens.ideas)
                        Label("Authors", systemImage: "person.2").tag(AcademicGraphLens.authors)
                    }
                } label: {
                    Label(lens == .ideas ? "Ideas" : "Authors", systemImage: lens == .ideas ? "lightbulb" : "person.2")
                }
                .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
                Menu {
                    Picker("Layout", selection: $layout) {
                        Label("Force", systemImage: "atom").tag(AcademicGraphLayoutMode.force)
                        Label("Radial", systemImage: "circle.grid.cross").tag(AcademicGraphLayoutMode.radial)
                    }
                } label: { Image(systemName: layout == .force ? "atom" : "circle.grid.cross") }
                    .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
            }
            HStack(spacing: 10) {
                Text("Minimum confidence").font(.caption).foregroundStyle(.secondary)
                Slider(value: $minimumWeight, in: 0...0.9, step: 0.1).tint(session.accent)
                Text(minimumWeight, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                Button { zoom = 1; offset = .zero } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
                    .accessibilityLabel("Reset graph view")
            }
        }
        .padding(.horizontal, NodusSpace.page)
        .padding(.vertical, 9)
        // The shared desktop chrome overlays its 44 pt top bar. Scroll-backed routes get
        // this clearance from their safe-area inset; the full-screen graph supplies it here.
        .padding(.top, 44)
        .background(Color(uiColor: .systemBackground).opacity(0.97))
    }

    private var graphCanvas: some View {
        GeometryReader { proxy in
            let renderedZoom = zoom * liveMagnification
            let renderedOffset = CGSize(width: offset.width + liveDrag.width, height: offset.height + liveDrag.height)
            ZStack(alignment: .bottomLeading) {
                AcademicMetalGraphSurface(
                    graph: graph, positions: positions, zoom: renderedZoom, offset: renderedOffset,
                    selectedId: selectedId, accent: session.accent.nodusReadable
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .updating($liveDrag) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            offset.width += value.translation.width
                            offset.height += value.translation.height
                        }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .updating($liveMagnification) { value, state, _ in state = value }
                        .onEnded { zoom = min(4, max(0.45, zoom * $0)) }
                )

                ForEach(Array(graph.nodes.prefix(sizeClass == .regular ? 54 : 24))) { node in
                    if let source = positions[node.id] {
                        let point = renderedPoint(source, in: proxy.size, zoom: renderedZoom, offset: renderedOffset)
                        if point.x > 12, point.x < proxy.size.width - 12, point.y > 12, point.y < proxy.size.height - 12 {
                            Button { selectedId = node.id } label: {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(nodeColor(node.kind))
                                        .frame(width: selectedId == node.id ? 15 : 11, height: selectedId == node.id ? 15 : 11)
                                        .shadow(color: nodeColor(node.kind).opacity(0.65), radius: 5)
                                    Text(node.label)
                                        .font(.system(size: sizeClass == .regular ? 10 : 9, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                .padding(.horizontal, 4).padding(.vertical, 3)
                                .background(Color(uiColor: .systemBackground).opacity(0.78), in: RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                            .position(x: min(proxy.size.width - 72, max(72, point.x + 48)), y: point.y)
                        }
                    }
                }
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in
                        selectedId = nearestNode(
                            to: value.location, in: proxy.size, zoom: renderedZoom, offset: renderedOffset
                        )
                    }
                )

                HStack(spacing: 10) {
                    Label("Pinch to zoom", systemImage: "arrow.up.left.and.arrow.down.right")
                    Label("Drag to move", systemImage: "hand.draw")
                }
                .font(.caption2).foregroundStyle(.secondary)
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(10)
            }
        }
        .background(
            LinearGradient(
                colors: [session.accent.opacity(0.055), Color(uiColor: .secondarySystemBackground).opacity(0.28)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .accessibilityLabel("Interactive academic graph with \(graph.nodes.count) nodes")
    }

    private var inspector: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let selectedNode {
                    Label(selectedNode.kind.capitalized, systemImage: selectedNode.kind == "author" ? "person" : "lightbulb")
                        .font(.caption.weight(.semibold)).foregroundStyle(session.accent.nodusReadable)
                    Text(selectedNode.label).font(.title3.weight(.semibold))
                    if !selectedNode.subtitle.isEmpty { Text(selectedNode.subtitle).font(.subheadline).foregroundStyle(.secondary) }
                    HStack {
                        NodusChip(key: "\(Int(selectedNode.weight.rounded())) weight", tint: session.accent)
                        if let group = selectedNode.group { NodusChip(key: group, tint: .indigo) }
                        if selectedNode.read { NodusChip(key: "read", tint: .green) }
                    }
                    let relations = graph.edges.filter { $0.source == selectedNode.id || $0.target == selectedNode.id }
                    Text("\(relations.count) connections").font(.caption.weight(.semibold)).padding(.top, 6)
                    ForEach(relations.prefix(12)) { edge in
                        let other = edge.source == selectedNode.id ? edge.target : edge.source
                        Button { selectedId = other } label: {
                            HStack {
                                Image(systemName: relationIcon(edge.kind)).foregroundStyle(relationColor(edge.kind))
                                Text(graph.nodes.first { $0.id == other }?.label ?? other).lineLimit(2)
                                Spacer(); Text(edge.kind).font(.caption2).foregroundStyle(.secondary)
                            }.font(.caption)
                        }.buttonStyle(.plain)
                    }
                    Divider().padding(.vertical, 4)
                } else {
                    Text("Select a node").font(.headline)
                    Text("Its grounded relations and graph metadata will appear here.").font(.caption).foregroundStyle(.secondary)
                    Divider().padding(.vertical, 4)
                }
                Text("Accessible node list").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(graph.nodes.prefix(120)) { node in
                    Button { selectedId = node.id } label: {
                        HStack(spacing: 8) {
                            Circle().fill(node.id == selectedId ? session.accent : Color.secondary.opacity(0.45)).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(node.label).lineLimit(1)
                                Text(node.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(node.label), \(node.kind), weight \(Int(node.weight.rounded()))")
                }
            }.padding(16)
        }
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.58))
    }

    private func load() async {
        loading = true
        do {
            let snapshot = try await session.client.snapshot(in: session.connection.spaceId)
            tables = snapshot.tables; error = nil; projectionGeneration += 1
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func rebuild() async {
        guard !tables.isEmpty else { return }
        if !query.isEmpty { try? await Task.sleep(for: .milliseconds(180)) }
        guard !Task.isCancelled else { return }
        let nextGraph = AcademicGraphProjection.build(
            from: tables, lens: lens, minimumWeight: minimumWeight, query: query, limit: 650
        )
        let nextPositions = await layoutEngine.layout(graph: nextGraph, mode: layout)
        guard !Task.isCancelled else { return }
        graph = nextGraph; positions = nextPositions
        if let selectedId, !nextGraph.nodes.contains(where: { $0.id == selectedId }) { self.selectedId = nil }
    }

    private func nearestNode(to location: CGPoint, in size: CGSize, zoom: CGFloat, offset: CGSize) -> String? {
        guard size.width > 0, size.height > 0 else { return nil }
        return graph.nodes.compactMap { node -> (String, CGFloat)? in
            guard let point = positions[node.id] else { return nil }
            let rendered = renderedPoint(point, in: size, zoom: zoom, offset: offset)
            return (node.id, hypot(rendered.x - location.x, rendered.y - location.y))
        }.filter { $0.1 < 34 }.min { $0.1 < $1.1 }?.0
    }

    private func renderedPoint(_ point: AcademicGraphPoint, in size: CGSize, zoom: CGFloat, offset: CGSize) -> CGPoint {
        let clipX = CGFloat(point.x) * zoom + offset.width / 360
        let clipY = CGFloat(point.y) * zoom - offset.height / 360
        return CGPoint(x: (clipX + 1) * size.width / 2, y: (1 - clipY) * size.height / 2)
    }

    private func nodeColor(_ kind: String) -> Color {
        switch kind {
        case "theme": .orange
        case "claim": .indigo
        case "finding": .mint
        case "construct", "framework": .cyan
        case "method": .pink
        case "author": .purple
        default: session.accent
        }
    }

    private func relationIcon(_ kind: String) -> String {
        ["contradicts", "refutes"].contains(kind) ? "bolt" : kind == "supports" ? "checkmark" : "link"
    }

    private func relationColor(_ kind: String) -> Color {
        ["contradicts", "refutes"].contains(kind) ? .red : kind == "supports" ? .green : session.accent
    }
}
