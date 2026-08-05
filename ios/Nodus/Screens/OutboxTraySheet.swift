import NodusKit
import NodusUI
import SwiftUI

/// Whether the tray is open, and what it is holding.
///
/// One object at the root rather than a `@State` per entry point, so the count on the Home tile,
/// the count beside the picker's control and the list inside the sheet are the same three
/// readings of one thing. Two of them disagreeing about how much is queued is worse than either
/// of them being absent.
@Observable
@MainActor
final class OutboxTrayModel {
    var isPresented = false
    let outbox = GlobalOutbox()

    /// Refreshed on demand, never on launch: the aggregate opens a SQLite file per space that
    /// has one, and a cold start should not pay for a screen nobody has asked for.
    func refresh() async { await outbox.refresh() }

    /// Reads the queues *and* asks each server how far its owner has collected. Attached to
    /// coming back to the app and to pulling the tray down — both moments when a person is
    /// asking "any news?", and neither of them a loop.
    func confirmDeliveries() async { await outbox.confirmDeliveries() }

    func open() {
        isPresented = true
    }
}

/// Everything queued on this device, in every vault.
///
/// A change that has reached the server is *in a ledger*; it becomes part of the vault only when
/// the owner's Nodus drains it. So a queued change has three states worth telling apart — "not
/// sent yet", "sent, waiting for the owner" and "the owner has it" — and collapsing any two of
/// them would tell somebody their work is somewhere it is not. Every row here says which it is.
struct OutboxTraySheet: View {
    @Environment(OutboxTrayModel.self) private var tray
    @Environment(\.dismiss) private var dismiss

    private var outbox: GlobalOutbox { tray.outbox }

