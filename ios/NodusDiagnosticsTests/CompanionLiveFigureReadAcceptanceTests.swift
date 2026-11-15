import CryptoKit
import Foundation
import NodusKit
import PDFKit
import UIKit
import XCTest
@testable import Nodus

/// Actual pinned HTTPS and production reader/download/PDF adapters, on a marked
/// laboratory copy only. Provider calls and UI acceptance are separate evidence.
final class CompanionLiveFigureReadAcceptanceTests: XCTestCase {
    private enum SetupError: Error { case explicitCopiedLabRequired }
    private struct Fixture {
        let session: SpaceSession
        let reportID: String
        let assets: [JSONValue]
        let vault: String
        let cache: PrivateBridgeCache
    }

    @MainActor private func fixture(flag: String) throws -> Fixture {
        continueAfterFailure = false
        executionTimeAllowance = 180
        let env = ProcessInfo.processInfo.environment
        guard env[flag] == "1" else {
            XCTFail("This selected diagnostic requires explicit copied-lab configuration.")
            throw SetupError.explicitCopiedLabRequired
        }
        let grantID = try XCTUnwrap(env["NODUS_ACCEPTANCE_DIAGNOSTIC_GRANT"])
        let vault = try XCTUnwrap(env["NODUS_ACCEPTANCE_FIGURE_VAULT"])
        let store = DesktopBridgePairingStore()
        let grant = try XCTUnwrap(store.pairings().first { $0.id == grantID })
        XCTAssertEqual(grant.certificateFingerprint, env["NODUS_ACCEPTANCE_DIAGNOSTIC_PIN"])
        XCTAssertEqual(grant.macDeviceId, env["NODUS_ACCEPTANCE_DIAGNOSTIC_MAC"])
        guard grant.vaultIds.contains(vault), grant.certificateFingerprint == env["NODUS_ACCEPTANCE_DIAGNOSTIC_PIN"],
              grant.macDeviceId == env["NODUS_ACCEPTANCE_DIAGNOSTIC_MAC"] else { throw SetupError.explicitCopiedLabRequired }
        let connection = try XCTUnwrap(AppModel.storedConnections().first { $0.desktopPairingId == grantID && $0.vaultId == vault })
        let client = try XCTUnwrap(ConnectionClient.make(for: connection))
        let session = SpaceSession(connection: connection, client: client)
        let bytes = Data(try XCTUnwrap(env["NODUS_ACCEPTANCE_FIGURE_ASSETS"]).utf8)
        let assets = try JSONDecoder.nodus.decode([JSONValue].self, from: bytes)
        XCTAssertEqual(assets.count, 2)
        return Fixture(session: session, reportID: try XCTUnwrap(env["NODUS_ACCEPTANCE_FIGURE_REPORT"]),
            assets: assets, vault: vault, cache: try PrivateBridgeCache(pairingId: grantID))
    }

