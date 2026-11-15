import Foundation

/// Portable projections for Desktop's universal Pages and Notion-style databases.
///
/// The published mirror exposes the normalized SQLite rows. Keeping the projection here means
/// iPhone and iPad use the same hierarchy, typed-cell and formula rules, while mutations still
/// travel through the generated outbox contract and Desktop remains the canonical repository.
public enum PagesDatabasesParity {
    public struct Page: Identifiable, Sendable, Hashable {
        public let id: String
        public let parentId: String?
        public let title: String
        public let icon: String?
        public let origin: String
        public let state: String
        public let locked: Bool
        public let fullWidth: Bool
        public let revision: Int
        public let updatedAt: String?
        public let favorite: Bool
        public let depth: Int
    }

    public struct Block: Identifiable, Sendable, Hashable {
        public let id: String
        public let pageId: String
        public let parentId: String?
        public let order: Double
        public let type: String
        public let content: [String: JSONValue]
        public let text: String
        public let revision: Int
    }

    public struct Backlink: Identifiable, Sendable, Hashable {
        public let id: String
        public let sourcePageId: String
        public let targetPageId: String?
        public let label: String
        public let kind: String
        public let broken: Bool
    }

    public struct Database: Identifiable, Sendable, Hashable {
        public let id: String
        public let shortId: String
        public let name: String
        public let icon: String?
        public let position: Int
        public let rowCount: Int
        public let updatedAt: String?
    }

    public struct Column: Identifiable, Sendable, Hashable {
        public let id: String
        public let databaseId: String
        public let name: String
        public let type: String
        public let position: Int
        public let config: [String: JSONValue]
        public let options: [Option]

        public var isReadOnly: Bool {
            ["formula", "rollup", "comparison", "created_by", "last_edited_by", "created_time", "last_edited_time", "unique_id"].contains(type)
        }
    }

    public struct Option: Identifiable, Sendable, Hashable {
        public let id: String
        public let label: String
        public let color: String?
        public let position: Int
    }

    public struct DataRow: Identifiable, Sendable, Hashable {
        public let id: String
        public let databaseId: String
        public let position: Double
        public var cells: [String: String]
        public let revision: Int
        public let updatedAt: String?
        public var formulaErrors: [String: String] = [:]
        public var formulaColors: [String: String] = [:]
    }

    public struct SavedView: Identifiable, Sendable, Hashable {
        public let id: String
        public let databaseId: String
        public let name: String
        public let layout: String
        public let position: Int
        public let revision: Int
        public let config: [String: JSONValue]
    }

    public enum SortDirection: String, Sendable, Hashable, Codable { case ascending, descending }

    public static func visibleColumns(_ columns: [Column], config: [String: JSONValue]) -> [Column] {
        let properties = (config["properties"]?.arrayValue ?? []).compactMap(\.objectValue)
        var known: Set<String> = [], ordered: [(Int, Int, Column)] = []
        for (index, property) in properties.enumerated() {
            guard let id = property["columnId"]?.stringValue, known.insert(id).inserted,
                  let column = columns.first(where: { $0.id == id }) else { continue }
            if property["visible"] != .bool(false) { ordered.append((property["order"]?.intValue ?? index, index, column)) }
        }
        return ordered.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map { $0.2 } + columns.filter { !known.contains($0.id) }
    }
    public static func cardColumns(_ columns: [Column], config: [String: JSONValue]) -> [Column] {
        if let ids = config["cardPropertyIds"]?.arrayValue, !ids.isEmpty {
            return ids.compactMap(\.stringValue).compactMap { id in columns.first { $0.id == id } }
        }
        return visibleColumns(columns, config: config).filter { $0.type != "title" }
    }
    public static func layoutColumn(_ columns: [Column], config: [String: JSONValue], field: String, types: Set<String>, fallback: Bool = true) -> Column? {
        if let id = config[field]?.stringValue, let column = columns.first(where: { $0.id == id && types.contains($0.type) }) { return column }
        return fallback ? columns.first { types.contains($0.type) } : nil
    }

