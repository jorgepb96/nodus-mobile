import Foundation
import Observation

public enum WorkspaceTabKind: String, Sendable, Hashable, Codable {
    case document
    case idea
    case author
    case argumentMap
    case reference
    case matrix
}

public enum WorkspaceTabPayload: Sendable, Hashable, Codable {
    case row(Row)
    case libraryDocument(PublishedLibraryDocument)
    case accountLibraryItem(AccountLibraryItem)
    case argumentSeed(id: String, label: String)
    case reference(kind: String, id: String)
}

public struct WorkspaceTab: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public var title: String
    public var systemImage: String
    public let kind: WorkspaceTabKind
    public var payload: WorkspaceTabPayload
    /// A heavy surface can be unmounted while retaining the state its renderer writes here.
    /// Lightweight dossiers normally stay mounted and need no serialisation during a session.
    public var serializedState: [String: JSONValue]

    public init(
        id: String,
        title: String,
        systemImage: String,
        kind: WorkspaceTabKind,
        payload: WorkspaceTabPayload,
        serializedState: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
        self.payload = payload
        self.serializedState = serializedState
    }
}

public struct WorkspaceTabSession: Sendable, Hashable, Codable {
    public var tabs: [WorkspaceTab]
    /// Nil is the fixed catalogue tab.
    public var activeTabId: String?

    public init(tabs: [WorkspaceTab] = [], activeTabId: String? = nil) {
        self.tabs = tabs
        self.activeTabId = tabs.contains(where: { $0.id == activeTabId }) ? activeTabId : nil
    }
}

/// One tab model for every shared SwiftUI surface.
///
/// Sections are addressed by the Desktop route id rather than an iOS-only enum. This lets deep
/// links, restoration tests and the generated parity manifest all speak the same vocabulary.
@Observable
@MainActor
public final class WorkspaceTabs {
    private var sessions: [String: WorkspaceTabSession] = [:]
    private let resetOnLeave: Set<String>

    public init(resetOnLeave: Set<String> = ["argument"]) {
        self.resetOnLeave = resetOnLeave
    }

    public func session(for section: String) -> WorkspaceTabSession {
        sessions[section] ?? WorkspaceTabSession()
    }

    public func tabs(in section: String) -> [WorkspaceTab] {
        session(for: section).tabs
    }

    public func activeTabId(in section: String) -> String? {
        session(for: section).activeTabId
    }

    /// Opens exactly once. A deep link to an existing dossier updates its display data and
    /// activates the existing tab instead of creating a second copy with divergent state.
    public func open(_ tab: WorkspaceTab, in section: String) {
        var value = session(for: section)
        if let index = value.tabs.firstIndex(where: { $0.id == tab.id }) {
            let retainedState = value.tabs[index].serializedState
            value.tabs[index] = tab
            if value.tabs[index].serializedState.isEmpty {
                value.tabs[index].serializedState = retainedState
            }
        } else {
            value.tabs.append(tab)
        }
        value.activeTabId = tab.id
        sessions[section] = value
    }

    public func activate(_ id: String, in section: String) {
        var value = session(for: section)
        guard value.tabs.contains(where: { $0.id == id }) else { return }
        value.activeTabId = id
        sessions[section] = value
    }

    public func activateCatalog(in section: String) {
        var value = session(for: section)
        value.activeTabId = nil
        sessions[section] = value
    }

    /// Closing the active tab selects the tab now occupying its index, or the preceding tab
    /// when the last one closes. Closing an inactive tab never moves the reader.
    @discardableResult
    public func close(_ id: String, in section: String) -> String? {
        var value = session(for: section)
        guard let closingIndex = value.tabs.firstIndex(where: { $0.id == id }) else {
            return value.activeTabId
        }
        value.tabs.remove(at: closingIndex)
        if value.activeTabId == id {
            value.activeTabId = value.tabs.isEmpty
                ? nil
                : value.tabs[min(closingIndex, value.tabs.count - 1)].id
        }
        sessions[section] = value
        return value.activeTabId
    }

    public func activateAdjacent(to id: String?, direction: Int, in section: String) {
        let value = session(for: section)
        let ids: [String?] = [nil] + value.tabs.map { Optional($0.id) }
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex(where: { $0 == id }) ?? 0
        let delta = direction < 0 ? -1 : 1
        let next = (current + delta + ids.count) % ids.count
        if let id = ids[next] { activate(id, in: section) }
        else { activateCatalog(in: section) }
    }

    public func saveState(_ state: [String: JSONValue], for id: String, in section: String) {
        var value = session(for: section)
        guard let index = value.tabs.firstIndex(where: { $0.id == id }) else { return }
        value.tabs[index].serializedState = state
        sessions[section] = value
    }

    public func leave(_ section: String) {
        guard resetOnLeave.contains(section) else { return }
        sessions[section] = WorkspaceTabSession()
    }

    public func clear(section: String) {
        sessions[section] = WorkspaceTabSession()
    }
}
