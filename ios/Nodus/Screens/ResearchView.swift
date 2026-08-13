import NodusAI
import NodusKit
import NodusUI
import SwiftUI

/// The Research tab: what the corpus already holds, and what the model can build from it.
///
/// Deep Research reports and immersion sessions published by the desktop sit beside the runner
/// that makes new ones, because to a reader they are the same thing at different ages.
struct ResearchView: View {
    @Environment(AISettings.self) private var ai
    let session: SpaceSession

    @State private var showingProviders = false
    @State private var store: LocalReportStore?
    /// How many the vault itself has published, so the count beside "All reports" is the
    /// number of reports there are rather than the number this phone happens to have written.
    @State private var publishedReports = 0

    var body: some View {
        Group {
            if let store { content(store) } else { ProgressView().tint(session.accent) }
        }
        .task(id: session.publishedRevision) {
            if store == nil { store = LocalReportStore.shared(for: session.connection.spaceId) }
            publishedReports = (try? await session.client.deepResearchReports(
                in: session.connection.spaceId,
                limit: 1
            ).total) ?? 0
        }
    }

    /// A `ScrollView` of the app's own cards, not a `List`.
    ///
    /// This screen was the last stock-iOS surface in the app and it looked it: a grouped `List`
    /// gives every row `secondarySystemGroupedBackground`, which is flat white in light mode and
    /// a flat near-black in dark, and its section headers are the system's own small capitals.
    /// So the Research tab was three black slabs and three shouting headings on a page whose
    /// every other screen is tinted glass over an accent wash — which is the break item 8 names.
    /// (`.listRowBackground` was there and did nothing: it applies to a row, and putting it on
    /// the `List` reaches no row at all.)
    private func content(_ local: LocalReportStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                VStack(alignment: .leading, spacing: 9) {
                    NodusSectionLabel("Deep Research")
                    NavigationLink {
                        DeepResearchScreen(session: session, local: local)
                            .environment(ai)
                    } label: {
                        row(
                            icon: "sparkles",
                            title: "Generate a report",
                            // The run in flight, when there is one: this row is the way back to
                            // it, and a row that says only which model is chosen does not look
                            // like one.
                            // `String(localized:)`, because the fallback is a literal reaching
                            // `Text` as a value — the model name beside it really is data.
                            subtitle: runner.isRunning
                                ? runner.request?.objective ?? String(localized: "In progress")
                                : ai.model(for: .deepResearch)?.model ?? String(localized: "No model chosen"),
                            isBusy: runner.isRunning
                        )
                    }
                    .buttonStyle(NodusCardButtonStyle())
                    Text("One model call per section, with citations checked against the corpus. Your key never passes through the server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                }

                VStack(alignment: .leading, spacing: 9) {
                    NodusSectionLabel("Reports")
                    NavigationLink {
                        ResearchLibraryView(session: session, local: local)
                    } label: {
                        // Both origins. Counting only the ones generated here read as "this
                        // vault has no reports" beside a vault with eighteen of them.
                        row(
                            icon: "books.vertical",
                            title: "All reports",
                            count: local.reports.count + publishedReports
                        )
                    }
                    .buttonStyle(NodusCardButtonStyle())
                }

                if session.hasImmersion {
                    VStack(alignment: .leading, spacing: 9) {
                        NodusSectionLabel("Immersion")
                        NavigationLink {
                            SpecialListView(session: session, resource: .immersion)
                        } label: {
                            row(icon: "waveform", title: "Sessions")
                        }
                        .buttonStyle(NodusCardButtonStyle())
                    }
                }

                if !session.hasDeepResearch, !session.hasImmersion {
                    Text("This space has published no reports or immersion sessions yet. You can generate one above.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(NodusSpace.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The only screen in the app that paints its own wash *and* is the root of a tab, so it
        // is the only one that has to say it does not need the bar reserved twice: the shell's
        // own backdrop, one container out, has already done it. This one is here for the iPad,
        // where there is no shell wrapper around a detail column — and no bar either.
        .nodusPageBackdrop(accent: session.accent, reservesBottomBar: false)
        .navigationTitle("Research")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingProviders = true } label: { Image(systemName: "key") }
                    .tint(session.accent)
            }
        }
        .nodusSheet(isPresented: $showingProviders) {
            ProviderSettingsView(accent: session.accent, requiredEmbedding: requiredEmbedding)
                .environment(ai)
                .nodusModalClose(accent: session.accent)
        }
    }

    /// The run this space has going, if any. Held outside every view, so this screen can be
    /// opened and closed without the report noticing.
    private var runner: DeepResearchRunner { DeepResearchRunner.shared(for: session.connection.spaceId) }

    /// The same row Home uses, in the same surface, at the same height.
    private func row(
        icon: String,
        title: LocalizedStringKey,
        subtitle: String? = nil,
        count: Int? = nil,
        isBusy: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(session.accent.nodusReadable)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            if isBusy {
                ProgressView().controlSize(.small).tint(session.accent)
            }
            if let count {
                CountBadge(count: count, accent: session.accent.nodusReadable)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: subtitle == nil ? 48 : 60)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nodusGlass(NodusGlass(.regular, tint: session.accent), in: NodusRadius.panelShape)
    }

    private var requiredEmbedding: EmbeddingIdentity? {
        if case .published(let identity) = session.embedding { return identity }
        return nil
    }
}

/// The Chat tab. Wraps `ChatScreen` with the key shortcut and the first-run prompt.
struct ChatTab: View {
    @Environment(AISettings.self) private var ai
    let session: SpaceSession

    @State private var showingProviders = false

    var body: some View {
        Group {
            if ai.configuredProviders.isEmpty {
                setupPrompt
            } else {
                // The chat's model menu offers the pinned models; everything else — the full
                // catalogue, the keys — is behind this sheet, which the tab owns.
                ChatScreen(session: session, openProviders: { showingProviders = true })
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingProviders = true } label: { Image(systemName: "key") }
                    .tint(session.accent)
            }
        }
        .nodusSheet(isPresented: $showingProviders) {
            ProviderSettingsView(accent: session.accent, requiredEmbedding: requiredEmbedding)
                .environment(ai)
                .nodusModalClose(accent: session.accent)
        }
    }

    private var requiredEmbedding: EmbeddingIdentity? {
        if case .published(let identity) = session.embedding { return identity }
        return nil
    }

    private var setupPrompt: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "sparkles")
                    .font(.system(size: 44))
                    .foregroundStyle(session.accent)
                Text("Bring your own model")
                    .font(.title3.weight(.semibold))
                Text("The server hands over the material and the budget; you choose the model. Your key is kept in this device's keychain and never passes through the Nodus Server.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    showingProviders = true
                } label: {
                    Label("Add a key", systemImage: "key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent))

                if case .published(let identity) = session.embedding, session.embedding.isReachableFromPhone {
                    NodusNotice(
                        tone: .info,
                        title: "For semantic search",
                        message: "This vault was indexed with \(identity.provider)/\(identity.model). With that key, retrieval will be semantic; without it, lexical.",
                        systemImage: "magnifyingglass"
                    )
                }
            }
            .padding(28)
        }
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
    }
}
