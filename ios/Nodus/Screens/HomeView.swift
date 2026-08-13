import NodusKit
import NodusUI
import SwiftUI

struct HomeView: View {
    let session: SpaceSession
    /// Switches the shell to the Research section rather than pushing a copy of it here.
    ///
    /// A tile that pushes the same screen the tab bar leads to gives you two of it, on two
    /// different navigation stacks, with a back button to a Home you are already looking at.
    /// The shell owns which section is open, so the shell is what this asks.
    var openResearch: (() -> Void)?

    @Environment(AppPreferences.self) private var preferences
    @Environment(OutboxTrayModel.self) private var tray

    var body: some View {
        ScrollView {
            // `NodusSpace.block` between blocks, not 16. The sections of this screen are
            // separate subjects — what the vault publishes, what you write, what you analyse —
            // and 16 points made them one long run of cards with occasional words in it.
            VStack(alignment: .leading, spacing: NodusSpace.block) {
                // Every vault type but academic is still being proved, and a reader should know
                // that before they trust a screen with their work rather than after.
                //
                // On its own line rather than in a row with the board/list switch: that switch
                // is in the header now, and what was left was an `HStack` holding one tag, a
                // `Spacer` and nothing — which on an academic vault was a whole empty row
                // before the screen began.
                if session.vaultType?.isAlpha == true {
                    VaultPhaseTag()
                }

                if !session.isPublished {
                    // Not an error. The space exists and this account can read it; its owner
                    // simply has not published yet, and the desktop is the only thing that can.
                    NodusNotice(
                        tone: .caution,
                        title: "This space has no publication yet",
                        message: "It will appear as soon as its owner publishes from Nodus desktop.",
                        systemImage: "tray"
                    )
                } else if let failure = session.loadFailure {
                    // The failure's own words, not "could not read the space": a laptop that
                    // went to sleep and a credential the server revoked are two different
                    // things to go and do, and this notice is where the reader learns which.
                    NodusNotice(
                        tone: failure.tone,
                        title: LocalizedStringKey(failure.title),
                        message: LocalizedStringKey(failure.sentence),
                        systemImage: failure.systemImage
                    )
                }

                if session.connection.role == .reader {
                    NodusNotice(
                        tone: .info,
                        title: "Read-only access",
                        message: "Anything you write or generate here stays on this device.",
                        systemImage: "eye"
                    )
                }

                embeddingNotice

                if !sections.isEmpty {
                    NodusGlassContainer(spacing: NodusSpace.card) {
                        // `Self.tileColumns`, not a fresh `[GridItem]` per body pass, and the
                        // same grid every other section on this screen uses.
                        LazyVGrid(columns: tileColumns, spacing: NodusSpace.card) {
                            ForEach(sections, id: \.path) { collection in
                                NavigationLink {
                                    CollectionListView(session: session, collection: collection)
                                } label: {
                                    let count = session.count(of: collection)
                                    SectionTile(
                                        title: LocalizedStringKey(collection.label),
                                        icon: collection.icon,
                                        count: count,
                                        accent: session.accent,
                                        isCountLoading: count == nil
                                            && (session.isLoading || session.loadFailure == nil)
                                    )
                                }
                                .buttonStyle(NodusCardButtonStyle())
                            }
                        }
                    }
                }

                // Screens a vault type deserves that are not just a table listing: a family
                // tree, a timetable, a deck of cards.
                if !vaultTools.isEmpty {
                    tileSection(toolsHeading) {
                        ForEach(vaultTools, id: \.title) { tool in
                            NavigationLink {
                                tool.destination()
                            } label: {
                                SectionTile(title: LocalizedStringKey(tool.title), icon: tool.icon, count: nil, accent: session.accent)
                            }
                            .buttonStyle(NodusCardButtonStyle())
                        }
                    }
                }

                // In the same grid as everything else, even alone. A single `NavigationLink`
                // outside a `LazyVGrid` stretches to the full width, and a lone stretched tile
                // among rows of square ones reads as a different kind of thing rather than as
                // the one item in its section.
                // Nodi's notes sit beside the queue rather than under Analyse, because both
                // are things you *write*. They are also the one tile here that is not about
                // this vault: Nodi follows the person, so the same notes are behind this tile
                // in every space.
                //
                // Which is exactly why the whole section is absent from the example vault:
                // Nodi follows the person and a demo has no person, and the queue needs
                // somewhere to send to. Both tiles could only ever end in an error.
                if !session.isDemo {
                    tileSection("Write") {
                        if session.connection.role.canSendChanges {
                            // A button rather than a link, because the queue is no longer a page
                            // inside this space: it is one sheet for the whole device, and it now
                            // carries a real count instead of the `nil` this tile used to pass.
                            Button {
                                tray.open()
                            } label: {
                                SectionTile(
                                    title: "Send queue",
                                    icon: "tray.and.arrow.up",
                                    count: tray.outbox.pending > 0 ? tray.outbox.pending : nil,
                                    accent: session.accent
                                )
                            }
                            .buttonStyle(NodusCardButtonStyle())
                        }
                        NavigationLink {
                            NodiNotesView(session: session)
                        } label: {
                            SectionTile(title: "Nodi’s notes", icon: "sparkles", count: nil, accent: session.accent)
                        }
                        .buttonStyle(NodusCardButtonStyle())
                        if session.hasNotes {
                            NavigationLink {
                                PublishedWorkspaceView(session: session)
                            } label: {
                                SectionTile(title: "Workspace", icon: "rectangle.stack", count: session.overview?.counts["notes"], accent: session.accent)
                            }
                            .buttonStyle(NodusCardButtonStyle())
                        }
                    }
                }

                if session.hasDebates || session.hasDeepResearch || session.hasImmersion {
                    tileSection("Analyse") {
                        if session.hasDebates {
                            specialTile(.debates, "Debates", "bubble.left.and.bubble.right")
                            // The same edges the debates come from, read as one argument
                            // instead of as a list of disagreements.
                            NavigationLink {
                                ArgumentMapView(session: session)
                            } label: {
                                SectionTile(title: "Argument map", icon: "arrow.triangle.branch", count: nil, accent: session.accent)
                            }
                            .buttonStyle(NodusCardButtonStyle())
                        }
                        if session.hasDeepResearch {
                            // Goes *to* the Research section rather than opening a second copy
                            // of it inside Home.
                            Button {
                                openResearch?()
                            } label: {
                                SectionTile(
                                    title: "Deep Research",
                                    icon: "doc.text.magnifyingglass",
                                    count: nil,
                                    accent: session.accent
                                )
                            }
                            .buttonStyle(NodusCardButtonStyle())
                            .disabled(openResearch == nil)
                        }
                        if session.hasImmersion {
                            specialTile(.immersion, "Immersion", "waveform")
                        }
                    }
                }

                // Last on the screen on purpose: what this space published is the subject, and
                // what only exists in this device's offline copy is a footnote to it.
                if !session.mirrorOnlyTables.isEmpty {
                    tileSection("More from this space") {
                        NavigationLink {
                            MirrorOnlySectionsView(session: session)
                        } label: {
                            SectionTile(
                                title: "Offline only",
                                icon: "internaldrive",
                                count: session.mirrorOnlyTables.reduce(0) { $0 + $1.count },
                                accent: session.accent
                            )
                        }
                        .buttonStyle(NodusCardButtonStyle())
                    }
                }

                if session.isPublished, session.sections.isEmpty, session.loadFailure == nil, !session.isLoading {
                    ContentUnavailableView(
                        "Empty publication",
                        systemImage: "square.dashed",
                        description: Text("This space's last publication carried no table with anything in it.")
                    )
                    .padding(.top, 40)
                }
            }
            .padding(.horizontal, NodusSpace.page)
            .padding(.vertical, NodusSpace.page)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nodusTopAnchor()
        }
        // Home is a board, not a list: it is one screen and a bit, and the indicator's only
        // effect was a grey bar running down the right edge of every tile a dozen points from
        // its corner. The long lists in the app keep theirs, because there the position of the
        // thumb in nine thousand rows is worth knowing.
        .scrollIndicators(.hidden)
        .nodusPageFunctions(accent: session.accent)
        .refreshable { await session.load() }
    }

