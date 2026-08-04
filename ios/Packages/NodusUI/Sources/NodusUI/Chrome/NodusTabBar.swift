import SwiftUI

/// The app's bottom bar, drawn rather than asked for.
///
/// `TabView`'s own bar could not be made to do three things this app needs. It is tall — on iOS
/// 26 the floating glass bar is some ninety points once the home indicator is under it, which on
/// a 6.1-inch phone is more chrome than most of the cards it sits over. Its selected tab wears a
/// large translucent capsule that is the brightest object on the screen, so the eye lands on
/// *where you already are* rather than on what you came to read. And it cannot be sent away for
/// one screen: a report or an argument map is a document, and a bar offering to leave it is not
/// what a reader wants forty points of.
///
/// So: forty-six points of content, a selected state that is a small pill and a colour rather
/// than a slab, and a caller that can simply not show it.
/// What the bar takes, stated once so the pages under it can clear it.
///
/// The bar floats: it is added with `safeAreaInset` outside the four `NavigationStack`s, and a
/// `NavigationStack` does not pass an outer inset on to what it is showing. Measured on an
/// iPhone, a page inside a tab reports a bottom safe area of 34 points — the home indicator, and
/// nothing for the bar — so the last fifty points of every one of those pages was drawn behind
/// it. That is the chat's composer, which was simply not on screen, and the last card of Home,
/// which you could scroll to and not see.
///
/// The pages therefore have to reserve this themselves, and this is the number to reserve. It is
/// a constant rather than a measurement because the bar is one: a 44-point cell, whose glyph and
/// label are stated in points and do not grow with Dynamic Type, and the padding around it.
public enum NodusTabBarMetrics {
    /// The tappable cell. Apple's minimum, and what the bar is built from.
    public static let cell: CGFloat = 44
    static let topPadding: CGFloat = 5
    static let bottomPadding: CGFloat = 3
    /// What the bar occupies above the home indicator.
    public static let height: CGFloat = cell + topPadding + bottomPadding

    /// What the selection lozenge leaves clear inside the cell it is on.
    ///
    /// The lozenge takes the whole cell — the glyph and the label under it — rather than a
    /// capsule around the glyph alone. A section is its name as much as its symbol, and a
    /// highlight that stops above the word leaves the word looking like a caption on the
    /// highlight rather than part of what is selected.
    ///
    /// Its width is therefore the cell's, less this, and not a constant: every cell is the same
    /// width, so the lozenge is still one size for a given screen — which is what matters for
    /// something that has to read as a single object travelling rather than as one being redrawn
    /// at each stop.
    static let lozengeInset: CGFloat = 5
    static let labelSpacing: CGFloat = 2
}

private struct HasTabBarKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// True while the app's bar is floating over the bottom of this view.
    ///
    /// The shell states it once, over the whole stack of tabs, and everything inside them
    /// inherits it — a screen pushed six deep as much as the root. That is the point: the inset
    /// itself does not travel that far, so the *fact* has to, and each screen reserves its own
    /// room from it.
    ///
    /// Two things read it. `nodusPageBackdrop` reserves the bar's height. And "back to top" sits
    /// above the bar rather than on it: on iOS 26 the bar floats over the content, so a button in
    /// the bottom-right corner of a tab lands on the bar and the bar takes the touch — which on
    /// the tab you are already looking at does nothing at all, and reads exactly like a dead
    /// button. A pushed screen with the bar sent away wants the button low, where a thumb is.
    ///
    /// A sheet is the one place it has to be said again, and `nodusSheet` is where: a sheet is
    /// presented *over* the bar and inherits the environment of whatever presented it, so without
    /// that every sheet in the app would open with fifty points of nothing at the bottom.
    var nodusHasTabBar: Bool {
        get { self[HasTabBarKey.self] }
        set { self[HasTabBarKey.self] = newValue }
    }
}

public extension View {
    /// A sheet, presented knowing that it covers the bar.
    ///
    /// The house `.sheet`. Everything else about it is the system's; the one thing it adds is
    /// that nothing inside reserves room for a bar it is drawn on top of.
    func nodusSheet<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented) {
            content().environment(\.nodusHasTabBar, false)
        }
    }

    /// The same, for a sheet that is presented by having something to show.
    func nodusSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(item: item) { value in
            content(value).environment(\.nodusHasTabBar, false)
        }
    }
}