    @MainActor
    func testActualMacFiguresReadAndChosenPackCommitWithoutAnAuthoringSession() async throws {
        let fixture = try fixture(flag: "NODUS_ACCEPTANCE_FIGURE_READ")
        let session = fixture.session
        let (vault, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
        XCTAssertEqual(vault, fixture.vault)
        let client = DesktopBridgeClient(pairing: pairing, token: token)
        let detail = try await client.corpus(vaultId: vault, path: "deep-research/\(fixture.reportID)")
        let native = try JSONDecoder.nodus.decode(JSONValue.self, from: detail.data)
        let draft = try XCTUnwrap(native.objectValue?["report"]?.objectValue?["draft"])
        XCTAssertEqual(session.aiExecutionMode, .live, "This beta keeps model execution on the owning Mac.")
        let receivedContext = try await CompanionResearchFigures.context(session: session, reportID: fixture.reportID, expectedDraft: draft)
        let context = try XCTUnwrap(receivedContext)
        XCTAssertEqual(context.objectValue?["origin"], .string("live-mac"))
        XCTAssertEqual(context.objectValue?["manifest"]?.objectValue?["figures"]?.arrayValue?.count, 2)
        for asset in fixture.assets {
            let fields = try XCTUnwrap(asset.objectValue)
            let id = try XCTUnwrap(fields["id"]?.stringValue), owner = try XCTUnwrap(fields["owner"]?.stringValue)
            let image = "nodus-image://chat/\(owner)/\(id)"
            let capability = "nodus-capability://chat/\(owner)/\(id)"
            let source = CompanionResearchFigures.allows(image, context: context) ? image : capability
            let first = try await CompanionLiveDocumentVisualRead.chunk(source, context: context, session: session, offset: 0, count: 524288)
            XCTAssertEqual(first.data.count, 524288)
            XCTAssertGreaterThan(first.total, 524288)
            let loaded = try await CompanionResearchFigures.load(source, context: context, session: session)
            XCTAssertEqual(loaded.data.count, fields["byteCount"]?.intValue)
            XCTAssertEqual(digest(loaded.data), fields["sha256"]?.stringValue)
            XCTAssertNotNil(UIImage(data: loaded.data))
        }
        let manifest = try XCTUnwrap(context.objectValue?["manifest"])
        let captured = try await CompanionDownloadedResearchFigures.capture(session: session, reportID: fixture.reportID,
            manifest: manifest, draft: draft, remaining: PrivateBridgeCache.maximumSelectedCopyBytes)
        XCTAssertEqual(captured.context.objectValue?["assets"]?.arrayValue?.count, 2)
        let html = try await ReportDocument.html(session: session, reportId: fixture.reportID)
        let entry: JSONValue = .object(["detail": native, "documentHTML": .string(html), "figureContext": captured.context])
        let copy: JSONValue = .object(["version": .int(1), "entries": .array([entry])])
        _ = try CompanionResearchCorpusCopy(copies: [copy])
        let current = try await client.operation(vaultId: vault, method: "getDocumentVisuals", args: [.object(["kind": .string("deep-research"), "id": .string(fixture.reportID)])])
        XCTAssertEqual(current, manifest, "A changed Mac source cannot be committed as the captured pack.")
        guard current == manifest else { throw DesktopBridgeError.malformedResponse }
        let packID = try PrivateBridgeCache.readPackSelectionId(vaultId: vault, recordIds: ["reports:\(fixture.reportID)"])
        _ = try await fixture.cache.saveReadPack(id: packID, vaultId: vault, title: "Isolated figures acceptance",
            expiresAt: Date().addingTimeInterval(7 * 86400), records: captured.records + [
                .init(domain: .corpus, recordId: CompanionResearchCorpusCopy.recordId, data: try JSONEncoder.nodus.encode(copy))])
        let receivedDownload = try await CompanionResearchFigures.context(session: session, reportID: fixture.reportID, downloadedOnly: true)
        let downloaded = try XCTUnwrap(receivedDownload)
        XCTAssertEqual(downloaded.objectValue?["origin"], .string("downloaded-mac"))
        try attach(.object(["reportID": .string(fixture.reportID), "vaultID": .string(vault), "packID": .string(packID.uuidString),
            "transport": .string("pinned-https"), "assets": .array(fixture.assets), "providerCalls": .int(0)]), name: "actual-native-figure-read-and-pack.json")
    }

    /// Explicit paid-provider acceptance, distinct from provider-free figure transfer.
    @MainActor
    func testReportQuestionStreamsFromActualMacAndCitesItsNumberedPassage() async throws {
        let fixture = try fixture(flag: "NODUS_ACCEPTANCE_PAGE_CHAT")
        executionTimeAllowance = 360
        let session = fixture.session
        let (vault, pairing, token) = try privateBridgeConnection(session, domain: .researchGeneration)
        let client = DesktopBridgeClient(pairing: pairing, token: token)
        let detail = try await client.corpus(vaultId: vault, path: "deep-research/\(fixture.reportID)")
        let saved = try JSONDecoder.nodus.decode(JSONValue.self, from: detail.data)
        let draft = try XCTUnwrap(saved.objectValue?["report"]?.objectValue?["draft"]?.objectValue)
        let markdown = try XCTUnwrap(draft["draftMarkdown"]?.stringValue)
        let paragraphs = markdown.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertTrue(paragraphs[1].contains("verde") && paragraphs[1].contains("azul"))
        let passages = paragraphs.enumerated().map { PageChatPassage(number: $0.offset + 1, path: [$0.offset], text: $0.element) }
        let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vault)
        let before = Set(await ledger.all().map(\.id))
        let subject = PageChatSubject(id: fixture.reportID, title: "Aceptación de figuras Mac 0.1.0", session: session)
        let store = PageChatStore.shared(for: subject.storeKey)
        defer { PageChatStore.forget(subject.storeKey) }
        XCTAssertTrue(store.turns.isEmpty)
        let question = "¿De qué colores son la imagen y el recurso descritos en el segundo pasaje? Responde en una frase, basada en ese pasaje, y cita su número."
        store.draft = question
        store.ask(question, passages: passages,
            subject: subject, ai: AISettings())
        let deadline = Date().addingTimeInterval(300)
        while store.isThinking && Date() < deadline { try await Task.sleep(for: .milliseconds(300)) }
        XCTAssertFalse(store.isThinking, "The actual Mac provider must finish within the diagnostic budget.")
        XCTAssertNil(store.failure, store.failure ?? "")
        XCTAssertFalse(store.canResumeMac)
        XCTAssertEqual(store.turns.count, 2)
        let answer = try XCTUnwrap(store.turns.last)
        XCTAssertTrue(answer.text.localizedCaseInsensitiveContains("verde") && answer.text.localizedCaseInsensitiveContains("azul"), answer.text)
        XCTAssertTrue(answer.passages.contains(2), "The answer must cite the actual numbered paragraph: " + answer.text)
        let added = await ledger.all().filter { !before.contains($0.id) && $0.method == "researchChatStream" }
        XCTAssertEqual(added.count, 1, "One reader question must create only one Mac request identity.")
        let receipt = try XCTUnwrap(added.first)
        let job = try await client.readJob(vaultId: vault, id: XCTUnwrap(receipt.jobId))
        XCTAssertEqual(job.state, .available)
        XCTAssertTrue(job.events.contains { $0.channel == "research:chatStream:delta" }, "This must exercise actual streamed response events.")
        let config = try await client.operation(vaultId: vault, method: "getMobileLiveChatConfiguration", args: [.string("research")])
        try attach(.object(["reportID": .string(fixture.reportID), "requestID": .string(receipt.id), "jobID": .string(job.id),
            "transport": .string("pinned-https"), "execution": .string("mac-live"), "macModel": config.objectValue?["model"] ?? .null,
            "answer": .string(answer.text), "passages": .array(answer.passages.map { .int(Int64($0)) })]), name: "actual-native-reader-mac-stream.json")
    }

