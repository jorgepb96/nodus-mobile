import AVFoundation
import NodusUI
import Observation
import SwiftUI

/// Playback belongs to the workspace, not a catalogue row, a modal, or a navigation route.
@Observable @MainActor final class LinkPodcastPlayback {
    private(set) var target: SavedAudioTarget?
    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var playing = false
    private(set) var rate: Float = 1
    private(set) var issue: String?
    var showingPlayer = false
    @ObservationIgnored private var native: AVAudioPlayer?
    private var opus: OpusPlayback?
    @ObservationIgnored private var remote = SavedAudioRemoteControls()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var pendingStop: Task<Void, Never>?
    @ObservationIgnored private var seekRevision = 0
    @ObservationIgnored private var revision = UUID()
    var opusWebView: WKWebView? { opus?.webView }

    func start(_ next: SavedAudioTarget) async throws {
        if target?.id == next.id, target?.resumeKey == next.resumeKey {
            if let start = next.initialTimestamp { await seek(start) }
            if !playing { await toggle() }
            return
        }
        stop()
        let current = UUID(); revision = current
        target = next; issue = nil
        await pendingStop?.value
        guard revision == current else { return }
        pendingStop = nil
        let start = next.initialTimestamp ?? next.resumeKey.map { UserDefaults.standard.double(forKey: $0) } ?? 0
        do {
            if ["audio/ogg", "audio/opus"].contains(next.copy.descriptor.mime) {
                let decoder = OpusPlayback(); opus = decoder
                try await decoder.prepare(Data(contentsOf: next.copy.url), title: next.label, position: start, artworkData: next.artworkData)
                guard revision == current else { await decoder.stop(); return }
                try await decoder.play(); duration = decoder.duration
            } else {
                let player = try AVAudioPlayer(data: Data(contentsOf: next.copy.url))
                player.enableRate = true
                guard player.prepareToPlay(), player.duration.isFinite, player.duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
                native = player; duration = player.duration
                player.currentTime = min(duration, max(0, start)); player.rate = rate
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                remote.bind(player, title: next.label, artworkData: next.artworkData)
                guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
            }
            playing = true; position = min(duration, max(0, start))
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.revision == current else { return }
                    await self.poll()
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                }
            }
        } catch {
            guard revision == current else { return }
            stop(); issue = error.localizedDescription; throw error
        }
    }
    private func poll() async {
        let current = revision
        if let opus {
            await opus.poll()
            guard revision == current else { return }
            position = opus.position; duration = opus.duration; playing = opus.playing; rate = opus.rate
        }
        else if let native { position = native.currentTime; playing = native.isPlaying; remote.update() }
        savePosition()
    }
    func toggle() async {
        do {
            if let opus { if opus.playing { await opus.pause() } else { try await opus.play() }; playing = opus.playing }
            else if let native {
                if native.isPlaying { native.pause() }
                else {
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                    try AVAudioSession.sharedInstance().setActive(true)
                    guard native.play() else { throw CocoaError(.fileReadCorruptFile) }
                }
                playing = native.isPlaying; remote.update()
            }
            issue = nil; savePosition()
        } catch { issue = error.localizedDescription }
    }
    func seek(_ seconds: Double) async {
        let value = min(duration, max(0, seconds.isFinite ? seconds : 0))
        seekRevision += 1
        let current = seekRevision
        position = value; savePosition()
        if let opus { await opus.seek(value) } else { native?.currentTime = value; remote.update() }
        guard seekRevision == current else { return }
        position = value; savePosition()
    }
    func changeRate(_ value: Float) async {
        if let opus { await opus.changeRate(value) } else { native?.rate = value; remote.update() }
        rate = value
    }
    func savePosition() {
        guard let key = target?.resumeKey, duration > 0 else { return }
        UserDefaults.standard.set(position >= duration - 1 ? 0 : position, forKey: key)
    }
    func stop() {
        savePosition(); seekRevision += 1; revision = UUID(); ticker?.cancel(); ticker = nil
        remote.unbind(); native?.stop(); native = nil
        if let decoder = opus {
            let previous = pendingStop
            pendingStop = Task { await previous?.value; await decoder.stop() }
        }; opus = nil
        target = nil; playing = false; duration = 0; position = 0; rate = 1
        showingPlayer = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

import WebKit
