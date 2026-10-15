import XCTest
import UIKit
import Vision
import NodusKit
@testable import Nodus

nonisolated final class CompanionDocumentVisualRuntimeTests: XCTestCase {
    private let owner = String(repeating: "a", count: 64)
    private let assetID = "20e4f7bc-a476-4a3c-a216-50d354ed59c9"

    @MainActor
    private func input(includeAsset: Bool = true) throws -> JSONValue {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let bytes = try XCTUnwrap(image.pngData())
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 400 120'><rect width='400' height='120' fill='#336699'/><text x='24' y='64' font-family='Arial' font-size='24' fill='white'>Captured research figure</text></svg>"
        return .object([
            "owner": .string(owner),
            "view": .object(["schemaVersion": .int(1), "summary": .string("Native document fixture"), "nodes": .array([
                .object(["kind": .string("svg"), "svg": .string(svg), "title": .string("Research visual"), "alt": .string("Blue source diagram")]),
                .object(["kind": .string("table"), "columns": .array([.object(["label": .string("Evidence")]), .object(["label": .string("Value")])]), "rows": .array([.array([.string("Source A"), .int(42)])])]),
                .object(["kind": .string("image"), "attachmentId": .string(assetID), "title": .string("Stored pixels"), "alt": .string("A green source image"), "name": .string("fixture.png"), "mimeType": .string("image/png"), "bytes": .int(Int64(bytes.count)), "width": .int(32), "height": .int(32)])
            ])]),
            "assets": .object(includeAsset ? [assetID: .object(["base64": .string(bytes.base64EncodedString()), "mimeType": .string("image/png")])] : [:])
        ])
    }

    @MainActor
    func testProductionFigureProducesActualPixelsAndReadableTable() async throws {
        let result = try await CompanionDocumentFigureSnapshot.snapshot(input())
        XCTAssertTrue(result.hasPrefix("data:image/png;base64,"))
        let bytes = try XCTUnwrap(Data(base64Encoded: String(result.dropFirst("data:image/png;base64,".count))))
        let image = try XCTUnwrap(UIImage(data: bytes)), raster = try XCTUnwrap(image.cgImage)
        XCTAssertGreaterThanOrEqual(raster.width, 990)
        XCTAssertGreaterThan(raster.height, 200)
        XCTAssertLessThanOrEqual(bytes.count, 8 * 1_048_576)

        // A PNG envelope is insufficient: inspect actual output colors, independent
        // of the simulator's 1x/2x/3x raster scale and the renderer's page margins.
        var pixels = [UInt8](repeating: 0, count: raster.width * raster.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let bitmap = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: raster.width,
                height: raster.height, bitsPerComponent: 8, bytesPerRow: raster.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.draw(raster, in: CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
        }
        var bluePixels = 0, greenPixels = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[index]), green = Int(pixels[index + 1]), blue = Int(pixels[index + 2])
            if abs(red - 51) <= 8, abs(green - 102) <= 8, abs(blue - 153) <= 8, pixels[index + 3] > 240 { bluePixels += 1 }
            if red < 30, green > 220, blue < 30, pixels[index + 3] > 240 { greenPixels += 1 }
        }
        XCTAssertGreaterThan(bluePixels, raster.width * raster.height / 4,
            "The source SVG must occupy its actual blue area in the poster.")
        XCTAssertGreaterThan(greenPixels, 100, "The supplied image bytes must appear in the actual poster.")

        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        recognition.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: raster).perform([recognition])
        let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(text.contains("Evidence"), text)
        XCTAssertTrue(text.contains("Source A"), text)
        let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.png")
        attachment.name = "actual-native-production-document-figure"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testMissingAttachmentCannotProduceASuccessfulPoster() async throws {
        do {
            _ = try await CompanionDocumentFigureSnapshot.snapshot(input(includeAsset: false))
            XCTFail("Missing bytes must not be rendered as a successful document figure.")
        } catch { XCTAssertFalse(error is CancellationError) }
        var invalid = try XCTUnwrap(input().objectValue)
        invalid["owner"] = .string("../unrelated")
        do {
            _ = try await CompanionDocumentFigureSnapshot.snapshot(.object(invalid))
            XCTFail("A different asset owner must not be accepted.")
        } catch { XCTAssertTrue(error is DesktopBridgeError) }
    }

    @MainActor
    func testSVGInspectorUsesRealLayoutInAFreshRestrictedDOM() async throws {
        let result = try await CompanionDocumentSvgEvaluation.evaluate(.object(["script": .string("""
        (async () => {
          document.body.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" width="400" height="120"><text x="10" y="50" font-family="Arial" font-size="24">Measured source label</text></svg>`;
          const text = document.querySelector('text').getBoundingClientRect();
          let blocked = false; try { await fetch('https://example.org/'); } catch { blocked = true; }
          return {width: text.width, height: text.height, networkBlocked: blocked,
            privilegedHandler: typeof window.webkit?.messageHandlers?.nodus !== 'undefined'};
        })()
        """)]))
        let object = try XCTUnwrap(result.objectValue)
        XCTAssertGreaterThan(try XCTUnwrap(object["width"]?.doubleValue), 100)
        XCTAssertGreaterThan(try XCTUnwrap(object["height"]?.doubleValue), 10)
        XCTAssertEqual(object["networkBlocked"], .bool(true))
        XCTAssertEqual(object["privilegedHandler"], .bool(false))
        let fresh = try await CompanionDocumentSvgEvaluation.evaluate(.object(["script": .string("({labels:document.querySelectorAll('text').length, localFile:location.protocol==='file:'})")]))
        XCTAssertEqual(fresh.objectValue?["labels"], .int(0))
        XCTAssertEqual(fresh.objectValue?["localFile"], .bool(false))
    }

    @MainActor
    func testCancellationDoesNotReturnAPartialVisual() async throws {
        let start = Date()
        let task = Task { try await CompanionDocumentSvgEvaluation.evaluate(.object(["script": .string("new Promise(resolve => setTimeout(() => resolve('late'), 5000))")])) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled work cannot return a visual.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}
