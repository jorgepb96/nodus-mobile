import NodusKit
import NodusUI
import SwiftUI

enum SensitiveRecordsWorkspaceMode: String {
    case archive
    case prosopSearch, prosopPopulation, prosopPersons, prosopSources, prosopAnalysis, prosopNetworks
    case testimonyInterviews, testimonyParticipants, testimonyContrasts
}

struct SensitiveRecordsWorkspaceView: View {
    let session: SpaceSession
    let mode: SensitiveRecordsWorkspaceMode

    var body: some View {
        switch mode {
        case .archive:
            PrimarySourcesArchiveWorkspace(session: session)
        case .prosopSearch, .prosopPopulation, .prosopPersons, .prosopSources, .prosopAnalysis, .prosopNetworks:
            ProsopographyWorkspace(session: session, mode: mode)
        case .testimonyInterviews, .testimonyParticipants, .testimonyContrasts:
            TestimoniesWorkspace(session: session, mode: mode)
        }
    }
}

private struct PrivateDomainBanner: View {
    let cached: Bool
    let issue: String?
    let accent: Color
    let pair: () -> Void

    var body: some View {
        if let issue {
            VStack(alignment: .leading, spacing: 9) {
                NodusNotice(
                    tone: .info,
                    title: "Link your Mac",
                    message: LocalizedStringKey(issue),
                    systemImage: "lock.shield"
                )
                Button(action: pair) {
                    Label("Link your Mac", systemImage: "macbook.and.iphone")
                }
                .buttonStyle(NodusPrimaryButtonStyle(accent: accent))
            }
        } else {
            NodusNotice(
                tone: cached ? .caution : .info,
                title: cached ? "Encrypted offline copy" : "Connected to your Mac",
                message: cached
                    ? "This read-only copy stays encrypted on this device and is removed when you unlink your Mac. Reconnect to refresh it."
                    : "These private records come from your linked Mac and are not published publicly.",
                systemImage: cached ? "lock.doc" : "lock.shield.fill"
            )
        }
    }
}

// MARK: - Primary Sources

private let archivePrivateTables = [
    "archive_repositories", "archive_description_units", "archive_items", "archive_item_units",
    "archive_item_profiles", "archive_item_files", "archive_text_versions", "archive_text_segments",
    "archive_excerpts", "archive_source_analyses", "archive_entity_proposals", "archive_integrity_checks",
    "archive_audit_log",
]

private struct PrimarySourcesArchiveWorkspace: View {
    @Environment(WorkspaceTabs.self) private var tabs
    @Environment(\.horizontalSizeClass) private var sizeClass
    let session: SpaceSession
    @State private var tables: [String: [Row]] = [:]
    @State private var query = ""
    @State private var selectedUnit: String?
    @State private var cached = false
    @State private var issue: String?
    @State private var pairing = false
    @State private var detailSection = "Description"
    private let section = "archive"

