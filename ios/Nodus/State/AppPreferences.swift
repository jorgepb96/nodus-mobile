import Foundation
import Observation
import SwiftUI

/// The handful of choices that belong to the person rather than to a space.
///
/// Kept apart from `SpaceSession` on purpose: a preference set while reading one vault should
/// hold when the next one is opened. Not the Keychain, because none of this is a secret — losing
/// it costs a toggle, not access — and through `SyncedDefaults` rather than `UserDefaults`
/// directly, because a choice that belongs to the person should follow them to their other
/// device. These four are a few dozen bytes that change once a month; see that type for the
/// conflict rule and for what is deliberately left behind.
@Observable
@MainActor
final class AppPreferences {
    /// Whether long screens carry a "back to top" button.
    ///
    /// On by default. A corpus screen is thousands of rows deep and the alternative — the
    /// status-bar tap iOS has always had — is a gesture nobody discovers.
    var showsScrollToTop: Bool {
        didSet { persist { store.set(showsScrollToTop, forKey: Key.scrollToTop) } }
    }

    /// How Home lays its sections out.
    ///
    /// The grid is the board — every section the same size, the whole vault at a glance. The
    /// list is for a vault with many of them, where square tiles mean scrolling past two
    /// columns of mostly empty card to read the names.
    var homeLayout: HomeLayout {
        didSet { persist { store.set(homeLayout.rawValue, forKey: Key.homeLayout) } }
    }

    enum HomeLayout: String, CaseIterable, Sendable {
        case grid
        case list

        var systemImage: String {
            switch self {
            case .grid: return "square.grid.2x2"
            case .list: return "rectangle.grid.1x2"
            }
        }

        /// What the button offers, which is the *other* one.
        var toggled: HomeLayout { self == .grid ? .list : .grid }
    }

    /// How the space picker orders its list. Remembered, because re-picking an order on every
    /// launch is the surest way to make somebody stop using it.
    var spaceOrder: SpaceOrder {
        didSet { persist { store.set(spaceOrder.rawValue, forKey: Key.spaceOrder) } }
    }

    enum SpaceOrder: String, CaseIterable, Sendable, Identifiable {
        case recentlyUsed
        case recentlyAdded
        case name

