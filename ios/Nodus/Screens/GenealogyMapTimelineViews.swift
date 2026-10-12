import MapKit
import NodusKit
import NodusUI
import SwiftUI

@MainActor
private func genealogyTables(_ session: SpaceSession, names: [String], downloadedOnly: Bool, map: Bool) async throws -> (tables: [String: [Row]], offline: Bool) {
    if downloadedOnly {
        let (vault, pairing, _) = try privateBridgeConnection(session, domain: .corpus)
        guard !pairing.isExpired else { throw DesktopBridgeError.expired }
        let cache = try PrivateBridgeCache(pairingId: pairing.id)
        let persons = try await CompanionCollectionCopy.downloaded(cache: cache, vaultId: vault, path: "persons")
        let events = map ? nil : try await CompanionCollectionCopy.downloaded(cache: cache, vaultId: vault, path: "events")
        guard map ? persons != nil : events != nil else { throw CompanionCollectionCopy.CopyError.dossierNotDownloaded }
        return (try GenealogyConsultation.selectedTables(persons: persons, events: events), true)
    }
    if let mirror = session.mirror {
        var tables: [String: [Row]] = [:]
        for name in names { tables[name] = try await mirror.allRows(table: name) }
        return (tables, true)
    }
    let snapshot = try await session.client.snapshot(in: session.connection.spaceId)
    return (Dictionary(uniqueKeysWithValues: names.map { ($0, snapshot.tables[$0] ?? []) }), false)
}

