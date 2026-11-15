import CryptoKit
import Foundation
import NodusKit

/// Exports one current Mac figure. No caller-supplied bytes or provider call.
@MainActor enum CompanionLiveDocumentVisualExport {
    static func export(_ input: JSONValue, session: SpaceSession) async throws -> PrivateBridgeFileLease {
        guard let object = input.objectValue, let id = object["reportId"]?.stringValue, UUID(uuidString:id) != nil,
              let expected = object["expected"] else { throw DesktopBridgeError.malformedResponse }
        let (vault,pairing,token) = try privateBridgeConnection(session,domain:.corpus)
        let client = DesktopBridgeClient(pairing:pairing,token:token)
        if let svg = object["svg"]?.stringValue, svg.utf8.count <= 2_000_000, let figure = object["figureId"]?.stringValue {
            let manifest = try await client.operation(vaultId:vault,method:"getDocumentVisuals",args:[.object(["kind":.string("deep-research"),"id":.string(id)])])
            guard manifest.objectValue?["revision"] == expected.objectValue?["revision"],manifest.objectValue?["contentHash"] == expected.objectValue?["contentHash"],
                  let entry = manifest.objectValue?["figures"]?.arrayValue?.first(where:{$0.objectValue?["id"]?.stringValue == figure}),
                  contains(svg:svg,nodes:entry.objectValue?["view"]?.objectValue?["nodes"]?.arrayValue ?? []) else { throw DesktopBridgeError.permissionDenied }
            return try PrivateBridgeFileLease.write(Data(svg.utf8),filename:"Nodus-figure.svg")
        }
        guard let source = object["source"]?.stringValue, let url = URL(string:source),
              let scheme = url.scheme,["nodus-image","nodus-capability"].contains(scheme),url.host == "chat" else { throw DesktopBridgeError.permissionDenied }
        let components = url.path.split(separator:"/").map(String.init)
        guard components.count == 2,UUID(uuidString:components[1]) != nil else { throw DesktopBridgeError.permissionDenied }
        guard let context=try await CompanionLiveDocumentVisualRead.context(session:session,reportID:id),
              context.objectValue?["manifest"]?.objectValue?["contentHash"] == expected.objectValue?["contentHash"],context.objectValue?["manifest"]?.objectValue?["revision"] == expected.objectValue?["revision"] else { throw APIError(status:409,code:"report_figures_changed",message:"Las figuras cambiaron en el Mac. Actualiza el informe antes de exportarlas.") }
        let content=try await CompanionResearchFigures.load(source,context:context,session:session)
        let ext=content.mime == "image/png" ? "png" : content.mime == "image/webp" ? "webp" : "jpg"
        return try PrivateBridgeFileLease.write(content.data,filename:"Nodus-figure.\(ext)")
    }

    private static func contains(svg:String,nodes:[JSONValue])->Bool {
        nodes.contains { node in node.objectValue?["svg"]?.stringValue == svg || contains(svg:svg,nodes:node.objectValue?["children"]?.arrayValue ?? []) }
    }
}

