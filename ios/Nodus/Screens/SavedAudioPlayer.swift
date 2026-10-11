import AVFoundation
import NodusUI
import SwiftUI

struct SavedAudioTarget: Identifiable {
    let id: String
    let label: String
    let copy: PrivateBridgeFileCopy
    var initialTimestamp: Double? = nil
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label(target.label, systemImage: "waveform").font(.title2).bold()
                if target.copy.offline {
                    Label("Downloaded copy", systemImage: "wifi.slash").foregroundStyle(.secondary)
                        .accessibilityIdentifier("saved-audio-offline")
                }
                if let issue { Text(issue).foregroundStyle(Color.nodusDanger).accessibilityIdentifier("saved-audio-error") }
                SavedAudioTimeline(player: player, duration: duration)
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
        .onChange(of: rate) { _, value in player?.rate = value; trace("rate") }
        .onChange(of: scenePhase) { _, phase in
            trace("scene:\(phase)")
            if phase != .active { player?.pause(); playing = false }
        }
        .task {
            do {
                let audio = try AVAudioPlayer(contentsOf: target.copy.url)
                audio.enableRate = true; audio.rate = rate
                guard audio.prepareToPlay(), audio.duration.isFinite, audio.duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
                player = audio; duration = audio.duration
                if let timestamp = target.initialTimestamp, timestamp.isFinite, timestamp >= 0 {
                    audio.currentTime = min(audio.duration, timestamp)
                }
                trace("prepared")
                while !Task.isCancelled {
                    playing = audio.isPlaying
                    try await Task.sleep(for: .milliseconds(200))
                }
            } catch is CancellationError { }
            catch { issue = String(localized: "The saved audio could not be opened.") }
        }
        .onDisappear {
            player?.stop(); player = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            // The protected file lease owns deletion. Another open control may
            // still need the same verified copy to save its chosen download.
        }
    }
    private func toggle() {
        trace("toggle")
        guard let player else { return }
        if player.isPlaying { player.pause(); playing = false; trace("paused"); return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            player.rate = rate
            guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
            playing = true; issue = nil
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
        player.currentTime = min(duration, max(0, player.currentTime + delta))
    }
}

/// Clock updates stay inside the timeline, preserving the open speed menu and
/// the identity of playback controls while audio advances.
private struct SavedAudioTimeline: View {
    let player: AVAudioPlayer?
    let duration: Double
    @State private var position = 0.0
    @State private var seeking = false

    var body: some View {
        VStack(spacing: 24) {
            Slider(value: $position, in: 0...max(duration, 0.001)) { editing in
                seeking = editing
                if !editing { player?.currentTime = position }
            }.disabled(player == nil).accessibilityLabel("Playback position")
                .accessibilityValue(Self.clock(position)).accessibilityIdentifier("saved-audio-seek")
            HStack {
                Text(Self.clock(position)).accessibilityIdentifier("saved-audio-elapsed")
                Spacer()
                Text(Self.clock(duration))
            }.monospacedDigit().foregroundStyle(.secondary)
        }
        .task(id: player.map(ObjectIdentifier.init)) {
            while !Task.isCancelled {
                if !seeking { position = player?.currentTime ?? 0 }
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
            }
        }
    }
    private static func clock(_ seconds: Double) -> String {
        let value = Int(max(0, seconds)); return String(format: "%d:%02d", value / 60, value % 60)
    }
}
