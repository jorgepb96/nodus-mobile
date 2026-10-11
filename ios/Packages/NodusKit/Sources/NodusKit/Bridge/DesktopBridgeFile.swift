import CryptoKit
import Foundation

public enum DesktopBridgeFileKind: String, Codable, Sendable {
    case studyMaterial, studyMaterialVersion, studyRecording, testimonyMedia, archiveItem, archiveFile
    case libraryOriginal, libraryAttachment, audioClip, corpusImage, chatCapability, databaseAttachment, pageAsset
    public var domain: DesktopBridgeDomain {
        switch self {
        case .studyMaterial, .studyMaterialVersion, .libraryOriginal, .libraryAttachment, .audioClip, .corpusImage, .chatCapability, .databaseAttachment, .pageAsset: .corpus
        case .studyRecording: .studyRecordings
        case .testimonyMedia: .testimonies
        case .archiveItem, .archiveFile: .primarySourceFiles
        }
    }
}

public enum DesktopLibraryAttachmentIdentity {
    public static func encode(documentId: String, attachmentId: String) throws -> String {
        guard !documentId.isEmpty, !attachmentId.isEmpty else { throw DesktopBridgeError.malformedResponse }
        return String(decoding: try JSONEncoder().encode([documentId, attachmentId]), as: UTF8.self)
    }
}

public struct DesktopBridgeFileDescriptor: Codable, Sendable, Equatable {
    public let kind: DesktopBridgeFileKind
    public let id: String
    public let filename: String
    public let mime: String
    public let byteSize: Int
    public let sha256: String
    public let chunkSize: Int
    public var requiredDomains: [DesktopBridgeDomain]? = nil
    func validate() throws {
        guard !id.isEmpty, byteSize >= 0, chunkSize > 0, chunkSize <= 4 * 1024 * 1024,
              sha256.count == 64, sha256.allSatisfy(\.isHexDigit),
              !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\") else { throw DesktopBridgeError.malformedResponse }
    }
}

extension DesktopBridgeClient {
    public func fileDescriptor(vaultId: String, kind: DesktopBridgeFileKind, id: String, timeout: TimeInterval? = nil) async throws -> DesktopBridgeFileDescriptor {
        let response = try await fileRequest(vaultId: vaultId, kind: kind, id: id, action: "descriptor", timeout: timeout)
        let descriptor = try JSONDecoder.nodus.decode(DesktopBridgeFileDescriptor.self, from: response.data)
        try descriptor.validate()
        guard descriptor.kind == kind, descriptor.id == id else { throw DesktopBridgeError.malformedResponse }
        return descriptor
    }
    public func fileData(vaultId: String, descriptor: DesktopBridgeFileDescriptor) async throws -> Data {
        try descriptor.validate()
        var result = Data()
        while result.count < descriptor.byteSize {
            try Task.checkCancellation()
            let size = min(descriptor.chunkSize, descriptor.byteSize - result.count)
            let response = try await fileRequest(vaultId: vaultId, kind: descriptor.kind, id: descriptor.id, action: "content",
                query: [URLQueryItem(name: "offset", value: String(result.count)), URLQueryItem(name: "limit", value: String(size))])
            guard response.data.count == size, response.headers["x-nodus-file-offset"] == String(result.count),
                  response.headers["x-nodus-file-size"] == String(descriptor.byteSize) else { throw DesktopBridgeError.malformedResponse }
            result.append(response.data)
        }
        guard SHA256.hash(data: result).map({ String(format: "%02x", $0) }).joined() == descriptor.sha256.lowercased() else { throw DesktopBridgeError.malformedResponse }
        return result
    }
}
