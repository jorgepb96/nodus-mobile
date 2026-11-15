import CryptoKit
import NodusKit
import XCTest

/// Read-only diagnostics for an actual isolated simulator grant. Only entry
/// names, shapes, sizes and hashes become evidence; no contents or secrets do.
final class LegacySurfaceStorageDiagnosticsTests: XCTestCase {
    @MainActor
    func testReadOnlyLegacySurfaceStorageMetadata() async throws {
        let env = ProcessInfo.processInfo.environment
        let id = try XCTUnwrap(env["NODUS_ACCEPTANCE_DIAGNOSTIC_GRANT"])
        let pin = try XCTUnwrap(env["NODUS_ACCEPTANCE_DIAGNOSTIC_PIN"])
        let grant = try XCTUnwrap(DesktopBridgePairingStore().pairings().first { $0.id == id })
        XCTAssertEqual(grant.certificateFingerprint, pin)
        let cache = try PrivateBridgeCache(pairingId: id)
        var rows = [[String: Any]]()
        for vault in grant.vaultIds.sorted() {
            guard let data = try await cache.data(vaultId: vault, domain: .writing, recordId: "surface-storage:v1") else { continue }
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: String])
            let entries = object.keys.sorted().map { key -> [String: Any] in
                let bytes = Data(object[key]!.utf8)
                var row: [String: Any] = ["key": key, "bytes": bytes.count,
                    "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
                if let nested = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                    row["nestedKeys"] = nested.keys.sorted()
                }
                return row
            }
            rows.append(["vaultId": vault, "bytes": data.count, "entries": entries])
        }
        XCTAssertFalse(rows.isEmpty, "The actual legacy storage that blocked linking must be present.")
        let output = try JSONSerialization.data(withJSONObject: ["grantId": id, "readOnly": true, "rows": rows], options: [.sortedKeys])
        let metadata = try XCTUnwrap(String(data: output, encoding: .utf8))
        print("NODUS_LEGACY_SURFACE_METADATA=" + metadata)
        let attachment = XCTAttachment(string: metadata); attachment.name = "legacy-surface-storage-readonly-metadata"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
