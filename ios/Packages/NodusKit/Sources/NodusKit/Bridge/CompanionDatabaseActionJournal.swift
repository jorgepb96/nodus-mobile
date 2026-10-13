import CryptoKit
import Foundation

public struct CompanionDatabaseActionCheckpoint: Sendable, Identifiable {
    public enum State: String, Sendable { case accepted, running, saved, failed, cancelled, interrupted }
    public let value: JSONValue
    public let id: String
    public let scope: String
    public let state: State
    public let publicationInput: JSONValue?
    public init(_ value: JSONValue) throws {
        guard let object=value.objectValue,object["version"] == .int(1),
              let id=object["id"]?.stringValue,UUID(uuidString:id) != nil,
              object["vaultId"]?.stringValue?.isEmpty == false,
              let request=object["request"],let row=request.objectValue?["rowId"]?.stringValue,!row.isEmpty,
              let column=request.objectValue?["columnId"]?.stringValue,!column.isEmpty,
              ["text","image","button"].contains(request.objectValue?["kind"]?.stringValue ?? ""),
              let revision=request.objectValue?["revision"]?.stringValue,revision.count == 64,
              revision.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),
              let created=object["createdAt"]?.stringValue,ISO8601DateFormatter().date(from:created) != nil,
              let rawState=object["state"]?.stringValue,let state=State(rawValue:rawState),
              let model=object["model"],try JSONEncoder.nodus.encode(value).count <= 65_000_000 else { throw DesktopBridgeError.malformedResponse }
        if request.objectValue?["kind"] != .string("button") {
            guard model.objectValue?["provider"]?.stringValue != nil,model.objectValue?["model"]?.stringValue != nil else {throw DesktopBridgeError.malformedResponse}
        }
        var publication: JSONValue?
        if let text=object["text"]?.stringValue {
            guard request.objectValue?["kind"] == .string("text"),text.count <= 100_000 else {throw DesktopBridgeError.malformedResponse}
            publication = .object(["requestId":.string(id),"request":request,"model":model,"text":.string(text)])
        }
        if let bytes=object["bytes"]?.stringValue {
            guard request.objectValue?["kind"] == .string("image"),let data=Data(base64Encoded:bytes),!data.isEmpty,data.count <= 20_000_000,data.base64EncodedString() == bytes,
                  ["image/png","image/jpeg","image/webp"].contains(object["mime"]?.stringValue ?? "") else {throw DesktopBridgeError.malformedResponse}
            publication = .object(["requestId":.string(id),"request":request,"model":model,"bytes":.string(bytes),"mime":object["mime"]!])
        }
        if let result=object["buttonResult"] {
            guard request.objectValue?["kind"] == .string("button"),result.objectValue != nil else {throw DesktopBridgeError.malformedResponse}
            if result.objectValue?["finishedAt"]?.stringValue != nil, result.objectValue?["pendingWebhook"] == nil {publication = .object(["requestId":.string(id),"request":request,"result":result])}
        }
        guard state != .saved || publication != nil else {throw DesktopBridgeError.malformedResponse}
        self.id=id;self.value=value;self.state=state
        self.scope=try Self.scope(request:request,model:model)
        self.publicationInput = [.saved,.failed,.interrupted].contains(state) ? publication:nil
    }
    public static func scope(request: JSONValue, model: JSONValue) throws -> String {
        "companion:database-action:v1:"+SHA256.hash(data:try JSONEncoder.nodus.encode(JSONValue.array([request,model]))).map {String(format:"%02x",$0)}.joined()
    }
    public func changing(state: State, output: JSONValue? = nil, error: String? = nil) throws -> Self {
        var object=value.objectValue!;object["state"] = .string(state.rawValue);object["error"] = error.map(JSONValue.string)
        if let output {for (key,value) in output.objectValue ?? [:] {guard ["text","bytes","mime","buttonResult"].contains(key) else {throw DesktopBridgeError.malformedResponse};object[key]=value}}
        return try Self(.object(object))
    }
}
public actor CompanionDatabaseActionJournal {
    private let cache: PrivateBridgeCache
    private let vault: String
    private var active: [String:Task<CompanionDatabaseActionCheckpoint,Error>] = [:]
    public static let indexKey = "companion:database-action-index:v1"
    private var index: [String:JSONValue]
    public init(cache: PrivateBridgeCache,vault:String) async throws {
        self.cache=cache;self.vault=vault
        if let bytes=try await cache.data(vaultId:vault,domain:.researchGeneration,recordId:Self.indexKey) {
            guard let index=try JSONDecoder.nodus.decode(JSONValue.self,from:bytes).objectValue else {throw DesktopBridgeError.malformedResponse};self.index=index
        }else{index=[:]}
    }
    public func load(scope:String) async throws -> CompanionDatabaseActionCheckpoint? {
        guard let bytes=try await cache.data(vaultId:vault,domain:.researchGeneration,recordId:scope) else {return nil}
        let checkpoint=try CompanionDatabaseActionCheckpoint(JSONDecoder.nodus.decode(JSONValue.self,from:bytes))
        guard checkpoint.value.objectValue?["vaultId"] == .string(vault), checkpoint.scope == scope || checkpoint.scope+":"+checkpoint.id == scope else {throw DesktopBridgeError.malformedResponse};return checkpoint
    }
    public func put(_ checkpoint:CompanionDatabaseActionCheckpoint) async throws {
        guard checkpoint.value.objectValue?["vaultId"] == .string(vault) else {throw DesktopBridgeError.permissionDenied}
        try await cache.store(JSONEncoder.nodus.encode(checkpoint.value),vaultId:vault,domain:.researchGeneration,recordId:checkpoint.scope)
        var summary=checkpoint.value.objectValue!;summary["bytes"]=nil;summary["text"]=nil;summary["buttonResult"]=nil;summary["source"]=nil;summary["references"]=nil;summary["scope"] = .string(checkpoint.scope)
        index[checkpoint.scope] = .object(summary)
        try await cache.store(JSONEncoder.nodus.encode(JSONValue.object(index)),vaultId:vault,domain:.researchGeneration,recordId:Self.indexKey)
    }
    public func perform(accepted:CompanionDatabaseActionCheckpoint,regenerateCompleted:Bool = false,generate:@escaping @Sendable () async throws -> JSONValue) async throws -> CompanionDatabaseActionCheckpoint {
        if let task=active[accepted.scope] {return try await task.value}
        if let existing=try await load(scope:accepted.scope) {
            if existing.value.objectValue?["recoveryReviewRequired"] == .bool(true) {throw APIError(status:409,code:"database_action_recovery_review",message:"Revisa el resultado conservado antes de continuar.")}
            if existing.publicationInput != nil, !regenerateCompleted {return existing}
            if regenerateCompleted, existing.publicationInput != nil {
                guard existing.id != accepted.id else {throw DesktopBridgeError.malformedResponse}
                let archiveKey=existing.scope+":"+existing.id
                try await cache.store(JSONEncoder.nodus.encode(existing.value),vaultId:vault,domain:.researchGeneration,recordId:archiveKey)
                var summary=existing.value.objectValue!;for key in ["bytes","text","buttonResult","source","references"] {summary[key]=nil};summary["scope"] = .string(archiveKey);index[archiveKey] = .object(summary)
                try await cache.store(JSONEncoder.nodus.encode(JSONValue.object(index)),vaultId:vault,domain:.researchGeneration,recordId:Self.indexKey)
            } else {
            // No automatic new paid request follows a lost response or restart.
            throw APIError(status:409,code:"database_action_interrupted",message:"Esta petición anterior no tiene un resultado confirmado. Revisa su estado antes de iniciar otra generación.")
            }
        }
        // Recheck after cache I/O: another observer may already own the call.
        if let task=active[accepted.scope] {return try await task.value}
        let task=Task {
            var checkpoint=accepted
            do {
                try await self.put(checkpoint);checkpoint=try checkpoint.changing(state:.running);try await self.put(checkpoint)
                try Task.checkCancellation();let output=try await generate()
                checkpoint=try checkpoint.changing(state:.saved,output:output);try await self.put(checkpoint)
                try Task.checkCancellation();return checkpoint
            }catch{checkpoint = try await self.load(scope:accepted.scope) ?? checkpoint;checkpoint=try checkpoint.changing(state:error.isCancellation ? .cancelled:.failed,error:error.localizedDescription);try await self.put(checkpoint);throw error}
        }
        active[accepted.scope]=task;defer{active[accepted.scope]=nil};return try await task.value
    }
    public func cancel(scope:String){active[scope]?.cancel()}
    public func summaries()->[JSONValue]{index.values.sorted{($0.objectValue?["createdAt"]?.stringValue ?? "") > ($1.objectValue?["createdAt"]?.stringValue ?? "")}}
}