/// Room for the bar at the bottom of one screen, and nothing drawn in it.
///
/// Clear rather than the bar itself: the bar is drawn once, over all four tabs, so that content
/// scrolls *under* its glass — which is what the material is for. This only stops the page from
/// coming to rest there.
///
/// It is a `safeAreaInset` on the screen rather than on the shell because the shell's inset does
/// not reach here. The bar is added outside the four `NavigationStack`s, and a `NavigationStack`
/// does not pass an outer inset on to what it is showing: measured, a page inside a tab reports a
/// bottom safe area of 34 points, which is the home indicator and nothing else. The root of each
/// tab used to be given this by the shell directly, which left every *pushed* screen — a
/// collection, a dossier — still drawing its last row behind the bar.
struct NodusBottomBarClearance: ViewModifier {
    /// False for the one backdrop that is behind a screen the shell has already given room to.
    let enabled: Bool

    @Environment(\.nodusHasTabBar) private var hasTabBar

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                // Always applied, at zero when there is nothing to clear: an inset that comes and
                // goes with an `if` is a different view each time, and the screen inside it would
                // lose its scroll position every time a document sent the bar away.
                .frame(height: enabled && hasTabBar ? NodusTabBarMetrics.height : 0)
                .allowsHitTesting(false)
        }
    }
}

public struct NodusTabBar<Tab: Hashable>: View {
    public struct Item: Identifiable {
        public let tab: Tab
        public let title: LocalizedStringKey
        public let systemImage: String

        public init(tab: Tab, title: LocalizedStringKey, systemImage: String) {
            self.tab = tab
            self.title = title
            self.systemImage = systemImage
        }

        public var id: Tab { tab }
    }

    @Binding private var selection: Tab
    private let items: [Item]
    private let accent: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How wide the row of cells came out. Needed because the whole of the sliding behaviour is
    /// arithmetic on a horizontal position, and there is no fixed number to do it with: the bar
    /// is as wide as the phone, minus its margins.
    @State private var rowWidth: CGFloat = 0

    /// Where the finger is, while there is one. `@GestureState` rather than `@State` so it
    /// cannot survive the gesture that set it — a lozenge stranded under a finger that has been
    /// lifted is the one failure this control cannot recover from on its own.
    @GestureState private var touchX: CGFloat?

    /// The coordinate space the drag is measured in. Named, because the gesture has to report
    /// positions in the row's own space and not in the window's — the bar is inset from both
    /// edges and sits above the home indicator.
    private static var space: String { "nodus.tabbar.row" }

    public init(selection: Binding<Tab>, accent: Color, items: [Item]) {
        _selection = selection
        self.accent = accent
        self.items = items
    }

    public var body: some View {
        // No `GlassEffectContainer` around these two, and that is a finding rather than an
        // omission. A container merges the glass inside it into one body — which is what it is
        // for, and exactly wrong here: the lozenge sits *on* the bar's own surface, zero points
        // away, so any spacing at all merges the two into a single shape that is then composited
        // over the row. The glyphs and the labels came out refracted through the bar they belong
        // to, blurred into a smear. Stacked glass is arranged by layering it, not by grouping it.
        row
            .background(alignment: .topLeading) { lozenge }
            .padding(.horizontal, 8)
            .padding(.top, NodusTabBarMetrics.topPadding)
            .padding(.bottom, NodusTabBarMetrics.bottomPadding)
            .background(alignment: .top) { surface }
    }