    private var units: [SensitiveRecordsParity.ArchiveUnit] {
        SensitiveRecordsParity.archiveUnits(in: tables["archive_description_units"] ?? [])
    }
    private var items: [SensitiveRecordsParity.ArchiveItem] {
        SensitiveRecordsParity.archiveItems(in: tables).filter {
            (query.isEmpty || "\($0.title) \($0.description) \($0.provenance)".localizedCaseInsensitiveContains(query))
                && (selectedUnit == nil || itemIds(in: selectedUnit!).contains($0.id))
        }
    }
    private var active: SensitiveRecordsParity.ArchiveItem? {
        SensitiveRecordsParity.archiveItems(in: tables).first { $0.id == tabs.activeTabId(in: section) }
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTabStrip(section: section, catalogueTitle: "Archive", catalogueImage: "archivebox", accent: session.accent)
            if sizeClass == .regular {
                HStack(spacing: 0) {
                    hierarchyRail.frame(width: 292)
                    Divider()
                    content
                }
            } else {
                content
            }
        }
        .nodusPageBackdrop(accent: session.accent)
        .task(id: session.publishedRevision) { await load() }
        .nodusSheet(isPresented: $pairing) {
            DesktopBridgePairingSheet(accent: session.accent) { Task { await load() } }
        }
        .accessibilityIdentifier("primary-sources-archive-workspace")
    }

    @ViewBuilder private var content: some View {
        if let active { dossier(active) } else { catalogue }
    }

    private var hierarchyRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ARCHIVAL DESCRIPTION").font(.caption2.bold()).foregroundStyle(.secondary).padding(12)
            Button { selectedUnit = nil } label: {
                Label("Entire archive", systemImage: "archivebox")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(selectedUnit == nil ? session.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain).padding(.horizontal, 7)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(units) { unit in
                        Button { selectedUnit = unit.id } label: {
                            HStack(spacing: 7) {
                                Image(systemName: unit.level == "fonds" ? "shippingbox" : "folder")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(unit.title).lineLimit(1)
                                    Text(unit.referenceCode).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .font(.caption)
                            .padding(8)
                            .padding(.leading, CGFloat(unit.depth) * 13)
                            .background(selectedUnit == unit.id ? session.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }.padding(7)
            }
        }
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.48))
    }

    private var catalogue: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                DesktopPageHeader(
                    title: "Primary Sources",
                    subtitle: "Hierarchy, provenance, files, text versions and stable excerpts",
                    systemImage: "archivebox",
                    accent: session.accent
                )
                PrivateDomainBanner(cached: cached, issue: issue, accent: session.accent) { pairing = true }
                if sizeClass == .compact {
                    Menu {
                        Button("Entire archive") { selectedUnit = nil }
                        ForEach(units) { unit in Button(unit.title) { selectedUnit = unit.id } }
                    } label: {
                        Label(selectedUnit.flatMap { id in units.first { $0.id == id }?.title } ?? "Entire archive", systemImage: "folder")
                    }
                    .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
                }
                NodusSearchField(text: $query, prompt: "Search title, provenance or description", accent: session.accent)
                HStack {
                    archiveMetric("Sources", items.count, "doc.text")
                    archiveMetric("Files", items.reduce(0) { $0 + $1.fileCount }, "paperclip")
                    archiveMetric("Excerpts", items.reduce(0) { $0 + $1.excerptCount }, "quote.bubble")
                }
                ForEach(items) { item in
                    Button { open(item) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.richtext").font(.title2).foregroundStyle(session.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.headline)
                                Text("\(item.dateDisplay) · \(item.provenance)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text(item.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                CountBadge(count: item.fileCount, accent: session.accent)
                                Text(item.accessStatus).font(.caption2).foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .desktopContentRow(accent: session.accent)
                    }
                    .buttonStyle(NodusCardButtonStyle())
                    .accessibilityIdentifier("archive-open-\(item.id)")
                }
            }
            .padding(NodusSpace.page).frame(maxWidth: 1050).frame(maxWidth: .infinity).nodusTopAnchor()
        }
    }

    private func dossier(_ item: SensitiveRecordsParity.ArchiveItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                DesktopPageHeader(
                    title: LocalizedStringKey(item.title), subtitle: "\(item.dateDisplay) · \(item.provenance)",
                    systemImage: "doc.richtext", accent: session.accent
                )
                Picker("Archive detail", selection: $detailSection) {
                    ForEach(["Description", "Files", "Text", "Excerpts", "Analysis", "Audit"], id: \.self) { Text($0) }
                }
                .pickerStyle(.segmented)
                detail(item)
            }
            .padding(NodusSpace.page).frame(maxWidth: 1050).frame(maxWidth: .infinity).nodusTopAnchor()
        }
        .accessibilityIdentifier("archive-dossier-\(item.id)")
    }

    @ViewBuilder private func detail(_ item: SensitiveRecordsParity.ArchiveItem) -> some View {
        switch detailSection {
        case "Files":
            ForEach(rows("archive_item_files", owner: "item_id", id: item.id), id: \.columns) { row in
                HStack {
                    Image(systemName: row.text("role") == "master" ? "lock.doc" : "doc")
                        .foregroundStyle(session.accent)
                    VStack(alignment: .leading) {
                        Text(row.text("original_file_name") ?? "File").font(.callout.weight(.medium))
                        Text("\(row.text("role") ?? "representation") · \(byteCount(row.int("byte_size") ?? 0)) · SHA-256").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(row.text("verification_status") ?? "pending", systemImage: row.text("verification_status") == "verified" ? "checkmark.seal.fill" : "clock")
                        .font(.caption).foregroundStyle(row.text("verification_status") == "verified" ? .green : .orange)
                }.desktopContentRow(accent: session.accent)
                PrivateFileButton(session: session, kind: .archiveFile, id: row.string("file_id") ?? "")
            }
        case "Text":
            ForEach(rows("archive_text_versions", owner: "item_id", id: item.id), id: \.columns) { row in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { NodusChip(key: row.text("kind") ?? "literal", tint: session.accent); Spacer(); Text(row.text("status") ?? "automatic").font(.caption).foregroundStyle(.secondary) }
                    Text(row.text("content") ?? "").font(.body).textSelection(.enabled)
                }.desktopContentRow(accent: session.accent)
            }
        case "Excerpts":
            ForEach(rows("archive_excerpts", owner: "item_id", id: item.id), id: \.columns) { row in
                VStack(alignment: .leading, spacing: 7) {
                    Text("“\(row.text("quoted_text") ?? "")”").font(.body.italic()).textSelection(.enabled)
                    HStack { Label(row.text("locator_display") ?? "Locator", systemImage: "mappin.and.ellipse"); Spacer(); NodusChip(key: row.text("review_status") ?? "unreviewed", tint: session.accent) }.font(.caption)
                    Text(row.text("description") ?? "").font(.caption).foregroundStyle(.secondary)
                }.desktopContentRow(accent: session.accent)
            }
        case "Analysis":
            ForEach(rows("archive_source_analyses", owner: "item_id", id: item.id), id: \.columns) { row in
                ForEach([("Origin", "origin_notes"), ("Purpose and audience", "purpose_audience"), ("Perspective", "perspective_bias"), ("Silences", "silences_limits"), ("Corroboration", "corroboration")], id: \.0) { label, key in
                    VStack(alignment: .leading, spacing: 4) { Text(label).font(.caption.weight(.semibold)).foregroundStyle(session.accent); Text(row.text(key) ?? "—").font(.callout) }.desktopContentRow(accent: session.accent)
                }
            }
        case "Audit":
            ForEach(rows("archive_integrity_checks", owner: "item_id", id: item.id), id: \.columns) { row in
                Text(row.text("status") ?? "Integrity check").desktopContentRow(accent: session.accent)
            }
            NodusNotice(tone: .info, title: "Immutable lineage", message: "File hashes, text versions, excerpts and proposal decisions remain separate records; a review never overwrites its source.", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
        default:
            Text(item.description).font(.body)
            HStack { archiveMetric("Files", item.fileCount, "paperclip"); archiveMetric("Verified", item.verifiedFileCount, "checkmark.seal"); archiveMetric("Text versions", item.textVersionCount, "text.quote"); archiveMetric("Excerpts", item.excerptCount, "quote.bubble") }
            LabeledContent("Document type", value: item.documentType).desktopContentRow(accent: session.accent)
            LabeledContent("Access", value: item.accessStatus).desktopContentRow(accent: session.accent)
            LabeledContent("Processing", value: item.processingStatus).desktopContentRow(accent: session.accent)
        }
    }

    private func archiveMetric(_ title: LocalizedStringKey, _ value: Int, _ image: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Image(systemName: image).foregroundStyle(session.accent); Text("\(value)").font(.title2.bold().monospacedDigit()); Text(title).font(.caption2).foregroundStyle(.secondary) }.desktopContentRow(accent: session.accent).frame(maxWidth: .infinity)
    }
    private func itemIds(in unit: String) -> Set<String> { Set((tables["archive_item_units"] ?? []).filter { $0.string("unit_id") == unit }.compactMap { $0.string("item_id") }) }
    private func rows(_ table: String, owner: String, id: String) -> [Row] { (tables[table] ?? []).filter { $0.string(owner) == id } }
    private func byteCount(_ value: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) }
    private func open(_ item: SensitiveRecordsParity.ArchiveItem) { tabs.open(.init(id: item.id, title: item.title, systemImage: "doc.richtext", kind: .document, payload: .reference(kind: "archive", id: item.id)), in: section) }
    private func load() async {
        do {
            let snapshot = try await loadPrivateBridgeTables(session, domain: .primarySourceFiles, names: archivePrivateTables, fixture: debugSensitiveFixture(for: ["primary_sources", "genealogy"]))
            try Task.checkCancellation()
            tables = snapshot.tables; cached = snapshot.readFromEncryptedCache; issue = nil
#if DEBUG
            if ProcessInfo.processInfo.environment["NODUS_SHOW_TAB_DEMO"] == "1", tabs.tabs(in: section).isEmpty {
                SensitiveRecordsParity.archiveItems(in: tables).prefix(2).forEach(open)
            }
#endif
        } catch where error.isCancellation { }
        catch { tables = [:]; issue = error.localizedDescription }
    }
}

