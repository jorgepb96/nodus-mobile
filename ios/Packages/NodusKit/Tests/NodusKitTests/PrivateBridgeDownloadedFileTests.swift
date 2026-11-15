import CryptoKit
import Foundation
import Testing
@testable import NodusKit

@Suite("Exact selected file versions")
struct PrivateBridgeDownloadedFileTests {
    @Test("opening an older chosen file does not substitute another pack or reusable copy")
    func exactVersion() async throws {
        let root=URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let keychain=KeychainStore(service:"selected-files-\(UUID().uuidString)")
        let pairing=UUID().uuidString
        defer { try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId:pairing)) }
        let cache=try PrivateBridgeCache(pairingId:pairing,directory:root,keychain:keychain)
        let older=Data("Chosen earlier archive version".utf8),newer=Data("Changed source on Mac".utf8)
        func descriptor(_ bytes:Data) -> DesktopBridgeFileDescriptor {
            DesktopBridgeFileDescriptor(kind:.archiveFile,id:"same-file",filename:"source.txt",mime:"text/plain",byteSize:bytes.count,sha256:SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined(),chunkSize:1024)
        }
        let old=descriptor(older),new=descriptor(newer),key="file:archiveFile:same-file"
        func records(_ file:DesktopBridgeFileDescriptor,_ data:Data) throws -> [PrivateBridgeCache.ReadPackRecord] {
            [.init(domain:.primarySourceFiles,recordId:key,data:try JSONEncoder.nodus.encode(file)),.init(domain:.primarySourceFiles,recordId:"\(key):\(file.sha256)",data:data)]
        }
        let first=try await cache.saveReadPack(vaultId:"archive",title:"Earlier",expiresAt:.distantFuture,records:records(old,older),primaryFile:old)
        _ = try await cache.saveReadPack(vaultId:"archive",title:"Later",expiresAt:.distantFuture,records:records(new,newer),primaryFile:new)
        let chosen=try await PrivateBridgeDownloadedFile.load(cache:cache,vaultId:"archive",kind:.archiveFile,id:"same-file",selectedFile:old)
        #expect(chosen.descriptor == old)
        #expect(chosen.data == older)
        let latest=try await PrivateBridgeDownloadedFile.load(cache:cache,vaultId:"archive",kind:.archiveFile,id:"same-file",selectedFile:new)
        #expect(latest.data == newer)
        await #expect(throws:PrivateBridgeDownloadedFile.ReadError.notDownloaded) { try await PrivateBridgeDownloadedFile.load(cache:cache,vaultId:"another",kind:.archiveFile,id:"same-file",selectedFile:old) }
        try await cache.removeReadPack(id:first.id,vaultId:"archive")
        _ = try await cache.store(try JSONEncoder.nodus.encode(old),vaultId:"archive",domain:.primarySourceFiles,recordId:key)
        _ = try await cache.store(older,vaultId:"archive",domain:.primarySourceFiles,recordId:"\(key):\(old.sha256)")
        await #expect(throws:PrivateBridgeDownloadedFile.ReadError.notDownloaded) { try await PrivateBridgeDownloadedFile.load(cache:cache,vaultId:"archive",kind:.archiveFile,id:"same-file",selectedFile:old) }
        #expect(try await PrivateBridgeDownloadedFile.load(cache:cache,vaultId:"archive",kind:.archiveFile,id:"same-file",selectedFile:new).data == newer)
    }
}
