import Foundation
import Testing
@testable import NodusKit

@Suite("Downloaded canonical map generation source") struct CompanionWorldMapGenerationSourceTests {
    private func fixture() throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: "world-map-generation-source", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder.nodus.decode(JSONValue.self, from: Data(contentsOf: url))
    }
    @Test("Desktop fixture preserves all ten styles and exact expansion direction") func canonicalTemplates() throws {
        let captured = try CompanionWorldMapGenerationSource(fixture(), mapId: "same-map")
        for style in CompanionWorldMapGenerationSource.styles {
            let result = try captured.prompt(request: .object(["mapId":.string("same-map"),"mode":.string("create"),"style":.string(style),"extra":.string("  A river\n across the valley ")]))
            #expect(result.contains("This map: A real valley.")); #expect(result.contains("A river across the valley")); #expect(result.hasSuffix("no hands, no border frame."))
            #expect(!result.contains("NODUS_MAP_EXTRA"))
        }
        let expanded = try captured.prompt(request: .object(["mapId":.string("same-map"),"mode":.string("expand"),"edge":.string("west"),"fraction":.double(0.5),"extra":.string("")]))
        #expect(expanded.contains("The new area is to the west")); #expect(expanded.contains("existing part must be reproduced unchanged"))
    }
    @Test("Copies cannot become another map or silently use incomplete prompts") func ownership() throws {
        #expect(throws: DesktopBridgeError.self) { try CompanionWorldMapGenerationSource(fixture(), mapId: "other-map") }
        var value = try #require(fixture().objectValue); var prompts = try #require(value["prompts"]?.objectValue)
        prompts["create:parchment:"] = nil; value["prompts"] = .object(prompts)
        #expect(throws: DesktopBridgeError.self) { try CompanionWorldMapGenerationSource(.object(value), mapId: "same-map") }
    }
    @Test("Extra direction is substituted once without interpreting its contents") func direction() throws {
        let captured = try CompanionWorldMapGenerationSource(fixture(), mapId: "same-map")
        let extra = "Keep NODUS_MAP_EXTRA_DIRECTION_3DC849 literally"
        let result = try captured.prompt(request: .object(["mapId":.string("same-map"),"mode":.string("create"),"style":.string("parchment"),"extra":.string(extra)]))
        #expect(result.contains(extra))
        #expect(throws: DesktopBridgeError.self) { try captured.prompt(request: .object(["mapId":.string("same-map"),"mode":.string("expand"),"edge":.string("north"),"fraction":.double(3),"extra":.string("")])) }
    }
    @Test("Publication is provider free and generation still requires a research grant") func jobBoundary() {
        #expect(DesktopBridgeClient.jobMethods.contains("generateMobileWorldMap"))
        #expect(DesktopBridgeClient.providerFreeJobMethods.contains("saveMobileWorldMapImage"))
        #expect(!DesktopBridgeClient.providerFreeJobMethods.contains("generateMobileWorldMap"))
    }
    @Test("Device image bytes survive process reopen and reconnect only submits publication") func durableDeviceImage() async throws {
        let pairing = UUID().uuidString, id = UUID().uuidString
        let directory = URL.temporaryDirectory.appendingPathComponent("nodus-map-result-\(pairing)")
        let keychain = KeychainStore(service: "nodus.tests.map.\(pairing)")
        defer { try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: pairing)); try? FileManager.default.removeItem(at: directory) }
        let cache = try PrivateBridgeCache(pairingId: pairing, directory: directory, keychain: keychain)
        let ledger = try DesktopJobLedger(cache: cache, vaultId: "vault", data: nil)
        let image = Data("generated-on-device-without-Mac".utf8)
        let input: JSONValue = .object(["requestId":.string(id),"request":.object(["mapId":.string("same-map"),"mode":.string("create")]),"bytes":.string(image.base64EncodedString()),"mime":.string("image/png")])
        _ = try await ledger.prepare(id: id, method: "saveMobileWorldMapImage", args: [input])
        try await ledger.disconnected(id: id, issue: "Mac asleep")
        let reopened = try DesktopJobLedger(cache: cache, vaultId: "vault", data: await cache.data(vaultId: "vault", domain: .researchGeneration, recordId: "job-ledger-v1"))
        #expect(await reopened.all().first?.args == [input])
        try await reopened.synchronize(list: { [] }, canSubmit: { DesktopBridgeClient.isProviderFreeJob(method: $0.method, args: $0.args) }, submit: { request in
            #expect(request.id == id); #expect(request.method == "saveMobileWorldMapImage"); #expect(request.args == [input])
            return DesktopBridgeJob(id: "saved-job", vaultId: "vault", method: request.method, state: .available, nextSequence: 0, events: [], result: .object(["map":.object(["mapId":.string("same-map")])]), error: nil)
        })
        let final = try DesktopJobLedger(cache: cache, vaultId: "vault", data: await cache.data(vaultId: "vault", domain: .researchGeneration, recordId: "job-ledger-v1"))
        #expect(await final.all().first?.state == "available")
        #expect(await final.all().first?.args.first?.objectValue?["bytes"] == .string(image.base64EncodedString()))
    }

}
