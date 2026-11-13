import AVFoundation
import UIKit
import XCTest
@testable import Nodus

nonisolated final class LinkAudioCompatibilityTests: XCTestCase {
    /// AAC (Mac/Windows) and the encoder's Opus fallback (Linux) must both decode.
    @MainActor
    func testSavedDesktopPodcastFormatsPrepareForPlayback() async throws {
        for ext in ["m4a"] {
            let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "podcast", withExtension: ext))
            let player = try AVAudioPlayer(data: Data(contentsOf: file))
            XCTAssertTrue(player.prepareToPlay(), "Saved \(ext) episode must prepare")
            XCTAssertGreaterThan(player.duration, 0.9)
            XCTAssertLessThan(player.duration, 1.2)
        }
        let opus = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "podcast", withExtension: "opus"))
        let playback = OpusPlayback()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(playback.webView)
        playback.webView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; playback.webView.removeFromSuperview() }
        do {
            try await playback.prepare(Data(contentsOf: opus), title: "Opus fixture")
            XCTAssertGreaterThan(playback.duration, 0.9)
            XCTAssertLessThan(playback.duration, 1.2)
            try await playback.play()
            try await Task.sleep(for: .milliseconds(500))
            await playback.poll()
            XCTAssertGreaterThan(playback.position, 0.1, "The actual Opus decoder must advance")
            await playback.stop()
        } catch {
            let state = try? await playback.webView.callAsyncJavaScript("const a=document.getElementById('audio');return {ready:a?.readyState,network:a?.networkState,error:a?.error?.code,hidden:document.hidden};", arguments: [:], in: nil, contentWorld: .page)
            print("Opus fixture state: \(String(describing: state))")
            await playback.stop(); throw error
        }
    }
}
