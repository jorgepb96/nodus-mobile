import NodusAI
import NodusKit
import NodusUI
import SwiftUI

/// The two ways a dated report library can be walked.
///
/// A missing date always goes last. Treating it as `.distantPast` would put an old published
/// row first when the reader asks for the oldest report, even though its age is actually
/// unknown. The original position breaks ties so changing the direction never makes equal-date
/// rows jump around arbitrarily.
enum ReportLibrarySortOrder: Hashable {
    case newest
    case oldest

    func ordered<Element>(_ elements: [Element], date: (Element) -> Date?) -> [Element] {
        elements.enumerated().sorted { lhs, rhs in
            switch (date(lhs.element), date(rhs.element)) {
            case let (left?, right?) where left != right:
                return self == .newest ? left > right : left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}

/// Which reading state is allowed into the report library.
enum ReportLibraryReadFilter: Hashable {
    case all
    case read
    case unread

    func includes(id: String?, isRead: (String) -> Bool) -> Bool {
        guard self != .all else { return true }
        let read = id.map(isRead) ?? false
        return self == .read ? read : !read
    }
}

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
    @State private var sortOrder: ReportLibrarySortOrder = .newest
    @State private var readFilter: ReportLibraryReadFilter = .all

    /// What this reader has done with these reports. One store for both sections, because
    /// "which have I read" is a question about the list rather than about where a report
    /// was written.
    private var marks: ReportMarks { ReportMarks.shared(for: session.connection.storageId) }

    private var matchingLocal: [LocalReportStore.Saved] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let searched = needle.isEmpty ? local.reports : local.reports.filter {
            $0.title.lowercased().contains(needle) || $0.report.sections.contains {
                $0.title.lowercased().contains(needle)
            }
        }
        let filtered = searched.filter {
            readFilter.includes(id: $0.id, isRead: marks.isRead)
        }
        return sortOrder.ordered(filtered) { $0.createdAt }
    }

    private var matchingPublished: [Row] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let searched = needle.isEmpty ? published : published.filter {
            $0.searchableText.lowercased().contains(needle)
        }
        let filtered = searched.filter {
            readFilter.includes(id: $0.string("id"), isRead: marks.isRead)
        }
        return sortOrder.ordered(filtered) {
            $0.date("created_at") ?? $0.date("updated_at")
        }
    }

