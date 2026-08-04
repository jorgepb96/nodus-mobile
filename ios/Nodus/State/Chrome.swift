import SwiftUI

/// What the shell's chrome is doing, asked for by the screens underneath it.
///
/// Two questions, and both of them are asked by a scrolling page about a bar it cannot see:
/// whether the header should be collapsed, and whether the bottom bar belongs on screen at all.
/// Neither can be answered by the screen itself — the chrome lives in `SpaceShell`, several
/// containers up — and neither can travel as a preference, because a `NavigationStack`'s pushed
/// destination does not reliably propagate one back to the stack's parent.
///
/// So it is a small piece of shared state, held by the shell and read by the chrome. A screen
/// states a fact about itself; the shell decides what to do about it.
@MainActor
@Observable
final class NodusChrome {
    /// True once the page under the header has been scrolled past a line or two.
    private(set) var isScrolled = false

    /// The screens currently asking for the bottom bar to get out of the way.
    ///
    /// A set of tokens rather than a flag or a counter: `onAppear` and `onDisappear` are not
    /// guaranteed to alternate during a navigation transition — a push can appear the new screen
    /// before disappearing the old one, and an interactive pop that is abandoned appears the
    /// same screen twice. Inserting and removing the same token is idempotent under all of that;
    /// a counter is not.
    private var hiders: Set<UUID> = []

    var hidesBottomBar: Bool { !hiders.isEmpty }

    func setScrolled(_ scrolled: Bool) {
        guard isScrolled != scrolled else { return }
        isScrolled = scrolled
    }

    func hideBottomBar(_ token: UUID) { hiders.insert(token) }
    func showBottomBar(_ token: UUID) { hiders.remove(token) }
}

extension View {
    /// Takes the bottom bar off the screen for as long as this view is on it.
    ///
    /// For the screens that are one long document — a report, an idea's dossier, an argument
    /// map. There is nothing on them the tab bar leads to, and forty points of chrome that only
    /// offers to take you somewhere else is forty points the document should have.
    func nodusHidesBottomBar() -> some View {
        modifier(HidesBottomBar())
    }
}

private struct HidesBottomBar: ViewModifier {
    @Environment(NodusChrome.self) private var chrome: NodusChrome?
    /// Stable for the lifetime of this view, which is what makes the insert/remove pair safe.
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { chrome?.hideBottomBar(token) }
            .onDisappear { chrome?.showBottomBar(token) }
    }
}
