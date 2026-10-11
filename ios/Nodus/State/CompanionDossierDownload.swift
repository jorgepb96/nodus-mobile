import Foundation
import NodusKit

@MainActor
enum CompanionDossierDownload {
    /// Prepare every selected resource before committing the owning read pack.
    /// Descriptor size is checked before requesting bytes. No download expands
    /// into an entire vault, starts extraction, or commits a partial success.
    static func records(client: DesktopBridgeClient, vault: String, domains: Set<DesktopBridgeDomain>,
                        collection: String, id: String, detail: JSONValue, images: Bool, files: Bool,
                        existing: Set<String>, maximumBytes: Int, fileCatalogue: JSONValue? = nil) async throws -> [PrivateBridgeCache.ReadPackRecord] {
        var output: [PrivateBridgeCache.ReadPackRecord] = [], seen = existing, used = 0
        func append(_ domain: DesktopBridgeDomain, _ key: String, _ data: Data) throws {
            guard !seen.contains(key) else { return }
            guard data.count <= maximumBytes - used else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            seen.insert(key); used += data.count; output.append(.init(domain: domain, recordId: key, data: data))
        }
        func descriptor(_ kind: DesktopBridgeFileKind, _ id: String, encoded: Bool = false) async throws -> DesktopBridgeFileDescriptor {
            guard domains.contains(.corpus), domains.contains(kind.domain) else { throw DesktopBridgeError.permissionDenied }
            let value = try await client.fileDescriptor(vaultId: vault, kind: kind, id: id)
            guard Set(value.requiredDomains ?? []).isSubset(of: domains) else { throw DesktopBridgeError.permissionDenied }
            // Codable Data uses base64. Reserve its actual upper bound before
            // loading an original, including a bounded metadata allowance.
            let size = value.byteSize
            guard size >= 0, size <= maximumBytes - used,
                  !encoded || (size <= CompanionEmbeddedResource.maximumBytes && ((size + 2) / 3) * 4 + 32_768 <= maximumBytes - used) else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            return value
        }
        if CompanionDossierResources.fileCollections.contains(collection), collection != "archive-items" || domains.contains(.primarySourceFiles) || files {
            let args = CompanionDossierResources.arguments(collection: collection, id: id)
            let value: JSONValue
            if let fileCatalogue { value = fileCatalogue }
            else { value = try await client.operation(vaultId: vault, method: "getMobileDossierFiles", args: args) }
            let catalog = try CompanionDossierResources(value: value, collection: collection, id: id)
            try append(.corpus, CompanionDocumentOutbox.operationKey("getMobileDossierFiles", args), JSONEncoder.nodus.encode(value))
            if let reader = catalog.reader { try append(.corpus, CompanionDocumentOutbox.operationKey("getLibraryReaderDocument", [.string(id)]), JSONEncoder.nodus.encode(reader)) }
            if files || images {
                for file in catalog.files where file.available && (files || file.mime == nil || file.mime?.lowercased().hasPrefix("image/") == true) {
                    try Task.checkCancellation()
                    let key = "file:\(file.kind.rawValue):\(file.fileId)"
                    guard !seen.contains(key) else { continue }
                    let info = try await descriptor(file.kind, file.fileId)
                    if !files && !info.mime.lowercased().hasPrefix("image/") { continue }
                    let metadata = try JSONEncoder.nodus.encode(info)
                    guard metadata.count + info.byteSize <= maximumBytes - used else { throw PrivateBridgeCache.ReadPackError.tooLarge }
                    let data = try await client.fileData(vaultId: vault, descriptor: info)
                    try append(file.kind.domain, key, metadata)
                    try append(file.kind.domain, "\(key):\(info.sha256)", data)
                }
            }
        }
        if images {
            for source in try CompanionDossierResources.imageSources(collection: collection, id: id, detail: detail) {
                try Task.checkCancellation()
                let key = CompanionCorpusImage.recordId(source: source)
                guard !seen.contains(key) else { continue }
                let info = try await descriptor(.corpusImage, source, encoded: true)
                let data = try await client.fileData(vaultId: vault, descriptor: info)
                let image = try CompanionCorpusImage(descriptor: info, data: data)
                try image.validate(source: source, domains: Array(domains))
                try append(.corpus, key, JSONEncoder.nodus.encode(image))
            }
        }
        if files {
            for source in try CompanionEmbeddedResource.sourceURLs(in: detail) {
                try Task.checkCancellation()
                let key = CompanionEmbeddedResource.recordId(source: source)
                guard !seen.contains(key) else { continue }
                let identity = try CompanionEmbeddedResource.identity(source)
                let info = try await descriptor(identity.kind, identity.id, encoded: true)
                let data = try await client.fileData(vaultId: vault, descriptor: info)
                let resource = try CompanionEmbeddedResource(source: source, descriptor: info, data: data, domains: Array(domains))
                try append(.corpus, key, JSONEncoder.nodus.encode(resource))
            }
        }
        return output
    }
}
