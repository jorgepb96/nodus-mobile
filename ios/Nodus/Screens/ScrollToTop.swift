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
                                .font(.footnote.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .tint(accent)
                        .nodusGlass(NodusGlass(.prominent, tint: accent), in: Circle())
                        .padding(.trailing, 16)
                        // Clear of the floating tab bar where there is one, and low where
                        // there is not. 20 points everywhere put the button *on* the bar, which
                        // took the touch and did nothing with it; 92 everywhere left it hanging
                        // mid-page on every pushed screen in the app.
                        .padding(.bottom, hasTabBar ? 76 : 22)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        .accessibilityLabel("Back to top")
                    }
                }
                .animation(.easeOut(duration: 0.2), value: isScrolled)
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
            withAnimation(.easeOut(duration: 0.32)) {
                proxy.scrollTo(NodusScrollAnchor.top, anchor: .top)
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            proxy.scrollTo(NodusScrollAnchor.top, anchor: .top)
        }
    }

    @ViewBuilder
    private func measured(_ content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                // One screen's worth down: far enough that scrolling back is a chore, near
                // enough that the button is there when it starts to be.
                geometry.contentOffset.y > geometry.containerSize.height * 0.75
            } action: { _, scrolled in
                isScrolled = scrolled
            }
        } else {
            content.onAppear { isScrolled = true }
        }
    }
}
