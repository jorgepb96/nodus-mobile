import NodusAI
import NodusKit
import NodusUI
import SwiftUI

/// A single query combines text matches and related records. Partial failures preserve
/// the other result source; linked query embeddings run on Desktop, never on the phone.
struct SearchScreen: View {
    @Environment(AISettings.self) private var ai
    @Environment(\.nodusResidentRouteActive) private var routeActive
    let session: SpaceSession

    @State private var query = ""
    @State private var hits: [CorpusSearch.Hit] = []
    @State private var mode: CorpusSearch.Mode = .lexical
    @State private var selectedKinds: Set<String> = []
    @State private var semanticWarning: String?
    @State private var isSearching = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchGeneration = 0
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let error {
                    NodusNotice(tone: .blocked, title: "Search failed", message: LocalizedStringKey(error))
                }
                if let semanticWarning {
                    NodusNotice(tone: .caution, title: "Search", message: LocalizedStringKey(semanticWarning), systemImage: "magnifyingglass")
                }
                if mode == .semantic, !hits.isEmpty {
                    Label("Text and related results", systemImage: "sparkle.magnifyingglass")
                        .font(.caption).foregroundStyle(session.accent.nodusReadable)
                }
                if availableKinds.count > 1 {
                    ScrollView(.horizontal) {
                        HStack(spacing: 7) {
                            kindFilterButton(nil, title: String(localized: "All"))
                            ForEach(availableKinds, id: \.self) { kind in
                                kindFilterButton(kind, title: SearchKind.label(for: kind))
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
                if trimmedQuery.count < 2 {
                    idleState.frame(maxWidth: .infinity).padding(.vertical, 42)
                } else {
                    ForEach(visibleHits) { hit in
                        if let reference = CorpusReference(hitId: hit.id) {
                            NavigationLink {
                                CorpusReferenceView(session: session, reference: reference)
                            } label: {
                                HitCell(hit: hit, source: source(of: hit), accent: session.accent)
                                    .desktopContentRow(accent: session.accent)
                            }.buttonStyle(NodusCardButtonStyle())
                        } else {
                            HitCell(hit: hit, source: source(of: hit), accent: session.accent)
                                .desktopContentRow(accent: session.accent)
                        }
                    }
                    if visibleHits.isEmpty, !isSearching, error == nil {
                        ContentUnavailableView("No results", systemImage: "magnifyingglass",
                            description: Text("Try different words or a shorter query."))
                            .padding(.vertical, 42)
                    }
                }
            }
            .padding(NodusSpace.page)
            .frame(maxWidth: 980).frame(maxWidth: .infinity)
            .nodusTopAnchor()
        }
        .nodusDismissesKeyboard()
        .nodusPageFunctions(accent: session.accent)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                DesktopPageHeader(title: "Search", subtitle: hits.isEmpty ? "Find ideas, works and concepts" : "\(visibleHits.count) results",
                    systemImage: "magnifyingglass", accent: session.accent)
                    .padding(.horizontal, NodusSpace.page)
                NodusSearchField(text: $query, prompt: "Search ideas, works or concepts", accent: session.accent, isBusy: isSearching)
                    .padding(.horizontal, NodusSpace.page)
                    .accessibilityIdentifier("corpus-unified-search")
            }
            .padding(.vertical, 9)
            .frame(maxWidth: 980).frame(maxWidth: .infinity)
            .background(Color(uiColor: .systemBackground).opacity(0.98))
        }
        .onChange(of: query) { _, _ in schedule() }
        .task(id: session.publishedRevision) { if trimmedQuery.count >= 2 { schedule(immediately: true) } }
        .onChange(of: routeActive) { _, active in
            if active, trimmedQuery.count >= 2 { schedule(immediately: true) }
            else if !active { stopSearch() }
        }
        .onDisappear { stopSearch() }
        .task(id: hits.map(\.id)) {
            let works = hits.compactMap(\.workId)
            if !works.isEmpty { await session.names.resolve(workIds: works) }
        }
    }

    private func source(of hit: CorpusSearch.Hit) -> String? { hit.workId.flatMap { session.names.work($0) } }

    private var idleState: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass").font(.system(size: 42)).foregroundStyle(session.accent.opacity(0.65))
            Text("Search \(session.connection.spaceName)").font(.headline)
            Text("Find text matches and related ideas with one search.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(30)
    }

    private var visibleHits: [CorpusSearch.Hit] {
        selectedKinds.isEmpty ? hits : hits.filter { selectedKinds.contains($0.type) }
    }
    private var availableKinds: [String] {
        Array(Set(hits.map(\.type))).sorted { CorpusSearch.rank($0) < CorpusSearch.rank($1) }
    }
    private func kindFilterButton(_ kind: String?, title: String) -> some View {
        let isSelected = kind.map { selectedKinds == Set([$0]) } ?? selectedKinds.isEmpty
        return Button { selectedKinds = kind.map { Set([$0]) } ?? [] } label: {
            Text(title).font(.caption.weight(.medium))
                .foregroundStyle(isSelected ? (session.accent.relativeLuminance > 0.179 ? Color.black : Color.white) : Color.primary)
                .padding(.horizontal, 11).frame(minHeight: 44)
                .background(isSelected ? session.accent : Color.secondary.opacity(0.09), in: Capsule())
        }.buttonStyle(.plain)
    }

    private func stopSearch() {
        searchTask?.cancel(); searchGeneration += 1; isSearching = false
    }
    private func schedule(immediately: Bool = false) {
        stopSearch()
        let current = trimmedQuery, generation = searchGeneration
        hits = []; semanticWarning = nil; error = nil; mode = .lexical
        guard current.count >= 2, routeActive else { return }
        isSearching = true
        searchTask = Task {
            if !immediately { try? await Task.sleep(for: .milliseconds(500)) }
            guard !Task.isCancelled else { return }
            await run(current, generation: generation)
        }
    }
    private func run(_ text: String, generation: Int) async {
        defer { if generation == searchGeneration { isSearching = false } }
        do {
            let outcome = try await search.runUnified(text, limit: 50) { literal in
                guard generation == searchGeneration, trimmedQuery == text else { return }
                hits = literal
            }
            guard !Task.isCancelled, generation == searchGeneration, trimmedQuery == text else { return }
            hits = outcome.hits; mode = outcome.mode; semanticWarning = outcome.warning; error = nil
            selectedKinds.formIntersection(Set(hits.map(\.type)))
        } catch is CancellationError {
        } catch {
            guard generation == searchGeneration, trimmedQuery == text else { return }
            if let apiError = error as? APIError, apiError.isNotPublished { hits = []; self.error = nil }
            else if let apiError = error as? APIError, apiError.isRateLimited {
                self.error = String(localized: "Too many searches in a row. Wait \(Int(apiError.retryAfter ?? 30)) s.")
            } else { self.error = error.localizedDescription }
        }
    }
    private var search: CorpusSearch {
        CorpusSearch.live(client: session.client, spaceId: session.connection.spaceId,
            embeddings: EmbeddingService(keyProvider: ai.keyProvider), identity: publishedIdentity,
            linked: session.connection.desktopPairingId != nil)
    }
    private var publishedIdentity: EmbeddingIdentity? {
        guard case .published(let identity) = session.embedding else { return nil }
        return identity
    }
}

