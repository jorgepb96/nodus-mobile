import Foundation
import NodusKit
import XCTest
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
