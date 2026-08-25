import NodusKit
import NodusUI
import SwiftUI

/// The published half of Desktop's State of Research workspace. Coverage, gaps and debates
/// all have replica contracts; the ranked reading plan does not and is therefore hidden rather
/// than redirected to an unrelated reports screen.
struct ResearchStateView: View {
    let session: SpaceSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                DesktopPageHeader(
                    title: "State of research",
                    subtitle: "Coverage, gaps and disagreements in the published corpus",
                    systemImage: "safari",
                    accent: session.accent
                )

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                    if let themes = Collections["themes"] {
                        destination("Themes", "number", count: session.count(of: themes)) {
                            CollectionListView(session: session, collection: themes)
                        }
                    }
                    if let gaps = Collections["gaps"] {
                        destination("Gaps", "questionmark.diamond", count: session.count(of: gaps)) {
                            CollectionListView(session: session, collection: gaps)
                        }
                    }
                    if session.hasDebates {
                        destination("Debates", "bubble.left.and.bubble.right", count: nil) {
                            SpecialListView(session: session, resource: .debates)
                        }
                        destination("Argument map", "square.3.layers.3d", count: nil) {
                            ArgumentMapView(session: session)
                        }
                    }
                }

                if !session.hasDebates, (session.overview?.counts["gaps"] ?? 0) == 0,
                   (session.overview?.counts["themes"] ?? 0) == 0 {
                    ContentUnavailableView(
                        "No research analysis published",
                        systemImage: "safari",
                        description: Text("Run corpus analysis in Nodus Desktop and publish the vault to see its coverage here.")
                    )
                    .padding(.vertical, 42)
                }
            }
            .padding(NodusSpace.page)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nodusTopAnchor()
        }
        .nodusPageBackdrop(accent: session.accent)
        .refreshable { await session.load() }
    }

    private func destination<Destination: View>(
        _ title: LocalizedStringKey,
        _ icon: String,
        count: Int?,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(session.accent.nodusReadable)
                    .frame(width: 32)
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if let count { CountBadge(count: count, accent: session.accent.nodusReadable) }
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .desktopContentRow(accent: session.accent)
            // Keep the four destinations a single visual row. “Gaps” is intentionally short;
            // the fixed height also prevents a longer translated title from making one card
            // taller than its neighbours.
            .frame(height: 64)
        }
        .buttonStyle(NodusCardButtonStyle())
    }
}
