import NodusKit
import NodusUI
import SwiftUI

/// One database, as a table you can read.
///
/// The server publishes the whole shape — `db_databases`, `db_columns`, `db_rows`, `db_cells`,
/// `db_views`, `db_select_options`, `db_relations`, `db_attachments` — and serves a page of
/// cells with each request, so a database with fifty thousand rows costs the same to open as
/// one with fifty.
///
/// It is read-only, and that is a server fact rather than a decision taken here: `db_cells` is
/// not on the mutation whitelist (`server/lib/core/mutations.mjs:27-39`), so a cell edited on
/// the phone has no channel to travel back through. The screen says so once, at the bottom,
/// rather than offering a field that silently does nothing.
struct DatabaseGridView: View {
    let session: SpaceSession
    let database: Row

    @State private var detail: DatabaseDetail?
    @State private var offset = 0
    @State private var isLoading = true
    @State private var error: String?

    private let pageSize = 50

    private var databaseId: String? { database.string("id") }

    var body: some View {
        Group {
            if let detail {
                grid(detail)
            } else if isLoading {
                ProgressView().tint(session.accent)
            } else if let error {
                NodusNotice(tone: .blocked, title: "Could not open", message: LocalizedStringKey(error)).padding(16)
            } else {
                ContentUnavailableView("Empty database", systemImage: "tablecells")
            }
        }
        .nodusHidesBottomBar()
        .navigationTitle(Text(verbatim: database.text("name") ?? String(localized: "Database")))
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .task(id: session.publishedRevision) { await load(offset: 0) }
    }