    /// A headed section whose contents sit in the one grid this screen uses.
    ///
    /// Every tile on Home is the same size — that is what makes the screen read as one board
    /// rather than as several lists — so the grid is defined once and every section goes
    /// through it, including the ones that hold a single tile.
    /// A section name has to be recognisable as a section name from across the screen and must
    /// not read as the most important thing on it.
    ///
    /// "Write" and "Analyse" were `subheadline.semibold` in the primary colour — a hair heavier
    /// than the tile titles under them and the same size, so they read as one more row that
    /// happened to have no card. Smaller, in the second level of text, with the letters opened
    /// out and real space above it: a label on the group rather than a member of it.
    @ViewBuilder
    private func tileSection<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            NodusSectionLabel(title)
            LazyVGrid(columns: tileColumns, spacing: NodusSpace.card) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One column when the screen is in list form, two or more when it is a board.
    ///
    /// Every section on Home goes through this, which is what keeps the two layouts honest:
    /// the toggle changes the shape of the whole screen rather than of one grid on it.
    private var tileColumns: [GridItem] {
        switch preferences.homeLayout {
        case .grid: return [GridItem(.adaptive(minimum: 150), spacing: NodusSpace.card)]
        case .list: return [GridItem(.flexible(), spacing: NodusSpace.card)]
        }
    }

