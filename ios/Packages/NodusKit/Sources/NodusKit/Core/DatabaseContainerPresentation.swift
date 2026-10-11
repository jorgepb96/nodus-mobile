import Foundation

public enum DatabaseContainerPresentation {
    /// The primary source's physical columns drive the native property controls.
    /// Foreign rows retain their actual database/row identities for navigation.
    public static func rows(definition:JSONValue,rows:[JSONValue],databaseId:String) throws -> [PagesDatabasesParity.DataRow] {
        guard let sources=definition.objectValue?["sources"]?.arrayValue,
            let primary=sources.first(where:{$0.objectValue?["databaseId"] == .string(databaseId) && $0.objectValue?["primary"] == .bool(true)}),
            let map=primary.objectValue?["propertyMap"]?.objectValue else {throw DesktopBridgeError.malformedResponse}
        var mappings:[String:String]=[:]
        for source in sources {
            guard let id=source.objectValue?["sourceId"]?.stringValue,let database=source.objectValue?["databaseId"]?.stringValue,mappings[id] == nil else {throw DesktopBridgeError.malformedResponse}
            mappings[id]=database
        }
        var ids=Set<String>()
        return try rows.enumerated().map{index,row in
            guard let value=row.objectValue,let id=value["rowId"]?.stringValue,!id.isEmpty,ids.insert(id).inserted,
                let source=value["sourceId"]?.stringValue,let owner=mappings[source],value["databaseId"] == .string(owner),
                value["id"] == .string("\(source):\(id)"),let cells=value["cells"]?.objectValue,
                let revision=value["revision"]?.intValue,revision > 0 else {throw DesktopBridgeError.malformedResponse}
            var physical:[String:String]=[:],errors:[String:String]=[:],colors:[String:String]=[:]
            for field in ["formulaErrors", "formulaColors"] {
                guard value[field] == nil || value[field] == .null || value[field]?.objectValue != nil else { throw DesktopBridgeError.malformedResponse }
            }
            for (canonical,column) in map {
                guard let key=column.stringValue,!key.isEmpty else {throw DesktopBridgeError.malformedResponse}
                if let content=cells[canonical],content != .null {
                    guard let text=content.stringValue else {throw DesktopBridgeError.malformedResponse};physical[key]=text
                }
                for field in ["formulaErrors", "formulaColors"] {
                    if let metadata = value[field]?.objectValue?[canonical], metadata != .null {
                        guard let text = metadata.stringValue else { throw DesktopBridgeError.malformedResponse }
                        if !text.isEmpty { if field == "formulaErrors" { errors[key] = text } else { colors[key] = text } }
                    }
                }
            }
            return PagesDatabasesParity.DataRow(id:id,databaseId:owner,position:Double(index),cells:physical,revision:revision,updatedAt:value["updatedAt"]?.stringValue,formulaErrors:errors,formulaColors:colors)
        }
    }
}