    private func grid(_ detail: DatabaseDetail) -> some View {
        // Columns arrive in the user's own order; the server sorted them by `position`.
        let columns = detail.columns

        return VStack(spacing: 0) {
            // The geometry reader is load-bearing, and the reason is worth writing down: a
            // scroll view with *both* axes proposes an unbounded size to its content, so
            // `maxHeight: .infinity` resolves to the content's own height and SwiftUI then
            // centres anything smaller than the viewport. A database with three rows opened
            // with its table floating in the middle of the screen. Giving the content a
            // minimum equal to the viewport is what puts it back in the top-left corner —
            // and a one-axis scroll view never needed it, which is why this only shows up
            // here.
            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                        ForEach(Array(detail.rows.enumerated()), id: \.offset) { _, row in
                            let context = DatabaseCell.Context(detail: detail, rowId: row.string("id") ?? "")
                            NavigationLink {
                                DatabaseRowView(
                                    session: session,
                                    databaseName: database.text("name"),
                                    columns: columns,
                                    context: context
                                )
                            } label: {
                                HStack(spacing: 0) {
                                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                                        cell(column, in: context)
                                            .frame(width: width(for: column), alignment: .leading)
                                            .padding(.horizontal, 10).padding(.vertical, 7)
                                    }
                                }
                                .frame(minHeight: 40)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().opacity(0.25)
                        }
                    } header: {
                        HStack(spacing: 0) {
                            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                                HStack(spacing: 4) {
                                    Image(systemName: DatabaseCell.icon(for: column.text("type")))
                                        .font(.caption2).foregroundStyle(session.accent)
                                    Text(verbatim: column.text("name") ?? "—")
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                }
                                .frame(width: width(for: column), alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 10)
                            }
                        }
                        // The app's own glass, not the system's material. On iOS 26 that is
                        // `glassEffect` — the row of column names really refracts the rows
                        // scrolling under it — and before 26 it is the same lit surface every
                        // other bar in the app wears, in the vault's colour rather than in grey.
                        .nodusGlass(NodusGlass(.thin, tint: session.accent), in: Rectangle())
                        }
                    }
                    .frame(
                        minWidth: proxy.size.width,
                        minHeight: proxy.size.height,
                        alignment: .topLeading
                    )
                }
            }

            footer(detail)
        }
    }

    /// One cell, at the size a table row allows: a thumbnail rather than the photograph, one
    /// line of chips rather than all of them. The whole of it is a tap away.
    @ViewBuilder
    private func cell(_ column: Row, in context: DatabaseCell.Context) -> some View {
        switch DatabaseCell.value(of: column, in: context) {
        case .empty:
            Color.clear.frame(height: 1)

        case .text(let value), .number(let value):
            Text(verbatim: value).font(.caption).lineLimit(2)

        case .checkbox(let on):
            Image(systemName: on ? "checkmark.square.fill" : "square")
                .font(.caption)
                .foregroundStyle(on ? AnyShapeStyle(session.accent) : AnyShapeStyle(.tertiary))

        case .options(let options):
            HStack(spacing: 4) {
                ForEach(options.prefix(2)) { option in
                    DatabaseOptionChip(option: option, accent: session.accent)
                }
                if options.count > 2 {
                    Text(verbatim: "+\(options.count - 2)").font(.caption2).foregroundStyle(.secondary)
                }
            }

        case .files(let files):
            HStack(spacing: 4) {
                ForEach(Array(files.prefix(3).enumerated()), id: \.offset) { _, file in
                    if let hash = DatabaseCell.imageHash(file, preferThumbnail: true) {
                        AssetImage(session: session, hash: hash)
                            .frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    } else {
                        // A file whose bytes stayed at home: a PDF, a video, anything that is
                        // not one of four image formats. It is still a file, and saying so
                        // beats an empty cell.
                        Image(systemName: "doc").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if files.count > 3 {
                    Text(verbatim: "+\(files.count - 3)").font(.caption2).foregroundStyle(.secondary)
                }
            }

        case .relations(let count):
            HStack(spacing: 3) {
                Image(systemName: "link").font(.caption2)
                Text("\(count)").font(.caption.monospacedDigit())
            }
            .foregroundStyle(.secondary)
        }
    }

    private func footer(_ detail: DatabaseDetail) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(detail.total.formatted()) rows · \(detail.columns.count) columns")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if offset > 0 {
                    Button("Previous") { Task { await load(offset: max(0, offset - pageSize)) } }
                        .font(.caption)
                }
                if detail.hasMore {
                    Button("Next") { Task { await load(offset: offset + pageSize) } }
                        .font(.caption)
                }
            }
            .tint(session.accent)

            Text("Read only: the server accepts no cell changes, so they are edited from Nodus desktop.")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .nodusGlass(NodusGlass(.thin, tint: session.accent), in: Rectangle())
    }

    /// A rough column width by type. Enough that dates and numbers do not get the same room as
    /// a paragraph of text.
    private func width(for column: Row) -> CGFloat {
        switch column.text("type") {
        case "number", "checkbox", "time", "relation": return 90
        case "date": return 120
        case "attachment", "ai_image": return 120
        case "select", "multi_select": return 150
        case "text", "formula", "ai": return 220
        default: return 160
        }
    }

    private func load(offset newOffset: Int) async {
        guard let databaseId else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await session.client.database(
                databaseId,
                in: session.connection.spaceId,
                limit: pageSize,
                offset: newOffset
            )
            offset = newOffset
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One row of a database, opened.
///
/// A table row is a compromise — two lines of text, a thumbnail, the first two chips — and a
/// gallery of photographs read through a 120-point column is not read at all. Here every
/// column gets its own line, every image its full width, and every file its name.
struct DatabaseRowView: View {
    let session: SpaceSession
    let databaseName: String?
    let columns: [Row]
    let context: DatabaseCell.Context

    /// The title column is the row's name, and repeating it as a field below its own heading
    /// is the kind of thing a generic renderer does and a person notices.
    private var titleColumn: Row? {
        columns.first { $0.text("type") == "title" } ?? columns.first
    }

    private var heading: String {
        guard let titleColumn, case .text(let value) = DatabaseCell.value(of: titleColumn, in: context) else {
            return String(localized: "Untitled row")
        }
        return value
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: heading).font(.title3.weight(.semibold))
                    if let databaseName {
                        Text(verbatim: databaseName).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .nodusGlass(NodusGlass(.regular, tint: session.accent))

                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    if case .empty = DatabaseCell.value(of: column, in: context) {
                        // A column with nothing in it says nothing. A dossier of forty
                        // headings over forty dashes is worse than a short one.
                        EmptyView()
                    } else if column.string("id") != titleColumn?.string("id") {
                        field(column)
                    }
                }
            }
            .padding(16)
            .nodusTopAnchor()
        }
        .nodusPageFunctions(accent: session.accent)
        .nodusHidesBottomBar()
        .navigationTitle(Text(verbatim: heading))
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
    }

    private func field(_ column: Row) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: DatabaseCell.icon(for: column.text("type")))
                    .font(.caption2).foregroundStyle(session.accent)
                Text(verbatim: column.text("name") ?? "—")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            value(column)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .nodusGlass(NodusGlass(.thin, tint: session.accent))
    }

    @ViewBuilder
    private func value(_ column: Row) -> some View {
        switch DatabaseCell.value(of: column, in: context) {
        case .empty:
            EmptyView()

        case .text(let text), .number(let text):
            Text(verbatim: text).font(.callout).textSelection(.enabled)

        case .checkbox(let on):
            Label(on ? "Yes" : "No", systemImage: on ? "checkmark.square.fill" : "square")
                .font(.callout)
                .foregroundStyle(on ? session.accent : .secondary)

        case .options(let options):
            FlowLayout(spacing: 5) {
                ForEach(options) { option in
                    DatabaseOptionChip(option: option, accent: session.accent)
                }
            }

        case .files(let files):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                    VStack(alignment: .leading, spacing: 4) {
                        if let hash = DatabaseCell.imageHash(file) {
                            AssetImage(session: session, hash: hash)
                                .frame(maxWidth: .infinity)
                                .frame(height: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        HStack(spacing: 6) {
                            Image(systemName: DatabaseCell.imageHash(file) == nil ? "doc" : "photo")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(verbatim: file.text("file_name") ?? String(localized: "File"))
                                .font(.caption).lineLimit(1)
                            if let bytes = file.int("bytes"), bytes > 0 {
                                Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        if DatabaseCell.imageHash(file) == nil {
                            // Said once per file rather than as a footnote: the reason this is
                            // a name and not a picture is a rule, not a failure.
                            Text("Only images travel to the server. This file stays on the desktop.")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        if let description = file.text("description") {
                            Text(verbatim: description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

        case .relations(let count):
            // The rows a relation points at are not in this page, and the desktop resolves
            // their labels by opening whatever vault they live in. Saying how many there are
            // is what this surface can say truthfully.
            Label("\(count) linked records", systemImage: "link")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