    /// Read once per body pass rather than three times.
    ///
    /// `session.sections` sorts the whole published menu on every access, and the grid asked
    /// for it in the `if`, in the `ForEach` and again on every diff.
    private var sections: [CollectionDescriptor] {
        session.sections.filter { !toolCoveredPaths.contains($0.path) }
    }

    struct VaultTool {
        let title: String
        let icon: String
        let destination: () -> AnyView
    }

    /// A `LocalizedStringKey`, not a `String`. `Text(someString)` does not localise — only a
    /// literal does — so a computed heading returned as a plain `String` would show the same
    /// words on every phone regardless of its language, which is exactly what these four did.
    private var toolsHeading: LocalizedStringKey {
        switch session.vaultType {
        case .genealogy, .prosopography: return "Kinship"
        case .estudio: return "Study"
        case .docencia: return "Teaching"
        default: return "Tools"
        }
    }

    /// What each vault type gets beyond its tables, gated on the publication actually having
    /// the rows — a timetable tile over an empty timetable is worse than no tile.
    /// Collections that have a screen of their own under the vault's tools.
    ///
    /// A study or teaching vault publishes `study_flashcards` and `study_questions` as tables
    /// *and* has a purpose-built screen for each — a deck you tap to turn over, a question bank
    /// you work through. Offered twice they were two tiles with the same name, and the first
    /// attempt at fixing it dropped the wrong one: the tool went and the generic row list
    /// stayed, so the deck became unreachable. The tool wins; the table tile is what goes.
    private var toolCoveredPaths: Set<String> {
        let counts = session.overview?.counts ?? [:]
        var covered: Set<String> = []
        if (counts["study_flashcards"] ?? 0) > 0 { covered.insert("study-flashcards") }
        if (counts["study_questions"] ?? 0) > 0 { covered.insert("study-questions") }
        return covered
    }

    private var vaultTools: [VaultTool] {
        var tools: [VaultTool] = []
        let counts = session.overview?.counts ?? [:]

        if (counts["persons"] ?? 0) > 0, (counts["relationships"] ?? 0) > 0 {
            tools.append(VaultTool(title: "Family tree", icon: "tree") {
                AnyView(FamilyTreeView(session: session))
            })
        }
        // The two tables that carry a moment in time. One tile for both, because "what have I
        // got on" is one question and the vault answers it from wherever it happens to have
        // written it down.
        if (counts["study_calendar_events"] ?? 0) > 0 || (counts["study_plan_blocks"] ?? 0) > 0 {
            tools.append(VaultTool(title: "Agenda", icon: "calendar.badge.clock") {
                AnyView(AgendaView(session: session))
            })
        }
        if (counts["study_goals"] ?? 0) > 0 {
            tools.append(VaultTool(title: "Goals", icon: "target") {
                AnyView(GoalsView(session: session))
            })
        }
        if (counts["study_schedule_cells"] ?? 0) > 0 {
            tools.append(VaultTool(title: "Timetables", icon: "calendar") {
                AnyView(ScheduleView(session: session))
            })
        }
        // Both of these are also published *tables*, so a vault that has them was offering two
        // tiles with the same name — one opening the study screen, one opening a generic list —
        // and no way to tell which was which. The purpose-built screen wins; the collection tile
        // above it is what would be redundant.
        if (counts["study_flashcards"] ?? 0) > 0 {
            tools.append(VaultTool(title: "Flashcards", icon: "rectangle.on.rectangle") {
                AnyView(FlashcardsView(session: session))
            })
        }
        if (counts["study_questions"] ?? 0) > 0 {
            tools.append(VaultTool(title: "Question bank", icon: "checklist") {
                AnyView(QuestionBankView(session: session))
            })
        }
        return tools
    }

    private func specialTile(_ resource: SpecialResource, _ title: String, _ icon: String) -> some View {
        NavigationLink {
            SpecialListView(session: session, resource: resource)
        } label: {
            SectionTile(title: LocalizedStringKey(title), icon: icon, count: nil, accent: session.accent)
        }
        .buttonStyle(NodusCardButtonStyle())
    }

