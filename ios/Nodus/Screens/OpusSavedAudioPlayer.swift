import NodusUI
import SwiftUI
import WebKit

/// Native controls remain the same for Linux's Opus episodes; only decoding uses WebKit.
struct OpusSavedAudioPlayer: View {
    let target: SavedAudioTarget
    let accent: Color
    @Environment(\.scenePhase) private var phase
    @State private var playback = OpusPlayback()
    @State private var issue: String?
    @State private var position = 0.0
    @State private var seeking = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label(target.label, systemImage: "waveform").font(.title2.bold())
                if target.copy.offline { Label("Downloaded copy", systemImage: "wifi.slash") }
                if let issue { Text(issue).foregroundStyle(Color.nodusDanger).accessibilityIdentifier("saved-audio-error") }
                if !playback.prepared && issue == nil { ProgressView("Preparando audio…") }
                Slider(value: $position, in: 0...max(playback.duration, 0.001)) { editing in
                    seeking = editing
                    if !editing { Task { await playback.seek(position) } }
                }.disabled(!playback.prepared).accessibilityIdentifier("saved-audio-seek").accessibilityLabel("Playback position")
                HStack {
                    Text(clock(position)).accessibilityIdentifier("saved-audio-elapsed")
                    Spacer(); Text(clock(playback.duration))
                }.monospacedDigit()
                HStack {
                    Button { Task { await playback.seek(playback.position - 15) } } label: { Image(systemName: "gobackward.15").frame(width: 44, height: 44) }
                        .accessibilityLabel("Back 15 seconds").accessibilityIdentifier("saved-audio-back")
                    Spacer()
                    Button { Task { await toggle() } } label: {
                        Label(playback.playing ? String(localized: "Pause") : String(localized: "Play"), systemImage: playback.playing ? "pause.fill" : "play.fill").frame(minWidth: 80, minHeight: 44)
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("saved-audio-play")
                    Spacer()
                    Button { Task { await playback.seek(playback.position + 15) } } label: { Image(systemName: "goforward.15").frame(width: 44, height: 44) }
                        .accessibilityLabel("Forward 15 seconds").accessibilityIdentifier("saved-audio-forward")
                }.disabled(!playback.prepared)
                Menu {
                    ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { rate in
                        Button("\(rate.formatted())×") { Task { await playback.changeRate(rate) } }
                    }
                } label: { Label("\(String(localized: "Playback speed")) · \(playback.rate.formatted())×", systemImage: "speedometer").frame(minHeight: 44) }
                    .accessibilityIdentifier("saved-audio-speed")
                ShareLink(item: target.copy.url) { Label("Export audio", systemImage: "square.and.arrow.up").frame(minHeight: 44) }.accessibilityIdentifier("saved-audio-export")
            }.padding(24).frame(maxWidth: 650)
        }.safeAreaPadding(.bottom, 76).tint(accent.nodusReadable)
            .background { OpusAudioHost(view: playback.webView).frame(width: 1, height: 1).accessibilityHidden(true).allowsHitTesting(false) }
            .task {
                do {
                    let start = target.initialTimestamp ?? target.resumeKey.map { UserDefaults.standard.double(forKey: $0) } ?? 0
                    try await playback.prepare(Data(contentsOf: target.copy.url), title: target.label, position: start)
                    while !Task.isCancelled {
                        await playback.poll(); if !seeking { position = playback.position }; savePosition()
                        try await Task.sleep(for: .milliseconds(500))
                    }
                } catch is CancellationError { }
                catch { issue = error.localizedDescription }
            }
            .onChange(of: phase) { _, value in if value != .active { savePosition() } }
            .onDisappear { savePosition(); Task { await playback.stop() } }
    }
    private func toggle() async {
        do { if playback.playing { await playback.pause() } else { try await playback.play() }; issue = nil }
        catch { issue = error.localizedDescription }
    }
    private func savePosition() {
        guard playback.prepared, let key = target.resumeKey else { return }
        UserDefaults.standard.set(playback.position >= playback.duration - 1 ? 0 : playback.position, forKey: key)
    }
    private func clock(_ seconds: Double) -> String {
        let value = Int(max(0, seconds)); return String(format: "%d:%02d", value / 60, value % 60)
    }
}
private struct OpusAudioHost: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ view: WKWebView, context: Context) { }
}
