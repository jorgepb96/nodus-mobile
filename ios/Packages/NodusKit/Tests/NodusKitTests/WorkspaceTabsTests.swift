import Testing
@testable import NodusKit

@Suite("Shared workspace tabs")
@MainActor
struct WorkspaceTabsTests {
    private func tab(_ id: String, kind: WorkspaceTabKind = .idea) -> WorkspaceTab {
        WorkspaceTab(
            id: id,
            title: "Tab \(id)",
            systemImage: "doc",
            kind: kind,
            payload: .reference(kind: kind.rawValue, id: id)
        )
    }

    @Test("opening an existing entity activates it without duplication")
    func noDuplicates() {
        let store = WorkspaceTabs()
        store.open(tab("a"), in: "ideas")
        store.open(tab("b"), in: "ideas")
        store.open(tab("a"), in: "ideas")
        #expect(store.tabs(in: "ideas").map(\.id) == ["a", "b"])
        #expect(store.activeTabId(in: "ideas") == "a")
    }

    @Test("closing the active tab chooses its new neighbour")
    func adjacentClose() {
        let store = WorkspaceTabs()
        for id in ["a", "b", "c"] { store.open(tab(id), in: "ideas") }
        store.activate("b", in: "ideas")
        #expect(store.close("b", in: "ideas") == "c")
        #expect(store.close("c", in: "ideas") == "a")
        #expect(store.close("a", in: "ideas") == nil)
    }

    @Test("inactive close and catalogue activation retain the intended surface")
    func inactiveClose() {
        let store = WorkspaceTabs()
        store.open(tab("a"), in: "authors")
        store.open(tab("b"), in: "authors")
        store.activate("a", in: "authors")
        #expect(store.close("b", in: "authors") == "a")
        store.activateCatalog(in: "authors")
        #expect(store.activeTabId(in: "authors") == nil)
        #expect(store.tabs(in: "authors").map(\.id) == ["a"])
    }

    @Test("Ideas and Library survive route changes while Argument Map does not")
    func routeRetention() {
        let store = WorkspaceTabs()
        store.open(tab("idea"), in: "ideas")
        store.open(tab("work", kind: .document), in: "library")
        store.open(tab("map", kind: .argumentMap), in: "argument")
        store.leave("ideas")
        store.leave("library")
        store.leave("argument")
        #expect(store.tabs(in: "ideas").count == 1)
        #expect(store.tabs(in: "library").count == 1)
        #expect(store.tabs(in: "argument").isEmpty)
    }

    @Test("serialized heavy state survives a duplicate deep link")
    func serializedState() {
        let store = WorkspaceTabs()
        store.open(tab("reader", kind: .document), in: "library")
        store.saveState(["scrollAnchor": .string("p-42")], for: "reader", in: "library")
        store.open(tab("reader", kind: .document), in: "library")
        #expect(store.tabs(in: "library").first?.serializedState["scrollAnchor"] == .string("p-42"))
    }
}
