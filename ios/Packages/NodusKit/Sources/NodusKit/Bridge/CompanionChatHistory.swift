import Foundation

public enum CompanionChatKind: String, Codable, Sendable, CaseIterable {
    case research, world, database, study
    public init(vaultType: VaultType?) {
        switch vaultType {
        case .worldbuilding: self = .world
        case .databases: self = .database
        case .estudio, .docencia: self = .study
        default: self = .research
        }
    }
}
public struct CompanionChatDocument: Codable, Sendable, Hashable {
    public let version: Int
    public let kind: CompanionChatKind
    public let id: String
    public let revision: String
    public let data: JSONValue
    public let companion: JSONValue?
    public init(version: Int,kind: CompanionChatKind,id: String,revision: String,data: JSONValue,companion: JSONValue?) {
        self.version = version;self.kind = kind;self.id = id;self.revision = revision;self.data = data;self.companion = companion
    }
    public func validate(kind expected: CompanionChatKind, id expectedId: String) throws {
        guard version == 1,kind == expected,id == expectedId,
              revision.count == 64,revision.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let object = data.objectValue,object["id"] == .string(id),
              object["title"]?.stringValue != nil,
              let messages = object["messages"]?.arrayValue,
              messages.allSatisfy({ value in
                  guard let message = value.objectValue else { return false }
                  return ["user","assistant"].contains(message["role"]?.stringValue ?? "") && message["content"]?.stringValue != nil
              }),companion == nil || companion == .null || companion?.objectValue != nil,
              try JSONEncoder.nodus.encode(self).count <= 20 * 1024 * 1024 else { throw DesktopBridgeError.malformedResponse }
    }
}
public struct CompanionChatPage: Decodable, Sendable {
    public let version: Int
    public let kind: CompanionChatKind
    public let revision: String
    public let rows: [JSONValue]
    public let cursor: Int
    public let hasMore: Bool
    public let organisation: CompanionChatOrganisation?
}

public struct CompanionChatOrganisation: Codable,Sendable,Hashable {
    public struct Project: Codable,Sendable,Hashable,Identifiable {public let id:String;public let name:String;public let instructions:String}
    public struct Folder: Codable,Sendable,Hashable,Identifiable {public let id:String;public let projectId:String;public let parentId:String?;public let name:String;public let position:Int}
    public struct Notebook: Codable,Sendable,Hashable,Identifiable {public let id:String;public let name:String}
    public let version:Int
    public let kind:CompanionChatKind
    public let projects:[Project]
    public let folders:[Folder]
    public let notebooks:[Notebook]
    public func validate(kind:CompanionChatKind) throws {
        guard version == 1,self.kind == kind,
              Set(projects.map(\.id)).count == projects.count,Set(folders.map(\.id)).count == folders.count,Set(notebooks.map(\.id)).count == notebooks.count,
              projects.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }),notebooks.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }),
              folders.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }),
              try JSONEncoder.nodus.encode(self).count <= 8 * 1024 * 1024 else { throw DesktopBridgeError.malformedResponse }
        let projectIds = Set(projects.map(\.id)),byId = Dictionary(uniqueKeysWithValues:folders.map { ($0.id,$0) })
        for folder in folders {
            guard projectIds.contains(folder.projectId),folder.parentId.map({ byId[$0]?.projectId == folder.projectId }) ?? true else { throw DesktopBridgeError.malformedResponse }
            var ancestors = Set<String>(),cursor: String? = folder.id
            while let id = cursor { guard ancestors.insert(id).inserted else { throw DesktopBridgeError.malformedResponse };cursor = byId[id]?.parentId }
        }
    }
    public func folderName(_ id:String) -> String? {
        let byId = Dictionary(uniqueKeysWithValues:folders.map { ($0.id,$0) })
        guard let folder = byId[id] else { return nil }
        var names:[String] = [],cursor:Folder? = folder,seen = Set<String>()
        while let item = cursor,seen.insert(item.id).inserted { names.insert(item.name,at:0);cursor = item.parentId.flatMap { byId[$0] } }
        return names.joined(separator:" › ")
    }
}

public struct CompanionChatPlacement: Codable,Sendable,Hashable {
    public var projectId:String?
    public var folderId:String?
    public var notebookId:String?
    public var pinned:Bool
    public init(projectId:String? = nil,folderId:String? = nil,notebookId:String? = nil,pinned:Bool = false) {
        self.projectId = projectId;self.folderId = folderId;self.notebookId = notebookId;self.pinned = pinned
    }
    /// Explicit nulls clear an old assignment; omitted IDs would be ambiguous.
    public var value:JSONValue { .object(["projectId":projectId.map(JSONValue.string) ?? .null,"folderId":folderId.map(JSONValue.string) ?? .null,"notebookId":notebookId.map(JSONValue.string) ?? .null,"pinned":.bool(pinned)]) }
    public static func desktop(_ value:JSONValue) -> Self {
        let raw = value.objectValue ?? [:]
        return Self(projectId:raw["projectId"]?.stringValue,folderId:raw["folderId"]?.stringValue,notebookId:raw["notebookId"]?.stringValue,pinned:raw["pinnedAt"]?.stringValue != nil)
    }
}
