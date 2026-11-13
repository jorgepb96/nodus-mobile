import NodusKit
import NodusAI
import SwiftUI

struct DatabasePropertyConfigurationFields: View {
    let type: String
    let databaseId: String
    let columnId: String?
    let tables: [String: [Row]]
    @Binding var config: [String: JSONValue]
    private var columns: [PagesDatabasesParity.Column] { PagesDatabasesParity.columns(databaseId: databaseId, in: tables).filter { $0.id != columnId } }
    private func text(_ key: String, _ fallback: String = "") -> Binding<String> {
        Binding(get: { config[key]?.stringValue ?? fallback }, set: { config[key] = .string($0) })
    }
    private func flag(_ key: String) -> Binding<Bool> { Binding(get: { config[key]?.boolValue ?? false }, set: { config[key] = .bool($0) }) }
    private func integer(_ key: String, _ fallback: Int) -> Binding<Int> { Binding(get: { config[key]?.intValue ?? fallback }, set: { config[key] = .int(Int64($0)) }) }
    private func decimal(_ key: String, _ fallback: Double) -> Binding<Double> { Binding(get: { config[key]?.doubleValue ?? fallback }, set: { config[key] = .double($0) }) }
    private func choices(_ title: String, key: String, values: [String], fallback: String) -> some View {
        Picker(title, selection: text(key, fallback)) { ForEach(values, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) } }
    }
    private func columnPicker(_ title: String, key: String, values: [PagesDatabasesParity.Column], titleTarget: Bool = false) -> some View {
        Picker(title, selection: text(key)) {
            Text("Sin seleccionar").tag("")
            if titleTarget { Text("Título de la fila").tag("__title__") }
            ForEach(values) { Text($0.name).tag($0.id) }
        }
    }
    @ViewBuilder var body: some View {
        switch type {
        case "number": numberFields
        case "date":
            Toggle("Incluir hora", isOn: flag("dateIncludeTime"))
            TextField("Zona horaria", text: text("dateTimeZone", TimeZone.current.identifier)).autocorrectionDisabled()
        case "unique_id":
            TextField("Prefijo", text: text("uniqueIdPrefix"))
            Stepper("Dígitos: \(integer("uniqueIdPadding", 4).wrappedValue)", value: integer("uniqueIdPadding", 4), in: 1...12)
        case "button":
            TextField("Etiqueta del botón", text: text("buttonLabel", "Ejecutar"))
            TextField("Color", text: text("buttonColor", "#4f46e5")).autocorrectionDisabled()
        case "relation": relationFields
        case "rollup": rollupFields
        case "comparison": comparisonFields
        case "formula": DatabaseFormulaConfigurationFields(columns: columns, config: $config)
        case "ai", "ai_image":
            TextField("Instrucciones", text: text("aiPrompt"), axis: .vertical).lineLimit(3...10)
            Toggle("Actualizar automáticamente", isOn: flag("aiAuto"))
            columnPicker("Archivo de contexto", key: "aiSourceColumnId", values: columns.filter { ["files", "attachment"].contains($0.type) })
        default: EmptyView()
        }
    }
    private var numberFields: some View {
        Group {
            choices("Formato", key: "numberFormat", values: ["plain","integer","decimal","currency","percent","progress"], fallback: "plain")
            if config["numberFormat"] == .string("currency") { TextField("Moneda", text: text("numberCurrency", "EUR")).textInputAutocapitalization(.characters) }
            if config["numberFormat"] == .string("progress") { TextField("Valor máximo", value: decimal("progressMaximum", 100), format: .number).keyboardType(.decimalPad) }
            Stepper("Decimales: \(integer("numberDecimals", 2).wrappedValue)", value: integer("numberDecimals", 2), in: 0...8)
        }
    }
    private var relationFields: some View {
        Group {
            choices("Relacionar con", key: "relationTargetKind", values: ["db_row","work","idea","gap","author","person"], fallback: "db_row")
            if (config["relationTargetKind"]?.stringValue ?? "db_row") == "db_row" {
                Picker("Base de datos de destino", selection: text("relationTargetDatabaseId")) {
                    Text("Sin seleccionar").tag("")
                    ForEach(PagesDatabasesParity.databases(in: tables)) { Text($0.name).tag($0.id) }
                }
                choices("Cardinalidad", key: "relationCardinality", values: ["one","many"], fallback: "many")
                let target = config["relationTargetDatabaseId"]?.stringValue ?? ""
                columnPicker("Propiedad inversa", key: "relationInverseColumnId", values: PagesDatabasesParity.columns(databaseId: target, in: tables).filter { $0.type == "relation" && $0.id != columnId })
            }
        }
    }
    private var rollupFields: some View {
        Group {
            let relations = columns.filter { $0.type == "relation" && $0.config["relationTargetKind"] == .string("db_row") }
            columnPicker("Relación", key: "rollupRelationColumnId", values: relations)
            let relation = relations.first { $0.id == config["rollupRelationColumnId"]?.stringValue }
            let target = relation?.config["relationTargetDatabaseId"]?.stringValue ?? ""
            columnPicker("Propiedad de destino", key: "rollupTargetColumnId", values: PagesDatabasesParity.columns(databaseId: target, in: tables), titleTarget: true)
            choices("Agregación", key: "rollupFunction", values: CompanionDatabaseProperty.rollupFunctions, fallback: "show")
        }
    }
    private var comparisonFields: some View {
        ForEach(columns) { column in
            Toggle(column.name, isOn: Binding(get: { config["comparisonSourceColumnIds"]?.arrayValue?.contains(.string(column.id)) == true }, set: { enabled in
                var values = config["comparisonSourceColumnIds"]?.arrayValue ?? []
                values.removeAll { $0 == .string(column.id) }; if enabled { values.append(.string(column.id)) }
                config["comparisonSourceColumnIds"] = .array(values)
            }))
        }
    }
}

