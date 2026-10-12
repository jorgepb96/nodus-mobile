import NodusKit
import NodusUI
import SwiftUI

/// Full-size shared map canvas with native touch controls and native sheets.
/// A map selection never opens a Desktop inspector beside an iPhone canvas.
struct WorldMapView: View {
    let session: SpaceSession
    var initialMapId: String? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ScaledMetric(relativeTo: .caption) private var markerFont: CGFloat = 14
    @State private var maps: [Row] = []
    @State private var selectedId = ""
    @State private var source: WorldMapReadSource?
    @State private var loading = false
    @State private var issue: String?
    @State private var attempt = 0
    @State private var rendererAttempt = 0
    @State private var fit = 0
    @State private var hiddenLayers = Set<String>()
    @State private var selectedCast = Set<String>()
    @State private var showScenes = false
    @State private var measuring = false
    @State private var day: Double?
    @State private var dayLabel = "Todas las fechas"
    @State private var range: ClosedRange<Double>?
    @State private var castPositions: [Row] = []
    @State private var marker: Selection?
    @State private var panel: Panel?
    @State private var openingOriginal = false
    @State private var query = ""

    enum Explorer: String, Identifiable { case maps = "Mapas", markers = "Marcadores", characters = "Personajes", scenes = "Escenas"; var id: String { rawValue } }
    enum Panel: Identifiable {
        case marker(Selection), related(Related), original(RichCorpusProse.OpenImage), timeline, explorer(Explorer), generation
        var id: String {
            switch self {
            case .marker(let item): "marker:" + item.id
            case .related(let item): "related:" + item.id
            case .original: "original"
            case .generation: "generation"
            case .timeline: "timeline"
            case .explorer(let item): "explorer:" + item.id
            }
        }
    }

