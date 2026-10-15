import Foundation
import NodusKit

@MainActor enum CompanionStudyKnowledgeSources {
    static func perform(session: SpaceSession, action: String, input: JSONValue?) async throws -> JSONValue {
        let (vault,pairing,token) = try privateBridgeConnection(session,domain:.corpus)
        let cache = try PrivateBridgeCache(pairingId:pairing.id)
        if action == "load" {
            let copies = try await cache.downloadedData(vaultId:vault,domain:.corpus,recordId:CompanionStudyKnowledgeCopy.recordId)
            guard !copies.isEmpty else { throw APIError(status:404,code:"study_knowledge_not_downloaded",message:"Descarga las ideas de una asignatura mientras Nodus esté conectado.") }
            return .array(try copies.map { data in
                let value = try JSONDecoder.nodus.decode(JSONValue.self,from:data)
                guard value.objectValue?["vaultId"] == .string(vault) else { throw DesktopBridgeError.malformedResponse }
                return try CompanionStudyKnowledgeCopy(saved:value,vaultId:vault).completed()
            })
        }
        guard action == "download", let fields = input?.objectValue, let subject = fields["subjectId"]?.stringValue,
              let days = fields["days"]?.intValue, [7,30].contains(days) else { throw PrivateBridgeCache.ReadPackError.invalidSelection }
        let client = DesktopBridgeClient(pairing:pairing,token:token)
        func page(_ offset:Int,_ revision:String?=nil) async throws -> JSONValue {
            var request:[String:JSONValue] = ["subjectId":.string(subject),"offset":.int(Int64(offset)),"limit":.int(80)]
            if let revision { request["revision"] = .string(revision) }
            return try await client.operation(vaultId:vault,method:"getMobileStudyKnowledgeSource",args:[.object(request)])
        }
        let first = try await page(0)
        var source = try CompanionStudyKnowledgeCopy(first:first,vaultId:vault,subjectId:subject)
        let revision = source.value.objectValue!["revision"]!.stringValue!
        let budget = try await cache.usage().readLimitBytes
        while source.count < source.total {
            try Task.checkCancellation()
            guard try JSONEncoder.nodus.encode(source.value).count <= budget else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            let next = try await page(source.count,revision)
            try source.append(next)
        }
        let complete = try source.completed()
        _ = try await page(0,revision) // final read barrier; no mixed/replaced source
        let bytes = try JSONEncoder.nodus.encode(complete)
        let selection = try PrivateBridgeCache.readPackSelectionId(vaultId:vault,recordIds:[CompanionStudyKnowledgeCopy.recordId+":"+subject])
        let title = complete.objectValue?["workspace"]?.objectValue?["subjects"]?.arrayValue?.first?.objectValue?["name"]?.stringValue ?? "Asignatura"
        try await cache.saveReadPack(id:selection,vaultId:vault,title:"Ideas: "+String(title.prefix(200)),expiresAt:Date().addingTimeInterval(Double(days)*86400),records:[.init(domain:.corpus,recordId:CompanionStudyKnowledgeCopy.recordId,data:bytes)])
        session.didChangeCompanionDownloads()
        return complete
    }
}
