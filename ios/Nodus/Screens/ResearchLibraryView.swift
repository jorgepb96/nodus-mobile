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

    /// What this reader has done with these reports. One store for both sections, because
    /// "which have I read" is a question about the list rather than about where a report
    /// was written.
    private var marks: ReportMarks { ReportMarks.shared(for: session.connection.spaceId) }

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

    /// The run in flight, which belongs to the space and not to the screen that started it.
    private var runner: DeepResearchRunner { DeepResearchRunner.shared(for: session.connection.spaceId) }

    var body: some View {
        List {
            if let error {
                NodusNotice(tone: .blocked, title: "Could not load", message: LocalizedStringKey(error))
                    .listRowBackground(Color.clear)
            }

            if let progress = runner.progress {
                Section {
                    RunningReportRow(
                        objective: runner.request?.objective ?? "",
                        progress: progress,
                        isIllustrating: runner.isIllustrating,
                        accent: session.accent,
                        onCancel: { runner.cancel() }
                    )
                    .listRowBackground(Color.clear)
                } header: {
                    NodusSectionLabel("Being written")
                }
            }

            if !matchingLocal.isEmpty {
                Section {
                    ForEach(matchingLocal) { saved in
                        NavigationLink {
                            LocalReportReader(session: session, local: local, saved: saved)
                        } label: {
                            localRow(saved)
                        }
                        .listRowBackground(Color.clear)
                        .swipeActions {
                            Button(role: .destructive) {
                                // The marks go with the report. Ids are minted per report, but
                                // a mark outliving the thing it is about is a bookmark waiting
                                // to be inherited by whatever takes the id next.
                                marks.forget(saved.id)
                                local.delete(saved.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            readAction(for: saved.id)
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
                        // Only the mark. A published report belongs to the vault and this
                        // account may not even be allowed to write to it — there is no delete
                        // to offer, and having read it is this device's business anyway.
                        .swipeActions { row.string("id").map { readAction(for: $0) } }
                    }
                } header: {
                    NodusSectionLabel("Published in the vault")
                }
            }

            if matchingLocal.isEmpty, matchingPublished.isEmpty, !isLoading, !runner.isRunning {
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
            if let url = local.imageURL(for: saved) {
                LocalReportImage(url: url)
                    .frame(width: Self.thumbnail, height: Self.thumbnail)
                    .clipShape(NodusRadius.controlShape)
            } else {
                glyphThumbnail(saved.mode == .teachingUnit ? "graduationcap" : "doc.text")
            }
            VStack(alignment: .leading, spacing: 3) {
                title(saved.title, id: saved.id)
                Text("\(saved.report.words.formatted()) words · \(saved.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
                // In the list rather than only in the report. Twenty reports and one question —
                // which of these has the desktop already got? — is a question you answer by
                // scanning, not by opening each one to look at the state of a button.
                if saved.wasSent {
                    Label("Sent to the desktop", systemImage: "paperplane.fill")
                        .font(.caption2).foregroundStyle(Color.nodusSuccess)
                }
                marksLine(for: saved.id)
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
                title(row.text("title") ?? String(localized: "Report"), id: row.string("id"))
                if let objective = row.text("objective") {
                    Text(objective).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                if let id = row.string("id") { marksLine(for: id) }
            }
        }
        .padding(.vertical, 6)
    }

    /// A report's name, one weight lighter once it has been read.
    ///
    /// The same rule an inbox uses, and for the same reason: a list where every entry is set at
    /// the same weight has to be read to be triaged, and the whole point of the mark is that it
    /// answers "what is still waiting" without reading anything.
    private func title(_ text: String, id: String?) -> some View {
        let read = id.map { marks.isRead($0) } ?? false
        return Text(text)
            .font(.subheadline.weight(read ? .regular : .medium))
            .foregroundStyle(read ? Color.nodusSecondaryText : Color.primary)
            .lineLimit(2)
    }

    /// What this reader has done with the report: finished it, and kept a place in it.
    @ViewBuilder
    private func marksLine(for id: String) -> some View {
        let mark = marks.mark(for: id)
        if mark.readAt != nil || mark.bookmark != nil {
            HStack(spacing: 9) {
                if mark.readAt != nil {
                    Label("Read", systemImage: "checkmark.circle.fill")
                }
                if mark.bookmark != nil {
                    Label("Bookmarked", systemImage: "bookmark.fill")
                }
            }
            .font(.caption2)
            .foregroundStyle(Color.nodusSuccess)
        }
    }

    /// Marking a report read from the list, which is where the question is usually asked.
    private func readAction(for id: String) -> some View {
        let read = marks.isRead(id)
        return Button {
            marks.setRead(id, !read)
        } label: {
            Label(
                read ? "Unread" : "Read",
                systemImage: read ? "circle" : "checkmark.circle.fill"
            )
        }
        .tint(Color.nodusSuccess)
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

/// A run in flight, listed among the reports it is about to join.
///
/// The progress belongs here rather than only on the screen that started it: a report takes
/// minutes, the user goes and reads something else, and "where is it" should be answered by the
/// list of reports rather than by remembering which screen it was launched from.
struct RunningReportRow: View {
    let objective: String
    let progress: DeepResearchProgress
    var isIllustrating = false
    let accent: Color
    let onCancel: () -> Void

    @State private var confirming = false

    var body: some View {
        HStack(spacing: 13) {
            VStack(alignment: .leading, spacing: 6) {
                Text(objective).font(.subheadline.weight(.medium)).lineLimit(2)
                if let fraction = progress.fraction {
                    ProgressView(value: fraction).tint(accent)
                } else {
                    ProgressView().tint(accent).frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }

            Button {
                confirming = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.nodusDanger)
            }
            // A row inside a `List` swallows a button's tap for the row's own selection unless
            // the button says it is one control rather than the whole cell.
            .buttonStyle(.borderless)
            .accessibilityLabel("Stop this report")
        }
        .padding(.vertical, 8)
        .nodusConfirmsCancelling($confirming, onCancel: onCancel)
    }

    private var detail: String {
        if isIllustrating { return String(localized: "Drawing the illustration") }
        guard let index = progress.sectionIndex, let total = progress.sectionTotal else {
            return progress.message
        }
        return "\(progress.message) · \(index + 1)/\(total)"
    }
}

/// An illustration drawn on this device, read from the file it was saved to.
struct LocalReportImage: View {
    let url: URL

    var body: some View {
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .clipped()
        }
    }
}

// MARK: - What a reader has done with one report

/// The two marks an open report carries: whether it is finished, and where the reader stopped.
///
/// A modifier rather than two copies, because there are two kinds of reader — a report written
/// here and a report the owner published — and the marks are about neither of those facts. They
/// are about the person holding the phone.
///
/// The bookmark object is made here and handed down the environment, so the prose several views
/// below can draw the mark and offer to make one without any of the screens in between knowing
/// that reading bookmarks exist.
struct ReportReadingMarks: ViewModifier {
    private let marks: ReportMarks
    private let id: String
    private let accent: Color

    @State private var bookmarks: ReadingBookmarks
    @State private var removing = false

    init(spaceId: String, id: String, accent: Color) {
        let store = ReportMarks.shared(for: spaceId)
        marks = store
        self.id = id
        self.accent = accent
        _bookmarks = State(
            initialValue: ReadingBookmarks(bookmark: store.bookmark(for: id)) { next in
                store.setBookmark(next, for: id)
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .environment(bookmarks)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { readButton }
                if bookmarks.bookmark != nil {
                    ToolbarItem(placement: .topBarTrailing) { bookmarkMenu }
                }
            }
            .confirmationDialog(
                "Remove the reading bookmark?",
                isPresented: $removing,
                titleVisibility: .visible
            ) {
                Button("Remove the bookmark", role: .destructive) { bookmarks.clear() }
                Button("Keep it", role: .cancel) {}
            }
            .task { await openWhereTheyStopped() }
    }

    private var readButton: some View {
        let read = marks.isRead(id)
        return Button {
            marks.setRead(id, !read)
        } label: {
            Label(
                read ? "Mark as unread" : "Mark as read",
                systemImage: read ? "checkmark.circle.fill" : "checkmark.circle"
            )
        }
        .tint(read ? Color.nodusSuccess : accent)
    }

    /// The bookmark, where a reader can reach it without finding the marked words first.
    ///
    /// The mark in the prose is the indicator and pressing it is how it is removed — but a
    /// twenty-page report can be reopened, scrolled past the mark and then wanted back, and
    /// hunting for a green line is not a way to navigate. So the same two acts sit here too,
    /// under the passage they are about.
    private var bookmarkMenu: some View {
        Menu {
            Section {
                Button {
                    bookmarks.aimAtBookmark()
                } label: {
                    Label("Go to the bookmark", systemImage: "arrow.down.to.line")
                }
                Button(role: .destructive) {
                    removing = true
                } label: {
                    Label("Remove the bookmark", systemImage: "bookmark.slash")
                }
            } header: {
                // The reader's own words, so it is obvious which passage this is about. Not a
                // localised string: it is a quotation from the report.
                Text(ReadingBookmarks.label(bookmarks.bookmark?.snippet ?? ""))
            }
        } label: {
            Image(systemName: "bookmark.fill")
        }
        .tint(Color.nodusBookmarkRule)
        .accessibilityLabel("The reading bookmark")
    }

    /// Open the report where the reader left it.
    ///
    /// Asked for twice, and that is not superstition. The first request is made while the
    /// report is still being laid out — a twenty-page document is several thousand points of
    /// text views whose heights are not known until they have been measured — and a scroll
    /// against a content size that is still growing lands short. The second is made once it has
    /// settled; if the first one landed, the second moves nothing.
    private func openWhereTheyStopped() async {
        guard bookmarks.bookmark != nil else { return }
        try? await Task.sleep(for: .milliseconds(180))
        bookmarks.aimAtBookmark()
        try? await Task.sleep(for: .milliseconds(480))
        bookmarks.aimAtBookmark()
    }
}

extension View {
    /// Gives this report its read mark and its reading bookmark.
    func nodusReadingMarks(spaceId: String, id: String, accent: Color) -> some View {
        modifier(ReportReadingMarks(spaceId: spaceId, id: id, accent: accent))
    }
}

/// The same, for a report that may not have an id yet.
///
/// A `ViewModifier` cannot be applied conditionally without changing the view's identity — and
/// changing a reader's identity halfway through loading it would throw away the scroll position
/// this feature exists to restore. So the condition is inside.
struct OptionalReadingMarks: ViewModifier {
    let session: SpaceSession
    let id: String?

    func body(content: Content) -> some View {
        if let id {
            content.nodusReadingMarks(spaceId: session.connection.spaceId, id: id, accent: session.accent)
        } else {
            content
        }
    }
}

/// The prose of a report and the sources under it, set the same way wherever it is read.
struct ReportBody: View {
    let report: DeepResearchReport
    let session: SpaceSession

    /// Token → label, for prose written before assembly turned its citations into links. A
    /// report written since carries the labels in the page itself and needs nothing here.
    private var referenceLabels: [String: String] {
        Dictionary(report.references.map { ($0.token, $0.label) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(report.sections.enumerated()), id: \.offset) { index, section in
                VStack(alignment: .leading, spacing: 14) {
                    ReportSectionTitle(section.title, accent: session.accent)
                    // The prose carries the citations the validator kept. Rendered as plain
                    // text they were bare `nodus://` URLs in the middle of a sentence;
                    // rendered here they are the source's own name, and they open it.
                    CorpusProse(
                        section.prose,
                        accent: session.accent,
                        session: session,
                        labels: referenceLabels
                    )
                    // One, because the title above it took nought. Every paragraph of the prose
                    // numbers itself under this.
                    .nodusSearchOrder(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ReportLayout.sectionPadding)
                // The same surface the header above it wears. A report that reads as one
                // document should not be a card followed by a column of darker panels.
                .nodusGlass(NodusGlass(.regular, tint: session.accent))
                // Where this section sits in the report, so find-in-page walks the matches
                // down the document rather than in whatever order the paragraphs registered.
                .nodusSearchOrder(index + 1)
            }

            if !report.references.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ReportSectionTitle("References", accent: session.accent)
                    Text("Built from the works actually cited.")
                        .font(.caption2).foregroundStyle(.secondary)
                    ForEach(Array(report.references.enumerated()), id: \.element.token) { index, entry in
                        PageText("· \(entry.label)", order: index + 1).font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ReportLayout.sectionPadding)
                .nodusGlass(NodusGlass(.regular, tint: session.accent))
                // After every section, whatever the report turned out to have.
                .nodusSearchOrder(report.sections.count + 1)
            }
        }
    }
}

/// A report generated here.
struct LocalReportReader: View {
    let session: SpaceSession
    /// Threaded in from the list rather than rebuilt, so marking this report as sent refreshes
    /// the list standing behind the reader instead of a second store nobody is watching.
    @Bindable var local: LocalReportStore
    let saved: LocalReportStore.Saved

    @Environment(AppPreferences.self) private var preferences
    /// The report with its citations named, when the one on disk still had raw ids in it.
    @State private var repaired: DeepResearchReport?

    private var report: DeepResearchReport { repaired ?? saved.report }
    private var store: LocalReportStore { LocalReportStore.shared(for: session.connection.spaceId) }

    /// What the send control needs, or nothing at all when this access cannot send.
    private var sendContext: ReportSendContext? {
        guard session.connection.role.canSendChanges else { return nil }
        // Read back from the store rather than trusting the copy this view was handed: sending
        // rewrites the record, and the row that navigated here is a value from before that.
        let current = local.reports.first { $0.id == saved.id } ?? saved
        return ReportSendContext(session: session, store: local, saved: current)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let url = store.imageURL(for: saved) {
                    LocalReportImage(url: url)
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 8) {
                    PageText(saved.title, order: 0).font(.title3.weight(.semibold))
                    HStack(spacing: 12) {
                        Label("\(report.words.formatted()) words", systemImage: "text.alignleft")
                        Label(String(format: "%.1f pp.", report.pages), systemImage: "doc")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Text("\(saved.mode.label) · \(saved.modelLabel)")
                        .font(.caption2).foregroundStyle(.tertiary)

                    if report.citationsRejected > 0 {
                        NodusNotice(
                            tone: .caution,
                            title: "\(report.citationsRejected) invented citations, removed",
                            message: "Of \(report.citationsChecked) checked."
                        )
                    }

                    // A report you came back to is sendable too. It was not, and that was the
                    // whole gap: the control lived on the screen that generated the report and
                    // nowhere else, so a report from yesterday could only be shared as Markdown.
                    ReportActions(
                        markdown: report.markdown,
                        title: nil,
                        send: sendContext,
                        accent: session.accent
                    )
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(NodusSpace.cardPadding)
                .nodusGlass(NodusGlass(.regular, tint: session.accent))
                .nodusSearchOrder(0)

                ReportBody(report: report, session: session)

                ShareLink(item: report.markdown) {
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
        .nodusPageFunctions(
            accent: session.accent,
            chat: PageChatSubject(id: saved.id, title: saved.title, session: session)
        )
        .nodusHidesBottomBar()
        .navigationTitle(saved.mode.label)
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .nodusReadingMarks(spaceId: session.connection.spaceId, id: saved.id, accent: session.accent)
        .task { await nameTheSources() }
    }

    /// Ask the corpus what this report's citations point at, and keep the answer.
    ///
    /// Only for reports written before assembly did this — everything since arrives with its
    /// sources already named, `repairing` says so by returning nil, and opening one costs a
    /// single regex over the prose.
    private func nameTheSources() async {
        guard repaired == nil else { return }
        let citations = CorpusCitations(client: session.client, spaceId: session.connection.spaceId)
        guard let named = await citations.repairing(saved.report) else { return }
        repaired = named
        store.replace(saved.id, with: named)
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
                    PageText(row.text("title") ?? String(localized: "Report"), order: 0)
                        .font(.title3.weight(.semibold))
                    if let objective = row.text("objective") {
                        PageText(objective, order: 1).font(.subheadline).foregroundStyle(.secondary)
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
                .nodusSearchOrder(0)

                if let error {
                    NodusNotice(tone: .blocked, title: "Could not open", message: LocalizedStringKey(error))
                }

                if let sections = prose {
                    ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                        VStack(alignment: .leading, spacing: 14) {
                            if let heading = section.heading {
                                ReportSectionTitle(heading, accent: session.accent)
                            }
                            // The desktop writes one Markdown document with its own headings
                            // and `nodus://` citations in it. Rendered as plain text, both
                            // arrived as punctuation.
                            CorpusProse(section.body, accent: session.accent, session: session)
                                .nodusSearchOrder(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(ReportLayout.sectionPadding)
                        .nodusGlass(NodusGlass(.regular, tint: session.accent))
                        .nodusSearchOrder(index + 1)
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
        .nodusPageFunctions(
            accent: session.accent,
            chat: PageChatSubject(
                id: row.string("id") ?? row.text("title") ?? "report",
                title: row.text("title") ?? String(localized: "Report"),
                session: session
            )
        )
        .nodusHidesBottomBar()
        .navigationTitle("Report")
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        // Only when the vault names the row. Without an id there is nothing stable to hang a
        // mark on, and a mark keyed on a title would move to whatever report was renamed into
        // it — so the report reads exactly as it did before instead.
        .modifier(OptionalReadingMarks(session: session, id: row.string("id")))
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
            // Zero, so a section's own name is the first thing the find bar walks onto inside it.
            PageText(title.uppercased(), order: 0)
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