    /// The vault's embedding identity, stated plainly — including when this device can never
    /// match it. A phone cannot reach Ollama or LM Studio on somebody's desktop, and saying so
    /// beats a search that silently returns nothing.
    @ViewBuilder
    private var embeddingNotice: some View {
        switch session.embedding {
        case .published(let identity) where !session.embedding.isReachableFromPhone:
            NodusNotice(
                tone: .caution,
                title: "Semantic search is not available here",
                message: "This vault was indexed with \(identity.provider)/\(identity.model), which runs on the computer where Nodus lives. From a phone, search will be lexical.",
                systemImage: "desktopcomputer"
            )
        case .noVectors:
            NodusNotice(
                tone: .info,
                title: "No published vectors",
                message: "Search will be lexical until the space's owner publishes the embeddings.",
                systemImage: "magnifyingglass"
            )
        default:
            EmptyView()
        }
    }
}

struct SectionTile: View {
    let title: LocalizedStringKey
    let icon: String
    let count: Int?
    let accent: Color
    var isCountLoading = false

    @Environment(AppPreferences.self) private var preferences
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Two shapes, one surface.
    ///
    /// A square tile stacked in a single column is mostly empty card with a name at the
    /// bottom, so the list form is not the grid form stretched — it is a row: the icon
    /// leading, the name reading across, the count trailing, and half the height.
    /// Not `interactive`. Every tile on this screen goes somewhere, so lighting the ones that do
    /// would light all of them — which is where the app started. The chevron says a row goes;
    /// `NodusCardButtonStyle` at the call site says it is being pressed.
    var body: some View {
        Group {
            switch preferences.homeLayout {
            case .grid: square
            case .list: row
            }
        }
        .nodusGlass(NodusGlass(.regular, tint: accent), in: NodusRadius.panelShape)
    }

    private var square: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: icon)
                    .font(Self.glyph)
                    .foregroundStyle(accent.nodusReadable)
                Spacer()
                countAccessory
            }
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(13)
        // A minimum rather than a fixed height: at the larger Dynamic Type sizes a two-line
        // title needs more than 84 points, and a tile that clips its own name is worse than a
        // row of tiles that are not quite the same height.
        .frame(minHeight: 84, alignment: .topLeading)
    }

    /// The list form, at the height a row of a list should be.
    ///
    /// 56 points is a comfortable row on a screen with six of them and a lot of screen on a
    /// phone with fourteen — Home in list form on an academic vault runs to two and a half
    /// screens of them. 48 is still well past the 44-point minimum and fits two more in a view.
    private var row: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(Self.glyph)
                .foregroundStyle(accent.nodusReadable)
                .frame(width: 24)
            Text(title)
                .font(.subheadline.weight(.medium))
                // One line at the ordinary sizes, where every section name fits and a row that
                // wraps looks broken. At the accessibility sizes nothing fits, and a menu entry
                // reading "Árbol genealó…" is a menu entry nobody can use.
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                // Without this the row proposes its own 48 points to the text and the text
                // takes them: a name allowed three lines is drawn on three lines and clipped
                // after the first.
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            countAccessory
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
    }

    @ViewBuilder
    private var countAccessory: some View {
        if isCountLoading {
            LoadingCountArrow(accent: accent.nodusReadable)
        } else if let count {
            CountBadge(count: count, accent: accent.nodusReadable)
        }
    }

    /// One size and one weight for a tile glyph. `.title3` grows to 26 points under Dynamic
    /// Type, which is what turned a 56-point row into an 80-point one and pushed the count off
    /// the end of it.
    private static let glyph: Font = .system(size: 19, weight: .regular)
}

/// Holds the count's place while the Home overview is in flight.
///
/// This is deliberately an arrow rather than an indeterminate `ProgressView`: the glyph says
/// that this particular count is being refreshed, while a spinner inside every tile makes the
/// entire board look busy and noisy. Its capsule has the same dimensions as a short count, so
/// the title and chevron do not move when the number arrives.
private struct LoadingCountArrow: View {
    let accent: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTurning = false

    var body: some View {
        Image(systemName: "arrow.clockwise")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(accent)
            .rotationEffect(.degrees(isTurning && !reduceMotion ? 360 : 0))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(accent.opacity(0.16), in: Capsule())
            .animation(
                reduceMotion ? nil : .linear(duration: 0.85).repeatForever(autoreverses: false),
                value: isTurning
            )
            .onAppear { isTurning = true }
            .onDisappear { isTurning = false }
            .accessibilityLabel("Loading…")
    }
}
