import CryptoKit
import Foundation

public extension CompanionGenerationPublication {
    /// Retain the exact paid result alongside its provider-free publication.
    /// A large image points to authenticated staged chunks; the original bytes
    /// stay in the checkpoint for offline reading and grant recovery.
    init?(databaseAction checkpoint: CompanionDatabaseActionCheckpoint, stagedImage: JSONValue? = nil) throws {
        guard var input = checkpoint.publicationInput?.objectValue else { return nil }
        if let stagedImage {
            guard input["request"]?.objectValue?["kind"] == .string("image"), let fields = stagedImage.objectValue,
                  Set(fields.keys) == ["blobUploadId", "sha256", "mimeType"],
                  fields["blobUploadId"]?.stringValue?.lowercased() == checkpoint.id.lowercased(),
                  fields["mimeType"] == input["mime"], let encoded = input["bytes"]?.stringValue, let bytes = Data(base64Encoded: encoded),
                  fields["sha256"] == .string(SHA256.hash(data: bytes).map {String(format: "%02x", $0)}.joined()) else { throw DesktopBridgeError.malformedResponse }
            input["bytes"] = nil; input["blobUploadId"] = fields["blobUploadId"]; input["sha256"] = fields["sha256"]
        }
        id = checkpoint.id; recordId = checkpoint.scope
        method = input["request"]?.objectValue?["kind"] == .string("button") ? "saveMobileDatabaseButtonResult" : "saveMobileDatabaseGeneratedCell"
        args = [.object(input)]; self.checkpoint = checkpoint.value
    }
}
