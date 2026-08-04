import NodusKit
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

    /// The chat's own controls, for as long as the chat is the screen on show.
    ///
    /// The shell draws the header, so anything that belongs in the header has to be reachable
    /// from the shell — and the chat's controls are the chat's state. Handing over the object
    /// rather than a snapshot of it is what keeps the corpus-layer menu honest: it is
    /// `@Observable`, so a tick added from the header is seen by the screen and by the header,
    /// and neither has to be told.
    var chat: ChatControls?

    func setScrolled(_ scrolled: Bool) {
        guard isScrolled != scrolled else { return }
        isScrolled = scrolled
    }

    func hideBottomBar(_ token: UUID) { hiders.insert(token) }
    func showBottomBar(_ token: UUID) { hiders.remove(token) }
}

/// The two chat controls that live in the chrome rather than on the page.
///
/// They used to be a bar of their own under the header — a strip of grey material carrying a
/// history button, the conversation's name and a filter, above a conversation that had nowhere
/// to go but down. That is a whole row of screen spent on two controls that never change while
/// you read, which is what the header is for; the strip they leave behind is given to the one
/// thing you *do* change mid-conversation, which is the model answering it.
@MainActor
@Observable
final class ChatControls {
    /// Which layers of the corpus enter the payload — the same choice the desktop's assistant
    /// offers, since a question about a gap in the literature wants different material from one
    /// about what a work argues.
    var include: Set<ContextSectionKind> = Set(ContextSectionKind.allCases)
    /// Opens the conversation list. Set by the screen, called by the header.
    var openHistory: () -> Void = {}
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
