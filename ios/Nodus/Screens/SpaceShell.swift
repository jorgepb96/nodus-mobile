import NodusKit
import NodusUI
import SwiftUI

/// The shell around an open space.
///
/// iPhone and iPad share the same bottom navigation, header, and screens. Keeping one shell
/// across form factors makes moving between sections predictable wherever the space is opened.
struct SpaceShell: View {
    @Environment(AppModel.self) private var model
    @Environment(AppPreferences.self) private var preferences
    @Environment(OutboxTrayModel.self) private var tray

    let session: SpaceSession

    @State private var tab: Tab = .home
    /// Which tabs have ever been opened.
    ///
    /// The four pages are held side by side rather than swapped, so each keeps its navigation
    /// stack and its scroll position — but a page nobody has opened should not be loading a
    /// corpus in the background, which is the one thing `TabView` was doing for free.
    @State private var visited: Set<Tab> = [.home]
    @State private var showingSettings = false
    @State private var chrome = NodusChrome()

    enum Tab: Hashable, CaseIterable { case home, search, research, chat }

    var body: some View {
        tabView
            .environment(chrome)
            .task {
                await session.load()
                await session.loadMirror()
                await session.probeEmbedding()
            }
            .nodusSheet(isPresented: $showingSettings) {
                SpaceSettingsView(session: session)
                    .nodusModalClose(accent: session.accent)
            }
    }

    // MARK: Navigation

