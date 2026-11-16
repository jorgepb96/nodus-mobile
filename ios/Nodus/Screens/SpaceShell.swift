import NodusAI
import NodusKit
import NodusUI
import SwiftUI
import UIKit

private struct ResidentRouteActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// UIKit-backed content must hide its own accessibility tree when its route is resident.
    var nodusResidentRouteActive: Bool {
        get { self[ResidentRouteActiveKey.self] }
        set { self[ResidentRouteActiveKey.self] = newValue }
    }
}

/// Renders the original Nodus icon when SF Symbols has no semantic equivalent. The telescope
/// path comes from the desktop icon set; all other names continue to use native SF Symbols.
struct NodusIcon: View {
    let name: String
    var size: CGFloat = 16
    var weight: Font.Weight = .regular

    var body: some View {
        if name == "telescope" {
            Image("NodusTelescope")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: name)
                .font(.system(size: size, weight: weight))
        }
    }
}

extension NodusIcon {
    /// An SF Symbol at the tab bar's size as a template image the bar tints itself.
    @MainActor static func tabBarSymbol(_ name: String) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium))?
            .withRenderingMode(.alwaysTemplate)
    }

    /// The tab bar takes an image at its final size and tints it itself. The telescope asset
    /// is drawn at the tab bar's 25-point symbol size as a template so selection colours it.
    @MainActor static func tabBarImage(named name: String, side: CGFloat = 25) -> UIImage? {
        guard let source = UIImage(named: name), source.size.width > 0, source.size.height > 0 else { return nil }
        let scale = min(side / source.size.width, side / source.size.height)
        let size = CGSize(width: source.size.width * scale, height: source.size.height * scale)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            source.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }.withRenderingMode(.alwaysTemplate)
    }
}

/// Native menus can discard SwiftUI symbol styling when they turn a Label into a
/// UIKit action. Supply an original bitmap resolved for the presented color scheme
/// so dark menus cannot inherit a black template icon from the underlying button.
///
/// Use it for every icon row inside a `Menu`, including a menu `Picker`'s options. The two
/// `systemImage:` initialisers mirror `Label`'s, so a menu row swaps one name for the other.
struct NodusMenuLabel: View {
    private let title: Text
    let image: String
    @Environment(\.colorScheme) private var colorScheme

    init(title: LocalizedStringKey, image: String) {
        self.title = Text(title)
        self.image = image
    }

    init(_ titleKey: LocalizedStringKey, systemImage: String) {
        self.init(title: titleKey, image: systemImage)
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, systemImage: String) {
        self.title = Text(title)
        self.image = systemImage
    }

    var body: some View {
        Label {
            title
        } icon: {
            if let rendered = renderedIcon {
                Image(uiImage: rendered).renderingMode(.original)
            }
        }
    }

    private var renderedIcon: UIImage? {
        let source = image == "telescope" ? UIImage(named: "NodusTelescope") : UIImage(systemName: image,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular))
        guard let source, source.size.width > 0, source.size.height > 0 else { return nil }
        let tinted = source.withTintColor(colorScheme == .dark ? .white : .black, renderingMode: .alwaysOriginal)
        let side: CGFloat = 20
        let scale = min(side / source.size.width, side / source.size.height)
        let size = CGSize(width: source.size.width * scale, height: source.size.height * scale)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            tinted.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                width: size.width, height: size.height))
        }.withRenderingMode(.alwaysOriginal)
    }
}