private struct DatabaseFormulaConfigurationFields: View {
    let columns: [PagesDatabasesParity.Column]
    @Binding var config: [String: JSONValue]
    private var formula: Binding<[String: JSONValue]> {
        Binding(get: { config["formula"]?.objectValue ?? ["kind": .string("arithmetic"), "op": .string("add"), "operands": .array([])] }, set: { config["formula"] = .object($0) })
    }
    private func text(_ key: String, _ fallback: String = "") -> Binding<String> { Binding(get: { formula.wrappedValue[key]?.stringValue ?? fallback }, set: { formula.wrappedValue[key] = .string($0) }) }
    private func rows(_ key: String) -> Binding<[JSONValue]> { Binding(get: { formula.wrappedValue[key]?.arrayValue ?? [] }, set: { formula.wrappedValue[key] = .array($0) }) }
    var body: some View {
        Group {
            Picker("Receta", selection: Binding(get: { text("kind", "arithmetic").wrappedValue }, set: { kind in
                switch kind {
                case "arithmetic": formula.wrappedValue = ["kind": .string(kind), "op": .string("add"), "operands": .array([])]
                case "columnStat": formula.wrappedValue = ["kind": .string(kind), "fn": .string("columnTotal"), "columnId": .string("")]
                case "concat": formula.wrappedValue = ["kind": .string(kind), "parts": .array([])]
                case "ifThen": formula.wrappedValue = ["kind": .string(kind), "rules": .array([]), "otherwise": .object(["kind": .string("empty")])]
                default: formula.wrappedValue = ["kind": .string("expression"), "source": .string("")]
                }
            })) {
                Text("Operación").tag("arithmetic"); Text("Estadística de columna").tag("columnStat"); Text("Si… entonces…").tag("ifThen"); Text("Texto combinado").tag("concat"); Text("Fórmula avanzada").tag("expression")
            }
            recipeFields
            Stepper("Decimales: \(Int(config["formulaDecimals"]?.intValue ?? 2))", value: Binding(get: { Int(config["formulaDecimals"]?.intValue ?? 2) }, set: { config["formulaDecimals"] = .int(Int64($0)) }), in: 0...8)
        }
    }
    @ViewBuilder private var recipeFields: some View {
        switch text("kind", "arithmetic").wrappedValue {
        case "arithmetic":
            Picker("Operación", selection: text("op", "add")) { ForEach(["add","subtract","multiply","divide","average","min","max","median","countFilled"], id: \.self) { Text($0.capitalized).tag($0) } }
            FormulaPartsFields(columns: columns, values: rows("operands"), textParts: false)
        case "columnStat":
            Picker("Estadística", selection: text("fn", "columnTotal")) { ForEach(["percentOfTotal","rank","diffFromMean","percentile","columnTotal","columnMean"], id: \.self) { Text($0).tag($0) } }
            Picker("Propiedad", selection: text("columnId")) { Text("Sin seleccionar").tag(""); ForEach(columns) { Text($0.name).tag($0.id) } }
        case "concat": FormulaPartsFields(columns: columns, values: rows("parts"), textParts: true)
        case "ifThen":
            let rules = rows("rules")
            ForEach(rules.wrappedValue.indices, id: \.self) { index in
                DatabaseFormulaRuleFields(columns: columns, rule: Binding(get: { rules.wrappedValue[index].objectValue ?? [:] }, set: { rules.wrappedValue[index] = .object($0) }))
                Button("Eliminar regla", role: .destructive) { rules.wrappedValue.remove(at: index) }
            }
            Button("Añadir regla") { rules.wrappedValue.append(.object(["id": .string(UUID().uuidString), "conjunction": .string("and"), "conditions": .array([]), "output": .object(["kind": .string("text"), "value": .string("")])])) }
            FormulaOutputFields(title: "Si ninguna regla coincide", columns: columns, value: Binding(get: { formula.wrappedValue["otherwise"]?.objectValue ?? ["kind": .string("empty")] }, set: { formula.wrappedValue["otherwise"] = .object($0) }))
        default:
            TextField("Expresión", text: text("source"), axis: .vertical).lineLimit(3...10).autocorrectionDisabled().textInputAutocapitalization(.never)
            Menu("Insertar propiedad") { ForEach(columns) { column in Button(column.name) { if let literal = try? JSONEncoder.nodus.encode(column.id) { text("source").wrappedValue += "property(" + String(decoding: literal, as: UTF8.self) + ")" } } } }
            Text("Usa property(\"id de la columna\") y funciones de fecha, texto o listas. Nodus valida y calcula la expresión al sincronizar.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct FormulaPartsFields: View {
    let columns: [PagesDatabasesParity.Column]
    @Binding var values: [JSONValue]
    let textParts: Bool
    var body: some View {
        ForEach(values.indices, id: \.self) { index in
            let item = values[index].objectValue ?? [:]
            Picker("Origen", selection: Binding(get: { item["kind"]?.stringValue ?? "column" }, set: { kind in values[index] = .object(kind == "column" ? ["kind": .string(kind), "columnId": .string("")] : ["kind": .string(kind), "value": textParts ? .string("") : .double(0)]) })) {
                Text("Propiedad").tag("column"); Text(textParts ? "Texto" : "Número").tag(textParts ? "text" : "number")
            }
            if item["kind"] == .string("column") {
                Picker("Propiedad", selection: Binding(get: { item["columnId"]?.stringValue ?? "" }, set: { value in var copy = item; copy["columnId"] = .string(value); values[index] = .object(copy) })) { Text("Sin seleccionar").tag(""); ForEach(columns) { Text($0.name).tag($0.id) } }
            } else if textParts {
                TextField("Texto", text: Binding(get: { item["value"]?.stringValue ?? "" }, set: { value in var copy = item; copy["value"] = .string(value); values[index] = .object(copy) }))
            } else {
                TextField("Número", value: Binding(get: { item["value"]?.doubleValue ?? 0 }, set: { value in var copy = item; copy["value"] = .double(value); values[index] = .object(copy) }), format: .number).keyboardType(.numbersAndPunctuation)
            }
            Button("Eliminar término", role: .destructive) { values.remove(at: index) }
        }
        Button("Añadir término") { values.append(.object(["kind": .string("column"), "columnId": .string("")])) }
    }
}

private struct FormulaOutputFields: View {
    let title: String
    let columns: [PagesDatabasesParity.Column]
    @Binding var value: [String: JSONValue]
    var body: some View {
        Picker(title, selection: Binding(get: { value["kind"]?.stringValue ?? "empty" }, set: { kind in value = ["kind": .string(kind)]; if kind == "text" { value["value"] = .string("") }; if kind == "number" { value["value"] = .double(0) }; if kind == "column" { value["columnId"] = .string("") } })) { Text("Vacío").tag("empty"); Text("Texto").tag("text"); Text("Número").tag("number"); Text("Propiedad").tag("column") }
        if value["kind"] == .string("text") { TextField("Resultado", text: Binding(get: { value["value"]?.stringValue ?? "" }, set: { value["value"] = .string($0) })) }
        if value["kind"] == .string("number") { TextField("Resultado", value: Binding(get: { value["value"]?.doubleValue ?? 0 }, set: { value["value"] = .double($0) }), format: .number).keyboardType(.numbersAndPunctuation) }
        if value["kind"] == .string("column") { Picker("Resultado", selection: Binding(get: { value["columnId"]?.stringValue ?? "" }, set: { value["columnId"] = .string($0) })) { Text("Sin seleccionar").tag(""); ForEach(columns) { Text($0.name).tag($0.id) } } }
    }
}

private struct DatabaseFormulaRuleFields: View {
    let columns: [PagesDatabasesParity.Column]
    @Binding var rule: [String: JSONValue]
    private var conditions: Binding<[JSONValue]> { Binding(get: { rule["conditions"]?.arrayValue ?? [] }, set: { rule["conditions"] = .array($0) }) }
    var body: some View {
        Picker("Coincidencia", selection: Binding(get: { rule["conjunction"]?.stringValue ?? "and" }, set: { rule["conjunction"] = .string($0) })) { Text("Todas las condiciones").tag("and"); Text("Cualquier condición").tag("or") }
        ForEach(conditions.wrappedValue.indices, id: \.self) { index in
            let condition = conditions.wrappedValue[index].objectValue ?? [:]
            Picker("Propiedad", selection: field("columnId", index: index)) { Text("Sin seleccionar").tag(""); ForEach(columns) { Text($0.name).tag($0.id) } }
            Picker("Condición", selection: field("op", index: index)) { ForEach(["contains","notContains","equals","notEquals","isEmpty","notEmpty","gt","gte","lt","lte","before","after","isAnyOf","isNoneOf","hasAllOf","isChecked","isUnchecked"], id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) } }
            if ["isAnyOf","isNoneOf","hasAllOf"].contains(condition["op"]?.stringValue ?? ""), let column = columns.first(where: { $0.id == condition["columnId"]?.stringValue }) {
                ForEach(column.options) { option in
                    Toggle(option.label, isOn: Binding(get: { conditions.wrappedValue[index].objectValue?["value"]?.arrayValue?.contains(.string(option.id)) == true }, set: { enabled in
                        var copy = conditions.wrappedValue[index].objectValue ?? [:]; var values = copy["value"]?.arrayValue ?? []; values.removeAll { $0 == .string(option.id) }; if enabled { values.append(.string(option.id)) }; copy["value"] = .array(values); conditions.wrappedValue[index] = .object(copy)
                    }))
                }
            } else if !["isEmpty","notEmpty","isChecked","isUnchecked"].contains(condition["op"]?.stringValue ?? "") { TextField("Valor", text: field("value", index: index)) }
            Button("Eliminar condición", role: .destructive) { conditions.wrappedValue.remove(at: index) }
        }
        Button("Añadir condición") { conditions.wrappedValue.append(.object(["columnId": .string(""), "id": .string(UUID().uuidString), "op": .string("equals"), "value": .string("")])) }
        FormulaOutputFields(title: "Entonces", columns: columns, value: Binding(get: { rule["output"]?.objectValue ?? ["kind": .string("empty")] }, set: { rule["output"] = .object($0) }))
        TextField("Color (opcional)", text: Binding(get: { rule["color"]?.stringValue ?? "" }, set: { rule["color"] = $0.isEmpty ? .null : .string($0) }))
    }
    private func field(_ key: String, index: Int) -> Binding<String> { Binding(get: { conditions.wrappedValue[index].objectValue?[key]?.stringValue ?? "" }, set: { text in var copy = conditions.wrappedValue[index].objectValue ?? [:]; copy[key] = .string(text); conditions.wrappedValue[index] = .object(copy) }) }
}

/// Model names are metadata. Provider credentials never enter a property mutation.
struct DatabasePropertyModelFields: View {
    @Environment(AISettings.self) private var ai
    let session: SpaceSession
    let image: Bool
    @Binding var config: [String: JSONValue]
    @State private var models: [JSONValue] = []
    @State private var providers: [NativeLiveChatOptions.Named] = []
    @State private var provider = ""
    @State private var issue: String?
    @State private var loading = false
    @State private var requestIdentity = UUID()
    private var modelKey: String { image ? "aiImageModel" : "aiModel" }
    private func key(_ value: JSONValue) -> String { (value.objectValue?["provider"]?.stringValue ?? "") + "::" + (value.objectValue?["model"]?.stringValue ?? "") }
    var body: some View {
        Section("Modelo") {
            if !providers.isEmpty {
                Picker("Proveedor", selection: $provider) { Text("Seleccionar").tag(""); ForEach(providers) { Text($0.name).tag($0.id) } }
            }
            Picker("Modelo", selection: Binding(get: { config[modelKey].map(key) ?? "" }, set: { selected in config[modelKey] = selected.isEmpty ? .null : models.first { key($0) == selected } })) {
                Text("Modelo configurado en Nodus").tag("")
                if let current = config[modelKey], current != .null, !models.contains(current) { Text(current.objectValue?["model"]?.stringValue ?? "Modelo guardado").tag(key(current)) }
                ForEach(models, id: \.self) { value in Text((value.objectValue?["model"]?.stringValue ?? "") + " · " + (value.objectValue?["provider"]?.stringValue ?? "")).tag(key(value)) }
            }
            if loading { ProgressView() }
            if let issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
        }.task(id: "\(image)|\(provider)|\(session.aiExecutionMode)") { await load() }
    }
    private func load() async {
        let identity = UUID(); requestIdentity = identity; let selectedProvider = provider
        loading = true; defer { if requestIdentity == identity { loading = false } }
        do {
            if session.aiExecutionMode == .autonomous {
                if image {
                    providers = AIProvider.allCases.filter { $0.supportsImageGeneration && ai.hasKey(for: $0) }.map { .init(id: $0.rawValue, name: $0.label) }
                    if let selected = AIProvider(rawValue: selectedProvider), selected.supportsImageGeneration, ai.hasKey(for: selected) {
                        let rows = try await ModelCatalogue(keyProvider: ai.keyProvider).imageModels(for: selected)
                        try Task.checkCancellation(); guard requestIdentity == identity else { return }
                        models = rows.map { .object(["provider": .string(selectedProvider == "gemini" ? "google" : selectedProvider), "model": .string($0)]) }
                    } else if let model = try ai.model(for: .image) { models = [.object(["provider": .string(model.provider == .gemini ? "google" : model.provider.rawValue), "model": .string(model.model)])] }
                } else {
                    providers = NodusAI.AIProvider.allCases.filter { ai.hasKey(for: $0) }.map { .init(id: $0.rawValue, name: $0.rawValue) }
                    if !selectedProvider.isEmpty {
                        let value = try await AutonomousSurfaceProvider(settings: ai).models(selectedProvider, includeStatus: true)
                        try Task.checkCancellation(); guard requestIdentity == identity else { return }
                        models = (value.objectValue?["selectableModels"]?.arrayValue ?? []).compactMap { $0.objectValue?["id"]?.stringValue }.map { .object(["provider": .string(selectedProvider), "model": .string($0)]) }
                    }
                }
            } else if image {
                let (vault, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
                let values = try await DesktopBridgeClient(pairing: pairing, token: token).operation(vaultId: vault, method: "listImageModels", args: [])
                try Task.checkCancellation(); guard requestIdentity == identity else { return }
                models = (values.arrayValue ?? []).compactMap { value in guard let fields = value.objectValue, let provider = fields["provider"]?.stringValue, let id = fields["id"]?.stringValue else { return nil }; return .object(["provider": .string(provider), "model": .string(id)]) }
            } else {
                let options = NativeLiveChatOptions(spaceId: session.connection.storageId)
                await options.load(session: session)
                try Task.checkCancellation()
                providers = options.providers
                if !selectedProvider.isEmpty { await options.catalogue(provider: selectedProvider, session: session); try Task.checkCancellation() }
                guard requestIdentity == identity else { return }
                models = options.models; issue = options.issue
            }
        } catch where error.isCancellation { return }
        catch { if requestIdentity == identity { issue = error.localizedDescription } }
    }
}

struct DatabasePropertyCellEditor: View {
    let column: PagesDatabasesParity.Column
    @Binding var value: String
    @State private var newPerson = ""
    @State private var newKind = "person"
    private func objectText(_ key: String, legacy: String? = nil) -> Binding<String> {
        Binding(get: { CompanionDatabaseProperty.object(value)[key]?.stringValue ?? (CompanionDatabaseProperty.object(value).isEmpty && legacy == key ? value : "") }, set: { text in
            if let encoded = try? CompanionDatabaseProperty.patchObject(value, legacyKey: legacy, fields: [key: text.isEmpty ? .null : .string(text)]) { value = encoded }
        })
    }
    @ViewBuilder var body: some View {
        switch column.type {
        case "select", "status":
            Picker(column.name, selection: $value) { Text("Sin valor").tag(""); ForEach(column.options) { Text($0.label).tag($0.id) } }.pickerStyle(.menu).frame(minHeight: 44)
        case "multi_select":
            ForEach(column.options) { option in Toggle(option.label, isOn: Binding(get: { CompanionDatabaseProperty.strings(value).contains(option.id) }, set: { enabled in
                var ids = CompanionDatabaseProperty.strings(value); ids.removeAll { $0 == option.id }; if enabled { ids.append(option.id) }; value = (try? CompanionDatabaseProperty.encodeStrings(ids)) ?? value
            })).frame(minHeight: 44) }
        case "checkbox": Toggle("Marcada", isOn: Binding(get: { ["1","true"].contains(value.lowercased()) }, set: { value = $0 ? "1" : "0" })).frame(minHeight: 44)
        case "date": DatabaseDatePropertyEditor(column: column, value: $value)
        case "time":
            DatePicker("Hora", selection: Binding(get: { let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"; return formatter.date(from: value) ?? Date() }, set: { date in let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"; value = formatter.string(from: date) }), displayedComponents: .hourAndMinute).frame(minHeight: 44)
            if value.isEmpty { Text("Sin valor").font(.caption).foregroundStyle(.secondary) }
            Button("Quitar hora") { value = "" }
        case "person": peopleFields
        case "location":
            TextField("Lugar", text: objectText("name", legacy: "name"), axis: .vertical).textFieldStyle(.roundedBorder).accessibilityLabel("Lugar")
            TextField("Dirección", text: objectText("address", legacy: "name"), axis: .vertical).textFieldStyle(.roundedBorder).accessibilityLabel("Dirección")
            coordinate("Latitud", key: "latitude", range: -90...90)
            coordinate("Longitud", key: "longitude", range: -180...180)
        default:
            TextField(column.name, text: $value, axis: .vertical).textFieldStyle(.roundedBorder)
                .keyboardType(column.type == "number" ? .numbersAndPunctuation : column.type == "email" ? .emailAddress : column.type == "url" ? .URL : column.type == "phone" ? .phonePad : .default)
                .autocorrectionDisabled(["email","url","phone","number"].contains(column.type))
                .textInputAutocapitalization(["email","url"].contains(column.type) ? .never : .sentences)
                // The visible column name sits beside the field, so VoiceOver had only the
                // stored value to announce. Name the control itself for the property it edits.
                .accessibilityLabel(column.name)
        }
    }
    private var people: [JSONValue] {
        if let data = value.data(using: .utf8), let entries = try? JSONDecoder.nodus.decode([JSONValue].self, from: data) { return entries }
        return value.isEmpty ? [] : [.object(["id": .string("person:" + value.lowercased()), "label": .string(value), "kind": .string("person")])]
    }
    private var peopleFields: some View {
        Group {
            ForEach(people.indices, id: \.self) { index in
                let person = people[index].objectValue ?? [:]
                Label(person["label"]?.stringValue ?? "", systemImage: person["kind"] == .string("group") ? "person.2" : "person")
                Button("Quitar", role: .destructive) { var entries = people; entries.remove(at: index); writePeople(entries) }
            }
            TextField("Nombre", text: $newPerson).accessibilityLabel("Nombre")
            Picker("Tipo", selection: $newKind) { Text("Persona").tag("person"); Text("Grupo").tag("group") }.pickerStyle(.segmented).accessibilityLabel("Tipo")
            Button("Añadir") {
                let label = newPerson.trimmingCharacters(in: .whitespacesAndNewlines), id = newKind + ":" + newPerson.lowercased()
                var entries = people; entries.removeAll { $0.objectValue?["id"] == .string(id) && $0.objectValue?["kind"] == .string(newKind) }
                entries.append(.object(["id": .string(id), "label": .string(label), "kind": .string(newKind)])); writePeople(entries); newPerson = ""
            }.disabled(newPerson.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    private func writePeople(_ entries: [JSONValue]) { if let data = try? JSONEncoder.nodus.encode(entries) { value = entries.isEmpty ? "" : String(decoding: data, as: UTF8.self) } }
    private func coordinate(_ title: String, key: String, range: ClosedRange<Double>) -> some View {
        TextField(title, text: Binding(get: { CompanionDatabaseProperty.object(value)[key]?.doubleValue.map { String($0) } ?? "" }, set: { text in
            let number = Double(text); let scalar: JSONValue = number.map { $0.isFinite && range.contains($0) ? .double($0) : .null } ?? .null
            if let encoded = try? CompanionDatabaseProperty.patchObject(value, legacyKey: "name", fields: [key: scalar]) { value = encoded }
        })).keyboardType(.numbersAndPunctuation).textFieldStyle(.roundedBorder).accessibilityLabel(title)
    }
}

private struct DatabaseDatePropertyEditor: View {
    let column: PagesDatabasesParity.Column
    @Binding var value: String
    private var object: [String: JSONValue] { let stored = CompanionDatabaseProperty.object(value); return stored.isEmpty && !value.isEmpty ? ["start": .string(value), "includeTime": .bool(value.contains("T"))] : stored }
    private var includeTime: Bool { object["includeTime"]?.boolValue ?? column.config["dateIncludeTime"]?.boolValue ?? false }
    private func patch(_ fields: [String: JSONValue]) { if let encoded = try? CompanionDatabaseProperty.patchObject(value, legacyKey: "start", fields: fields) { value = encoded } }
    private func date(_ key: String) -> Binding<Date> {
        Binding(get: { let raw = object[key]?.stringValue ?? ""; let formatter = ISO8601DateFormatter(); if let parsed = formatter.date(from: raw) { return parsed }; let simple = DateFormatter(); simple.dateFormat = "yyyy-MM-dd"; simple.locale = Locale(identifier: "en_US_POSIX"); return simple.date(from: raw) ?? Date() }, set: { date in
            let raw: String
            if includeTime { raw = ISO8601DateFormatter().string(from: date) }
            else { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; raw = formatter.string(from: date) }
            patch([key: .string(raw), "includeTime": .bool(includeTime)])
        })
    }
    var body: some View {
        Group {
            DatePicker("Inicio", selection: date("start"), displayedComponents: includeTime ? [.date,.hourAndMinute] : [.date]).frame(minHeight: 44)
            if value.isEmpty { Button("Establecer fecha") { date("start").wrappedValue = Date() } }
            Toggle("Incluir hora", isOn: Binding(get: { includeTime }, set: { patch(["includeTime": .bool($0)]) }))
            Toggle("Fecha final", isOn: Binding(get: { object["end"]?.stringValue?.isEmpty == false }, set: { enabled in if enabled { date("end").wrappedValue = date("start").wrappedValue } else { patch(["end": .null]) } }))
            if object["end"]?.stringValue?.isEmpty == false { DatePicker("Fin", selection: date("end"), displayedComponents: includeTime ? [.date,.hourAndMinute] : [.date]).frame(minHeight: 44) }
            TextField("Zona horaria", text: Binding(get: { object["timeZone"]?.stringValue ?? column.config["dateTimeZone"]?.stringValue ?? "" }, set: { patch(["timeZone": $0.isEmpty ? .null : .string($0)]) })).autocorrectionDisabled()
            TextField("Recordatorio (minutos)", text: Binding(get: { object["reminderMinutes"]?.doubleValue.map { String(Int($0)) } ?? "" }, set: { text in patch(["reminderMinutes": Int64(text).map { $0 >= 0 ? .int($0) : .null } ?? .null]) })).keyboardType(.numberPad)
            Picker("Repetir", selection: Binding(get: { object["recurrence"]?.stringValue ?? "" }, set: { patch(["recurrence": $0.isEmpty ? .null : .string($0)]) })) { Text("No repetir").tag(""); Text("Diariamente").tag("daily"); Text("Semanalmente").tag("weekly"); Text("Mensualmente").tag("monthly"); Text("Anualmente").tag("yearly") }
            Button("Quitar fecha", role: .destructive) { value = "" }
        }
    }
}

struct DatabasePropertyActionControls: View {
    @Environment(AISettings.self) private var ai
    let session: SpaceSession
    let rowId: String
    let column: PagesDatabasesParity.Column
    @State private var busy = false
    @State private var message: String?
    @State private var failure: String?
    @State private var jobsOpen = false
    private var kind: String { column.type == "button" ? "button" : column.type == "ai_image" ? "image" : "text" }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await run() }
            } label: {
                HStack(spacing: 8) {
                    if busy { ProgressView() } else { Image(systemName: kind == "button" ? "hand.tap" : "sparkles") }
                    Text(kind == "button" ? column.config["buttonLabel"]?.stringValue ?? "Ejecutar botón" : session.aiExecutionMode == .live ? "Generar en Nodus" : "Generar en este dispositivo")
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(minHeight: 44)
            }.buttonStyle(.bordered).disabled(busy || !session.canAuthor)
                .accessibilityIdentifier("database-property-action-\(column.id)")
            Menu {
                Button("Guardar durante 7 días") { Task { await download(days: 7) } }
                Button("Guardar durante 30 días") { Task { await download(days: 30) } }
            } label: { Label("Descargar contexto de esta acción", systemImage: "arrow.down.circle").font(.caption).fixedSize(horizontal: false, vertical: true) }
                .disabled(busy).accessibilityIdentifier("database-action-download-\(column.id)")
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if message != nil { Button("Trabajos y resultados") { jobsOpen = true }.font(.caption).frame(minHeight: 44) }
        }.nodusSheet(isPresented: $jobsOpen) {
            NavigationStack { LiveJobsView(session: session).nodusModalClose(accent: session.accent) }
        }
    }
    private func run() async {
        guard !busy else { return }; busy = true; failure = nil; defer { busy = false }
        do {
            let result: DesktopJobLedger.Request
            if kind == "button" { result = try await DatabasePropertyActions.runButton(session: session, rowId: rowId, columnId: column.id) }
            else if kind == "image" { result = try await DatabasePropertyActions.generateImage(session: session, rowId: rowId, columnId: column.id, ai: ai) }
            else { result = try await DatabasePropertyActions.generateText(session: session, rowId: rowId, columnId: column.id, ai: ai) }
            message = result.state == "available" ? "Resultado guardado en Nodus." : "Trabajo guardado. Consulta su estado en Trabajos y resultados."
            await session.synchronizeCompanionChanges()
        } catch { failure = error.localizedDescription }
    }
    private func download(days: Int) async {
        guard !busy else { return }; busy = true; failure = nil; defer { busy = false }
        do {
            try await DatabasePropertyActions.download(session: session, rowId: rowId, columnId: column.id, kind: kind, days: days)
            message = "Contexto de esta acción guardado durante \(days) días."
        } catch { failure = error.localizedDescription }
    }
}