    private var row: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                cell(item)
                    .accessibilityAddTraits(selection == item.tab ? [.isSelected, .isButton] : .isButton)
                    .accessibilityAction { select(item.tab) }
            }
        }
        .coordinateSpace(.named(Self.space))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        .contentShape(Rectangle())
        .gesture(slide)
        // The small knock as the lozenge passes from one section to the next. Without it the
        // slide is silent to the hand, and a control you can drag with no feedback reads as one
        // you are dragging *at* rather than *with*.
        .sensoryFeedback(.selection, trigger: selection)
    }

    /// Press and slide, and the sections change under your finger.
    ///
    /// `minimumDistance: 0`, which makes this the bar's tap handler as well: a tap is a slide
    /// that went nowhere, and writing it as one gesture is what stops a `Button` and a drag
    /// arguing over the same touch. The lozenge follows the finger continuously rather than
    /// jumping cell to cell, because the position it is drawn at is the finger's, not the
    /// selection's — the selection only decides where it comes to rest.
    private var slide: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .updating($touchX) { value, state, _ in state = value.location.x }
            .onChanged { value in select(tab(at: value.location.x)) }
            .onEnded { value in select(tab(at: value.location.x)) }
    }

    private func select(_ tab: Tab?) {
        guard let tab, tab != selection else { return }
        if reduceMotion {
            selection = tab
        } else {
            withAnimation(NodusMotion.morph) { selection = tab }
        }
    }

    /// Which section a point along the bar belongs to. Clamped at both ends, so a finger that
    /// runs off the side keeps the section it last passed over rather than losing it.
    private func tab(at x: CGFloat) -> Tab? {
        guard rowWidth > 0, !items.isEmpty else { return nil }
        let width = rowWidth / CGFloat(items.count)
        let index = min(items.count - 1, max(0, Int(x / width)))
        return items[index].tab
    }

    /// The one piece of glass in the bar, and where it currently is.
    ///
    /// Under the finger while there is one, on the selected cell otherwise — and the spring
    /// between the two is what makes it read as liquid: it trails a little behind the finger on
    /// the way across and settles onto the cell when the finger lifts, rather than being
    /// wherever the touch is at each frame.
    private var lozenge: some View {
        let width = max(cellWidth - NodusTabBarMetrics.lozengeInset * 2, 0)
        return Capsule()
            .fill(.clear)
            .frame(width: width, height: NodusTabBarMetrics.cell)
            .nodusGlassLozenge(tint: accent)
            .offset(x: centre - width / 2)
            .animation(reduceMotion ? nil : NodusMotion.morph, value: centre)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var cellWidth: CGFloat {
        guard rowWidth > 0, !items.isEmpty else { return 0 }
        return rowWidth / CGFloat(items.count)
    }

    private var centre: CGFloat {
        guard cellWidth > 0 else { return 0 }
        if let touchX {
            // Never past the first or last cell's own centre: the lozenge may be dragged, not
            // taken off the end of the bar.
            return min(max(touchX, cellWidth / 2), rowWidth - cellWidth / 2)
        }
        let index = items.firstIndex { $0.tab == selection } ?? 0
        return (CGFloat(index) + 0.5) * cellWidth
    }

    private func cell(_ item: Item) -> some View {
        let selected = selection == item.tab
        return VStack(spacing: NodusTabBarMetrics.labelSpacing) {
            Image(systemName: item.systemImage)
                // One size, one weight, stated in points. Left to a text style the four glyphs
                // were four different optical weights — `bubble.left.and.text.bubble.right` is a
                // far heavier drawing than `house` at the same nominal size — and every one of
                // them grew with Dynamic Type until the labels underneath had nowhere to go.
                .font(.system(size: 17, weight: selected ? .semibold : .regular))
                .frame(height: 21)
            Text(item.title)
                .font(.system(size: 10, weight: selected ? .semibold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(selected ? accent.nodusReadable : Color.nodusSecondaryText)
        .frame(maxWidth: .infinity)
        .frame(height: NodusTabBarMetrics.cell)
        .contentShape(Rectangle())
    }

    /// The bar's own surface, extended down under the home indicator.
    ///
    /// One material in both states — the same decision the old `toolbarBackground` call was
    /// making — and the top corners rounded to the screen's radius, which is the header's bottom
    /// edge turned upside down. The hairline along the top is what separates the bar from the
    /// content instead of a shadow, because a shadow under a bar that content scrolls beneath is
    /// a grey band that moves.
    private var surface: some View {
        Color.clear
            .nodusGlass(
                NodusGlass(.thin, tint: accent),
                in: UnevenRoundedRectangle(
                    topLeadingRadius: NodusRadius.screenEdge,
                    topTrailingRadius: NodusRadius.screenEdge,
                    style: .continuous
                )
            )
            .ignoresSafeArea(edges: .bottom)
    }
}
