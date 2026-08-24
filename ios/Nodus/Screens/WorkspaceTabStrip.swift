import NodusKit
import NodusUI
import SwiftUI

/// Desktop's fixed catalogue tab followed by closeable document tabs.
///
/// The strip is deliberately shared by Ideas, Authors, Argument Map and Library. That makes
/// close selection, keyboard traversal, pointer behaviour and accessibility one contract rather
/// than four similar implementations that can drift independently.
struct WorkspaceTabStrip: View {
    @Environment(WorkspaceTabs.self) private var workspaceTabs
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let section: String
    let catalogueTitle: String
    let catalogueImage: String
    let accent: Color

    private var tabs: [WorkspaceTab] { workspaceTabs.tabs(in: section) }
    private var activeId: String? { workspaceTabs.activeTabId(in: section) }
    private var height: CGFloat {
        horizontalSizeClass == .compact
            ? NodusChromeMetrics.compactWorkspaceTabs
            : NodusChromeMetrics.workspaceTabs
    }
    private var catalogueWidth: CGFloat { horizontalSizeClass == .compact ? 150 : 168 }
    private var documentWidth: CGFloat { horizontalSizeClass == .compact ? 218 : 260 }
    private var localizedCatalogueTitle: String {
        Bundle.main.localizedString(forKey: catalogueTitle, value: catalogueTitle, table: nil)
    }

    var body: some View {
        HStack(spacing: 0) {
            catalogueTab.frame(width: catalogueWidth)
            Divider().frame(height: 22)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        documentTab(tab)
                            .frame(width: documentWidth)
                            .id(tab.id)
                    }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .accessibilityIdentifier("workspace-tabs-\(section)")
                .onChange(of: activeId, initial: true) { _, id in
                    guard let id else { return }
                    withAnimation(NodusMotion.quick) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .frame(height: height)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.94))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .background { keyboardCommands }
    }

    private var catalogueTab: some View {
        Button { workspaceTabs.activateCatalog(in: section) } label: {
            HStack(spacing: 7) {
                Image(systemName: catalogueImage).font(.system(size: 12, weight: .semibold))
                Text(localizedCatalogueTitle).font(.caption.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(activeId == nil ? Color.primary : Color.nodusSecondaryText)
            .padding(.horizontal, 13)
            .frame(height: height)
            .background(tabBackground(active: activeId == nil))
            .overlay(alignment: .bottom) { selectionLine(active: activeId == nil) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(Text("\(localizedCatalogueTitle), \(String(localized: "catalogue"))"))
        .accessibilityAddTraits(activeId == nil ? .isSelected : [])
        .accessibilityIdentifier("workspace-catalogue-\(section)")
    }

    private func documentTab(_ tab: WorkspaceTab) -> some View {
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
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .accessibilityIdentifier("workspace-tab-\(section)-\(safeIdentifier(tab.id))")

            Button { workspaceTabs.close(tab.id, in: section) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: horizontalSizeClass == .compact ? 34 : 26, height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isActive ? Color.nodusSecondaryText : Color.nodusTertiaryText)
            .accessibilityLabel("Close \(tab.title)")
            .accessibilityIdentifier("workspace-close-\(section)-\(safeIdentifier(tab.id))")
        }
        .padding(.leading, 11)
        .fixedSize(horizontal: false, vertical: true)
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
