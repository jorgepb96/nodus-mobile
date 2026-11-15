import Foundation
import NodusKit

struct CompanionWorldChatOptions: Codable,Hashable {
    struct Selection: Codable,Hashable { var scope = "auto";var entryKeys: [String] = [];var keepFocus = false }
    struct Focus: Codable,Hashable,Identifiable { let kind: String,id: String,title: String;var key: String { "\(kind):\(id)" } }
    var selection = Selection()
    var focus: [Focus] = []
    var value: JSONValue { get throws { try JSONDecoder.nodus.decode(JSONValue.self,from:JSONEncoder.nodus.encode(self)) } }
    static func desktop(_ value: JSONValue) throws -> Self {
        guard let source = value.objectValue,let selection = source["selection"],let focus = source["focus"] else { throw DesktopBridgeError.malformedResponse }
        return try JSONDecoder.nodus.decode(Self.self,from:JSONEncoder.nodus.encode(JSONValue.object(["selection":selection,"focus":focus])))
    }
    var focusKeys: [String] { selection.scope == "manual" ? selection.entryKeys:selection.keepFocus ? focus.map(\.key):[] }
}

@MainActor
enum CompanionWorldChatSources {
    static let recordId = "companion:world-chat-sources:v1"
    struct Entry: Codable,Hashable,Identifiable { let kind: String,key: String,title: String;var id: String { key } }
    static func packs(session: SpaceSession) async throws -> [JSONValue] {
        let (vault,pairing,_) = try privateBridgeConnection(session,domain:.corpus)
        let copies = try await PrivateBridgeCache(pairingId:pairing.id).downloadedData(vaultId:vault,domain:.corpus,recordId:recordId)
        guard !copies.isEmpty else { throw APIError(status:409,code:"world_chat_not_downloaded",message:"Elige los elementos del mundo que quieres llevar desde Descargas mientras Nodus esté conectado.") }
        var packs: [JSONValue] = [],ids = Set<String>(),bytes = 0
        for data in copies {
            bytes += data.count;guard bytes <= 50 * 1024 * 1024 else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            let pack = try JSONDecoder.nodus.decode(JSONValue.self,from:data)
            guard let id = pack.objectValue?["id"]?.stringValue,pack.objectValue?["vaultId"] == .string(vault),pack.objectValue?["version"] == .int(1) else { throw DesktopBridgeError.malformedResponse }
            if ids.insert(id).inserted { packs.append(pack) }
        }
        return packs
    }
    static func catalogue(session: SpaceSession) async throws -> ([Entry],Bool) {
        guard let vault = session.vaultId else { throw DesktopBridgeError.permissionDenied }
        do {
            let value = try await ConnectionClient.companionChat(for:session.connection).operation(vaultId:vault,method:"listWorldEntries",args:[])
            let entries = try JSONDecoder.nodus.decode([Entry].self,from:JSONEncoder.nodus.encode(value))
            guard Set(entries.map(\.key)).count == entries.count else { throw DesktopBridgeError.malformedResponse };return (entries,false)
        } catch {
            guard isPrivateBridgeOffline(error) else { throw error }
            var entries: [String:Entry] = [:]
            for pack in try await packs(session:session) {
                guard let data = pack.objectValue?["data"]?.objectValue?["entries"] else { throw DesktopBridgeError.malformedResponse }
                for entry in try JSONDecoder.nodus.decode([Entry].self,from:JSONEncoder.nodus.encode(data)) where entries[entry.key] == nil { entries[entry.key] = entry }
            }
            return (entries.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },true)
        }
    }
    static func download(session: SpaceSession,keys: [String],days: Int) async throws {
        guard !keys.isEmpty,keys.count <= 100,Set(keys).count == keys.count,[7,30].contains(days),let vault = session.vaultId else { throw DesktopBridgeError.malformedResponse }
        let (owner,pairing,token) = try privateBridgeConnection(session,domain:.corpus);guard owner == vault else { throw DesktopBridgeError.permissionDenied }
        let pack = try await DesktopBridgeClient(pairing:pairing,token:token).operation(vaultId:vault,method:"getMobileWorldChatSourcePack",args:[.object(["entryKeys":.array(keys.map(JSONValue.string))])])
        try await CompanionChatContext.validateWorldSources(pack,vaultId:vault)
        let body = try JSONEncoder.nodus.encode(pack),cache = try PrivateBridgeCache(pairingId:pairing.id)
        let previous = try await cache.downloadedData(vaultId:vault,domain:.corpus,recordId:recordId).reduce(0) { $0 + $1.count }
        guard body.count <= 16_000_000,body.count + previous <= 50 * 1024 * 1024 else { throw PrivateBridgeCache.ReadPackError.tooLarge }
        let id = try PrivateBridgeCache.readPackSelectionId(vaultId:vault,recordIds:keys.sorted().map { "world-chat:\($0)" })
        try Task.checkCancellation()
        try await cache.saveReadPack(id:id,vaultId:vault,title:"Contexto del mundo · \(keys.count)",expiresAt:Date().addingTimeInterval(Double(days)*86_400),records:[.init(domain:.corpus,recordId:recordId,data:body)])
        session.didChangeCompanionDownloads()
    }
    static func source(session: SpaceSession,key: String) async throws -> JSONValue {
        guard let vault = session.vaultId else { throw DesktopBridgeError.permissionDenied }
        let pack: JSONValue
        do { pack = try await ConnectionClient.companionChat(for:session.connection).operation(vaultId:vault,method:"getMobileWorldChatSourcePack",args:[.object(["entryKeys":.array([.string(key)])])]) }
        catch {
            guard isPrivateBridgeOffline(error) else { throw error }
            guard let chosen = try await packs(session:session).first(where:{$0.objectValue?["entryKeys"]?.arrayValue?.contains(.string(key)) == true}) else { throw APIError(status:409,code:"world_source_not_downloaded",message:"Este elemento no está descargado. Su referencia se conserva; vuelve a conectar con Nodus o elígelo para llevar.") };pack = chosen
        }
        try await CompanionChatContext.validateWorldSources(pack,vaultId:vault)
        guard let data = pack.objectValue?["data"]?.objectValue,let entry = data["entries"]?.arrayValue?.first(where:{$0.objectValue?["key"] == .string(key)}),let prose = data["prose"]?.objectValue?[key] else { throw DesktopBridgeError.malformedResponse }
        return .object(["entry":entry,"prose":prose])
    }
}
