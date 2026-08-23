import Foundation
import Testing
@testable import NodusKit

@Suite("Parity transport contracts")
struct ParityTransportTests {
    @Test("the generated mutation registry is complete and excludes private domains")
    func generatedRegistry() {
        #expect(MutableTable.allCases.count >= 91)
        #expect(MutableTable(rawValue: "pages") == .pages)
        #expect(MutableTable(rawValue: "world_images") == .worldImages)
        #expect(MutableTable(rawValue: "world_scene_text") == .worldSceneText)
        #expect(MutableTable(rawValue: "teaching_students") == nil)
        #expect(MutableTable(rawValue: "testimony_interviews") == nil)
    }

    @Test("new capabilities decode without turning the Bridge into a cloud relay")
    func capabilities() throws {
        let json = """
        {
          "api":"v1","version":"4.3.0",
          "server":{"name":"Nodus Cloud","publicUrl":"https://example.org","language":"es","version":"4.3.0"},
          "snapshotVersions":[1,2],"assets":true,"libraryDocuments":true,"mutations":true,"vectors":true,
          "resources":{"api":"https://example.org/api/v1","mcp":"https://example.org/mcp"},
          "maxAssetBytes":8388608,"maxSpaceAssetBytes":1073741824,
          "maxSnapshotBytes":536870912,"maxSnapshotJsonBytes":536870912,
          "maxLibraryPackageBytes":134217728,"maxSpaceLibraryBytes":4294967296,
          "maxMutationBatch":32,
          "spaceActions":{"schemaVersion":1,"statuses":["queued","claimed","running","applied","refused","failed","cancelled"]},
          "accountLibrarySync":{"schemaVersion":1,"immutableVersions":true,"objects":"sha256-r2","maxRecordBatch":12},
          "desktopBridge":{"protocol":"/bridge/v1","relay":false,"transport":"private-tls"}
        }
        """
        let value = try JSONDecoder.nodus.decode(ServerCapabilities.self, from: Data(json.utf8))
        #expect(value.supportsSpaceActions)
        #expect(value.supportsAccountLibrarySync)
        #expect(value.guaranteesPrivateBridge)
    }

    @Test("a Bridge pairing requires direct HTTPS and exact grants")
    func bridgePairing() throws {
        #expect(throws: DesktopBridgeError.invalidOrigin) {
            _ = try DesktopBridgePairing(
                id: "pair-1",
                origin: "http://192.168.1.4:7444",
                certificateFingerprint: String(repeating: "a", count: 64),
                deviceId: "phone",
                deviceName: "iPhone",
                vaultIds: ["vault-1"],
                domains: [.testimonies],
                pairedAt: Date(),
                expiresAt: nil
            )
        }
        let pairing = try DesktopBridgePairing(
            id: "pair-1",
            origin: "https://192.168.1.4:7444",
            certificateFingerprint: String(repeating: "AB:", count: 31) + "AB",
            deviceId: "phone",
            deviceName: "iPhone",
            vaultIds: ["vault-1"],
            domains: [.testimonies],
            pairedAt: Date(),
            expiresAt: nil
        )
        #expect(pairing.domains == [.testimonies])
        #expect(!pairing.domains.contains(.teachingGrades))
        #expect(pairing.certificateFingerprint.count == 64)
    }

    @Test("remote work terminal states cannot be mistaken for pending work")
    func terminalStates() {
        #expect(!RemoteWorkStatus.queued.isTerminal)
        #expect(!RemoteWorkStatus.running.isTerminal)
        #expect(RemoteWorkStatus.applied.isTerminal)
        #expect(RemoteWorkStatus.refused.isTerminal)
        #expect(RemoteWorkStatus.failed.isTerminal)
        #expect(RemoteWorkStatus.cancelled.isTerminal)
    }
}
