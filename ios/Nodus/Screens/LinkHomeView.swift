import NodusKit
import NodusUI
import SwiftUI

/// A reading dashboard. Every card opens a real section of the linked academic vault.
struct LinkHomeView: View {
    let session: SpaceSession
    let onSelect: (NodusRoute) -> Void
    private let destinations: [(NodusRoute, String, String, String)] = [
        (.ideas, "Ideas", "lightbulb", "Ideas y fuentes"),
        (.graph, "Graph", "point.3.connected.trianglepath.dotted", "Relaciones entre ideas"),
        (.argument, "Argument map", "square.3.layers.3d", "Argumentos y evidencias"),
        (.deepResearch, "Deep Research", "telescope", "Informes guardados"),
        (.dictionary, "Dictionary", "character.book.closed", "Conceptos y definiciones"),
        (.podcast, "Podcasts", "headphones", "Episodios para escuchar"),
        (.authors, "Authors", "graduationcap", "Autores y sus obras"),
        (.library, "Library", "books.vertical", "Consulta las obras y sus fuentes")
    ]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tu investigación").font(.title.bold()).accessibilityAddTraits(.isHeader)
                    Text(session.connection.spaceName).font(.title3).foregroundStyle(.secondary)
                }
                connectionStatus
                HStack(spacing: 0) {
                    Button { onSelect(.search) } label: {
                        Label("Buscar ideas, fuentes o conceptos", systemImage: "magnifyingglass")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .padding(.leading, 16)
                    }.buttonStyle(.plain).accessibilityIdentifier("link-home-search")
                    LinkSectionPin(route: .search, accent: session.accent).padding(.trailing, 4)
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 14) {
                    Text("Sections").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(destinations, id: \.0) { item in
                            ZStack(alignment: .topTrailing) {
                                Button { onSelect(item.0) } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        NodusIcon(name: item.2, size: 21).foregroundStyle(session.accent.nodusReadable)
                                            .frame(width: 36, height: 36)
                                            .background(session.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(LocalizedStringKey(item.1)).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                            Text(LocalizedStringKey(item.3)).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
                                        .padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                                }.buttonStyle(.plain).multilineTextAlignment(.leading)
                                    .accessibilityIdentifier("link-home-\(item.0.rawValue)")
                                // A sibling button, so pinning never also opens the section.
                                HStack(spacing: 0) {
                                    if !session.isDemo, let section = LinkDownloadSection(route: item.0) { LinkSectionDownloadButton(section: section) }
                                    LinkSectionPin(route: item.0, accent: session.accent)
                                }.padding(6)
                            }
                        }
                    }
                }
                ZStack(alignment: .topTrailing) {
                    Button { onSelect(.settings) } label: {
                        Label("Settings", systemImage: "gearshape")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.leading, 16).padding(.trailing, 56).padding(.vertical, 6)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain).accessibilityIdentifier("link-home-settings")
                    LinkSectionPin(route: .settings, accent: session.accent).padding(6)
                }
            }.padding(20).frame(maxWidth: 920).frame(maxWidth: .infinity)
        }.background(Color(uiColor: .systemGroupedBackground)).accessibilityIdentifier("link-home")
    }
    private var connectionStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(session.isDemo ? "Demostración local" : session.connection.serverName,
                  systemImage: session.isDemo ? "iphone" : session.loadFailure == nil ? "desktopcomputer" : "wifi.slash")
                .font(.subheadline.weight(.medium))
            if let failure = session.loadFailure, !session.isDemo {
                Text(failure.sentence).font(.caption).foregroundStyle(.secondary)
                Button("Reintentar conexión") { Task { await session.refreshPublishedContent() } }.frame(minHeight: 44)
            } else if session.isDemo {
                Text("Explora los contenidos de ejemplo. No necesitas conectar un ordenador.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(session.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Shared by dashboard cards and the current section's top-right controls.
/// At three pins, replacing a shortcut is an explicit choice rather than evicting one silently.
struct LinkSectionPin: View {
    @Environment(AppPreferences.self) private var preferences
    let route: NodusRoute
    let accent: Color
    @State private var replacing = false
    private var pinned: Bool { preferences.phonePinnedRoutes.contains(route) }
    private var sectionLabel: LocalizedStringKey {
        AppPreferences.phonePinCandidates.first(where: { $0.route == route })?.label ?? LocalizedStringKey(route.rawValue)
    }

    var body: some View {
        Button {
            if pinned { preferences.unpinPhoneRoute(route) }
            else if preferences.phonePinnedRoutes.count < 3 { preferences.pinPhoneRoute(route) }
            else { replacing = true }
        } label: {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(pinned ? accent.nodusReadable : Color.secondary)
        .accessibilityLabel(Text(pinned ? LocalizedStringKey("Unpin from bottom bar") : LocalizedStringKey("Pin to bottom bar")))
        .accessibilityValue(Text(sectionLabel))
        .accessibilityAddTraits(pinned ? .isSelected : [])
        .accessibilityIdentifier("section-pin-\(route.rawValue)")
        .confirmationDialog("Replace a pinned section", isPresented: $replacing, titleVisibility: .visible) {
            ForEach(preferences.phonePinnedRoutes) { previous in
                Button {
                    preferences.pinPhoneRoute(route, replacing: previous)
                } label: {
                    Text(AppPreferences.phonePinCandidates.first(where: { $0.route == previous })?.label ?? LocalizedStringKey(previous.rawValue))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can pin three sections. Choose which one to replace.")
        }
    }
}