    @MainActor
    func testChosenFiguresAndPDFRemainReadableWithOwningBridgeActuallyStopped() async throws {
        let fixture = try fixture(flag: "NODUS_ACCEPTANCE_FIGURE_OFFLINE")
        let origin = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_OFFLINE_ORIGIN"])
        let url = try XCTUnwrap(URL(string: origin + "/bridge/v2/capabilities"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4; configuration.timeoutIntervalForResource = 5
        let probe = URLSession(configuration: configuration)
        defer { probe.invalidateAndCancel() }
        do {
            _ = try await probe.data(from: url)
            XCTFail("The owning Bridge must actually be stopped for this phase.")
            throw SetupError.explicitCopiedLabRequired
        } catch let error as URLError {
            XCTAssertTrue([.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .timedOut].contains(error.code), "A TLS or permission failure does not prove disconnection.")
        }
        let receivedContext = try await CompanionResearchFigures.context(session: fixture.session, reportID: fixture.reportID, downloadedOnly: true)
        let context = try XCTUnwrap(receivedContext)
        XCTAssertEqual(context.objectValue?["origin"], .string("downloaded-mac"))
        for asset in try XCTUnwrap(context.objectValue?["assets"]?.arrayValue) {
            let source = try XCTUnwrap(asset.objectValue?["source"]?.stringValue)
            let loaded = try await CompanionResearchFigures.load(source, context: context, session: fixture.session)
            XCTAssertEqual(digest(loaded.data), asset.objectValue?["sha256"]?.stringValue)
        }
        let html = try await ReportDocument.html(session: fixture.session, reportId: fixture.reportID, downloadedOnly: true)
        let bytes = try await ReportDocument.pdf(from: html, session: fixture.session, figureContext: context)
        let document = try XCTUnwrap(PDFDocument(data: bytes))
        XCTAssertGreaterThan(document.pageCount, 0)
        var green = 0
        for index in 0..<document.pageCount { green += try greenPixels(try XCTUnwrap(document.page(at: index))) }
        XCTAssertGreaterThan(green, 10000, "The offline PDF must contain actual saved green pixels.")
        let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "com.adobe.pdf")
        attachment.name = "actual-mac-chosen-figures-offline.pdf"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func attach(_ value: JSONValue, name: String) throws {
        let attachment = XCTAttachment(data: try JSONEncoder.nodus.encode(value), uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func greenPixels(_ page: PDFPage) throws -> Int {
        let raster = try XCTUnwrap(page.thumbnail(of: CGSize(width: 595, height: 842), for: .mediaBox).cgImage)
        var pixels = [UInt8](repeating: 0, count: raster.width * raster.height * 4)
        try pixels.withUnsafeMutableBytes { storage in
            let canvas = try XCTUnwrap(CGContext(data: storage.baseAddress, width: raster.width, height: raster.height,
                bitsPerComponent: 8, bytesPerRow: raster.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            canvas.draw(raster, in: CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
        }
        return stride(from: 0, to: pixels.count, by: 4).reduce(0) { $0 + (pixels[$1] < 40 && pixels[$1 + 1] > 210 && pixels[$1 + 2] < 50 ? 1 : 0) }
    }
}
