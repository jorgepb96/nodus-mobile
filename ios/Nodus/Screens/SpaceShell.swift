import NodusAI
import NodusKit
import NodusUI
import SwiftUI

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

/// One adaptive shell for iPhone and iPad. Width changes the sidebar presentation, never the
/// hierarchy or the destination set.
struct SpaceShell: View {
    @Environment(AppModel.self) private var model
    @Environment(AppPreferences.self) private var preferences
    @Environment(OutboxTrayModel.self) private var tray
    @Environment(\.colorScheme) private var colorScheme

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

    init(session: SpaceSession) {
        self.session = session
        var initial: NodusRoute = .home
#if DEBUG
        // Deterministic visual-QA entry point. `simctl` can set this without persisting a
        // different navigation state for real users, which lets every phase capture the exact
        // same native screen on iPhone and iPad.
        if let raw = ProcessInfo.processInfo.environment["NODUS_START_ROUTE"],
           let requested = NodusRoute(rawValue: raw) {
            initial = requested
        }
#endif
        _route = State(initialValue: initial)
        _residentRoutes = State(initialValue: [initial])
    }

    var body: some View {
        GeometryReader { proxy in
            let presentation = SidebarPresentation(
                availableWidth: proxy.size.width,
                isUserCollapsed: preferences.sidebarCollapsed,
                expandedWidth: CGFloat(preferences.sidebarWidth)
            )
            // Resident routes sit below the top bar and, on a regular-width device, beside
            // the persistent sidebar. Freezing an inactive route to the whole window made
            // that hidden route dictate the ZStack's minimum size: one top bar too tall and
            // one sidebar too wide. The visible workspace was consequently clipped at the
            // bottom and trailing edge on iPad in both orientations.
            let residentRouteSize = presentation.residentRouteSize(in: proxy.size)

            ZStack(alignment: .leading) {
                VStack(spacing: 0) {
                    DesktopTopBar(
                        session: session,
                        presentation: presentation,
                        queueCount: tray.outbox.pending,
                        onToggleNavigation: { toggleNavigation(presentation) },
                        onSwitchSpace: { model.closeSession() },
                        onCommands: { showingCommands = true },
                        onAssistant: { showingAssistant = true },
                        onQueue: { tray.open() },
                        onRefresh: { Task { await session.refreshPublishedContent() } },
                        onTheme: { preferences.toggleInterfaceStyle(current: colorScheme) },
                        onSettings: { select(.settings) }
                    )

                    HStack(spacing: 0) {
                        if presentation.isPersistent {
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

                if !presentation.isPersistent, showingDrawer {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(NodusMotion.standard) { showingDrawer = false } }
                        .transition(.opacity)

                    sidebar(collapsed: false)
                        .frame(width: min(320, proxy.size.width * 0.86))
                        .shadow(color: .black.opacity(0.28), radius: 24, x: 8)
                        .transition(.move(edge: .leading))
                }

                // WKWebView and other UIKit-backed views can consume a drag before a SwiftUI
                // ancestor sees it. Keep a narrow, dedicated edge band above route content so
                // the standard drawer gesture works consistently without affecting horizontal
                // scrolling elsewhere on the screen.
                if !presentation.isPersistent, !showingDrawer {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 52).allowsHitTesting(false)
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(edgeOpenGesture(presentation: presentation, width: proxy.size.width))
                    }
                    .frame(width: 24)
                    .accessibilityHidden(true)
                    .zIndex(20)
                }
            }
            .animation(NodusMotion.standard, value: showingDrawer)
            .animation(NodusMotion.standard, value: presentation.sidebarWidth)
            .simultaneousGesture(edgeOpenGesture(presentation: presentation, width: proxy.size.width))
        }
        .environment(chrome)
        .environment(workspaceTabs)
        .environment(\.nodusHasTabBar, false)
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Nodus")
                .accessibilityIdentifier("nodus-space-shell")
                .allowsHitTesting(false)
        }
        .task {
            await session.load()
            await session.loadMirror()
            await session.probeEmbedding()
        }
        .task { await session.monitorPublishedContent() }
        .nodusSheet(isPresented: $showingAssistant) {
            NavigationStack { ChatTab(session: session) }.nodusModalClose(accent: session.accent)
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
    /// must not be re-laid out for every intermediate sidebar width. Fixing only the inactive
    /// stacks to the window size leaves the selected route adaptive while taking hidden browser,
    /// report and database trees out of the 60 fps animation path. They receive the current
    /// proposal again as soon as they become selected.
    private func routeContainer(frozenSize: CGSize) -> some View {
        ZStack {
            ForEach(residentRoutes) { resident in
                NavigationStack {
                    routeView(resident).toolbar(.hidden, for: .navigationBar)
                }
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
        guard selected != route else {
            showingDrawer = false
            return
        }

        let previous = route
        if !residentRoutes.contains(selected) { residentRoutes.append(selected) }
        route = selected
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
        case .argument, .map, .tree:
            return false
        default:
            return true
        }
    }

    @ViewBuilder
    private func routeView(_ route: NodusRoute) -> some View {
        switch route {
        case .home:
            HomeView(session: session, openResearch: { select(.deepResearch) })
        case .search, .studySearch:
            SearchScreen(session: session)
        case .library:
            LibraryRouteView(session: session)
        case .argument:
            ArgumentMapView(session: session)
        case .ideas:
            IdeasWorkspaceView(session: session, onOpenArgument: openArgument)
        case .authors:
            AuthorsWorkspaceView(session: session, onOpenIdea: openIdea, onOpenArgument: openArgument)
        case .deepResearch, .studyDeepResearch:
            DeepResearchRouteView(session: session)
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
            ImmersionLibraryView(session: session)
        case .workspace, .notes:
            PublishedWorkspaceView(session: session)
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
            else { collection("events") }
        case .relations:
            if displayedVaultType(for: session) == .worldbuilding { WorldRelationsView(session: session) }
            else { collection("relationships") }
        case .map:
            if displayedVaultType(for: session) == .worldbuilding { WorldMapView(session: session) }
            else { collection("places") }
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
            collection("ideas", route: .studyIdeas)
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
        case .worldChat, .studyChat, .dbChat:
            ChatTab(session: session)
        case .browser, .radar, .toolkit:
            PlatformToolsWorkspaceView(session: session, route: route)
        case .settings:
            SpaceSettingsView(session: session)
        }
    }

    /// A drawer gesture begins only in the system-like edge band and commits only after a
    /// decisive horizontal movement. Using a simultaneous gesture preserves carousels,
    /// browser history swipes and horizontally scrolling workspaces away from the edge.
    private func edgeOpenGesture(presentation: SidebarPresentation, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onEnded { value in
                guard !presentation.isPersistent, !showingDrawer else { return }
                let beganAtEdge = value.startLocation.x <= min(28, width * 0.08)
                let horizontal = value.translation.width >= 64
                    && abs(value.translation.width) > abs(value.translation.height) * 1.25
                guard beganAtEdge, horizontal else { return }
                withAnimation(NodusMotion.standard) { showingDrawer = true }
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
            if store == nil { store = LocalReportStore.shared(for: session.connection.spaceId) }
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

    var body: some View {
        Group {
            if session.isDemo {
                AccountLibraryView(session: session)
            } else if let supportsAccountSync {
                switch LibraryRouteSource.resolve(
                    isDemo: false,
                    supportsAccountSync: supportsAccountSync
                ) {
                case .account:
                    AccountLibraryView(session: session)
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

struct SidebarPresentation: Equatable {
    let availableWidth: CGFloat
    let isUserCollapsed: Bool
    var expandedWidth: CGFloat = NodusChromeMetrics.expandedSidebar

    static let minimumExpandedWidth = 176.0
    static let maximumExpandedWidth = 360.0

    static func clampedWidth(_ width: Double) -> Double {
        min(maximumExpandedWidth, max(minimumExpandedWidth, width))
    }

    var isPersistent: Bool { availableWidth >= 600 }
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

    let session: SpaceSession
    let presentation: SidebarPresentation
    let queueCount: Int
    let onToggleNavigation: () -> Void
    let onSwitchSpace: () -> Void
    let onCommands: () -> Void
    let onAssistant: () -> Void
    let onQueue: () -> Void
    let onRefresh: () -> Void
    let onTheme: () -> Void
    let onSettings: () -> Void

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

                    if presentation.availableWidth >= 720 {
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

            Button(action: onSwitchSpace) {
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
            .frame(maxWidth: presentation.availableWidth < 500 ? 156 : 260)
            .accessibilityLabel("Switch space")
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
            if presentation.availableWidth >= 620 {
                topButton("command", label: "Commands", action: onCommands)
                topButton("sparkles", label: "Nodi", action: onAssistant)
                topButton("arrow.clockwise", label: "Refresh", action: onRefresh)
                if queueCount > 0 { topButton("tray.and.arrow.up", label: "Send queue", badge: queueCount, action: onQueue) }
                topButton(colorScheme == .dark ? "sun.max" : "moon", label: "Theme", action: onTheme)
                topButton("gearshape", label: "Settings", action: onSettings)
            } else {
                topButton("sparkles", label: "Nodi", action: onAssistant)
                Menu {
                    Button("Commands", systemImage: "command", action: onCommands)
                    Button("Refresh", systemImage: "arrow.clockwise", action: onRefresh)
                    if queueCount > 0 { Button("Send queue", systemImage: "tray.and.arrow.up", action: onQueue) }
                    Button("Theme", systemImage: colorScheme == .dark ? "sun.max" : "moon", action: onTheme)
                    Button("Settings", systemImage: "gearshape", action: onSettings)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .accessibilityLabel("More actions")
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
        .accessibilityLabel(label)
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
                                        .font(.system(size: 9, weight: .bold)).tracking(0.7)
                                        .textCase(.uppercase)
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(.tertiary)
                                .padding(.top, 14).padding(.horizontal, 10).padding(.bottom, 3)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("nodus-nav-group-\(group.rawValue)")
                        } else {
                            Divider().padding(.vertical, 6).padding(.horizontal, 12)
                        }
                        if collapsed || !collapsedGroups.contains(group) {
                            ForEach(items) { item($0) }
                        }
                    }
                }
                .padding(8)
            }

            Divider()
            if let settings = visible.first(where: { $0.route == .settings }) {
                item(settings).padding(8)
            }
        }
        .background(colorScheme == .dark ? Color(hex: "#111113") : Color(hex: "#f7f7f8"))
        .overlay(alignment: .trailing) { Divider() }
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
                    .frame(width: 44, height: 44, alignment: .center)
                if !collapsed {
                    Text(nav.label)
                        .font(.system(size: 12, weight: selection == nav.route ? .semibold : .regular))
                        .lineLimit(1)
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
