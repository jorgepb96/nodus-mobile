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
        (.podcast, "Podcasts", "headphones", "Episodios para escuchar")
    ]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tu investigación").font(.title.bold()).accessibilityAddTraits(.isHeader)
                    Text(session.connection.spaceName).font(.title3).foregroundStyle(.secondary)
                }
                connectionStatus
                Button { onSelect(.search) } label: {
                    Label("Buscar ideas, fuentes o conceptos", systemImage: "magnifyingglass")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(.horizontal, 16)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain).accessibilityIdentifier("link-home-search")
                VStack(alignment: .leading, spacing: 14) {
                    Text("Explorar").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(destinations, id: \.0) { item in
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
                        }
                    }
                }
                Button { onSelect(.library) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "books.vertical").foregroundStyle(session.accent.nodusReadable)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Library").font(.headline).foregroundStyle(.primary)
                            Text("Consulta las obras y sus fuentes").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                    }.padding(16).frame(minHeight: 56)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                }.buttonStyle(.plain).accessibilityIdentifier("link-home-library")
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
