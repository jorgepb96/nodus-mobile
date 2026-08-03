import SwiftUI
import UIKit

/// Ask whatever is focused to let go.
///
/// Up the responder chain rather than through a binding: the question is "whoever has the
/// keyboard, give it back", and it needs to know nothing about which field that was.
func nodusResignFirstResponder() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

/// Putting the keyboard away, on every screen that can raise one.
///
/// The chat got this first and the rest of the app did not, which is the wrong shape for a fix:
/// a filter field over a list of nine thousand ideas raises the same keyboard over the same
/// results, and iOS gives a plain `TextField` no way at all to resign — no Done key on a
/// single-line field, no tap-outside behaviour, nothing.
///
/// So it is a modifier rather than a per-screen `@FocusState`. Fifteen screens would have meant
/// fifteen focus bindings threaded to fifteen fields, and every screen written after this one
/// would have started out without one.
extension View {
    /// Drag to dismiss, and tap anywhere in the content to dismiss.
    ///
    /// Applied to the scrollable, not to the field: what the reader wants to touch is the thing
    /// the keyboard is covering. `simultaneousGesture` so a tap that lands on a row still opens
    /// it — putting the keyboard away is never the *only* thing a tap should do.
    func nodusDismissesKeyboard() -> some View {
        scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded { nodusResignFirstResponder() })
    }
}
