import AVFoundation
import ImageIO
@preconcurrency import MediaPlayer
import NodusUI
import SwiftUI
import UIKit

struct SavedAudioTarget: Identifiable {
    let id: String
    let label: String
    let copy: PrivateBridgeFileCopy
    var initialTimestamp: Double? = nil
    var resumeKey: String? = nil
    var backgroundPlayback = false
    var artworkData: Data? = nil
}

/// The player receives only the verified, protected local copy; no Mac URL or credential.
struct SavedAudioPlayer: View {
    let target: SavedAudioTarget
    let accent: Color
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVAudioPlayer?
    @State private var duration = 0.0
    @State private var playing = false
    @State private var rate: Float = 1
    @State private var issue: String?
    @State private var remote = SavedAudioRemoteControls()

    var body: some View {
        if ["audio/ogg", "audio/opus"].contains(target.copy.descriptor.mime) {
            OpusSavedAudioPlayer(target: target, accent: accent)
        } else { nativeBody }
    }
    private var nativeBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label(target.label, systemImage: "waveform").font(.title2).bold()
                if target.copy.offline {
                    Label("Downloaded copy", systemImage: "wifi.slash").foregroundStyle(.secondary)
                        .accessibilityIdentifier("saved-audio-offline")
                }
                if let issue { Text(issue).foregroundStyle(Color.nodusDanger).accessibilityIdentifier("saved-audio-error") }
                SavedAudioTimeline(player: player, duration: duration, onSeek: { remote.update() })
                HStack(spacing: 24) {
                    Button { seek(-15) } label: { Image(systemName: "gobackward.15").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("Back 15 seconds").disabled(player == nil)
                        .accessibilityIdentifier("saved-audio-back")
                    Spacer()
                    Button(action: toggle) {
                        Label(playing ? String(localized: "Pause") : String(localized: "Play"), systemImage: playing ? "pause.fill" : "play.fill")
                            .frame(minWidth: 80, minHeight: 44)
                    }.buttonStyle(.borderedProminent).tint(accent)
                        .foregroundStyle(accent.relativeLuminance > 0.179 ? Color.black : Color.white)
                        .disabled(player == nil)
                        .accessibilityIdentifier("saved-audio-play")
                    Spacer()
                    Button { seek(15) } label: { Image(systemName: "goforward.15").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("Forward 15 seconds").disabled(player == nil)
                        .accessibilityIdentifier("saved-audio-forward")
                }
                Menu {
                    Picker("Playback speed", selection: $rate) {
                        ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { value in Text("\(value.formatted())×").tag(value) }
                    }
                } label: {
                    HStack {
                        Label("Playback speed", systemImage: "speedometer")
                        Spacer()
                        Text("\(rate.formatted())×").monospacedDigit()
                    }.frame(minHeight: 44)
                }.accessibilityIdentifier("saved-audio-speed")
                ShareLink(item: target.copy.url) { Label("Export audio", systemImage: "square.and.arrow.up") }
                    .frame(minHeight: 44).accessibilityIdentifier("saved-audio-export")
            }.padding(24).frame(maxWidth: 650)
        }
        // Keep scrollable actions above the 44-point close control and its bottom margin.
        .safeAreaPadding(.bottom, 76)
        .accessibilityIdentifier("saved-audio-player-scroll")
        .tint(accent.nodusReadable)
        .navigationTitle("Saved narration").navigationBarTitleDisplayMode(.inline)
        .onChange(of: rate) { _, value in player?.rate = value; remote.update(); trace("rate") }
        .onChange(of: scenePhase) { _, phase in
            trace("scene:\(phase)")
            if phase != .active {
                savePosition()
                if !target.backgroundPlayback { player?.pause(); playing = false }
            }
        }
        .task {
            do {
                let audio = try target.backgroundPlayback
                    ? AVAudioPlayer(data: Data(contentsOf: target.copy.url))
                    : AVAudioPlayer(contentsOf: target.copy.url)
                audio.enableRate = true; audio.rate = rate
                guard audio.prepareToPlay(), audio.duration.isFinite, audio.duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
                player = audio; duration = audio.duration
                if let timestamp = target.initialTimestamp ?? target.resumeKey.map({ UserDefaults.standard.double(forKey: $0) }), timestamp.isFinite, timestamp >= 0 {
                    audio.currentTime = min(audio.duration, timestamp)
                }
                if target.backgroundPlayback { remote.bind(audio, title: target.label, artworkData: target.artworkData) }
                trace("prepared")
                var ticks = 0
                while !Task.isCancelled {
                    playing = audio.isPlaying
                    ticks += 1
                    if ticks % 25 == 0 { savePosition(); remote.update() }
                    try await Task.sleep(for: .milliseconds(200))
                }
            } catch is CancellationError { }
            catch { issue = String(localized: "The saved audio could not be opened.") }
        }
        .onDisappear {
            savePosition(); remote.unbind()
            player?.stop(); player = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            // The protected file lease owns deletion. Another open control may
            // still need the same verified copy to save its chosen download.
        }
    }
    private func savePosition() {
        guard let key = target.resumeKey, let player else { return }
        UserDefaults.standard.set(player.currentTime >= player.duration - 1 ? 0 : player.currentTime, forKey: key)
    }
    private func toggle() {
        trace("toggle")
        guard let player else { return }
        if player.isPlaying { player.pause(); playing = false; remote.update(); trace("paused"); return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            player.rate = rate
            guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
            playing = true; issue = nil; remote.update()
            trace("playing")
        } catch { issue = String(localized: "The saved audio could not be played. Try again.") }
    }
    private func trace(_ event: String) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_AUDIO_TRACE"] == "1" {
            print("[acceptance-saved-audio] \(event) player:\(player?.isPlaying.description ?? "nil") displayed:\(playing) time:\(player?.currentTime ?? -1) rate:\(rate)")
        }
        #endif
    }
    private func seek(_ delta: Double) {
        guard let player else { return }
        trace("seek:\(delta)")
        player.currentTime = min(duration, max(0, player.currentTime + delta))
        remote.update(); trace("seeked")
    }
}