    struct Selection: Identifiable { let row: Row; var id: String { row.string("markerId") ?? "" } }
    struct Related: Identifiable { let collection: CollectionDescriptor; let row: Row; var id: String { collection.path + ":" + (row.string(collection.idField) ?? "") } }
    private var characters: [Row] {
        var seen = Set<String>()
        return (source?.presences ?? []).filter { row in row.string("personId").map { seen.insert($0).inserted } ?? false }
            .sorted { ($0.string("personName") ?? "").localizedStandardCompare($1.string("personName") ?? "") == .orderedAscending }
    }
    private var options: JSONValue {
        .object(["hiddenLayers": .array(hiddenLayers.sorted().map(JSONValue.string)),
                 "selectedMarker": marker.map { .string($0.id) } ?? .null,
                 "cast": .array(selectedCast.sorted().map(JSONValue.string)), "day": day.map { .double($0) } ?? .null,
                 "scenes": .bool(showScenes), "measuring": .bool(measuring), "fitKey": .string("\(fit)"), "dark": .bool(colorScheme == .dark), "language": .string(Prompts.interfaceLanguage), "fontSize": .double(Double(markerFont))])
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                mapPicker
                Spacer(minLength: 0)
                controls
                Button { fit += 1 } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.frame(minWidth: 44, minHeight: 44).accessibilityLabel("Ajustar mapa")
            }.padding(.horizontal, NodusSpace.page)
            if let source {
                if source.ancestry.count > 1, verticalSizeClass != .compact {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(source.ancestry.reversed(), id: \.columns) { map in
                                Button(map.text("name") ?? "Mapa") { if let id = map.string("mapId") { select(id) } }.font(.caption).frame(minHeight: 44)
                                if map.string("mapId") != selectedId { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                            }
                        }.padding(.horizontal, NodusSpace.page)
                    }.scrollIndicators(.hidden)
                }
                SharedWorldMapReader(session: session, source: source, options: options, onEvent: event, onIssue: { issue = $0 })
                    .id("\(selectedId)|\(rendererAttempt)").frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("world-map-shared-canvas").accessibilityLabel("Mapa: \(source.map.text("name") ?? "")")
                    .clipShape(RoundedRectangle(cornerRadius: 14)).padding(.horizontal, sizeClass == .regular ? NodusSpace.page : 8)
                    .overlay { if loading { ProgressView().padding(12).background(.regularMaterial, in: Capsule()) } }
                if !selectedCast.isEmpty, verticalSizeClass != .compact { timeline }
                HStack {
                    if !source.markers.isEmpty { markersMenu(source) }
                    if !selectedCast.isEmpty, verticalSizeClass == .compact { Button("Tiempo y personajes") { panel = .timeline }.font(.caption).frame(minHeight: 44) }
                    if openingOriginal { ProgressView("Abriendo original…").font(.caption) }
                }
            } else if loading { Spacer(); ProgressView("Cargando mapa…"); Spacer() }
            else if issue == nil { ContentUnavailableView("No hay mapas", systemImage: "map", description: Text("Los mapas y sus capas se consultan al vincular tu Nodus.")); Spacer() }
            if let issue {
                VStack(alignment: .leading, spacing: 6) {
                    Text(issue).font(.caption).foregroundStyle(Color.nodusDanger).fixedSize(horizontal: false, vertical: true)
                    Button("Reintentar") { rendererAttempt += 1; attempt += 1 }.frame(minHeight: 44)
                }.padding(.horizontal, NodusSpace.page)
            }
        }
        .padding(.bottom, 8).nodusPageBackdrop(accent: session.accent).nodusHidesBottomBar()
        .task(id: session.publishedRevision) { await loadCatalogue() }
        .task(id: "\(selectedId)|\(attempt)|\(session.publishedRevision)|\(session.companionDownloadRevision)") { await loadMap() }
        .nodusSheet(item: $panel) { item in panelBody(item) }
        .onChange(of: panel?.id) { _, value in if value == nil { marker = nil } }
    }
    @ViewBuilder private func panelBody(_ panel: Panel) -> some View {
        switch panel {
        case .marker(let selected): markerSheet(selected.row)
        case .related(let target): NavigationStack { RowDetailView(session: session, collection: target.collection, row: target.row) }
        case .original(let image): ReaderImageViewer(content: image.content, image: image.preview, title: image.title, accent: session.accent)
        case .timeline: NavigationStack { ScrollView { timeline.padding(.vertical) }.navigationTitle("Tiempo y personajes").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Cerrar") { self.panel = nil } } } }
        case .explorer(let kind): browser(kind)
        case .generation: if let source { WorldMapGenerationSheet(session: session, mapId: source.map.string("mapId") ?? "", title: source.map.text("name") ?? "Mapa", initialStyle: source.map.string("style") ?? "parchment") { attempt += 1; rendererAttempt += 1 } }
        }
    }
    private var mapPicker: some View {
        Button { query = ""; panel = .explorer(.maps) } label: {
            HStack(spacing: 6) { Image(systemName: "map"); Text(source?.map.text("name") ?? maps.first { $0.string("map_id") == selectedId }?.text("name") ?? "Mapas").font(.headline).lineLimit(1); Image(systemName: "chevron.down").font(.caption) }
                .frame(minHeight: 44).foregroundStyle(session.accent.nodusReadable)
        }.disabled(maps.isEmpty).accessibilityIdentifier("world-map-chooser")
    }
    private var controls: some View {
        Menu {
            if let source {
                if session.connection.role.canSendChanges { Button("Generar o ampliar mapa") { panel = .generation } }
                Menu("Capas") {
                    ForEach(source.layers, id: \.columns) { layer in
                        if let id = layer.string("layerId") {
                            Toggle(layer.text("name") ?? "Capa", isOn: Binding(get: { !hiddenLayers.contains(id) }, set: { if $0 { hiddenLayers.remove(id) } else { hiddenLayers.insert(id) } }))
                        }
                    }
                }
                Toggle("Mostrar escenas", isOn: $showScenes)
                Button("Personajes · \(selectedCast.count)") { query = ""; panel = .explorer(.characters) }
                Button("Consultar escenas") { query = ""; panel = .explorer(.scenes) }
                Toggle("Medir distancia y viaje", isOn: $measuring)
                Button("Ver dossier del mapa") { openRelated("world-maps", id: selectedId) }
                if let image = source.imageSource {
                    Button("Ver imagen original") { Task { await openOriginal(image, title: source.map.text("name") ?? "Mapa") } }.disabled(openingOriginal)
                }
            }
        } label: { Image(systemName: "slider.horizontal.3").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("Opciones del mapa").accessibilityIdentifier("world-map-options")
    }
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(dayLabel).font(.caption); Spacer(); Button("Todas las fechas") { day = nil }.font(.caption).frame(minHeight: 44) }
            if let range, range.lowerBound < range.upperBound {
                Slider(value: Binding(get: { day ?? range.lowerBound }, set: { day = $0.rounded() }), in: range, step: 1).tint(session.accent).accessibilityLabel("Fecha del mapa")
            }
            if !castPositions.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(castPositions, id: \.columns) { person in
                            Button { if let id = person.string("personId") { openRelated("persons", id: id) } } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(person.text("personName") ?? "Personaje").font(.caption.weight(.medium))
                                    Text(person.bool("beforeFirst") == true ? "Antes del primer registro" : person.text("towardsPlaceName").map { "Hacia \($0)" } ?? person.text("placeName") ?? "Sin posición en este mapa").font(.caption2).foregroundStyle(.secondary)
                                }.frame(minHeight: 44).padding(.horizontal, 10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                        }
                    }
                }.scrollIndicators(.hidden)
            }
        }.padding(.horizontal, NodusSpace.page)
    }
    private func markersMenu(_ source: WorldMapReadSource) -> some View {
        Button { query = ""; panel = .explorer(.markers) } label: { Label("Marcadores · \(source.markers.count)", systemImage: "mappin.and.ellipse").font(.caption).frame(minHeight: 44) }.accessibilityIdentifier("world-map-markers")
    }
    private func browser(_ kind: Explorer) -> some View {
        NavigationStack {
            List {
                switch kind {
                case .maps:
                    ForEach(maps.filter { matches($0.text("name")) }, id: \.columns) { row in
                        if let id = row.string("map_id") {
                            Button { panel = nil; select(id) } label: { Label(row.text("name") ?? "Mapa", systemImage: id == selectedId ? "checkmark" : "map") }.frame(minHeight: 44)
                        }
                    }
                case .markers:
                    ForEach((source?.markers ?? []).filter { matches($0.text("label") ?? $0.text("placeName")) }, id: \.columns) { row in
                        NavigationLink {
                            markerSheetContent(row)
                        } label: { Label(row.text("label") ?? row.text("placeName") ?? "Marcador", systemImage: "mappin.and.ellipse") }.frame(minHeight: 44)
                    }
                case .characters:
                    Button("Ocultar todos") { selectedCast.removeAll(); day = nil }
                    ForEach(characters.filter { matches($0.text("personName")) }, id: \.columns) { row in
                        if let id = row.string("personId") { Toggle(row.text("personName") ?? "Personaje", isOn: Binding(get: { selectedCast.contains(id) }, set: { if $0 { selectedCast.insert(id) } else { selectedCast.remove(id) } })).tint(session.accent).frame(minHeight: 44) }
                    }
                case .scenes:
                    let placeIds = Set((source?.markers ?? []).compactMap { $0.string("placeId") })
                    ForEach((source?.scenes ?? []).filter { $0.string("placeId").map(placeIds.contains) ?? false }.filter { matches($0.text("title")) }, id: \.columns) { row in
                        if let id = row.string("sceneId"), let collection = Collections["world-scenes"] {
                            NavigationLink(row.text("title") ?? "Escena") { RowDetailView(session: session, collection: collection, row: Row([collection.idField: .string(id)])) }.frame(minHeight: 44)
                        }
                    }
                }
            }.searchable(text: $query, prompt: "Buscar")
                .navigationTitle(kind.rawValue).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Cerrar") { panel = nil } } }
        }
    }
    private func matches(_ value: String?) -> Bool { query.isEmpty || (value ?? "").localizedStandardContains(query) }
    private func markerSheet(_ row: Row) -> some View {
        NavigationStack {
            markerSheetContent(row)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Cerrar") { panel = nil; marker = nil } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private func markerSheetContent(_ row: Row) -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let notes = row.text("notes"), !notes.isEmpty { CorpusProse(notes, accent: session.accent, session: session).font(.body) }
                    if let place = row.string("placeId"), let collection = Collections["places"] {
                        NavigationLink("Abrir lugar") { RowDetailView(session: session, collection: collection, row: Row(["place_id": .string(place), "name": .string(row.text("placeName") ?? "Lugar")])) }
                    }
                    if let child = row.string("childMapId") { Button("Abrir mapa vinculado") { marker = nil; panel = nil; select(child) }.frame(minHeight: 44) }
                    DossierValueView(session: session, value: .object(row.columns.filter { $0.key != "notes" }), field: "", linkedCollection: nil)
                }.padding(NodusSpace.page)
            }.navigationTitle(row.text("label") ?? row.text("placeName") ?? "Marcador").navigationBarTitleDisplayMode(.inline)
    }
    private func select(_ id: String) {
        guard !id.isEmpty, id != selectedId else { return }
        selectedId = id; source = nil; issue = nil; marker = nil; panel = nil
        hiddenLayers = []; day = nil; range = nil; castPositions = []; fit = 0; rendererAttempt = 0
    }
    private func openRelated(_ path: String, id: String) {
        guard let collection = Collections[path], !id.isEmpty else { return }
        panel = .related(Related(collection: collection, row: Row([collection.idField: .string(id)])))
    }
    private func event(_ value: JSONValue) {
        guard let source, let object = value.objectValue, object["mapId"] == .string(selectedId) else { return }
        switch object["type"]?.stringValue {
        case "marker":
            if let id = object["id"]?.stringValue, let row = source.markers.first(where: { $0.string("markerId") == id }) { let selection = Selection(row: row); marker = selection; panel = .marker(selection) }
        case "child":
            if let id = object["id"]?.stringValue, source.markers.contains(where: { $0.string("childMapId") == id }) || source.children.contains(where: { $0.string("mapId") == id }) { select(id) }
        case "scene":
            if let id = object["id"]?.stringValue, source.scenes.contains(where: { $0.string("sceneId") == id }) { openRelated("world-scenes", id: id) }
        case "summary":
            if let bounds = object["range"]?.objectValue, let lower = Row(bounds).double("min"), let upper = Row(bounds).double("max"), lower.isFinite, upper.isFinite, lower <= upper { range = lower...upper }
            else { range = nil }
            dayLabel = object["dayLabel"]?.stringValue ?? "Todas las fechas"
            let ids = Set(characters.compactMap { $0.string("personId") })
            castPositions = (object["cast"]?.arrayValue ?? []).compactMap { $0.objectValue.map(Row.init) }.filter { $0.string("personId").map(ids.contains) ?? false }
        default: break
        }
    }
    private func loadCatalogue() async {
        do {
            let tables = try await worldTables(session, ["world_maps"])
            try Task.checkCancellation()
            maps = tables["world_maps"] ?? []
            if selectedId.isEmpty, let id = initialMapId ?? maps.first?.string("map_id") { selectedId = id }
        } catch where error.isCancellation {}
        catch { issue = error.localizedDescription }
    }
    private func openOriginal(_ url: String, title: String) async {
        openingOriginal = true; defer { openingOriginal = false }
        do {
            let content = try await ReaderImageSource.load(url, session: session)
            let preview = content.mime == "image/svg+xml" || content.mime == "image/gif" ? nil : try ReaderRasterImage.preview(content.data)
            try Task.checkCancellation(); panel = .original(.init(content: content, preview: preview, title: title))
        } catch where error.isCancellation {}
        catch { issue = error.localizedDescription }
    }
    private func loadMap() async {
        guard !selectedId.isEmpty else { return }
        let id = selectedId; loading = true
        defer { if selectedId == id { loading = false } }
        do {
            let (vault, _, _) = try privateBridgeConnection(session, domain: .corpus)
            let value = try await loadPrivateBridgeValue(session, method: "getMobileWorldMapReadSource", args: [.string(id)])
            let loaded = try WorldMapReadSource(value, vault: vault, mapId: id)
            try Task.checkCancellation(); guard selectedId == id else { return }
            if source == nil { hiddenLayers = Set(loaded.layers.filter { $0.bool("visible") == false }.compactMap { $0.string("layerId") }) }
            source = loaded; issue = nil
        } catch where error.isCancellation {}
        catch { guard selectedId == id else { return }; source = nil; issue = error.localizedDescription }
    }
}
