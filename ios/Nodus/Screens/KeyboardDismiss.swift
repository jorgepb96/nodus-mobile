import SwiftUI
#if os(iOS)
import UIKit
import WebKit
#endif

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
    /// Tapping is handled a level up, by `nodusDismissesKeyboardOnTap` on the app's window,
    /// which is the one place a tap can be *observed* rather than consumed.
    func nodusDismissesKeyboard() -> some View {
        scrollDismissesKeyboard(.immediately)
    }

    /// Tap anywhere, on any screen, and the keyboard goes away.
    ///
    /// Installed once at the root of the app rather than per screen, because the failure this
    /// fixes is not per screen either: every field in the app raises a keyboard that only the
    /// chat knew how to put down, and a field that is scrolled to — Search's, a note's title, a
    /// provider key — had no gesture that would resign it at all.
    ///
    /// It is a `UITapGestureRecognizer` on the window rather than a SwiftUI `TapGesture` because
    /// of what SwiftUI gestures do to what is under them. `simultaneousGesture(TapGesture())`
    /// over a `List` wins the tap and the rows stop opening — that is the failure recorded above,
    /// and it is a property of SwiftUI's gesture arbitration, not something to be tuned around.
    /// A UIKit recogniser with `cancelsTouchesInView = false` has no such quarrel: it watches the
    /// touch go past and lets every button, row and link underneath receive it unchanged.
    func nodusDismissesKeyboardOnTap() -> some View {
        #if os(iOS)
        background { KeyboardDismissInstaller().allowsHitTesting(false) }
        #else
        self
        #endif
    }
}

#if os(iOS)

/// Resigning whatever is typing, without knowing what it is.
///
/// The app holds its four tabs side by side so each keeps its scroll position, which means a
/// page you have left is still in the hierarchy — merely transparent and not hit-testable. A
/// `TextField` on one of those pages therefore stays first responder after you switch tabs: the
/// keyboard was still up over Home, belonging to a field on Search that no longer takes touches,
/// and nothing on screen could put it away. Sending `resignFirstResponder` to `nil` walks the
/// responder chain and ends it, whichever page it was left on.
@MainActor
enum Keyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

/// A zero-sized view whose only job is to find the window and put one recogniser on it.
private struct KeyboardDismissInstaller: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = WindowWatcher()
        view.isUserInteractionEnabled = false
        // `didMoveToWindow` rather than `makeUIView`: a view has no window until it is in the
        // hierarchy, and by the time `updateUIView` first runs it may still not.
        view.onWindow = { [coordinator = context.coordinator] window in
            coordinator.install(in: window)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.install(in: view.window)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Which window already has the recogniser. A scene can be rebuilt, and the app can
        /// have more than one, so this is per-window rather than a global flag.
        private weak var installed: UIWindow?

        func install(in window: UIWindow?) {
            guard let window, window !== installed else { return }
            installed = window
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            // The whole of why this works. Left at its default the recogniser swallows the
            // touch, and every button, row and link in the app stops responding the moment a
            // keyboard is on screen.
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
        }

        @objc private func handleTap() {
            Keyboard.dismiss()
        }

        /// Never in competition with anything: a scroll, a row's tap, a drag on the map all
        /// recognise as they did before.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        /// Two kinds of tap are not a request to stop typing.
        ///
        /// A tap inside the field itself is a caret move. And a tap on the row the field is
        /// drawn in — the clear button at the end of `NodusSearchField`, the magnifier at its
        /// head — is part of the same act of typing: clearing a query is a prelude to typing
        /// another one, and losing the keyboard to it means reaching for the field again.
        ///
        /// The row is found by geometry rather than by view hierarchy. `superview` looks like
        /// the answer and is not: SwiftUI gives a `TextField` and the button laid out beside it
        /// no common parent worth the name, so the check found nothing and the clear button put
        /// the keyboard away. What the two do share is a line on the screen.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard let touched = touch.view else { return true }
            // WKContentView owns HTML inputs and rich editor selection. Treating it as
            // empty background resigns its responder immediately after the input focuses.
            var ancestor: UIView? = touched
            while let candidate = ancestor {
                // UIKit editing-menu arrows and actions are controls outside the field's
                // geometry. They must finish their action without resigning its responder.
                if candidate is WKWebView || candidate is UIControl { return false }
                ancestor = candidate.superview
            }
            if let window = installed, window.containsWebContent(at: touch.location(in: window), in: window) { return false }
            if touched.isInsideTextInput { return false }
            guard let window = installed, let responder = window.currentTextInput else { return true }
            // Sideways far enough to take in a trailing button and a leading glyph, and barely
            // at all downward — a row of content sixty points below is not part of the field.
            let row = responder.convert(responder.bounds, to: window).insetBy(dx: -64, dy: -10)
            return !row.contains(touch.location(in: window))
        }
    }
}

/// A view that says when it has a window, because `UIViewRepresentable` has no hook for it.
private final class WindowWatcher: UIView {
    var onWindow: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindow?(window)
    }
}

private extension UIView {
    func containsWebContent(at point: CGPoint, in window: UIWindow) -> Bool {
        guard !isHidden, alpha > 0.01 else { return false }
        if self is WKWebView, bounds.contains(convert(point, from: window)) { return true }
        return subviews.contains { $0.containsWebContent(at: point, in: window) }
    }
    /// The tap landed on a text field, or on something drawn inside one — SwiftUI's `TextField`
    /// is a `UITextField` with its own subviews, and a tap on the text lands on one of those.
    var isInsideTextInput: Bool {
        var view: UIView? = self
        while let candidate = view {
            if candidate is UITextField || candidate is UITextView { return true }
            view = candidate.superview
        }
        return false
    }

    /// Whatever is currently typing, if it is a text input rather than something else that
    /// happens to be first responder.
    var currentTextInput: UIView? {
        if isFirstResponder, self is UITextField || self is UITextView { return self }
        for subview in subviews {
            if let found = subview.currentTextInput { return found }
        }
        return nil
    }
}

#endif
