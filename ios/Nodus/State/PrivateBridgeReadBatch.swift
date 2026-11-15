import Foundation
import NodusKit

/// A paginated consultation tries the Mac once after losing its transport.
/// Subsequent pages in this batch use the same local source policy, rather than
/// spending a separate connection timeout on every cached page.
@MainActor final class PrivateBridgeReadBatch {
    private let session:SpaceSession
    private let downloadedOnly:Bool
    private var offline=false
    init(session:SpaceSession,downloadedOnly:Bool=false){self.session=session;self.downloadedOnly=downloadedOnly}
    func operation(_ method:String,_ args:[JSONValue]) async throws -> JSONValue {
        guard ["getMobilePageDocument","getMobileSyncedBlockSource","getMobileLinkedDatabaseRead"].contains(method) else {throw DesktopBridgeError.permissionDenied}
        let (vault,pairing,token)=try privateBridgeConnection(session,domain:.corpus)
        guard !pairing.isExpired else {throw DesktopBridgeError.expired}
        let cache=try PrivateBridgeCache(pairingId:pairing.id),key=try CompanionDocumentOutbox.operationKey(method,args)
        func local() async throws -> JSONValue {
            let bytes:Data?
            if downloadedOnly {bytes=try await cache.downloadedData(vaultId:vault,domain:.corpus,recordId:key).first}
            else {bytes=try await cache.data(vaultId:vault,domain:.corpus,recordId:key)}
            guard let bytes else {throw APIError(status:409,code:"page_content_not_downloaded",message:"Falta una parte de esta vista en el dispositivo. Actualiza su descarga cuando Nodus esté conectado.")}
            return try JSONDecoder.nodus.decode(JSONValue.self,from:bytes)
        }
        if downloadedOnly || offline {return try await local()}
        do {
            let source=try await DesktopBridgeClient(pairing:pairing,token:token).operation(vaultId:vault,method:method,args:args)
            try await cache.store(JSONEncoder.nodus.encode(source),vaultId:vault,domain:.corpus,recordId:key);return source
        }catch{
            guard isPrivateBridgeOffline(error) else {throw error};offline=true
            return try await local()
        }
    }
}