    public static func pages(in tables: [String: [Row]], includeTrashed: Bool = false) -> [Page] {
        let favorites = Set((tables["page_favorites"] ?? []).compactMap { $0.string("page_id") })
        let raw = (tables["pages"] ?? []).filter { includeTrashed || ($0.string("state") ?? "active") == "active" }
        let known = Set(raw.compactMap { $0.string("id") })
        let grouped = Dictionary(grouping: raw) { row -> String? in
            guard let parent = row.string("parent_page_id"), known.contains(parent) else { return nil }
            return parent
        }
        var result: [Page] = []
        var visited = Set<String>()

        func visit(_ row: Row, depth: Int, path: Set<String>) {
            guard let id = row.string("id"), !visited.contains(id), !path.contains(id) else { return }
            visited.insert(id)
            result.append(Page(
                id: id, parentId: row.string("parent_page_id"), title: row.text("title") ?? "Untitled page",
                icon: row.text("icon"), origin: row.string("origin") ?? "standalone",
                state: row.string("state") ?? "active", locked: row.bool("locked") == true,
                fullWidth: row.bool("full_width") == true, revision: row.int("revision") ?? 1,
                updatedAt: row.string("updated_at"), favorite: favorites.contains(id), depth: depth
            ))
            let nextPath = path.union([id])
            for child in (grouped[id] ?? []).sorted(by: pageOrder) { visit(child, depth: depth + 1, path: nextPath) }
        }

        for root in (grouped[nil] ?? []).sorted(by: pageOrder) { visit(root, depth: 0, path: []) }
        // Corrupt/cyclic ancestry must remain visible and repairable instead of disappearing.
        for orphan in raw.sorted(by: pageOrder) where orphan.string("id").map({ !visited.contains($0) }) == true {
            visit(orphan, depth: 0, path: [])
        }
        return result
    }