    var body: some View {
        NavigationStack {
            list
                .navigationTitle("Send queue")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task { await outbox.refresh() }
    }

    private var list: some View {
        List {
            Section { relayExplanation }

            if outbox.pending > 0 {
                Section {
                    Button {
                        Task { await outbox.sendEverything() }
                    } label: {
                        if outbox.isSending {
                            Label("Sending…", systemImage: "arrow.up.circle")
                        } else {
                            // A catalogue entry with a plural rule, not an interpolated key.
                            // This used to be `"Send \(count) change\(count == 1 ? "" : "s")"`,
                            // which builds an English plural by hand *and* interpolates — and an
                            // interpolated key matches nothing in the catalogue, so the busiest
                            // button on the screen was English on every phone.
                            Label("^[Send \(outbox.pending) change](inflect: true)", systemImage: "arrow.up.circle")
                        }
                    }
                    .disabled(outbox.isSending)
                }
            }

            ForEach(failures, id: \.spaceId) { failure in
                Section {
                    NodusNotice(
                        tone: .blocked,
                        title: LocalizedStringKey(failure.spaceName),
                        message: LocalizedStringKey(failure.reason)
                    )
                }
            }

            // The other thing the delivery check learns. A queue whose token has run out will
            // keep failing to send with a message about the network, and this is the only
            // screen in a position to say what is actually wrong.
            ForEach(credentialNotices, id: \.spaceId) { notice in
                Section { credentialNotice(notice) }
            }

            if outbox.entries.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Nothing queued",
                        systemImage: "tray",
                        description: Text("Notes you write and reports you send appear here before they travel.")
                    )
                }
            } else {
                Section {
                    ForEach(outbox.entries) { entry in
                        row(entry)
                    }
                } header: {
                    NodusSectionLabel("Queue")
                }
            }
        }
        .scrollContentBackground(.hidden)
        // The same three lines every other list in the app carries: the grouped style's opaque
        // row cards, its separators drawn for a white table, and its small-capital headers.
        .listStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Color.nodusTertiaryText.opacity(0.45))
        .textCase(nil)
        // Pulling this list down is somebody asking "any news?", so it asks the servers rather
        // than only re-reading the queues. It is a gesture, not a loop.
        .refreshable { await outbox.confirmDeliveries() }
    }

    private var failures: [(spaceId: String, spaceName: String, reason: String)] {
        outbox.failures.compactMap { spaceId, reason in
            guard let name = outbox.entries.first(where: { $0.connection.spaceId == spaceId })?.connection.spaceName
            else { return nil }
            return (spaceId: spaceId, spaceName: name, reason: reason)
        }
        .sorted { $0.spaceName < $1.spaceName }
    }

    private var credentialNotices: [(spaceId: String, spaceName: String, credential: MutationDelivery.Credential)] {
        outbox.credentials.compactMap { spaceId, credential in
            guard let name = outbox.entries.first(where: { $0.connection.spaceId == spaceId })?.connection.spaceName
            else { return nil }
            return (spaceId: spaceId, spaceName: name, credential: credential)
        }
        .sorted { $0.spaceName < $1.spaceName }
    }

    /// Interpolated into a `LocalizedStringKey` literal rather than built with
    /// `String(localized:)`: interpolation into a key produces a key with `%@` in it, which is
    /// what the catalogue holds. A string built first and wrapped afterwards is looked up as
    /// itself, and matches nothing on any phone.
    @ViewBuilder
    private func credentialNotice(
        _ notice: (spaceId: String, spaceName: String, credential: MutationDelivery.Credential)
    ) -> some View {
        switch notice.credential {
        case .rejected:
            NodusNotice(
                tone: .blocked,
                title: "Sign in again",
                message: "The server no longer accepts this device's key for “\(notice.spaceName)”. Nothing queued is lost; it travels once you have signed in again.",
                systemImage: "key.slash"
            )
        case .expiring(let date):
            NodusNotice(
                tone: .caution,
                title: "Sign in again soon",
                message: "This device's key for “\(notice.spaceName)” stops working on \(date.formatted(date: .abbreviated, time: .omitted)).",
                systemImage: "key"
            )
        }
    }

    private var relayExplanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("How this reaches the vault", systemImage: "arrow.triangle.branch")
                .font(.footnote.weight(.medium))
            Text("The server keeps your changes in a ledger. They join the vault when its owner opens Nodus desktop and republishes. Until then nobody sees them, you included.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func row(_ entry: GlobalOutbox.Entry) -> some View {
        HStack(spacing: 10) {
            // The vault this change belongs to, said in colour. It is a bar rather than a dot
            // because it has to survive being the only coloured thing on a row of grey text.
            Capsule()
                .fill(entry.connection.accent)
                .frame(width: 4)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.item.title).font(.callout).lineLimit(1)
                    Spacer()
                    stateBadge(entry)
                }
                // The name as well as the colour. Two academic vaults share an accent, so colour
                // alone narrows the answer down without giving it.
                Text(entry.connection.spaceName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(entry.connection.accent.nodusReadable)
                Text(caption(for: entry.item))
                    .font(.caption2)
                    .foregroundStyle(entry.item.state == .rejected ? AnyShapeStyle(Color.nodusDanger) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.vertical, 3)
        .swipeActions {
            Button(role: .destructive) {
                Task { await outbox.discard(entry) }
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func stateBadge(_ entry: GlobalOutbox.Entry) -> some View {
        // `LocalizedStringKey`: a computed `String` here reached `Text` as data and shipped the
        // three most-read words on this screen in English on every phone.
        let (label, colour): (LocalizedStringKey, Color) = switch entry.item.state {
        case .pending: ("Not sent", Color.nodusCaution)
        case .accepted: ("On the server", entry.connection.accent)
        case .rejected: ("Rejected", Color.nodusDanger)
        // The one green thing on this screen, and the only state that is the end of a journey.
        case .delivered: ("In the vault", Color.nodusSuccess)
        }
        return Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(colour)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(colour.opacity(0.15), in: Capsule())
    }

    /// `String(localized:)` rather than a bare literal: the result is handed to `Text` as a
    /// value, and a value is never looked up in the catalogue.
    private func caption(for item: MutationOutbox.Item) -> String {
        if let detail = item.detail { return detail }
        switch item.state {
        case .pending:
            return String(localized: "Saved on this device.")
        case .accepted:
            // The important sentence on this screen.
            return String(localized: "Waiting for the owner to republish.")
        case .rejected:
            return String(localized: "The server rejected it.")
        case .delivered:
            // Applied is not published, and this sentence is the whole difference. The owner's
            // Nodus has written it into their own database; the copy everybody reads — this
            // phone included — is the last one they published, and this is not in it yet.
            return String(localized: "In the owner's Nodus. It joins the published copy when they republish.")
        }
    }
}
