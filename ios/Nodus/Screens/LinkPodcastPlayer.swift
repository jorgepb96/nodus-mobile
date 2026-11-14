import NodusUI
import SwiftUI
import WebKit

struct LinkPodcastPlayer: View {
    let playback: LinkPodcastPlayback
    let accent: Color
    @State private var availableHeight: CGFloat = 700
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: availableHeight < 420 ? 10 : 20) {
                    if let target = playback.target {
                        if availableHeight >= 420, let image = SavedAudioNowPlayingInfo.image(target.artworkData) {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: min(260, availableHeight * 0.3))
                                .clipShape(RoundedRectangle(cornerRadius: 20)).frame(maxWidth: .infinity)
                        }
                        Text(target.label).font(availableHeight < 420 ? .headline : .title2.bold()).fixedSize(horizontal: false, vertical: true)
                        if let issue = playback.issue { Text(issue).foregroundStyle(Color.nodusDanger) }
                        Slider(value: Binding(get: { playback.position }, set: { value in Task { await playback.seek(value) } }), in: 0...max(playback.duration, 0.001))
                            .accessibilityIdentifier("saved-audio-seek").accessibilityLabel("Playback position")
                        HStack {
                            Text(clock(playback.position)).accessibilityIdentifier("saved-audio-elapsed")
                            Spacer(); Text(clock(playback.duration))
                        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        HStack {
                            Button { Task { await playback.seek(playback.position - 15) } } label: { Image(systemName: "gobackward.15").frame(width: 56, height: 56) }
                                .accessibilityLabel("Back 15 seconds").accessibilityIdentifier("saved-audio-back")
                            Spacer()
                            Button { Task { await playback.toggle() } } label: {
                                Image(systemName: playback.playing ? "pause.fill" : "play.fill").font(.title).frame(width: 72, height: 72)
                            }.buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                                .foregroundStyle(accent.relativeLuminance > 0.179 ? Color.black : Color.white)
                                .accessibilityLabel(playback.playing ? "Pause" : "Play")
                                .accessibilityValue(Text(verbatim: playback.playing ? "playing" : "paused")).accessibilityIdentifier("saved-audio-play")
                            Spacer()
                            Button { Task { await playback.seek(playback.position + 15) } } label: { Image(systemName: "goforward.15").frame(width: 56, height: 56) }
                                .accessibilityLabel("Forward 15 seconds").accessibilityIdentifier("saved-audio-forward")
                        }
                        Menu {
                            ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { rate in
                                Button("\(rate.formatted())×") { Task { await playback.changeRate(rate) } }
                            }
                        } label: { Label("\(String(localized: "Playback speed")) · \(playback.rate.formatted())×", systemImage: "speedometer").frame(minHeight: 44) }
                            .accessibilityIdentifier("saved-audio-speed")
                        ShareLink(item: target.copy.url) { Label("Export audio", systemImage: "square.and.arrow.up").frame(minHeight: 44) }
                            .accessibilityIdentifier("saved-audio-export")
                    }
                }.padding(availableHeight < 420 ? 16 : 24).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
                .accessibilityIdentifier("saved-audio-player-scroll")
                .navigationTitle("Podcasts").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Cerrar") { playback.showingPlayer = false } } }
        }.tint(accent.nodusReadable)
    }
    private func clock(_ seconds: Double) -> String {
        let value = Int(max(0, seconds)); return String(format: "%d:%02d", value / 60, value % 60)
    }
}

struct LinkMiniPlayer: View {
    let playback: LinkPodcastPlayback
    let accent: Color
    var body: some View {
        if let target = playback.target {
            HStack(spacing: 12) {
                Button { playback.showingPlayer = true } label: {
                    HStack(spacing: 12) {
                        Group {
                            if let image = SavedAudioNowPlayingInfo.image(target.artworkData) { Image(uiImage: image).resizable().scaledToFill() }
                            else { Image(systemName: "headphones").foregroundStyle(accent.nodusReadable) }
                        }.frame(width: 42, height: 42).clipped().background(accent.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(target.label).font(.subheadline.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
                    }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("podcast-mini-open")
                Button { Task { await playback.toggle() } } label: { Image(systemName: playback.playing ? "pause.fill" : "play.fill").frame(width: 44, height: 52) }
                    .accessibilityLabel(playback.playing ? "Pause" : "Play")
                    .accessibilityValue(Text(verbatim: playback.playing ? "playing" : "paused")).accessibilityIdentifier("podcast-mini-play")
                Button { playback.stop() } label: { Image(systemName: "xmark").font(.caption).frame(width: 44, height: 52) }
                    .accessibilityLabel("Detener podcast").accessibilityIdentifier("podcast-mini-stop")
            }.padding(.leading, 16).padding(.trailing, 4).background(.regularMaterial)
                .overlay(alignment: .top) { Divider() }.accessibilityElement(children: .contain).accessibilityIdentifier("podcast-mini-player")
        }
    }
}

/// WebKit's audio decoder remains mounted when the visible catalogue or player is dismissed.
struct LinkPodcastAudioHost: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ view: WKWebView, context: Context) { }
}
