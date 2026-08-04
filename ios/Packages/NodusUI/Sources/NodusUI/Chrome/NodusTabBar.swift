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
    @Namespace private var indicator

    public init(selection: Binding<Tab>, accent: Color, items: [Item]) {
        _selection = selection
        self.accent = accent
        self.items = items
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                Button {
                    guard selection != item.tab else { return }
                    if reduceMotion {
                        selection = item.tab
                    } else {
                        withAnimation(NodusMotion.standard) { selection = item.tab }
                    }
                } label: {
                    cell(item)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == item.tab ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, NodusTabBarMetrics.topPadding)
        .padding(.bottom, NodusTabBarMetrics.bottomPadding)
        .background(alignment: .top) { surface }
    }

    private func cell(_ item: Item) -> some View {
        let selected = selection == item.tab
        return VStack(spacing: 2) {
            Image(systemName: item.systemImage)
                // One size, one weight, stated in points. Left to a text style the four glyphs
                // were four different optical weights — `bubble.left.and.text.bubble.right` is a
                // far heavier drawing than `house` at the same nominal size — and every one of
                // them grew with Dynamic Type until the labels underneath had nowhere to go.
                .font(.system(size: 17, weight: selected ? .semibold : .regular))
                .frame(height: 20)
                .padding(.horizontal, 14)
                .padding(.vertical, 3)
                .background {
                    if selected {
                        Capsule().fill(accent.opacity(0.18))
                            .matchedGeometryEffect(id: "selection", in: indicator)
                    }
                }
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
