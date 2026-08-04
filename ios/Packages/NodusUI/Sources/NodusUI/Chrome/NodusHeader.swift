import SwiftUI

/// The app's top chrome: the mark, centred, with the cutout absorbed into it.
///
/// The desktop centres its vault badge by measuring rather than by `left-1/2`, because the
/// leading and trailing clusters are never the same width. The same problem exists here and has
/// the same answer — the mark is laid out in its own centred layer, and the two accessory
/// clusters float over it. Nothing on either side can push it off centre.
///
/// The glass extends up behind the notch or the Dynamic Island, and an accent halo rings the
/// cutout, so the hardware reads as the top of the chrome instead of a gap in it.
public struct NodusHeader<Leading: View, Trailing: View>: View {
    public var title: String?
    public var subtitle: String?
    public var accent: Color
    /// Raises the halo while a job is running. 0 leaves the ring at rest.
    public var activity: Double
    /// True once the page under the header has been scrolled at all.
    ///
    /// A header is a title page while you are at the top of a screen and an obstruction three
    /// paragraphs down. Collapsed it keeps the mark and the vault's name — which is the one
    /// thing worth carrying, since a phone can show two vaults that look identical — and drops
    /// the record count and most of its padding.
    public var collapsed: Bool
    private let leading: Leading
    private let trailing: Trailing

    @Environment(\.screenCutout) private var cutout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var markProgress: Double = 0

