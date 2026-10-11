import NodusKit
import SwiftUI

extension Notification.Name { static let nodusMobileNavigate = Notification.Name("nodus.mobile.navigate") }

/// The route vocabulary of the current desktop app.
///
/// Keeping every Desktop route here makes drift measurable. Visibility is a presentation
/// decision expressed by `NodusRouteSupport`; every route remains executable from a deep link.
/// Adding a route on Desktop without classifying it here fails the parity audit.
enum NodusRoute: String, CaseIterable, Codable, Hashable, Identifiable {
    case home, search, testimonyInterviews, testimonyParticipants, testimonyContrasts
    case library, graph, studyGraph, argument, ideas, dictionary, authors, persons
    case prosopSearch, prosopPopulation, prosopPersons, prosopSources, prosopAnalysis, prosopNetworks
    case encyclopedia, continuity, conflicts, arcs, rules, questions, worldChat, manuscript
    case characters, places, factions, cultures, dynasties, scenes, timeline, tree, relations, map, archive
    case pages, databases, dbSearch, dbAnalysis, dbChat, dbDeepResearch
    case studyCourses, studySchedule, studyCalendar, studySearch, studyLibrary, studyRecordings
    case studyChat, studyIdeas, studyQuestions, studyReview, studyDeepResearch
    case teachingGroups, teachingGrades, teachingExams, teachingRubrics, teachingUnits
    case immersion, gaps, debate, research, hypothesis, reading, writing, deepResearch, projects, notes, workspace
    case researchChat, browser, radar, compass, studyFocus, toolkit, settings

    var id: String { rawValue }
}

enum NodusNavigationGroup: String, CaseIterable, Identifiable, Hashable {
    case explore, analyze, create, tools

    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .explore: return "Explore"
        case .analyze: return "Analyze"
        case .create: return "Write"
        case .tools: return "Tools"
        }
    }
}

enum NodusRouteSupport: Hashable {
    /// A purpose-built SwiftUI surface exists.
    case native
    /// The published collection can be shown with the shared catalogue/dossier UI.
    case collection(path: String)
    /// Published in the snapshot rather than through a REST collection. Optional field values
    /// reproduce the typed facet used by Desktop for shared tables such as `world_groups`.
    case mirror(table: String, field: String?, values: [String])
    /// Routable from a dossier or dashboard, but deliberately not a sidebar destination.
    case nested

    var isVisible: Bool {
        switch self {
        case .native, .collection, .mirror: return true
        case .nested: return false
        }
    }
}

struct NodusNavigationItem: Identifiable {
    let route: NodusRoute
    let label: LocalizedStringKey
    let labelKey: String
    let systemImage: String
    let group: NodusNavigationGroup?
    let vaultTypes: Set<VaultType>
    let support: NodusRouteSupport

    var id: NodusRoute { route }

    init(
        _ route: NodusRoute,
        _ label: String,
        _ systemImage: String,
        group: NodusNavigationGroup? = nil,
        vaultTypes: Set<VaultType> = Set(VaultType.allCases),
        support: NodusRouteSupport
    ) {
        self.route = route
        self.label = LocalizedStringKey(label)
        self.labelKey = label
        self.systemImage = systemImage
        self.group = group
        self.vaultTypes = vaultTypes
        self.support = support
    }
}

@MainActor
enum NodusNavigationContract {
    private static let academic: Set<VaultType> = [.academic]
    private static let records: Set<VaultType> = [.genealogy, .primarySources]
    private static let prosopography: Set<VaultType> = [.prosopography]
    private static let testimony: Set<VaultType> = [.testimonios]
    private static let world: Set<VaultType> = [.worldbuilding]
    private static let study: Set<VaultType> = [.estudio]
    private static let teaching: Set<VaultType> = [.docencia]
    private static let databases: Set<VaultType> = [.databases]

