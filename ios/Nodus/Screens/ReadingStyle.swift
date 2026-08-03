import SwiftUI
import UIKit

/// How a long document is set: its size, and whether its paragraphs are justified.
///
/// It travels in the environment rather than as a parameter because the reader that owns the
/// controls and the prose that obeys them are several views apart — a report is a header, a
/// stack of sections and a bibliography, and `CorpusProse` appears in all of them. A screen
/// that never sets it renders exactly as it did before.
struct ReadingStyle: Equatable {
    /// A multiple of whatever Dynamic Type already decided. 1 is "as the rest of the app".
    var scale: Double = 1
    /// Justified paragraphs, which only a document wants: a chat bubble or a list cell set
    /// justified is a ragged mess of word spacing.
    var justified = false

    static let plain = ReadingStyle()

    /// A text style at this reading size, in points.
    ///
    /// Built from the user's own Dynamic Type size rather than from a constant, so enlarging a
    /// report scales *their* body size instead of overriding it.
    func size(_ style: UIFont.TextStyle) -> CGFloat {
        UIFont.preferredFont(forTextStyle: style).pointSize * scale
    }

    func font(_ style: UIFont.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(size: size(style), weight: weight)
    }

    func uiFont(_ style: UIFont.TextStyle, weight: UIFont.Weight = .regular) -> UIFont {
        .systemFont(ofSize: size(style), weight: weight)
    }
}

private struct ReadingStyleKey: EnvironmentKey {
    static let defaultValue = ReadingStyle.plain
}

extension EnvironmentValues {
    var nodusReadingStyle: ReadingStyle {
        get { self[ReadingStyleKey.self] }
        set { self[ReadingStyleKey.self] = newValue }
    }
}

extension View {
    func nodusReadingStyle(_ style: ReadingStyle) -> some View {
        environment(\.nodusReadingStyle, style)
    }
}

/// The two letters, next to the copy and download buttons.
///
/// A phone screen is narrow and a Deep Research report is a book chapter; the system's own
/// text-size control is three taps away in Settings and changes the whole device. This changes
/// the document, where the problem is.
struct ReadingSizeButtons: View {
    let accent: Color

    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        HStack(spacing: 0) {
            button(
                "textformat.size.smaller",
                label: "Smaller text",
                enabled: preferences.canShrinkReading,
                delta: -AppPreferences.readingScaleStep
            )
            button(
                "textformat.size.larger",
                label: "Larger text",
                enabled: preferences.canEnlargeReading,
                delta: AppPreferences.readingScaleStep
            )
        }
    }

    private func button(
        _ systemImage: String,
        label: LocalizedStringKey,
        enabled: Bool,
        delta: Double
    ) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                preferences.readingScale += delta
            }
        } label: {
            Image(systemName: systemImage)
                .font(.callout)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? accent : Color.secondary.opacity(0.5))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
