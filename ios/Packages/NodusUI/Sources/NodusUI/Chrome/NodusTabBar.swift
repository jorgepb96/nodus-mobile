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
        .padding(.top, 5)
        .padding(.bottom, 3)
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
        .frame(height: 44)
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