private struct GenealogyFilterSheet: View {
    let title: String
    let options: [(id: String, name: String)]
    @Binding var selection: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        NavigationStack {
            List {
                Button("Show all") { selection.removeAll() }
                ForEach(options.filter { query.isEmpty || $0.name.localizedStandardContains(query) }, id: \.id) { option in
                    Button {
                        if selection.contains(option.id) { selection.remove(option.id) } else { selection.insert(option.id) }
                    } label: {
                        HStack { Text(option.name); Spacer(); Image(systemName: selection.contains(option.id) ? "checkmark.circle.fill" : "circle") }
                    }
                }
            }.searchable(text: $query).navigationTitle(title)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct GenealogyMapView: View {
    let session: SpaceSession
    @State private var tables: [String: [Row]] = [:]
    @State private var points: [GenealogyConsultation.MapPoint] = []
    @State private var selectedPeople = Set<String>()
    @State private var year: Double?
    @State private var routesVisible = true
    @State private var playing = false
    @State private var camera: MapCameraPosition = .automatic
    @State private var filterOpen = false
    @State private var selectedPlace: GenealogyPlaceSelection?
    @State private var loading = false
    @State private var issue: String?
    @State private var offline = false
    @State private var downloadedOnly = false
    @State private var retry = 0
    private struct GenealogyPlaceSelection: Identifiable { let id: String }
    private var personFiltered: [GenealogyConsultation.MapPoint] { GenealogyConsultation.filter(points, people: selectedPeople, throughYear: nil) }
    private var shown: [GenealogyConsultation.MapPoint] { GenealogyConsultation.filter(personFiltered, people: [], throughYear: year.map(Int.init)) }
    private var range: ClosedRange<Int>? { GenealogyConsultation.yearRange(personFiltered) }
    private var people: [(id: String, name: String)] {
        Dictionary(grouping: points, by: \.personId).compactMap { id, points in points.first.map { (id: id, name: $0.personName) } }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var locations: [GenealogyConsultation.MapPoint] {
        var seen = Set<String>(); return shown.filter { seen.insert($0.placeId).inserted }
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button { filterOpen = true } label: { Label(selectedPeople.isEmpty ? "All people" : "\(selectedPeople.count) people", systemImage: "person.2") }
                    .accessibilityIdentifier("genealogy-map-person-filter")
                Spacer()
                Toggle("Routes", isOn: $routesVisible).fixedSize().accessibilityIdentifier("genealogy-map-routes")
                Button { fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.accessibilityLabel("Fit map").frame(minWidth: 44, minHeight: 44)
            }
            if session.connection.desktopPairingId != nil {
                Toggle("Downloaded dossiers only", isOn: $downloadedOnly).font(.caption).accessibilityIdentifier("genealogy-map-downloads")
            }
            if let range {
                HStack {
                    Button { if year == nil || Int(year!) >= range.upperBound { year = Double(range.lowerBound) }; playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                        .disabled(range.lowerBound == range.upperBound).frame(minWidth: 44, minHeight: 44).accessibilityLabel(playing ? "Pause timeline" : "Play timeline")
                    Slider(value: Binding(get: { year ?? Double(range.upperBound) }, set: { year = $0; playing = false }), in: Double(range.lowerBound)...Double(max(range.upperBound, range.lowerBound + 1)), step: 1)
                        .disabled(range.lowerBound == range.upperBound).accessibilityIdentifier("genealogy-map-year")
                    Text(year.map { "≤ \(Int($0))" } ?? "All dates").font(.caption.monospacedDigit()).frame(minWidth: 62)
                }
            }
            if loading && points.isEmpty { ProgressView("Loading map…").frame(maxHeight: .infinity) }
            else if points.isEmpty && issue == nil { ContentUnavailableView("No located places", systemImage: "map", description: Text("Add places with coordinates to a person’s record in Nodus.")) }
            else {
                Map(position: $camera) {
                    ForEach(locations) { point in
                        Annotation(point.placeName, coordinate: coordinate(point)) {
                            Button { selectedPlace = .init(id: point.placeId) } label: { Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(session.accent).background(.regularMaterial, in: Circle()) }
                                .accessibilityLabel("\(point.placeName), \(shown.filter { $0.placeId == point.placeId }.count) records")
                        }
                    }
                    if routesVisible {
                        ForEach(Array(GenealogyConsultation.routes(shown).enumerated()), id: \.offset) { index, route in
                            MapPolyline(coordinates: route.map(coordinate)).stroke(routeColor(index), style: StrokeStyle(lineWidth: 3, dash: [7, 5]))
                        }
                    }
                }.mapControls { MapCompass(); MapScaleView() }
                    .accessibilityIdentifier("genealogy-map-canvas").clipShape(RoundedRectangle(cornerRadius: 14))
                HStack { Text("\(shown.count) locations").font(.caption); Spacer(); if offline { Label(downloadedOnly ? "Selected downloaded dossiers" : "Offline copy", systemImage: "lock").font(.caption) } }
                Text("Place records and routes remain available offline. The geographic basemap may require a connection.").font(.caption2).foregroundStyle(.secondary)
                // The list also exposes dense or overlapping map pins to VoiceOver.
                ScrollView(.horizontal) {
                    HStack { ForEach(locations) { point in Button(point.placeName) { selectedPlace = .init(id: point.placeId) }.buttonStyle(.bordered).frame(minHeight: 44) } }
                }.scrollIndicators(.hidden)
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(Color.nodusDanger); Button("Retry") { retry += 1 } }
        }.padding(NodusSpace.page).navigationTitle("Map").nodusPageBackdrop(accent: session.accent).nodusHidesBottomBar()
            .task(id: "\(session.publishedRevision ?? ""):\(session.companionDownloadRevision):\(downloadedOnly):\(retry)") { await load() }
            .task(id: playing) {
                guard playing, let range else { return }
                while playing && !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(550)) } catch { return }
                    let next = min(range.upperBound, Int(year ?? Double(range.lowerBound)) + 1)
                    year = Double(next); if next >= range.upperBound { playing = false }
                }
            }
            .onChange(of: selectedPeople) { _, _ in playing = false; year = range.map { Double($0.upperBound) }; fit() }
            .sheet(isPresented: $filterOpen) { GenealogyFilterSheet(title: "People", options: people, selection: $selectedPeople) }
            .sheet(item: $selectedPlace) { selected in placeSheet(selected.id) }
    }
    private func coordinate(_ point: GenealogyConsultation.MapPoint) -> CLLocationCoordinate2D { .init(latitude: point.latitude, longitude: point.longitude) }
    private func routeColor(_ index: Int) -> Color { [.indigo, .orange, .green, .pink, .cyan, .purple][index % 6] }
    private func fit() {
        guard !personFiltered.isEmpty else { camera = .automatic; return }
        let coords = personFiltered.map(coordinate)
        let minLat = coords.map(\.latitude).min()!, maxLat = coords.map(\.latitude).max()!
        let minLon = coords.map(\.longitude).min()!, maxLon = coords.map(\.longitude).max()!
        camera = .region(.init(center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2), span: .init(latitudeDelta: min(170, max(0.08, (maxLat - minLat) * 1.4)), longitudeDelta: min(359, max(0.08, (maxLon - minLon) * 1.4)))))
    }
    private func placeSheet(_ id: String) -> some View {
        NavigationStack {
            List(shown.filter { $0.placeId == id }) { point in
                VStack(alignment: .leading, spacing: 8) {
                    GenealogyPersonLink(session: session, tables: tables, id: point.personId, name: point.personName, downloadedOnly: downloadedOnly)
                    Text([point.label, point.date, point.region.isEmpty ? nil : point.region].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle(shown.first { $0.placeId == id }?.placeName ?? "Place")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selectedPlace = nil } } }
        }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do {
            let source = try await genealogyTables(session, names: ["persons", "places", "person_places"], downloadedOnly: downloadedOnly, map: true)
            try Task.checkCancellation(); tables = source.tables; offline = source.offline
            points = GenealogyConsultation.mapPoints(tables: tables); issue = nil
            selectedPeople.formIntersection(Set(points.map(\.personId)))
            year = range.map { Double($0.upperBound) }; playing = false; fit()
        } catch where error.isCancellation { }
        catch { tables = [:]; points = []; issue = error.localizedDescription }
    }
}

