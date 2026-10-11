import Foundation

/// A frozen question sent to the paired Mac. Model references and corpus
/// choices are portable; credentials stay in the Mac and there is no fallback.
public struct CompanionLiveChatRequest: Codable, Sendable, Hashable {
    public let version: Int
    public let requestId: String
    public let kind: CompanionChatKind
    public let answerId: String
    public let edit: JSONValue
    public let generation: JSONValue
    public init(requestId: String,kind: CompanionChatKind,answerId: String,edit: JSONValue,generation: JSONValue) throws {
        version=1;self.requestId=requestId;self.kind=kind;self.answerId=answerId;self.edit=edit;self.generation=generation
        try validate()
    }
    public func validate() throws {
        guard version == 1,UUID(uuidString:requestId) != nil,UUID(uuidString:answerId) != nil,
              let edit=edit.objectValue,edit["version"] == .int(1),edit["id"] == .string(requestId),edit["action"] == .string("save"),
              let conversationId=edit["conversationId"]?.stringValue,!conversationId.isEmpty,
              let messages=edit["draft"]?.objectValue?["messages"]?.arrayValue,let question=messages.last?.objectValue,
              question["role"] == .string("user"),let text=question["content"]?.stringValue,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              UUID(uuidString:question["id"]?.stringValue ?? "") != nil,
              !messages.contains(where:{$0.objectValue?["id"]?.stringValue.flatMap(UUID.init(uuidString:)) == UUID(uuidString:answerId)}),
              let generation=generation.objectValue,Set(generation.keys).isSubset(of:Set(["model","systemPromptId","thinkingEffort","attachmentIds","selection","webSearch","skillIds","concilium"])),
              try JSONEncoder.nodus.encode(self).count <= 20*1024*1024+64*1024 else { throw DesktopBridgeError.malformedResponse }
        if kind != .research,!["selection","webSearch","skillIds","concilium"].allSatisfy({generation[$0] == nil}) { throw DesktopBridgeError.malformedResponse }
        if let model=generation["model"],model != .null {
            guard let fields=model.objectValue,Set(fields.keys).isSubset(of:Set(["provider","model","pending","reasoningEffort"])),
                  let provider=fields["provider"]?.stringValue,!provider.isEmpty,
                  let name=fields["model"]?.stringValue,!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.utf8.count <= 1024 else { throw DesktopBridgeError.malformedResponse }
        }
    }
    public var conversationId:String { edit.objectValue?["conversationId"]?.stringValue ?? "" }
    public var value:JSONValue { get throws { try validate();return try JSONDecoder.nodus.decode(JSONValue.self,from:JSONEncoder.nodus.encode(self)) } }
}

public struct CompanionLiveChatResult: Codable,Sendable,Hashable {
    public let version:Int
    public let requestId:String
    public let kind:CompanionChatKind
    public let document:CompanionChatDocument
    public let interrupted:Bool
    public func validate(request:CompanionLiveChatRequest) throws {
        try request.validate();try document.validate(kind:request.kind,id:request.conversationId)
        guard version == 1,requestId == request.requestId,kind == request.kind,
              document.data.objectValue?["messages"]?.arrayValue?.contains(where:{
                  $0.objectValue?["id"]?.stringValue.flatMap(UUID.init(uuidString:)) == UUID(uuidString:request.answerId) && $0.objectValue?["role"] == .string("assistant")
              }) == true else { throw DesktopBridgeError.malformedResponse }
    }
    public static func decode(_ value:JSONValue,request:CompanionLiveChatRequest) throws -> Self {
        let result=try JSONDecoder.nodus.decode(Self.self,from:JSONEncoder.nodus.encode(value));try result.validate(request:request);return result
    }
}
