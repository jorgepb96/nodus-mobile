import NodusKit
import NodusUI
import SwiftUI

struct LinkHomeView: View {
    let session: SpaceSession
    let onSelect: (NodusRoute) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label("Nodus Link", systemImage: "link").font(.largeTitle.bold())
                Text("Tus ideas, siempre contigo").font(.title3)
                Text("Consulta tu investigación y escucha los podcasts que has creado en Nodus. Vincula tu ordenador en la misma red o VPN para ver sus contenidos actualizados.")
                    .foregroundStyle(.secondary)
                if let failure = session.loadFailure {
                    NodusNotice(tone: failure.tone, title: LocalizedStringKey(failure.title), message: LocalizedStringKey(failure.sentence), systemImage: failure.systemImage)
                    Button("Reintentar conexión") { Task { await session.refreshPublishedContent() } }
                        .frame(minHeight: 44)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                    ForEach(NodusNavigationContract.visibleItems(for: session.vaultType).filter {
                        [.ideas, .studyIdeas, .graph, .studyGraph, .argument, .deepResearch, .studyDeepResearch, .dictionary, .podcast, .library].contains($0.route)
                    }) { item in
                        Button { onSelect(item.route) } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                NodusIcon(name: item.systemImage, size: 25)
                                Text(item.label).font(.headline).multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                            .padding(16).background(session.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain).foregroundStyle(session.accent.nodusReadable)
                        .accessibilityIdentifier("link-home-\(item.route.rawValue)")
                    }
                }
                Label(session.connection.serverName, systemImage: "desktopcomputer").font(.footnote).foregroundStyle(.secondary)
                Text("La creación y edición se realizan en Nodus Desktop. Las copias descargadas siguen disponibles cuando el ordenador no está conectado.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }.accessibilityIdentifier("link-home")
    }
}