        public var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .recentlyUsed: return "Recently opened"
            case .recentlyAdded: return "Recently added"
            case .name: return "Name"
            }
        }

        var systemImage: String {
            switch self {
            case .recentlyUsed: return "clock"
            case .recentlyAdded: return "plus.circle"
            case .name: return "textformat.abc"
            }
        }
    }

    /// How large a report reads, as a multiple of the system's own body size.
    ///
    /// Dynamic Type is the floor, not the ceiling: it sets the size of the whole app, and a
    /// twenty-page report read on a phone is the one place somebody wants a different size from
    /// the one their lists are in. So this multiplies whatever Dynamic Type already decided,
    /// and it is remembered — a reader who needs larger text needs it in every report.
    /// Clamped by `adjustReading(by:)` and never inside this observer.
    ///
    /// `didSet` on an `@Observable` property is not the observer on a stored property it looks
    /// like: the macro rewrites the property as a computed one, so assigning to it from inside
    /// its own `didSet` calls the setter again, and again — the app died on the stack the first
    /// time somebody pressed A⁺. An observer here may persist the value. It may not change it.
    var readingScale: Double {
        didSet { persist { store.set(readingScale, forKey: Key.readingScale) } }
    }

    enum InterfaceStyle: String, CaseIterable, Sendable {
        case system, light, dark

        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    var interfaceStyle: InterfaceStyle {
        didSet { persist { store.set(interfaceStyle.rawValue, forKey: Key.interfaceStyle) } }
    }

    var sidebarCollapsed: Bool {
        didSet { persist { store.set(sidebarCollapsed, forKey: Key.sidebarCollapsed) } }
    }

    /// Desktop keeps a 176 pt default and lets the reader resize it up to 360 pt.
    /// The iPad shell uses the same bounds; iPhone presents this hierarchy as a drawer.
    var sidebarWidth: Double {
        didSet { persist { store.set(sidebarWidth, forKey: Key.sidebarWidth) } }
    }

    /// Mirrors Desktop's per-person sidebar customisation. An empty order keeps the canonical
    /// Desktop order; once customised, hidden rows and ordering follow the person across iOS
    /// and iPadOS without changing which routes can be opened from commands or deep links.
    var sidebarOrder: [String] {
        didSet { persist { store.set(Self.encode(sidebarOrder), forKey: Key.sidebarOrder) } }
    }

    var sidebarHidden: Set<String> {
        didSet { persist { store.set(Self.encode(sidebarHidden.sorted()), forKey: Key.sidebarHidden) } }
    }

    var sidebarCustomized: Bool {
        didSet { persist { store.set(sidebarCustomized, forKey: Key.sidebarCustomized) } }
    }

    /// Personal shortcuts, shared across vaults. Home and More are never replaceable.
    private(set) var phonePinnedRoutes: [NodusRoute] {
        didSet { persist { store.set(Self.encode(phonePinnedRoutes.map(\.rawValue)), forKey: Key.phonePinnedRoutes) } }
    }

    static var phonePinCandidates: [NodusNavigationItem] {
        NodusNavigationContract.visibleItems(for: .academic).filter { $0.route != .home }
    }

    func pinPhoneRoute(_ route: NodusRoute, replacing previous: NodusRoute? = nil) {
        guard Self.phonePinCandidates.contains(where: { $0.route == route }),
              !phonePinnedRoutes.contains(route) else { return }
        if let previous, let index = phonePinnedRoutes.firstIndex(of: previous) {
            var next = phonePinnedRoutes
            next[index] = route
            phonePinnedRoutes = next
        } else if phonePinnedRoutes.count < 3 {
            phonePinnedRoutes = phonePinnedRoutes + [route]
        }
    }

    func unpinPhoneRoute(_ route: NodusRoute) {
        phonePinnedRoutes = phonePinnedRoutes.filter { $0 != route }
    }

    private static func readPhonePins(_ data: Data?) -> [NodusRoute] {
        guard let data else { return [.ideas, .graph, .deepResearch] }
        let allowed = Set(phonePinCandidates.map(\.route))
        var seen = Set<NodusRoute>()
        return Array(decode(data).compactMap(NodusRoute.init(rawValue:))
            .filter { allowed.contains($0) && seen.insert($0).inserted }.prefix(3))
    }

    func toggleInterfaceStyle(current scheme: ColorScheme) {
        interfaceStyle = scheme == .dark ? .light : .dark
    }

    static let minReadingScale = 0.85
    static let maxReadingScale = 1.8
    static let readingScaleStep = 0.15

    var canEnlargeReading: Bool { readingScale < Self.maxReadingScale - 0.001 }
    var canShrinkReading: Bool { readingScale > Self.minReadingScale + 0.001 }

    /// One step larger or smaller, kept inside the range.
    func adjustReading(by delta: Double) {
        let wanted = readingScale + delta
        readingScale = min(Self.maxReadingScale, max(Self.minReadingScale, wanted))
    }

    private let store: SyncedDefaults

    private enum Key {
        static let scrollToTop = "nodus.prefs.scrollToTop"
        static let homeLayout = "nodus.prefs.homeLayout"
        static let spaceOrder = "nodus.prefs.spaceOrder"
        static let readingScale = "nodus.prefs.readingScale"
        static let interfaceStyle = "nodus.prefs.interfaceStyle"
        static let sidebarCollapsed = "nodus.prefs.sidebarCollapsed"
        static let sidebarWidth = "nodus.prefs.sidebarWidth"
        static let sidebarOrder = "nodus.prefs.sidebarOrder"
        static let sidebarHidden = "nodus.prefs.sidebarHidden"
        static let sidebarCustomized = "nodus.prefs.sidebarCustomized"
        static let phonePinnedRoutes = "nodus.prefs.phonePinnedRoutes"

        static let all: Set<String> = [
            scrollToTop, homeLayout, spaceOrder, readingScale, interfaceStyle,
            sidebarCollapsed, sidebarWidth, sidebarOrder, sidebarHidden, sidebarCustomized,
            phonePinnedRoutes,
        ]
    }

    init(store: SyncedDefaults = .shared) {
        self.store = store
        // Optional reads rather than `bool(forKey:)`-style ones with a built-in zero: an absent
        // key would read as false, which would ship the back-to-top button switched off for
        // everyone who never touched the switch.
        showsScrollToTop = store.bool(forKey: Key.scrollToTop) ?? true
        homeLayout = HomeLayout(rawValue: store.string(forKey: Key.homeLayout) ?? "") ?? .grid
        spaceOrder = SpaceOrder(rawValue: store.string(forKey: Key.spaceOrder) ?? "") ?? .recentlyUsed
        readingScale = store.double(forKey: Key.readingScale) ?? 1
        interfaceStyle = InterfaceStyle(rawValue: store.string(forKey: Key.interfaceStyle) ?? "") ?? .system
        sidebarCollapsed = store.bool(forKey: Key.sidebarCollapsed) ?? false
        sidebarWidth = store.double(forKey: Key.sidebarWidth) ?? 176
        sidebarOrder = Self.decode(store.data(forKey: Key.sidebarOrder))
        sidebarHidden = Set(Self.decode(store.data(forKey: Key.sidebarHidden)))
        sidebarCustomized = store.bool(forKey: Key.sidebarCustomized) ?? false
        phonePinnedRoutes = Self.readPhonePins(store.data(forKey: Key.phonePinnedRoutes))
        store.onExternalChange(of: Key.all) { [weak self] in self?.adoptRemote() }
    }

    /// Whether a change to one of these properties is this device's decision or somebody else's.
    ///
    /// Every setter persists, which is right when a person taps a switch and wrong when the
    /// value arrived from their iPad: writing it back would stamp it as this device's newer
    /// choice and push it out again, and the two devices would trade the same preference until
    /// one of them was switched off.
    private var isAdoptingRemote = false

    private func persist(_ write: () -> Void) {
        guard !isAdoptingRemote else { return }
        write()
    }

    private func adoptRemote() {
        isAdoptingRemote = true
        defer { isAdoptingRemote = false }
        showsScrollToTop = store.bool(forKey: Key.scrollToTop) ?? true
        homeLayout = HomeLayout(rawValue: store.string(forKey: Key.homeLayout) ?? "") ?? .grid
        spaceOrder = SpaceOrder(rawValue: store.string(forKey: Key.spaceOrder) ?? "") ?? .recentlyUsed
        readingScale = store.double(forKey: Key.readingScale) ?? 1
        interfaceStyle = InterfaceStyle(rawValue: store.string(forKey: Key.interfaceStyle) ?? "") ?? .system
        sidebarCollapsed = store.bool(forKey: Key.sidebarCollapsed) ?? false
        sidebarWidth = store.double(forKey: Key.sidebarWidth) ?? 176
        sidebarOrder = Self.decode(store.data(forKey: Key.sidebarOrder))
        sidebarHidden = Set(Self.decode(store.data(forKey: Key.sidebarHidden)))
        sidebarCustomized = store.bool(forKey: Key.sidebarCustomized) ?? false
        phonePinnedRoutes = Self.readPhonePins(store.data(forKey: Key.phonePinnedRoutes))
    }

    private static func encode(_ values: [String]) -> Data {
        (try? JSONEncoder().encode(values)) ?? Data("[]".utf8)
    }

    private static func decode(_ data: Data?) -> [String] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
