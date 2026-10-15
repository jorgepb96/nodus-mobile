import NodusKit
import NodusUI
import SwiftUI
import UIKit

/// Desktop's fixed catalogue tab followed by closeable document tabs.
///
/// The strip is deliberately shared by Ideas, Authors, Argument Map and Library. That makes
/// close selection, keyboard traversal, pointer behaviour and accessibility one contract rather
/// than four similar implementations that can drift independently.
struct WorkspaceTabStrip: View {
    @Environment(WorkspaceTabs.self) private var workspaceTabs
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.nodusResidentRouteActive) private var routeActive
    @ScaledMetric(relativeTo: .caption) private var scaledTouchHeight: CGFloat = 44

    let section: String
    let catalogueTitle: String
    let catalogueImage: String
    let accent: Color

    private var tabs: [WorkspaceTab] { workspaceTabs.tabs(in: section) }
    private var activeId: String? { workspaceTabs.activeTabId(in: section) }
    private var usesTouchTabs: Bool { UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact }
    private var height: CGFloat { max(44, scaledTouchHeight) }
    private var compactCatalogue: Bool { usesTouchTabs && activeId != nil }
    private var catalogueWidth: CGFloat { compactCatalogue ? 44 : usesTouchTabs ? 150 : 168 }
    private var localizedCatalogueTitle: String {
        Bundle.main.localizedString(forKey: catalogueTitle, value: catalogueTitle, table: nil)
    }

    var body: some View {
        GeometryReader { geometry in
            let documentWidth: CGFloat = usesTouchTabs && geometry.size.width <= 600
                ? max(44, geometry.size.width - catalogueWidth - 1)
                : usesTouchTabs ? 218.0 : 260.0
            HStack(spacing: 0) {
                catalogueTab
                Divider().frame(height: 22)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ForEach(tabs) { tab in
                                documentTab(tab, width: documentWidth).id(tab.id)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    .accessibilityIdentifier("workspace-tabs-\(section)")
                    .onChange(of: activeId, initial: true) { _, id in
                        guard let id else { return }
                        withAnimation(NodusMotion.quick) { proxy.scrollTo(id, anchor: .leading) }
                    }
                    .onChange(of: horizontalSizeClass) { _, _ in
                        guard let activeId else { return }
                        proxy.scrollTo(activeId, anchor: .leading)
                    }
                    .onChange(of: documentWidth) { _, _ in
                        guard let activeId else { return }
                        proxy.scrollTo(activeId, anchor: .leading)
                    }
                }
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.94))
        .overlay(alignment: .bottom) { Divider() }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-tab-strip-\(section)")
        .background { if routeActive { keyboardCommands } }
    }

    private var catalogueTab: some View {
        Button { workspaceTabs.activateCatalog(in: section) } label: {
            HStack(spacing: 7) {
                Image(systemName: catalogueImage).font(.system(size: 12, weight: .semibold))
                if !compactCatalogue {
                    Text(localizedCatalogueTitle).font(.caption.weight(.medium)).lineLimit(1)
                }
            }
            .foregroundStyle(activeId == nil ? Color.primary : Color.nodusSecondaryText)
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: catalogueWidth, height: height)
        .background(tabBackground(active: activeId == nil))
        .overlay(alignment: .bottom) { selectionLine(active: activeId == nil) }
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .accessibilityLabel(Text("\(localizedCatalogueTitle), \(String(localized: "catalogue"))"))
        .accessibilityAddTraits(activeId == nil ? .isSelected : [])
        .accessibilityIdentifier("workspace-catalogue-\(section)")
    }

    private func documentTab(_ tab: WorkspaceTab, width: CGFloat) -> some View {
        let isActive = activeId == tab.id
        return HStack(spacing: 5) {
            Button { workspaceTabs.activate(tab.id, in: section) } label: {
                HStack(spacing: 7) {
                    Image(systemName: tab.systemImage).font(.system(size: 11, weight: .medium))
                    Text(tab.title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(isActive ? Color.primary : Color.nodusSecondaryText)
                .frame(height: height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .layoutPriority(-1)
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .accessibilityIdentifier("workspace-tab-\(section)-\(safeIdentifier(tab.id))")

            Button { workspaceTabs.close(tab.id, in: section) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 44, height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isActive ? Color.nodusSecondaryText : Color.nodusTertiaryText)
            .accessibilityLabel("Close \(tab.title)")
            .accessibilityIdentifier("workspace-close-\(section)-\(safeIdentifier(tab.id))")
            .fixedSize()
        }
        .padding(.leading, 11)
        .frame(width: width, height: height)
        .clipped()
        .background(tabBackground(active: isActive))
        .overlay(alignment: .bottom) { selectionLine(active: isActive) }
        .overlay(alignment: .trailing) { Divider().frame(height: 18) }
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .contextMenu {
            Button(role: .destructive) { workspaceTabs.close(tab.id, in: section) } label: {
                Label("Close tab", systemImage: "xmark")
            }
        }
    }

    private func tabBackground(active: Bool) -> some View {
        Rectangle().fill(active ? Color(uiColor: .systemBackground) : Color.clear)
    }

    private func selectionLine(active: Bool) -> some View {
        Rectangle().fill(active ? accent : Color.clear).frame(height: 2)
    }

    /// Command-W and Command-Shift-[ / ] mirror the Desktop tab contract. Invisible command
    /// buttons keep the implementation on public SwiftUI APIs back to the iOS 17 deployment.
    private var keyboardCommands: some View {
        Group {
            Button("Previous workspace tab") {
                workspaceTabs.activateAdjacent(to: activeId, direction: -1, in: section)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next workspace tab") {
                workspaceTabs.activateAdjacent(to: activeId, direction: 1, in: section)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Close workspace tab") {
                if let activeId { workspaceTabs.close(activeId, in: section) }
            }
            .keyboardShortcut("w", modifiers: .command)
        }
        .hidden()
    }

    private func safeIdentifier(_ value: String) -> String {
        value.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
    }
}