    public init(
        title: String? = nil,
        subtitle: String? = nil,
        accent: Color,
        activity: Double = 0,
        collapsed: Bool = false,
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accent = accent
        self.activity = activity
        self.collapsed = collapsed
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        // The centrepiece is the content and the accessories float over it, not the other way
        // round. With an HStack of small buttons driving the height, the taller centred cluster
        // overflowed at both ends — the mark disappearing under the Dynamic Island and the
        // subtitle being cut off by the glass.
        centrepiece
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) { accessory(Leading.self) { leading } }
            .overlay(alignment: .trailing) { accessory(Trailing.self) { trailing } }
            .padding(.horizontal, 6)
            // Room to breathe under the cutout, and no more.
            //
            // This used to be a stacked mark, title and subtitle with 10 above and 14 below —
            // some eighty-eight points of chrome before the first thing anybody opened the app
            // for, repeated on all four tabs. Laid out across instead of down, it is a little
            // over half that, and the mark, the name, the count and both controls are all still
            // on it.
            .padding(.top, collapsed ? 2 : 5)
            .padding(.bottom, collapsed ? 5 : 9)
        // The chrome bleeds up behind the cutout; the content does not. Putting the halo and
        // the glass in the *background* rather than beside the content in a ZStack is what
        // keeps them separable — an earlier version had the halo's GeometryReader stretch the
        // stack upward and push the mark under the Dynamic Island.
        .background(alignment: .top) { chrome }
        .animation(reduceMotion ? nil : NodusMotion.standard, value: collapsed)
        .task {
            guard markProgress == 0 else { return }
            if reduceMotion {
                markProgress = 1
            } else {
                withAnimation(.easeOut(duration: 0.9)) { markProgress = 1 }
            }
        }
    }

    /// The tappable box an accessory gets, whatever glyph the caller put in it.
    ///
    /// The two header buttons were a `callout`-sized SF Symbol and nothing else: a target of
    /// roughly 17 × 17 points, sitting 16 points from the edge of the screen, where the palm
    /// already rests and the system's own edge gestures start. Both of them read as broken —
    /// most taps landed beside the glyph and did nothing at all.
    ///
    /// 44 × 44 is Apple's minimum, and it is also all a one-row header has room for. It is not
    /// less target than the 52 it replaced in any direction a thumb cares about, and it stops
    /// the two glyphs crowding the vault's name. `contentShape` is what makes the whole box
    /// tappable rather than the glyph's own outline.
    ///
    /// A header with no accessory on a side gets nothing there — a 44-point `contentShape` over
    /// an `EmptyView` is an invisible button that eats every tap in that corner.
    ///
    /// `minWidth`, not `width`: a side can hold more than one control. Home puts its board/list
    /// switch beside the settings gear, because a control that changes the shape of one screen
    /// belongs in that screen's chrome and not in a row of its own above the content.
    @ViewBuilder
    private func accessory<V: View>(_ type: V.Type, @ViewBuilder _ content: () -> V) -> some View {
        if type != EmptyView.self {
            content()
                // Stated in points, not as a text style. `.title3` is 20 points at the default
                // Dynamic Type size and 26 at the largest, and a header glyph that grows with
                // the body text pushes the vault's name off its own row — while `.caption`
                // glyphs elsewhere in the app stayed put. One size and one weight for every
                // glyph at this level of the app is what item 21 is asking for.
                .font(.system(size: 17, weight: .medium))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
    }

    /// The mark, the vault's name and its count — across, not down.
    ///
    /// `ViewThatFits` rather than a layout priority: when a long vault name and its record count
    /// cannot both fit, the count is what goes, and it goes *entirely*. Compressed instead, it
    /// came out as "· 67 re…", which is not a smaller version of the information — it is the
    /// same clutter saying nothing. The name never truncates, because two spaces on one server
    /// can differ only in their last few words.
    private var centrepiece: some View {
        ViewThatFits(in: .horizontal) {
            cluster(withSubtitle: true)
            cluster(withSubtitle: false)
        }
        // Room reserved for the accessories, rather than a fixed cap on the title.
        //
        // They are overlaid on this view rather than laid out beside it — that is what keeps
        // the mark centred on the screen and not centred on whatever is left — so nothing
        // stops them meeting the title in the middle except this. Symmetric, and sized for the
        // widest side (two 44-point controls), so the mark stays on the centre line and the
        // header does not shift as you change tab. What is left is width − 184: 256 points on
        // a 440-point phone, 191 on the narrowest one the app supports, and the count beside
        // the vault's name appears or does not according to which of those it is.
        .padding(.horizontal, 92)
        // `minHeight`, not `height`: the accessories set the floor at 44 and the title is
        // allowed to make it taller rather than be clipped by it.
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private func cluster(withSubtitle: Bool) -> some View {
        HStack(spacing: 7) {
            NodusMark(style: .accent(accent), progress: markProgress, nodeReveal: markProgress)
                .frame(width: 22, height: 22)
                .accessibilityHidden(false)
                .accessibilityLabel("Nodus")
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    // The one piece of the header that grows with the reader's text size, so it
                    // is also the one that has to be allowed to give: at the accessibility sizes
                    // a subheadline is nearly twice its default and would push the count off the
                    // row and the row past the chrome that draws it.
                    .minimumScaleFactor(0.75)
                if withSubtitle, let subtitle, !collapsed {
                    Text(verbatim: "· \(subtitle)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
        }
    }

    /// The bar itself, extended up under the status area so the cutout sits *on* the chrome.
    private var chrome: some View {
        Color.clear
            .nodusGlass(
                NodusGlass(.thin, tint: accent),
                in: UnevenRoundedRectangle(
                    bottomLeadingRadius: NodusRadius.screenEdge,
                    bottomTrailingRadius: NodusRadius.screenEdge,
                    style: .continuous
                )
            )
            .overlay(alignment: .top) {
                CutoutHalo(cutout: cutout, accent: accent, intensity: 0.35 + activity * 0.65)
            }
            .ignoresSafeArea(edges: .top)
    }
}

public extension NodusHeader where Leading == EmptyView, Trailing == EmptyView {
    init(title: String? = nil, subtitle: String? = nil, accent: Color, activity: Double = 0) {
        self.init(title: title, subtitle: subtitle, accent: accent, activity: activity, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

#if DEBUG
#Preview("Header") {
    ZStack(alignment: .top) {
        LinearGradient(colors: [Color(hex: "#0b0a12"), Color(hex: "#241a44")], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        NodusHeader(title: "Franquismo", subtitle: "1 284 obras", accent: Color(hex: "#6366f1"), activity: 0.6) {
            Image(systemName: "line.3.horizontal")
        } trailing: {
            Image(systemName: "magnifyingglass")
        }
        .environment(\.screenCutout, .dynamicIsland)
    }
}
#endif