public extension CompanionDatabaseActionCheckpoint {
    static func instantiate(_ value:JSONValue,requestId:String,clickedAt:String)throws->JSONValue {
        switch value {
        case .string(let text):
            let expression=try NSRegularExpression(pattern:"NODUS_ACTION_ID:(drow|arun|anote|pblk):(\\d+)")
            var output=text
            for match in expression.matches(in:text,range:NSRange(text.startIndex...,in:text)).reversed() {
                guard let prefixRange=Range(match.range(at:1),in:text),let indexRange=Range(match.range(at:2),in:text),let range=Range(match.range,in:output) else {throw DesktopBridgeError.malformedResponse}
                let prefix=String(text[prefixRange]),index=String(text[indexRange]),hex=SHA256.hash(data:Data("\(requestId):\(prefix):\(index)".utf8)).map{String(format:"%02x",$0)}.joined()
                let characters=Array(hex.prefix(32)),uuid=String(characters[0..<8])+"-"+String(characters[8..<12])+"-"+String(characters[12..<16])+"-"+String(characters[16..<20])+"-"+String(characters[20..<32])
                output.replaceSubrange(range,with:prefix+"_"+uuid)
            }
            return .string(output.replacingOccurrences(of:"NODUS_ACTION_CLICK_TIME",with:clickedAt))
        case .array(let values):return .array(try values.map{try instantiate($0,requestId:requestId,clickedAt:clickedAt)})
        case .object(let values):return .object(try values.mapValues{try instantiate($0,requestId:requestId,clickedAt:clickedAt)})
        default:return value
        }
    }
    /// Only executed local deltas are overlaid. An unrelated consulted forest,
    /// remote computed value, or recovered unreviewed grant is never invented.
    func projectedCells()throws->[String:[String:JSONValue]] {
        guard value.objectValue?["recoveryReviewRequired"] != .bool(true) else {return [:]}
        var result:[String:[String:JSONValue]] = [:]
        guard let request=value.objectValue?["request"]?.objectValue,let row=request["rowId"]?.stringValue,let column=request["columnId"]?.stringValue else {throw DesktopBridgeError.malformedResponse}
        if let text=value.objectValue?["text"]?.stringValue {result[row]=[column:.string(text.trimmingCharacters(in:.whitespacesAndNewlines))]}
        guard let progress=value.objectValue?["buttonResult"]?.objectValue,let count=progress["completedSteps"]?.intValue,let clickedAt=progress["clickedAt"]?.stringValue,
              let rawPlan=value.objectValue?["source"]?.objectValue?["plan"],let operations=try Self.instantiate(rawPlan,requestId:id,clickedAt:clickedAt).objectValue?["operations"]?.arrayValue,count>=0,count<=operations.count else {return result}
        for operation in operations.prefix(Int(count)) {
            guard let fields=operation.objectValue else {throw DesktopBridgeError.malformedResponse}
            if fields["type"] == .string("set_property"),let row=fields["rowId"]?.stringValue,let column=fields["columnId"]?.stringValue {result[row,default:[:]][column]=fields["value"] ?? .null}
            else if fields["type"] == .string("button_click"),let row=fields["rowId"]?.stringValue,let column=fields["columnId"]?.stringValue {
                let body:JSONValue = .object(["clicks":fields["clicks"] ?? .int(1),"lastClickedAt":.string(clickedAt),"lastClickedBy":.string("local")])
                result[row,default:[:]][column] = .string(String(decoding:try JSONEncoder.nodus.encode(body),as:UTF8.self))
            }
        }
        return result
    }
}
