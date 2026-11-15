import NodusKit
import NodusUI
import SwiftUI

/// The ideas gathered under one theme.
///
/// The theme's enriched public dossier carries its actual linked ideas. Opening
/// it does not require downloading the whole vault or its image collection.
struct ThemeIdeasView: View {
    let session: SpaceSession
    let theme: Row

    @State private var ideas: [Row] = []
    @State private var query = ""
    @State private var isLoading = true
    @State private var fromDevice = false
    @State private var visibleLimit = 80
    @State private var error: String?

    private var themeId: String? { theme.string("theme_id") }
    private var label: String { theme.text("label") ?? "Theme" }

    private var filtered: [Row] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return ideas }
        return ideas.filter { $0.searchableText.lowercased().contains(needle) }
    }

    var body: some View {
        List {
            if fromDevice {
                Label("Sin conexión · contenido de este dispositivo", systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary).listRowBackground(Color.clear)
            }

            if isLoading {
                HStack { Spacer(); ProgressView("Loading ideas…"); Spacer() }
                    .listRowBackground(Color.clear)
            }

            if let error {
                NodusNotice(tone: .blocked, title: "Could not load theme ideas", message: LocalizedStringKey(error))
                    .listRowBackground(Color.clear)
                Button("Reintentar") { Task { await load() } }.frame(minHeight: 44).disabled(isLoading)
            }

            ForEach(Array(filtered.prefix(visibleLimit).enumerated()), id: \.offset) { _, idea in
                NavigationLink {
                    RowDetailView(session: session, collection: Collections["ideas"], row: idea)
                } label: {
                    RowCell(row: idea, presenter: RowPresenter.forTable("ideas"), accent: session.accent)
                }
                .listRowBackground(Color.clear)
            }
            if filtered.count > visibleLimit {
                Button("Mostrar más ideas (\(filtered.count - visibleLimit))") { visibleLimit += 80 }.frame(minHeight: 44)
                    .accessibilityIdentifier("theme-ideas-show-more")
            }

            if !isLoading, ideas.isEmpty, error == nil {
                ContentUnavailableView(
                    "No ideas",
                    systemImage: "lightbulb",
                    description: Text("No idea in this publication is linked to “\(label)”.")
                )
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .nodusDismissesKeyboard()
        .listStyle(.plain)
        .listRowSeparatorTint(Color.nodusTertiaryText.opacity(0.45))
        .navigationTitle(label)
        .navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .safeAreaInset(edge: .top) {
            NodusSearchField(text: $query, prompt: "Filter ideas under this theme", accent: session.accent)
                .padding(.horizontal, NodusSpace.page)
                .padding(.bottom, 8)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !ideas.isEmpty {
                    Text("\(filtered.count)")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: query) { _, _ in visibleLimit = 80 }
        .task(id: session.publishedRevision) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let themeId, let collection = Collections["themes"] else { throw DesktopBridgeError.malformedResponse }
            let dossier = try await session.client.dossier(collection, id: themeId, in: session.connection.spaceId)
            guard let rows = dossier.sections["ideas"]?.arrayValue, rows.allSatisfy({ $0.objectValue != nil && $0.objectValue?["global_id"]?.stringValue != nil }) else { throw DesktopBridgeError.malformedResponse }
            try Task.checkCancellation()
            ideas = rows.map { Row($0.objectValue!) }; fromDevice = dossier.fromDevice; visibleLimit = 80
            error = nil
        } catch where error.isCancellation {
            // A hidden route or a newer publication supersedes this read.
        } catch {
            self.error = error.localizedDescription
        }
    }
}
