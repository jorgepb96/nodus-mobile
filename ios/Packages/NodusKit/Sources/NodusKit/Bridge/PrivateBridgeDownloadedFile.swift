import CryptoKit
import Foundation

/// Resolves only independently selected file copies. Has no transport dependency.
public enum PrivateBridgeDownloadedFile {
    public enum ReadError: Error, LocalizedError {
        case notDownloaded
        public var errorDescription: String? { "Esta versión del archivo no está descargada en este dispositivo." }
    }
    public struct Copy: Sendable {
        public let descriptor: DesktopBridgeFileDescriptor
        public let data: Data
    }
    public static func load(cache: PrivateBridgeCache, vaultId: String, kind: DesktopBridgeFileKind,
                            id: String, selectedFile: DesktopBridgeFileDescriptor? = nil) async throws -> Copy {
        let key = "file:\(kind.rawValue):\(id)"
        let copies = try await cache.downloadedData(vaultId: vaultId, domain: kind.domain, recordId: key)
        let metadata = copies.first { bytes in
            selectedFile == nil || (try? JSONDecoder.nodus.decode(DesktopBridgeFileDescriptor.self, from: bytes)) == selectedFile
        }
        guard let metadata else { throw ReadError.notDownloaded }
        let file = try JSONDecoder.nodus.decode(DesktopBridgeFileDescriptor.self, from: metadata)
        try file.validate()
        guard file.kind == kind, file.id == id, file.byteSize <= PrivateBridgeCache.defaultReadLimitBytes,
              let data = try await cache.downloadedData(vaultId: vaultId, domain: kind.domain, recordId: "\(key):\(file.sha256)").first,
              data.count == file.byteSize, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.sha256.lowercased()
        else { throw DesktopBridgeError.malformedResponse }
        return Copy(descriptor: file, data: data)
    }
}
