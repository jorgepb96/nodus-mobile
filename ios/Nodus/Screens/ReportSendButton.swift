import NodusAI
import NodusUI
import SwiftUI

/// What a report needs to know before it can be sent.
///
/// A struct rather than the tuple `pdf:` uses, because three references of similar shape read
/// as three unlabelled positions when they are a tuple and as three names when they are not.
struct ReportSendContext {
    let session: SpaceSession
    let store: LocalReportStore
    let saved: LocalReportStore.Saved
}

/// Send this report to the vault, and say afterwards that you did.
///
/// It sits in the same row as Copy and the text size rather than at the foot of the document,
/// which is where it used to be — below every section and the reference list, on a report that
/// can run to twenty pages. An action nobody scrolls to is an action nobody takes; that is the
/// whole reason this control exists as a control.
///
/// It asks first. Sharing takes a copy off the phone and changes nothing; this puts a document
/// in somebody's corpus, and the two should not be one tap apart and indistinguishable.
///
/// The label is one word on purpose. This chip sits beside "Copy" and a two-ended stepper, and
/// "Send to the vault" would be the widest thing in the row — enough to force a wrap at the
/// default text size, before anybody has touched the size control at all.
struct ReportSendButton: View {
    let context: ReportSendContext

    @Environment(AISettings.self) private var ai

    @State private var confirming = false
    @State private var sending = false
    @State private var sentAt: Date?
    @State private var failure: String?

    private var accent: Color { context.session.accent }
    private var wasSent: Bool { sentAt != nil }

    var body: some View {
        Button {
            confirming = true
        } label: {
            // Sized for both words, for the reason `reportActionWidth` gives: "Sent" arrives on
            // a press, it is the longer word, and a chip that grows on a press is drawn with a
            // broken outline while its row is placed again around it.
            chip
                .reportActionWidth {
                    label("Send", icon: "arrow.up.doc")
                    label("Sent", icon: "checkmark.circle")
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .reportActionSurface(accent: accent)
        }
        .buttonStyle(.plain)
        .disabled(sending)
        .accessibilityLabel(wasSent ? "Send the report again" : "Send the report to the vault")
        .animation(NodusMotion.quick, value: wasSent)
        .animation(NodusMotion.quick, value: sending)
        // Seeded from the file rather than from a fresh `false`, so a report opened from the
        // library already knows it has travelled.
        .task { sentAt = context.saved.sentAt }
        .alert(wasSent ? "Send this report again?" : "Send to Nodus desktop?", isPresented: $confirming) {
            Button(wasSent ? "Send again" : "Send") { Task { await send() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(wasSent
                 ? "It replaces the copy already in the vault rather than adding a second one."
                 : "It travels to the server now. It joins the vault when whoever owns it next opens Nodus desktop and republishes.")
        }
        // Presented as an alert rather than drawn under the chip: a two-line failure inside a
        // `FlowLayout` is a flow item the width of the screen, and it would push the size
        // control onto a line of its own.
        .alert(
            "Could not send the report",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(LocalizedStringKey(failure ?? ""))
        }
    }

    /// What the chip is saying now: the word for the state it is in, and a spinner in place of
    /// the glyph while the report is on its way.
    @ViewBuilder
    private var chip: some View {
        if sending {
            Label { Text("Send") } icon: { ProgressView().controlSize(.small) }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent.nodusReadable)
        } else {
            label(wasSent ? "Sent" : "Send", icon: wasSent ? "checkmark.circle" : "arrow.up.doc")
        }
    }

    private func label(_ title: LocalizedStringKey, icon: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(accent.nodusReadable)
    }

    private func send() async {
        guard !sending else { return }
        sending = true
        defer { sending = false }

        guard let model = context.saved.modelRef ?? ai.model(for: .deepResearch) else {
            // A report saved before the model was kept as a reference, on a device with no model
            // chosen either. Nothing here can name the provider the row needs.
            failure = "Choose a model under Providers before sending this report."
            return
        }
        guard let controller = await OutboxController.open(session: context.session) else {
            failure = "Your access to this space is read only."
            return
        }

        let sent = await controller.sendReport(
            context.saved.report,
            mode: context.saved.mode,
            model: model,
            language: Prompts.interfaceLanguage,
            // Reusing the row id is what makes a second send an update of the owner's copy
            // rather than a second report in their list.
            rowId: context.saved.vaultRowId ?? UUID().uuidString
        )

        guard let sent else {
            failure = controller.lastError ?? "The report could not be queued on this device."
            return
        }
        context.store.markSent(context.saved.id, outboxId: sent.outboxId, vaultRowId: sent.rowId)
        sentAt = Date()
        // A network failure after the change was queued and released is not a failure — the
        // next flush finishes it — so `lastError` is deliberately not surfaced here. The queue
        // is where an unfinished send is visible, and it says so in its own words.
    }
}