    static let items: [NodusNavigationItem] = [
        .init(.home, "Home", "house", support: .native),
        // Library is account-global on Desktop and is pinned immediately below Home,
        // independently of the active vault type.
        .init(.library, "Library", "book.closed", group: .explore, support: .collection(path: "works")),
        .init(.search, "Search", "magnifyingglass", group: .explore, support: .native),
        .init(.graph, "Graph", "point.3.connected.trianglepath.dotted", group: .explore, support: .native),
        .init(.ideas, "Ideas", "lightbulb", group: .explore, support: .collection(path: "ideas")),
        .init(.authors, "Authors", "graduationcap", group: .explore, support: .collection(path: "authors")),
        .init(.argument, "Argument map", "square.3.layers.3d", group: .explore, support: .native),
        .init(.research, "State of the art", "safari", group: .analyze, support: .native),
        .init(.immersion, "Immersion", "scope", group: .analyze, support: .native),
        .init(.deepResearch, "Deep Research", "telescope", group: .analyze, support: .native),
        .init(.dictionary, "Dictionary", "character.book.closed", group: .analyze, support: .native),
        .init(.researchChat, "Research chat", "bubble.left.and.text.bubble.right", group: .analyze, support: .native),
        .init(.hypothesis, "Hypothesis", "flask", group: .analyze, support: .native),
        .init(.reading, "Reading path", "point.topleft.down.to.point.bottomright.curvepath", group: .analyze, support: .native),
        .init(.gaps, "Research gaps", "circle.dashed", support: .nested),
        .init(.debate, "Debates", "bubble.left.and.bubble.right", support: .nested),
        .init(.workspace, "Workspace", "note.text", group: .create, vaultTypes: academic, support: .native),
        .init(.writing, "Writing", "square.and.pencil", group: .create, vaultTypes: Set(VaultType.allCases).subtracting(academic), support: .native),
        .init(.projects, "Projects", "folder", group: .create, vaultTypes: Set(VaultType.allCases).subtracting(academic), support: .native),

        .init(.persons, "People", "person.2", group: .explore, vaultTypes: records, support: .collection(path: "persons")),
        .init(.timeline, "Timeline", "clock", group: .explore, vaultTypes: records.union(world), support: .native),
        .init(.tree, "Family tree", "arrow.triangle.branch", group: .explore, vaultTypes: records.union(world), support: .native),
        .init(.relations, "Social relations", "link", group: .explore, vaultTypes: records.union(world), support: .native),
        .init(.map, "Map", "map", group: .explore, vaultTypes: records.union(world), support: .native),
        .init(.archive, "Archive", "archivebox", group: .explore, vaultTypes: records, support: .native),

        .init(.prosopSearch, "Search", "magnifyingglass", group: .explore, vaultTypes: prosopography, support: .native),
        .init(.prosopPopulation, "Population", "person.3", group: .explore, vaultTypes: prosopography, support: .native),
        .init(.prosopPersons, "People", "person", group: .explore, vaultTypes: prosopography, support: .native),
        .init(.prosopSources, "Sources", "archivebox", group: .explore, vaultTypes: prosopography, support: .native),
        .init(.prosopAnalysis, "Analysis", "chart.bar", group: .analyze, vaultTypes: prosopography, support: .native),
        .init(.prosopNetworks, "Networks", "point.3.connected.trianglepath.dotted", group: .analyze, vaultTypes: prosopography, support: .native),

        .init(.testimonyInterviews, "Interviews", "mic", group: .explore, vaultTypes: testimony, support: .native),
        .init(.testimonyParticipants, "Participants", "person.2", group: .explore, vaultTypes: testimony, support: .native),
        .init(.testimonyContrasts, "Contrasts", "scale.3d", group: .analyze, vaultTypes: testimony, support: .native),

        .init(.encyclopedia, "Encyclopedia", "books.vertical", group: .explore, vaultTypes: world, support: .native),
        .init(.characters, "Characters", "person.2", group: .explore, vaultTypes: world, support: .native),
        .init(.places, "Places", "map", group: .explore, vaultTypes: world, support: .native),
        .init(.factions, "Factions", "point.3.connected.trianglepath.dotted", group: .explore, vaultTypes: world, support: .native),
        .init(.cultures, "Cultures", "character.book.closed", group: .explore, vaultTypes: world, support: .native),
        .init(.dynasties, "Dynasties", "shield", group: .explore, vaultTypes: world, support: .native),
        .init(.rules, "World rules", "lock", group: .analyze, vaultTypes: world, support: .native),
        .init(.conflicts, "Conflicts", "scale.3d", group: .analyze, vaultTypes: world, support: .native),
        .init(.arcs, "Story arcs", "point.topleft.down.to.point.bottomright.curvepath", group: .analyze, vaultTypes: world, support: .native),
        .init(.continuity, "Continuity", "checkmark.seal", group: .analyze, vaultTypes: world, support: .native),
        .init(.questions, "Open questions", "questionmark.circle", group: .analyze, vaultTypes: world, support: .native),
        .init(.worldChat, "World chat", "bubble.left.and.text.bubble.right", group: .analyze, vaultTypes: world, support: .native),
        .init(.scenes, "Scenes", "photo", group: .create, vaultTypes: world, support: .native),
        .init(.manuscript, "Manuscript", "square.and.pencil", group: .create, vaultTypes: world, support: .native),

        .init(.pages, "Pages", "note.text", group: .explore, vaultTypes: databases, support: .native),
        .init(.databases, "Databases", "tablecells", group: .explore, vaultTypes: databases, support: .native),
        .init(.dbSearch, "Search", "magnifyingglass", group: .explore, vaultTypes: databases, support: .native),
        .init(.dbAnalysis, "Analysis", "chart.bar", group: .analyze, vaultTypes: databases, support: .native),
        .init(.dbChat, "Data chat", "bubble.left.and.text.bubble.right", group: .analyze, vaultTypes: databases, support: .native),
        .init(.dbDeepResearch, "Deep Research", "telescope", group: .analyze, vaultTypes: databases, support: .native),

        .init(.studyCourses, "Courses and subjects", "graduationcap", group: .explore, vaultTypes: study.union(teaching), support: .native),
        .init(.studySchedule, "Schedule", "clock", group: .explore, vaultTypes: study.union(teaching), support: .native),
        .init(.studyCalendar, "Calendar", "calendar", group: .explore, vaultTypes: study.union(teaching), support: .native),
        .init(.studySearch, "Study search", "magnifyingglass", group: .explore, vaultTypes: study.union(teaching), support: .native),
        .init(.studyLibrary, "Study materials", "books.vertical", group: .explore, vaultTypes: study.union(teaching), support: .native),
        .init(.studyRecordings, "Recordings", "mic", group: .explore, vaultTypes: study.union(teaching), support: .native),
        .init(.studyChat, "Study chat", "bubble.left.and.text.bubble.right", group: .analyze, vaultTypes: study.union(teaching), support: .native),
        .init(.studyIdeas, "Study ideas", "lightbulb", group: .analyze, vaultTypes: study.union(teaching), support: .collection(path: "ideas")),
        .init(.studyGraph, "Graph", "point.3.connected.trianglepath.dotted", group: .analyze, vaultTypes: study.union(teaching), support: .native),
        .init(.studyQuestions, "Question bank", "questionmark.circle", group: .analyze, vaultTypes: study.union(teaching), support: .native),
        .init(.studyReview, "Review", "rectangle.on.rectangle.angled", group: .analyze, vaultTypes: study.union(teaching), support: .native),
        .init(.studyDeepResearch, "Study research", "telescope", group: .analyze, vaultTypes: study.union(teaching), support: .native),
        .init(.teachingGroups, "Groups", "person.3", group: .explore, vaultTypes: teaching, support: .native),
        .init(.teachingGrades, "Grades", "chart.bar", group: .analyze, vaultTypes: teaching, support: .native),
        .init(.teachingExams, "Exams", "note.text", group: .analyze, vaultTypes: teaching, support: .native),
        .init(.teachingRubrics, "Rubrics", "tablecells", group: .analyze, vaultTypes: teaching, support: .native),
        .init(.teachingUnits, "Unit design", "safari", group: .create, vaultTypes: teaching, support: .native),

        .init(.notes, "Notes", "note.text", group: .create, vaultTypes: Set(VaultType.allCases).subtracting(academic), support: .native),
        .init(.browser, "Nodus Browser", "globe", group: .tools, support: .native),
        .init(.radar, "Nodus Radar", "dot.radiowaves.left.and.right", group: .tools, support: .native),
        .init(.compass, "Nodus Compass", "safari", group: .tools, support: .native),
        .init(.studyFocus, "Nodus Focus", "scope", group: .tools, support: .native),
        .init(.toolkit, "Nodus Tools", "wrench.and.screwdriver", group: .tools, support: .native),
        .init(.settings, "Settings", "gearshape", support: .native),
    ]

