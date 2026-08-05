import NodusKit
import NodusUI
import SwiftUI

/// The checks, in order, with what each one found.
///
/// This is what `diagnose()` in the space settings used to be: two calls whose only visible
/// result was one red line, and which could only run inside a space that had already opened —
/// exactly the case where nothing needs diagnosing. It runs the same two calls and four more,
/// against an address rather than against a working session, and every line says what it
/// asked and what came back.
struct ConnectionDiagnosticsView: View {
    @Environment(AppModel.self) private var model
    let connection: AppModel.Connection

    @State private var report: ConnectionReport?
    @State private var isRunning = false
    @State private var hasCopied = false

    var body: some View {
        List {
            if let report {
                Section {
                    ForEach(report.checks) { check in
                        row(check)
                    }
                } header: {
                    Text("Checks")
                } footer: {
                    // A check that never ran is not a check that passed, and a list that
                    // silently omitted them would read as six greens with three missing.
                    Text("Each check only means anything once the one above it has passed, so a run stops at the first failure.")
                }

                if let failure = report.failure {
                    Section {
                        NodusNotice(
                            tone: failure.tone,
                            title: LocalizedStringKey(failure.title),
                            message: LocalizedStringKey(failure.sentence),
                            systemImage: failure.systemImage
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }

                Section {
                    labelled("Server", report.origin)
                    labelled("This app", report.appVersion)
                } header: {
                    Text("What was asked")
                }

                Section {
                    Button {
                        UIPasteboard.general.string = report.plainText
                        hasCopied = true
                    } label: {
                        Label(hasCopied ? "Copied" : "Copy the report", systemImage: hasCopied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel(Text("Copy the report to the clipboard"))
                } footer: {
                    // Said out loud because the alternative — a button that quietly posts a
                    // report somewhere — is what people have learned to expect from the word
                    // "diagnostics", and this one does not.
                    Text("The report goes to the clipboard and nowhere else. It carries no credential and no provider key.")
                }
            } else {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Asking…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .nodusPageBackdrop(accent: connection.accent)
        .tint(connection.accent)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await run() }
                } label: {
                    Label("Run again", systemImage: "arrow.clockwise")
                }
                .disabled(isRunning)
                .accessibilityLabel(Text("Run the checks again"))
            }
        }
        .task { await run() }
    }

    private func row(_ check: ConnectionCheck) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: glyph(for: check))
                .font(.callout)
                .foregroundStyle(colour(for: check))
                // A glyph that only differs by colour is invisible to a reader who cannot
                // separate the two, so the shapes differ as well.
                .accessibilityHidden(true)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(check.step.label))
                    .font(.callout)
                switch check.outcome {
                case .passed(let detail):
                    if let detail {
                        Text(detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                case .failed(let failure):
                    Text(LocalizedStringKey(failure.sentence))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let detail = failure.detail {
                        Text(detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                case .skipped:
                    Text("Not asked")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        // 44 points, because a row in a `List` shrinks to its content and these are two short
        // lines of text.
        .frame(minHeight: 44, alignment: .center)
        .accessibilityElement(children: .combine)
        // `verbatim`: both halves are already translated, and interpolating them into a
        // `Text` literal would send SwiftUI looking for a catalogue entry called "%@, %@".
        .accessibilityLabel(Text(verbatim: "\(check.step.label), \(check.spokenOutcome)"))
    }

    private func glyph(for check: ConnectionCheck) -> String {
        switch check.outcome {
        case .passed: return "checkmark.circle.fill"
        case .failed(let failure): return failure.systemImage
        case .skipped: return "minus.circle"
        }
    }

    private func colour(for check: ConnectionCheck) -> Color {
        switch check.outcome {
        case .passed: return connection.accent
        case .failed(let failure): return failure.tone == .caution ? .nodusCaution : .nodusDanger
        case .skipped: return .secondary
        }
    }

    private func labelled(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    private func run() async {
        guard !isRunning else { return }
        isRunning = true
        hasCopied = false
        report = nil
        defer { isRunning = false }
        report = await model.diagnose(connection)
    }
}
