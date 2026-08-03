import NodusKit
import NodusUI
import SwiftUI

/// How finished the vault type behind a space is.
///
/// The desktop grades its nine types across three phases — pre-alpha, alpha, beta
/// (`src/components/vaultTypeUi.tsx:117`). This app makes one distinction instead, because it
/// is the only one a reader of a published space can act on: academic is the mode Nodus was
/// built around and the one everything else was generalised out of, and every other type is
/// still being proved. Grading them here would promise a precision the phone client has not
/// earned — none of these screens has had the use the academic ones have.
extension VaultType {
    /// Nothing for academic, which needs no warning; `ALPHA` for everything else.
    var isAlpha: Bool { self != .academic }
}

/// The tag itself: amber, small, and — where there is room for it to be — tappable.
///
/// Amber rather than red: this is not an error and nothing is broken. It is the app saying
/// which parts of itself have been walked over less.
struct VaultPhaseTag: View {
    var explains = true

    @State private var showingExplanation = false

    var body: some View {
        Group {
            if explains {
                Button { showingExplanation = true } label: { label }
                    .buttonStyle(.plain)
                    .accessibilityHint("What ALPHA means")
            } else {
                label
            }
        }
        .alert("ALPHA", isPresented: $showingExplanation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(Self.explanation)
        }
    }

    /// The desktop's own words for the alpha phase (`src/components/vaultTypeUi.tsx:120-122`),
    /// so the phone does not invent a second promise about the same software.
    static let explanation: LocalizedStringKey =
        "Its main features are still being tested; recommended only for testers."

    private var label: some View {
        Text(verbatim: "ALPHA")
            .font(.caption2.weight(.bold))
            .tracking(0.6)
            .foregroundStyle(Color.nodusAlpha)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.nodusAlpha.opacity(0.16), in: Capsule())
            .overlay(Capsule().stroke(Color.nodusAlpha.opacity(0.45), lineWidth: 0.5))
    }
}

extension Color {
    /// Amber. Not the space's accent: the tag says something about the software rather than
    /// about the vault, and wearing the vault's colour would read as part of it.
    static let nodusAlpha = Color(red: 0.98, green: 0.75, blue: 0.14)
}