    /// Desktop presets for the two generic navigation modes. Dedicated workspaces use
    /// closed allow-lists below, so no inherited academic row can leak into their sidebar.
    static func defaultHiddenRoutes(for vaultType: VaultType?) -> Set<String> {
        switch vaultType ?? .academic {
        case .academic: ["hypothesis", "reading"]
        case .genealogy: [
            "argument", "debate", "ideas", "authors", "immersion",
            "hypothesis", "reading", "research", "gaps", "writing", "projects",
        ]
        default: []
        }
    }

    /// Mirrors `DEDICATED_VAULT_NAV_IDS` in Desktop. Home, the account Library and
    /// Settings are pinned by the common shell and therefore are added here uniformly.
    static func sidebarAllowedRoutes(for vaultType: VaultType?) -> Set<NodusRoute>? {
        let dedicated: Set<NodusRoute>?
        switch vaultType ?? .academic {
        case .prosopography:
            dedicated = [
                .prosopSearch, .prosopPopulation, .prosopPersons, .prosopSources,
                .prosopAnalysis, .prosopNetworks, .notes, .browser, .radar, .toolkit,
            ]
        case .primarySources:
            dedicated = [.search, .archive, .persons, .timeline, .map, .relations, .notes, .browser, .radar, .toolkit]
        case .estudio:
            dedicated = [
                .studyCourses, .studySchedule, .studyCalendar, .studySearch, .studyLibrary,
                .studyRecordings, .studyChat, .studyIdeas, .studyGraph, .studyQuestions,
                .studyReview, .studyDeepResearch, .browser, .radar, .toolkit,
            ]
        case .docencia:
            dedicated = [
                .studyCourses, .teachingGroups, .studySchedule, .studyCalendar, .studyLibrary,
                .studyRecordings, .studyChat, .studyIdeas, .studyGraph, .studyDeepResearch, .studyQuestions,
                .teachingRubrics, .teachingExams, .teachingGrades, .teachingUnits,
                .browser, .radar, .toolkit,
            ]
        case .databases:
            dedicated = [.pages, .databases, .dbSearch, .dbAnalysis, .dbChat, .dbDeepResearch, .notes, .browser, .radar, .toolkit]
        case .testimonios:
            dedicated = [
                .search, .testimonyInterviews, .testimonyParticipants, .testimonyContrasts,
                .notes, .browser, .radar, .toolkit,
            ]
        case .worldbuilding:
            dedicated = [
                .encyclopedia, .characters, .places, .factions, .cultures, .timeline,
                .map, .relations, .tree, .dynasties, .worldChat, .rules, .conflicts,
                .arcs, .continuity, .questions, .notes, .scenes, .manuscript,
                .browser, .radar, .toolkit,
            ]
        case .academic, .genealogy:
            dedicated = nil
        }
        return dedicated?.union([.home, .library, .settings, .dictionary, .compass, .studyFocus])
    }

