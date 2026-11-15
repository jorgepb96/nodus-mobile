import CryptoKit
import Foundation
import Testing
import ZIPFoundation
@testable import NodusKit

@Suite("Authored document figure assets")
struct CompanionDocumentFigureAssetsTests {
    private func parent(generation: UUID, figure: UUID, revision: UUID, owner: String, input: JSONValue? = nil) -> JSONValue {
        let objective: JSONValue = .string("Figure storage contract")
        var value: [String: JSONValue] = ["id": .string(generation.uuidString.lowercased()), "entityKey": .string("figures"), "state": .string("running"),
            "request": .object(["objective": objective]), "context": .object(["vaultId": .string("vault"), "revision": .string(String(repeating: "a", count: 64))]),
            "report": .object(["mobileVisuals": .object(["manifest": .object(["vaultId": .string("vault"), "target": .object(["kind": .string("deep-research"), "id": .string(generation.uuidString.lowercased())]),
                "revision": .string(revision.uuidString.lowercased()), "figures": .array([.object(["id": .string(figure.uuidString.lowercased()), "state": .string("running"), "owner": .string(owner), "ownerRevision": .string(revision.uuidString.lowercased())])])])])])]
        if let input { value["inflight"] = .object(["request": input]) }
        return .object(value)
    }
    private func owner(generation: UUID, revision: UUID, figure: UUID) throws -> String {
        CompanionDocumentFigureAssets.hash(try JSONEncoder.nodus.encode(["document-figure", "vault", "deep-research:\(generation.uuidString.lowercased()):\(revision.uuidString.lowercased()):\(figure.uuidString.lowercased())"]))
    }
    private func saveParent(_ value: JSONValue, cache: PrivateBridgeCache) async throws -> String {
        let record = try CompanionGenerationPublication.recordId(kind: "deepResearch", entity: "figures")
        try await cache.storeIndexedGeneration(JSONEncoder.nodus.encode(value), vaultId: "vault", recordId: record, indexId: "autonomous:deepResearch:index:v1", entity: "figures")
        return record
    }
    private func visualParent(session: UUID, target: UUID, figure: UUID, revision: UUID, owner: String) -> JSONValue {
        let manifest: JSONValue = .object(["vaultId": .string("vault"), "target": .object(["kind": .string("deep-research"), "id": .string(target.uuidString.lowercased())]),
            "revision": .string(revision.uuidString.lowercased()), "figures": .array([.object(["id": .string(figure.uuidString.lowercased()), "state": .string("running"), "owner": .string(owner), "ownerRevision": .string(revision.uuidString.lowercased())])])])
        return .object(["version": .int(1), "kind": .string("documentVisuals"), "id": .string(session.uuidString.lowercased()),
            "entityKey": .string("deep-research:" + target.uuidString.lowercased()), "target": .object(["kind": .string("deep-research"), "id": .string(target.uuidString.lowercased())]),
            "source": .object(["vaultId": .string("vault"), "draft": .object(["id": .string(target.uuidString.lowercased()), "draftMarkdown": .string("Existing report")]),
                "origin": .string("desktop-capture"), "contentHash": .string(String(repeating: "a", count: 64))]), "manifest": manifest])
    }
    @Test("visual-only sessions retain the report target and recover without publishing a new report")
    func visualOnlySessionRecovery() async throws {
        let f = try PrivateBridgeAuthoringRecoveryTests.Fixture(); defer { f.clean() }
        let old = try f.pairing("visual-only-old"), cache = try f.cache(old.id)
        let session = UUID(), target = UUID(), figure = UUID(), revision = UUID()
        let owner = try owner(generation: target, revision: revision, figure: figure)
        let entity = "deep-research:" + target.uuidString.lowercased()
        let record = try CompanionGenerationPublication.recordId(kind: "documentVisuals", entity: entity)
        let parent = visualParent(session: session, target: target, figure: figure, revision: revision, owner: owner)
        try await cache.storeIndexedGeneration(JSONEncoder.nodus.encode(parent), vaultId: "vault", recordId: record, indexId: "autonomous:documentVisuals:index:v1", entity: entity)
        let store = CompanionDocumentFigureAssets(cache: cache, vaultId: "vault"), bytes = Data(repeating: 5, count: 19)
        let receipt = try await store.store(data: bytes, mimeType: "image/png", parentRecordId: record, generationId: session, figureId: figure, owner: owner)
        #expect(receipt.targetId == target.uuidString.lowercased())
        #expect(receipt.generationId == session && receipt.generationId != target)
        await #expect(throws: (any Error).self) { _ = try await store.store(data: bytes, mimeType: "image/png", parentRecordId: record, generationId: target, figureId: figure, owner: owner) }
        var forged = parent.objectValue!; forged["target"] = .object(["kind": .string("deep-research"), "id": .string(UUID().uuidString.lowercased())])
        #expect(throws: (any Error).self) { _ = try CompanionDocumentFigureAssets.Parent(.object(forged), vaultId: "vault", recordId: record) }
        // A paid planning call can precede the first manifest. Keep that typed
        // session authored, but never permit asset ownership without a figure.
        var planning = parent.objectValue!; planning["manifest"] = .null
        _ = try CompanionDocumentFigureAssets.Parent(.object(planning), vaultId: "vault", recordId: record)
        #expect(throws: (any Error).self) { try CompanionDocumentFigureAssets.validate(receipt, parent: .object(planning)) }
        try await cache.freezeForRevocation(true)
        let snapshot = try await cache.authoringRecoverySnapshot(vaultIds: ["vault"])
        let authored = try #require(snapshot.records.first { $0.generationKind == "documentVisuals" })
        let recovered = try PrivateBridgeAuthoringRecovery.recoveredRequest(authored, requiresReview: true)
        let local = try #require(recovered)
        #expect(local.method == "localDocumentVisuals" && local.args.isEmpty && local.state == "recoveryReview")
        #expect(!PrivateBridgeAuthoringRecovery.canReviewResult(local))
        let saved = try await f.recovery.preserve(snapshot: snapshot, pairing: old, macDeviceId: "real-mac")
        try await f.recovery.completeRevocation(saved)
        let fresh = try f.pairing("visual-only-new"), destination = try f.cache(fresh.id)
        _ = try await f.recovery.adopt(pairing: fresh, macDeviceId: "real-mac", cache: destination)
        let restoredBytes = try #require(await destination.data(vaultId: "vault", domain: .researchGeneration, recordId: record))
        #expect(try JSONDecoder.nodus.decode(JSONValue.self, from: restoredBytes).objectValue?["recoveryReviewRequired"] == .bool(true))
        #expect(try await CompanionDocumentFigureAssets(cache: destination, vaultId: "vault").data(receipt) == bytes)
        await #expect(throws: (any Error).self) { try await destination.requireGenerationExecutionAllowed(vaultId: "vault", generationId: session.uuidString.lowercased()) }
        for key in [old.id, fresh.id] { try? f.keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: key)) }
        try? f.keychain.remove(saved.recoveryKeyName)
    }
    @Test("legacy capture imports only the exact source asset without inventing an owner birth")
    func capturedLegacyAsset() async throws {
        let f = try PrivateBridgeAuthoringRecoveryTests.Fixture(); defer { f.clean() }
        let old = try f.pairing("visual-legacy"), cache = try f.cache(old.id)
        let session = UUID(), target = UUID(), figure = UUID(), revision = UUID(), nativeAsset = UUID(), sourceAsset = UUID().uuidString.lowercased()
        let owner = String(repeating: "b", count: 64), bytes = Data(repeating: 31, count: CompanionDocumentFigureAssets.chunkBytes + 3)
        let entity = "deep-research:" + target.uuidString.lowercased(), record = try CompanionGenerationPublication.recordId(kind: "documentVisuals", entity: entity)
        var fields = visualParent(session: session, target: target, figure: figure, revision: revision, owner: owner).objectValue!
        var manifest = fields["manifest"]!.objectValue!, figureValue = manifest["figures"]!.arrayValue![0].objectValue!
        figureValue["ownerRevision"] = nil; figureValue["state"] = .string("ready"); manifest["figures"] = .array([.object(figureValue)])
        let capture: JSONValue = .object(["version": .int(1), "vaultId": .string("vault"), "target": fields["target"]!,
            "contentHash": .string(String(repeating: "a", count: 64)), "manifest": .object(manifest),
            "assets": .array([.object(["id": .string(sourceAsset), "figureId": .string(figure.uuidString.lowercased()), "owner": .string(owner),
                "mimeType": .string("image/png"), "byteCount": .int(Int64(bytes.count)), "sha256": .string(CompanionDocumentFigureAssets.hash(bytes))])])])
        let canonical = try JSONEncoder.nodus.encode(capture), proof = CompanionDocumentFigureAssets.hash(canonical)
        var source = fields["source"]!.objectValue!
        source["capture"] = capture; source["captureCanonical"] = .string(String(decoding: canonical, as: UTF8.self)); source["captureHash"] = .string(proof)
        fields["source"] = .object(source); fields["manifest"] = .object(manifest)
        func save(_ value: JSONValue) async throws {
            try await cache.storeIndexedGeneration(JSONEncoder.nodus.encode(value), vaultId: "vault", recordId: record, indexId: "autonomous:documentVisuals:index:v1", entity: entity)
        }
        try await save(.object(fields))
        let store = CompanionDocumentFigureAssets(cache: cache, vaultId: "vault")
        await #expect(throws: (any Error).self) { _ = try await store.store(data: bytes, mimeType: "image/png", parentRecordId: record, generationId: session, figureId: figure, owner: owner) }
        await #expect(throws: (any Error).self) { _ = try await store.importCapturedLegacyAsset(data: Data([1]), mimeType: "image/png", parentRecordId: record, generationId: session, figureId: figure, owner: owner, sourceAssetId: sourceAsset) }
        await #expect(throws: (any Error).self) { _ = try await store.importCapturedLegacyAsset(data: bytes, mimeType: "image/png", parentRecordId: record, generationId: session, figureId: figure, owner: owner, sourceAssetId: "another-asset") }
        let receipt = try await store.importCapturedLegacyAsset(data: bytes, mimeType: "image/png", parentRecordId: record, generationId: session, figureId: figure, owner: owner, sourceAssetId: sourceAsset, assetId: nativeAsset)
        #expect(receipt.ownerRevision.isEmpty && receipt.captureHash == proof && receipt.capturedAssetId == sourceAsset)
        #expect(try await store.data(receipt) == bytes)
        // Both decoded metadata and original serialization must match the source checksum.
        var tampered = fields, tamperedSource = source; tamperedSource["captureCanonical"] = .string("{}")
        tampered["source"] = .object(tamperedSource)
        #expect(throws: (any Error).self) { try CompanionDocumentFigureAssets.validate(receipt, parent: .object(tampered)) }
        // Removing a figure later cannot make previously paid/copied authoring bytes
        // unclassifiable, nor does it let a new asset attach to the removed figure.
        manifest["figures"] = .array([]); manifest["revision"] = .string(UUID().uuidString.lowercased()); fields["manifest"] = .object(manifest)
        try await save(.object(fields))
        #expect(try await store.receipts(parentRecordId: record, generationId: session) == [receipt])
        await #expect(throws: (any Error).self) { _ = try await store.importCapturedLegacyAsset(data: bytes, mimeType: "image/png", parentRecordId: record, generationId: session, figureId: figure, owner: owner, sourceAssetId: sourceAsset) }
        try await cache.freezeForRevocation(true)
        let snapshot = try await cache.authoringRecoverySnapshot(vaultIds: ["vault"])
        let saved = try await f.recovery.preserve(snapshot: snapshot, pairing: old, macDeviceId: "real-mac")
        let id = try #require(UUID(uuidString: saved.archiveURL.deletingPathExtension().lastPathComponent))
        let lease = try await f.recovery.exportFile(id: id), zip = try Archive(url: lease.url, accessMode: .read)
        let entry = try #require(zip.first { $0.path.hasSuffix(".png") })
        var exported = Data(); _ = try zip.extract(entry) { exported.append($0) }
        #expect(exported == bytes)
        try? f.keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: old.id)); try? f.keychain.remove(saved.recoveryKeyName)
    }
    @Test("legacy poster retry is a PNG derivation of only the exact captured view and survives regrant for review")
    func derivedLegacyPoster() async throws {
        let f = try PrivateBridgeAuthoringRecoveryTests.Fixture(); defer { f.clean() }
        let old = try f.pairing("derived-poster-old"), cache = try f.cache(old.id)
        let session = UUID(), target = UUID(), figure = UUID(), revision = UUID(), asset = UUID()
        let owner = String(repeating: "c", count: 64), entity = "deep-research:" + target.uuidString.lowercased()
        let record = try CompanionGenerationPublication.recordId(kind: "documentVisuals", entity: entity)
        let view: JSONValue = .object(["schemaVersion": .int(1), "summary": .string("Original table"), "nodes": .array([.object(["kind": .string("table"), "columns": .array([.object(["label": .string("Value")])]), "rows": .array([.array([.string("Exact source")])])])])])
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jN3sAAAAASUVORK5CYII="))
        var fields = visualParent(session: session, target: target, figure: figure, revision: revision, owner: owner).objectValue!
        var manifest = fields["manifest"]!.objectValue!, item = manifest["figures"]!.arrayValue![0].objectValue!
        item["ownerRevision"] = nil; item["view"] = view; item["state"] = .string("failed"); manifest["figures"] = .array([.object(item)])
        let capture: JSONValue = .object(["version": .int(1), "vaultId": .string("vault"), "target": fields["target"]!, "contentHash": .string(String(repeating: "a", count: 64)), "manifest": .object(manifest), "assets": .array([])])
        let serialized = try JSONEncoder.nodus.encode(capture), proof = CompanionDocumentFigureAssets.hash(serialized)
        var source = fields["source"]!.objectValue!; source["capture"] = capture; source["captureCanonical"] = .string(String(decoding: serialized, as: UTF8.self)); source["captureHash"] = .string(proof)
        fields["source"] = .object(source); fields["manifest"] = .object(manifest)
        try await cache.storeIndexedGeneration(JSONEncoder.nodus.encode(JSONValue.object(fields)), vaultId: "vault", recordId: record, indexId: "autonomous:documentVisuals:index:v1", entity: entity)
        let store = CompanionDocumentFigureAssets(cache: cache, vaultId: "vault")
        let receipt = try await store.storeDerivedCapturedPoster(data: png, view: view, parentRecordId: record, generationId: session, figureId: figure, owner: owner, assetId: asset)
        #expect(receipt.derivation == "captured-view-poster-v1" && receipt.ownerRevision.isEmpty && receipt.captureHash == proof && receipt.capturedAssetId == nil)
        #expect(try await store.data(receipt) == png)
        #expect(try await store.storeDerivedCapturedPoster(data: png, view: view, parentRecordId: record, generationId: session, figureId: figure, owner: owner, assetId: asset) == receipt)
        var changedView = view.objectValue!; changedView["summary"] = .string("Different view")
        await #expect(throws: (any Error).self) { _ = try await store.storeDerivedCapturedPoster(data: png, view: .object(changedView), parentRecordId: record, generationId: session, figureId: figure, owner: owner) }
        await #expect(throws: (any Error).self) { _ = try await store.storeDerivedCapturedPoster(data: png, view: view, parentRecordId: record, generationId: target, figureId: figure, owner: owner) }
        await #expect(throws: (any Error).self) { _ = try await store.storeDerivedCapturedPoster(data: png, view: view, parentRecordId: record, generationId: session, figureId: UUID(), owner: owner) }
        await #expect(throws: (any Error).self) { _ = try await store.storeDerivedCapturedPoster(data: png, view: view, parentRecordId: record, generationId: session, figureId: figure, owner: String(repeating: "d", count: 64)) }
        await #expect(throws: (any Error).self) { _ = try await store.storeDerivedCapturedPoster(data: Data([1,2,3]), view: view, parentRecordId: record, generationId: session, figureId: figure, owner: owner) }
        var changed = fields, changedManifest = manifest, changedItem = item
        changedItem["view"] = .object(changedView); changedManifest["figures"] = .array([.object(changedItem)]); changed["manifest"] = .object(changedManifest)
        #expect(throws: (any Error).self) { try CompanionDocumentFigureAssets.validate(receipt, parent: .object(changed)) }
        changed = fields; changed["target"] = .object(["kind": .string("deep-research"), "id": .string(UUID().uuidString.lowercased())])
        #expect(throws: (any Error).self) { try CompanionDocumentFigureAssets.validate(receipt, parent: .object(changed)) }
        changed = fields; var changedSource = source; changedSource["captureHash"] = .string(String(repeating: "e", count: 64)); changed["source"] = .object(changedSource)
        #expect(throws: (any Error).self) { try CompanionDocumentFigureAssets.validate(receipt, parent: .object(changed)) }
        // The general import path cannot relabel a derived poster as an original asset.
        await #expect(throws: (any Error).self) { _ = try await store.importCapturedLegacyAsset(data: png, mimeType: "image/png", parentRecordId: record, generationId: session, figureId: figure, owner: owner, sourceAssetId: asset.uuidString.lowercased()) }
        try await cache.freezeForRevocation(true)
        let snapshot = try await cache.authoringRecoverySnapshot(vaultIds: ["vault"]), saved = try await f.recovery.preserve(snapshot: snapshot, pairing: old, macDeviceId: "real-mac")
        try await f.recovery.completeRevocation(saved)
        let fresh = try f.pairing("derived-poster-new"), destination = try f.cache(fresh.id)
        _ = try await f.recovery.adopt(pairing: fresh, macDeviceId: "real-mac", cache: destination)
        let restored = CompanionDocumentFigureAssets(cache: destination, vaultId: "vault")
        #expect(try await restored.data(receipt) == png)
        #expect(try await restored.receipts(parentRecordId: record, generationId: session) == [receipt])
        await #expect(throws: (any Error).self) { _ = try await restored.storeDerivedCapturedPoster(data: png, view: view, parentRecordId: record, generationId: session, figureId: figure, owner: owner, assetId: UUID()) }
        for key in [old.id, fresh.id] { try? f.keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: key)) }; try? f.keychain.remove(saved.recoveryKeyName)
    }
    @Test("a visual session references exact original authored assets without copying bytes or changing receipt ownership")
    func originalAssetBinding() async throws {
        let f = try PrivateBridgeAuthoringRecoveryTests.Fixture(); defer { f.clean() }
        let old = try f.pairing("original-reference-old"), cache = try f.cache(old.id), target = UUID(), session = UUID(), figure = UUID(), revision = UUID(), asset = UUID()
        let owner = try owner(generation: target, revision: revision, figure: figure), bytes = Data(repeating: 51, count: CompanionDocumentFigureAssets.chunkBytes + 13)
        let view: JSONValue = .object(["schemaVersion": .int(1), "summary": .string("Actual original figure"), "nodes": .array([.object(["kind": .string("image"), "attachmentId": .string(asset.uuidString.lowercased()), "alt": .string("Original image"), "name": .string("Original.png"), "mimeType": .string("image/png"), "bytes": .int(Int64(bytes.count))])])])
        var original = parent(generation: target, figure: figure, revision: revision, owner: owner).objectValue!
        var report = original["report"]!.objectValue!, mobile = report["mobileVisuals"]!.objectValue!, manifest = mobile["manifest"]!.objectValue!, originalFigure = manifest["figures"]!.arrayValue![0].objectValue!
        originalFigure["view"] = view; originalFigure["poster"] = .string("nodus-image://chat/\(owner)/\(asset.uuidString.lowercased())"); manifest["figures"] = .array([.object(originalFigure)])
        mobile["manifest"] = .object(manifest); report["mobileVisuals"] = .object(mobile); original["report"] = .object(report)
        let originalRecord = try await saveParent(.object(original), cache: cache), store = CompanionDocumentFigureAssets(cache: cache, vaultId: "vault")
        let receipt = try await store.store(data: bytes, mimeType: "image/png", parentRecordId: originalRecord, generationId: target, figureId: figure, owner: owner, assetId: asset)
        let capture: JSONValue = .object(["version": .int(1), "vaultId": .string("vault"), "target": manifest["target"]!, "contentHash": .string(String(repeating: "a", count: 64)), "manifest": .object(manifest), "assets": .array([.object(["id": .string(asset.uuidString.lowercased()), "figureId": .string(receipt.figureKey), "owner": .string(owner), "mimeType": .string(receipt.mimeType), "byteCount": .int(receipt.byteCount), "sha256": .string(receipt.sha256)])])])
        let serialized = try JSONEncoder.nodus.encode(capture), entity = "deep-research:" + target.uuidString.lowercased(), record = try CompanionGenerationPublication.recordId(kind: "documentVisuals", entity: entity)
        var fields = visualParent(session: session, target: target, figure: figure, revision: revision, owner: owner).objectValue!, source = visualParent(session: session, target: target, figure: figure, revision: revision, owner: owner).objectValue!["source"]!.objectValue!
        source["origin"] = .string("authored-mobile"); source["originalReceipts"] = .array([try receipt.jsonValue()]); source["capture"] = capture; source["captureCanonical"] = .string(String(decoding: serialized, as: UTF8.self)); source["captureHash"] = .string(CompanionDocumentFigureAssets.hash(serialized))
        fields["source"] = .object(source); fields["manifest"] = .object(manifest)
        try await cache.storeIndexedGeneration(JSONEncoder.nodus.encode(JSONValue.object(fields)), vaultId: "vault", recordId: record, indexId: "autonomous:documentVisuals:index:v1", entity: entity)
        #expect(try await store.referencedReceipts(parentRecordId: record, generationId: session) == [receipt])
        #expect(try await store.dataReferenced(receipt, parentRecordId: record, generationId: session) == bytes)
        #expect(try await store.readReferenced(receipt, parentRecordId: record, generationId: session, offset: 7, count: 13) == bytes.subdata(in: 7..<20))
        let indexData = try #require(await cache.data(vaultId: "vault", domain: .researchGeneration, recordId: CompanionDocumentFigureAssets.indexKey))
        #expect(try JSONDecoder.nodus.decode([String].self, from: indexData) == [asset.uuidString.lowercased()])
        await #expect(throws: (any Error).self) { _ = try await store.store(data: bytes, mimeType: "image/png", parentRecordId: record, generationId: session, figureId: figure, owner: owner, assetId: asset) }
        #expect(try await store.data(receipt) == bytes)
        await #expect(throws: (any Error).self) { _ = try await store.dataReferenced(receipt, parentRecordId: record, generationId: target) }
        var wrongReceipt = try receipt.jsonValue().objectValue!; wrongReceipt["owner"] = .string(String(repeating: "f", count: 64))
        let forged = try CompanionDocumentFigureAssets.Receipt(value: .object(wrongReceipt))
        await #expect(throws: (any Error).self) { _ = try await store.dataReferenced(forged, parentRecordId: record, generationId: session) }
        var wrong = fields; wrong["target"] = .object(["kind": .string("deep-research"), "id": .string(UUID().uuidString.lowercased())])
        #expect(throws: (any Error).self) { try CompanionDocumentFigureAssets.validateReferenced(receipt, parent: .object(wrong), parentRecordId: record, generationId: session) }
        wrong = fields; var wrongSource = source; wrongSource["captureHash"] = .string(String(repeating: "e", count: 64)); wrong["source"] = .object(wrongSource)
        #expect(throws: (any Error).self) { try CompanionDocumentFigureAssets.validateReferenced(receipt, parent: .object(wrong), parentRecordId: record, generationId: session) }
        var noURI = manifest, noURIfigure = originalFigure; noURIfigure["poster"] = nil; noURIfigure["view"] = .object(["schemaVersion": .int(1), "nodes": .array([])])
        noURI["figures"] = .array([.object(noURIfigure)])
        var noURIcapture = capture.objectValue!; noURIcapture["manifest"] = .object(noURI)
        let noURIbytes = try JSONEncoder.nodus.encode(JSONValue.object(noURIcapture))
        wrongSource = source; wrongSource["capture"] = .object(noURIcapture); wrongSource["captureCanonical"] = .string(String(decoding: noURIbytes, as: UTF8.self)); wrongSource["captureHash"] = .string(CompanionDocumentFigureAssets.hash(noURIbytes)); wrong = fields; wrong["source"] = .object(wrongSource)
        #expect(throws: (any Error).self) { try CompanionDocumentFigureAssets.validateReferenced(receipt, parent: .object(wrong), parentRecordId: record, generationId: session) }
        try await cache.freezeForRevocation(true)
        let snapshot = try await cache.authoringRecoverySnapshot(vaultIds: ["vault"])
        #expect(snapshot.records.filter { $0.generationKind == "documentFigureAssetChunk" }.count == 2)
        let saved = try await f.recovery.preserve(snapshot: snapshot, pairing: old, macDeviceId: "real-mac"); try await f.recovery.completeRevocation(saved)
        let fresh = try f.pairing("original-reference-new"), destination = try f.cache(fresh.id)
        _ = try await f.recovery.adopt(pairing: fresh, macDeviceId: "real-mac", cache: destination)
        let restored = CompanionDocumentFigureAssets(cache: destination, vaultId: "vault")
        #expect(try await restored.dataReferenced(receipt, parentRecordId: record, generationId: session) == bytes)
        #expect(try await restored.referencedReceipts(parentRecordId: record, generationId: session) == [receipt])
        await #expect(throws: (any Error).self) { try await destination.requireGenerationExecutionAllowed(vaultId: "vault", generationId: session.uuidString.lowercased()) }
        _ = try await destination.authoringRecoverySnapshot(vaultIds: ["vault"])
        for id in [old.id, fresh.id] { try? f.keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)) }; try? f.keychain.remove(saved.recoveryKeyName)
    }
    @Test("a receipt-only paid image becomes encrypted chunks and a thin durable replay pointer")
    func paidImageReceipt() async throws {
        let f = try PrivateBridgeAuthoringRecoveryTests.Fixture(); defer { f.clean() }
        let cache = try f.cache("figure-old"), generation = UUID(), figure = UUID(), revision = UUID(), asset = UUID()
        let owner = try owner(generation: generation, revision: revision, figure: figure)
        let input: JSONValue = .object(["generationId": .string(generation.uuidString.lowercased()), "figureOwner": .string(owner), "format": .string("image"), "responseMode": .string("receipt")])
        let record = try await saveParent(parent(generation: generation, figure: figure, revision: revision, owner: owner, input: input), cache: cache)
        let bytes = Data(repeating: 73, count: CompanionDocumentFigureAssets.chunkBytes + 17)
        let raw = String(decoding: try JSONEncoder.nodus.encode(JSONValue.object(["bytes": .string(bytes.base64EncodedString()), "mime": .string("image/png")])), as: UTF8.self)
        let completion = "autonomous:\(generation.uuidString.lowercased()):completion:" + CompanionDocumentFigureAssets.hash(try JSONEncoder.nodus.encode(input))
        try await cache.storeIndexedGeneration(JSONEncoder.nodus.encode(JSONValue.string(raw)), vaultId: "vault", recordId: completion, indexId: "autonomous:completion-index:v1", entity: completion)
        let store = CompanionDocumentFigureAssets(cache: cache, vaultId: "vault")
        let receipt = try await store.store(data: bytes, mimeType: "image/png", parentRecordId: record, generationId: generation, figureId: figure, owner: owner, assetId: asset, sourceCompletionRecordId: completion)
        #expect(receipt.byteCount == bytes.count)
        #expect(try await store.receipts(parentRecordId: record, generationId: generation, figureId: figure, owner: owner) == [receipt])
        #expect(try await store.data(receipt) == bytes)
        #expect(try await store.read(receipt, offset: Int64(CompanionDocumentFigureAssets.chunkBytes - 3), count: 12) == bytes.subdata(in: (CompanionDocumentFigureAssets.chunkBytes - 3)..<(CompanionDocumentFigureAssets.chunkBytes + 9)))
        let replayBytes = try #require(await cache.data(vaultId: "vault", domain: .researchGeneration, recordId: completion))
        let replay = try JSONDecoder.nodus.decode(JSONValue.self, from: replayBytes)
        #expect(try CompanionDocumentFigureAssets.Receipt(value: #require(replay.objectValue?["documentFigureAsset"])) == receipt)
        #expect(replayBytes.count < 2_048)
        // A byte-for-byte repeat resumes the same identity; no duplicate index entry.
        let again = try await store.store(data: bytes, mimeType: "image/png", parentRecordId: record, generationId: generation, figureId: figure, owner: owner, assetId: asset, sourceCompletionRecordId: completion)
        #expect(again == receipt)
        await #expect(throws: (any Error).self) { _ = try await store.store(data: bytes, mimeType: "image/png", parentRecordId: record, generationId: UUID(), figureId: figure, owner: owner) }
        await #expect(throws: (any Error).self) { _ = try await store.store(data: bytes, mimeType: "image/png", parentRecordId: record, generationId: generation, figureId: figure, owner: String(repeating: "b", count: 64)) }
        let wrongVault = CompanionDocumentFigureAssets(cache: cache, vaultId: "other-vault")
        await #expect(throws: (any Error).self) { _ = try await wrongVault.data(receipt) }
        // Advancing the enclosing revision must not change the figure's owner birth.
        var current = try #require(parent(generation: generation, figure: figure, revision: revision, owner: owner).objectValue)
        var report = current["report"]!.objectValue!, visuals = report["mobileVisuals"]!.objectValue!, manifest = visuals["manifest"]!.objectValue!
        manifest["revision"] = .string(UUID().uuidString.lowercased()); visuals["manifest"] = .object(manifest); report["mobileVisuals"] = .object(visuals); current["report"] = .object(report)
        _ = try await saveParent(.object(current), cache: cache)
        #expect(try await store.store(data: bytes, mimeType: "image/png", parentRecordId: record, generationId: generation, figureId: figure, owner: owner, assetId: asset) == receipt)
        // A present chunk with the right identity but different bytes is never accepted.
        let corrupted = CompanionDocumentFigureAssets.Chunk(id: asset, index: 0, bytes: Data(repeating: 0, count: CompanionDocumentFigureAssets.chunkBytes).base64EncodedString())
        try await cache.store(JSONEncoder.nodus.encode(corrupted), vaultId: "vault", domain: .researchGeneration, recordId: CompanionDocumentFigureAssets.chunkId(asset, 0))
        await #expect(throws: (any Error).self) { _ = try await store.data(receipt) }
        await #expect(throws: (any Error).self) { _ = try await cache.authoringRecoverySnapshot(vaultIds: ["vault"]) }
        try? f.keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: "figure-old"))
    }

    @Test("unlink streams independent figure bytes and regrant retains review-only ownership without paid replay")
    func recoveryStreamsAssets() async throws {
        let f = try PrivateBridgeAuthoringRecoveryTests.Fixture(); defer { f.clean() }
        let old = try f.pairing("figure-archive"), cache = try f.cache(old.id), generation = UUID(), figure = UUID(), revision = UUID()
        let owner = try owner(generation: generation, revision: revision, figure: figure)
        let record = try await saveParent(parent(generation: generation, figure: figure, revision: revision, owner: owner), cache: cache)
        let bytes = Data(repeating: 91, count: CompanionDocumentFigureAssets.chunkBytes + 29)
        let store = CompanionDocumentFigureAssets(cache: cache, vaultId: "vault")
        let receipt = try await store.store(data: bytes, mimeType: "image/jpeg", parentRecordId: record, generationId: generation, figureId: figure, owner: owner)
        try await cache.freezeForRevocation(true)
        let snapshot = try await cache.authoringRecoverySnapshot(vaultIds: ["vault"])
        let chunks = snapshot.records.filter { $0.generationKind == "documentFigureAssetChunk" }
        #expect(chunks.count == 2 && chunks.allSatisfy { $0.data.isEmpty && $0.source != nil })
        let saved = try await f.recovery.preserve(snapshot: snapshot, pairing: old, macDeviceId: "real-mac")
        #expect(try Data(contentsOf: saved.archiveURL).count < 16_384)
        try await f.recovery.completeRevocation(saved)
        let id = try #require(UUID(uuidString: saved.archiveURL.deletingPathExtension().lastPathComponent))
        let lease = try await f.recovery.exportFile(id: id)
        let zip = try Archive(url: lease.url, accessMode: .read)
        let entry = try #require(zip.first { $0.path.hasPrefix("figure-") && $0.path.hasSuffix(".jpg") })
        var exported = Data(); _ = try zip.extract(entry) { exported.append($0) }
        #expect(exported == bytes)
        let fresh = try f.pairing("figure-restored"), destination = try f.cache(fresh.id)
        _ = try await f.recovery.adopt(pairing: fresh, macDeviceId: "real-mac", cache: destination)
        let restored = CompanionDocumentFigureAssets(cache: destination, vaultId: "vault")
        #expect(try await restored.data(receipt) == bytes)
        let metadataBytes = try #require(await destination.data(vaultId: "vault", domain: .researchGeneration, recordId: CompanionDocumentFigureAssets.recordId(receipt.id)))
        #expect(try JSONDecoder.nodus.decode(JSONValue.self, from: metadataBytes).objectValue?["recoveryReviewRequired"] == .bool(true))
        await #expect(throws: (any Error).self) { _ = try await restored.store(data: bytes, mimeType: "image/jpeg", parentRecordId: record, generationId: generation, figureId: figure, owner: owner, assetId: receipt.id) }
        await #expect(throws: (any Error).self) { try await destination.requireGenerationExecutionAllowed(vaultId: "vault", generationId: generation.uuidString.lowercased()) }
        for key in [old.id, fresh.id] { try? f.keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: key)) }
        try? f.keychain.remove(saved.recoveryKeyName)
    }

    @Test("interrupted chunk import exports its exact partial bytes and missing confirmed chunks block unlink")
    func partialImportAndMissingChunk() async throws {
        let f = try PrivateBridgeAuthoringRecoveryTests.Fixture(); defer { f.clean() }
        let old = try f.pairing("figure-partial"), cache = try f.cache(old.id), generation = UUID(), figure = UUID(), revision = UUID()
        let owner = try owner(generation: generation, revision: revision, figure: figure)
        let record = try await saveParent(parent(generation: generation, figure: figure, revision: revision, owner: owner), cache: cache)
        let bytes = Data(repeating: 67, count: CompanionDocumentFigureAssets.chunkBytes + 11)
        let store = CompanionDocumentFigureAssets(cache: cache, vaultId: "vault")
        let receipt = try await store.store(data: bytes, mimeType: "image/png", parentRecordId: record, generationId: generation, figureId: figure, owner: owner)
        let encoded = try #require(await cache.data(vaultId: "vault", domain: .researchGeneration, recordId: CompanionDocumentFigureAssets.recordId(receipt.id)))
        var partial = try JSONDecoder.nodus.decode(CompanionDocumentFigureAssets.Manifest.self, from: encoded)
        partial.state = "importing"; partial.chunkHashes = Array(partial.chunkHashes.prefix(1))
        try await cache.store(JSONEncoder.nodus.encode(partial), vaultId: "vault", domain: .researchGeneration, recordId: CompanionDocumentFigureAssets.recordId(receipt.id))
        try await cache.remove(vaultId: "vault", domain: .researchGeneration, recordId: CompanionDocumentFigureAssets.chunkId(receipt.id, 1))
        let snapshot = try await cache.authoringRecoverySnapshot(vaultIds: ["vault"])
        let saved = try await f.recovery.preserve(snapshot: snapshot, pairing: old, macDeviceId: "real-mac")
        let id = try #require(UUID(uuidString: saved.archiveURL.deletingPathExtension().lastPathComponent))
        let lease = try await f.recovery.exportFile(id: id)
        let zip = try Archive(url: lease.url, accessMode: .read), entry = try #require(zip.first { $0.path.hasSuffix(".png.partial") })
        var exported = Data(); _ = try zip.extract(entry) { exported.append($0) }
        #expect(exported == bytes.prefix(CompanionDocumentFigureAssets.chunkBytes))
        try await cache.remove(vaultId: "vault", domain: .researchGeneration, recordId: CompanionDocumentFigureAssets.chunkId(receipt.id, 0))
        await #expect(throws: (any Error).self) { _ = try await cache.authoringRecoverySnapshot(vaultIds: ["vault"]) }
        try? f.keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: old.id)); try? f.keychain.remove(saved.recoveryKeyName)
    }

    @Test("a paid response interrupted before asset claiming stays lazy and exportable")
    func unclaimedPaidResponse() async throws {
        let f = try PrivateBridgeAuthoringRecoveryTests.Fixture(); defer { f.clean() }
        let old = try f.pairing("figure-raw"), cache = try f.cache(old.id), generation = UUID()
        let record = "autonomous:\(generation.uuidString.lowercased()):completion:" + String(repeating: "a", count: 64)
        let raw = JSONValue.string(String(repeating: "paid-byte", count: 100_000))
        let data = try JSONEncoder.nodus.encode(raw)
        try await cache.storeIndexedGeneration(data, vaultId: "vault", recordId: record, indexId: "autonomous:completion-index:v1", entity: record)
        try await cache.freezeForRevocation(true)
        let snapshot = try await cache.authoringRecoverySnapshot(vaultIds: ["vault"])
        let response = try #require(snapshot.records.first { $0.generationKind == "completion" })
        #expect(response.data.isEmpty && response.source != nil)
        let saved = try await f.recovery.preserve(snapshot: snapshot, pairing: old, macDeviceId: "real-mac")
        let id = try #require(UUID(uuidString: saved.archiveURL.deletingPathExtension().lastPathComponent))
        let lease = try await f.recovery.exportFile(id: id)
        let zip = try Archive(url: lease.url, accessMode: .read), entry = try #require(zip.first { $0.path.hasPrefix("provider-completion-") })
        var exported = Data(); _ = try zip.extract(entry) { exported.append($0) }
        #expect(exported == data)
        try await f.recovery.completeRevocation(saved)
        let fresh = try f.pairing("figure-raw-restored"), destination = try f.cache(fresh.id)
        _ = try await f.recovery.adopt(pairing: fresh, macDeviceId: "real-mac", cache: destination)
        await #expect(throws: (any Error).self) { try await destination.requireGenerationExecutionAllowed(vaultId: "vault", generationId: generation.uuidString.lowercased()) }
        #expect(try await destination.data(vaultId: "vault", domain: .researchGeneration, recordId: record) == data)
        try? f.keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: fresh.id))
        try? f.keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: old.id)); try? f.keychain.remove(saved.recoveryKeyName)
    }
}
