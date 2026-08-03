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

    let session: SpaceSession

    @State private var tab: Tab = .home
    @State private var sidebarSelection: SidebarItem? = .home
    @State private var showingSettings = false

    enum Tab: Hashable { case home, search, research, chat }

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

    private var tabView: some View {
        // Four tabs, not five. "Browse" showed the same sections as Home in a list instead
        // of a grid, so it cost a tab to say nothing new.
        TabView(selection: $tab) {
            page { HomeView(session: session, openResearch: { tab = .research }) }
                .tabItem { Label("Home", systemImage: "house") }
                .tag(Tab.home)

            page { SearchScreen(session: session) }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)

            page { ResearchView(session: session) }
                .tabItem { Label("Research", systemImage: "doc.text.magnifyingglass") }
                .tag(Tab.research)

            page { ChatTab(session: session) }
                .tabItem { Label("Chat", systemImage: "bubble.left.and.text.bubble.right") }
                .tag(Tab.chat)
        }
        .tint(session.accent)
        // Everything inside a tab, pushed screens included: nothing here hides the tab bar on
        // a push, so it floats over the bottom-right corner of every one of these screens.
        .environment(\.nodusHasTabBar, true)
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
                // The tab bar's own background, stated rather than left to the system.
                //
                // Left alone it has two: a translucent one while content is passing under it,
                // and an opaque `systemBackground` — flat white in light mode — the moment the
                // content ends above it. So the same bar was a tinted band on one screen and a
                // white slab with a hard edge on the next, on a page whose backdrop is neither.
                // One material in both states, with the accent wash showing through it.
                .toolbarBackground(.ultraThinMaterial, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
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
            activity: session.isLoading ? 1 : 0
        ) {
            Button {
                model.closeSession()
            } label: {
                Image(systemName: "rectangle.stack")
            }
            .tint(session.accent)
            .accessibilityLabel("Switch space")
        } trailing: {
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .tint(session.accent)
            .accessibilityLabel("Settings")
        }
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
