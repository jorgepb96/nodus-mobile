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
}