private struct GenealogyPersonLink: View {
    let session: SpaceSession
    let tables: [String: [Row]]
    let id: String
    let name: String
    let downloadedOnly: Bool
    var body: some View {
        if let row = tables["persons"]?.first(where: { $0.string("person_id") == id }), let descriptor = Collections["persons"] {
            NavigationLink {
                if downloadedOnly { GenealogyDownloadedDossierView(session: session, path: "persons", recordId: id) }
                else { RowDetailView(session: session, collection: descriptor, row: row) }
            } label: { Label(name, systemImage: "person.crop.circle") }
        } else { Text(name).foregroundStyle(.secondary); Text("This person’s record is unavailable in this copy.").font(.caption) }
    }
}

private struct GenealogyDownloadedDossierView: View {
    let session: SpaceSession
    let path: String
    let recordId: String
    @State private var dossier: CollectionDossier?
    @State private var issue: String?
    @State private var related: Target?
    private struct Target: Hashable { let path: String; let id: String }
    var body: some View {
        Group {
            if let dossier {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Selected downloaded dossier", systemImage: "lock").font(.caption)
                        CollectionDossierBody(session: session, dossier: dossier, showConnectionState: false, onOpenRelated: { collection, row in
                            if let id = row.string(collection.idField) { related = .init(path: collection.path, id: id) }
                        })
                        DossierOriginalResourcesView(session: session, dossier: dossier, downloadedOnly: true)
                    }.padding(NodusSpace.page)
                }.navigationTitle(Text(dossier.collection.presenter.title(dossier.primary)))
            } else if let issue { ContentUnavailableView("Dossier unavailable", systemImage: "arrow.down.circle", description: Text(issue)) }
            else { ProgressView("Reading downloaded dossier…") }
        }.nodusPageBackdrop(accent: session.accent)
            .navigationDestination(item: $related) { target in GenealogyDownloadedDossierView(session: session, path: target.path, recordId: target.id) }
            .task(id: path + ":" + recordId) {
                dossier = nil; issue = nil
                do { dossier = try await downloadedCollection(session, path: path).dossier(id: recordId) }
                catch where error.isCancellation { }
                catch { issue = error.localizedDescription }
            }
    }
}

