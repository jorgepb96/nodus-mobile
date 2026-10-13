import Foundation

/// The Desktop property registry and canonical wire values. This describes edits;
/// formula evaluation, automation and extraction remain repository operations.
public enum CompanionDatabaseProperty: String, CaseIterable, Identifiable, Sendable {
    case title, rich_text, text, number, date, time, select, status, multi_select, checkbox, person, url, email, phone, location, files
    case created_by, last_edited_by, created_time, last_edited_time, unique_id, button, attachment, ai, ai_image, relation, rollup, formula, comparison
    public var id: String { rawValue }
    public var label: String {
        ["title":"Título", "rich_text":"Texto enriquecido", "text":"Texto (heredado)", "number":"Número", "date":"Fecha", "time":"Hora", "select":"Selección", "status":"Estado", "multi_select":"Selección múltiple", "checkbox":"Casilla", "person":"Persona o grupo", "url":"URL", "email":"Email", "phone":"Teléfono", "location":"Ubicación", "files":"Archivos", "created_by":"Creado por", "last_edited_by":"Editado por", "created_time":"Fecha de creación", "last_edited_time":"Última edición", "unique_id":"ID único", "button":"Botón", "attachment":"Adjunto", "ai":"IA", "ai_image":"Imagen IA", "relation":"Relación", "rollup":"Rollup", "formula":"Fórmula", "comparison":"Comparación"][rawValue]!
    }
    public var computed: Bool { [.created_by,.last_edited_by,.created_time,.last_edited_time,.unique_id,.rollup,.formula,.comparison].contains(self) }
    public var cellStorage: String {
        switch self {
        case .number: "number"
        case .checkbox: "integer"
        case .date: "date"
        case .select,.status,.relation: "reference"
        case .multi_select,.person,.location,.files,.attachment,.ai_image,.button: "json"
        default: "text"
        }
    }
    public static let rollupFunctions = ["show","show_unique","count","count_values","count_empty","count_unique","percent_empty","percent_not_empty","sum","average","median","min","max","range","earliest_date","latest_date","date_range","checked","unchecked","percent_checked","percent_unchecked"]
    public static func object(_ value: String) -> [String: JSONValue] {
        guard let data = value.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder.nodus.decode(JSONValue.self, from: data).objectValue) ?? [:]
    }
    public static func strings(_ value: String) -> [String] {
        guard let data = value.data(using: .utf8), let rows = try? JSONDecoder.nodus.decode([String].self, from: data) else { return [] }
        return rows
    }
    /// Preserve unknown structured fields when a single control changes a value.
    public static func patchObject(_ value: String, legacyKey: String? = nil, fields: [String: JSONValue]) throws -> String {
        var object = object(value)
        if object.isEmpty, let legacyKey, !value.isEmpty { object[legacyKey] = .string(value) }
        object.merge(fields) { _, new in new }
        return String(decoding: try JSONEncoder.nodus.encode(JSONValue.object(object)), as: UTF8.self)
    }
    public static func encodeStrings(_ values: [String]) throws -> String {
        var seen = Set<String>()
        return String(decoding: try JSONEncoder.nodus.encode(values.filter { !$0.isEmpty && seen.insert($0).inserted }), as: UTF8.self)
    }
    /// Existing unknown config belongs to the Desktop schema; editing one field
    /// must not drop it, a formula AST, metadata or an approved model reference.
    public static func configuration(_ original: [String: JSONValue], patch: [String: JSONValue]) throws -> String {
        var config = original; config.merge(patch) { _, new in new }
        return String(decoding: try JSONEncoder.nodus.encode(JSONValue.object(config)), as: UTF8.self)
    }
}
