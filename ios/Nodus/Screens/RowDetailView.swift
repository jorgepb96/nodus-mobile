import NodusKit
import NodusUI
import SwiftUI

/// One row, opened.
///
/// Domain readers preserve the whole public dossier, including versions and
/// nested sections added by Desktop. Large relation lists grow on demand.
struct RowDetailView: View {
    let session: SpaceSession
    let collection: CollectionDescriptor?
    @State private var row: Row
    var title: String?
    /// Root workspaces use this to keep related records in sibling tabs. Nested dossiers that
    /// are not tabbed leave it nil and retain ordinary NavigationStack pushes.
    var onOpenRelated: ((CollectionDescriptor, Row) -> Void)?

    @State private var enriched: Enriched?
    @State private var isLoading = false
    @State private var error: String?
    @State private var relationLimits: [String: Int] = [:]
    @State private var evidenceLimit = 40
    @State private var supplement: CollectionDossier?
    @State private var resourceDossier: CollectionDossier?
    @State private var fromDevice = false

    init(
        session: SpaceSession,
        collection: CollectionDescriptor?,
        row: Row,
        title: String? = nil,
        onOpenRelated: ((CollectionDescriptor, Row) -> Void)? = nil
    ) {
        self.session = session
        self.collection = collection
        self.title = title
        self.onOpenRelated = onOpenRelated
        _row = State(initialValue: row)
    }

    enum Enriched {
        case idea(IdeaDetail)
        case work(WorkDetail)
        case person(PersonDetail)
        case author(AuthorDetail)
        case database(DatabaseDetail)
        case exam(ExamDetail)
        case plan(StudyPlanDetail)
        case dossier(CollectionDossier)
    }

    private var presenter: RowPresenter {
        collection?.presenter ?? RowPresenter.generic(table: title ?? "row")
    }

    private var theme: String? { row.string("theme_id") }

