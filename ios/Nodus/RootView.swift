import NodusKit
import NodusUI
import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()
    @State private var ai = AISettings()
    @State private var lock = AppLock()
    @State private var preferences = AppPreferences()
    @State private var tilt = DeviceTiltProvider()
    @State private var showingConnect = false

    var body: some View {
        Group {
            if let session = model.session {
                SpaceShell(session: session)
            } else {
                SpacePickerView(showingConnect: $showingConnect)
            }
        }
        // Over everything, including any sheet: a settings screen presented before the app went
        // away must not be readable through the lock.
        .overlay {
            if lock.isLocked {
                LockScreen(lock: lock)
            } else if lock.isEnabled, scenePhase == .inactive {
                // The multitasking snapshot is taken here. Without this it would show the
                // corpus, which makes the lock decorative.
                PrivacyCover()
            }
        }
        .environment(model)
        .environment(ai)
        .environment(lock)
        .environment(preferences)
        .detectingScreenCutout()
        .nodusTiltDriven(tilt)
        .sheet(isPresented: $showingConnect) { ConnectView().environment(model) }
        .task {
            // Reopen where the user left off, but only if the credential is still there — a
            // revoked token should land on the picker, not on a broken shell.
            if model.session == nil, let recent = model.mostRecent {
                model.open(recent)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            // Immediately, with no grace period. A window in which the app reopens unlocked is
            // a window somebody else can use.
            lock.lock()
            // The moment work stops being foreground work is the moment to ask iOS to finish
            // it. Asking earlier is refused — the scheduler will not accept a request from an
            // app that is on screen.
            Task { await BackgroundWork.scheduleWhatIsPending() }
        }
    }
}

