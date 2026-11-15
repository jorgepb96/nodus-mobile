import NodusUI
import SwiftUI
import WebKit

struct LinkPodcastPlayer: View {
    let playback: LinkPodcastPlayback
    let accent: Color
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let compact = geometry.size.height < 420
                let horizontal = geometry.size.width >= 600 && geometry.size.width > geometry.size.height && !textSize.isAccessibilitySize
                // Artwork and transport share one measured flow. A flexible artwork scroll
                // used to take all spare height and leave a large gap before the controls.
                // Scrolling the complete layout also keeps the last button reachable in a
                // short sheet or at accessibility text sizes, rather than clipping it.
                ScrollView {
                    Group {
                        if horizontal {
                            HStack(alignment: .center, spacing: 24) {
                                artwork(side: max(80, min(280, min(geometry.size.height - 32, geometry.size.width * 0.35))))
                                VStack(spacing: 16) {
                                    playbackIssue
                                    if let target = playback.target { playbackControls(target, compact: true) }
                                }
                            }
                        } else {
                            VStack(spacing: compact ? 16 : 24) {
                                if !compact {
                                    artwork(side: max(80, min(360, min(geometry.size.width - 48, geometry.size.height * 0.46))))
                                }
                                playbackIssue
                                if let target = playback.target { playbackControls(target, compact: compact) }
                            }
                        }
                    }
                    .frame(maxWidth: horizontal ? 960 : 600)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, compact ? 16 : 24)
                    .padding(.vertical, compact ? 16 : 24)
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("saved-audio-player-scroll")
            }
            .navigationTitle("Podcasts").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Close") { playback.showingPlayer = false } }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Section("Playback speed") {
                            ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { rate in
                                Button("\(rate.formatted())×") { Task { await playback.changeRate(rate) } }
                            }
                        }
                        if let target = playback.target {
                            ShareLink(item: target.copy.url) { NodusMenuLabel(title: "Export audio", image: "square.and.arrow.up") }
                                .accessibilityIdentifier("saved-audio-export")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                        .tint(.primary)
                        .accessibilityLabel("Playback options")
                        .accessibilityIdentifier("saved-audio-speed")
                }
            }
        }.tint(accent.nodusReadable)
            .accessibilityElement(children: .contain).accessibilityIdentifier("podcast-player-sheet")
    }

    private func artwork(side: CGFloat) -> some View {
        Group {
            if let image = SavedAudioNowPlayingInfo.image(playback.target?.artworkData) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                NodusMark(style: .accent(accent)).padding(side * 0.2)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityHidden(true)
    }

    @ViewBuilder private var playbackIssue: some View {
        if let issue = playback.issue {
            Text(issue).font(.callout).foregroundStyle(Color.nodusDanger)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Transport stays adjacent to the artwork and can always be scrolled into view.
    private func playbackControls(_ target: SavedAudioTarget, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 12) {
            Text(target.label).font(compact ? .callout.weight(.semibold) : .title3.weight(.semibold))
                .lineLimit(textSize.isAccessibilitySize ? nil : compact ? 2 : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Slider(value: Binding(get: { playback.position }, set: { value in Task { await playback.seek(value) } }), in: 0...max(playback.duration, 0.001))
                .accessibilityIdentifier("saved-audio-seek").accessibilityLabel("Playback position")
            HStack {
                Text(clock(playback.position)).accessibilityIdentifier("saved-audio-elapsed")
                Spacer(); Text(clock(playback.duration))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack {
                Button { Task { await playback.seek(playback.position - 15) } } label: {
                    Image(systemName: "gobackward.15").font(.system(size: 23)).frame(width: 56, height: 56).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Back 15 seconds").accessibilityIdentifier("saved-audio-back")
                Spacer()
                Button { Task { await playback.toggle() } } label: {
                    Image(systemName: playback.playing ? "pause.fill" : "play.fill").font(.system(size: 26, weight: .semibold))
                        .frame(width: compact ? 56 : 72, height: compact ? 56 : 72)
                        .foregroundStyle(accent.relativeLuminance > 0.179 ? Color.black : Color.white)
                        .background(accent, in: Circle()).contentShape(Circle())
                }.buttonStyle(.plain).accessibilityLabel(playback.playing ? "Pause" : "Play")
                    .accessibilityValue(Text(LocalizedStringKey(playback.playing ? "Playing" : "Paused")))
                    .accessibilityAddTraits(playback.playing ? .isSelected : []).accessibilityIdentifier("saved-audio-play")
                Spacer()
                Button { Task { await playback.seek(playback.position + 15) } } label: {
                    Image(systemName: "goforward.15").font(.system(size: 23)).frame(width: 56, height: 56).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Forward 15 seconds").accessibilityIdentifier("saved-audio-forward")
            }
        }.frame(maxWidth: 600).frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain).accessibilityIdentifier("saved-audio-player-controls")
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
                    .accessibilityValue(Text(LocalizedStringKey(playback.playing ? "Playing" : "Paused")))
                    .accessibilityAddTraits(playback.playing ? .isSelected : []).accessibilityIdentifier("podcast-mini-play")
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