/// One adaptive shell for iPhone and iPad. Width changes the sidebar presentation, never the
/// hierarchy or the destination set.
struct SpaceShell: View {
    @Environment(AppModel.self) private var model
    @Environment(AppPreferences.self) private var preferences
    @Environment(OutboxTrayModel.self) private var tray
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .footnote) private var scaledSidebarWidth: CGFloat = 176

    let session: SpaceSession

    @State private var route: NodusRoute
    /// Resident sections replace `.id(route)`, which rebuilt the selected hierarchy and lost
    /// filters, scroll position and document tabs every time the sidebar changed destination.
    @State private var residentRoutes: [NodusRoute]
    @State private var workspaceTabs = WorkspaceTabs()
    @State private var showingDrawer = false
    @State private var showingAssistant = false
    @State private var showingCommands = false
    @State private var chrome = NodusChrome()
    @State private var sidebarResizeOrigin: Double?
    @State private var downloads: LinkDownloads
    @State private var phoneTab: PhoneTab = .home
    @State private var phoneSheet: PhoneSectionSheet?
    /// Tab bar, player and home indicator, measured from the native tab page. Seeded with the
    /// usual iPhone value so the first frame does not draw content under the bar.
    @State private var phoneBarInset: CGFloat = 83

    init(session: SpaceSession) {
        self.session = session
        _downloads = State(initialValue: LinkDownloads(session: session))
        var initial = UserDefaults.standard.string(forKey: "nodus.navigation.lastRoute.\(session.connection.id)")
            .flatMap(NodusRoute.init(rawValue:)) ?? .home
#if DEBUG
        // Deterministic visual-QA entry point. `simctl` can set this without persisting a
        // different navigation state for real users, which lets every phase capture the exact
        // same native screen on iPhone and iPad.
        if let raw = ProcessInfo.processInfo.environment["NODUS_START_ROUTE"],
           let requested = NodusRoute(rawValue: raw) {
            initial = requested
        }
#endif
        if !NodusLinkPolicy.routes.contains(initial) { initial = .home }
        _route = State(initialValue: initial)
        _residentRoutes = State(initialValue: [initial])
    }

    var body: some View {
        shellLayout
        .environment(chrome)
        .environment(workspaceTabs)
        .environment(downloads)
        .environment(\.nodusHasTabBar, false)
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Nodus")
                .accessibilityIdentifier("nodus-space-shell")
                .allowsHitTesting(false)
        }
        .background {
            if let view = session.podcastPlayback.opusWebView {
                LinkPodcastAudioHost(view: view).frame(width: 1, height: 1).accessibilityHidden(true).allowsHitTesting(false)
            }
        }
        .sheet(isPresented: Binding(get: { session.podcastPlayback.showingPlayer }, set: { session.podcastPlayback.showingPlayer = $0 })) {
            LinkPodcastPlayer(playback: session.podcastPlayback, accent: session.accent)
        }
        .task {
            await session.load()
            await session.loadMirror()
            await session.probeEmbedding()
        }
        .task { await session.monitorPublishedContent() }
        .task(id: scenePhase) {
            guard scenePhase == .active, !session.isDemo else { return }
            while !Task.isCancelled {
                await downloads.checkForChanges()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        .onChange(of: session.contentEpoch) { _, _ in
            if scenePhase == .active, !session.isDemo { Task { await downloads.checkForChanges() } }
        }
        .alert("Download unavailable", isPresented: Binding(get: { downloads.issue != nil }, set: { if !$0 { downloads.issue = nil } })) {
            Button("OK") { downloads.issue = nil }
        } message: { Text(downloads.issue ?? "") }
        .onReceive(NotificationCenter.default.publisher(for:.nodusMobileNavigate)) { event in
            guard event.userInfo?["connectionId"] as? String == session.connection.id,
                  let value = event.userInfo?["route"] as? String, let target = NodusRoute(rawValue:value) else { return }
            showingAssistant = false; select(target)
        }
        .nodusSheet(isPresented: $showingAssistant) {
            NavigationStack { ChatTab(session: session, showsModalDone: true) }
        }
        .sheet(isPresented: $showingCommands) {
            CommandPalette(session: session, selection: route) { selected in
                showingCommands = false
                select(selected)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    /// The top bar, sidebar or drawer, and the resident routes. One instance for the whole
    /// session: the phone tab bar only reserves space beneath it, so switching tabs never
    /// rebuilds a route and loses its scroll position, filters or document tabs.
    private var workspace: some View {
        GeometryReader { proxy in
            let presentation = SidebarPresentation(
                availableWidth: proxy.size.width,
                isUserCollapsed: preferences.sidebarCollapsed,
                isPhone: UIDevice.current.userInterfaceIdiom == .phone,
                expandedWidth: textSize.isAccessibilitySize
                    ? max(CGFloat(preferences.sidebarWidth), scaledSidebarWidth)
                    : CGFloat(preferences.sidebarWidth)
            )
            // Resident routes sit below the top bar and, on a regular-width device, beside
            // the persistent sidebar. Freezing an inactive route to the whole window made
            // that hidden route dictate the ZStack's minimum size: one top bar too tall and
            // one sidebar too wide. The visible workspace was consequently clipped at the
            // bottom and trailing edge on iPad in both orientations.
            let residentRouteSize = session.isSurfaceFullscreen ? proxy.size : presentation.residentRouteSize(in: proxy.size)

            ZStack(alignment: .leading) {
                VStack(spacing: 0) {
                    if !session.isSurfaceFullscreen { DesktopTopBar(
                        session: session,
                        presentation: presentation,
                        pinRoute: route == .home ? nil : route,
                        queueCount: tray.outbox.pending,
                        onToggleNavigation: { toggleNavigation(presentation) },
                        onSwitchSpace: { model.closeSession() },
                        onCommands: { showingCommands = true },
                        onAssistant: { showingAssistant = true },
                        onQueue: { tray.open() },
                        onRefresh: { Task { await session.refreshAll() } },
                        onTheme: { preferences.toggleInterfaceStyle(current: colorScheme) },
                        onSettings: { select(.settings) }
                    ) }

                    HStack(spacing: 0) {
                        if presentation.isPersistent, !session.isSurfaceFullscreen {
                            sidebar(collapsed: presentation.isCollapsed)
                                .frame(width: presentation.sidebarWidth)
                                .overlay(alignment: .trailing) {
                                    if !presentation.isCollapsed {
                                        sidebarResizeHandle
                                    }
                                }
                        }
                        routeContainer(frozenSize: residentRouteSize)
                    }
                }

                if !presentation.isPersistent, showingDrawer, !session.isSurfaceFullscreen {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(NodusMotion.standard) { showingDrawer = false } }
                        .accessibilityElement()
                        .accessibilityLabel("Close navigation")
                        .accessibilityIdentifier("nodus-navigation-dismiss")
                        .accessibilityAddTraits(.isButton)
                        .transition(.opacity)

                    sidebar(collapsed: false)
                        // The scrim paints outside the safe area. Its expanded size must not
                        // become the drawer's layout proposal and move Home under the clock.
                        .frame(width: min(320, proxy.size.width * 0.86), height: proxy.size.height)
                        .shadow(color: .black.opacity(0.28), radius: 24, x: 8)
                        .transition(.move(edge: .leading))
                }

            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background {
                ScreenEdgeNavigationInstaller(enabled: !presentation.isPersistent && !session.isSurfaceFullscreen && !showingDrawer) {
                    withAnimation(NodusMotion.standard) { showingDrawer = true }
                }
            }
            .animation(NodusMotion.standard, value: showingDrawer)
            .animation(NodusMotion.standard, value: presentation.sidebarWidth)
        }
    }

    /// iPhone keeps a native tab bar, the only control that gets the system's Liquid Glass
    /// selection lens and drag-between-tabs behaviour on iOS 26. The tab bar sits behind the
    /// single shared workspace and only reserves the space measured under it; its tabs carry no
    /// content of their own. iPad has no tab bar: the player sits under the workspace instead.
    @ViewBuilder private var shellLayout: some View {
        if isPhone {
            ZStack {
                phoneTabHost
                workspace
                    .padding(.bottom, phoneBarInset)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
            .sheet(item: $phoneSheet, onDismiss: { phoneTab = routeTab }) { sheet in
                switch sheet {
                case .more:
                    PhoneSectionPicker(title: "More", items: morePhoneSections, selection: route, accent: session.accent) { picked in
                        phoneSheet = nil
                        select(picked)
                    }
                case .pin:
                    PhoneSectionPicker(title: "Choose a pinned section", items: unpinnedPhoneSections, selection: nil, accent: session.accent) { picked in
                        phoneSheet = nil
                        preferences.pinPhoneRoute(picked)
                        select(picked)
                    }
                }
            }
            .onChange(of: routeTab, initial: true) { _, tab in
                if phoneSheet == nil { phoneTab = tab }
            }
        } else {
            // NavigationStack does not reliably forward a safe-area inset installed outside
            // it to pushed pages. Give the footer real layout space instead: every route,
            // scroll view and web canvas then receives the unobscured viewport height.
            VStack(spacing: 0) {
                workspace
                padMiniPlayer
            }
        }
    }

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    private var padMiniPlayer: some View {
        LinkMiniPlayer(playback: session.podcastPlayback, accent: session.accent)
            .frame(maxWidth: 520)
            .padding(.horizontal, 16)
            .padding(.vertical, session.podcastPlayback.target == nil ? 0 : 8)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            .animation(.easeInOut(duration: 0.22), value: session.podcastPlayback.target == nil)
    }

    @ViewBuilder private var phoneTabHost: some View {
        let tabs = TabView(selection: phoneTabSelection) {
            Tab(value: PhoneTab.home) { phoneTabContent } label: { phoneTabLabel("Home", image: "house") }
            ForEach(0..<3, id: \.self) { slot in
                Tab(value: PhoneTab.slot(slot)) { phoneTabContent } label: { phoneSlotLabel(slot) }
            }
            Tab(value: PhoneTab.more) { phoneTabContent } label: { phoneTabLabel("More", image: "ellipsis") }
        }
        .tint(session.accent.nodusReadable)

        if #available(iOS 26.1, *) {
            tabs
                .tabBarMinimizeBehavior(.never)
                .tabViewBottomAccessory(isEnabled: session.podcastPlayback.target != nil) {
                    // The accessory draws its own glass capsule; a second one inside it would
                    // show as an empty rim at both ends.
                    LinkMiniPlayer(playback: session.podcastPlayback, accent: session.accent, showsBackground: false)
                        .frame(maxWidth: .infinity)
                }
                .animation(.easeInOut(duration: 0.22), value: session.podcastPlayback.target == nil)
        } else {
            tabs
        }
    }

    /// Every tab shows the same transparent page: the real content is the shared workspace in
    /// front of it. What the page contributes is its bottom safe area — tab bar, player and
    /// home indicator — which becomes the workspace's bottom margin.
    private var phoneTabContent: some View {
        Color.clear
            .ignoresSafeArea(.keyboard)
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { phoneBarInset = $0 }
            .safeAreaInset(edge: .bottom, spacing: 0) { legacyPhoneMiniPlayer }
            .toolbar(session.isSurfaceFullscreen ? .hidden : .visible, for: .tabBar)
    }

    /// Before iOS 26.1 there is no tab-bar accessory: the same capsule floats above the bar.
    @ViewBuilder private var legacyPhoneMiniPlayer: some View {
        if #available(iOS 26.1, *) {
            EmptyView()
        } else if session.podcastPlayback.target != nil, !session.isSurfaceFullscreen {
            LinkMiniPlayer(playback: session.podcastPlayback, accent: session.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        }
    }

    /// Home and More are fixed; the three slots between them are the person's pinned sections,
    /// or a "Pin" placeholder that offers one. More and an empty slot open a section list
    /// rather than a page, so the setter acts on every tap, including a tap on the tab that
    /// is already selected.
    private var phoneTabSelection: Binding<PhoneTab> {
        Binding(get: { phoneTab }, set: { tapped in
            phoneTab = tapped
            switch tapped {
            case .home:
                select(.home)
            case .slot(let slot):
                if slot < preferences.phonePinnedRoutes.count { select(preferences.phonePinnedRoutes[slot]) }
                else { phoneSheet = .pin }
            case .more:
                phoneSheet = .more
            }
        })
    }

    /// The tab that represents the visible route.
    private var routeTab: PhoneTab {
        if route == .home { return .home }
        if let slot = preferences.phonePinnedRoutes.firstIndex(of: route) { return .slot(slot) }
        return .more
    }

    @ViewBuilder private func phoneSlotLabel(_ slot: Int) -> some View {
        if slot < preferences.phonePinnedRoutes.count,
           let item = AppPreferences.phonePinCandidates.first(where: { $0.route == preferences.phonePinnedRoutes[slot] }) {
            phoneTabLabel(item.tabLabel, image: item.systemImage)
        } else {
            phoneTabLabel("Pin", image: "pin")
        }
    }

    private func phoneTabLabel(_ title: LocalizedStringKey, image: String) -> some View {
        Label {
            Text(title)
        } icon: {
            // A UIKit template image, not `Image(systemName:)`: under the app's own dark/light
            // override the tab bar resolved SwiftUI symbols in the system appearance and drew
            // them almost black on dark glass. A template is tinted by the bar itself.
            if let icon = image == "telescope" ? NodusIcon.tabBarImage(named: "NodusTelescope") : NodusIcon.tabBarSymbol(image) {
                Image(uiImage: icon)
            } else {
                Image(systemName: image)
            }
        }
    }

    private var unpinnedPhoneSections: [NodusNavigationItem] {
        AppPreferences.phonePinCandidates.filter { !preferences.phonePinnedRoutes.contains($0.route) }
    }

    private var morePhoneSections: [NodusNavigationItem] {
        AppPreferences.phonePinCandidates.filter {
            !preferences.phonePinnedRoutes.contains($0.route) || [.library, .settings].contains($0.route)
        }
    }

    private func sidebar(collapsed: Bool) -> some View {
        DesktopSidebar(
            session: session,
            selection: route,
            collapsed: collapsed,
            onSelect: select,
            onSettings: { select(.settings) }
        )
    }

    private var sidebarResizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 12)
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let origin = sidebarResizeOrigin ?? preferences.sidebarWidth
                        if sidebarResizeOrigin == nil { sidebarResizeOrigin = origin }
                        preferences.sidebarWidth = SidebarPresentation.clampedWidth(origin + value.translation.width)
                    }
                    .onEnded { _ in sidebarResizeOrigin = nil }
            )
            .accessibilityElement()
            .accessibilityLabel("Resize sidebar")
            .accessibilityValue(Text(Int(preferences.sidebarWidth), format: .number))
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 16.0 : -16.0
                preferences.sidebarWidth = SidebarPresentation.clampedWidth(preferences.sidebarWidth + delta)
            }
    }

    /// Resident workspaces keep their navigation and editing state, but an invisible workspace
    /// must not be re-laid out for every intermediate sidebar width. Fixing inactive stacks to
    /// the current content area keeps hidden browser, report and database trees out of the 60 fps
    /// animation path without letting one of them widen the selected route beyond the device.
    /// They receive the current proposal again as soon as they become selected.
    private func routeContainer(frozenSize: CGSize) -> some View {
        ZStack {
            ForEach(residentRoutes) { resident in
                NavigationStack {
                    routeView(resident)
                        .modifier(CompanionCollectionAccess(session: session, route: resident))
                        .toolbar(.hidden, for: .navigationBar)
                }
                .environment(\.nodusResidentRouteActive, resident == route)
                .frame(
                    width: resident == route ? nil : frozenSize.width,
                    height: resident == route ? nil : frozenSize.height
                )
                .opacity(resident == route ? 1 : 0)
                .allowsHitTesting(resident == route)
                .accessibilityHidden(resident != route)
                .zIndex(resident == route ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { NodusBackdrop(accent: session.accent) }
        .clipped()
    }

    private func toggleNavigation(_ presentation: SidebarPresentation) {
        if presentation.isPersistent {
            preferences.sidebarCollapsed.toggle()
        } else {
            withAnimation(NodusMotion.standard) { showingDrawer.toggle() }
        }
    }

    private func select(_ selected: NodusRoute) {
        guard NodusLinkPolicy.routes.contains(selected) else { return }
        session.isSurfaceFullscreen = false
        guard selected != route else {
            showingDrawer = false
            return
        }

        let previous = route
        if !residentRoutes.contains(selected) { residentRoutes.append(selected) }
        route = selected
        UserDefaults.standard.set(selected.rawValue, forKey: "nodus.navigation.lastRoute.\(session.connection.id)")
        workspaceTabs.leave(previous.rawValue)
        if !retainsRouteState(previous) { residentRoutes.removeAll { $0 == previous } }
        chrome.setScrolled(false)
        showingDrawer = false
        Keyboard.dismiss()
    }

    /// Most Desktop sections are workspaces and keep their local state for the session. The
    /// map renderers are deliberately transient: revisiting a generated graph must not revive
    /// an expensive operation that the user left behind.
    private func retainsRouteState(_ route: NodusRoute) -> Bool {
        switch route {
        case .argument, .map, .tree, .graph, .dictionary, .deepResearch:
            return false
        default:
            return true
        }
    }

    @ViewBuilder
    private func routeView(_ route: NodusRoute) -> some View {
        switch route {
        case .home:
            LinkHomeView(session: session, onSelect: select)
        case .podcast:
            PodcastsView(session: session)
        case .search, .studySearch:
            SearchScreen(session: session)
        case .library:
            LibraryRouteView(session: session)
        case .argument:
            if session.connection.desktopPairingId != nil { SharedDesktopSurface(session: session, surface: .argument) }
            else { ArgumentMapView(session: session) }
        case .graph, .studyGraph:
            SharedDesktopSurface(session: session, surface: .graph)
        case .dictionary:
            DictionaryWorkspaceView(session: session)
        case .ideas:
            IdeasWorkspaceView(session: session, onOpenArgument: openArgument)
        case .authors:
            AuthorsWorkspaceView(session: session, onOpenIdea: openIdea, onOpenArgument: openArgument)
        case .deepResearch, .studyDeepResearch:
            DeepResearchRouteView(session: session)
        case .dbDeepResearch:
            if session.connection.desktopPairingId != nil { SharedDesktopSurface(session:session,surface:.databaseResearch) }
            else { ContentUnavailableView("Informes de datos",systemImage:"chart.bar.doc.horizontal",description:Text("Vincula Nodus para consultar los informes de tus bases de datos.")) }
        case .research:
            ResearchStateView(session: session)
        case .gaps:
            collection("gaps", route: .gaps)
        case .debate:
            SpecialListView(session: session, resource: .debates)
        case .hypothesis:
            HypothesisLabMobileView(session: session)
        case .reading:
            ReadingPathMobileView(session: session)
        case .immersion:
            if session.connection.desktopPairingId != nil {
                SharedDesktopSurface(session: session, surface: .immersion)
            } else { ImmersionLibraryView(session: session) }
        case .workspace, .notes:
            if session.connection.desktopPairingId != nil { SharedDesktopSurface(session: session, surface: .workspace) }
            else { PublishedWorkspaceView(session: session) }
        case .writing:
            WritingWorkshopMobileView(session: session)
        case .projects:
            ProjectsMobileView(session: session)
        case .persons:
            collection("persons")
        case .archive:
            SensitiveRecordsWorkspaceView(session: session, mode: .archive)
        case .prosopSearch:
            SensitiveRecordsWorkspaceView(session: session, mode: .prosopSearch)
        case .prosopPopulation:
            SensitiveRecordsWorkspaceView(session: session, mode: .prosopPopulation)
        case .prosopPersons:
            SensitiveRecordsWorkspaceView(session: session, mode: .prosopPersons)
        case .prosopSources:
            SensitiveRecordsWorkspaceView(session: session, mode: .prosopSources)
        case .prosopAnalysis:
            SensitiveRecordsWorkspaceView(session: session, mode: .prosopAnalysis)
        case .prosopNetworks:
            SensitiveRecordsWorkspaceView(session: session, mode: .prosopNetworks)
        case .testimonyInterviews:
            SensitiveRecordsWorkspaceView(session: session, mode: .testimonyInterviews)
        case .testimonyParticipants:
            SensitiveRecordsWorkspaceView(session: session, mode: .testimonyParticipants)
        case .testimonyContrasts:
            SensitiveRecordsWorkspaceView(session: session, mode: .testimonyContrasts)
        case .timeline:
            if displayedVaultType(for: session) == .worldbuilding { WorldTimelineView(session: session) }
            else { GenealogyTimelineView(session: session) }
        case .relations:
            if displayedVaultType(for: session) == .worldbuilding { WorldRelationsView(session: session) }
            else { collection("relationships") }
        case .map:
            if displayedVaultType(for: session) == .worldbuilding { WorldMapView(session: session) }
            else { GenealogyMapView(session: session) }
        case .tree:
            if displayedVaultType(for: session) == .worldbuilding { WorldHierarchyView(session: session) }
            else { FamilyTreeView(session: session) }
        case .encyclopedia, .characters, .places, .factions, .cultures, .dynasties,
             .rules, .conflicts, .arcs, .questions, .scenes:
            WorldEntityWorkspaceView(session: session, route: route)
        case .continuity:
            WorldContinuityView(session: session)
        case .manuscript:
            WorldManuscriptView(session: session)
        case .pages:
            PagesWorkspaceView(session: session)
        case .databases:
            DatabasesWorkspaceView(session: session)
        case .dbSearch:
            DatabasesWorkspaceView(session: session, mode: .search)
        case .dbAnalysis:
            DatabasesWorkspaceView(session: session, mode: .analysis)
        case .studyCourses:
            StudyTeachingWorkspaceView(session: session, mode: .courses)
        case .studyLibrary:
            StudyTeachingWorkspaceView(session: session, mode: .materials)
        case .studyIdeas:
            SharedDesktopSurface(session: session, surface: .studyIdeas)
        case .studySchedule:
            StudyTeachingWorkspaceView(session: session, mode: .schedule)
        case .studyCalendar:
            StudyTeachingWorkspaceView(session: session, mode: .calendar)
        case .studyRecordings:
            StudyTeachingWorkspaceView(session: session, mode: .recordings)
        case .studyQuestions:
            QuestionBankView(session: session)
        case .studyReview:
            FlashcardsView(session: session)
        case .teachingExams:
            StudyTeachingWorkspaceView(session: session, mode: .exams)
        case .teachingRubrics:
            StudyTeachingWorkspaceView(session: session, mode: .rubrics)
        case .teachingGroups:
            StudyTeachingWorkspaceView(session: session, mode: .groups)
        case .teachingGrades:
            StudyTeachingWorkspaceView(session: session, mode: .grades)
        case .teachingUnits:
            StudyTeachingWorkspaceView(session: session, mode: .units)
        case .researchChat, .worldChat, .studyChat, .dbChat:
            ChatTab(session: session)
        case .browser, .radar, .compass, .studyFocus, .toolkit:
            ComingSoonToolView(route: route, accent: session.accent)
        case .settings:
            SpaceSettingsView(session: session)
        }
    }

    private func openIdea(_ row: Row) {
        guard let id = row.string("global_id") else { return }
        workspaceTabs.open(WorkspaceTab(
            id: "ideas:\(id)", title: row.text("label") ?? id, systemImage: "lightbulb",
            kind: .idea, payload: .row(row)
        ), in: NodusRoute.ideas.rawValue)
        select(.ideas)
    }

    private func openArgument(_ seed: ArgumentSeed) {
        workspaceTabs.open(WorkspaceTab(
            id: "argument:\(seed.id)", title: seed.label, systemImage: "arrow.triangle.branch",
            kind: .argumentMap, payload: .argumentSeed(id: seed.id, label: seed.label)
        ), in: NodusRoute.argument.rawValue)
        select(.argument)
    }

    @ViewBuilder
    private func collection(_ path: String, route: NodusRoute? = nil) -> some View {
        if let descriptor = Collections[path] {
            CollectionListView(session: session, collection: descriptor, workspaceRoute: route)
        } else {
            ContentUnavailableView("Unavailable collection", systemImage: "tray")
        }
    }
}

/// A shell route is a destination, not a shortcut to a hub. This small loader gives Deep
/// Research the same direct route it has on Desktop while retaining the shared per-space store.
private struct DeepResearchRouteView: View {
    @Environment(AISettings.self) private var ai
    let session: SpaceSession
    @State private var store: LocalReportStore?

    var body: some View {
        Group {
            if let store {
                DeepResearchScreen(session: session, local: store)
                    .environment(ai)
            } else {
                ProgressView().tint(session.accent)
            }
        }
        .task {
            if store == nil { store = LocalReportStore.shared(for: session.connection.storageId) }
        }
    }
}

/// Opens the account-global Library only when the connected server advertises that contract.
///
/// Older servers have no `/api/v1/library/changes` route. Sending the sidebar there produced
/// an empty "No references" screen whose underlying error was `not_found`, even though the
/// same space's published works were available from Home. The fallback deliberately uses the
/// exact `works` collection Home uses, so both doors show the same references on those servers.
private struct LibraryRouteView: View {
    let session: SpaceSession
    @State private var supportsAccountSync: Bool?
    @State private var showDocuments = false
    @State private var liveLibraryIssue: String?

    var body: some View {
        Group {
            if session.isDemo {
                if NodusLinkPolicy.readOnly, let works = Collections.byPath["works"] {
                    CollectionListView(session: session, collection: works, workspaceRoute: .library)
                } else { AccountLibraryView(session: session) }
            } else if session.connection.desktopPairingId != nil {
                VStack(spacing: 0) {
                    Picker("Library", selection: $showDocuments) {
                        Text("Works").tag(false)
                        Text("Documents").tag(true)
                    }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
                    if let liveLibraryIssue { Text(liveLibraryIssue).font(.caption).foregroundStyle(.red).padding() }
                    if showDocuments { PublishedLibraryView(session: session) }
                    else if let works = Collections.byPath["works"] {
                        CollectionListView(session: session, collection: works, workspaceRoute: .library)
                    }
                }
            } else if let supportsAccountSync {
                switch LibraryRouteSource.resolve(
                    isDemo: false,
                    supportsAccountSync: supportsAccountSync
                ) {
                case .account:
                    if NodusLinkPolicy.readOnly, let works = Collections.byPath["works"] {
                        CollectionListView(session: session, collection: works, workspaceRoute: .library)
                    } else { AccountLibraryView(session: session) }
                case .publishedWorks:
                    if let works = Collections.byPath["works"] {
                        CollectionListView(session: session, collection: works, workspaceRoute: .library)
                    } else {
                        ContentUnavailableView("Library unavailable", systemImage: "books.vertical")
                    }
                }
            } else {
                ProgressView().tint(session.accent)
            }
        }
        .task {
            guard !session.isDemo, supportsAccountSync == nil else { return }
            if session.connection.desktopPairingId != nil {
                do {
                    showDocuments = try await session.client.publishedLibrarySummary(in: session.connection.spaceId).documents > 0
                    liveLibraryIssue = nil
                } catch { liveLibraryIssue = error.localizedDescription }
                supportsAccountSync = false
                return
            }
            supportsAccountSync = (try? await session.client.capabilities().supportsAccountLibrarySync) ?? false
        }
    }
}

enum LibraryRouteSource: Equatable {
    case account
    case publishedWorks

    static func resolve(isDemo: Bool, supportsAccountSync: Bool) -> Self {
        isDemo || supportsAccountSync ? .account : .publishedWorks
    }
}

private enum PhoneTab: Hashable {
    case home
    case slot(Int)
    case more
}

private enum PhoneSectionSheet: String, Identifiable {
    case more
    case pin
    var id: String { rawValue }
}

/// What More and an empty pinned slot open on iPhone. A native tab cannot be a menu, so the
/// list that used to be a pop-up menu is a short sheet with the same sections.
private struct PhoneSectionPicker: View {
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    let items: [NodusNavigationItem]
    let selection: NodusRoute?
    let accent: Color
    let onPick: (NodusRoute) -> Void

    var body: some View {
        NavigationStack {
            List(items) { nav in
                Button { onPick(nav.route) } label: {
                    Label {
                        HStack {
                            Text(nav.label).foregroundStyle(.primary)
                            Spacer()
                            if nav.route == selection { Image(systemName: "checkmark").foregroundStyle(accent.nodusReadable) }
                        }
                    } icon: {
                        NodusIcon(name: nav.systemImage, size: 16).foregroundStyle(accent.nodusReadable)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(nav.route == selection ? .isSelected : [])
                .accessibilityIdentifier("nodus-phone-section-\(nav.route.rawValue)")
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct SidebarPresentation: Equatable {
    let availableWidth: CGFloat
    let isUserCollapsed: Bool
    var isPhone = false
    var expandedWidth: CGFloat = NodusChromeMetrics.expandedSidebar

    static let minimumExpandedWidth = 176.0
    static let maximumExpandedWidth = 360.0

    static func clampedWidth(_ width: Double) -> Double {
        min(maximumExpandedWidth, max(minimumExpandedWidth, width))
    }

    var isPersistent: Bool { !isPhone && availableWidth >= 600 }
    var isCollapsed: Bool { availableWidth < 720 || isUserCollapsed }
    var sidebarWidth: CGFloat {
        isCollapsed
            ? NodusChromeMetrics.collapsedSidebar
            : CGFloat(Self.clampedWidth(Double(expandedWidth)))
    }

    /// A safe, stable proposal for a route that is resident but not visible.
    ///
    /// The width reserves the largest sidebar the user can choose, rather than today's width.
    /// It therefore remains constant through collapse and resize animations while never being
    /// large enough to make the route container overflow. The selected route has no fixed
    /// proposal and continues to use every point that is actually available.
    func residentRouteSize(in window: CGSize) -> CGSize {
        CGSize(
            width: max(0, window.width - (isPersistent ? Self.maximumExpandedWidth : 0)),
            height: max(0, window.height - NodusChromeMetrics.topBar)
        )
    }
}

/// Visual-QA only vault override, paired with `NODUS_START_ROUTE`. It changes no data source;
/// it lets simulator captures verify every adaptive sidebar without fabricating user records.
@MainActor
private func displayedVaultType(for session: SpaceSession) -> VaultType? {
#if DEBUG
    if let raw = ProcessInfo.processInfo.environment["NODUS_VAULT_TYPE_OVERRIDE"],
       let type = VaultType(rawValue: raw) {
        return type
    }
#endif
    return session.vaultType
}

private struct DesktopTopBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppModel.self) private var model
    @State private var showingVaults = false

    let session: SpaceSession
    let presentation: SidebarPresentation
    let pinRoute: NodusRoute?
    let queueCount: Int
    let onToggleNavigation: () -> Void
    let onSwitchSpace: () -> Void
    let onCommands: () -> Void
    let onAssistant: () -> Void
    let onQueue: () -> Void
    let onRefresh: () -> Void
    let onTheme: () -> Void
    let onSettings: () -> Void

    private var expandedActions: Bool { !presentation.isPhone && presentation.availableWidth >= 620 }
    private var chooserWidth: CGFloat {
        let leading = presentation.isPersistent ? presentation.sidebarWidth + 8 : 48
        let actions = expandedActions
            ? (NodusLinkPolicy.readOnly ? 4 : (queueCount > 0 ? 6 : 5))
            : (NodusLinkPolicy.readOnly ? 1 : 2)
        let download = !session.isDemo && pinRoute.flatMap(LinkDownloadSection.init(route:)) != nil
        let trailing = CGFloat(actions + (pinRoute == nil ? 0 : 1) + (download ? 1 : 0)) * 44 + 4
        let safeWidth = presentation.availableWidth - 2 * (max(leading, trailing) + 8)
        return max(44, min(presentation.availableWidth < 500 ? 156 : 260, safeWidth))
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Button(action: onToggleNavigation) {
                        Image(systemName: presentation.isPersistent && !presentation.isCollapsed ? "sidebar.leading" : "line.3.horizontal")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Navigation")
                    .accessibilityIdentifier("nodus-navigation-toggle")

                    if !presentation.isPhone && presentation.availableWidth >= 720 {
                        NodusMark(style: .accent(session.accent)).frame(width: 24, height: 24)
                        Text(verbatim: "Nodus")
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .frame(width: presentation.isPersistent ? presentation.sidebarWidth : nil, alignment: .leading)
                .padding(.leading, presentation.isPersistent ? 8 : 4)

                Spacer(minLength: 8)
                actionRail
            }

            Button { showingVaults.toggle() } label: {
                HStack(spacing: 7) {
                    Circle().fill(session.accent).frame(width: 7, height: 7)
                    Text(session.connection.spaceName).font(.caption.weight(.semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(session.accent.nodusReadable)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(session.accent.opacity(colorScheme == .dark ? 0.12 : 0.06), in: Capsule())
                .overlay(Capsule().stroke(session.accent.opacity(0.38), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: chooserWidth)
            .frame(height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Switch space")
            .accessibilityValue(Text(session.connection.spaceName))
            .accessibilityIdentifier("nodus-workspace-switch")
            .popover(isPresented: $showingVaults, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your vaults").font(.headline).padding(.horizontal, 12)
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(model.linkConnections) { connection in
                                Button {
                                    showingVaults = false
                                    guard connection.id != session.connection.id else { return }
                                    if connection.isDemo { Task { await model.openDemo() } }
                                    else { _ = model.open(connection) }
                                } label: {
                                    HStack(spacing: 10) {
                                        Circle().fill(connection.accent).frame(width: 8, height: 8)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(connection.spaceName).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                                            Text(connection.serverName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer(minLength: 4)
                                        if connection.id == session.connection.id { Image(systemName: "checkmark").foregroundStyle(connection.accent.nodusReadable) }
                                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(10).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityIdentifier("vault-popover-\(connection.vaultId ?? connection.spaceId)")
                            }
                        }
                    }.frame(maxHeight: 300)
                    Divider()
                    Button("Manage connections", systemImage: "link") { showingVaults = false; onSwitchSpace() }
                        .accessibilityIdentifier("nodus-manage-connections")
                        .frame(minHeight: 44).padding(.horizontal, 12)
                }.padding(12).frame(width: 300).presentationCompactAdaptation(.popover)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("vault-switcher-popover")
            }
        }
        .frame(height: NodusChromeMetrics.topBar)
        // The desktop chrome has a fixed 44-point row. Keep its labels readable inside that
        // row while the actual page content continues to honour the full accessibility scale.
        .dynamicTypeSize(.small ... .large)
        .background(colorScheme == .dark ? Color(hex: "#111113") : Color.white)
        .overlay(alignment: .bottom) { Divider() }
        .zIndex(20)
    }

    private var actionRail: some View {
        HStack(spacing: 0) {
            if !session.isDemo, let route = pinRoute, let section = LinkDownloadSection(route: route) {
                LinkSectionDownloadButton(section: section)
            }
            if let pinRoute { LinkSectionPin(route: pinRoute, accent: session.accent) }
            if expandedActions {
                topButton("command", label: "Commands", action: onCommands)
                if !NodusLinkPolicy.readOnly { topButton("sparkles", label: "Nodi", action: onAssistant) }
                topButton("arrow.clockwise", label: "Refresh", action: onRefresh)
                if !NodusLinkPolicy.readOnly && queueCount > 0 { topButton("tray.and.arrow.up", label: "Send queue", badge: queueCount, action: onQueue) }
                topButton(colorScheme == .dark ? "sun.max" : "moon", label: "Theme", action: onTheme)
                topButton("gearshape", label: "Settings", action: onSettings)
            } else {
                if !NodusLinkPolicy.readOnly { topButton("sparkles", label: "Nodi", action: onAssistant) }
                Menu {
                    Button(action: onCommands) { NodusMenuLabel(title: "Commands", image: "command") }
                    Button(action: onRefresh) { NodusMenuLabel(title: "Refresh", image: "arrow.clockwise") }
                    if !NodusLinkPolicy.readOnly && queueCount > 0 {
                        Button(action: onQueue) { NodusMenuLabel(title: "Send queue", image: "tray.and.arrow.up") }
                    }
                    Button(action: onTheme) { NodusMenuLabel(title: "Theme", image: colorScheme == .dark ? "sun.max" : "moon") }
                    Button(action: onSettings) { NodusMenuLabel(title: "Settings", image: "gearshape") }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .accessibilityLabel("More actions").accessibilityIdentifier("nodus-top-more")
            }
        }
        .padding(.trailing, 4)
    }

    private func topButton(
        _ image: String,
        label: LocalizedStringKey,
        badge: Int? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge, format: .number)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(session.accent, in: Capsule())
                            .offset(x: 1, y: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
        .accessibilityValue(badge.map(String.init) ?? "")
        .accessibilityIdentifier("nodus-top-\(image)")
    }
}

private struct DesktopSidebar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppPreferences.self) private var preferences
    @State private var collapsedGroups: Set<NodusNavigationGroup> = []

    let session: SpaceSession
    let selection: NodusRoute
    let collapsed: Bool
    let onSelect: (NodusRoute) -> Void
    let onSettings: () -> Void

    private var visible: [NodusNavigationItem] {
        NodusNavigationContract.visibleItems(
            for: displayedVaultType(for: session),
            order: preferences.sidebarOrder,
            hidden: preferences.sidebarCustomized ? preferences.sidebarHidden : nil
        )
    }

    private var groups: [(NodusNavigationGroup, [NodusNavigationItem])] {
        NodusNavigationContract.groupedItems(
            for: displayedVaultType(for: session),
            order: preferences.sidebarOrder,
            hidden: preferences.sidebarCustomized ? preferences.sidebarHidden : nil
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if let home = visible.first(where: { $0.route == .home }) { item(home) }
                    if let library = visible.first(where: { $0.route == .library }) { item(library) }
                    ForEach(groups, id: \.0.id) { group, items in
                        if !collapsed {
                            Button {
                                if collapsedGroups.contains(group) { collapsedGroups.remove(group) }
                                else { collapsedGroups.insert(group) }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8, weight: .semibold))
                                        .rotationEffect(.degrees(collapsedGroups.contains(group) ? 0 : 90))
                                    Text(group.title)
                                        .font(.caption2.weight(.bold)).tracking(0.7)
                                        .textCase(.uppercase)
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(Color.primary.opacity(0.7))
                                .padding(.top, 14).padding(.horizontal, 10).padding(.bottom, 3)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("nodus-nav-group-\(group.rawValue)")
                        }
                        if collapsed || !collapsedGroups.contains(group) {
                            ForEach(items) { item($0) }
                        }
                    }
                }
                .padding(8)
            }

            if let settings = visible.first(where: { $0.route == .settings }) {
                item(settings).padding(8)
            }
        }
        .background(colorScheme == .dark ? Color(hex: "#111113") : Color(hex: "#f7f7f8"))
        .overlay(alignment: .trailing) {
            // Divider has a horizontal default in an overlay, irrespective of its alignment.
            Rectangle().fill(Color.secondary.opacity(0.22)).frame(width: 1)
                .accessibilityHidden(true)
        }
    }

    private func item(_ nav: NodusNavigationItem) -> some View {
        Button {
            nav.route == .settings ? onSettings() : onSelect(nav.route)
        } label: {
            HStack(spacing: collapsed ? 0 : 6) {
                NodusIcon(
                    name: nav.systemImage,
                    size: 14,
                    weight: selection == nav.route ? .semibold : .regular
                )
                    .frame(width: collapsed ? 44 : 20, height: 44, alignment: .center)
                if !collapsed {
                    Text(nav.label)
                        .font(.footnote.weight(selection == nav.route ? .semibold : .regular))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(selection == nav.route ? session.accent.nodusReadable : Color.primary.opacity(0.78))
            .padding(.horizontal, collapsed ? 0 : 4)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: collapsed ? .center : .leading)
            .background(selection == nav.route ? session.accent.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .leading) {
                if selection == nav.route { Capsule().fill(session.accent).frame(width: 2, height: 18).offset(x: -1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(nav.labelKey)
        .accessibilityLabel(nav.label)
        .accessibilityIdentifier("nodus-nav-\(nav.route.rawValue)")
        .accessibilityAddTraits(selection == nav.route ? .isSelected : [])
    }
}

private struct CommandPalette: View {
    @Environment(\.dismiss) private var dismiss
    let session: SpaceSession
    let selection: NodusRoute
    let onSelect: (NodusRoute) -> Void
    @State private var query = ""

    private var items: [NodusNavigationItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        return NodusNavigationContract.scopedItems(for: displayedVaultType(for: session)).filter {
            needle.isEmpty || $0.labelKey.localizedLowercase.contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            List(items) { nav in
                Button { onSelect(nav.route) } label: {
                    Label {
                        HStack {
                            Text(nav.label)
                            Spacer()
                            if nav.route == selection { Image(systemName: "checkmark").foregroundStyle(session.accent) }
                        }
                    } icon: {
                        NodusIcon(name: nav.systemImage, size: 16).foregroundStyle(session.accent)
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $query, prompt: "Go to a section")
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

/// Observe a system edge pan without placing an invisible hit-test view above the
/// workspace. A stationary tap at the left of an HTML input must reach WebKit.
private struct ScreenEdgeNavigationInstaller: UIViewRepresentable {
    let enabled: Bool
    let open: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView {
        let view = WindowWatcher()
        view.isUserInteractionEnabled = false
        view.onWindow = { [coordinator = context.coordinator] window in coordinator.install(in: window) }
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.open = open
        context.coordinator.enabled = enabled
        context.coordinator.install(in: view.window)
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.remove() }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var window: UIWindow?
        var recognizer: UIPanGestureRecognizer?
        var enabled = false { didSet { recognizer?.isEnabled = enabled } }
        var open: (() -> Void)?
        func install(in target: UIWindow?) {
            guard let target, target !== window else { return }
            remove(); window = target
            let edge = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            edge.maximumNumberOfTouches = 1
            edge.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            edge.cancelsTouchesInView = false
            edge.delaysTouchesBegan = false; edge.delaysTouchesEnded = false
            edge.delegate = self; edge.isEnabled = enabled
            target.addGestureRecognizer(edge); recognizer = edge
        }
        func remove() { if let recognizer { window?.removeGestureRecognizer(recognizer) }; recognizer = nil; window = nil }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: window)
            if gesture.state == .changed || gesture.state == .ended, translation.x >= 64, translation.x > abs(translation.y) * 1.25 { open?() }
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let window else { return false }
            let translation = pan.translation(in: window)
            let startX = pan.location(in: window).x - translation.x
            // Observe only a rightward stroke that started at the screen edge. Stationary
            // taps, text selection and vertical scrolling keep their normal recognizers.
            return startX <= 24 && translation.x > 0 && translation.x > abs(translation.y) * 1.25
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
    private final class WindowWatcher: UIView {
        var onWindow: ((UIWindow?) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); onWindow?(window) }
    }
}