// MARK: - Prosopography

private struct ProsopographyWorkspace: View {
    @Environment(WorkspaceTabs.self) private var tabs
    let session: SpaceSession
    let mode: SensitiveRecordsWorkspaceMode
    @State private var tables: [String: [Row]] = [:]
    @State private var query = ""
    @State private var issue: String?
    @State private var cached = false
    @State private var pairing = false
    private let section = "prosopPersons"

    private var people: [SensitiveRecordsParity.ProsopPerson] {
        SensitiveRecordsParity.prosopPersons(in: tables).filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) }
    }
    private var active: SensitiveRecordsParity.ProsopPerson? {
        SensitiveRecordsParity.prosopPersons(in: tables).first { $0.id == tabs.activeTabId(in: section) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if mode == .prosopPersons {
                WorkspaceTabStrip(section: section, catalogueTitle: "People", catalogueImage: "person.2", accent: session.accent)
            }
            Group {
                switch mode {
                case .prosopSearch: searchView
                case .prosopPopulation: populationView
                case .prosopPersons:
                    if let active {
                        personDossier(active)
                    } else {
                        peopleCatalogue
                    }
                case .prosopSources: sourcesView
                case .prosopAnalysis: analysisView
                case .prosopNetworks: networksView
                default: EmptyView()
                }
            }
        }
        .nodusPageBackdrop(accent: session.accent)
        .task(id: session.publishedRevision) { await load() }
        .nodusSheet(isPresented: $pairing) { DesktopBridgePairingSheet(accent: session.accent) { Task { await load() } } }
        .accessibilityIdentifier("prosopography-\(mode.rawValue)-workspace")
    }

    private var privateBanner: some View { PrivateDomainBanner(cached: cached, issue: issue, accent: session.accent) { pairing = true } }
    private var searchView: some View { page(title: "Prosopography search", subtitle: "People, literal attestations, sources and factoids", image: "magnifyingglass") { privateBanner; NodusSearchField(text: $query, prompt: "Search the private corpus", accent: session.accent); ForEach(people) { personCard($0) }; ForEach((tables["prosop_sources"] ?? []).filter { query.isEmpty || $0.searchableText.localizedCaseInsensitiveContains(query) }, id: \.columns) { sourceCard($0) } } }
    private var populationView: some View { page(title: "Population", subtitle: "Explicit criteria, membership decisions and missingness", image: "person.3") { privateBanner; ForEach(tables["prosop_studies"] ?? [], id: \.columns) { study in VStack(alignment: .leading, spacing: 8) { Text(study.text("title") ?? "Study").font(.title2.bold()); Text(study.text("research_question") ?? "").font(.headline); Text(study.text("population_definition") ?? "").font(.callout).foregroundStyle(.secondary); HStack { metric("Expected", study.int("expected_population") ?? 0); metric("Included", memberships("included")); metric("Uncertain", memberships("uncertain")) } }.desktopContentRow(accent: session.accent) }; ForEach(tables["prosop_population_criteria"] ?? [], id: \.columns) { row in HStack { Image(systemName: row.text("kind") == "include" ? "checkmark.circle" : "minus.circle").foregroundStyle(session.accent); VStack(alignment: .leading) { Text(row.text("label") ?? "Criterion").font(.callout.weight(.medium)); Text(row.text("description") ?? "").font(.caption).foregroundStyle(.secondary) }; Spacer(); if row.int("required") == 1 { NodusChip(key: "required", tint: session.accent) } }.desktopContentRow(accent: session.accent) } } }
    private var peopleCatalogue: some View { page(title: "People", subtitle: "Identity, evidence, authority and completeness", image: "person.2") { privateBanner; NodusSearchField(text: $query, prompt: "Search people", accent: session.accent); ForEach(people) { person in Button { open(person) } label: { personCard(person) }.buttonStyle(NodusCardButtonStyle()).accessibilityIdentifier("prosop-person-open-\(person.id)") } } }
    private var sourcesView: some View { page(title: "Sources", subtitle: "Provenance, literal segments and source assessment", image: "archivebox") { privateBanner; ForEach(tables["prosop_sources"] ?? [], id: \.columns) { sourceCard($0) } } }
    private var analysisView: some View { page(title: "Analysis", subtitle: "Versioned definitions, cohorts, missingness and reproducible runs", image: "chart.bar") { privateBanner; ForEach(tables["prosop_analysis_definitions"] ?? [], id: \.columns) { definition in VStack(alignment: .leading, spacing: 8) { HStack { Text(definition.text("title") ?? "Analysis").font(.headline); Spacer(); NodusChip(key: definition.text("analysis_kind") ?? "analysis", tint: session.accent) }; if let run = run(definition.string("analysis_id")) { HStack { metric("Population", run.int("population_count") ?? 0); metric("Included", run.int("included_count") ?? 0); metric("Missing", missingTotal(run)) }; Text(run.text("input_fingerprint") ?? "").font(.caption2.monospaced()).foregroundStyle(.secondary) } }.desktopContentRow(accent: session.accent) } } }
    private var networksView: some View {
        page(title: "Networks", subtitle: "Explicit and derived edges retain their provenance", image: "point.3.connected.trianglepath.dotted") {
            privateBanner
            networkCanvas
            ForEach(SensitiveRecordsParity.networkEdges(in: tables["prosop_network_edges"] ?? [])) { edge in
                HStack {
                    Text(name(edge.sourceId))
                    Image(systemName: "arrow.left.and.right").foregroundStyle(session.accent)
                    Text(name(edge.targetId))
                    Spacer()
                    NodusChip(key: edge.origin, tint: edge.origin == "explicit" ? session.accent : .orange)
                    Text(String(format: "%.0f×", edge.weight)).font(.caption.monospacedDigit())
                }
                .desktopContentRow(accent: session.accent)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("prosop-network-edge-\(edge.id)-\(edge.origin)")
            }
        }
    }

    private func personDossier(_ person: SensitiveRecordsParity.ProsopPerson) -> some View { page(title: LocalizedStringKey(person.displayName), subtitle: "\(person.identityStatus) · \(person.reviewStatus)", image: "person.crop.circle") { HStack { metric("Completeness", Int((person.completeness ?? 0) * 100), suffix: "%"); metric("Factoids", person.factoidCount); metric("Statements", person.statementCount); metric("Authorities", person.authorityCount) }; ForEach(statements(person.id), id: \.columns) { row in VStack(alignment: .leading, spacing: 5) { HStack { Text(row.text("statement_type") ?? "Statement").font(.caption.weight(.semibold)).foregroundStyle(session.accent); Spacer(); NodusChip(key: row.text("status") ?? "draft", tint: session.accent) }; Text(row.text("literal_value") ?? row.text("value_text") ?? "").font(.body); Text("Reading: \(row.text("reading_certainty") ?? "unknown")").font(.caption).foregroundStyle(.secondary) }.desktopContentRow(accent: session.accent) }; ForEach((tables["prosop_authority_ids"] ?? []).filter { $0.string("entity_id") == person.id }, id: \.columns) { row in LabeledContent(row.text("scheme") ?? "Authority", value: row.text("external_id") ?? "").desktopContentRow(accent: session.accent) }; ForEach((tables["prosop_audit_log"] ?? []).filter { $0.string("entity_id") == person.id }, id: \.columns) { row in VStack(alignment: .leading) { Label(row.text("action") ?? "Audit", systemImage: "clock.arrow.circlepath"); Text(row.text("reason") ?? "").font(.caption).foregroundStyle(.secondary) }.desktopContentRow(accent: session.accent) } } }
    private func personCard(_ person: SensitiveRecordsParity.ProsopPerson) -> some View { HStack { Circle().fill(session.accent.opacity(0.15)).frame(width: 40, height: 40).overlay { Text(person.displayName.prefix(1)).font(.headline).foregroundStyle(session.accent) }; VStack(alignment: .leading) { Text(person.displayName).font(.headline); Text("\(person.identityStatus) · \(person.factoidCount) factoids · \(person.statementCount) statements").font(.caption).foregroundStyle(.secondary) }; Spacer(); ProgressView(value: person.completeness ?? 0).frame(width: 75).tint(session.accent) }.desktopContentRow(accent: session.accent) }
    private func sourceCard(_ source: Row) -> some View { VStack(alignment: .leading, spacing: 5) { HStack { Image(systemName: "archivebox").foregroundStyle(session.accent); Text(source.text("title") ?? "Source").font(.headline); Spacer(); NodusChip(key: source.text("access_status") ?? "open", tint: session.accent) }; Text(source.text("citation") ?? "").font(.caption.monospaced()).foregroundStyle(.secondary); Text(source.text("description") ?? "").font(.callout) }.desktopContentRow(accent: session.accent) }
    private var networkCanvas: some View { Canvas { context, size in let nodes = SensitiveRecordsParity.prosopPersons(in: tables); let edges = SensitiveRecordsParity.networkEdges(in: tables["prosop_network_edges"] ?? []); let center = CGPoint(x: size.width / 2, y: size.height / 2); let radius = min(size.width, size.height) * 0.34; let points = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { index, node in (node.id, CGPoint(x: center.x + cos(Double(index) / Double(max(1, nodes.count)) * .pi * 2) * radius, y: center.y + sin(Double(index) / Double(max(1, nodes.count)) * .pi * 2) * radius)) }); for edge in edges { guard let a = points[edge.sourceId], let b = points[edge.targetId] else { continue }; var path = Path(); path.move(to: a); path.addLine(to: b); context.stroke(path, with: .color(edge.origin == "explicit" ? session.accent : .orange), lineWidth: max(1, min(5, edge.weight))) }; for node in nodes { guard let point = points[node.id] else { continue }; context.fill(Path(ellipseIn: CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22)), with: .color(session.accent)); context.draw(Text(node.displayName).font(.caption2), at: CGPoint(x: point.x, y: point.y + 22)) } }.frame(height: 320).desktopContentRow(accent: session.accent).accessibilityHidden(true) }

    private func page<Content: View>(title: LocalizedStringKey, subtitle: LocalizedStringKey, image: String, @ViewBuilder content: () -> Content) -> some View { ScrollView { VStack(alignment: .leading, spacing: 13) { DesktopPageHeader(title: title, subtitle: subtitle, systemImage: image, accent: session.accent); content() }.padding(NodusSpace.page).frame(maxWidth: 1000).frame(maxWidth: .infinity).nodusTopAnchor() } }
    private func metric(_ title: LocalizedStringKey, _ value: Int, suffix: String = "") -> some View { VStack(alignment: .leading) { Text("\(value)\(suffix)").font(.title2.bold().monospacedDigit()); Text(title).font(.caption2).foregroundStyle(.secondary) }.desktopContentRow(accent: session.accent).frame(maxWidth: .infinity) }
    private func memberships(_ status: String) -> Int { (tables["prosop_population_memberships"] ?? []).filter { $0.text("status") == status }.count }
    private func run(_ analysis: String?) -> Row? { (tables["prosop_analysis_runs"] ?? []).filter { $0.string("analysis_id") == analysis }.max { ($0.text("created_at") ?? "") < ($1.text("created_at") ?? "") } }
    private func missingTotal(_ run: Row) -> Int { run.embeddedJSON("missing_summary_json")?.objectValue?.values.compactMap(\.intValue).reduce(0, +) ?? 0 }
    private func name(_ id: String) -> String { SensitiveRecordsParity.prosopPersons(in: tables).first { $0.id == id }?.displayName ?? id }
    private func statements(_ person: String) -> [Row] { let ids = Set((tables["prosop_statement_entities"] ?? []).filter { $0.string("entity_id") == person && $0.text("entity_kind") == "person" }.compactMap { $0.string("statement_id") }); return (tables["prosop_statements"] ?? []).filter { ids.contains($0.string("statement_id") ?? "") } }
    private func open(_ person: SensitiveRecordsParity.ProsopPerson) { tabs.open(.init(id: person.id, title: person.displayName, systemImage: "person.crop.circle", kind: .document, payload: .reference(kind: "prosop-person", id: person.id)), in: section) }
    private func load() async {
        do {
            let names = ["persons", "prosop_studies", "prosop_population_criteria", "prosop_population_memberships", "prosop_person_profiles", "prosop_sources", "prosop_source_segments", "prosop_factoids", "prosop_statements", "prosop_statement_entities", "prosop_authority_ids", "prosop_analysis_definitions", "prosop_analysis_runs", "prosop_network_layers", "prosop_network_edges", "prosop_audit_log"]
            let snapshot = try await loadPrivateBridgeTables(session, domain: .prosopographyPrivate, names: names, fixture: debugSensitiveFixture(for: ["prosopography"]))
            try Task.checkCancellation()
            tables = snapshot.tables; cached = snapshot.readFromEncryptedCache; issue = nil
#if DEBUG
            if mode == .prosopPersons, ProcessInfo.processInfo.environment["NODUS_SHOW_TAB_DEMO"] == "1", tabs.tabs(in: section).isEmpty { SensitiveRecordsParity.prosopPersons(in: tables).prefix(2).forEach(open) }
#endif
        } catch where error.isCancellation { }
        catch { tables = [:]; issue = error.localizedDescription }
    }
}