    /// The run in flight, which belongs to the space and not to the screen that started it.
    private var runner: DeepResearchRunner { DeepResearchRunner.shared(for: session.connection.storageId) }

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
                            readAction(for: saved.id, remoteId: saved.vaultRowId)
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
                        .swipeActions { row.string("id").map { readAction(for: $0, remoteId: $0) } }
                    }
                } header: {
                    NodusSectionLabel("Published in the vault")
                }
            }

            if matchingLocal.isEmpty, matchingPublished.isEmpty, !isLoading, !runner.isRunning, error == nil {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(emptyDescription)
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
                .padding(.horizontal, NodusSpace.page)
                .padding(.bottom, 8)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                filterMenu
                sortMenu
            }
        }
        .task(id: session.publishedRevision) { await load() }
        .refreshable { await load() }
    }

    private var emptyTitle: LocalizedStringKey {
        if !query.isEmpty { return "No matches" }
        if readFilter != .all { return "No matching reports" }
        return "No reports"
    }

    private var emptyDescription: LocalizedStringKey {
        if !query.isEmpty { return "No report contains “\(query)”." }
        if readFilter != .all { return "Change the read filter to show other reports." }
        return "Nothing published, and nothing generated here yet."
    }

    private var filterMenu: some View {
        Menu {
            Picker("Filter reports", selection: $readFilter) {
                NodusMenuLabel("All", systemImage: "doc.text").tag(ReportLibraryReadFilter.all)
                NodusMenuLabel("Read", systemImage: "checkmark.circle.fill").tag(ReportLibraryReadFilter.read)
                NodusMenuLabel("Unread", systemImage: "circle").tag(ReportLibraryReadFilter.unread)
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filter reports")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sortOrder) {
                NodusMenuLabel("Newest", systemImage: "arrow.down").tag(ReportLibrarySortOrder.newest)
                NodusMenuLabel("Oldest", systemImage: "arrow.up").tag(ReportLibrarySortOrder.oldest)
            }
        } label: {
            Image(systemName: sortOrder == .newest ? "arrow.down" : "arrow.up")
        }
        .accessibilityLabel("Sort")
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
            if let id = row.string("id"), id.hasPrefix("mobile-dr-"), row.embeddedJSON("image")?.objectValue?["status"] == .string("ready") {
                CompanionReportCoverImage(session: session, id: id)
                    .frame(width: Self.thumbnail, height: Self.thumbnail).clipShape(NodusRadius.controlShape)
            } else if let hash = row.embeddedJSON("image")?.objectValue?["hash"]?.stringValue {
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
    private func readAction(for id: String, remoteId: String? = nil) -> some View {
        let read = marks.isRead(id)
        return Button {
            if let remoteId {
                marks.setReadSynced(localId: id, remoteId: remoteId, !read, session: session)
            } else {
                marks.setRead(id, !read)
            }
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
            published = try await session.client.allDeepResearchReports(in: session.connection.spaceId)
            reconcilePublishedReadState()
            error = nil
        } catch let apiError as APIError where apiError.isNotPublished {
            published = []
            error = nil
        } catch where error.isCancellation {
            // Superseded or let go of. Nothing failed, so nothing is reported.
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reconcilePublishedReadState() {
        let byId = Dictionary(uniqueKeysWithValues: published.compactMap { row in
            row.string("id").map { ($0, row.date("read_at")) }
        })
        for (remoteId, readAt) in byId {
            let localId = local.reports.first(where: { $0.vaultRowId == remoteId })?.id ?? remoteId
            marks.reconcileRead(localId: localId, remoteId: remoteId, readAt: readAt)
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

/// The same 16:9 illustration and 26rem height cap as Desktop. A layout gives
/// the image an actual frame; a suggested aspect ratio alone lets a large
/// photograph keep its original height and fill most of an iPad screen.
private struct ReportHeroLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        return CGSize(width: width, height: min(width * 9 / 16, 416))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            view.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
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
                    NodusMenuLabel("Go to the bookmark", systemImage: "arrow.down.to.line")
                }
                Button(role: .destructive) {
                    removing = true
                } label: {
                    NodusMenuLabel("Remove the bookmark", systemImage: "bookmark.slash")
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

/// Local reports use the same annotation contract once the account can publish them. A
/// read-only local report still keeps its personal read flag and bookmark without pretending a
/// server mutation can succeed.
private struct LocalReportReadingTools: ViewModifier {
    let session: SpaceSession
    let localId: String
    let remoteId: String?
    let remoteReadAt: Date?
    let rows: [Row]

    func body(content: Content) -> some View {
        if session.canAuthor, let remoteId {
            content.modifier(SyncedReportReadingTools(
                session: session,
                id: remoteId,
                localMarkId: localId,
                remoteReadAt: remoteReadAt,
                rows: rows
            ))
        } else {
            content.nodusReadingMarks(spaceId: session.connection.storageId, id: localId, accent: session.accent)
        }
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
            content.nodusReadingMarks(spaceId: session.connection.storageId, id: id, accent: session.accent)
        } else {
            content
        }
    }
}

/// The published report's local read flag plus its server-backed reader annotations.
///
/// The read flag remains personal to this phone. Highlights, comments and the bookmark
/// instead enter the mutation ledger immediately and are overlaid from that durable queue
/// until the owner's next publication contains them.
struct SyncedReportReadingTools: ViewModifier {
    let session: SpaceSession
    let id: String
    let localMarkId: String
    let remoteReadAt: Date?
    let rows: [Row]
    let scope: String
    let annotationPrefix: String

    private let marks: ReportMarks
    @State private var legacyBookmark: ReadingBookmarks
    @State private var annotations: ReaderAnnotations

    init(
        session: SpaceSession,
        id: String,
        localMarkId: String? = nil,
        remoteReadAt: Date? = nil,
        rows: [Row],
        scope: String = "source",
        annotationPrefix: String = ""
    ) {
        self.session = session
        self.id = id
        self.localMarkId = localMarkId ?? id
        self.remoteReadAt = remoteReadAt
        self.rows = rows
        self.scope = scope
        self.annotationPrefix = annotationPrefix
        let store = ReportMarks.shared(for: session.connection.storageId)
        marks = store
        _legacyBookmark = State(initialValue: ReadingBookmarks(bookmark: store.bookmark(for: localMarkId ?? id)) { next in
            store.setBookmark(next, for: localMarkId ?? id)
        })
        _annotations = State(initialValue: ReaderAnnotations(
            draftId: id,
            scope: scope,
            isWritable: session.canAnnotateReports,
            idPrefix: annotationPrefix
        ))
    }

    private var rowStamp: String {
        "\(remoteReadAt?.timeIntervalSince1970 ?? -1)|" + rows.map { "\($0.string("id") ?? ""):\($0.string("updated_at") ?? "")" }.joined(separator: "|")
    }

    func body(content: Content) -> some View {
        content
            .environment(legacyBookmark)
            .environment(annotations)
            .toolbar {
                if UIDevice.current.userInterfaceIdiom == .phone {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            readButton
                            if annotations.isWritable {
                                highlighterButton
                                highlightColorMenu
                                undoHighlightButton
                            }
                            if annotations.bookmark != nil || legacyBookmark.bookmark != nil { bookmarkMenu }
                        } label: {
                            Label("Reading tools", systemImage: "ellipsis.circle")
                                .foregroundStyle(session.accent)
                        }
                        .tint(session.accent)
                        .accessibilityIdentifier("report-reading-tools")
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) { readButton }
                    if annotations.isWritable {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            undoHighlightButton
                            highlighterButton
                            highlightColorMenu
                        }
                    }
                    if annotations.bookmark != nil || legacyBookmark.bookmark != nil {
                        ToolbarItem(placement: .topBarTrailing) { bookmarkMenu }
                    }
                }
            }
            .sheet(
                item: Binding(
                    get: { annotations.presentation },
                    set: { annotations.presentation = $0 }
                )
            ) { presentation in
                ReaderAnnotationSheet(annotations: annotations, presentation: presentation)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .alert(
                "The annotation is waiting on this device",
                isPresented: Binding(
                    get: { annotations.error != nil },
                    set: { if !$0 { annotations.dismissError() } }
                )
            ) {
                Button("OK") { annotations.dismissError() }
            } message: {
                Text(annotations.error ?? "It will be retried from the send queue.")
            }
            .task(id: rowStamp) {
                marks.reconcileRead(localId: localMarkId, remoteId: id, readAt: remoteReadAt)
                await annotations.load(rows: rows, session: session)
                guard annotations.bookmark != nil else { return }
                // The document is still measuring on the first pass; the second aim lands
                // once a long report has its final content height.
                try? await Task.sleep(for: .milliseconds(180))
                annotations.aimAtBookmark()
                try? await Task.sleep(for: .milliseconds(480))
                annotations.aimAtBookmark()
            }
            .onChange(of: annotations.bookmark?.id) { _, synced in
                if synced != nil, legacyBookmark.bookmark != nil { legacyBookmark.clear() }
            }
            .onDisappear {
                // Undo belongs to this reading session; synced highlights themselves remain.
                annotations.clearHighlightUndoHistory()
            }
    }

    private var readButton: some View {
        let read = marks.isRead(localMarkId)
        return Button {
            marks.setReadSynced(localId: localMarkId, remoteId: id, !read, session: session)
        } label: {
            Label(
                read ? "Mark as unread" : "Mark as read",
                systemImage: read ? "checkmark.circle.fill" : "checkmark.circle"
            )
        }
        .tint(read ? Color.nodusSuccess : session.accent)
    }

    private var highlighterButton: some View {
        Button {
            annotations.toggleHighlighter()
        } label: {
            // A Label, not a bare symbol: the toolbar draws only the icon, but on a phone these
            // controls collapse into the reading-tools menu, where a row needs its words.
            Label(annotations.highlighterEnabled ? "Turn highlighter off" : "Turn highlighter on", systemImage: "highlighter")
        }
        .tint(annotations.highlighterEnabled ? annotations.selectedColor.color : session.accent)
        .accessibilityLabel(annotations.highlighterEnabled ? "Turn highlighter off" : "Turn highlighter on")
        .accessibilityValue(annotations.highlighterEnabled ? "On" : "Off")
    }

    private var undoHighlightButton: some View {
        Button {
            annotations.undoLastHighlight()
        } label: {
            Label("Undo last highlight", systemImage: "arrow.uturn.backward")
        }
        .disabled(!annotations.canUndoLastHighlight)
        .tint(session.accent)
        .accessibilityLabel("Undo last highlight")
        .accessibilityIdentifier("reader-undo-highlight")
    }

    private var highlightColorMenu: some View {
        Menu {
            Section("Highlight color") {
                ForEach(ReaderAnnotationColor.allCases) { colour in
                    Button {
                        annotations.selectedColor = colour
                    } label: {
                        Label(colour.label, systemImage: annotations.selectedColor == colour ? "checkmark.circle.fill" : "circle.fill")
                    }
                    .tint(colour.color)
                }
            }
        } label: {
            Label {
                Text("Highlight color")
            } icon: {
                Image(systemName: "circle.fill")
                    .foregroundStyle(annotations.selectedColor.color)
            }
        }
        .accessibilityLabel("Highlight color")
        .accessibilityValue(Text(annotations.selectedColor.label))
    }

    private var bookmarkMenu: some View {
        Menu {
            Button {
                if annotations.bookmark != nil { annotations.aimAtBookmark() }
                else { legacyBookmark.aimAtBookmark() }
            } label: {
                NodusMenuLabel("Go to the bookmark", systemImage: "arrow.down.to.line")
            }
            Button(role: .destructive) {
                if let bookmark = annotations.bookmark { annotations.delete(bookmark) }
                else { legacyBookmark.clear() }
            } label: {
                NodusMenuLabel("Remove the bookmark", systemImage: "bookmark.slash")
            }
        } label: {
            Image(systemName: "bookmark.fill")
        }
        .tint(Color.nodusBookmarkRule)
        .accessibilityLabel("The reading bookmark")
    }
}

private struct ReaderAnnotationSheet: View {
    let annotations: ReaderAnnotations
    let presentation: ReaderAnnotations.Presentation

    var body: some View {
        NavigationStack {
            Group {
                switch presentation {
                case .bookmark(let annotation):
                    actionSheet(annotation, title: "Reading bookmark", icon: "bookmark.fill")
                case .comment(let annotation):
                    ReaderCommentEditor(annotations: annotations, annotation: annotation, anchor: annotation.anchor)
                case .newComment(let anchor):
                    ReaderCommentEditor(annotations: annotations, annotation: nil, anchor: anchor)
                }
            }
            .padding(NodusSpace.page)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { annotations.presentation = nil } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
    }

    private func actionSheet(_ annotation: ReaderAnnotation, title: LocalizedStringKey, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon).font(.headline)
            Text("“\(ReadingBookmarks.label(annotation.anchor.selectedText))”")
                .font(.callout).foregroundStyle(.secondary)
            if annotations.isWritable {
                Button(role: .destructive) {
                    // Highlights deliberately have no confirmation. The bookmark is one
                    // reversible place marker and follows the same lightweight treatment.
                    annotations.delete(annotation)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(NodusGlassButtonStyle(accent: .red))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReaderCommentEditor: View {
    let annotations: ReaderAnnotations
    let annotation: ReaderAnnotation?
    let anchor: ReaderAnnotationAnchor

    @State private var bodyText: String
    @State private var confirmingDelete = false

    init(annotations: ReaderAnnotations, annotation: ReaderAnnotation?, anchor: ReaderAnnotationAnchor) {
        self.annotations = annotations
        self.annotation = annotation
        self.anchor = anchor
        _bodyText = State(initialValue: annotation?.comment ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(annotation == nil ? "New comment" : "Comment", systemImage: "text.bubble")
                .font(.headline)
            Text("“\(ReadingBookmarks.label(anchor.selectedText))”")
                .font(.caption).foregroundStyle(.secondary)

            if annotations.isWritable {
                TextEditor(text: $bodyText)
                    .frame(minHeight: 82)
                    .padding(8)
                    .nodusFieldSurface(accent: .secondary)
                    .accessibilityLabel("Comment")
                    .accessibilityIdentifier("report-comment-editor")
            } else {
                Text(annotation?.comment ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .toolbar {
            if annotations.isWritable {
                ToolbarItemGroup(placement: .confirmationAction) {
                    if annotation != nil {
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Delete")
                    }
                    Button("Save") {
                        if let annotation { annotations.updateComment(annotation, body: bodyText) }
                        else { annotations.saveNewComment(anchor, body: bodyText) }
                    }
                    .accessibilityIdentifier("report-comment-save")
                    .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .confirmationDialog(
            "Delete this comment?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            if let annotation {
                Button("Delete the comment", role: .destructive) { annotations.delete(annotation) }
            }
            Button("Keep it", role: .cancel) {}
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
            if let notice = report.materialNotice {
                NodusNotice(tone: .info, title: "Alcance de la investigación", message: LocalizedStringKey(notice))
            }
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
                .id("report-section-\(index)")
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
    @State private var liveDetail: DeepResearchReportDetail?
    @State private var sheet: DeepResearchReaderSheet?
    @State private var activeSection = 0

    private var report: DeepResearchReport { repaired ?? saved.report }
    private var publishedMarkdown: String? {
        guard let row = liveDetail?.report else { return nil }
        let draft = (row.embeddedJSON("draft") ?? row["draft"])?.objectValue
        if let markdown = draft?["draftMarkdown"]?.stringValue, !markdown.isEmpty { return markdown }
        return row.text("content") ?? row.text("markdown")
    }
    private var liveMarkdown: String { publishedMarkdown ?? report.markdown }
    private var liveTitle: String { liveDetail?.report.text("title") ?? saved.title }
    private var store: LocalReportStore { LocalReportStore.shared(for: session.connection.storageId) }
    private var currentSaved: LocalReportStore.Saved { local.reports.first(where: { $0.id == saved.id }) ?? saved }

    /// What the send control needs, or nothing at all when this access cannot send.
    private var sendContext: ReportSendContext? {
        guard session.canAuthor else { return nil }
        // Read back from the store rather than trusting the copy this view was handed: sending
        // rewrites the record, and the row that navigated here is a value from before that.
        let current = local.reports.first { $0.id == saved.id } ?? saved
        return ReportSendContext(session: session, store: local, saved: current)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                if let hash = liveDetail?.image?.text("hash") {
                    ReportHeroLayout { AssetImage(session: session, hash: hash) }
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else if let url = store.imageURL(for: currentSaved) {
                    ReportHeroLayout { LocalReportImage(url: url) }
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 8) {
                    PageText(liveTitle, order: 0).font(.title3.weight(.semibold))
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
                        markdown: liveMarkdown,
                        title: nil,
                        pdf: (session, currentSaved.vaultRowId ?? currentSaved.id, liveTitle),
                        localPDF: liveDetail == nil ? (currentSaved, local) : nil,
                        send: sendContext,
                        saveToNotes: (saved.id, liveTitle, liveMarkdown, session),
                        accent: session.accent
                    )
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(NodusSpace.cardPadding)
                .nodusGlass(NodusGlass(.regular, tint: session.accent))
                .nodusSearchOrder(0)

                if let publishedMarkdown {
                    CorpusProse(publishedMarkdown, accent: session.accent, session: session)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(ReportLayout.sectionPadding)
                        .nodusGlass(NodusGlass(.regular, tint: session.accent))
                        .nodusSearchOrder(1)
                } else {
                    ReportBody(report: report, session: session)
                }

                ShareLink(item: liveMarkdown) {
                    Label("Share as Markdown", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(NodusGlassButtonStyle(accent: session.accent))
                }
                .padding(NodusSpace.page)
                .frame(maxWidth: ReportLayout.readerMeasure)
                .frame(maxWidth: .infinity)
                .nodusTopAnchor()
            }
            .safeAreaInset(edge: .top) {
                HStack(spacing: 10) {
                    Text("\(min(activeSection + 1, max(1, report.sections.count))) / \(max(1, report.sections.count))")
                        .font(.caption.monospacedDigit())
                    ProgressView(value: Double(activeSection + 1), total: Double(max(1, report.sections.count)))
                        .tint(session.accent)
                }
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(.ultraThinMaterial)
            }
            .onChange(of: activeSection) { _, section in
                guard report.sections.indices.contains(section) else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo("report-section-\(section)", anchor: .top) }
                UserDefaults.standard.set(section, forKey: "deep-research.reader-section.\(saved.id)")
            }
        }
        .nodusReadingStyle(ReadingStyle(scale: preferences.readingScale, document: true))
        .nodusPageFunctions(
            accent: session.accent,
            chat: PageChatSubject(id: saved.id, title: liveTitle, session: session)
        )
        .nodusHidesBottomBar()
        .navigationTitle(saved.mode.label)
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .modifier(LocalReportReadingTools(
            session: session,
            localId: saved.id,
            remoteId: currentSaved.vaultRowId,
            remoteReadAt: liveDetail?.report.date("read_at"),
            rows: liveDetail?.annotations ?? []
        ))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { sheet = .outline } label: { Image(systemName: "list.bullet") }
                    .accessibilityLabel("Report outline")
                    .accessibilityIdentifier("report-tool-outline")
                Button { sheet = .workspace } label: { Image(systemName: "rectangle.3.group") }
                    .accessibilityLabel("Sources and citations")
                    .accessibilityIdentifier("report-tool-sources")
                Button { sheet = .translation } label: { Image(systemName: "character.book.closed") }
                    .accessibilityLabel("Translations")
                    .accessibilityIdentifier("report-tool-translations")
                Button { sheet = .image } label: { Image(systemName: "photo") }
                    .accessibilityLabel("Report image")
                    .accessibilityIdentifier("report-tool-image")
            }
        }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .outline:
                DeepResearchOutlineSheet(report: report, activeSection: activeSection, accent: session.accent) { section in
                    activeSection = section
                    sheet = nil
                }
                .presentationDetents([.medium, .large])
            case .workspace:
                DeepResearchWorkspaceSheet(report: report, session: session)
                    .presentationDetents([.large])
            case .translation:
                DeepResearchTranslationSheet(
                    reportId: currentSaved.vaultRowId ?? saved.id,
                    sourceMarkdown: liveMarkdown,
                    sourceTitle: currentSaved.title,
                    session: session,
                    remoteRows: liveDetail?.translations,
                    syncEnabled: currentSaved.vaultRowId != nil
                )
                    .presentationDetents([.large])
            case .image:
                DeepResearchImageEditorSheet(saved: currentSaved, store: local, session: session)
                    .presentationDetents([.large])
            }
        }
        .task {
            activeSection = min(
                UserDefaults.standard.integer(forKey: "deep-research.reader-section.\(saved.id)"),
                max(0, report.sections.count - 1)
            )
            await nameTheSources()
        }
        .task(id: session.publishedRevision) { await refreshPublishedCopy() }
        .task(id: currentSaved.vaultRowId) { await refreshPublishedCopy() }
    }

    /// A sent local report and its published row are the same document under two identities.
    /// Refresh the canonical server copy while this reader remains mounted so annotations,
    /// read state, translations and image metadata converge without a navigation round-trip.
    private func refreshPublishedCopy() async {
        guard let id = currentSaved.vaultRowId else { return }
        do {
            liveDetail = try await session.client.deepResearchReport(id, in: session.connection.spaceId)
        } catch where error.isCancellation {
        } catch {
            // The durable local report remains readable while its first publication is still
            // waiting for Desktop. The next revision probe tries again.
        }
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
    /// Empty space at either side of the prose on a regular-width device. The right rail holds
    /// comment and bookmark controls; mirroring it on the left keeps the 660-point reading
    /// column centred rather than nudging every paragraph sideways when it gains a note.
    static let annotationRail: CGFloat = 44
    /// A little more than a card's own padding, because the one thing inside is prose and prose
    /// wants a margin of its own.
    static let sectionPadding: CGFloat = 19
    /// The report card grows on iPad so the rails come from the device's lateral margins, not
    /// from the central text block. On compact screens the surrounding frame simply contracts.
    static let readerMeasure = measure + annotationRail * 2 + sectionPadding * 2
}

/// A report the owner published from the desktop.
struct PublishedReportReader: View {
    let session: SpaceSession
    let row: Row

    @Environment(AppPreferences.self) private var preferences
    @Environment(\.downloadedReaderOnly) private var downloadedOnly
    @State private var visualEditorOpen = false
    @State private var detail: DeepResearchReportDetail?
    @State private var error: String?
    @State private var translationOpen = false
    @State private var loading = false
    @State private var metadataExpanded = false
    @State private var authoredFigureContext: JSONValue?
    @State private var figureIssue: String?
    @State private var figureSourceIsAuthored = false
    @State private var figureSourceIsDevice = false
    private var phoneHeader: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    private var currentRow: Row { detail?.report ?? row }
    private var localCoverID: String? {
        guard let id = currentRow.string("id"), id.hasPrefix("mobile-dr-"),
              (detail?.image?.text("status") ?? row.embeddedJSON("image")?.objectValue?["status"]?.stringValue) == "ready" else { return nil }
        return id
    }
    private var imageHash: String? {
        if let detail { return detail.image?.text("hash") }
        return row.embeddedJSON("image")?.objectValue?["hash"]?.stringValue
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if currentRow.string("id")?.hasPrefix("mobile-dr-") == true {
                    Label("Informe escrito en este dispositivo · la publicación en el Mac se revisa en la cola", systemImage: "pencil.and.outline")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if detail?.fromDevice == true {
                    Label("Sin conexión · informe descargado en este dispositivo", systemImage: "wifi.slash")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if session.connection.desktopPairingId != nil, let id = currentRow.string("id"), !id.hasPrefix("mobile-dr-") {
                    LinkReportHero(session: session, id: id, height: phoneHeader ? 190 : 280)
                } else {
                    if let id = localCoverID {
                        ReportHeroLayout { CompanionReportCoverImage(session: session, id: id) }
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    } else if let hash = imageHash {
                        ReportHeroLayout { AssetImage(session: session, hash: hash) }
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    PageText(currentRow.text("title") ?? String(localized: "Report"), order: 0)
                        .font(.title3.weight(.semibold))
                    if phoneHeader {
                        DisclosureGroup("Detalles y opciones", isExpanded: $metadataExpanded) {
                            reportMetadata
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("report-native-details")
                    } else { reportMetadata }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .nodusSearchOrder(0)

                if let error {
                    NodusNotice(tone: .blocked, title: "Could not open", message: LocalizedStringKey(error))
                    Button("Reintentar") { Task { await load() } }.frame(minHeight: 44).disabled(loading).accessibilityIdentifier("report-native-load-retry")
                }

                if let figureIssue {
                    NodusNotice(tone: .blocked, title: "Recursos visuales del informe", message: LocalizedStringKey(figureIssue))
                    Button("Reintentar figuras") { Task { if let id = currentRow.string("id") { authoredFigureContext = await loadFigureContext(id) } } }.frame(minHeight: 44)
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
                            CorpusProse(section.body, accent: session.accent, session: session, figureContext: authoredFigureContext)
                                .environment(\.authoredResearchReaderID, currentRow.string("id").flatMap { $0.hasPrefix("mobile-dr-") ? $0 : nil })
                                .nodusSearchOrder(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .padding(.horizontal, phoneHeader ? 0 : ReportLayout.sectionPadding)
                        .nodusSearchOrder(index + 1)
                    }
                } else if detail == nil, error == nil {
                    ProgressView().tint(session.accent).frame(maxWidth: .infinity)
                }
            }
            .padding(NodusSpace.page)
            .frame(maxWidth: ReportLayout.readerMeasure)
            .frame(maxWidth: .infinity)
            .nodusTopAnchor()
        }
        .accessibilityIdentifier("report-native-reader")
        .nodusReadingStyle(ReadingStyle(scale: preferences.readingScale, document: true))
        .nodusPageFunctions(
            accent: session.accent,
            chat: PageChatSubject(
                id: currentRow.string("id") ?? currentRow.text("title") ?? "report",
                title: currentRow.text("title") ?? String(localized: "Report"),
                session: session
            )
        )
        .nodusHidesBottomBar()
        .navigationTitle("Report")
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        // Published reports use the server-backed annotation rows. A row without an id
        // has no stable identity and therefore keeps the plain reader.
        .modifier(OptionalSyncedReportReadingTools(
            session: session,
            id: currentRow.string("id"),
            remoteReadAt: currentRow.date("read_at"),
            rows: detail?.annotations ?? []
        ))
        .toolbar {
            if session.canAuthor {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { visualEditorOpen = true } label: { Image(systemName: "photo.badge.plus") }
                        .accessibilityLabel("Recursos visuales del informe")
                        .accessibilityIdentifier("report-tool-visuals")
                        .disabled(document == nil)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { translationOpen = true } label: { Image(systemName: "character.book.closed") }
                    .accessibilityLabel("Translations")
                    .accessibilityIdentifier("report-tool-translations")
                    .disabled(document == nil)
            }
        }
        .sheet(isPresented: $visualEditorOpen, onDismiss: { Task { if let id = currentRow.string("id") { authoredFigureContext = await loadFigureContext(id) } } }) {
            if let id = currentRow.string("id") {
                NavigationStack {
                    SharedDesktopSurface(session: session, surface: .deepResearch, initialResearchVisualReportId: id, downloadedOnly: downloadedOnly)
                        .navigationTitle("Recursos visuales")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { visualEditorOpen = false } } }
                }.presentationDetents([.large])
            }
        }
        .sheet(isPresented: $translationOpen) {
            if let id = currentRow.string("id"), let document {
                DeepResearchTranslationSheet(
                    reportId: id,
                    sourceMarkdown: document,
                    sourceTitle: currentRow.string("title") ?? "Deep Research",
                    session: session,
                    remoteRows: detail?.translations
                )
                .presentationDetents([.large])
            }
        }
        .task(id: "\(session.publishedRevision ?? ""):\(session.companionDownloadRevision)") { await load() }
    }

    @ViewBuilder private var reportMetadata: some View {
                    if let objective = currentRow.text("objective") {
                        PageText(objective, order: 1).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let document {
                        ReportActions(
                            markdown: document,
                            title: currentRow.text("title"),
                            // Beside the copy, because it is the other way to take the report
                            // with you — and the only one that keeps its layout.
                            pdf: currentRow.string("id").map {
                                (session, $0, currentRow.text("title") ?? String(localized: "Report"))
                            },
                            saveToNotes: currentRow.string("id").map {
                                ($0, currentRow.text("title") ?? String(localized: "Report"), document, session)
                            },
                            accent: session.accent
                        )
                        .environment(\.downloadedReaderOnly, downloadedOnly || (figureSourceIsDevice && session.connection.desktopPairingId != nil))
                        .padding(.top, 6)
                    }
    }

    private struct Prose { let heading: String?; let body: String }

    /// The draft is a Writing-Workshop document (`shared/types.ts:5838`), and the field that
    /// actually carries the prose is `draftMarkdown` — one document, not a list of section
    /// bodies. `outline` beside it holds titles and purposes with no text in them, which is why
    /// reading `outline` for prose returns a report of empty sections.
    ///
    /// The `sections` fallback is kept because that is the shape older versions of this app's
    /// orchestrator produced. Once published, `draftMarkdown` wins so every device renders one
    /// canonical document and annotation offsets never restart at a section boundary.
    private var prose: [Prose]? {
        guard let detail else { return nil }
        let draft = (detail.report.embeddedJSON("draft") ?? detail.report["draft"])?.objectValue

        // The desktop's own drafts, and everything this app now sends to a vault.
        //
        // `abstract` is deliberately not shown beside it: `draftMarkdown` is the whole
        // document and already opens with the abstract under its own heading, so rendering
        // both printed the summary twice.
        if let markdown = draft?["draftMarkdown"]?.stringValue, !markdown.isEmpty {
            return [Prose(heading: nil, body: markdown)]
        }

        if let sections = draft?["sections"]?.arrayValue, !sections.isEmpty {
            let parsed = sections.compactMap { entry -> Prose? in
                guard let object = entry.objectValue else { return nil }
                let body = object["markdown"]?.stringValue ?? object["body"]?.stringValue ?? object["prose"]?.stringValue
                guard let body, !body.isEmpty else { return nil }
                return Prose(heading: object["title"]?.stringValue, body: body)
            }
            if !parsed.isEmpty { return parsed }
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

    private func loadFigureContext(_ id: String, preferAuthored: Bool? = nil, expectedDraft:JSONValue? = nil) async -> JSONValue? {
        do { let value = try await CompanionResearchFigures.context(session: session, reportID: id, downloadedOnly:(downloadedOnly || figureSourceIsDevice) && session.connection.desktopPairingId != nil && !session.isDemo, preferAuthored:preferAuthored ?? figureSourceIsAuthored, expectedDraft:expectedDraft ?? detail?.report.embeddedJSON("draft")); figureIssue = value?.objectValue?["unsupportedOriginals"]?.arrayValue?.isEmpty == false ? "La vista previa está disponible. Algunos originales de capacidades todavía no se pueden abrir en este lector." : nil; return value }
        catch is CancellationError { return nil }
        catch { figureIssue = error.localizedDescription; return nil }
    }
    private func load() async {
        guard let id = row.string("id") else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            if (!downloadedOnly || id.hasPrefix("mobile-dr-")), let own = try await CompanionDeepResearchResult.detail(session: session, id: id) {
                figureSourceIsAuthored = true; figureSourceIsDevice = false; authoredFigureContext = await loadFigureContext(id,preferAuthored:true); detail = own; error = nil; return
            }
            if downloadedOnly,session.connection.desktopPairingId != nil,!session.isDemo {
                let source=try await CompanionDownloadedResearchFigures.source(session:session,reportID:id)
                detail=source.detail;figureSourceIsAuthored=false;figureSourceIsDevice=true
                authoredFigureContext=await loadFigureContext(id,expectedDraft:source.detail.report.embeddedJSON("draft"));error=nil;return
            }
            do {
                let loaded = try await session.client.deepResearchReport(id, in: session.connection.spaceId)
                figureSourceIsAuthored = false; figureSourceIsDevice = loaded.fromDevice
                authoredFigureContext = await loadFigureContext(id,expectedDraft:loaded.report.embeddedJSON("draft"))
                detail = loaded
                error = nil
            } catch {
                guard !downloadedOnly, isPrivateBridgeOffline(error),
                      let own = try await CompanionDeepResearchResult.detail(session: session, id: id, publishedReceipt: true) else { throw error }
                figureSourceIsAuthored = true; figureSourceIsDevice = false
                authoredFigureContext = await loadFigureContext(id,preferAuthored:true)
                detail = own
                self.error = nil
            }
        } catch where error.isCancellation {
            // Superseded or let go of. Nothing failed, so nothing is reported.
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct OptionalSyncedReportReadingTools: ViewModifier {
    let session: SpaceSession
    let id: String?
    var localMarkId: String? = nil
    var remoteReadAt: Date? = nil
    let rows: [Row]

    func body(content: Content) -> some View {
        if let id {
            content.modifier(SyncedReportReadingTools(
                session: session,
                id: id,
                localMarkId: localMarkId,
                remoteReadAt: remoteReadAt,
                rows: rows
            ))
        } else {
            content
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ title: String, accent: Color) {
        self.title = title
        self.accent = accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Zero, so a section's own name is the first thing the find bar walks onto inside it.
            PageText(title.uppercased(), order: 0)
                .font(reading.font(.title3, weight: .bold, dynamicTypeSize: dynamicTypeSize))
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

/// Authored image bytes remain with their checkpoint even after consulted packs
/// are purged. This path never substitutes a live asset or a different report.
private struct CompanionReportCoverImage: View {
    let session: SpaceSession
    let id: String
    @State private var image: UIImage?
    @State private var failure: String?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else if let failure { ContentUnavailableView("No se ha podido cargar la portada", systemImage: "photo.badge.exclamationmark", description: Text(failure)) }
            else { ProgressView() }
        }
        .task(id: id) {
            do {
                guard let dataURL = try await CompanionDeepResearchResult.cover(session: session, id: id, dataURL: true).stringValue,
                      let payload = dataURL.split(separator: ",", maxSplits: 1).last, let bytes = Data(base64Encoded: String(payload)),
                      let decoded = UIImage(data: bytes) else { throw DesktopBridgeError.malformedResponse }
                image = decoded
            } catch { failure = error.localizedDescription }
        }
    }
}

/// Explicit access from the current gallery. Original IDs, images, send receipts
/// and the original reader stay in their original store; nothing is migrated or
/// reclassified as a new generation checkpoint.
struct LegacyResearchReportsView: View {
    let session: SpaceSession
    @Bindable var local: LocalReportStore
    var body: some View {
        List {
            if let checkpoint = DeepResearchCheckpointStore.load(spaceId: session.connection.storageId), !checkpoint.isComplete {
                Section {
                    if session.aiExecutionMode == .autonomous {
                        NavigationLink("Continuar el informe anterior inacabado") {
                            DeepResearchScreen(session: session, local: local)
                        }
                    } else {
                        Text("Hay un informe anterior inacabado. Sus respuestas se conservan; la generación en este dispositivo está aplazada durante esta beta.")
                    }
                }
            }

            if local.reports.isEmpty {
                ContentUnavailableView("No hay informes de versiones anteriores", systemImage: "doc.text")
            } else {
                Section {
                    ForEach(local.reports) { saved in
                        NavigationLink {
                            LocalReportReader(session: session, local: local, saved: saved)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(saved.title)
                                Text(saved.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                if saved.wasSent { Label("Enviado al Mac", systemImage: "paperplane").font(.caption) }
                            }
                        }
                    }
                } header: { Text("Guardados en este dispositivo por versiones anteriores") }
            }
        }
        .navigationTitle("Informes anteriores")
        .nodusPageBackdrop(accent: session.accent)
    }
}
