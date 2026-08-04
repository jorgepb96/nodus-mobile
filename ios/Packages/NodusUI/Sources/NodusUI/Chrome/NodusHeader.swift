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
        // subtitle being cut off by the glass. Nothing here but the padding to the screen edge,
        // which is the accessories' own margin: they are overlaid one level down, on the mark.
        centrepiece
            .padding(.horizontal, 6)
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

    /// The mark on the centre line, and everything else small underneath it.
    ///
    /// Down, not across. Laid out across, the mark sat wherever the vault's name left room for
    /// it: "Franquismo" and "Testimonios orales del exilio" are not the same width, so the one
    /// fixed thing in the chrome moved from screen to screen and from vault to vault. Centring
    /// the *cluster* is not centring the mark. On its own line it is on the centre line of the
    /// screen and stays there, whatever is written under it.
    ///
    /// What is written under it is the vault's name and its record count, in the type the count
    /// was already set in — small, second level, one line. They are data about the space, not a
    /// title, and at that size they cost nothing: the mark and the caption together come to
    /// thirty-five points inside a chrome that is fifty-eight tall, so the header is exactly as
    /// tall as it has always been and the pair sits in the middle of it.
    ///
    /// `ViewThatFits` rather than a layout priority: when a long vault name and its record count
    /// cannot both fit, the count is what goes, and it goes *entirely*. Compressed instead, it
    /// came out as "· 67 re…", which is not a smaller version of the information — it is the
    /// same clutter saying nothing. The name never truncates, because two spaces on one server
    /// can differ only in their last few words.
    private var centrepiece: some View {
        // One block, centred as a block — no hand-set gaps at all.
        //
        // The mark used to be centred in the chrome *on its own*, with the caption dropped into
        // whatever was left underneath. That is not the same thing as a centred header: it put
        // eighteen points of air above the mark and three below the caption, so the mark, the
        // glyphs beside it and the small print all sat low in the glass, hard against its bottom
        // edge. What has to be centred is the pair. Stacking them and letting the fixed frame
        // centre the stack splits the spare height evenly above and below the two together, and
        // keeps doing so when the chrome collapses and when a reader's text size makes the
        // caption taller.
        //
        // The gap between the two is the same size as the space left over above and below them.
        // Butted together, the caption sat under the mark's lower node with nothing between them
        // and read as part of the drawing. Eight points is what makes the three gaps equal at the
        // default text size — mark and caption come to thirty-five points, the chrome is
        // fifty-eight, and what is spare divides into two margins of a little over seven.
        VStack(spacing: 8) {
            markRow
            captionRow
        }
        // Stated, not a floor. The centring above is measured against this number, so it has to
        // be a number: a minimum leaves the frame free to accept whatever height it is offered,
        // and inside a `safeAreaInset` what it is offered is the window.
        .frame(height: contentHeight)
    }

    /// The mark on the centre line of the screen, and the accessories on the centre line of the
    /// mark.
    ///
    /// The two clusters are overlaid on the mark's own row rather than on the header as a whole.
    /// Overlaid on the header they were centred in it, which was the mark's centre line only for
    /// as long as the mark was the thing centred in it — the moment the caption joined the mark
    /// in one centred block, a header-centred glyph sat six points below the mark it is meant to
    /// sit beside. Measured against the row, a glyph and the mark share a line whatever the
    /// caption under them does, and at the accessibility text sizes the caption is nearly twice
    /// its default height.
    ///
    /// An overlay does not enlarge what it is over, so the 44-point accessory box hangs eleven
    /// points past the 22-point row at each end. That is deliberate: the box is a target, the
    /// 17-point glyph inside it is the drawing, and the glass it hangs over runs up behind the
    /// status area anyway.
    private var markRow: some View {
        NodusMark(style: .accent(accent), progress: markProgress, nodeReveal: markProgress)
            .frame(width: Self.markSize, height: Self.markSize)
            .accessibilityHidden(false)
            .accessibilityLabel("Nodus")
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) { accessory(Leading.self) { leading } }
            .overlay(alignment: .trailing) { accessory(Trailing.self) { trailing } }
    }

    /// The line of small print, kept clear of the accessories.
    ///
    /// Room reserved for them, rather than a fixed cap on the title. They are overlaid on the row
    /// above rather than laid out beside this — that is what keeps the mark centred on the screen
    /// and not centred on whatever is left — so nothing stops them meeting the title in the
    /// middle except this. Symmetric, and sized for the widest side (two 44-point controls), so
    /// the header does not shift as you change tab. What is left is width − 184: 256 points on a
    /// 440-point phone, 191 on the narrowest one the app supports, and the count beside the
    /// vault's name appears or does not according to which of those it is.
    ///
    /// One element, not two: the name and the count are one fact about the space you are in, and
    /// VoiceOver reading "nodus-m2-air" and "· 135 533 records" as separate stops is two stops
    /// for one line.
    private var captionRow: some View {
        ViewThatFits(in: .horizontal) {
            caption(withSubtitle: true)
            caption(withSubtitle: false)
        }
        .padding(.horizontal, 92)
        .accessibilityElement(children: .combine)
    }

    /// The mark's own size, named because the header's measurements are taken from it.
    /// Computed rather than stored: `NodusHeader` is generic over its two accessories, and a
    /// generic type may not hold a static stored property.
    private static var markSize: CGFloat { 22 }

    /// What the chrome occupies below the cutout, and the whole of what the layout above is
    /// centred in.
    ///
    /// It was three numbers before — five above the row, forty-four of row, nine below — and the
    /// nine was the gap to the content under the chrome rather than anything about the header,
    /// which is what put a centred block off centre. One number, and the same total as the three
    /// it replaces, so the header is the height it has always been.
    private var contentHeight: CGFloat { collapsed ? 51 : 58 }

    /// The vault's name and its record count, in one voice.
    ///
    /// The count was already `.caption2` in the second level of text, and the name was a
    /// semibold subheadline in the first — two sizes and two weights for two facts of the same
    /// kind. Under the mark they are one line of small print about the space you are in, so
    /// they are set the same way, and the separator between them is the one the app uses
    /// everywhere else it puts two facts on a line.
    private func caption(withSubtitle: Bool) -> some View {
        HStack(spacing: 4) {
            if let title {
                Text(title)
                    .lineLimit(1)
                    // The one piece of the header that grows with the reader's text size, so it
                    // is also the one that has to be allowed to give: at the accessibility sizes
                    // even a caption is far past its default and would push the count off the
                    // line and the line past the chrome that draws it.
                    .minimumScaleFactor(0.75)
                if withSubtitle, let subtitle, !collapsed {
                    Text(verbatim: "· \(subtitle)")
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
        }
        .font(.caption2)
        // Grows with the reader, up to the point where it would stop fitting in the thing that
        // draws it. The glyphs beside it are stated in points for this reason and the chrome is
        // a stated height for the same one; a caption that keeps growing after both have stopped
        // is a line of small print hanging out of the bottom of the glass, which is what the
        // accessibility sizes did to it — at the largest, "Franquismo" was set larger than the
        // vault's own screen titles and its descenders were cut off by the header's own edge.
        // The last non-accessibility size is a little over half as large again as the default,
        // and it is the last one the chrome can hold.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .foregroundStyle(.secondary)
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
