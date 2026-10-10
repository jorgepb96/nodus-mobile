import NodusUI
import SwiftUI

/// The compact title block used by Desktop content workspaces. It stays inside the scrolling
/// surface so the same hierarchy survives on iPhone instead of becoming a second iOS navbar.
struct DesktopPageHeader: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let systemImage: String
    let accent: Color
    private let trailing: AnyView?

    init(title: LocalizedStringKey, subtitle: LocalizedStringKey, systemImage: String, accent: Color) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.accent = accent
        trailing = nil
    }

    init<Trailing: View>(
        title: LocalizedStringKey, subtitle: LocalizedStringKey, systemImage: String, accent: Color,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.accent = accent
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        Group {
            if trailing != nil && (horizontalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize) {
                VStack(alignment: .leading, spacing: 12) {
                    titleBlock
                    trailing
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(alignment: .center, spacing: 11) {
                    titleBlock
                    Spacer(minLength: 0)
                    trailing
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var titleBlock: some View {
        HStack(alignment: .center, spacing: 11) {
            NodusIcon(name: systemImage, size: 17, weight: .medium)
                .foregroundStyle(accent.nodusReadable)
                .frame(width: 36, height: 36)
                .background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Color.nodusSecondaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .layoutPriority(1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nodus-page-heading")
    }
}

/// Desktop-like content rows: bounded and opaque enough to read as a working surface, while
/// retaining the same touch target and reflow on the phone.
struct DesktopContentRowModifier: ViewModifier {
    let accent: Color

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nodusGlass(NodusGlass(.regular, tint: accent), in: NodusRadius.panelShape)
    }
}

extension View {
    func desktopContentRow(accent: Color) -> some View {
        modifier(DesktopContentRowModifier(accent: accent))
    }
}
