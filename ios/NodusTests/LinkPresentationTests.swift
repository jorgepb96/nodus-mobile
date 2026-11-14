import Foundation
import NodusKit
import XCTest
import WebKit
@testable import Nodus

nonisolated final class LinkPresentationTests: XCTestCase {
    @MainActor
    func testLocalReaderHostRestartsWithoutReturningTheDeadOrigin() async throws {
        let host = LocalSurfaceHost()
        defer { host.restart() }
        let first = try await host.documentURL()
        let (_, response) = try await URLSession.shared.data(from: first)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        host.restart()
        let second = try await host.documentURL()
        let (html, nextResponse) = try await URLSession.shared.data(from: second)
        XCTAssertEqual((nextResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: html, as: UTF8.self).contains("surface.iife.js"))
        XCTAssertTrue(host.owns(second))
    }

    @MainActor
    func testInlineCitationsHaveOneReadableStyleInBothThemes() async throws {
        let configuration = WKWebViewConfiguration()
        LinkReaderPresentation.install(in: configuration)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 500), configuration: configuration)
        defer { web.stopLoading() }
        web.loadHTMLString("""
            <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
            <style>.citation-link{display:inline-flex;padding:20px;border:1px solid red;background:red;color:black}body{font-size:16px}</style>
            </head><body><article class="link-reader"><div class="md"><p>Una idea con
            <button class="citation-link" data-citation-kind="work">Una referencia extensa a una obra con varias palabras (2026)</button>
            y su evidencia.</p></div></article></body></html>
            """, baseURL: nil)
        var ready = false
        for _ in 0..<150 {
            ready = (try? await web.evaluateJavaScript("document.readyState==='complete' && !!document.getElementById('nodus-link-presentation')")) as? Bool == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(ready, "The actual bundled mobile stylesheet must load")
        for dark in [false, true] {
            let result = try await web.callAsyncJavaScript("""
                document.documentElement.classList.toggle('dark',dark);
                const cite=document.querySelector('.citation-link'),style=getComputedStyle(cite);
                const panel=document.querySelector('article').getBoundingClientRect();
                return {display:style.display,background:style.backgroundColor,border:style.borderTopWidth,
                  width:cite.getBoundingClientRect().width,panel:panel.width,color:style.color,font:style.fontSize};
                """, arguments: ["dark": dark], in: nil, contentWorld: .page) as? [String: Any]
            let values = try XCTUnwrap(result)
            XCTAssertEqual(values["display"] as? String, "inline")
            XCTAssertEqual(values["background"] as? String, "rgba(0, 0, 0, 0)")
            XCTAssertEqual(values["border"] as? String, "0px")
            XCTAssertEqual(values["font"] as? String, "16px")
            XCTAssertEqual(values["color"] as? String, dark ? "rgb(180, 176, 255)" : "rgb(79, 70, 199)")
            XCTAssertLessThanOrEqual(try XCTUnwrap(values["width"] as? Double), try XCTUnwrap(values["panel"] as? Double))
        }
    }

    @MainActor
    func testClosingPodcastPresentationKeepsPlaybackAndSeekPosition() async throws {
        let file = try XCTUnwrap(Bundle(for: LinkAudioCompatibilityTests.self).url(forResource: "podcast", withExtension: "m4a"))
        let bytes = try Data(contentsOf: file)
        let lease = try PrivateBridgeFileLease.write(bytes, filename: "podcast.m4a")
        let descriptor = try JSONDecoder().decode(DesktopBridgeFileDescriptor.self, from: JSONSerialization.data(withJSONObject: [
            "kind": "podcastAudio", "id": "presentation-fixture", "filename": "podcast.m4a", "mime": "audio/mp4",
            "byteSize": bytes.count, "sha256": String(repeating: "a", count: 64), "chunkSize": 1024
        ]))
        let key = "nodus-test-playback-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let target = SavedAudioTarget(id: "presentation-fixture", label: "Saved episode", copy: PrivateBridgeFileCopy(url: lease.url, descriptor: descriptor, offline: false, lease: lease), resumeKey: key, backgroundPlayback: true)
        let playback = LinkPodcastPlayback(); defer { playback.stop() }
        try await playback.start(target)
        playback.showingPlayer = true
        playback.showingPlayer = false
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(playback.playing, "Dismissing a presentation must not stop the session's player")
        await playback.seek(0.3)
        XCTAssertEqual(playback.position, 0.3, accuracy: 0.03)
        XCTAssertEqual(playback.target?.id, target.id)
        playback.stop()
        XCTAssertNil(playback.target)
        XCTAssertFalse(playback.playing)
    }
}
