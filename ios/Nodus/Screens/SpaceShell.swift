import NodusKit
import NodusUI
import SwiftUI

/// The shell around an open space.
///
/// iPhone gets a tab bar; iPad gets the desktop's sidebar as a split view. Both share the same
/// header — the mark centred, the cutout absorbed into the chrome — and the same screens
/// underneath, because the difference is navigation, not content.
struct SpaceShell: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(AppModel.self) private var model
    @Environment(AppPreferences.self) private var preferences

    let session: SpaceSession

    @State private var tab: Tab = .home
    /// Which tabs have ever been opened.
    ///
    /// The four pages are held side by side rather than swapped, so each keeps its navigation
    /// stack and its scroll position — but a page nobody has opened should not be loading a
    /// corpus in the background, which is the one thing `TabView` was doing for free.
    @State private var visited: Set<Tab> = [.home]
    @State private var sidebarSelection: SidebarItem? = .home
    @State private var showingSettings = false
    @State private var chrome = NodusChrome()

    enum Tab: Hashable, CaseIterable { case home, search, research, chat }

    enum SidebarItem: Hashable {
        case home
        case collection(String)
        case debates
        case notes
        case deepResearch
        case search
        case writing
        case research
        case chat
    }

    /// The sidebar is for an iPad-shaped canvas, not for any wide one.
    ///
    /// `horizontalSizeClass == .regular` alone is true of a large iPhone held sideways, and
    /// that phone got the iPad layout: a sidebar over 390 points of height, a detail column
    /// beside it, and the floating header sitting on top of the split view's own toggle. A
    /// phone in landscape is a phone. Both classes regular is what actually means "there is
    /// room for two columns".
    private var wantsSidebar: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
    }

    var body: some View {
        Group {
            if wantsSidebar {
                splitView
            } else {
                tabView
            }
        }
        .environment(chrome)
        .task {
            await session.load()
            await session.loadMirror()
            await session.probeEmbedding()
        }
        .sheet(isPresented: $showingSettings) {
            SpaceSettingsView(session: session)
        }
    }

    // MARK: iPhone

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
    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack {
            content()
                .safeAreaInset(edge: .top) { header }
                .toolbar(.hidden, for: .navigationBar)
                .nodusPageBackdrop(accent: session.accent)
        }
    }

    // MARK: iPad

    /// The header above the split view, not floating over it.
    ///
    /// It used to be an `.overlay(alignment: .top)` with 96 points of clear inset pushed into
    /// both columns to make room. That works until something else wants the top of a column —
    /// and something does: the split view's own show/hide-sidebar button lives in the detail
    /// column's navigation bar, exactly under the overlay. It was there the whole time, behind
    /// the glass, and could not be tapped. A `VStack` gives the header the top of the window
    /// and leaves the columns their own.
    private var splitView: some View {
        VStack(spacing: 0) {
            header
            splitColumns
        }
        .background { NodusBackdrop(accent: session.accent) }
    }

    private var splitColumns: some View {
        NavigationSplitView {
            List(selection: $sidebarSelection) {
                Section {
                    Label("Home", systemImage: "house").tag(SidebarItem.home)
                    Label("Search", systemImage: "magnifyingglass").tag(SidebarItem.search)
                    Label("Research", systemImage: "doc.text.magnifyingglass").tag(SidebarItem.research)
                    Label("Chat", systemImage: "bubble.left.and.text.bubble.right").tag(SidebarItem.chat)
                }
                Section("Browse") {
                    ForEach(session.sections, id: \.path) { collection in
                        Label {
                            HStack {
                                Text(LocalizedStringKey(collection.label))
                                Spacer()
                                CountBadge(count: session.count(of: collection), accent: session.accent)
                            }
                        } icon: {
                            Image(systemName: collection.icon)
                        }
                        .tag(SidebarItem.collection(collection.path))
                    }
                }
                if session.connection.role.canSendChanges {
                    Section("Write") {
                        Label("Send queue", systemImage: "tray.and.arrow.up").tag(SidebarItem.writing)
                    }
                }
                if session.hasDebates || session.hasNotes || session.hasDeepResearch {
                    Section("Analyse") {
                        if session.hasDebates {
                            Label("Debates", systemImage: "bubble.left.and.bubble.right").tag(SidebarItem.debates)
                        }
                        if session.hasDeepResearch {
                            Label("Deep Research", systemImage: "doc.text.magnifyingglass").tag(SidebarItem.deepResearch)
                        }
                        if session.hasNotes {
                            Label("Notes", systemImage: "note.text").tag(SidebarItem.notes)
                        }
                    }
                }
            }
            .navigationTitle(session.connection.spaceName)
            .tint(session.accent)
        } detail: {
            NavigationStack {
                detailContent
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch sidebarSelection {
        case .home, .none: HomeView(session: session, openResearch: { sidebarSelection = .research })
        case .search: SearchScreen(session: session)
        case .research: ResearchView(session: session)
        case .chat: ChatTab(session: session)
        case .debates: SpecialListView(session: session, resource: .debates)
        case .notes: SpecialListView(session: session, resource: .notes)
        case .deepResearch: SpecialListView(session: session, resource: .deepResearch)
        case .writing: WritingView(session: session)
        case .collection(let path):
            if let collection = Collections[path] {
                CollectionListView(session: session, collection: collection)
            } else {
                ContentUnavailableView("Unknown section", systemImage: "questionmark.folder")
            }
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
            headerButton("rectangle.stack", label: "Switch space") { model.closeSession() }
        } trailing: {
            // Each glyph in its own 44-point box, not the pair in one.
            //
            // The accessory slot sizes what it is handed, so handing it an `HStack` gave the
            // *cluster* the 44 points and left each button as wide as its own drawing — two
            // 17-point targets sitting eight points apart, which reads as one control that has
            // been drawn twice and misses half the taps aimed at either.
            HStack(spacing: 2) {
                if showsLayoutToggle { layoutToggle }
                headerButton("gearshape", label: "Settings") { showingSettings = true }
            }
        }
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
        wantsSidebar ? sidebarSelection == .home : tab == .home
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
