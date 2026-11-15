import CryptoKit
import Foundation
import NodusKit

/// Read-pack metadata and bounded encrypted chunks, never authored generations.
@MainActor enum CompanionDownloadedResearchFigures {
    static func unsupportedOriginals(_ manifest:JSONValue)->[JSONValue] {
        var sources=Set<String>()
        func visit(_ nodes:[JSONValue],owner:String) { for node in nodes { if let id=node.objectValue?["attachmentId"]?.stringValue,node.objectValue?["kind"] != .string("image") { sources.insert("nodus-capability://chat/\(owner)/\(id)") };visit(node.objectValue?["children"]?.arrayValue ?? [],owner:owner) } }
        for figure in manifest.objectValue?["figures"]?.arrayValue ?? [] { if let owner=figure.objectValue?["owner"]?.stringValue { visit(figure.objectValue?["view"]?.objectValue?["nodes"]?.arrayValue ?? [],owner:owner) } }
        return sources.sorted().map(JSONValue.string)
    }
    static func draftHash(_ draft:JSONValue) throws -> String { SHA256.hash(data:try JSONEncoder.nodus.encode(draft)).map{String(format:"%02x",$0)}.joined() }
    static func source(session:SpaceSession,reportID:String) async throws -> CompanionResearchCorpusCopy.SelectedReportSource {
        let scope=try session.surfaceStorageScope(),cache=try PrivateBridgeCache(pairingId:scope.cacheId)
        guard let copy=try await CompanionResearchCorpusCopy.downloaded(cache:cache,vaultId:scope.recordVaultId),let source=try copy.selectedReportSource(reportID:reportID) else { throw APIError(status:404,code:"report_not_downloaded",message:"Este informe no está incluido en la copia elegida.") }
        return source
    }
    static func context(session:SpaceSession,reportID:String,expectedDraft:JSONValue? = nil) async throws -> JSONValue? {
        let scope=try session.surfaceStorageScope(),cache=try PrivateBridgeCache(pairingId:scope.cacheId)
        guard let copy=try await CompanionResearchCorpusCopy.downloaded(cache:cache,vaultId:scope.recordVaultId),
              let context=try copy.figureContext(reportID:reportID) else { throw APIError(status:404,code:"report_figures_not_downloaded",message:"Esta descarga no conserva los recursos visuales del informe. Actualiza la copia elegida desde el Mac.") }
        guard context.objectValue?["origin"] == .string("downloaded-mac"),context.objectValue?["vaultId"] == .string(scope.recordVaultId),context.objectValue?["reportId"] == .string(reportID) else { throw DesktopBridgeError.malformedResponse }
        if let expectedDraft { guard context.objectValue?["draftHash"] == .string(try draftHash(expectedDraft)) else { throw APIError(status:409,code:"report_figure_prose_conflict",message:"Las figuras descargadas pertenecen a otra versión del informe. Abre la copia elegida o actualízala.") } }
        return context.objectValue?["manifest"] == .null ? nil : context
    }
    static func capture(session:SpaceSession,reportID:String,manifest:JSONValue,draft:JSONValue,remaining:Int) async throws -> (context:JSONValue,records:[PrivateBridgeCache.ReadPackRecord],bytes:Int) {
        let scope=try session.surfaceStorageScope()
        if manifest != .null { guard manifest.objectValue?["vaultId"] == .string(scope.recordVaultId),manifest.objectValue?["target"]?.objectValue?["id"] == .string(reportID),manifest.objectValue?["target"]?.objectValue?["kind"] == .string("deep-research") else { throw DesktopBridgeError.malformedResponse } }
        let remote:JSONValue = .object(["origin":.string("live-mac"),"vaultId":.string(scope.recordVaultId),"reportId":.string(reportID),"manifest":manifest])
        var sources=Set<String>()
        func visit(_ nodes:[JSONValue],owner:String) { for node in nodes { if node.objectValue?["kind"] == .string("image"),let id=node.objectValue?["attachmentId"]?.stringValue { sources.insert("nodus-capability://chat/\(owner)/\(id)") };visit(node.objectValue?["children"]?.arrayValue ?? [],owner:owner) } }
        for item in manifest.objectValue?["figures"]?.arrayValue ?? [] where item.objectValue?["state"] == .string("ready") {
            guard let figure=item.objectValue,let owner=figure["owner"]?.stringValue else { continue }
            if let poster=figure["poster"]?.stringValue,poster.hasPrefix("nodus-image://") { sources.insert(poster) }
            visit(figure["view"]?.objectValue?["nodes"]?.arrayValue ?? [],owner:owner)
        }
        var assets:[JSONValue]=[],records:[PrivateBridgeCache.ReadPackRecord]=[],used=0
        for source in sources.sorted() {
            try Task.checkCancellation()
            let first=try await CompanionLiveDocumentVisualRead.chunk(source,context:remote,session:session,offset:0,count:524288)
            guard first.total <= remaining-used else { throw PrivateBridgeCache.ReadPackError.perDownloadLimit }
            let identity=SHA256.hash(data:Data("\(scope.recordVaultId):\(reportID):\(source):\(first.sha256)".utf8)).map{String(format:"%02x",$0)}.joined()
            var offset=0,index=0,part=first,keys:[JSONValue]=[],hash=SHA256()
            while offset < first.total {
                try Task.checkCancellation()
                guard part.total == first.total,part.mime == first.mime,part.sha256 == first.sha256 else { throw DesktopBridgeError.malformedResponse }
                let key="companion:report-figure:v1:\(identity):\(index)"
                records.append(.init(domain:.corpus,recordId:key,data:part.data));keys.append(.string(key));used += part.data.count;hash.update(data:part.data);offset += part.data.count;index += 1
                if offset < first.total { part=try await CompanionLiveDocumentVisualRead.chunk(source,context:remote,session:session,offset:Int64(offset),count:524288) }
            }
            guard hash.finalize().map({String(format:"%02x",$0)}).joined() == first.sha256 else { throw DesktopBridgeError.malformedResponse }
            assets.append(.object(["source":.string(source),"mimeType":.string(first.mime),"byteCount":.int(Int64(first.total)),"sha256":.string(first.sha256),"chunks":.array(keys)]))
        }
        let value:JSONValue = .object(["origin":.string("downloaded-mac"),"vaultId":.string(scope.recordVaultId),"reportId":.string(reportID),"manifest":manifest,"draftHash":.string(try draftHash(draft)),"unsupportedOriginals":.array(unsupportedOriginals(manifest)),"assets":.array(assets)])
        return (value,records,used)
    }
    static func chunk(_ source:String,context:JSONValue,session:SpaceSession,offset:Int64,count:Int) async throws -> CompanionLiveDocumentVisualRead.Chunk {
        guard context.objectValue?["origin"] == .string("downloaded-mac"),CompanionResearchFigures.allows(source,context:context),offset >= 0,count > 0,count <= 524288,
              let asset=context.objectValue?["assets"]?.arrayValue?.first(where:{$0.objectValue?["source"] == .string(source)})?.objectValue,
              let rawTotal=asset["byteCount"],case .int(let total64)=rawTotal,let total=Int(exactly:total64),total > 0,total <= 8_388_608,offset < total64,
              let keys=asset["chunks"]?.arrayValue,keys.count == (total+524287)/524288,let mime=asset["mimeType"]?.stringValue,let hash=asset["sha256"]?.stringValue else { throw DesktopBridgeError.permissionDenied }
        let scope=try session.surfaceStorageScope();guard context.objectValue?["vaultId"] == .string(scope.recordVaultId) else { throw DesktopBridgeError.permissionDenied }
        let index=Int(offset/524288),within=Int(offset%524288)
        guard let key=keys[index].stringValue,key.hasPrefix("companion:report-figure:v1:") else { throw DesktopBridgeError.malformedResponse }
        let cache=try PrivateBridgeCache(pairingId:scope.cacheId)
        guard let bytes=try await cache.downloadedData(vaultId:scope.recordVaultId,domain:.corpus,recordId:key).first,bytes.count == min(524288,total-index*524288),within < bytes.count else { throw APIError(status:404,code:"report_figure_chunk_not_downloaded",message:"Falta una parte de la figura en esta descarga. Actualiza la copia elegida.") }
        return .init(data:bytes.subdata(in:within..<min(bytes.count,within+count)),total:total,mime:mime,sha256:hash)
    }
    static func data(_ source:String,context:JSONValue,session:SpaceSession) async throws -> ReaderImageSource.Content {
        try await CompanionLiveDocumentVisualRead.assemble { offset,count in try await chunk(source,context:context,session:session,offset:offset,count:count) }
    }
}