private struct HitCell: View {
    let hit: CorpusSearch.Hit
    /// The work a passage was cut from, when its title has been resolved.
    var source: String?
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                // The kind, as the same tag every other list in the app puts it in.
                NodusChip(key: typeLabel, tint: accent.nodusReadable, systemImage: icon)
                if let page = hit.page {
                    Text(verbatim: page).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                // Shown only for a semantic hit, because only a semantic hit has a distance.
                // A lexical match either contains the string or does not.
                if let score = hit.score {
                    Text(score.formatted(.number.precision(.fractionLength(2))))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            if let headline {
                Text(headline).font(.subheadline.weight(.medium)).lineLimit(2)
            }
            if let supporting {
                Text(supporting)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // A quotation is the result, not a caption under one, so it gets the room
                    // a sentence needs to be recognised.
                    .lineLimit(hit.type == "passage" ? 5 : 3)
            }
            if headline == nil, supporting == nil {
                Text("This row published no text.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
    }

    /// The bold line.
    ///
    /// For a passage that is the work it comes from: the passage's own text is the body, and
    /// repeating its first line above itself in bold says nothing twice. When the work has not
    /// resolved — or the space did not publish it — the passage still has a body, so this is
    /// allowed to be nothing at all rather than the word "Untitled".
    private var headline: String? {
        if hit.type == "passage" { return source ?? hit.title }
        if let title = hit.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        // A row with no title but with text is not "Untitled"; its text is its title.
        return hit.excerpt == nil ? String(localized: "Untitled") : nil
    }

    /// The line under the headline: a passage's own words, or a row's supporting text.
    private var supporting: String? {
        guard let excerpt = hit.excerpt?.trimmingCharacters(in: .whitespacesAndNewlines), !excerpt.isEmpty else {
            return nil
        }
        // The excerpt often opens with the title — the lexical endpoint builds one out of the
        // other. Printing both puts the same sentence on the screen twice.
        if let headline, excerpt.hasPrefix(headline) { return excerpt.count > headline.count ? excerpt : nil }
        return excerpt
    }

    private var typeLabel: String { SearchKind.label(for: hit.type) }

    private var icon: String {
        switch hit.type {
        case "work", "works": return "book.closed"
        case "idea", "ideas": return "lightbulb"
        case "theme", "themes": return "number"
        case "gap", "gaps": return "questionmark.diamond"
        case "note", "notes": return "note.text"
        case "passage", "passages": return "text.quote"
        case "person", "persons": return "person"
        case "place", "places": return "mappin.and.ellipse"
        case "event", "events": return "calendar"
        case let type where SearchKind.ideaTypes.contains(type): return "lightbulb"
        default: return "doc"
        }
    }
}

/// The one name a search result kind is shown under, shared by the filter chips and the tag
/// on each result so the two never disagree.
enum SearchKind {
    /// Idea subtypes the server returns as the hit type instead of "idea".
    static let ideaTypes: Set<String> = ["claim", "finding", "construct", "method", "framework", "hypothesis"]

    /// Both spellings on purpose. The record kind is what reaches here now, but a server that
    /// answers with its table name — which is what the lexical endpoint does
    /// (`server/lib/core/search.mjs:41`) — must not fall through to a capitalised table name
    /// that no catalogue can translate. Anything else is looked up in lower case, the form the
    /// catalogue stores idea types in, and only shown raw when no translation exists.
    static func label(for type: String) -> String {
        switch type {
        case "work", "works": return String(localized: "Work")
        case "idea", "ideas": return String(localized: "Idea")
        case "theme", "themes": return String(localized: "Theme")
        case "gap", "gaps": return String(localized: "Gap")
        case "note", "notes": return String(localized: "Note")
        case "passage", "passages": return String(localized: "Passage")
        case "person", "persons": return String(localized: "Person")
        case "place", "places": return String(localized: "Place")
        case "event", "events": return String(localized: "Event")
        default:
            let key = type.lowercased()
            let translated = Bundle.main.localizedString(forKey: key, value: type, table: nil)
            guard let first = translated.first else { return type }
            return first.uppercased() + translated.dropFirst()
        }
    }
}
