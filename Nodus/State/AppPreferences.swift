import Foundation
import Observation
import SwiftUI

/// The handful of choices that belong to the person rather than to a space.
///
/// Kept apart from `SpaceSession` on purpose: a preference set while reading one vault should
/// hold when the next one is opened. `UserDefaults` rather than the Keychain because none of
/// this is a secret — losing it costs a toggle, not access.
@Observable
@MainActor
final class AppPreferences {
    /// Whether long screens carry a "back to top" button.
    ///
    /// On by default. A corpus screen is thousands of rows deep and the alternative — the
    /// status-bar tap iOS has always had — is a gesture nobody discovers.
    var showsScrollToTop: Bool {
        didSet { defaults.set(showsScrollToTop, forKey: Key.scrollToTop) }
    }

    /// How Home lays its sections out.
    ///
    /// The grid is the board — every section the same size, the whole vault at a glance. The
    /// list is for a vault with many of them, where square tiles mean scrolling past two
    /// columns of mostly empty card to read the names.
    var homeLayout: HomeLayout {
        didSet { defaults.set(homeLayout.rawValue, forKey: Key.homeLayout) }
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
        didSet { defaults.set(spaceOrder.rawValue, forKey: Key.spaceOrder) }
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

    private let defaults: UserDefaults

    private enum Key {
        static let scrollToTop = "nodus.prefs.scrollToTop"
        static let homeLayout = "nodus.prefs.homeLayout"
        static let spaceOrder = "nodus.prefs.spaceOrder"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `object(forKey:)` rather than `bool(forKey:)`: an absent key reads as false, which
        // would ship the feature switched off for everyone who never touched the switch.
        showsScrollToTop = defaults.object(forKey: Key.scrollToTop) as? Bool ?? true
        homeLayout = HomeLayout(rawValue: defaults.string(forKey: Key.homeLayout) ?? "") ?? .grid
        spaceOrder = SpaceOrder(rawValue: defaults.string(forKey: Key.spaceOrder) ?? "") ?? .recentlyUsed
    }
}
