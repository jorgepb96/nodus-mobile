import Foundation
import Testing
import UIKit
import NodusKit
@testable import Nodus

@Suite("Native reader image presentation")
@MainActor
struct ReaderImagePresentationTests {
    @Test("Wide originals retain their bytes and decode only within the chosen pixel budget")
    func boundedPixels() throws {
        let format = UIGraphicsImageRendererFormat();format.scale = 1;format.opaque = true
        let original = UIGraphicsImageRenderer(size:CGSize(width:8000,height:40),format:format).image { context in UIColor.systemPurple.setFill();context.fill(CGRect(x:0,y:0,width:8000,height:40)) }
        let bytes = try #require(original.pngData()),preview = try ReaderRasterImage.preview(bytes,maxPixelSize:1024)
        #expect(max(preview.cgImage!.width,preview.cgImage!.height) <= 1024)
        #expect(preview.size.width > preview.size.height)
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        var lease: PrivateBridgeFileLease? = try PrivateBridgeFileLease.write(bytes,filename:"original.png",directory:directory)
        let url = try #require(lease?.url)
        #expect(try Data(contentsOf:url) == bytes)
        lease = nil
        #expect(!FileManager.default.fileExists(atPath:url.path))
    }
    @Test("Corrupt rasters and an unbounded display decode fail honestly")
    func malformedImage() {
        #expect(throws:DesktopBridgeError.malformedResponse) { try ReaderRasterImage.preview(Data([0,1,2,3])) }
        #expect(throws:DesktopBridgeError.malformedResponse) { try ReaderRasterImage.preview(Data(),maxPixelSize:100_000) }
    }
}
