import Foundation
import NodusKit

struct CompanionStudyChatOptions: Codable,Hashable {
    struct Selection: Codable,Hashable {
        var scope = "library"
        var sourceKeys: [String] = []
        var courseId: String?
        var subjectId: String?
        var topicId: String?
    }
    var selection = Selection()
    var task = "answer"
    var level = "standard"
    var tone = "clear"
    var language = "auto"
    var allowExternalKnowledge = false
    var value: JSONValue { get throws { try JSONDecoder.nodus.decode(JSONValue.self,from:JSONEncoder.nodus.encode(self)) } }
    static func desktop(_ value: JSONValue) throws -> Self {
        guard let source = value.objectValue else { throw DesktopBridgeError.malformedResponse }
        let keys = ["selection","task","level","tone","language","allowExternalKnowledge"]
        return try JSONDecoder.nodus.decode(Self.self,from:JSONEncoder.nodus.encode(JSONValue.object(source.filter { keys.contains($0.key) })))
    }
}

/// Metadata browsing downloads no source text. Only an explicit read pack owns
/// reusable fragments, subject to the app's encrypted temporary-copy budget.
@MainActor
enum CompanionStudyChatSources {
    static let recordId = "companion:study-chat-sources:v1"
    static let catalogueId = "companion:study-chat-catalogue:v1"
    struct Catalogue: Codable {
        struct Named: Codable,Identifiable { let id: String,name: String }
        struct Source: Codable,Identifiable {
            let sourceKey: String,kind: String,sourceId: String,title: String,subtitle: String
            let chunks: Int
            let available: Bool?
            var id: String { sourceKey }
        }
        let version: Int
        let courses: [Named],subjects: [Named],topics: [Named],sources: [Source]
    }
    static func catalogue(session: SpaceSession) async throws -> (Catalogue,Bool,Set<String>) {
        let (vault,pairing,token) = try privateBridgeConnection(session,domain:.corpus)
        let value: JSONValue,offline: Bool
        do {
            value = try await DesktopBridgeClient(pairing:pairing,token:token).operation(vaultId:vault,method:"getMobileStudyChatCatalogue",args:[]);offline = false
        } catch {
            guard isPrivateBridgeOffline(error) else { throw error }
            let cache = try PrivateBridgeCache(pairingId:pairing.id)
            guard let data = try await cache.downloadedData(vaultId:vault,domain:.corpus,recordId:catalogueId).first else {
                throw APIError(status:409,code:"study_chat_not_downloaded",message:"Elige fuentes de estudio para llevar mientras Nodus esté conectado.")
            }
            value = try JSONDecoder.nodus.decode(JSONValue.self,from:data);offline = true
        }
        let catalogue = try JSONDecoder.nodus.decode(Catalogue.self,from:JSONEncoder.nodus.encode(value))
        guard catalogue.version == 1,Set(catalogue.sources.map(\.id)).count == catalogue.sources.count else { throw DesktopBridgeError.malformedResponse }
        var downloaded = Set<String>()
        if offline {
            for pack in try await packs(session:session) {
                for entry in pack.objectValue?["entries"]?.arrayValue ?? [] {
                    guard let kind = entry.objectValue?["kind"]?.stringValue,let id = entry.objectValue?["sourceId"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
                    downloaded.insert("\(kind):\(id)")
                }
            }
        }
        return (catalogue,offline,downloaded)
    }
    static func packs(session: SpaceSession) async throws -> [JSONValue] {
        let (vault,pairing,_) = try privateBridgeConnection(session,domain:.corpus)
        let copies = try await PrivateBridgeCache(pairingId:pairing.id).downloadedData(vaultId:vault,domain:.corpus,recordId:recordId)
        guard !copies.isEmpty else { throw APIError(status:409,code:"study_chat_not_downloaded",message:"No hay fuentes de estudio descargadas. Elige cuáles llevar desde Descargas.") }
        var seen = Set<String>(),packs: [JSONValue] = [],bytes = 0
        for data in copies {
            bytes += data.count;guard bytes <= 50 * 1024 * 1024 else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            let value = try JSONDecoder.nodus.decode(JSONValue.self,from:data)
            guard let id = value.objectValue?["id"]?.stringValue,value.objectValue?["vaultId"] == .string(vault),value.objectValue?["version"] == .int(1) else { throw DesktopBridgeError.malformedResponse }
            if seen.insert(id).inserted { packs.append(value) }
        }
        return packs
    }
    static func original(kind: String,id: String,session: SpaceSession) async throws -> (JSONValue,Bool) {
        guard ["question","exam"].contains(kind),!id.isEmpty else { throw DesktopBridgeError.malformedResponse }
        let (vault,pairing,token) = try privateBridgeConnection(session,domain:.corpus)
        let source: JSONValue,offline: Bool
        let args: [JSONValue] = [.object(["kind":.string(kind),"sourceId":.string(id)])]
        do {
            source = try await DesktopBridgeClient(pairing:pairing,token:token).operation(vaultId:vault,method:"getMobileStudyChatOriginal",args:args);offline = false
        } catch {
            guard isPrivateBridgeOffline(error) else { throw error }
            var chosen: JSONValue?
            let key = try CompanionDocumentOutbox.operationKey("getMobileStudyChatOriginal", args)
            if let data = try await PrivateBridgeCache(pairingId:pairing.id).downloadedData(vaultId:vault,domain:.corpus,recordId:key).first {
                chosen = try JSONDecoder.nodus.decode(JSONValue.self,from:data)
            } else {
                for pack in try await packs(session:session) {
                    try await CompanionChatContext.validateStudySources(pack,vaultId:vault)
                    if let candidate = pack.objectValue?["originals"]?.objectValue?["\(kind):\(id)"] { chosen = candidate;break }
                }
            }
            guard let chosen else { throw APIError(status:409,code:"study_chat_original_not_downloaded",message:"La cita está guardada, pero su fuente completa no está descargada. Vuelve a descargar esta pregunta o examen desde Fuentes de estudio cuando Nodus esté conectado.") }
            source = chosen;offline = true
        }
        guard source.objectValue?["kind"] == .string(kind),source.objectValue?["sourceId"] == .string(id) else { throw DesktopBridgeError.malformedResponse }
        try await CompanionChatContext.validateStudyOriginal(source)
        return (source,offline)
    }
    static func download(session: SpaceSession,keys: [String],days: Int) async throws {
        guard !keys.isEmpty,keys.count <= 100,Set(keys).count == keys.count,[7,30].contains(days) else { throw DesktopBridgeError.malformedResponse }
        let (vault,pairing,token) = try privateBridgeConnection(session,domain:.corpus),client = DesktopBridgeClient(pairing:pairing,token:token)
        let catalogue = try await client.operation(vaultId:vault,method:"getMobileStudyChatCatalogue",args:[])
        var selection = CompanionStudyChatOptions.Selection();selection.scope = "manual";selection.sourceKeys = keys
        let query = try JSONDecoder.nodus.decode(JSONValue.self,from:JSONEncoder.nodus.encode(selection))
        let pack = try await client.operation(vaultId:vault,method:"getMobileStudyChatSourcePack",args:[query])
        try await CompanionChatContext.validateStudySources(pack,vaultId:vault)
        let body = try JSONEncoder.nodus.encode(pack),metadata = try JSONEncoder.nodus.encode(catalogue)
        let cache = try PrivateBridgeCache(pairingId:pairing.id)
        let existing = try await cache.downloadedData(vaultId:vault,domain:.corpus,recordId:recordId).reduce(0) { $0 + $1.count }
        guard body.count <= 16_000_000,body.count + metadata.count + existing <= 50 * 1024 * 1024 else { throw PrivateBridgeCache.ReadPackError.tooLarge }
        let id = try PrivateBridgeCache.readPackSelectionId(vaultId:vault,recordIds:keys.sorted().map { "study-chat:\($0)" })
        try Task.checkCancellation()
        try await cache.saveReadPack(id:id,vaultId:vault,title:"Fuentes del chat de estudio · \(keys.count)",expiresAt:Date().addingTimeInterval(Double(days)*86_400),records:[.init(domain:.corpus,recordId:recordId,data:body),.init(domain:.corpus,recordId:catalogueId,data:metadata)])
        session.didChangeCompanionDownloads()
    }
}