/// A read-only Mac source, independent of authoring sessions and write grants.
@MainActor enum CompanionLiveDocumentVisualRead {
    struct Chunk { let data:Data; let total:Int; let mime:String; let sha256:String }
    static func context(session:SpaceSession,reportID:String,expectedDraft:JSONValue? = nil) async throws -> JSONValue? {
        guard session.connection.desktopPairingId != nil,!session.isDemo,UUID(uuidString:reportID) != nil else { return nil }
        let (vault,pairing,token) = try privateBridgeConnection(session,domain:.corpus)
        let client=DesktopBridgeClient(pairing:pairing,token:token)
        let draft:JSONValue
        if let expectedDraft { draft=expectedDraft }
        else {
            let saved=try await client.operation(vaultId:vault,method:"getWritingWorkshopDraft",args:[.string(reportID)])
            guard let actual=saved.objectValue?["draft"] else { throw DesktopBridgeError.malformedResponse };draft=actual
        }
        let reply:JSONValue
        do { reply=try await client.operation(vaultId:vault,method:"readMobileDeepResearchVisualAsset",args:[.object(["action":.string("context"),"reportId":.string(reportID),"expectedDraft":draft])]) }
        catch let error as APIError where ["unknown_operation","unknown_method","unsupported_method","invalid_research_visual_asset_read"].contains(error.code ?? "") || error.localizedDescription.contains("invalid_research_visual_asset_read") {
            throw APIError(status:426,code:"report_figure_read_upgrade_required",message:"Actualiza Nodus en el Mac para consultar los recursos visuales. El texto del informe permanece disponible.")
        }
        guard reply.objectValue?["version"] == .int(1),reply.objectValue?["vaultId"] == .string(vault),reply.objectValue?["target"]?.objectValue?["id"] == .string(reportID),reply.objectValue?["target"]?.objectValue?["kind"] == .string("deep-research"),let manifest=reply.objectValue?["manifest"] else { throw APIError(status:426,code:"report_figure_read_upgrade_required",message:"Actualiza Nodus en el Mac para consultar los recursos visuales de este informe.") }
        if manifest == .null { return nil }
        guard manifest.objectValue?["vaultId"] == .string(vault),manifest.objectValue?["target"]?.objectValue?["id"] == .string(reportID),manifest.objectValue?["target"]?.objectValue?["kind"] == .string("deep-research"),manifest.objectValue?["contentHash"]?.stringValue?.count == 64 else { throw DesktopBridgeError.malformedResponse }
        return .object(["origin":.string("live-mac"),"vaultId":.string(vault),"reportId":.string(reportID),"manifest":manifest,"unsupportedOriginals":.array(CompanionDownloadedResearchFigures.unsupportedOriginals(manifest))])
    }
    static func chunk(_ source:String,context:JSONValue,session:SpaceSession,offset:Int64,count:Int) async throws -> Chunk {
        guard session.connection.desktopPairingId != nil,!session.isDemo,offset >= 0,count > 0,count <= 524288,
              CompanionResearchFigures.allows(source,context:context),let object = context.objectValue,object["origin"] == .string("live-mac"),
              let id = object["reportId"]?.stringValue,let manifest = object["manifest"],let url = URL(string:source) else { throw DesktopBridgeError.permissionDenied }
        let (vault,pairing,token) = try privateBridgeConnection(session,domain:.corpus)
        guard object["vaultId"] == .string(vault) else { throw DesktopBridgeError.permissionDenied }
        let parts=url.path.split(separator:"/").map(String.init)
        guard parts.count == 2 else { throw DesktopBridgeError.permissionDenied }
        let input:JSONValue = .object(["reportId":.string(id),"expected":.object(["contentHash":manifest.objectValue?["contentHash"] ?? .null,"revision":manifest.objectValue?["revision"] ?? .null]),"expectedManifest":manifest,"source":.string(source),"owner":.string(parts[0]),"assetId":.string(parts[1]),"offset":.int(offset),"count":.int(Int64(count))])
        let result = try await DesktopBridgeClient(pairing:pairing,token:token).operation(vaultId:vault,method:"readMobileDeepResearchVisualAsset",args:[input])
        return try decode(result,offset:offset,count:count)
    }
    static func decode(_ value:JSONValue,offset:Int64,count:Int) throws -> Chunk {
        guard let fields=value.objectValue,let rawTotal=fields["byteCount"],case .int(let total64)=rawTotal,let total=Int(exactly:total64),total > 0,total <= 8_388_608,
              fields["offset"] == .int(offset),let encoded=fields["base64"]?.stringValue,encoded.utf8.count <= 700_000,
              let data=Data(base64Encoded:encoded),!data.isEmpty,data.count <= count,offset+Int64(data.count) <= total64,
              let mime=fields["mimeType"]?.stringValue,["image/png","image/jpeg","image/webp"].contains(mime),let hash=fields["sha256"]?.stringValue,
              hash.count == 64,hash.allSatisfy({$0.isHexDigit && !$0.isUppercase}) else { throw DesktopBridgeError.malformedResponse }
        return Chunk(data:data,total:total,mime:mime,sha256:hash)
    }
    static func data(_ source:String,context:JSONValue,session:SpaceSession) async throws -> ReaderImageSource.Content {
        try await assemble { offset,count in try await chunk(source,context:context,session:session,offset:offset,count:count) }
    }
    static func assemble(_ read:(Int64,Int)async throws->Chunk) async throws -> ReaderImageSource.Content {
        var bytes=Data(),total=1,mime="",hash=""
        while bytes.count < total {
            try Task.checkCancellation()
            let part=try await read(Int64(bytes.count),524288)
            if bytes.isEmpty { total=part.total;mime=part.mime;hash=part.sha256 }
            guard part.total == total,part.mime == mime,part.sha256 == hash else { throw DesktopBridgeError.malformedResponse }
            bytes.append(part.data)
        }
        guard SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined() == hash else { throw DesktopBridgeError.malformedResponse }
        return .init(data:bytes,mime:mime)
    }
}
