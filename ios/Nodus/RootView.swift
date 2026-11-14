import NodusKit
import NodusUI
import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var systemTextSize
    @State private var model = AppModel()
    @State private var ai = AISettings()
    @State private var lock = AppLock()
    @State private var preferences = AppPreferences()
    @State private var tilt = DeviceTiltProvider()
    @State private var showingConnect = false
    @State private var didRestoreSession = false
    @State private var pairingLink: String?
#if DEBUG
    @State private var recoveryFixtureReady = ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_AUTHORING_RECOVERY"] == nil
    @State private var recoveryFixtureIssue: String?
#endif
    /// The queue belongs to the device rather than to a space, so it lives above the branch
    /// that decides whether a space is open at all.
    @State private var tray = OutboxTrayModel()
    /// The one state object that is a singleton rather than owned here: the two stores that feed
    /// it are not views. Put in the environment all the same, so a settings screen reads it the
    /// way it reads everything else.
    private let cloud = CloudBackup.shared

    private var effectiveTextSize: DynamicTypeSize {
#if DEBUG
        if ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] == "accessibility3" { return .accessibility3 }
#endif
        return systemTextSize
    }

    @ViewBuilder private var rootContent: some View {
        if let session = model.session {
            SpaceShell(session: session)
        } else if model.isOpeningLocalCorpus {
            ProgressView("Abriendo el vault…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("nodus-opening-corpus")
        } else {
            SpacePickerView(showingConnect: $showingConnect)
        }
    }

    var body: some View {
        Group {
#if DEBUG
            if let issue = recoveryFixtureIssue {
                Text(issue).accessibilityIdentifier("recovery-fixture-error")
            } else if !recoveryFixtureReady {
                ProgressView("Preparing isolated recovery fixture")
            } else {
                rootContent
            }
#else
            rootContent
#endif
        }

        .allowsHitTesting(!model.isClosingDesktopGrant)
        // Over everything, including any sheet: a settings screen presented before the app went
        // away must not be readable through the lock.
        .overlay {
            if lock.isLocked {
                LockScreen(lock: lock)
            } else if model.isClosingDesktopGrant {
                ZStack {
                    NodusBackdrop(accent: Color(hex: VaultType.academic.accentHex))
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Conservando tu trabajo local…")
                        Text("El Mac ha cerrado el enlace. Esperamos a que el trabajo iniciado termine de guardarse.").font(.footnote).multilineTextAlignment(.center)
                    }.padding(NodusSpace.page)
                }
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
        .environment(tray)
        .environment(cloud)
        .nodusTextHierarchy()
        .preferredColorScheme(preferences.interfaceStyle.colorScheme)
        .detectingScreenCutout()
        .nodusTiltDriven(tilt)
        // Once, here, for every field in the app — including the ones inside sheets, which are
        // presented into this same window.
        .nodusDismissesKeyboardOnTap()
        .nodusSheet(isPresented: $showingConnect) { ConnectView().environment(model).dynamicTypeSize(effectiveTextSize) }
        .sheet(isPresented: Binding(get: { pairingLink != nil }, set: { if !$0 { pairingLink = nil } })) {
            DesktopBridgePairingSheet(accent: model.session?.accent ?? Color(hex: VaultType.academic.accentHex), initialLink: pairingLink ?? "") { pairingLink = nil }.environment(model).dynamicTypeSize(effectiveTextSize)
        }
        .onOpenURL { url in if url.scheme == "nodus", url.host == "pair" { pairingLink = url.absoluteString } }
        // Attached here, above the branch, so one sheet serves both the picker and whatever
        // space happens to be open. Presenting it from inside `SpaceShell` would put it behind
        // that shell's own sheets, and iOS fails a second presentation silently.
        .nodusSheet(isPresented: $tray.isPresented) {
            OutboxTraySheet()
                .environment(tray)
                .environment(model)
                .dynamicTypeSize(effectiveTextSize)
                // The open space's colour when there is one; the queue is also reachable from
                // the picker, where no vault is open to lend one.
                .nodusModalClose(accent: model.session?.accent ?? Color(hex: VaultType.academic.accentHex))
        }
        .dynamicTypeSize(effectiveTextSize)
        .task {
            // Changing the root branch can start this task again. Restoration belongs
            // to launch; closing a workspace must leave its chooser open, also offline.
            guard !didRestoreSession else { return }
            didRestoreSession = true
#if DEBUG
            if ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_AUTHORING_RECOVERY"] != nil {
                do { try await model.prepareAuthoringRecoveryAcceptance(); recoveryFixtureReady = true }
                catch { recoveryFixtureIssue = error.localizedDescription }
                return
            }
            if let filename = ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_SNAPSHOT_FILENAME"] {
                do { try await model.openAcceptanceSnapshot(filename) }
                catch { model.reportAcceptanceFailure(error) }
                return
            }
            if let link = ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_PAIRING_LINK"] {
                pairingLink = link
                return
            }
            // UI and visual-parity tests always start from the bundled public-domain fixture.
            // This bypasses persisted connections without adding any test credential or
            // production-data path to the app.
            if ProcessInfo.processInfo.environment["NODUS_UI_TEST_DEMO"] == "1" {
                // Sidebar state is deliberately durable in production. Visual tests need the
                // opposite guarantee: a previous test tapping the collapse control must not
                // turn the next Desktop comparison into an icon-only sidebar.
                preferences.sidebarCollapsed = false
                preferences.sidebarWidth = 176
                preferences.sidebarOrder = []
                preferences.sidebarHidden = []
                preferences.sidebarCustomized = false
                if let rawStyle = ProcessInfo.processInfo.environment["NODUS_INTERFACE_STYLE"],
                   let style = AppPreferences.InterfaceStyle(rawValue: rawStyle) {
                    preferences.interfaceStyle = style
                }
                await model.openDemo()
                if ProcessInfo.processInfo.environment["NODUS_SHOW_SYNC_CENTER"] == "1" {
                    tray.open()
                }
                return
            }
#endif
            // Reopen where the user left off, but only if the credential is still there — a
            // revoked token should land on the picker, not on a broken shell.
            if model.session == nil, let recent = model.mostRecent {
                if recent.isDemo {
                    await model.openDemo()
                } else {
                    model.open(recent)
                }
            }
            // A sleeping Mac must not hold downloaded reading and authored work
            // behind the catalogue request's network timeout. Opening checks the
            // saved grant locally; the refresh still handles remote revocation.
            await model.refreshDesktopWorkspaceCatalogues()
            // Which of this device's files a backup carries, decided in one place and applied
            // to whatever is already on disk. Detached because it is `setxattr` per file and
            // this is the launch path; nothing on screen waits for the answer.
            Task.detached(priority: .utility) {
                BackupPolicy.apply(toSpacesDirectory: URL.applicationSupportDirectory
                    .appendingPathComponent("spaces", isDirectory: true))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: DesktopBridgePairingStore.authorizationRevokedNotification)) { event in
            if let pairingId = event.object as? String { Task { await model.handleDesktopAuthorizationRevocation(pairingId: pairingId) } }
        }
        .task {
#if DEBUG
            guard ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_AUTHORING_RECOVERY"] == nil else { return }
#endif
            while !Task.isCancelled {
                if scenePhase == .active { await model.refreshDesktopWorkspaceCatalogues() }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
#if DEBUG
            guard ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_AUTHORING_RECOVERY"] == nil else { return }
#endif
            // Coming back is when the answer may have changed: the background flush may have
            // finished a send while the app was away, and — the other half of the same
            // question — somebody may have opened their desktop and collected it. It is a
            // handful of SQLite opens and, only for spaces actually holding changes in a
            // ledger, one request each.
            if phase != .active { model.stopLinkedMacDiscovery() }
            if phase == .active {
                Task { await tray.confirmDeliveries() }
                Task { await model.refreshDesktopWorkspaceCatalogues() }
                // Coming back is also when another device may have written a report or a chat.
                // Returns on the first line unless the user switched the iCloud copy on.
                Task { await cloud.refresh() }
                // Do not wait for the foreground polling interval after an edit was made on
                // the desktop while this app was suspended.
                if let session = model.session {
                    Task { await session.refreshPublishedContent() }
                }
            }

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
    @Environment(OutboxTrayModel.self) private var tray
    @Binding var showingConnect: Bool

    @State private var query = ""
    @State private var vaultFilter: VaultType?
    /// The connection whose diagnostics are open, presented from the notice above the list.
    @State private var diagnosing: AppModel.Connection?
    @State private var savedWork: [PrivateBridgeAuthoringRecovery.ArchiveInfo] = []
    @State private var showingSavedWork = false

    private let accent = Color(hex: VaultType.academic.accentHex)

    /// Search, filter and order are offered from two connections up.
    ///
    /// One space needs no searching and no ordering, and a filter over a list of one is a
    /// control that can only ever hide the single thing on screen.
    private var offersFinding: Bool { model.linkConnections.count > 1 }

    /// The vault types actually present. Offering the nine the app knows about, when this
    /// device holds two academic spaces, is offering seven ways to empty the list.
    private var availableTypes: [VaultType] {
        let present = Set(model.linkConnections.compactMap(\.vaultType))
        return VaultType.allCases.filter { present.contains($0) }
    }

    private var visible: [AppModel.Connection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Ordered by the *stored* position first, because that is the order they were added in
        // and it is the fallback for a connection made before `addedAt` existed.
        let ordered = model.linkConnections.enumerated().sorted { left, right in
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

                    // Above the spaces rather than inside one of them: what is queued is a fact
                    // about this device, and the picker is the only screen that belongs to the
                    // device rather than to a vault.
                    if !NodusLinkPolicy.readOnly && tray.outbox.hasAnything { queueControl }
                    if !savedWork.isEmpty {
                        Button { showingSavedWork = true } label: {
                            Label("Trabajo guardado", systemImage: "doc.text")
                                .frame(minHeight: 44).contentShape(Rectangle())
                        }.accessibilityIdentifier("saved-local-work")
                    }

                    if let issue = model.desktopRecoveryIssue {
                        NodusNotice(tone: .blocked, title: "Trabajo local conservado", message: LocalizedStringKey(issue), systemImage: "doc.text")
                    }
                    if let stranded = model.needsSignIn {
                        signInAgainNotice(stranded)
                    }

                    // Beside the sign-in notice, and for the same reason: somebody who lands
                    // back here after a space failed to open should be told why by the screen
                    // they are looking at, not by the one they have just left.
                    if let (connection, failure) = model.lastFailure {
                        unreachableNotice(connection, failure)
                    }

                    // A separate notice from the one above, because it is a separate kind of
                    // fault: no network and no credential are involved, and nothing the reader
                    // can do fixes it — the corpus the build was supposed to carry is not there.
                    if let failure = model.demoFailure {
                        NodusNotice(
                            tone: .blocked,
                            title: "Could not open the example vault",
                            message: LocalizedStringKey(failure),
                            systemImage: "shippingbox"
                        )
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
                            message: "Link your desktop Nodus with a code or QR to access your workspace in real time.",
                            systemImage: "antenna.radiowaves.left.and.right"
                        )
                    }

                    if !model.hasAnyConnection { linkControl }

                    if !hasDemo { exampleVaultButton }
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.hasAnyConnection {
                linkControl
                    .frame(maxWidth: 560)
                    .padding(.horizontal, NodusSpace.page)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background { NodusBackdrop(accent: accent) }
            }
        }
        .task { savedWork = (try? await PrivateBridgeAuthoringRecovery.shared.allSummaries()) ?? [] }
        .nodusSheet(isPresented: $showingSavedWork) {
            NavigationStack {
                List {
                    Section {
                        ForEach(savedWork) { archive in RecoveredAuthoringArchiveRow(archive: archive) }
                    } footer: { Text("Puedes exportar tu trabajo sin conexión. Enlaza el mismo Mac para recuperarlo y revisar los cambios antes de enviarlos.") }
                }
                .navigationTitle("Trabajo guardado")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSavedWork = false } } }
            }
        }
        .nodusSheet(item: $diagnosing) { connection in
            // Its own stack: the picker has no navigation bar of its own, and the screen needs
            // a title and a "run again" control.
            NavigationStack {
                ConnectionDiagnosticsView(connection: connection)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { diagnosing = nil }
                        }
                    }
            }
            .environment(model)
            .nodusModalClose(accent: connection.accent)
        }
    }

    /// Linking is the primary companion action, even when the workspace contains many vaults.
    private var linkControl: some View {
        Button { showingConnect = true } label: {
            Label("Link Nodus", systemImage: "qrcode").frame(maxWidth: .infinity)
        }
        .buttonStyle(NodusPrimaryButtonStyle(accent: accent))
        .accessibilityIdentifier("nodus-add-server")
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

    /// Whether the example vault is already on the list, in which case its card is the way in
    /// and a second button beside it would be the same door twice.
    private var hasDemo: Bool { model.connections.contains(where: \.isDemo) }

    /// The way in for somebody with no server.
    ///
    /// Under "Add a server" rather than above it, and quieter than it: connecting a vault is
    /// still what this app is for, and this is the answer to "what does it look like?" — a
    /// question that has to be answerable before the first one is worth asking.
    private var exampleVaultButton: some View {
        VStack(spacing: 6) {
            Button {
                Task { await model.openDemo() }
            } label: {
                Label("See an example vault", systemImage: "books.vertical")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NodusGlassButtonStyle(accent: accent))
            .accessibilityHint("Opens a small read-only corpus stored in the app. No account and no connection.")

            Text("A read-only corpus that ships with the app. No account, no server, works offline.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func card(_ connection: AppModel.Connection) -> some View {
        // Asked once per card rather than assumed: a connection whose token is gone opens
        // nothing, and the card says so instead of being a button that does nothing.
        let usable = model.hasCredential(for: connection)
        return Button {
            if connection.isDemo {
                Task { await model.openDemo() }
            } else if !usable || !model.open(connection) {
                showingConnect = true
            }
        } label: {
            ConnectionCard(connection: connection, needsSignIn: !usable)
        }
        .buttonStyle(NodusCardButtonStyle())
        .accessibilityIdentifier("space-\(connection.vaultId ?? connection.spaceId)")
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

    /// The last server that could not be reached, in the failure's own words.
    ///
    /// No retry button. A classified failure is shown once and the user decides: the computer
    /// they need is asleep in another room, and an app that keeps knocking on its own is an app
    /// that spends a battery saying the same thing.
    private func unreachableNotice(_ connection: AppModel.Connection, _ failure: ConnectionFailure) -> some View {
        // Built as a `String` and then wrapped: `LocalizedStringKey("\(a) — \(b)")` would go
        // looking for a catalogue entry called "%@ — %@", and both halves are already
        // translated by the time they get here.
        let message = "\(connection.spaceName) — \(failure.sentence)"
        return VStack(spacing: 10) {
            NodusNotice(
                tone: failure.tone,
                title: LocalizedStringKey(failure.title),
                message: LocalizedStringKey(message),
                systemImage: failure.systemImage
            )
            HStack(spacing: 10) {
                Button("What went wrong") { diagnosing = connection }
                    .buttonStyle(NodusGlassButtonStyle(accent: accent))
                Button("Dismiss") { model.clearFailureNotice() }
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

    /// What this device still owes its vaults, in one line.
    ///
    /// Only drawn when something is queued. A permanently visible control that says "nothing"
    /// is a control that teaches people to stop reading it.
    private var queueControl: some View {
        Button {
            tray.open()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.up").font(.footnote)
                // Three counts, said apart, because they are different facts: work that has not
                // left the phone, work that has left it and is waiting for somebody to open
                // their desktop, and work that got there. The most urgent one that applies wins
                // the line — and when none of them does, because everything queued was
                // refused, the control says what it is rather than counting nothing.
                if tray.outbox.pending > 0 {
                    Text("^[\(tray.outbox.pending) change](inflect: true) to send").font(.caption)
                } else if tray.outbox.accepted > 0 {
                    Text("^[\(tray.outbox.accepted) change](inflect: true) waiting for its vault").font(.caption)
                } else if tray.outbox.delivered > 0 {
                    Text("^[\(tray.outbox.delivered) change](inflect: true) in the vault").font(.caption)
                } else {
                    Text("Send queue").font(.caption)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .nodusGlass(NodusGlass(.thin, tint: accent, interactive: true), in: NodusRadius.controlShape)
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
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
        if NodusLinkPolicy.readOnly { return String(localized: "read") }
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