/// Clock updates stay inside the timeline, preserving the open speed menu and
/// the identity of playback controls while audio advances.
private struct SavedAudioTimeline: View {
    let player: AVAudioPlayer?
    let duration: Double
    let onSeek: () -> Void
    @State private var position = 0.0

    var body: some View {
        VStack(spacing: 24) {
            Slider(value: Binding(get: { position }, set: { value in
                position = value
                player?.currentTime = value
                onSeek()
            }), in: 0...max(duration, 0.001))
                .disabled(player == nil).accessibilityLabel("Playback position")
                .accessibilityHint(Self.clock(position)).accessibilityIdentifier("saved-audio-seek")
            HStack {
                Text(Self.clock(position)).accessibilityIdentifier("saved-audio-elapsed")
                Spacer()
                Text(Self.clock(duration))
            }.monospacedDigit().foregroundStyle(.secondary)
        }
        .task(id: player.map(ObjectIdentifier.init)) {
            while !Task.isCancelled {
                position = player?.currentTime ?? 0
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
            }
        }
    }
    private static func clock(_ seconds: Double) -> String {
        let value = Int(max(0, seconds)); return String(format: "%d:%02d", value / 60, value % 60)
    }
}


/// Own only our command targets. Closing one player must never remove another app's targets.
@MainActor
final class SavedAudioRemoteControls {
    private weak var player: AVAudioPlayer?
    private var title = ""
    private var artwork: MPMediaItemArtwork?
    private var targets: [(MPRemoteCommand, Any)] = []
    func bind(_ player: AVAudioPlayer, title: String, artworkData: Data? = nil) {
        unbind(); self.player = player; self.title = title
        artwork = SavedAudioNowPlayingInfo.artwork(artworkData)
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true; center.pauseCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true; center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.isEnabled = true; center.skipForwardCommand.preferredIntervals = [15]
        targets.append((center.playCommand, center.playCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                do {
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                    try AVAudioSession.sharedInstance().setActive(true)
                    self?.player?.play(); self?.update()
                } catch { self?.player?.pause(); self?.update() }
            }; return .success
        }))
        targets.append((center.pauseCommand, center.pauseCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in self?.player?.pause(); self?.update() }; return .success
        }))
        targets.append((center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime, position.isFinite else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let player = self?.player else { return }
                player.currentTime = min(player.duration, max(0, position)); self?.update()
            }; return .success
        }))
        for (command, delta) in [(center.skipBackwardCommand, -15.0), (center.skipForwardCommand, 15.0)] {
            targets.append((command, command.addTarget { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let player = self?.player else { return }
                    player.currentTime = min(player.duration, max(0, player.currentTime + delta)); self?.update()
                }; return .success
            }))
        }
        update()
    }
    func update() {
        guard let player else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = SavedAudioNowPlayingInfo.metadata(title: title,
            duration: player.duration, position: player.currentTime, playing: player.isPlaying, rate: player.rate, artwork: artwork)
    }
    func unbind() {
        guard !targets.isEmpty else { return }
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll(); player = nil; artwork = nil; MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}

@MainActor
enum SavedAudioNowPlayingInfo {
    static func image(_ data: Data?) -> UIImage? {
        guard let data, data.count <= 8 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 512,
                 kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
    static func artwork(_ data: Data?) -> MPMediaItemArtwork? {
        guard let thumbnail = image(data) else { return nil }
        return MPMediaItemArtwork(boundsSize: thumbnail.size) { @Sendable _ in thumbnail }
    }
    static func metadata(title: String, duration: Double, position: Double, playing: Bool, rate: Float,
                         artwork: MPMediaItemArtwork?) -> [String: Any] {
        var info: [String: Any] = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyAlbumTitle: "Nodus Link",
            MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? rate : 0, MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue, MPNowPlayingInfoPropertyIsLiveStream: false]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        return info
    }
}
