import NodusUI
import SwiftUI

/// Everything you can do to a report, said in words.
///
/// It was five bare glyphs in a row under the title: a page, a page with lines on it, a page
/// with an arrow, a small A and a large A. Two of those five differ from each other by whether
/// the drawing has lines in it, and the difference they actually stand for — with the citations
/// or without them, which is the difference between a copy you paste into a document and one you
/// paste into a voice reader — is not a thing a glyph can say. Nobody could read that row.
///
/// So: the two copies become one labelled control with a menu, because they are two forms of one
/// act; the PDF keeps its own button and gains its name; and the text size becomes a pair of
/// steppers inside a single bordered group, which is what makes two 44-point targets read as one
/// control with two ends rather than as two more mystery glyphs.
struct ReportActions: View {
    /// The report as Markdown, which is what a copy is of.
    let markdown: String
    /// Prepended to the listening copy when the Markdown does not open with the title itself.
    var title: String?
    /// Set for a published report, which the server can render as a PDF. A report generated on
    /// this device has no id in the vault and so no document to ask for.
    var pdf: (session: SpaceSession, reportId: String, filename: String)?
    /// Set for a report generated here, by an access that may send changes.
    ///
    /// Optional rather than a flag the caller flips, so "a report already in the vault has no
    /// send control" is structural: `PublishedReportReader` simply has nothing to pass.
    var send: ReportSendContext?
    let accent: Color

    var body: some View {
        // Wrapping rather than a fixed row: at the larger text sizes three labelled controls do
        // not fit across a phone, and a row that overflows is worse than one that wraps.
        FlowLayout(spacing: NodusSpace.card) {
            // First, because it is the act this screen is now about and the first chip is the
            // one that never ends up on the second line.
            if let send {
                ReportSendButton(context: send)
            }
            ReportCopyButtons(markdown: markdown, title: title, accent: accent)
            if let pdf {
                ReportPDFButton(
                    session: pdf.session,
                    reportId: pdf.reportId,
                    title: pdf.filename,
                    accent: accent
                )
            }
            ReadingSizeButtons(accent: accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The shape all three of them wear: a 44-point-tall bordered group in the accent.
///
/// It is deliberately the same geometry as `NodusGlassButtonStyle` without being that style —
/// a `Menu` and a `ShareLink` cannot take a `ButtonStyle` and still look like one, and a
/// stepper is two buttons in one container rather than a button at all.
struct ReportActionSurface: ViewModifier {
    let accent: Color

    func body(content: Content) -> some View {
        content
            .frame(minHeight: 44)
            .background(accent.opacity(0.12), in: NodusRadius.controlShape)
            .overlay {
                NodusRadius.controlShape
                    .strokeBorder(accent.opacity(0.4), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func reportActionSurface(accent: Color) -> some View {
        modifier(ReportActionSurface(accent: accent))
    }

    /// Holds a chip at the width of the longest thing it can say.
    ///
    /// Two of these controls change their word when they are pressed — "Copy" for "Copied",
    /// "Send" for "Sent" — and in every language the app ships the acknowledgement is the longer
    /// of the two. Growing is not the problem; growing *inside a `FlowLayout`* is. The row is
    /// laid out again from the new ideal width and places the chip at it immediately, while the
    /// chip's own border is still animating there from the old one. For the length of that
    /// animation the border and the surface under it are two rectangles of different widths,
    /// which is exactly what a reader sees: a button whose outline is broken down one side and
    /// which then appears to shrink back.
    ///
    /// Laying the other states out invisibly underneath means there is no new width to animate
    /// to. The chip is as wide as its longest state from the first frame, and pressing it swaps
    /// a word inside a box that does not move.
    func reportActionWidth(@ViewBuilder reserving states: () -> some View) -> some View {
        ZStack {
            states().hidden()
            self
        }
    }
}
