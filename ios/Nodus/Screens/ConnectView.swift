import NodusKit
import NodusUI
import SwiftUI

/// Adding a server: probe, sign in, pick a space.
///
/// Three steps rather than one form, because each answers a question the next one needs. The
/// probe is unauthenticated and settles "is this a Nodus Server and does this build understand
/// it" before asking for a password. Sign-in returns the spaces this account can reach, so the
/// space is chosen from a list rather than typed. Only then is a token minted, and it is bound
/// to exactly the space that was chosen.
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable {
        case address
        case credentials(ServerAddress, ServerCapabilities)
        case space(ServerAddress, LoginTicket)
    }

    @State private var step: Step = .address
    @State private var addressInput = ""
    @State private var email = ""
    @State private var password = ""
    @State private var pairingCode = ""
    @State private var usePairingCode = false
    /// A failure that is about reaching the server: it gets the classifier's sentence.
    @State private var failure: ConnectionFailure?
    /// A refusal the server explained itself — a wrong password, an expired ticket. Its own
    /// words are better than anything this screen could invent, so they are kept.
    @State private var refusal: String?
    @State private var isBusy = false
    @State private var linkingDesktop = false
    @State private var advanced = false

    private let accent = Color(hex: VaultType.academic.accentHex)

    var body: some View {
        Group {
            if advanced {
                NavigationStack { content }
            } else {
                DesktopBridgePairingSheet(accent: accent, onAdvanced: { advanced = true }) { dismiss() }
                    .environment(model)
            }
        }
        .onAppear {
            // Debug builds only: lets the verification loop skip retyping a local address on
            // every run. Release has no such path — see LabDefaults.
            guard let defaults = LabDefaults.current else { return }
            if addressInput.isEmpty { addressInput = defaults.address }
            if email.isEmpty { email = defaults.email }
            if password.isEmpty { password = defaults.password }
        }
        .sheet(isPresented: $linkingDesktop) { DesktopBridgePairingSheet(accent: accent) { dismiss() }.environment(model) }
    }

    private var content: some View {
        Group {
            ZStack {
                NodusBackdrop(accent: accent)
                ScrollView {
                    VStack(spacing: 22) {
                        header
                        switch step {
                        case .address: addressStep
                        case .credentials(let address, let capabilities): credentialsStep(address, capabilities)
                        case .space(let address, let ticket): spaceStep(address, ticket)
                        }
                        if let failure {
                            // The classified failure, in the shape every other screen shows one
                            // in. A wrong password and a sleeping computer used to arrive here
                            // as the same grey line of text.
                            NodusNotice(
                                tone: failure.tone,
                                title: LocalizedStringKey(failure.title),
                                message: LocalizedStringKey(failure.sentence),
                                systemImage: failure.systemImage
                            )
                            if let detail = failure.detail {
                                Text(detail)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        } else if let refusal {
                            Label(refusal, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(Color.nodusDanger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .nodusGlass(NodusGlass(.thin, tint: Color.nodusDanger), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .padding(20)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .nodusDismissesKeyboard()
            .tint(accent)
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            NodusMark(style: .accent(accent)).frame(width: 64, height: 64)
            Text("Connect to a Nodus Server")
                .font(.title3.weight(.semibold))
            Text("Your server holds a published projection of the vault. AI keys never leave this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 12)
    }

    // MARK: Step 1

    private var addressStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button("Link Nodus", systemImage: "qrcode") { linkingDesktop = true }
                .buttonStyle(NodusPrimaryButtonStyle(accent: accent))
                .accessibilityIdentifier("nodus-link-mac")
            Text("Server address").font(.subheadline.weight(.medium))
            TextField("nodus.example.org", text: $addressInput)
                .accessibilityIdentifier("nodus-server-address")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.plain)
                .padding(14)
                .nodusFieldSurface(accent: accent)

            Text("HTTPS is assumed. The server refuses any public address that is not.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // A disabled button with no explanation is what a slow probe used to look like:
            // the user tapped, the address was fine, and the only feedback was the button
            // going grey for half a minute. Now it says what it is doing.
            Button {
                Task { await probe() }
            } label: {
                HStack(spacing: 7) {
                    if isBusy {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("Looking for the server…")
                    } else {
                        Image(systemName: "arrow.right")
                        Text("Continue")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(NodusPrimaryButtonStyle(accent: accent))
            .disabled(addressInput.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
        }
        .padding(18)
        .nodusGlass(NodusGlass(.regular, tint: accent))
    }

    // MARK: Step 2

    private func credentialsStep(_ address: ServerAddress, _ capabilities: ServerCapabilities) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(capabilities.server.name).font(.subheadline.weight(.semibold))
                    Text(address.origin).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if address.isInsecure {
                    // Saying so is the point. A padlock this connection has not earned would be
                    // worse than no padlock at all.
                    Label("Not encrypted", systemImage: "lock.open")
                        .font(.caption2).foregroundStyle(Color.nodusCaution)
                }
            }

            // A real label, hidden rather than empty: an empty one is still a string to
            // translate, it lands in the catalogue as a blank key, and VoiceOver reads the
            // control as unnamed.
            Picker("How to sign in", selection: $usePairingCode) {
                Text("Account").tag(false)
                Text("Code").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if usePairingCode {
                TextField("XXXX-XXXX", text: $pairingCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textFieldStyle(.plain)
                    .padding(14)
                    .nodusFieldSurface(accent: accent)
                Text("A pairing code expires after fifteen minutes and works once.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .textFieldStyle(.plain)
                    .padding(14)
                    .nodusFieldSurface(accent: accent)
                SecureField("Password", text: $password)
                    .textFieldStyle(.plain)
                    .padding(14)
                    .nodusFieldSurface(accent: accent)
            }

            Button {
                Task { usePairingCode ? await pair(address) : await signIn(address) }
            } label: {
                Label(usePairingCode ? "Pair" : "Sign in", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NodusPrimaryButtonStyle(accent: accent))
            .disabled(isBusy)
        }
        .padding(18)
        .nodusGlass(NodusGlass(.regular, tint: accent))
    }

    // MARK: Step 3

    private func spaceStep(_ address: ServerAddress, _ ticket: LoginTicket) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a space").font(.subheadline.weight(.medium))
            Text("Each space needs its own credential: one works for exactly one space.")
                .font(.caption).foregroundStyle(.secondary)

            if ticket.spaces.isEmpty {
                ContentUnavailableView(
                    "No spaces",
                    systemImage: "square.dashed",
                    description: Text("This account has no access to any space yet. Ask whoever administers the server.")
                )
            }

            ForEach(ticket.spaces) { space in
                Button {
                    Task { await connect(address, ticket, space) }
                } label: {
                    SpaceRow(space: space)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            }
        }
        .padding(18)
        .nodusGlass(NodusGlass(.regular, tint: accent))
    }

    // MARK: Actions

    private func probe() async {
        await attempt {
            let (address, capabilities) = try await model.probe(addressInput)
            step = .credentials(address, capabilities)
        }
    }

    private func signIn(_ address: ServerAddress) async {
        await attempt {
            let ticket = try await model.signIn(to: address, email: email, password: password)
            password = ""
            step = .space(address, ticket)
        }
    }

    private func pair(_ address: ServerAddress) async {
        await attempt {
            let connection = try await model.pair(to: address, code: pairingCode.uppercased())
            model.open(connection)
            dismiss()
        }
    }

    private func connect(_ address: ServerAddress, _ ticket: LoginTicket, _ space: SpaceSummary) async {
        await attempt {
            let connection = try await model.connect(to: address, ticket: ticket, space: space)
            model.open(connection)
            dismiss()
        }
    }

    /// One step of the flow, with the same busy state and the same way of failing.
    ///
    /// The four steps used to repeat five lines each, and the last of those lines was a
    /// `describe` that carried a second, older copy of every sentence in
    /// `ConnectionFailureText`. Two copies of a sentence is two sentences to keep translated.
    private func attempt(_ work: () async throws -> Void) async {
        isBusy = true
        failure = nil
        refusal = nil
        defer { isBusy = false }
        do {
            try await work()
        } catch {
            await record(error)
        }
    }

    /// A refusal the server explained keeps its own words; everything else is classified.
    private func record(_ error: any Error) async {
        if let api = error as? APIError, let sentence = Self.explain(api) {
            refusal = sentence
            return
        }
        // Already classified on the way out of `probe`, and there is nothing to add to it.
        if let classified = error as? ConnectionFailure {
            failure = classified
            return
        }
        // Sign-in and pairing go through the ordinary session, so they can fail in every way a
        // probe can — the computer sleeps between typing the address and typing the password.
        let origin = currentOrigin
        let network = await NetworkReachability.current(within: 0.5)
        failure = ConnectionFailure.classify(
            error: error,
            origin: origin,
            network: network,
            knock: .unauthenticated,
            appVersion: NodusVersion.current
        ) ?? .unclassified(host: ConnectionFailure.host(of: origin), detail: error.localizedDescription)
    }

    /// The address the current step is talking to: what was typed until it has been validated,
    /// and the normalised origin after.
    private var currentOrigin: String {
        switch step {
        case .address: return addressInput.trimmingCharacters(in: .whitespaces)
        case .credentials(let address, _), .space(let address, _): return address.origin
        }
    }

    /// The three refusals this screen provokes on purpose, in words that name the field to fix.
    /// Anything else the server says is a sentence it wrote itself, and it goes to the
    /// classifier to be placed rather than being paraphrased here.
    private static func explain(_ api: APIError) -> String? {
        switch api.code {
        case "invalid_credentials": return String(localized: "That email or password is not right.")
        case "invalid_ticket": return String(localized: "The sign-in expired. Sign in again.")
        case "rate_limited":
            let seconds = Int(api.retryAfter ?? 60)
            return String(localized: "Too many attempts. Try again in \(seconds) s.")
        default: return nil
        }
    }
}

private struct SpaceRow: View {
    let space: SpaceSummary

    var body: some View {
        let accent = Color(hex: space.vault?.type?.accentHex ?? VaultType.academic.accentHex)
        HStack(spacing: 12) {
            NodusMark(style: .accent(accent)).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(space.name).font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    Text(LocalizedStringKey(roleLabel(space.role))).font(.caption2)
                    if !space.hasSnapshot {
                        Text("· not published").font(.caption2).foregroundStyle(Color.nodusCaution)
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nodusFieldSurface(accent: accent)
    }

    private func roleLabel(_ role: SpaceRole) -> String {
        switch role {
        case .reader: return String(localized: "Read only")
        case .writer: return String(localized: "Can send changes")
        case .owner: return String(localized: "Owner")
        }
    }
}
