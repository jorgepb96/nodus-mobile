import AVFoundation
@preconcurrency import MediaPlayer
import UIKit
import XCTest
@testable import Nodus

nonisolated final class LinkAudioCompatibilityTests: XCTestCase {
    @MainActor
    func testSystemNowPlayingHasArtworkAndSeekControls() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 900))
        let cover = renderer.pngData { context in
            UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 900))
        }
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "podcast", withExtension: "m4a"))
        let player = try AVAudioPlayer(data: Data(contentsOf: file)); XCTAssertTrue(player.prepareToPlay())
        let remote = SavedAudioRemoteControls(); defer { remote.unbind() }
        remote.bind(player, title: "Episode with cover", artworkData: cover)
        player.currentTime = 0.4; remote.update()
        let info = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Episode with cover")
        XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "Nodus Link")
        XCTAssertEqual(try XCTUnwrap(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double), player.currentTime, accuracy: 0.01)
        let artwork = try XCTUnwrap(info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        let image = try XCTUnwrap(artwork.image(at: CGSize(width: 300, height: 300)))
        XCTAssertGreaterThan(image.size.width, 0); XCTAssertLessThanOrEqual(image.size.width, 512)
        XCTAssertEqual(MPRemoteCommandCenter.shared().skipBackwardCommand.preferredIntervals, [15])
        XCTAssertEqual(MPRemoteCommandCenter.shared().skipForwardCommand.preferredIntervals, [15])
        XCTAssertTrue(MPRemoteCommandCenter.shared().skipBackwardCommand.isEnabled)
        XCTAssertTrue(MPRemoteCommandCenter.shared().skipForwardCommand.isEnabled)
        remote.bind(player, title: "Episode without cover")
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork], "The previous episode's cover must not leak to one without an image")
        XCTAssertNil(SavedAudioNowPlayingInfo.artwork(Data("invalid image".utf8)))
    }
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
            let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).pngData { context in
                UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
            }
            try await playback.prepare(Data(contentsOf: opus), title: "Opus fixture", artworkData: image)
            XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Opus fixture")
            XCTAssertNotNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork])
            XCTAssertGreaterThan(playback.duration, 0.9)
            XCTAssertLessThan(playback.duration, 1.2)
            try await playback.play()
            try await Task.sleep(for: .milliseconds(500))
            await playback.poll()
            XCTAssertGreaterThan(playback.position, 0.1, "The actual Opus decoder must advance")
            await playback.pause()
            for target in [0.25, 0.75] {
                async let oldClock: Void = playback.poll()
                await playback.seek(target)
                await oldClock
                await playback.poll()
                XCTAssertEqual(playback.position, target, accuracy: 0.03, "A previous clock read cannot undo the chosen seek")
            }
            await playback.seek(playback.duration)
            try await playback.play()
            await playback.poll()
            XCTAssertTrue(playback.playing, "An ended Opus episode must replay when Play is pressed")
            XCTAssertLessThan(playback.position, playback.duration / 2)
            async let oldClock: Void = playback.poll()
            await playback.pause()
            await oldClock
            await playback.poll()
            XCTAssertFalse(playback.playing, "A clock read cannot undo an explicit pause")
            await playback.stop()
        } catch {
            let state = try? await playback.webView.callAsyncJavaScript("const a=document.getElementById('audio');return {ready:a?.readyState,network:a?.networkState,error:a?.error?.code,hidden:document.hidden};", arguments: [:], in: nil, contentWorld: .page)
            print("Opus fixture state: \(String(describing: state))")
            await playback.stop(); throw error
        }
    }
}