    static func scopedItems(for vaultType: VaultType?) -> [NodusNavigationItem] {
        let type = vaultType ?? .academic
        return items.filter { $0.vaultTypes.contains(type) }
    }

    static func visibleItems(
        for vaultType: VaultType?,
        order: [String] = [],
        hidden: Set<String>? = nil
    ) -> [NodusNavigationItem] {
        let hidden = hidden ?? defaultHiddenRoutes(for: vaultType)
        let allowed = sidebarAllowedRoutes(for: vaultType)
        let eligible = scopedItems(for: vaultType).filter {
            $0.support.isVisible
                && !hidden.contains($0.route.rawValue)
                && (allowed?.contains($0.route) ?? true)
        }
        guard !order.isEmpty else { return eligible }
        let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        let fallback = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.route.rawValue, $0.offset) })
        return eligible.sorted {
            let left = positions[$0.route.rawValue] ?? (order.count + (fallback[$0.route.rawValue] ?? 0))
            let right = positions[$1.route.rawValue] ?? (order.count + (fallback[$1.route.rawValue] ?? 0))
            return left < right
        }
    }

    static func groupedItems(
        for vaultType: VaultType?,
        order: [String] = [],
        hidden: Set<String>? = nil
    ) -> [(NodusNavigationGroup, [NodusNavigationItem])] {
        let visible = visibleItems(for: vaultType, order: order, hidden: hidden)
        return NodusNavigationGroup.allCases.compactMap { group in
            let members = visible.filter { $0.group == group && $0.route != .library }
            return members.isEmpty ? nil : (group, members)
        }
    }
}