    /// The Zotero item this record came from, when it came from one.
    ///
    /// Read from the enriched work as well as from the row: a work reached through a citation is
    /// fetched by the enriched handler, and the row this view was handed is the one the *list*
    /// carried, which for some routes is a summary without the key in it. Blank keys are treated
    /// as absent — the column exists for every work, including the ones a vault created by hand.
    private var zoteroKey: String? {
        let raw: String?
        if case .work(let detail) = enriched {
            raw = detail.work.string("zotero_key") ?? row.string("zotero_key")
        } else {
            raw = row.string("zotero_key")
        }
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var body: some View {
        // An exam is a document, not a dossier: it gets the whole screen rather than a
        // "Questions" section under a field list nobody reads.
        if session.connection.desktopPairingId != nil, let collection,
           let id = row.string(collection.idField),
           let reference = try? PrivateCorpusReference.collectionReference(path: collection.path, id: id) {
            PrivateCorpusSourceView(session: session, reference: reference)
        } else if case .exam(let detail) = enriched {
            ExamView(session: session, detail: detail)
        } else {
            dossier
        }
    }

    private var dossier: some View {
        ScrollView {
            // `NodusSpace.block`, not 16. A dossier is three or four different kinds of thing
            // stacked — what the idea says, the passages under it, the edges out of it, and the
            // raw record at the bottom — and at 16 points apart they read as one long card with
            // occasional bold words in it. The distance is what says where one ends.
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                heading
                if fromDevice {
                    Label("Sin conexión · contenido de este dispositivo", systemImage: "wifi.slash")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let state = row.string("mobileSyncState") {
                    Label(state == "pending" ? "Guardado en este dispositivo · pendiente de sincronizar" : "Guardado en este dispositivo · revisa la sincronización en Scriptor", systemImage: "iphone")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Under the title, because following a work back to the library it came from is
                // something a reader does *instead* of reading this screen rather than after it.
                if let key = zoteroKey {
                    ZoteroItemLink(key: key, accent: session.accent)
                }

                if let error {
                    NodusNotice(tone: .caution, title: "Could not expand", message: LocalizedStringKey(error))
                    Button("Reintentar") { Task { await enrich() } }.frame(minHeight: 44).disabled(isLoading)
                }
                if isLoading { ProgressView("Cargando dossier…").tint(session.accent) }

                if collection?.path == "themes", theme != nil {
                    NavigationLink {
                        ThemeIdeasView(session: session, theme: row)
                    } label: {
                        HStack {
                            Label("See the ideas under this theme", systemImage: "lightbulb")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(NodusSpace.cardPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .nodusGlass(NodusGlass(.regular, tint: session.accent))
                    }
                    .buttonStyle(NodusCardButtonStyle())
                }

                switch enriched {
                case .idea(let detail): ideaBody(detail)
                case .work(let detail): workBody(detail)
                case .person(let detail): personBody(detail)
                case .author(let detail): authorBody(detail)
                case .database(let detail): databaseBody(detail)
                case .plan(let detail): planBody(detail)
                case .dossier(let detail):
                    if collection?.path == "passages" { passageBody(detail.primary) }
                    else { CollectionDossierBody(session: session, dossier: detail, showConnectionState: false, onOpenRelated: onOpenRelated) }
                // Handled above: an exam replaces the dossier rather than sitting inside it.
                case .exam: EmptyView()
                case nil:
                    // A passage has no enriched handler on the server and never will: it is one
                    // row. But the generic renderer showed it as a field list — chunk index,
                    // page, ids — with the quotation itself just another row in the table, and
                    // a quotation is the only reason to open one.
                    if collection?.path == "passages" {
                        passageBody(row)
                    } else {
                        fields(of: row)
                    }
                }
                if let resourceDossier { DossierOriginalResourcesView(session: session, dossier: resourceDossier) }
                if let supplement {
                    CollectionDossierBody(session: session, dossier: supplement, displayPrimary: false, showConnectionState: false, onOpenRelated: onOpenRelated)
                }
            }
            .padding(NodusSpace.page)
            .nodusTopAnchor()
        }
        .nodusPageFunctions(accent: session.accent)
        // A dossier is a document. Nothing the tab bar leads to is on it, and the four tabs
        // under a quotation are four ways to stop reading it.
        .nodusHidesBottomBar()
        // `LocalizedStringKey`, not the bare `String`: a collection's label is a value, and a
        // value handed to `navigationTitle` ships in the base language on every phone — which
        // is how a Spanish reader opening a citation landed on a screen titled "Library". The
        // fallback was worse: a Spanish literal, in an app whose base language is English.
        .navigationTitle(Text(LocalizedStringKey(collection?.label ?? title ?? "Detail")))
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        // Keep an already-open dossier on the same publication as its parent list. The
        // revision task preserves navigation and scroll position while replacing the record.
        .task(id: session.publishedRevision) { await enrich() }
    }

    @ViewBuilder
    private var heading: some View {
        // A passage's presented title *is* its text, which is right in a list and absurd as a
        // heading: several hundred characters set in a semibold title, with the same text
        // repeated underneath. Its heading is where it comes from.
        if collection?.path == "passages" {
            VStack(alignment: .leading, spacing: 6) {
                Text("Passage")
                    .font(.title3.weight(.semibold))
                if let page = CorpusSearch.pageLabel(row) {
                    Text(page).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(NodusSpace.cardPadding)
            .nodusGlass(NodusGlass(.regular, tint: session.accent))
        } else {
            genericHeading
        }
    }

    private var genericHeading: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(presenter.title(row))
                // Long titles are the norm here, not the exception: an idea's label is a
                // sentence and a work's title is a sentence with a subtitle after it. At a flat
                // `.title3` the four-line ones took most of a phone screen before the reader
                // reached anything they had not already read in the list. Allowed to shrink a
                // fifth and to stop at four lines, a long title is still a heading and a short
                // one is unchanged.
                .font(.title3.weight(.semibold))
                .lineLimit(4)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = presenter.subtitle(row) {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            if let detail = presenter.detail(row) {
                NodusChip(detail, tint: session.accent.nodusReadable)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(NodusSpace.cardPadding)
        .nodusGlass(NodusGlass(.regular, tint: session.accent))
    }

    // MARK: Enriched bodies

    private func ideaBody(_ detail: IdeaDetail) -> some View {
        VStack(alignment: .leading, spacing: NodusSpace.block) {
            // Start with provenance: before classifying an idea by theme, show the works where
            // the reader can actually find it. This also puts the most useful navigation out
            // of an idea above its longer evidence and record sections.
            if detail.idea.string("mobileSourceScope") == "authoredText" {
                NodusNotice(tone: .info, title: "Texto escrito en este móvil", message: "Las evidencias y conexiones necesitan su propia descarga para consultarlas sin el Mac.")
            } else { occurrencesSection(detail) }
            if !detail.themes.isEmpty {
                chips(detail.themes, label: "Themes")
            }
            // The passages live here rather than in a section of their own, because a quotation
            // means something as the support for a claim and very little in a list of 5 803.
            if !detail.evidence.isEmpty {
                section("Passages that support it", count: detail.evidence.count) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(detail.evidence.prefix(evidenceLimit).enumerated()), id: \.offset) { index, item in
                            VStack(alignment: .leading, spacing: 8) {
                                if let quote = item.text("quote") {
                                    Text(quote)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                        .padding(.leading, 11)
                                        .overlay(alignment: .leading) {
                                            Rectangle()
                                                .fill(session.accent.opacity(0.5))
                                                .frame(width: 2)
                                        }
                                }
                                // Where it is and how it was read, as two tags on one line
                                // rather than as two loose sizes of grey. Same height, same
                                // type, same padding as every other tag in the app.
                                HStack(spacing: 6) {
                                    if let location = item.text("location") {
                                        // The corpus's own words — "p. 40", "ff. 12–14" — so
                                        // the chip is not allowed to tidy the case.
                                        NodusChip(location, tint: .nodusSecondaryText, capitalises: false)
                                    }
                                    if let kind = item.text("kind") {
                                        NodusChip(
                                            kind == "explicit"
                                                ? String(localized: "Explicit")
                                                : String(localized: "Paraphrased"),
                                            tint: session.accent.nodusReadable
                                        )
                                    }
                                }
                            }
                            if index < min(detail.evidence.count, evidenceLimit) - 1 { Divider().opacity(0.3) }
                        }
                        if detail.evidence.count > evidenceLimit {
                            Button("Mostrar más evidencias") { evidenceLimit += 40 }.frame(minHeight: 44)
                        }
                    }
                }
            }
            fields(of: detail.idea)
            if detail.idea.string("mobileSourceScope") != "authoredText" { relationsSection(detail) }
        }
    }

    private func workBody(_ detail: WorkDetail) -> some View {
        VStack(alignment: .leading, spacing: NodusSpace.block) {
            if session.connection.desktopPairingId != nil, let workId = detail.work.string("nodus_id") {
                NavigationLink {
                    SourceDocumentReader(session: session, target: SourceDocumentTarget(itemId: workId, scope: .vault, page: nil, attachmentId: nil))
                } label: { Label("Abrir documento", systemImage: "doc.text").frame(minHeight: 44) }
                    .accessibilityIdentifier("work-open-source-document")
            }
            if detail.passages > 0 {
                NodusNotice(
                    tone: .info,
                    title: detail.passages == 1 ? "1 passage extracted" : "\(detail.passages) passages extracted",
                    message: "Consulta los pasajes desde las ideas que sustentan o abre el documento para seguir leyendo.",
                    systemImage: "text.quote"
                )
            }
            fields(of: detail.work)
            group("Ideas", detail.ideas, table: "ideas", linksTo: Collections["ideas"])
            if let summary = detail.summary {
                section("Synthesis") { fields(of: summary) }
            }
        }
    }

    /// A passage: the quotation, where it came from, and the rest of the row underneath.
    ///
    /// The text is not always there. Passages are the one table the desktop leaves out of a
    /// publication by default — extracted full text can be licensed — so a space can carry the
    /// passage *vectors*, and therefore the search hits, while the rows themselves arrive as
    /// coordinates with nothing to read. That is a fact about the publication, not a bug in the
    /// screen, and saying it is the only useful thing this view can do in that case.
    @ViewBuilder
    private func passageBody(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: NodusSpace.block) {
            if let text = row.text("text") ?? row.text("content") {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(session.accent.opacity(0.45)).frame(width: 3)
                        }
                }
                .padding(16)
                .nodusGlass(NodusGlass(.thin, tint: session.accent))
            } else {
                NodusNotice(
                    tone: .caution,
                    title: "The text of this passage was not published",
                    message: "Extracted full text can be licensed, so a space carries it only when its owner turns that on. The passage is here, and what it says is not.",
                    systemImage: "text.quote"
                )
            }

            if let workId = row.string("nodus_id") {
                NavigationLink {
                    WorkByIdView(session: session, nodusId: workId)
                } label: {
                    HStack {
                        Label(
                            session.names.work(workId).map { LocalizedStringKey($0) } ?? "Open the work",
                            systemImage: "book.closed"
                        )
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(NodusSpace.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .nodusGlass(NodusGlass(.regular, tint: session.accent))
                }
                .buttonStyle(NodusCardButtonStyle())
                .task { await session.names.resolve(workIds: [workId]) }
            }

            // The coordinates stay, below the quotation rather than instead of it — minus the
            // text itself, which is now the screen.
            fields(of: row, hiding: ["text", "content"])
        }
    }

    private func personBody(_ detail: PersonDetail) -> some View {
        VStack(alignment: .leading, spacing: NodusSpace.block) {
            if let personId = detail.person.string("person_id") {
                NavigationLink {
                    FamilyTreeView(session: session, rootPersonId: personId)
                } label: {
                    HStack {
                        Label("See the tree from here", systemImage: "point.3.filled.connected.trianglepath.dotted")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(NodusSpace.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .nodusGlass(NodusGlass(.regular, tint: session.accent))
                }
                .buttonStyle(NodusCardButtonStyle())
            }
            if let portrait = detail.portrait, let hash = portrait.text("asset_ref") ?? portrait.text("hash") {
                AssetImage(session: session, hash: hash)
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipShape(NodusRadius.panelShape)
            }
            fields(of: detail.person)
            group("Names", detail.names, table: "person_names")
            group("Relationships", detail.relationships, table: "relationships")
            group("Events", detail.events, table: "events", linksTo: Collections["events"])
            group("Places", detail.places, table: "places", linksTo: Collections["places"])
        }
    }

    private func authorBody(_ detail: AuthorDetail) -> some View {
        VStack(alignment: .leading, spacing: NodusSpace.block) {
            fields(of: detail.author)
            // The synthesis is what the dossier is *for*: it says what this author argues
            // across everything the corpus holds of theirs. Below a list of works — which for
            // a well-read author is forty rows — it was the one thing nobody scrolled to.
            if let synthesis = detail.synthesis {
                section("Synthesis") { fields(of: synthesis) }
            }
            group("Works", detail.works, table: "works", linksTo: Collections["works"])
            authorRelationsSection(detail)
        }
    }

    /// An author's relations shown as the *other author*.
    ///
    /// `author_relations` is `{from_author, to_author, type, weight}` and carries no name at
    /// all, so the generic presenter had nothing to title a row with: a dossier with a hundred
    /// and eleven relations rendered as a hundred and eleven rows reading "Untitled" over the
    /// word "contradicts". The names come from one page of the authors table, not one request
    /// per row.
    private func authorRelationsSection(_ detail: AuthorDetail) -> some View {
        let selfId = detail.author.string("author_id") ?? ""
        return Group {
            if !detail.relations.isEmpty {
                section("Relationships", count: detail.relations.count) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(detail.relations.enumerated()), id: \.offset) { index, edge in
                            authorRelationRow(edge, selfId: selfId)
                            if index < detail.relations.count - 1 { Divider().opacity(0.35) }
                        }
                    }
                }
            }
        }
        .task { await session.names.preloadAuthors() }
    }

    private func authorRelationRow(_ edge: Row, selfId: String) -> some View {
        let otherId = (edge.string("from_author") == selfId ? edge.string("to_author") : edge.string("from_author")) ?? ""
        let relation = edge.text("type") ?? ""
        return NavigationLink {
            AuthorByIdView(session: session, authorId: otherId)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                NodusChip(
                    Bundle.main.localizedString(forKey: Self.relationLabel(relation), value: nil, table: nil),
                    tint: SemanticTone.relation(relation, fallback: session.accent),
                    systemImage: "person"
                )
                Text(session.names.author(otherId) ?? String(localized: "Loading…"))
                    .font(.subheadline).lineLimit(2).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(NodusCardButtonStyle())
        .padding(.vertical, 7)
    }

    /// A study plan is its blocks, on the days they fall.
    ///
    /// Grouped by day rather than listed flat, because a plan is read as "what am I doing on
    /// Thursday" and a flat list of forty blocks answers that question only by scrolling.
    private func planBody(_ detail: StudyPlanDetail) -> some View {
        let calendar = Calendar.current
        let days = Dictionary(grouping: detail.blocks.filter { $0.date("starts_at") != nil }) {
            calendar.startOfDay(for: $0.date("starts_at")!)
        }
        return VStack(alignment: .leading, spacing: NodusSpace.block) {
            fields(of: detail.plan)
            if !days.isEmpty {
                section("Blocks", count: detail.blocks.count) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(days.keys.sorted(), id: \.self) { day in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(verbatim: day.formatted(.dateTime.weekday(.wide).day().month()))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(session.accent)
                                ForEach(Array((days[day] ?? []).enumerated()), id: \.offset) { _, block in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(verbatim: (block.date("starts_at") ?? day).formatted(date: .omitted, time: .shortened))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .frame(width: 48, alignment: .leading)
                                        Text(verbatim: block.text("title") ?? "—")
                                            .font(.subheadline)
                                            .strikethrough(block.text("status") == "completed", color: .secondary)
                                        Spacer(minLength: 6)
                                        if let minutes = block.int("duration_minutes"), minutes > 0 {
                                            Text("\(minutes) min").font(.caption2).foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func databaseBody(_ detail: DatabaseDetail) -> some View {
        VStack(alignment: .leading, spacing: NodusSpace.block) {
            NavigationLink { DatabaseGridView(session: session, database: detail.database) }
                label: { Label("Abrir tabla", systemImage: "tablecells").frame(minHeight: 44) }
            Text("\(detail.total.formatted()) rows · \(detail.columns.count) columns")
                .font(.caption).foregroundStyle(.secondary)
            group("Columns", detail.columns, table: "db_columns")
            group("Views", detail.views, table: "db_views")
        }
    }

    /// An edge shown as the idea at its other end.
    ///
    /// The row is `{from_id, to_id, relation}` and nothing else, so without resolving the id
    /// this list renders as a column of "Untitled" — which is exactly what it did.
    private func relationsSection(_ detail: IdeaDetail) -> some View {
        let selfId = detail.idea.string("global_id") ?? ""
        let others = detail.relations.compactMap {
            $0.string("from_id") == selfId ? $0.string("to_id") : $0.string("from_id")
        }
        return Group {
            if !detail.relations.isEmpty {
                section("Relationships", count: detail.relations.count) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(detail.relations.enumerated()), id: \.offset) { index, edge in
                            relationRow(edge, selfId: selfId)
                            if index < detail.relations.count - 1 { Divider().opacity(0.35) }
                        }
                    }
                }
            }
        }
        .task {
            // One request for the whole neighbourhood, then a per-id round for anything the
            // graph did not carry back. The other order — a request per relation, capped —
            // is what left half of a long list saying "Loading…" permanently.
            await session.names.resolveNeighbours(ofIdea: selfId)
            await session.names.resolve(ideaIds: others)
        }
    }

    /// One edge, in the colour its meaning carries everywhere else in the app.
    ///
    /// Both the relation and the direction were drawn in the vault's accent, so "supports" and
    /// "contradicts" arrived as the same violet word and a list of forty relations said nothing
    /// until it was read one line at a time. The argument map had been colouring these correctly
    /// since it was written; this is the same table.
    private func relationRow(_ edge: Row, selfId: String) -> some View {
        let otherId = (edge.string("from_id") == selfId ? edge.string("to_id") : edge.string("from_id")) ?? ""
        let outgoing = edge.string("from_id") == selfId
        let relation = edge.text("relation") ?? ""
        let tone = SemanticTone.relation(relation, fallback: session.accent)
        return NavigationLink {
            IdeaByIdView(session: session, globalId: otherId)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                NodusChip(
                    Bundle.main.localizedString(forKey: Self.relationLabel(relation), value: nil, table: nil),
                    tint: tone,
                    systemImage: outgoing ? "arrow.right" : "arrow.left"
                )
                Text(session.names.idea(otherId) ?? String(localized: "Loading…"))
                    .font(.subheadline).lineLimit(2).foregroundStyle(.primary)
                if let rationale = edge.text("rationale") {
                    Text(rationale).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(NodusCardButtonStyle())
        .padding(.vertical, 7)
    }

    /// An occurrence shown as the work it appears in.
    private func occurrencesSection(_ detail: IdeaDetail) -> some View {
        let workIds = detail.occurrences.compactMap { $0.string("nodus_id") }
        return Group {
            if !detail.occurrences.isEmpty {
                section("Appears in", count: detail.occurrences.count) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(detail.occurrences.enumerated()), id: \.offset) { index, occurrence in
                            occurrenceRow(occurrence)
                            if index < detail.occurrences.count - 1 { Divider().opacity(0.35) }
                        }
                    }
                }
            }
        }
        .task { await session.names.resolve(workIds: workIds) }
    }

    private func occurrenceRow(_ occurrence: Row) -> some View {
        let workId = occurrence.string("nodus_id") ?? ""
        return NavigationLink {
            WorkByIdView(session: session, nodusId: workId)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(session.names.work(workId) ?? String(localized: "Loading…"))
                    .font(.subheadline).lineLimit(2).foregroundStyle(.primary)
                if let development = occurrence.text("development") {
                    Text(development).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                if let role = occurrence.text("role") {
                    NodusChip(
                        role == "principal" ? String(localized: "Principal") : String(localized: "Secondary"),
                        tint: session.accent.nodusReadable
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(NodusCardButtonStyle())
        .padding(.vertical, 7)
    }

    /// The edge vocabulary, in the desktop's words.
    static func relationLabel(_ relation: String) -> String {
        switch relation {
        case "supports": return String(localized: "Supports")
        case "contradicts": return String(localized: "Contradicts")
        case "refutes": return String(localized: "Refutes")
        case "refines": return String(localized: "Refines")
        case "extends": return String(localized: "Extends")
        case "variant_of": return String(localized: "Variant of")
        case "depends_on": return String(localized: "Depends on")
        case "exemplifies": return String(localized: "Exemplifies")
        case "applies": return String(localized: "Applies")
        case "compares": return String(localized: "Compares")
        case "responds_to": return String(localized: "Responds to")
        default: return relation
        }
    }

    // MARK: Generic rendering

    /// The raw record, under a name that says that is what it is.
    ///
    /// It sat directly under the heading with no title of its own, which is how an idea's page
    /// came to open with its label and statement and then repeat both of them verbatim four
    /// hundred points further down under the words `LABEL` and `STATEMENT`. Titled, it reads as
    /// the technical card at the bottom of a dossier — which is what a reader wants it to be.
    private func fields(of row: Row, hiding extra: Set<String> = [], titled: Bool = true) -> some View {
        Group {
            if titled {
                section("Record") { fieldRows(of: row, hiding: extra) }
            } else {
                fieldRows(of: row, hiding: extra)
                    .padding(.horizontal, NodusSpace.cardPadding)
                    .padding(.vertical, 4)
                    .nodusGlass(NodusGlass(.thin, tint: session.accent))
            }
        }
    }

    private func fieldRows(of row: Row, hiding extra: Set<String> = []) -> some View {
        let keys = displayableKeys(of: row, hiding: extra)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(keys, id: \.self) { key in
                VStack(alignment: .leading, spacing: 3) {
                    // Neither `.textCase(.uppercase)` nor the raw column name. Capitals are a
                    // shout the rest of the app does not use, and the column name is what
                    // showed a Spanish reader `GLOBAL ID`.
                    Text(FieldNames.label(for: key))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(display(row[key], key: key) ?? "—")
                        .font(.callout)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 9)
                if key != keys.last { Divider().opacity(0.4) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A related list inside a detail.
    ///
    /// `linksTo` is what makes a dossier a graph rather than a dead end: an idea listed under a
    /// work opens that idea's own page, exactly as if it had been reached from Ideas, and the
    /// work under an author opens the work as the library shows it.
    private func group(
        _ title: LocalizedStringKey,
        _ rows: [Row],
        table: String,
        linksTo collection: CollectionDescriptor? = nil
    ) -> some View {
        let groupId = "\(title):\(table)"
        let limit = relationLimits[groupId] ?? 60
        return Group {
            if !rows.isEmpty {
                // The heading is the key and the count is data beside it. Interpolating the
                // two — `"\(title) · \(rows.count)"` — made the *whole line* the key, so the
                // catalogue never matched and every group on a dossier read in English.
                section(title, count: rows.count) {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.prefix(limit).enumerated()), id: \.offset) { index, row in
                            if let collection, row.string(collection.idField) != nil {
                                if let onOpenRelated {
                                    Button { onOpenRelated(collection, row) } label: {
                                        HStack {
                                            RowCell(row: row, presenter: RowPresenter.forTable(table), accent: session.accent)
                                            Spacer(minLength: 6)
                                            Image(systemName: "plus.rectangle.on.rectangle")
                                                .font(.caption2).foregroundStyle(.tertiary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(NodusCardButtonStyle())
                                    .padding(.vertical, 4)
                                } else {
                                    NavigationLink {
                                        RowDetailView(session: session, collection: collection, row: row)
                                    } label: {
                                        HStack {
                                            RowCell(row: row, presenter: RowPresenter.forTable(table), accent: session.accent)
                                            Spacer(minLength: 6)
                                            Image(systemName: "chevron.right")
                                                .font(.caption2).foregroundStyle(.tertiary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(NodusCardButtonStyle())
                                    .padding(.vertical, 4)
                                }
                            } else {
                                RowCell(row: row, presenter: RowPresenter.forTable(table), accent: session.accent)
                                    .padding(.vertical, 4)
                            }
                            if index < min(rows.count, limit) - 1 { Divider().opacity(0.35) }
                        }
                        if rows.count > limit {
                            Button("Mostrar más (\(rows.count - limit))") { relationLimits[groupId] = limit + 60 }
                                .frame(minHeight: 44).accessibilityIdentifier("dossier-related-show-more-\(table)")
                        }
                    }
                }
            }
        }
    }

    /// `LocalizedStringKey`, not `String`: every call site passes a literal, and a `String`
    /// parameter is what silently turns a translated heading back into English.
    private func section<Content: View>(
        _ title: LocalizedStringKey,
        count: Int? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            NodusSectionLabel(title, count: count)
            content()
                .padding(NodusSpace.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .nodusGlass(NodusGlass(.thin, tint: session.accent))
        }
    }

    private func chips(_ values: [String], label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            NodusSectionLabel(label)
            FlowLayout(spacing: 6) {
                ForEach(values, id: \.self) { value in
                    NodusChip(value, tint: session.accent.nodusReadable)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Columns worth showing: not empty, not machinery, not the same thing twice.
    ///
    /// The `*_json` columns are the raw form of what the heading already renders properly —
    /// showing both means a screen that opens with a readable author line and then repeats it
    /// as `[{"lastName":"Arco Blanco","firstName":…}]`.
    private func displayableKeys(of row: Row, hiding extra: Set<String> = []) -> [String] {
        // Pipeline bookkeeping: when the desktop last scanned this work and how it went. Real
        // columns, and nothing a reader of the corpus has any use for.
        let hidden: Set<String> = [
            "embedding", "embedding_provider", "embedding_model", "embedding_dim", "embedding_text_hash",
            "content_hash", "light_hash", "deep_hash", "summary_hash",
            "light_at", "light_status", "deep_at", "deep_status", "deep_trigger", "manual_deep",
            "summary_at", "summary_status", "source_type", "zotero_version", "order_idx",
            "created_at", "updated_at",
            "mobileSourceScope", "mobileSyncState", "mobileSyncIssue",
            // Shown as the control at the top of the dossier, which carries the key itself as
            // its subtitle. Listing it here as well would put the same eight characters on the
            // screen twice, once as something you can press and once as something you cannot.
            "zotero_key",
        ]
        return row.columns.keys
            .filter { key in
                guard !hidden.contains(key), !extra.contains(key), !key.hasSuffix("_json") else { return false }
                guard let value = row[key], !value.isNull else { return false }
                if let string = value.stringValue, string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
                return true
            }
            .sorted { lhs, rhs in
                let order = ["title", "label", "name", "display_name", "statement", "type", "kind", "year"]
                let left = order.firstIndex(of: lhs) ?? Int.max
                let right = order.firstIndex(of: rhs) ?? Int.max
                return left == right ? lhs < rhs : left < right
            }
    }

    private func display(_ value: JSONValue?, key: String) -> String? {
        guard let value, !value.isNull else { return nil }
        switch value {
        case .array(let items):
            return items.count == 1
                ? String(localized: "1 item")
                : String(localized: "\(items.count) items")
        case .object(let object):
            return object.count == 1
                ? String(localized: "1 field")
                : String(localized: "\(object.count) fields")
        case .int(let number) where Self.booleanColumns.contains(key):
            // SQLite has no boolean type, so these arrive as 0 and 1. Printing the integer is
            // technically the value and tells the reader nothing.
            //
            // `String(localized:)`, and the English is the key. The literal here used to be
            // "Sí" — a Spanish word in an app whose base language is English, which is exactly
            // the trap `LocalisationTests` was written to catch: it made the *English* bundle
            // answer in Spanish, and no catalogue entry can fix that.
            return number == 0 ? String(localized: "No") : String(localized: "Yes")
        case .string(let raw) where Self.vocabularyColumns.contains(key):
            // The corpus's own vocabulary — `claim`, `supports`, `principal` — which the
            // catalogue already holds because the chips elsewhere on this screen use it. Shown
            // raw, a Spanish reader met "Tipo: claim" one line under a chip reading
            // "Afirmación".
            return NodusChip.sentenceCased(
                Bundle.main.localizedString(forKey: raw, value: raw, table: nil)
            )
        default:
            return value.stringValue
        }
    }

    private static let booleanColumns: Set<String> = [
        "archived", "pinned", "manual_deep", "internal", "dismissed", "resolved", "hidden", "starred",
    ]

    /// Columns whose values come from a closed vocabulary the app can name, rather than from
    /// whatever somebody typed. Anything outside the catalogue passes through unchanged.
    private static let vocabularyColumns: Set<String> = [
        "type", "kind", "relation", "role", "status", "sex", "subtype",
    ]

    // MARK: Loading

    private func enrich() async {
        guard let collection else { return }
        guard let id = row.string(collection.idField) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let query = collection.path == "databases" ? [URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "offset", value: "0")] : []
            let dossier = try await session.client.dossier(collection, id: id, in: session.connection.spaceId, query: query)
            try Task.checkCancellation()
            fromDevice = dossier.fromDevice
            resourceDossier = dossier
            supplement = nil
            switch collection.path {
            case "ideas":
                let detail = try dossier.decode(IdeaDetail.self)
                row = detail.idea
                enriched = .idea(detail)
                supplement = try dossier.supplement(excluding: ["relations", "occurrences", "evidence", "themes"])
            case "works":
                let detail = try dossier.decode(WorkDetail.self)
                row = detail.work
                enriched = .work(detail)
                supplement = try dossier.supplement(excluding: ["ideas", "summary", "passages"])
            case "persons":
                let detail = try dossier.decode(PersonDetail.self)
                row = detail.person
                enriched = .person(detail)
                supplement = try dossier.supplement(excluding: ["names", "places", "relationships", "events", "portrait"])
            case "authors":
                let detail = try dossier.decode(AuthorDetail.self)
                row = detail.author
                enriched = .author(detail)
                supplement = try dossier.supplement(excluding: ["works", "relations", "synthesis"])
            case "databases":
                let detail = try dossier.decode(DatabaseDetail.self)
                row = detail.database
                enriched = .database(detail)
                supplement = try dossier.supplement(excluding: ["columns", "views", "options", "rows", "cells", "relations", "attachments", "total", "offset", "limit", "hasMore"])
            case "teaching-exams":
                let detail = try dossier.decode(ExamDetail.self)
                row = detail.exam
                enriched = .exam(detail)
            case "study-plans":
                let detail = try dossier.decode(StudyPlanDetail.self)
                row = detail.plan
                enriched = .plan(detail)
                supplement = try dossier.supplement(excluding: ["blocks"])
            default:
                row = dossier.primary
                enriched = .dossier(dossier)
            }
            error = nil
        } catch where error.isCancellation {
            // Superseded or let go of. Nothing failed, so nothing is reported.
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Images come down by content hash and need an `Authorization` header, so `AsyncImage` cannot
/// fetch them. The hash *is* the content, which is why the cache never revalidates.
struct AssetImage: View {
    let session: SpaceSession
    let hash: String

    @State private var data: Data?
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let data, let image = PlatformImage(data: data) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                    .accessibilityLabel("Published image")
                    .accessibilityIdentifier("published-image-\(hash)")
            } else if let failure {
                VStack(spacing: 8) {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Image unavailable").font(.caption)
                    Text(failure).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                    Button("Retry") { attempt += 1 }
                }
                .padding()
                .accessibilityIdentifier("published-image-error")
            } else {
                ProgressView().tint(session.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // What is behind an image that has not arrived. `.quaternary` is the system's grey, and
        // on a page whose every other surface is tinted glass it read as a hole rather than as a
        // photograph on its way — the same reasoning `nodusFieldSurface` is written from.
        .background(session.accent.opacity(0.12))
        .clipped()
        .task(id: attempt) {
            guard data == nil else { return }
            failure = nil
            do {
                let bytes = try await session.client.asset(hash: hash, in: session.connection.spaceId)
                guard PlatformImage(data: bytes) != nil else {
                    failure = String(localized: "The downloaded file could not be opened as an image.")
                    return
                }
                data = bytes
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#endif

/// Wrapping chips. `Layout` rather than a stack of rows so it reflows with Dynamic Type.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    private func measuredSize(_ subview: LayoutSubview, within width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard width.isFinite, ideal.width > max(0, width) else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: max(0, width), height: nil))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = measuredSize(subview, within: width)
            if x + size.width > width, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = measuredSize(subview, within: bounds.width)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}


/// Opens an idea from its id alone, fetching the row first.
struct IdeaByIdView: View {
    let session: SpaceSession
    let globalId: String

    @State private var row: Row?
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let row {
                RowDetailView(session: session, collection: Collections["ideas"], row: row)
            } else if let failure {
                CorpusOpenFailure(message: failure) { attempt += 1 }
            } else {
                ProgressView().tint(session.accent)
            }
        }
        .task(id: "\(globalId)|\(session.publishedRevision ?? "local")|\(attempt)") {
            guard row == nil else { return }
            failure = nil
            do {
                let loaded = try await session.client.idea(globalId, in: session.connection.spaceId).idea
                try Task.checkCancellation(); row = loaded
            } catch where error.isCancellation {
            } catch { failure = error.localizedDescription }
        }
    }
}

/// Opens an author from their id alone, which is all an `author_relations` row carries.
struct AuthorByIdView: View {
    let session: SpaceSession
    let authorId: String

    @State private var row: Row?
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let row {
                RowDetailView(session: session, collection: Collections["authors"], row: row)
            } else if let failure {
                CorpusOpenFailure(message: failure) { attempt += 1 }
            } else {
                ProgressView().tint(session.accent)
            }
        }
        .task(id: "\(authorId)|\(session.publishedRevision ?? "local")|\(attempt)") {
            guard row == nil else { return }
            failure = nil
            do {
                let loaded = try await session.client.author(authorId, in: session.connection.spaceId).author
                try Task.checkCancellation(); row = loaded
            } catch where error.isCancellation {
            } catch { failure = error.localizedDescription }
        }
    }
}

/// Opens a work from its id alone.
struct WorkByIdView: View {
    let session: SpaceSession
    let nodusId: String

    @State private var row: Row?
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let row {
                RowDetailView(session: session, collection: Collections["works"], row: row)
            } else if let failure {
                CorpusOpenFailure(message: failure) { attempt += 1 }
            } else {
                ProgressView().tint(session.accent)
            }
        }
        .task(id: "\(nodusId)|\(session.publishedRevision ?? "local")|\(attempt)") {
            guard row == nil else { return }
            failure = nil
            do {
                let loaded = try await session.client.work(nodusId, in: session.connection.spaceId).work
                try Task.checkCancellation(); row = loaded
            } catch where error.isCancellation {
            } catch { failure = error.localizedDescription }
        }
    }
}
