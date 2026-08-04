import NodusAI
import NodusKit
import NodusUI
import SwiftUI

/// Every report this space can show, wherever it was written.
///
/// Two origins, one list: reports the owner published from the desktop, and reports generated
/// on this device. Keeping them apart in the UI would make the user remember where each one
/// came from; keeping them together with a label does not.
struct ResearchLibraryView: View {
    let session: SpaceSession
    @Bindable var local: LocalReportStore

    @State private var published: [Row] = []
    @State private var query = ""
    @State private var isLoading = true
    @State private var error: String?

    private var matchingLocal: [LocalReportStore.Saved] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return local.reports }
        return local.reports.filter {
            $0.title.lowercased().contains(needle)
                || $0.report.sections.contains { $0.title.lowercased().contains(needle) }
        }
    }

    private var matchingPublished: [Row] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return published }
        return published.filter { $0.searchableText.lowercased().contains(needle) }
    }

    var body: some View {
        List {
            if let error {
                NodusNotice(tone: .blocked, title: "Could not load", message: LocalizedStringKey(error))
                    .listRowBackground(Color.clear)
            }

            if !matchingLocal.isEmpty {
                Section {
                    ForEach(matchingLocal) { saved in
                        NavigationLink {
                            LocalReportReader(session: session, saved: saved)
                        } label: {
                            localRow(saved)
                        }
                        .listRowBackground(Color.clear)
                        .swipeActions {
                            Button(role: .destructive) { local.delete(saved.id) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    NodusSectionLabel("On this device")
                } footer: {
                    Text("Generated here and kept on this device. They are not part of the vault until you send one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !matchingPublished.isEmpty {
                Section {
                    ForEach(Array(matchingPublished.enumerated()), id: \.offset) { _, row in
                        NavigationLink {
                            PublishedReportReader(session: session, row: row)
                        } label: {
                            publishedRow(row)
                        }
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    NodusSectionLabel("Published in the vault")
                }
            }

            if matchingLocal.isEmpty, matchingPublished.isEmpty, !isLoading {
                ContentUnavailableView(
                    query.isEmpty ? "No reports" : "No matches",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(query.isEmpty
                        ? "Nothing published, and nothing generated here yet."
                        : "No report contains “\(query)”.")
                )
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        // `.plain`, not the grouped default. Grouped gives every row its own opaque card —
        // `secondarySystemGroupedBackground`, flat white or flat near-black — which is the
        // "black panels" of item 8, and it inset those cards away from the separators that were
        // supposed to be doing the separating.
        .listStyle(.plain)
        // The system's separator is a hairline of `separator`, which is the label colour at
        // about a tenth — designed for a flat white table and all but invisible over this app's
        // dark tinted glass. Two reports with two-line titles ran together into one block of
        // text. This is the same hairline at a strength the surface it is drawn on can carry.
        .listRowSeparatorTint(Color.nodusTertiaryText.opacity(0.45))
        // The system sets a `List` header in small capitals of its own accord, which is the one
        // typographic style nothing else in the app uses.
        .textCase(nil)
        .nodusDismissesKeyboard()
        .navigationTitle("Reports")
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .safeAreaInset(edge: .top) {
            NodusSearchField(text: $query, prompt: "Search reports", accent: session.accent, isBusy: isLoading)
        }
        .task { await load() }
        .refreshable { await load() }
    }

    /// The thumbnail every row in this list wears.
    ///
    /// 56 rather than 44, at the app's control radius. A report is a document with a cover, and
    /// at 44 points the illustration the desktop generated for it was a stamp beside two lines
    /// of text — too small to be recognised, and small enough that a row with a picture and a
    /// row with a glyph read as two different kinds of row.
    private static let thumbnail: CGFloat = 56

    private func localRow(_ saved: LocalReportStore.Saved) -> some View {
        HStack(spacing: 13) {
            glyphThumbnail(saved.mode == .teachingUnit ? "graduationcap" : "doc.text")
            VStack(alignment: .leading, spacing: 3) {
                Text(saved.title).font(.subheadline.weight(.medium)).lineLimit(2)
                Text("\(saved.report.words.formatted()) words · \(saved.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
                if saved.report.citationsRejected > 0 {
                    Text("\(saved.report.citationsRejected) invented citations removed")
                        .font(.caption2).foregroundStyle(Color.nodusCaution)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func publishedRow(_ row: Row) -> some View {
        HStack(spacing: 13) {
            // The list endpoint carries the illustration's asset ref beside each report, which
            // is the only place a client can learn its hash.
            if let hash = row.embeddedJSON("image")?.objectValue?["hash"]?.stringValue {
                AssetImage(session: session, hash: hash)
                    .frame(width: Self.thumbnail, height: Self.thumbnail)
                    .clipShape(NodusRadius.controlShape)
            } else {
                glyphThumbnail("doc.richtext")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.text("title") ?? "Report").font(.subheadline.weight(.medium)).lineLimit(2)
                if let objective = row.text("objective") {
                    Text(objective).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// The stand-in for a report that has no illustration: the same square, so the two kinds of
    /// row line up down the left edge.
    private func glyphThumbnail(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(session.accent.nodusReadable)
            .frame(width: Self.thumbnail, height: Self.thumbnail)
            .background(session.accent.opacity(0.14), in: NodusRadius.controlShape)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        local.reload()
        do {
            published = try await session.client.deepResearchReports(in: session.connection.spaceId, limit: 100).items
            error = nil
        } catch let apiError as APIError where apiError.isNotPublished {
            published = []
        } catch where error.isCancellation {
            // Superseded or let go of. Nothing failed, so nothing is reported.
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A report generated here.
struct LocalReportReader: View {
    let session: SpaceSession
    let saved: LocalReportStore.Saved

    @Environment(AppPreferences.self) private var preferences

    /// Token → label for the works this report really cited.
    private var referenceLabels: [String: String] {
        Dictionary(saved.report.references.map { ($0.token, $0.label) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(saved.title).font(.title3.weight(.semibold))
                    HStack(spacing: 12) {
                        Label("\(saved.report.words.formatted()) words", systemImage: "text.alignleft")
                        Label(String(format: "%.1f pp.", saved.report.pages), systemImage: "doc")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Text("\(saved.mode.label) · \(saved.modelLabel)")
                        .font(.caption2).foregroundStyle(.tertiary)

                    if saved.report.citationsRejected > 0 {
                        NodusNotice(
                            tone: .caution,
                            title: "\(saved.report.citationsRejected) invented citations, removed",
                            message: "Of \(saved.report.citationsChecked) checked."
                        )
                    }

                    ReportActions(
                        markdown: saved.report.markdown,
                        title: nil,
                        accent: session.accent
                    )
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(NodusSpace.cardPadding)
                .nodusGlass(NodusGlass(.regular, tint: session.accent))

                ForEach(Array(saved.report.sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 14) {
                        ReportSectionTitle(section.title, accent: session.accent)
                        CorpusProse(
                            section.prose,
                            accent: session.accent,
                            session: session,
                            labels: referenceLabels
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(ReportLayout.sectionPadding)
                    // `.regular`, the same weight as the header above it. The sections were
                    // `.thin` — a different, darker material — so a report was one solid card
                    // followed by a column of near-black panels, which is the break item 8 is
                    // about.
                    .nodusGlass(NodusGlass(.regular, tint: session.accent))
                }

                if !saved.report.references.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ReportSectionTitle("References", accent: session.accent)
                        ForEach(saved.report.references, id: \.token) { entry in
                            Text(verbatim: "· \(entry.label)").font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(ReportLayout.sectionPadding)
                    .nodusGlass(NodusGlass(.regular, tint: session.accent))
                }

                ShareLink(item: saved.report.markdown) {
                    Label("Share as Markdown", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
            }
            .padding(NodusSpace.page)
            .frame(maxWidth: ReportLayout.measure)
            .frame(maxWidth: .infinity)
            .nodusTopAnchor()
        }
        .nodusReadingStyle(ReadingStyle(scale: preferences.readingScale, document: true))
        .nodusScrollToTop(accent: session.accent)
        .nodusHidesBottomBar()
        .navigationTitle(saved.mode.label)
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
    }
}

/// How a report is set on the page.
enum ReportLayout {
    /// The widest a column of prose is allowed to get.
    ///
    /// A phone is always narrower than this and is unaffected; an iPad in landscape was setting
    /// a twenty-page report across 1 300 points, which is some twenty-five words to a line —
    /// past the point where the eye reliably finds the start of the next one.
    static let measure: CGFloat = 660
    /// A little more than a card's own padding, because the one thing inside is prose and prose
    /// wants a margin of its own.
    static let sectionPadding: CGFloat = 19
}

/// A report the owner published from the desktop.
struct PublishedReportReader: View {
    let session: SpaceSession
    let row: Row

    @Environment(AppPreferences.self) private var preferences
    @State private var detail: DeepResearchReportDetail?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let hash = detail?.image?.text("hash") ?? row.embeddedJSON("image")?.objectValue?["hash"]?.stringValue {
                    AssetImage(session: session, hash: hash)
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(row.text("title") ?? "Report").font(.title3.weight(.semibold))
                    if let objective = row.text("objective") {
                        Text(objective).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let document {
                        ReportActions(
                            markdown: document,
                            title: row.text("title"),
                            // Beside the copy, because it is the other way to take the report
                            // with you — and the only one that keeps its layout.
                            pdf: row.string("id").map {
                                (session, $0, row.text("title") ?? String(localized: "Report"))
                            },
                            accent: session.accent
                        )
                        .padding(.top, 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(NodusSpace.cardPadding)
                .nodusGlass(NodusGlass(.regular, tint: session.accent))

                if let error {
                    NodusNotice(tone: .blocked, title: "Could not open", message: LocalizedStringKey(error))
                }

                if let sections = prose {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 14) {
                            if let heading = section.heading {
                                ReportSectionTitle(heading, accent: session.accent)
                            }
                            // The desktop writes one Markdown document with its own headings
                            // and `nodus://` citations in it. Rendered as plain text, both
                            // arrived as punctuation.
                            CorpusProse(section.body, accent: session.accent, session: session)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(ReportLayout.sectionPadding)
                        .nodusGlass(NodusGlass(.regular, tint: session.accent))
                    }
                } else if detail == nil, error == nil {
                    ProgressView().tint(session.accent).frame(maxWidth: .infinity)
                }
            }
            .padding(NodusSpace.page)
            .frame(maxWidth: ReportLayout.measure)
            .frame(maxWidth: .infinity)
            .nodusTopAnchor()
        }
        .nodusReadingStyle(ReadingStyle(scale: preferences.readingScale, document: true))
        .nodusScrollToTop(accent: session.accent)
        .nodusHidesBottomBar()
        .navigationTitle("Report")
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .task { await load() }
    }

    private struct Prose { let heading: String?; let body: String }

    /// The draft is a Writing-Workshop document (`shared/types.ts:5838`), and the field that
    /// actually carries the prose is `draftMarkdown` — one document, not a list of section
    /// bodies. `outline` beside it holds titles and purposes with no text in them, which is why
    /// reading `outline` for prose returns a report of empty sections.
    ///
    /// The `sections` branch is kept because that is the shape this app's own orchestrator
    /// produces, and a report written on the phone before it could be sent to the vault is
    /// still on the phone. Rendered as plain paragraphs rather than parsed as Markdown, because
    /// a half-parsed heading reads worse than none.
    private var prose: [Prose]? {
        guard let detail else { return nil }
        let draft = (detail.report.embeddedJSON("draft") ?? detail.report["draft"])?.objectValue

        if let sections = draft?["sections"]?.arrayValue, !sections.isEmpty {
            let parsed = sections.compactMap { entry -> Prose? in
                guard let object = entry.objectValue else { return nil }
                let body = object["markdown"]?.stringValue ?? object["body"]?.stringValue ?? object["prose"]?.stringValue
                guard let body, !body.isEmpty else { return nil }
                return Prose(heading: object["title"]?.stringValue, body: body)
            }
            if !parsed.isEmpty { return parsed }
        }

        // The desktop's own drafts, and everything this app now sends to a vault.
        //
        // `abstract` is deliberately not shown beside it: `draftMarkdown` is the whole
        // document and already opens with the abstract under its own heading, so rendering
        // both printed the summary twice.
        if let markdown = draft?["draftMarkdown"]?.stringValue, !markdown.isEmpty {
            return [Prose(heading: nil, body: markdown)]
        }

        guard let body = detail.report.text("content") ?? detail.report.text("markdown") else { return nil }
        return [Prose(heading: nil, body: body)]
    }

    /// The report as one Markdown document, which is what a copy is of.
    ///
    /// `prose` is a list because a report written on this phone arrives as sections; a report
    /// the desktop published is already one document and comes back as a single entry.
    private var document: String? {
        guard let sections = prose, !sections.isEmpty else { return nil }
        return sections
            .map { section in
                guard let heading = section.heading, !heading.isEmpty else { return section.body }
                return "## \(heading)\n\n\(section.body)"
            }
            .joined(separator: "\n\n")
    }

    private func load() async {
        guard let id = row.string("id") else { return }
        do {
            detail = try await session.client.deepResearchReport(id, in: session.connection.spaceId)
        } catch where error.isCancellation {
            // Superseded or let go of. Nothing failed, so nothing is reported.
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A section title in a report.
///
/// Uppercase, bold, two sizes above the prose and with a rule under it. A report on a phone is
/// one column of grey paragraphs in stacked cards, and a `.headline` title — one step above the
/// body — disappeared into it: there was nothing to scroll *to*. This is deliberately more than
/// the surrounding text needs, because finding where a section begins is the one thing a reader
/// does without reading.
struct ReportSectionTitle: View {
    private let title: String
    private let accent: Color

    @Environment(\.nodusReadingStyle) private var reading

    init(_ title: String, accent: Color) {
        self.title = title
        self.accent = accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(reading.font(.title3, weight: .bold))
                .tracking(0.8)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle()
                .fill(accent.opacity(0.35))
                .frame(height: 1.5)
                .frame(maxWidth: 56)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 2)
    }
}
