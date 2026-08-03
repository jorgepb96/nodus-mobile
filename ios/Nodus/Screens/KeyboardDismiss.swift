import SwiftUI

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
    /// Scrolling the results puts the keyboard away.
    ///
    /// Scroll and nothing else. The first version of this added
    /// `simultaneousGesture(TapGesture())` so a tap anywhere would dismiss too, on the
    /// reasoning that a simultaneous gesture recognises *alongside* the row's own and takes
    /// nothing from it. That is not what happens on a `List`: the container's recogniser wins
    /// the tap and the rows below it stop opening — the library, the reports and every other
    /// list went dead to the touch.
    ///
    /// So a list keeps the one gesture that cannot collide with a row, and `.immediately`
    /// rather than `.interactively` because the point is filtering: you type, you look, you
    /// scroll, and the keyboard should already be gone by then rather than follow the drag.
    ///
    /// Tap-to-dismiss lives where there is nothing to tap *through* — the chat, which handles
    /// it itself over prose rather than over rows.
    func nodusDismissesKeyboard() -> some View {
        scrollDismissesKeyboard(.immediately)
    }
}
