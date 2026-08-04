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
    /// Set for prose that is meant to be read for minutes rather than glanced at: a report, an
    /// immersion station. It buys open leading, real space between paragraphs, headings that can
    /// be found by scrolling past them, and both margins straight.
    ///
    /// The justification is the one setting here that has been argued twice. It went away
    /// because a 370-point measure holds seven or eight words and straightening both margins on
    /// that opens rivers of white — and it is back because a report is a document, the desktop
    /// sets the same prose justified, and a phone showing it ragged was the odd one out. What
    /// does not come back with it is the hyphenation: that is what actually made it unreadable,
    /// breaking a word on most lines of twenty pages.
    var document = false

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

    /// Two ends of one control, inside one border.
    ///
    /// They were two bare glyphs in the same row as three other bare glyphs, and the two that
    /// change the text size looked exactly as much like "copy" as the ones that copy. Drawn as
    /// a single bordered group with a divider down the middle, the pair reads as a stepper — the
    /// shape iOS uses for exactly this — and gains a visible area to aim at, which is what a
    /// 17-point glyph floating on a page never had.
    var body: some View {
        HStack(spacing: 0) {
            button(
                "textformat.size.smaller",
                label: "Smaller text",
                enabled: preferences.canShrinkReading,
                delta: -AppPreferences.readingScaleStep
            )
            Rectangle()
                .fill(accent.opacity(0.3))
                .frame(width: 1, height: 22)
            button(
                "textformat.size.larger",
                label: "Larger text",
                enabled: preferences.canEnlargeReading,
                delta: AppPreferences.readingScaleStep
            )
        }
        .reportActionSurface(accent: accent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Text size")
    }

    private func button(
        _ systemImage: String,
        label: LocalizedStringKey,
        enabled: Bool,
        delta: Double
    ) -> some View {
        Button {
            // No `withAnimation`. A report is a stack of `UITextView`s several thousand words
            // long, and animating a text-size change asks SwiftUI to interpolate every one of
            // their heights over 150 ms — re-laying out the whole document on every frame of
            // it. The tap felt stuck because it was: the work was real and the animation
            // multiplied it. Changing the size is instant, which is also what it should be.
            preferences.adjustReading(by: delta)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 46, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? accent.nodusReadable : Color.nodusTertiaryText)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