/// The list of spaces this device holds a credential for.
struct SpacePickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppPreferences.self) private var preferences
    @Binding var showingConnect: Bool

    @State private var query = ""
    @State private var vaultFilter: VaultType?

    private let accent = Color(hex: VaultType.academic.accentHex)

    /// Search, filter and order are offered from two connections up.
    ///
    /// One space needs no searching and no ordering, and a filter over a list of one is a
    /// control that can only ever hide the single thing on screen.
    private var offersFinding: Bool { model.connections.count > 1 }

    /// The vault types actually present. Offering the nine the app knows about, when this
    /// device holds two academic spaces, is offering seven ways to empty the list.
    private var availableTypes: [VaultType] {
        let present = Set(model.connections.compactMap(\.vaultType))
        return VaultType.allCases.filter { present.contains($0) }
    }

    private var visible: [AppModel.Connection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Ordered by the *stored* position first, because that is the order they were added in
        // and it is the fallback for a connection made before `addedAt` existed.
        let ordered = model.connections.enumerated().sorted { left, right in
            switch preferences.spaceOrder {
            case .recentlyUsed:
                return (left.element.lastOpenedAt ?? .distantPast) > (right.element.lastOpenedAt ?? .distantPast)
            case .recentlyAdded:
                guard let leftDate = left.element.addedAt, let rightDate = right.element.addedAt else {
                    return left.offset > right.offset
                }
                return leftDate > rightDate
            case .name:
                return left.element.spaceName.localizedStandardCompare(right.element.spaceName) == .orderedAscending
            }
        }
        return ordered.map(\.element).filter { connection in
            guard vaultFilter == nil || connection.vaultType == vaultFilter else { return false }
            guard !needle.isEmpty else { return true }
            // The three names a person would type: the space, the server it lives on, and the
            // vault behind it, which is not always the space's own name.
            return [connection.spaceName, connection.serverName, connection.vaultName ?? ""]
                .contains { $0.lowercased().contains(needle) }
        }
    }

    var body: some View {
        ZStack {
            NodusBackdrop(accent: accent)
            ScrollView {
                VStack(spacing: 18) {
                    masthead

                    if let stranded = model.needsSignIn {
                        signInAgainNotice(stranded)
                    }

                    if offersFinding { finding }

                    if model.hasAnyConnection {
                        if visible.isEmpty {
                            ContentUnavailableView(
                                "No spaces match",
                                systemImage: "line.3.horizontal.decrease.circle",
                                description: Text("Nothing here answers to that name or that vault type.")
                            )
                        } else {
                            VStack(spacing: 10) {
                                ForEach(visible) { connection in
                                    card(connection)
                                }
                            }
                        }
                    } else {
                        NodusNotice(
                            tone: .info,
                            title: "No spaces yet",
                            message: "Connect to the Nodus Server where your vault is published.",
                            systemImage: "antenna.radiowaves.left.and.right"
                        )
                    }

                    Button {
                        showingConnect = true
                    } label: {
                        Label("Add a server", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NodusPrimaryButtonStyle(accent: accent))
                }
                // `NodusSpace.page`, the same margin every other screen uses. This one was 20
                // and the rest were 16, which is exactly the kind of four points nobody can
                // name and everybody feels when they move between two screens.
                .padding(.horizontal, NodusSpace.page)
                .padding(.bottom, 24)
                // A 13-inch iPad is not a very wide iPhone. Stretching a list of four
                // connections across 1 000 points gives rows that are mostly empty and a line
                // length nobody reads comfortably.
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .nodusDismissesKeyboard()
        }
    }

    /// The mark, the name and the line under it.
    ///
    /// It used to open with 50 points of padding under a navigation bar that is not there, and
    /// an 84-point mark: on a phone that is a third of the screen spent before the first thing
    /// you came for. It shrinks when there is a list to get to, because at that point the
    /// masthead is a heading and not a title page — and it keeps its full size when the list is
    /// empty, where it is the only thing on screen.
    private var masthead: some View {
        VStack(spacing: model.hasAnyConnection ? 6 : 12) {
            NodusMark(style: .brand)
                .frame(width: model.hasAnyConnection ? 54 : 84, height: model.hasAnyConnection ? 54 : 84)
            Text("Nodus")
                .font(model.hasAnyConnection ? .title2.weight(.semibold) : .largeTitle.weight(.semibold))
            Text("Your vaults, wherever you are.")
                .font(model.hasAnyConnection ? .caption : .subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, model.hasAnyConnection ? 10 : 40)
    }

    private func card(_ connection: AppModel.Connection) -> some View {
        // Asked once per card rather than assumed: a connection whose token is gone opens
        // nothing, and the card says so instead of being a button that does nothing.
        let usable = model.hasCredential(for: connection)
        return Button {
            if !usable || !model.open(connection) { showingConnect = true }
        } label: {
            ConnectionCard(connection: connection, needsSignIn: !usable)
        }
        .buttonStyle(NodusCardButtonStyle())
        .contextMenu {
            Button(role: .destructive) {
                model.forget(connection)
            } label: {
                Label("Forget", systemImage: "trash")
            }
        }
    }

    /// Said out loud, once, at the top: the server refused the credential this device held.
    private func signInAgainNotice(_ connection: AppModel.Connection) -> some View {
        VStack(spacing: 10) {
            NodusNotice(
                tone: .caution,
                title: "Sign in again",
                message: "The server no longer accepts this device's credential for “\(connection.spaceName)”. Adding the server again restores it.",
                systemImage: "key.slash"
            )
            HStack(spacing: 10) {
                Button("Add the server again") { showingConnect = true }
                    .buttonStyle(NodusGlassButtonStyle(accent: accent))
                Button("Dismiss") { model.clearSignInNotice() }
                    .font(.subheadline)
                    .tint(.secondary)
            }
        }
    }

    /// The search field, and the two controls under it centred beneath it.
    ///
    /// Two chips pinned to the left edge of a 560-point column read as the start of a toolbar
    /// that never arrives. Centred, they read as what they are: a pair of choices about the
    /// list below.
    private var finding: some View {
        VStack(spacing: 10) {
            NodusSearchField(text: $query, prompt: "Search spaces", accent: accent)
            HStack(spacing: 10) {
                Menu {
                    Picker("Order", selection: Binding(
                        get: { preferences.spaceOrder },
                        set: { preferences.spaceOrder = $0 }
                    )) {
                        ForEach(AppPreferences.SpaceOrder.allCases) { order in
                            Label(order.label, systemImage: order.systemImage).tag(order)
                        }
                    }
                } label: {
                    controlLabel(preferences.spaceOrder.label, systemImage: "arrow.up.arrow.down")
                }

                if availableTypes.count > 1 {
                    Menu {
                        Button { vaultFilter = nil } label: {
                            Label("Every kind", systemImage: vaultFilter == nil ? "checkmark" : "square.stack.3d.up")
                        }
                        ForEach(availableTypes, id: \.self) { type in
                            Button { vaultFilter = type } label: {
                                Label(type.localizedName, systemImage: vaultFilter == type ? "checkmark" : "circle")
                            }
                        }
                    } label: {
                        controlLabel(vaultFilter.map { LocalizedStringKey($0.localizedName) } ?? "Every kind", systemImage: "line.3.horizontal.decrease")
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func controlLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.caption2)
            Text(title).font(.caption).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .nodusGlass(NodusGlass(.thin, tint: accent, interactive: true), in: Capsule())
        .foregroundStyle(.primary)
    }
}

extension VaultType {
    /// What a vault type is called on screen, in the desktop's own vocabulary.
    ///
    /// `String(localized:)` per case rather than a `LocalizedStringKey`, because this is read
    /// twice and one of the readings interpolates it into a line of data — "Nodus Server ·
    /// Academic · owner". A key cannot be interpolated; a plain `String` built from `rawValue`
    /// would ship in English on every phone. The same shape `RowPresenter.kinship` uses.
    var localizedName: String {
        switch self {
        case .academic: return String(localized: "Academic")
        case .primarySources: return String(localized: "Primary sources")
        case .testimonios: return String(localized: "Oral history")
        case .databases: return String(localized: "Databases")
        case .docencia: return String(localized: "Teaching")
        case .estudio: return String(localized: "Study")
        case .genealogy: return String(localized: "Genealogy")
        case .prosopography: return String(localized: "Prosopography")
        case .worldbuilding: return String(localized: "Worldbuilding")
        }
    }
}

private struct ConnectionCard: View {
    let connection: AppModel.Connection
    /// This device has no credential for the space any more. The card still belongs on the
    /// list — the server address is worth keeping — but it opens the sign-in flow, not a vault,
    /// and it has to look like it.
    var needsSignIn = false

    var body: some View {
        HStack(spacing: 13) {
            NodusMark(style: .accent(connection.accent)).frame(width: 38, height: 38)
                .opacity(needsSignIn ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(connection.spaceName).font(.subheadline.weight(.semibold))
                    // Said here as well as on Home, because this is where a space is chosen.
                    // Not tappable inside a card that is itself a button: the explanation is
                    // one tap further in, on the space's own screen.
                    if connection.vaultType?.isAlpha == true, !needsSignIn {
                        VaultPhaseTag(explains: false)
                    }
                }
                if needsSignIn {
                    Label("Sign in again", systemImage: "key.slash")
                        .font(.caption).foregroundStyle(Color.nodusCaution)
                        .lineLimit(1)
                } else {
                    // Server · kind · role. The kind is what tells two spaces on the same
                    // server apart at a glance, and it is the one of the three that decides
                    // what the app will show once it opens.
                    Text(verbatim: [connection.serverName, connection.vaultType?.localizedName, roleLabel]
                        .compactMap { $0 }
                        .joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                        // Three names on one line is a tight fit on a phone, and the one that
                        // gets cut is the last — the role. Shrinking a little beats truncating
                        // the third of the three that the reader asked to see.
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(NodusSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A row that goes somewhere, not a control that acts: the chevron says so and
        // `NodusCardButtonStyle` gives under the thumb. Five of these stacked, each with a lit
        // edge and a coloured glow, was the space picker's whole problem.
        .nodusGlass(NodusGlass(.regular, tint: needsSignIn ? Color.nodusCaution : connection.accent))
    }

    /// `String(localized:)`: interpolated into a line of data, so it reaches `Text` as a value
    /// and would otherwise stay English on a Spanish phone.
    private var roleLabel: String {
        switch connection.role {
        case .reader: return String(localized: "read")
        case .writer: return String(localized: "write")
        case .owner: return String(localized: "owner")
        }
    }
}

#Preview {
    RootView()
}
