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
            guard manifest.objectValue?["revision"] == expected.objectValue?["revision"],
                  let entry = manifest.objectValue?["figures"]?.arrayValue?.first(where:{$0.objectValue?["id"]?.stringValue == figure}),
                  contains(svg:svg,nodes:entry.objectValue?["view"]?.objectValue?["nodes"]?.arrayValue ?? []) else { throw DesktopBridgeError.permissionDenied }
            return try PrivateBridgeFileLease.write(Data(svg.utf8),filename:"Nodus-figure.svg")
        }
        guard let source = object["source"]?.stringValue, let url = URL(string:source),
              let scheme = url.scheme,["nodus-image","nodus-capability"].contains(scheme),url.host == "chat" else { throw DesktopBridgeError.permissionDenied }
        let components = url.path.split(separator:"/").map(String.init)
        guard components.count == 2,UUID(uuidString:components[1]) != nil else { throw DesktopBridgeError.permissionDenied }
        var bytes = Data(), total = 1, mime = "", hash = ""
        while bytes.count < total {
            try Task.checkCancellation()
            let part = try await client.operation(vaultId:vault,method:"readMobileDeepResearchVisualAsset",args:[.object(["reportId":.string(id),"expected":expected,"owner":.string(components[0]),"assetId":.string(components[1]),"offset":.int(Int64(bytes.count)),"count":.int(524288)])])
            guard let fields = part.objectValue, let count = fields["byteCount"]?.intValue,count > 0,count <= 8_388_608,
                  fields["offset"]?.intValue == bytes.count,let encoded = fields["base64"]?.stringValue,encoded.utf8.count <= 700_000,
                  let chunk = Data(base64Encoded:encoded),!chunk.isEmpty,bytes.count + chunk.count <= count,
                  let actualMime = fields["mimeType"]?.stringValue,["image/png","image/jpeg","image/webp"].contains(actualMime),let actualHash = fields["sha256"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
            if bytes.isEmpty { total=count;mime=actualMime;hash=actualHash }
            guard count == total,mime == actualMime,hash == actualHash else { throw DesktopBridgeError.malformedResponse }
            bytes.append(chunk)
        }
        guard SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined() == hash else { throw DesktopBridgeError.malformedResponse }
        let ext = mime == "image/png" ? "png" : mime == "image/webp" ? "webp" : "jpg"
        return try PrivateBridgeFileLease.write(bytes,filename:"Nodus-figure.\(ext)")
    }
    private static func contains(svg:String,nodes:[JSONValue])->Bool {
        nodes.contains { node in node.objectValue?["svg"]?.stringValue == svg || contains(svg:svg,nodes:node.objectValue?["children"]?.arrayValue ?? []) }
    }
}