// MARK: - Testimonies

private struct TestimoniesWorkspace: View {
    @Environment(WorkspaceTabs.self) private var tabs
    let session: SpaceSession
    let mode: SensitiveRecordsWorkspaceMode
    @State private var tables: [String: [Row]] = [:]
    @State private var query = ""
    @State private var issue: String?
    @State private var cached = false
    @State private var pairing = false
    private let section = "testimonyInterviews"
    private var interviews: [SensitiveRecordsParity.TestimonyInterview] { SensitiveRecordsParity.testimonyInterviews(in: tables).filter { query.isEmpty || "\($0.title) \($0.participantNames.joined(separator: " "))".localizedCaseInsensitiveContains(query) } }
    private var active: SensitiveRecordsParity.TestimonyInterview? { SensitiveRecordsParity.testimonyInterviews(in: tables).first { $0.id == tabs.activeTabId(in: section) } }

    var body: some View {
        if session.connection.desktopPairingId != nil {
            switch mode {
            case .testimonyInterviews: PrivateSourceCatalogueView(session: session, kind: .interview, title: "Entrevistas", icon: "mic")
            case .testimonyParticipants: PrivateSourceCatalogueView(session: session, kind: .participant, title: "Participantes", icon: "person.2")
            case .testimonyContrasts: PrivateSourceCatalogueView(session: session, kind: .contrast, title: "Contrastes", icon: "scale.3d")
            default: EmptyView()
            }
        } else {
        VStack(spacing: 0) {
            if mode == .testimonyInterviews { WorkspaceTabStrip(section: section, catalogueTitle: "Interviews", catalogueImage: "mic", accent: session.accent) }
            switch mode {
            case .testimonyInterviews: if let active { interviewDossier(active) } else { interviewsCatalogue }
            case .testimonyParticipants: participantsView
            case .testimonyContrasts: contrastsView
            default: EmptyView()
            }
        }
        .nodusPageBackdrop(accent: session.accent).task(id: session.publishedRevision) { await load() }
        .nodusSheet(isPresented: $pairing) { DesktopBridgePairingSheet(accent: session.accent) { Task { await load() } } }
        .accessibilityIdentifier("testimonies-\(mode.rawValue)-workspace")
        }
    }

