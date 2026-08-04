import NodusUI
import SwiftUI

/// "Back to top", for screens that are long enough to need it.
///
/// Two pieces, because `ScrollViewProxy` can only reach a view that is inside the scroll view:
/// the screen marks its first element with `nodusTopAnchor()`, and the scrollable itself takes
/// `nodusScrollToTop(accent:)`, which wraps it in a reader and floats the button over it.
///
/// The button appears only once the screen has actually been scrolled — a corpus of nine
/// thousand ideas needs it, an empty state does not. That measurement is iOS 18's
/// `onScrollGeometryChange`; before 18 the button is simply always there, which is the honest
/// degradation: still useful, just not as quiet.
enum NodusScrollAnchor: Hashable {
    case top
}

private struct TabBarClearanceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True for the four screens that are the root of a tab.
    ///
    /// On iOS 26 the tab bar floats *over* the content, so anything an overlay puts in the
    /// bottom-right corner of a tab root lands on the bar and the bar takes the touch — which
    /// on the tab you are already looking at does nothing at all, and reads exactly like a
    /// dead button. A pushed screen has no bar there and wants the button low, where a thumb
    /// is. The two cases need different numbers, so the shell says which one this is.
    var nodusHasTabBar: Bool {
        get { self[TabBarClearanceKey.self] }
        set { self[TabBarClearanceKey.self] = newValue }
    }
}

extension View {
    /// Marks the first element of a scrollable as the place "back to top" goes.
    func nodusTopAnchor() -> some View {
        id(NodusScrollAnchor.top)
    }

    /// Floats a "back to top" button over a scrollable that carries a `nodusTopAnchor()`.
    func nodusScrollToTop(accent: Color) -> some View {
        modifier(ScrollToTopModifier(accent: accent))
    }
}

/// The same anchor, shaped as a list row.
///
/// A `List` gives every row a minimum height and its own insets, so the plain modifier would
/// leave a visible gap above the first entry. This one takes no space at all.
struct NodusTopAnchorRow: View {
    var body: some View {
        Color.clear
            .frame(height: 0)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .nodusTopAnchor()
    }
}

private struct ScrollToTopModifier: ViewModifier {
    let accent: Color

    @Environment(AppPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nodusHasTabBar) private var hasTabBar
    /// Optional on purpose. Every long scrollable in the app is inside a `SpaceShell`, which
    /// provides one — but a non-optional `@Environment` for an `@Observable` is a crash when it
    /// is missing, and a "back to top" button is not worth taking a screen down for.
    @Environment(NodusChrome.self) private var chrome: NodusChrome?
    @State private var isScrolled = false

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            measured(content)
                .overlay(alignment: .bottomTrailing) {
                    if preferences.showsScrollToTop, isScrolled {
                        Button {
                            goToTop(proxy)
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 13, weight: .semibold))
                                // A 36-point circle inside a 44-point target. The circle used
                                // to *be* 44 and drawn in the prominent material with a glow
                                // under it, which on a page of quiet cards made the one thing
                                // that only scrolls the loudest object on the screen. The thumb
                                // still gets its 44; the eye gets a good deal less.
                                .frame(width: 36, height: 36)
                                .nodusGlass(NodusGlass(.regular, tint: accent, interactive: true), in: Circle())
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .tint(accent)
                        .padding(.trailing, NodusSpace.page)
                        // Clear of the bottom bar where there is one, and low where there is
                        // not. It used to need 76 to clear the system's floating tab bar, which
                        // overlaps content and takes the touches landing on it. The bar the app
                        // draws now goes in a `safeAreaInset`, so it is not floating over
                        // anything and the button only has to sit above the bar's own height.
                        .padding(.bottom, hasTabBar ? 62 : 22)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        .accessibilityLabel("Back to top")
                    }
                }
                .animation(NodusMotion.quick, value: isScrolled)
                // Every scrollable in the shell reports its position, including the ones on
                // pushed screens — where the header is not even on screen. Scrolling a dossier
                // therefore collapsed the header of the tab root behind it, and popping back
                // landed on a page at the top wearing a collapsed header, which reads as a bug
                // because it is one. A screen that goes away stops speaking for the chrome.
                .onDisappear { chrome?.setScrolled(false) }
        }
    }

    /// Back to the top, and a second attempt a beat later.
    ///
    /// A scroll view that is still decelerating overrides a programmatic scroll with its own
    /// momentum: the tap registers, the animation starts, the flick wins, and the button looks
    /// broken precisely when it is most wanted — while the list is still moving. The touch
    /// never reaches the scroll view to stop it, because the button is an overlay *beside* the
    /// scroll view rather than inside it. So the request is made again once the momentum has
    /// had time to be overridden; if the first one landed, the second is a no-op.
    private func goToTop(_ proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo(NodusScrollAnchor.top, anchor: .top)
        } else {
            withAnimation(NodusMotion.deliberate) {
                proxy.scrollTo(NodusScrollAnchor.top, anchor: .top)
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            proxy.scrollTo(NodusScrollAnchor.top, anchor: .top)
        }
    }

    /// One measurement, two answers.
    ///
    /// The header wants to know whether the page has moved at all — that is a line or two, and
    /// it wants to know immediately. The button wants to know whether scrolling back would be a
    /// chore, which is about a screen's worth. Both come out of the same geometry callback,
    /// because adding a second one to every scroll view in the app would be paying twice for a
    /// number the system already handed over.
    ///
    /// The header's answer is given as *two* thresholds rather than one, and that is the whole
    /// of why the page no longer shakes. Collapsing the header takes seven points off the top
    /// inset, and a scroll view keeps its offset when its inset changes — so the same gesture
    /// that crossed a single threshold going down immediately crossed it again coming back:
    /// collapse, seven points of slack, expand, seven points back, collapse. At rest that is a
    /// flicker; at the bottom of a page, where the rubber band is already returning the content,
    /// it is a page that bounces and a title that slides left and right as the record count
    /// appears and disappears under it. The band between the two thresholds is twenty points —
    /// comfortably more than the seven the collapse itself moves — so nothing the header does
    /// can undo the reading that produced it.
    @ViewBuilder
    private func measured(_ content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Thresholds.self) { geometry in
                // Measured from where the content rests, not from the raw offset: a scroll view
                // under a hundred-point header sits at −100 when it has not been touched, so
                // `contentOffset.y > 16` meant "scrolled past a hundred and sixteen points" on
                // one screen and something else on the next.
                let travelled = geometry.contentOffset.y + geometry.contentInsets.top
                return Thresholds(
                    // Past the top by more than a rubber-band wobble.
                    beyondCollapse: travelled > 24,
                    beyondReturn: travelled > 4,
                    far: travelled > geometry.containerSize.height * 0.75
                )
            } action: { _, crossed in
                isScrolled = crossed.far
                if crossed.beyondCollapse {
                    chrome?.setScrolled(true)
                } else if !crossed.beyondReturn {
                    chrome?.setScrolled(false)
                }
            }
        } else {
            content.onAppear { isScrolled = true }
        }
    }

    private struct Thresholds: Equatable {
        /// Far enough down that the header should give up its second line.
        let beyondCollapse: Bool
        /// Still far enough down that it should stay given up.
        let beyondReturn: Bool
        let far: Bool
    }
}
