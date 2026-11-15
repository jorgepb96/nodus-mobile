import Foundation
import Testing
@testable import NodusKit

@Suite("Scoped Bridge file downloads")
struct DesktopBridgeFileTests {
    @Test func privateDomainsStaySeparate() {
        #expect(DesktopBridgeFileKind.studyMaterial.domain == .corpus)
        #expect(DesktopBridgeFileKind.studyRecording.domain == .studyRecordings)
        #expect(DesktopBridgeFileKind.testimonyMedia.domain == .testimonies)
        #expect(DesktopBridgeFileKind.archiveFile.domain == .primarySourceFiles)
        #expect(DesktopBridgeFileKind.libraryOriginal.domain == .corpus)
        #expect(DesktopBridgeFileKind.libraryAttachment.domain == .corpus)
        #expect(DesktopBridgeFileKind.audioClip.domain == .corpus)
    }
    @Test func attachmentIdentityRetainsOpaqueCharactersWithoutSelectingAPath() throws {
        let encoded = try DesktopLibraryAttachmentIdentity.encode(documentId: "nodus:source#1", attachmentId: "attachment:one/two")
        #expect(try JSONDecoder().decode([String].self, from: Data(encoded.utf8)) == ["nodus:source#1", "attachment:one/two"])
        #expect(throws: DesktopBridgeError.self) { try DesktopLibraryAttachmentIdentity.encode(documentId: "", attachmentId: "one") }
    }
    @Test func untrustedDescriptorsCannotEscapeOrAllocateInvalidChunks() throws {
        let hash = String(repeating: "a", count: 64)
        for (name, size, chunk, sha) in [("../private.key", 50, 1024, hash), ("source.bin", -1, 1024, hash), ("source.bin", 10, 0, hash), ("source.bin", 10, 8_388_608, hash), ("source.bin", 10, 1024, "unknown")] {
            let file = DesktopBridgeFileDescriptor(kind: .archiveFile, id: "opaque", filename: name, mime: "application/octet-stream", byteSize: size, sha256: sha, chunkSize: chunk)
            #expect(throws: DesktopBridgeError.self) { try file.validate() }
        }
    }
    @Test func largeFilesRetainFullSize() throws {
        let file = DesktopBridgeFileDescriptor(kind: .studyRecording, id: "opaque", filename: "recording.m4a", mime: "audio/mp4", byteSize: 1_073_741_824, sha256: String(repeating: "a", count: 64), chunkSize: 4_194_304)
        try file.validate()
        #expect(file.byteSize == 1_073_741_824)
    }
    @Test func corpusPermissionCannotReadAudio() async throws {
        let pairing = try DesktopBridgePairing(id: "grant", origin: "https://localhost:1", certificateFingerprint: String(repeating: "a", count: 64), deviceId: "Mac", deviceName: "Mac", vaultIds: ["vault"], domains: [.corpus], pairedAt: Date(), expiresAt: nil)
        let client = DesktopBridgeClient(pairing: pairing, token: "unused")
        await #expect(throws: DesktopBridgeError.permissionDenied) {
            try await client.fileDescriptor(vaultId: "vault", kind: .studyRecording, id: "opaque")
        }
    }
}
