import NodusKit
import SwiftUI

/// What one cell of a database means, read from the column's type.
///
/// `db_cells.value_text` is text for every column, and what that text *is* depends entirely on
/// the type: a select stores an option id, a multi-select a JSON array of them, a checkbox `0`
/// or `1`, a number a bare numeral. Rendering the column without asking the type is how a
/// select shows a UUID and a checkbox shows the digit one — which is what this screen did.
///
/// The vocabulary is `shared/databases.ts:20`; anything not listed there is read as text,
/// exactly as `columnTypeDef` falls back to text on the desktop.
enum DatabaseCell {
    /// The decoded value of one cell, or nil when the row has nothing for that column.
    enum Value {
        case text(String)
        case number(String)
        case checkbox(Bool)
        /// Option labels with their colours, for `select` and `multi_select`.
        case options([Option])
        /// Files on this row for this column. Some carry an image, some are only a name.
        case files([Row])
        /// How many rows or entities this relation cell points at.
        case relations(Int)
        case empty
    }

    struct Option: Identifiable, Hashable {
        let id: String
        let label: String
        let colour: String?
    }

    /// Everything a cell needs from the page, gathered once per row rather than searched per
    /// column: a database with forty columns and fifty rows is two thousand lookups a pass.
    struct Context {
        let cells: [String: Row]
        let options: [String: Row]
        let attachments: [String: [Row]]
        let relations: [String: Int]

        init(detail: DatabaseDetail, rowId: String) {
            cells = Dictionary(
                detail.cells.filter { $0.string("row_id") == rowId }
                    .compactMap { cell in cell.string("column_id").map { ($0, cell) } },
                uniquingKeysWith: { first, _ in first }
            )
            options = Dictionary(
                detail.options.compactMap { option in option.string("id").map { ($0, option) } },
                uniquingKeysWith: { first, _ in first }
            )
            attachments = Dictionary(
                grouping: detail.attachments.filter { $0.string("row_id") == rowId },
                by: { $0.string("column_id") ?? "" }
            )
            relations = detail.relations
                .filter { $0.string("row_id") == rowId }
                .reduce(into: [:]) { counts, relation in
                    counts[relation.string("column_id") ?? "", default: 0] += 1
                }
        }
    }

    static func value(of column: Row, in context: Context) -> Value {
        guard let columnId = column.string("id") else { return .empty }
        let type = column.text("type") ?? "text"

        switch type {
        case "attachment", "ai_image":
            let files = context.attachments[columnId] ?? []
            return files.isEmpty ? .empty : .files(files)

        case "relation":
            let count = context.relations[columnId] ?? 0
            return count == 0 ? .empty : .relations(count)

        default:
            break
        }

        guard let raw = context.cells[columnId]?.text("value_text") else { return .empty }

        switch type {
        case "checkbox":
            // `encodeCheckbox` writes "1"/"0"; `decodeCheckbox` also accepts "true".
            return .checkbox(raw == "1" || raw.lowercased() == "true")

        case "select":
            return .options(options(ids: [raw], in: context))

        case "multi_select":
            // A JSON array of option ids. A bare string is tolerated because that is what a
            // single-select column looks like after somebody changes its type.
            let ids = (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? [raw]
            return .options(options(ids: ids, in: context))

        case "number", "rollup":
            return .number(raw)

        default:
            return .text(raw)
        }
    }

    private static func options(ids: [String], in context: Context) -> [Option] {
        ids.compactMap { id in
            guard let option = context.options[id] else {
                // An id with no option behind it: the desktop drops these on read, and so does
                // this. Showing the raw id would be showing a UUID and calling it a value.
                return nil
            }
            return Option(id: id, label: option.text("label") ?? id, colour: option.text("color"))
        }
    }

    /// The icon beside a column's name, by type.
    static func icon(for type: String?) -> String {
        switch type {
        case "title": return "textformat.size"
        case "number": return "number"
        case "date": return "calendar"
        case "time": return "clock"
        case "checkbox": return "checkmark.square"
        case "select", "multi_select": return "tag"
        case "attachment": return "paperclip"
        case "ai": return "wand.and.stars"
        case "ai_image": return "photo"
        case "relation": return "link"
        case "rollup": return "sum"
        case "formula": return "function"
        case "comparison": return "scalemass"
        default: return "textformat"
        }
    }

    /// Whether an attachment row carries an image whose bytes reached the server.
    static func imageHash(_ attachment: Row, preferThumbnail: Bool = false) -> String? {
        if preferThumbnail, let thumb = attachment.string("thumbHash") { return thumb }
        return attachment.string("hash") ?? attachment.string("thumbHash")
    }
}

/// A select option as the desktop draws it: the label on its own colour.
///
/// `color` is a Tailwind-ish token or a hex string depending on when the option was made, so a
/// value that is not a colour falls back to the vault accent rather than to nothing.
struct DatabaseOptionChip: View {
    let option: DatabaseCell.Option
    let accent: Color

    var body: some View {
        Text(verbatim: option.label)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.22), in: Capsule())
            .foregroundStyle(tint)
    }

    private var tint: Color {
        guard let colour = option.colour, colour.hasPrefix("#") else { return accent }
        return Color(hex: colour)
    }
}
