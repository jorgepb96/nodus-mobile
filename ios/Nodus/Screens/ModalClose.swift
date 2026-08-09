import NodusUI
import SwiftUI

/// The way out of a modal, put where the thumb already is.
///
/// A sheet offers two ways to close it and both of them are at the top of the screen: "Done" in
/// the navigation bar, or a drag that has to start on the sheet's own header. For a modal opened
/// from the middle of something being read — a source pressed in a report, the providers gone to
/// check — that is the whole length of the phone travelled for an action that means "put this
/// away and give me back what I was reading".
///
/// So the same disc the page's own tools wear, centred along the bottom edge, pointing down.
/// Down because that is the direction the sheet goes when it closes, so the glyph says what
/// will happen rather than naming it. Centring keeps dismissal in a stable place whichever
/// page tools the modal happens to carry and stops the control reading as attached to a corner.
///
/// Applied per sheet rather than by `nodusSheet` itself, because not every modal closes by being
/// closed. An editor's dismissal is a Cancel and belongs beside its Save, where a reader can see
/// what happens to what they typed; the report's own conversation keeps a composer along that
/// edge and has no room for anything over it.
struct NodusModalClose: ViewModifier {
    let accent: Color

    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .nodusFloatingCircle(accent: accent)
            }
            .tint(accent.nodusReadable)
            .accessibilityLabel("Close")
            // The same height off the bottom the page tools sit at inside a sheet, where there
            // is no bar under them: the two read as one pair rather than as two decisions.
            .padding(.bottom, 22)
        }
    }
}

extension View {
    /// Floats a centred "close this" control over a modal's bottom edge.
    func nodusModalClose(accent: Color) -> some View {
        modifier(NodusModalClose(accent: accent))
    }
}
