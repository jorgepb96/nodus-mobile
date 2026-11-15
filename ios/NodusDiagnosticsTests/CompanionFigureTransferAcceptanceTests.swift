import CryptoKit
import Foundation
import NodusKit
import XCTest

/// Opt-in writes to an explicitly paired COPIED acceptance vault. The runner
/// validates its lab marker and supplies identity metadata, never a bearer.
/// This exercises the production pinned HTTPS client, including its capability
/// preflight. Direct calls to the SQLite upload function do not cover that path.
final class CompanionFigureTransferAcceptanceTests: XCTestCase {
    private enum SetupError: Error { case isolatedAcceptanceRequired }

    @MainActor
    func testPinnedHTTPSUploadCommitsAndReplaysWithoutDuplicatingTheAsset() async throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard env["NODUS_ACCEPTANCE_FIGURE_HTTP"] == "1" else {
            XCTFail("Explicit copied-lab figure-transfer acceptance is required.")
            throw SetupError.isolatedAcceptanceRequired
        }
        let grantID = try XCTUnwrap(env["NODUS_ACCEPTANCE_DIAGNOSTIC_GRANT"])
        let pin = try XCTUnwrap(env["NODUS_ACCEPTANCE_DIAGNOSTIC_PIN"])
        let macID = try XCTUnwrap(env["NODUS_ACCEPTANCE_DIAGNOSTIC_MAC"])
        let vault = try XCTUnwrap(env["NODUS_ACCEPTANCE_FIGURE_VAULT"])
        let store = DesktopBridgePairingStore()
        let grant = try XCTUnwrap(store.pairings().first { $0.id == grantID })
        XCTAssertEqual(grant.certificateFingerprint, pin)
        XCTAssertEqual(grant.macDeviceId, macID)
        XCTAssertTrue(grant.vaultIds.contains(vault))
        guard grant.certificateFingerprint == pin, grant.macDeviceId == macID,
              grant.vaultIds.contains(vault) else { throw SetupError.isolatedAcceptanceRequired }
        let token = try XCTUnwrap(store.credential(for: grant))
        let client = DesktopBridgeClient(pairing: grant, token: token)
        let capabilities = try await client.liveCapabilities()
        XCTAssertEqual(capabilities.deviceId, macID)
        let target = UUID().uuidString.lowercased(), figure = UUID().uuidString.lowercased()
        let revision = UUID().uuidString.lowercased(), asset = UUID()
        let identity = try JSONEncoder.nodus.encode(["document-figure", vault, "deep-research:\(target):\(revision):\(figure)"])
        let owner = digest(identity)
        let bytes = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGwoAAAAASUVORK5CYII="))
        let manifest: JSONValue = .object([
            "version": .int(1), "id": .string(asset.uuidString.lowercased()), "vaultId": .string(vault),
            "generationId": .string(target), "figureId": .string(figure), "ownerRevision": .string(revision),
            "owner": .string(owner), "mimeType": .string("image/png"), "byteCount": .int(Int64(bytes.count)),
            "sha256": .string(digest(bytes)), "metadata": .object(["title": .string("Isolated HTTP acceptance")])
        ])
        let begun = try await client.researchFigureUpload(vaultId: vault, uploadId: asset, action: "begin", body: .object(["manifest": manifest]))
        XCTAssertEqual(begun.objectValue?["state"], .string("pending"))
        _ = try await client.researchFigureUpload(vaultId: vault, uploadId: asset, action: "chunk", body: .object([
            "index": .int(0), "bytes": .string(bytes.base64EncodedString()), "sha256": .string(digest(bytes))
        ]))
        let committed = try await client.researchFigureUpload(vaultId: vault, uploadId: asset, action: "commit", body: .object([:]))
        XCTAssertEqual(committed.objectValue?["state"], .string("available"))
        XCTAssertEqual(committed.objectValue?["receipt"], manifest)
        let replay = try await client.researchFigureUpload(vaultId: vault, uploadId: asset, action: "begin", body: .object(["manifest": manifest]))
        XCTAssertEqual(replay.objectValue?["state"], .string("available"))
        XCTAssertEqual(replay.objectValue?["receipt"], manifest)
        let receipt = try JSONEncoder.nodus.encode(.object([
            "assetId": .string(asset.uuidString.lowercased()), "targetId": .string(target), "vaultId": .string(vault),
            "sha256": .string(digest(bytes)), "bytes": .int(Int64(bytes.count)),
            "transport": .string("pinned-https"), "providerCalls": .int(0)
        ]) as JSONValue)
        let attachment = XCTAttachment(data: receipt, uniformTypeIdentifier: "public.json")
        attachment.name = "actual-figure-http-receipt.json"; attachment.lifetime = .keepAlways; add(attachment)
        // The final runner independently checks the copied SQLite receipt and
        // actual image bytes using this ID. HTTP ACK alone is not that oracle.
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