struct GenealogyTimelineView: View {
    let session: SpaceSession
    @State private var tables: [String: [Row]] = [:]
    @State private var selectedPeople = Set<String>()
    @State private var selectedTypes = Set<String>()
    @State private var filter: Filter?
    @State private var selectedEvent: GenealogyConsultation.Event?
    @State private var loading = false
    @State private var issue: String?
    @State private var offline = false
    @State private var downloadedOnly = false
    @State private var retry = 0
    private enum Filter: String, Identifiable { case people, types; var id: String { rawValue } }
    private var events: [GenealogyConsultation.Event] { GenealogyConsultation.events(tables: tables, people: selectedPeople, types: selectedTypes) }
    private var people: [(id: String, name: String)] { (tables["persons"] ?? []).compactMap { row in row.string("person_id").map { (id: $0, name: row.text("display_name") ?? $0) } }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    private var types: [(id: String, name: String)] {
        Set(["birth", "baptism", "marriage", "death", "burial", "census", "residence", "migration", "occupation", "other"] + (tables["events"] ?? []).compactMap { $0.string("type") }).sorted().map { (id: $0, name: $0.capitalized) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button { filter = .people } label: { Label(selectedPeople.isEmpty ? "All people" : "\(selectedPeople.count) people", systemImage: "person.2") }.accessibilityIdentifier("genealogy-timeline-person-filter")
                    Spacer()
                    Button { filter = .types } label: { Label(selectedTypes.isEmpty ? "All event types" : "\(selectedTypes.count) types", systemImage: "line.3.horizontal.decrease.circle") }.accessibilityIdentifier("genealogy-timeline-type-filter")
                }
                if session.connection.desktopPairingId != nil {
                    Toggle("Downloaded dossiers only", isOn: $downloadedOnly).font(.caption).accessibilityIdentifier("genealogy-timeline-downloads")
                }
                Text("\(events.count) events").font(.caption).foregroundStyle(.secondary)
                if offline { Label(downloadedOnly ? "Selected downloaded dossiers" : "Offline copy", systemImage: "lock").font(.caption) }
                if let issue { NodusNotice(tone: .blocked, title: "Could not load timeline", message: LocalizedStringKey(issue)); Button("Retry") { retry += 1 } }
                if loading && tables.isEmpty { ProgressView("Loading timeline…") }
                else if events.isEmpty && issue == nil { ContentUnavailableView("No events", systemImage: "clock", description: Text("Choose other filters or record dated events in Nodus.")) }
                ForEach(events) { event in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) { Circle().fill(session.accent).frame(width: 12, height: 12); Rectangle().fill(session.accent.opacity(0.25)).frame(width: 2) }.padding(.top, 16)
                        VStack(alignment: .leading, spacing: 10) {
                            Button { selectedEvent = event } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(event.date ?? "Undated").font(.caption.monospacedDigit()).foregroundStyle(session.accent)
                                    Text(event.type.capitalized).font(.headline)
                                    if let label = event.row.text("label") { Text(label).font(.callout) }
                                    if let place = event.placeName { Label(place, systemImage: "mappin").font(.caption).foregroundStyle(.secondary) }
                                    if let notes = event.row.text("notes") { Text(notes).font(.caption).lineLimit(3).foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            ForEach(event.participants) { person in
                                HStack { GenealogyPersonLink(session: session, tables: tables, id: person.personId, name: person.name, downloadedOnly: downloadedOnly); Text(person.role).font(.caption2).foregroundStyle(.secondary) }
                            }
                        }.desktopContentRow(accent: session.accent)
                    }.accessibilityIdentifier("genealogy-timeline-event-\(event.id)")
                }
            }.padding(NodusSpace.page).frame(maxWidth: 960).frame(maxWidth: .infinity)
        }.navigationTitle("Timeline").nodusPageBackdrop(accent: session.accent).nodusHidesBottomBar()
            .task(id: "\(session.publishedRevision ?? ""):\(session.companionDownloadRevision):\(downloadedOnly):\(retry)") { await load() }
            .sheet(item: $filter) { selected in GenealogyFilterSheet(title: selected == .people ? "People" : "Event types", options: selected == .people ? people : types, selection: selected == .people ? $selectedPeople : $selectedTypes) }
            .sheet(item: $selectedEvent) { event in eventSheet(event) }
    }
    private func eventSheet(_ event: GenealogyConsultation.Event) -> some View {
        NavigationStack {
            List {
                Section("Event") { Text(event.type.capitalized); Text(event.date ?? "Undated"); if let place = event.placeName { Text(place) }; if let notes = event.row.text("notes") { Text(notes).textSelection(.enabled) } }
                Section("Participants") { ForEach(event.participants) { person in VStack(alignment: .leading) { GenealogyPersonLink(session: session, tables: tables, id: person.personId, name: person.name, downloadedOnly: downloadedOnly); Text(person.role).font(.caption).foregroundStyle(.secondary) } } }
                Section("Evidence") {
                    let evidence = (tables["record_evidence"] ?? []).filter { $0.string("target_kind") == "event" && $0.string("target_id") == event.id }
                    if evidence.isEmpty { Text("No attached evidence in this copy.").foregroundStyle(.secondary) }
                    ForEach(evidence, id: \.columns) { item in VStack(alignment: .leading, spacing: 6) { if let quote = item.text("quote") { Text(quote).italic().textSelection(.enabled) }; Text([item.text("source_kind"), item.text("location")].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) } }
                }
            }.navigationTitle(event.row.text("label") ?? event.type.capitalized)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selectedEvent = nil } } }
        }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do {
            let source = try await genealogyTables(session, names: ["persons", "places", "events", "event_participants", "record_evidence"], downloadedOnly: downloadedOnly, map: false)
            try Task.checkCancellation(); tables = source.tables; offline = source.offline; issue = nil
        } catch where error.isCancellation { }
        catch { tables = [:]; issue = error.localizedDescription }
    }
}