    public static func blocks(pageId: String, in tables: [String: [Row]]) -> [Block] {
        (tables["page_blocks"] ?? []).compactMap { row in
            guard row.string("page_id") == pageId, row.string("trashed_at") == nil,
                  let id = row.string("id") else { return nil }
            let content = row.embeddedJSON("content_json")?.objectValue ?? [:]
            let text = content["text"]?.stringValue ?? row.string("normalized_text") ?? ""
            return Block(
                id: id, pageId: pageId, parentId: row.string("parent_block_id"),
                order: row.double("sort_order") ?? 0, type: row.string("type") ?? "paragraph",
                content: content, text: text, revision: row.int("revision") ?? 1
            )
        }.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    public static func backlinks(pageId: String, in tables: [String: [Row]]) -> [Backlink] {
        let pageIds = Set((tables["pages"] ?? []).compactMap { $0.string("id") })
        let blockPage: [String: String] = Dictionary(uniqueKeysWithValues: (tables["page_blocks"] ?? []).compactMap { row -> (String, String)? in
            guard let id = row.string("id"), let pageId = row.string("page_id") else { return nil }
            return (id, pageId)
        })
        return (tables["page_links"] ?? []).compactMap { row in
            guard let resolved = row.string("target_page_id") ?? row.string("target_block_id").flatMap({ blockPage[$0] }),
                  resolved == pageId, let id = row.string("id"), let source = row.string("source_page_id") else { return nil }
            return Backlink(
                id: id, sourcePageId: source, targetPageId: resolved,
                label: row.text("label") ?? "Linked page", kind: row.string("kind") ?? "page",
                broken: !pageIds.contains(resolved)
            )
        }.sorted { ($0.label, $0.id) < ($1.label, $1.id) }
    }

    public static func databases(in tables: [String: [Row]]) -> [Database] {
        let counts = Dictionary(grouping: tables["db_rows"] ?? [], by: { $0.string("database_id") ?? "" }).mapValues(\.count)
        return (tables["db_databases"] ?? []).compactMap { row in
            guard let id = row.string("id") else { return nil }
            return Database(
                id: id, shortId: row.string("short_id") ?? id, name: row.text("name") ?? "Database",
                icon: row.text("icon"), position: row.int("position") ?? 0,
                rowCount: counts[id] ?? 0, updatedAt: row.string("updated_at")
            )
        }.sorted { ($0.position, $0.name, $0.id) < ($1.position, $1.name, $1.id) }
    }

    public static func columns(databaseId: String, in tables: [String: [Row]]) -> [Column] {
        let options = Dictionary(grouping: tables["db_select_options"] ?? [], by: { $0.string("column_id") ?? "" })
        return (tables["db_columns"] ?? []).compactMap { row in
            guard row.string("database_id") == databaseId, let id = row.string("id") else { return nil }
            let mappedOptions = (options[id] ?? []).compactMap { option -> Option? in
                guard let optionId = option.string("id") else { return nil }
                return Option(id: optionId, label: option.text("label") ?? optionId, color: option.string("color"), position: option.int("position") ?? 0)
            }.sorted { ($0.position, $0.label) < ($1.position, $1.label) }
            return Column(
                id: id, databaseId: databaseId, name: row.text("name") ?? "Property",
                type: row.string("type") ?? "text", position: row.int("position") ?? 0,
                config: row.embeddedJSON("config_json")?.objectValue ?? [:], options: mappedOptions
            )
        }.sorted { ($0.position, $0.name, $0.id) < ($1.position, $1.name, $1.id) }
    }

    public static func rows(databaseId: String, in tables: [String: [Row]]) -> [DataRow] {
        let rawRows = (tables["db_rows"] ?? []).filter { $0.string("database_id") == databaseId }
        var cellsByRow: [String: [String: String]] = [:]
        var errorsByRow: [String: [String: String]] = [:], colorsByRow: [String: [String: String]] = [:]
        for cell in (tables["db_cells"] ?? []) + (tables["db_computed_cells"] ?? []) where cell.string("database_id").map({ $0 == databaseId }) ?? true {
            guard let rowId = cell.string("row_id"), let columnId = cell.string("column_id") else { continue }
            if let value = rawCell(cell) { cellsByRow[rowId, default: [:]][columnId] = value }
            if let error = cell.string("error"), !error.isEmpty { errorsByRow[rowId, default: [:]][columnId] = error }
            if let color = cell.string("color"), !color.isEmpty { colorsByRow[rowId, default: [:]][columnId] = color }
        }
        return rawRows.compactMap { row in
            guard let id = row.string("id") else { return nil }
            var values = cellsByRow[id] ?? [:]
            for column in columns(databaseId: databaseId, in: tables) {
                switch column.type {
                case "created_time": if let stamp = row.string("created_at") { values[column.id] = stamp }
                case "last_edited_time": if let stamp = row.string("updated_at") { values[column.id] = stamp }
                case "created_by", "last_edited_by":
                    if let actor = row.string(column.type == "created_by" ? "created_by" : "updated_by"),
                       let data = try? JSONEncoder.nodus.encode(JSONValue.array([.object(["id": .string(actor), "label": .string(actor), "kind": .string("person")])])) { values[column.id] = String(decoding: data, as: UTF8.self) }
                case "unique_id":
                    if let sequence = row.int("unique_sequence") {
                        let prefix = String((column.config["uniqueIdPrefix"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
                        let padding = min(12, max(1, Int(column.config["uniqueIdPadding"]?.intValue ?? 4)))
                        values[column.id] = prefix + String(format: "%0*d", padding, max(0, sequence))
                    }
                default: break
                }
            }
            return DataRow(
                id: id, databaseId: databaseId, position: row.double("position") ?? 0,
                cells: values, revision: row.int("revision") ?? 1,
                updatedAt: row.string("updated_at"), formulaErrors: errorsByRow[id] ?? [:], formulaColors: colorsByRow[id] ?? [:]
            )
        }.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
    }

    public static func views(databaseId: String, in tables: [String: [Row]]) -> [SavedView] {
        (tables["db_views"] ?? []).compactMap { row in
            guard row.string("database_id") == databaseId, let id = row.string("id") else { return nil }
            let config = row.embeddedJSON("config_json")?.objectValue ?? [:]
            return SavedView(
                id: id, databaseId: databaseId, name: row.text("name") ?? "View",
                layout: row.string("layout") ?? config["layout"]?.stringValue ?? "table",
                position: row.int("position") ?? 0, revision: row.int("revision") ?? 1, config: config
            )
        }.sorted { ($0.position, $0.name) < ($1.position, $1.name) }
    }

    public static func displayValue(column: Column, row: DataRow, allRows: [DataRow], columns: [Column]) -> String {
        if let error = row.formulaErrors[column.id], !error.isEmpty { return error }
        if ["formula", "rollup"].contains(column.type) { return row.cells[column.id] ?? "" }
        let raw = row.cells[column.id] ?? ""
        if let display=DatabaseCardPresentation.structuredValue(type:column.type,raw:raw) { return display }
        switch column.type {
        case "checkbox": return ["1", "true", "yes"].contains(raw.lowercased()) ? "Yes" : "No"
        case "select", "status": return column.options.first(where: { $0.id == raw })?.label ?? raw
        case "multi_select":
            let ids = jsonStrings(raw) ?? raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return ids.map { id in column.options.first(where: { $0.id == id })?.label ?? id }.joined(separator: ", ")
        default: return raw
        }
    }

    public static func filteredRows(
        _ rows: [DataRow], columns: [Column], query: String,
        sortColumnId: String? = nil, direction: SortDirection = .ascending
    ) -> [DataRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = needle.isEmpty ? rows : rows.filter { row in
            columns.contains { displayValue(column: $0, row: row, allRows: rows, columns: columns).localizedCaseInsensitiveContains(needle) }
        }
        if let sortColumnId, let column = columns.first(where: { $0.id == sortColumnId }) {
            result.sort { lhs, rhs in
                let left = displayValue(column: column, row: lhs, allRows: rows, columns: columns)
                let right = displayValue(column: column, row: rhs, allRows: rows, columns: columns)
                let order: Bool
                if let a = Double(left), let b = Double(right) { order = a == b ? lhs.id < rhs.id : a < b }
                else { order = left == right ? lhs.id < rhs.id : left.localizedStandardCompare(right) == .orderedAscending }
                return direction == .ascending ? order : !order
            }
        }
        return result
    }

    /// Desktop formulas are structured recipes, not executable text. This portable evaluator
    /// implements the deterministic arithmetic, column-stat and concatenation recipes; advanced
    /// expression/relations remain materialized by Desktop in the published cell projection.
    public static func formulaValue(
        spec: [String: JSONValue], row: DataRow, allRows: [DataRow], columns: [Column]
    ) -> String? {
        let byId = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, $0) })
        func number(_ operand: [String: JSONValue]) -> Double? {
            if operand["kind"]?.stringValue == "number" { return operand["value"]?.doubleValue }
            guard let id = operand["columnId"]?.stringValue else { return nil }
            return Double(row.cells[id] ?? "")
        }
        switch spec["kind"]?.stringValue {
        case "arithmetic":
            let values = (spec["operands"]?.arrayValue ?? []).compactMap { $0.objectValue }.map(number)
            let op = spec["op"]?.stringValue ?? "add"
            if op == "countFilled" { return String(values.compactMap { $0 }.count) }
            if ["subtract", "divide"].contains(op), values.contains(where: { $0 == nil }) { return nil }
            let nums = values.compactMap { $0 }; guard !nums.isEmpty else { return nil }
            let result: Double?
            switch op {
            case "add": result = nums.reduce(0, +)
            case "subtract": result = nums.dropFirst().reduce(nums[0], -)
            case "multiply": result = nums.reduce(1, *)
            case "divide": result = nums.dropFirst().reduce(nums[0]) { value, divisor in divisor == 0 ? .nan : value / divisor }
            case "average": result = nums.reduce(0, +) / Double(nums.count)
            case "min": result = nums.min()
            case "max": result = nums.max()
            case "median":
                let sorted = nums.sorted(), middle = sorted.count / 2
                result = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
            default: result = nil
            }
            return result.flatMap(formatNumber)
        case "columnStat":
            guard let columnId = spec["columnId"]?.stringValue, byId[columnId] != nil else { return nil }
            let values = allRows.compactMap { Double($0.cells[columnId] ?? "") }.sorted()
            guard !values.isEmpty else { return nil }
            let current = Double(row.cells[columnId] ?? "")
            let total = values.reduce(0, +), mean = total / Double(values.count)
            let result: Double?
            switch spec["fn"]?.stringValue {
            case "columnTotal": result = total
            case "columnMean": result = mean
            case "percentOfTotal": result = current.flatMap { total == 0 ? nil : ($0 / total) * 100 }
            case "diffFromMean": result = current.map { $0 - mean }
            case "rank": result = current.map { value in Double(values.filter { $0 > value }.count + 1) }
            case "percentile": result = current.map { value in Double(values.filter { $0 < value }.count) / Double(values.count) * 100 }
            default: result = nil
            }
            return result.flatMap(formatNumber)
        case "concat":
            let parts = (spec["parts"]?.arrayValue ?? []).compactMap { $0.objectValue }
            let value = parts.map { part -> String in
                if part["kind"]?.stringValue == "text" { return part["value"]?.stringValue ?? "" }
                guard let id = part["columnId"]?.stringValue else { return "" }
                return row.cells[id] ?? ""
            }.joined()
            return value.isEmpty ? nil : value
        default: return row.cells[columns.first(where: { $0.type == "formula" })?.id ?? ""]
        }
    }

    private static func pageOrder(_ lhs: Row, _ rhs: Row) -> Bool {
        let leftFavorite = lhs.bool("favorite") == true ? 0 : 1
        let rightFavorite = rhs.bool("favorite") == true ? 0 : 1
        return (leftFavorite, lhs.string("updated_at") ?? "", lhs.string("id") ?? "")
            < (rightFavorite, rhs.string("updated_at") ?? "", rhs.string("id") ?? "")
    }

    private static func rawCell(_ row: Row) -> String? {
        for key in ["value_text", "value_date", "value_json", "value_reference", "value_number", "value_integer"] {
            if let value = row.string(key), !value.isEmpty { return value }
        }
        return nil
    }

    private static func jsonStrings(_ raw: String) -> [String]? {
        guard let data = raw.data(using: .utf8), let values = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return values
    }

    private static func formatNumber(_ value: Double) -> String? {
        guard value.isFinite else { return nil }
        let clean = (value * 10_000_000_000).rounded() / 10_000_000_000
        return clean.rounded() == clean ? String(Int(clean)) : String(clean)
    }
}