    /// The four tabs and the bar under them, both drawn here.
    ///
    /// Not a `TabView`. Its bar cannot be shortened, its selected tab cannot be given a quieter
    /// state than the large translucent capsule iOS 26 puts there, and it cannot be hidden for
    /// the screens that are documents — see `NodusTabBar`. What a `TabView` was actually buying
    /// is that each tab keeps its own navigation stack and scroll position while the others stay
    /// loaded, and a `ZStack` of pages that have been visited buys the same thing: the identity
    /// of each page is stable, so its state is too.
    private var tabView: some View {
        ZStack {
            // Four tabs, not five. "Browse" showed the same sections as Home in a list instead
            // of a grid, so it cost a tab to say nothing new.
            ForEach(Tab.allCases, id: \.self) { candidate in
                if visited.contains(candidate) {
                    page { content(for: candidate) }
                        .opacity(tab == candidate ? 1 : 0)
                        // Both are needed and they are not the same thing: a transparent view
                        // still takes touches, and VoiceOver still reads it.
                        .allowsHitTesting(tab == candidate)
                        .accessibilityHidden(tab != candidate)
                        .zIndex(tab == candidate ? 1 : 0)
                }
            }
        }
        .tint(session.accent)
        // Everything inside a tab, pushed screens included: the bar floats over the bottom of
        // every one of these screens unless a screen has asked it not to.
        .environment(\.nodusHasTabBar, !chrome.hidesBottomBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !chrome.hidesBottomBar {
                NodusTabBar(selection: $tab, accent: session.accent, items: tabItems)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(NodusMotion.standard, value: chrome.hidesBottomBar)
        .onChange(of: tab) { _, opened in
            visited.insert(opened)
            // A new page starts at the top, so the header does not arrive already collapsed.
            chrome.setScrolled(false)
            // The page you just left is still in the hierarchy — that is how it keeps its
            // scroll position — so a field focused on it stays first responder and its keyboard
            // stays up over the tab you switched to, belonging to a screen you can no longer
            // touch. Leaving a tab is leaving the field on it.
            Keyboard.dismiss()
        }
    }

    private var tabItems: [NodusTabBar<Tab>.Item] {
        [
            .init(tab: .home, title: "Home", systemImage: "house"),
            .init(tab: .search, title: "Search", systemImage: "magnifyingglass"),
            .init(tab: .research, title: "Research", systemImage: "doc.text.magnifyingglass"),
            .init(tab: .chat, title: "Chat", systemImage: "bubble.left.and.text.bubble.right"),
        ]
    }

    @ViewBuilder
    private func content(for tab: Tab) -> some View {
        switch tab {
        case .home: HomeView(session: session, openResearch: { self.tab = .research })
        case .search: SearchScreen(session: session)
        case .research: ResearchView(session: session)
        case .chat: ChatTab(session: session)
        }
    }

    /// Each tab is its own navigation stack.
    ///
    /// The header belongs to the *root* of the stack, not above the whole stack. Floating it
    /// over the TabView meant hiding the navigation bar everywhere to stop the two colliding —
    /// which also took the back button with it, and left a pushed list with no way out.
    /// Pushed screens keep the ordinary bar; only the root wears the mark.
    ///
    /// The backdrop goes inside each page rather than once behind the `TabView`: a TabView
    /// draws its own opaque page background over anything behind it, so a single shared
    /// backdrop showed up as plain black the moment a tab was selected.
    ///
    /// Room for the bar comes from the backdrop, and it is the same backdrop every screen in the
    /// app asks for. The bar is added with `safeAreaInset` on the stack of pages, *outside* these
    /// navigation stacks, and a `NavigationStack` does not pass an outer inset on to what it
    /// shows: measured, a page in a tab reports 34 points of bottom safe area, which is the home
    /// indicator and nothing else. So the last fifty points of every tab were drawn behind the
    /// bar — the chat's composer, which was therefore not on screen at all, and the last card of
    /// Home, which you could scroll to and still not see.
    ///
    /// This wrapper used to reserve those points itself, which fixed the four roots and left
    /// every screen *pushed* from one still drawing its last row under the bar. The reservation
    /// belongs to whatever is inside the stack rather than to the stack, so it went to
    /// `nodusPageBackdrop` — where the root gets it from the call below, and a pushed screen gets
    /// it from its own.
    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack {
            content()
                .safeAreaInset(edge: .top) { header }
                .toolbar(.hidden, for: .navigationBar)
                .nodusPageBackdrop(accent: session.accent)
        }
    }

    // MARK: Chrome

    private var header: some View {
        NodusHeader(
            title: session.connection.spaceName,
            subtitle: subtitle,
            accent: session.accent,
            activity: session.isLoading ? 1 : 0,
            collapsed: chrome.isScrolled
        ) {
            // Never more than two a side: the mark is centred by reserving 92 points at each
            // end, and a third 44-point control would meet the vault's name in the middle.
            HStack(spacing: 2) {
                headerButton("rectangle.stack", label: "Switch space") { model.closeSession() }
                if let chat = chatControls { historyButton(chat) }
            }
        } trailing: {
            // Each glyph in its own 44-point box, not the pair in one.
            //
            // The accessory slot sizes what it is handed, so handing it an `HStack` gave the
            // *cluster* the 44 points and left each button as wide as its own drawing — two
            // 17-point targets sitting eight points apart, which reads as one control that has
            // been drawn twice and misses half the taps aimed at either.
            HStack(spacing: 2) {
                if let chat = chatControls { layersMenu(chat) }
                if showsLayoutToggle { layoutToggle }
                // In the chrome, and present in every vault including a read-only one: the queue
                // spans the device, so a change queued in another space is still this device's
                // unfinished business. Hidden only when nothing on this device could ever queue
                // anything at all.
                if canQueueAnywhere { queueButton }
                headerButton("gearshape", label: "Settings") { showingSettings = true }
            }
        }
    }

    /// Whether any space this device holds could put something in the queue.
    ///
    /// Read from the model's own list rather than from `storedConnections()`, which re-parses
    /// `UserDefaults` — and this is in a view body.
    private var canQueueAnywhere: Bool {
        model.connections.contains { $0.role.canSendChanges }
    }

    /// The queue, with a dot when it is holding something.
    ///
    /// A dot rather than a number: at 44 points beside two other glyphs there is no room for a
    /// legible count, and the question this answers from here is "is there anything?" — the
    /// tray itself is where "how much, and what" is answered.
    private var queueButton: some View {
        headerButton("tray.and.arrow.up", label: "Send queue") { tray.open() }
            .overlay(alignment: .topTrailing) {
                if tray.outbox.pending > 0 {
                    Circle()
                        .fill(Color.nodusCaution)
                        .frame(width: 8, height: 8)
                        .padding(.top, 9).padding(.trailing, 9)
                        .allowsHitTesting(false)
                }
            }
            .animation(NodusMotion.quick, value: tray.outbox.pending)
    }

    /// The chat's controls, but only while the chat is the screen you are looking at.
    ///
    /// The four tabs are held side by side rather than swapped, so the chat page does not
    /// disappear when you leave it and cannot be relied on to take its controls with it. What
    /// decides whether they are on the header is the same thing that decides which page is
    /// visible: the shell's own selection.
    private var chatControls: ChatControls? {
        tab == .chat ? chrome.chat : nil
    }

    private func historyButton(_ chat: ChatControls) -> some View {
        headerButton("clock.arrow.circlepath", label: "History") { chat.openHistory() }
    }

    /// Which layers of the corpus a question is answered from.
    ///
    /// Read straight off the chat's own state rather than from a copy, so a layer switched off
    /// here is switched off in the payload the next question builds.
    private func layersMenu(_ chat: ChatControls) -> some View {
        Menu {
            ForEach(ContextSectionKind.allCases, id: \.self) { kind in
                Button {
                    if chat.include.contains(kind) {
                        chat.include.remove(kind)
                    } else {
                        chat.include.insert(kind)
                    }
                } label: {
                    // `LocalizedStringKey(_:)` around the name, because the section's label is a
                    // computed `String` and `Label(_:systemImage:)` handed one of those renders
                    // it verbatim — which is how a menu of English layer names survived in a
                    // Spanish app.
                    Label(
                        LocalizedStringKey(CorpusRetrieval.MaterialSection(kind: kind, rows: []).label),
                        systemImage: chat.include.contains(kind) ? "checkmark" : ""
                    )
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .tint(session.accent)
        .accessibilityLabel("Corpus layers")
    }

    /// The shape every control in the header wears: the glyph, centred in a 44-point square.
    private func headerButton(
        _ systemImage: String,
        label: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .tint(session.accent)
        .accessibilityLabel(label)
    }

    /// Board or list, in the chrome rather than on the page.
    ///
    /// It used to be a row of its own above Home's first section: a single 38-point circle
    /// pinned right, with sixty points of nothing beside it and another twenty-six under it
    /// before the content began. That is a lot of screen for one control, and it is the kind of
    /// control the chrome is for — it changes the shape of the screen rather than being part of
    /// what the screen says.
    private var layoutToggle: some View {
        Button {
            withAnimation(NodusMotion.standard) {
                preferences.homeLayout = preferences.homeLayout.toggled
            }
        } label: {
            Image(systemName: preferences.homeLayout.toggled.systemImage)
                // No glass circle any more: beside the gear it has to be the same kind of
                // object as the gear, in the same 44-point square.
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .tint(session.accent)
        .accessibilityLabel(preferences.homeLayout == .grid ? "Show as a list" : "Show as a grid")
    }

    /// Only where it does something. On the other three tabs it would be a control that changes
    /// a screen you are not looking at.
    private var showsLayoutToggle: Bool {
        tab == .home
    }

    private var subtitle: String? {
        // `String(localized:)` rather than a bare literal: this is a computed value handed to a
        // header that renders it as data, and a literal would ship in one language only.
        if !session.isPublished { return String(localized: "Not published") }
        guard let overview = session.overview else { return nil }
        let rows = overview.counts.values.reduce(0, +)
        guard rows > 0 else { return nil }
        return String(localized: "\(rows.formatted()) records")
    }
}
