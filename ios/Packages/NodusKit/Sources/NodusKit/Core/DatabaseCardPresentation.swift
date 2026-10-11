import Foundation

/// Presentation of the canonical property codecs; raw cells remain unchanged.
public enum DatabaseCardPresentation {
    public struct Person:Sendable,Hashable { public let id:String;public let label:String;public let kind:String }
    public static func people(_ raw:String) -> [Person] {
        guard !raw.isEmpty else { return [] }
        guard let value=try? JSONDecoder.nodus.decode(JSONValue.self,from:Data(raw.utf8)),let items=value.arrayValue else {
            return [.init(id:"person:\(raw.lowercased())",label:raw,kind:"person")]
        }
        return items.compactMap { item in
            guard let object=item.objectValue,let label=object["label"]?.stringValue,!label.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return nil }
            let kind=object["kind"] == .string("group") ? "group":"person"
            return .init(id:object["id"]?.stringValue?.nonEmpty ?? "\(kind):\(label.lowercased())",label:label,kind:kind)
        }
    }
    public static func structuredValue(type:String,raw:String) -> String? {
        if ["person","created_by","last_edited_by"].contains(type) { return people(raw).map(\.label).joined(separator:", ") }
        let object=(try? JSONDecoder.nodus.decode(JSONValue.self,from:Data(raw.utf8)))?.objectValue
        if type == "location" {
            guard let object else { return raw }
            guard let name=object["name"]?.stringValue,!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return "" }
            return [name,object["address"]?.stringValue].compactMap{$0?.nonEmpty}.joined(separator:" · ")
        }
        if ["date","created_time","last_edited_time"].contains(type) {
            let start=object?["start"]?.stringValue ?? (object == nil ? raw:"")
            guard !start.isEmpty else { return "" }
            let formatter=DateFormatter();formatter.locale = .current;formatter.calendar=Calendar(identifier:.gregorian)
            let includeTime=object.map{$0["includeTime"] == .bool(true)} ?? start.contains("T")
            formatter.dateStyle = .medium;formatter.timeStyle = includeTime ? .short:.none
            if let zone=object?["timeZone"]?.stringValue,let timeZone=TimeZone(identifier:zone) { formatter.timeZone=timeZone }
            func display(_ value:String) -> String {
                if let date=ISO8601DateFormatter.nodusFractional.date(from:value) ?? ISO8601DateFormatter.nodusPlain.date(from:value) { return formatter.string(from:date) }
                let plain=DateFormatter();plain.locale=Locale(identifier:"en_US_POSIX");plain.calendar=Calendar(identifier:.gregorian);plain.timeZone=formatter.timeZone;plain.dateFormat="yyyy-MM-dd";plain.isLenient=false
                return plain.date(from:value).map{formatter.string(from:$0)} ?? value
            }
            return [start,object?["end"]?.stringValue].compactMap{$0?.nonEmpty}.map(display).joined(separator:" – ")
        }
        return nil
    }

    public struct Lane:Identifiable,Sendable,Hashable {
        public let id:String;public let label:String;public let color:String?
        public var rows:[PagesDatabasesParity.DataRow]
        public let limit:Int?
        public var atCapacity:Bool { limit.map{rows.count >= $0} ?? false }
    }
    public static func lanes(column:PagesDatabasesParity.Column?,rows:[PagesDatabasesParity.DataRow],config:[String:JSONValue]) -> [Lane] {
        guard let column,["status","select","person"].contains(column.type) else { return [] }
        let limits=config["groupLimits"]?.objectValue ?? [:]
        func lane(_ id:String,_ label:String,_ color:String? = nil) -> Lane {
            .init(id:id,label:label,color:color,rows:[],limit:limits[id]?.intValue.flatMap{$0 >= 0 ? $0:nil})
        }
        var result = column.type == "person" ? [] : column.options.sorted{$0.position == $1.position ? $0.id < $1.id:$0.position < $1.position}.map{lane($0.id,$0.label,$0.color)}
        result.append(lane("__empty__","Sin grupo"))
        for row in rows {
            let raw=row.cells[column.id] ?? ""
            let person=column.type == "person" ? people(raw).first:nil
            let key=person?.id ?? (raw.isEmpty ? "__empty__":raw)
            if column.type == "person",let person,!result.contains(where:{$0.id==key}) { result.append(lane(key,person.label)) }
            let index=result.firstIndex{$0.id==key} ?? result.firstIndex{$0.id=="__empty__"}!
            result[index].rows.append(row)
        }
        if config["hideEmptyGroups"] == .bool(true) { result.removeAll{$0.rows.isEmpty} }
        if config["groupBy"]?.objectValue?["dir"] == .string("desc") { result.reverse() }
        return result
    }
}

private extension String { var nonEmpty:String? { isEmpty ? nil:self } }