    private var banner: some View { PrivateDomainBanner(cached: cached, issue: issue, accent: session.accent) { pairing = true } }
    private var interviewsCatalogue: some View { page(title: "Interviews", subtitle: "Sessions, consent, media lineage, transcripts and codes", image: "mic") { banner; NodusSearchField(text: $query, prompt: "Search interviews and public participant names", accent: session.accent); ForEach(interviews) { interview in Button { open(interview) } label: { HStack { Image(systemName: "waveform.circle.fill").font(.title2).foregroundStyle(session.accent); VStack(alignment: .leading) { Text(interview.title).font(.headline); Text(interview.participantNames.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary); Text("\(interview.sessionCount) sessions · \(interview.transcriptCount) transcripts · \(interview.annotationCount) annotations").font(.caption2).foregroundStyle(.secondary) }; Spacer(); VStack(alignment: .trailing) { NodusChip(key: interview.workflowStatus, tint: session.accent); Text(interview.accessLevel).font(.caption2).foregroundStyle(.secondary) }; Image(systemName: "chevron.right").foregroundStyle(.secondary) }.desktopContentRow(accent: session.accent) }.buttonStyle(NodusCardButtonStyle()).accessibilityIdentifier("testimony-interview-open-\(interview.id)") } } }
    private var participantsView: some View { page(title: "Participants", subtitle: "Public attribution remains separate from the working identity", image: "person.2") { banner; ForEach(tables["testimony_participant_profiles"] ?? [], id: \.columns) { row in VStack(alignment: .leading, spacing: 7) { HStack { Circle().fill(session.accent.opacity(0.15)).frame(width: 40, height: 40).overlay { Text((row.text("public_name") ?? "?").prefix(1)).foregroundStyle(session.accent) }; VStack(alignment: .leading) { Text(row.text("public_name") ?? "Restricted participant").font(.headline); Text(row.text("identity_mode") ?? "identified").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "lock.shield").foregroundStyle(session.accent) }; Text(row.text("biographical_note") ?? "").font(.callout); Text(row.text("attribution_note") ?? "").font(.caption).foregroundStyle(.secondary) }.desktopContentRow(accent: session.accent) } } }
    private var contrastsView: some View { page(title: "Contrasts", subtitle: "Pinned fragments preserve disagreement and access decisions", image: "scale.3d") { banner; ForEach(tables["testimony_contrasts"] ?? [], id: \.columns) { contrast in VStack(alignment: .leading, spacing: 9) { Text(contrast.text("title") ?? "Contrast").font(.title3.bold()); Text(contrast.text("memo_markdown") ?? "").font(.callout); ForEach(contrastAnnotations(contrast.string("id")), id: \.columns) { annotation in VStack(alignment: .leading, spacing: 4) { Text("“\(annotation.text("quote_snapshot") ?? "")”").font(.body.italic()); Text(annotation.text("memo") ?? "").font(.caption).foregroundStyle(.secondary); HStack { Label(duration(annotation.double("t_start") ?? 0), systemImage: "waveform"); Spacer(); NodusChip(key: annotation.text("link_status") ?? "valid", tint: session.accent) }.font(.caption) }.padding(10).background(session.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 9)) } }.desktopContentRow(accent: session.accent) } } }

    private func interviewDossier(_ interview: SensitiveRecordsParity.TestimonyInterview) -> some View {
        page(
            title: LocalizedStringKey(interview.title),
            subtitle: "\(interview.collection) · \(interview.participantNames.joined(separator: ", "))",
            image: "waveform"
        ) {
            HStack {
                metric("Sessions", interview.sessionCount)
                metric("Media", interview.mediaCount)
                metric("Transcripts", interview.transcriptCount)
                metric("Annotations", interview.annotationCount)
            }
            NodusNotice(
                tone: interview.accessLevel == "embargoed" ? .caution : .info,
                title: "\(interview.agreementStatus) · \(interview.accessLevel)",
                message: LocalizedStringKey(agreement(interview.id)?.text("restrictions_markdown") ?? "No broader use is inferred from workflow status."),
                systemImage: "hand.raised.fill"
            )
            .accessibilityIdentifier("testimony-access-\(interview.accessLevel)-\(interview.agreementStatus)")
            ForEach(sessions(interview.id), id: \.columns) { sessionRow in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(sessionRow.text("title") ?? "Session").font(.headline)
                        Spacer()
                        NodusChip(key: sessionRow.text("status") ?? "planned", tint: session.accent)
                    }
                    Text(sessionRow.text("field_notes") ?? "").font(.caption).foregroundStyle(.secondary)
                    ForEach(media(sessionRow.string("id")), id: \.columns) { medium in
                        HStack {
                            Image(systemName: "waveform").foregroundStyle(session.accent)
                            VStack(alignment: .leading) {
                                Text(medium.text("file_name") ?? "Master audio").font(.callout.weight(.medium))
                                Text("\(duration(medium.double("duration_seconds") ?? 0)) · \(medium.text("role") ?? "master") · SHA-256")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if medium.int("immutable") == 1 {
                                Label("Immutable", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 3)
                        PrivateFileButton(session: session, kind: .testimonyMedia, id: medium.string("id") ?? "")
                        ForEach(transcripts(medium.string("id")), id: \.columns) { transcript in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    NodusChip(key: transcript.text("kind") ?? "literal", tint: session.accent)
                                    Text("v\(transcript.int("version_no") ?? 1)").font(.caption.monospacedDigit())
                                    Spacer()
                                    Text(transcript.text("status") ?? "pending").font(.caption).foregroundStyle(.secondary)
                                }
                                Text(transcript.text("content_markdown") ?? "").font(.body).textSelection(.enabled)
                            }
                            .padding(10)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }.desktopContentRow(accent: session.accent)
            }
        }
    }
    private func page<Content: View>(title: LocalizedStringKey, subtitle: LocalizedStringKey, image: String, @ViewBuilder content: () -> Content) -> some View { ScrollView { VStack(alignment: .leading, spacing: 13) { DesktopPageHeader(title: title, subtitle: subtitle, systemImage: image, accent: session.accent); content() }.padding(NodusSpace.page).frame(maxWidth: 1000).frame(maxWidth: .infinity).nodusTopAnchor() } }
    private func metric(_ title: LocalizedStringKey, _ value: Int) -> some View { VStack(alignment: .leading) { Text("\(value)").font(.title2.bold().monospacedDigit()); Text(title).font(.caption2).foregroundStyle(.secondary) }.desktopContentRow(accent: session.accent).frame(maxWidth: .infinity) }
    private func agreement(_ interview: String) -> Row? { (tables["testimony_agreements"] ?? []).filter { $0.string("interview_id") == interview && $0.int("is_current") == 1 }.max { ($0.int("version_no") ?? 0) < ($1.int("version_no") ?? 0) } }
    private func sessions(_ interview: String) -> [Row] { (tables["testimony_sessions"] ?? []).filter { $0.string("interview_id") == interview }.sorted { ($0.int("sequence_no") ?? 0) < ($1.int("sequence_no") ?? 0) } }
    private func media(_ sessionId: String?) -> [Row] { (tables["testimony_media"] ?? []).filter { $0.string("session_id") == sessionId } }
    private func transcripts(_ mediaId: String?) -> [Row] { (tables["testimony_transcripts"] ?? []).filter { $0.string("media_id") == mediaId }.sorted { ($0.int("version_no") ?? 0) > ($1.int("version_no") ?? 0) } }
    private func contrastAnnotations(_ contrast: String?) -> [Row] { let ids = Set((tables["testimony_contrast_items"] ?? []).filter { $0.string("contrast_id") == contrast }.compactMap { $0.string("annotation_id") }); return (tables["testimony_annotations"] ?? []).filter { ids.contains($0.string("id") ?? "") } }
    private func duration(_ seconds: Double) -> String { let value = Int(seconds); return "\(value / 60):\(String(format: "%02d", value % 60))" }
    private func open(_ interview: SensitiveRecordsParity.TestimonyInterview) { tabs.open(.init(id: interview.id, title: interview.title, systemImage: "waveform", kind: .document, payload: .reference(kind: "testimony", id: interview.id)), in: section) }
    private func load() async {
        do {
            let names = ["persons", "testimony_interviews", "testimony_participant_profiles", "testimony_interview_participants", "testimony_sessions", "testimony_media", "testimony_transcripts", "testimony_transcript_segments", "testimony_codes", "testimony_annotations", "testimony_annotation_codes", "testimony_agreements", "testimony_contrasts", "testimony_contrast_items", "testimony_note_links"]
            let snapshot = try await loadPrivateBridgeTables(session, domain: .testimonies, names: names, fixture: debugSensitiveFixture(for: ["testimonios"]))
            try Task.checkCancellation()
            tables = snapshot.tables; cached = snapshot.readFromEncryptedCache; issue = nil
#if DEBUG
            if mode == .testimonyInterviews, ProcessInfo.processInfo.environment["NODUS_SHOW_TAB_DEMO"] == "1", tabs.tabs(in: section).isEmpty { SensitiveRecordsParity.testimonyInterviews(in: tables).prefix(2).forEach(open) }
#endif
        } catch where error.isCancellation { }
        catch { tables = [:]; issue = error.localizedDescription }
    }
}

private func debugSensitiveFixture(for vaultTypes: Set<String>) -> [String: [Row]] {
#if DEBUG
    guard
        let override = ProcessInfo.processInfo.environment["NODUS_VAULT_TYPE_OVERRIDE"],
        vaultTypes.contains(override),
        let url = Bundle.main.url(forResource: "sensitive-records-fixture", withExtension: "json"),
        let data = try? Data(contentsOf: url),
        let object = try? JSONDecoder().decode([String: JSONValue].self, from: data)
    else { return [:] }
    return object.compactMapValues { $0.arrayValue?.compactMap { $0.objectValue.map(Row.init) } }
#else
    return [:]
#endif
}
