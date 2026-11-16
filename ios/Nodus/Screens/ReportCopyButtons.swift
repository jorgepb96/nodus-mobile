import NodusAI
import NodusUI
import SwiftUI
import UIKit

/// The two ways to take a report with you, the same two the desktop offers.
///
/// **With references** is the document as it stands: Markdown, headings, the inline `nodus://`
/// citations and the reference list. It is the copy you paste back into something that will
/// render it.
///
/// **Without references** is `ReadingCopy` — the citation buttons, the author-year parentheses,
/// the bibliography and the Markdown syntax all removed, and nothing else. It is the copy you
/// paste into a voice reader, where every surname and page number is an interruption. It runs
/// the desktop's own rules: `scripts/test-reading-copy-parity.mjs` puts both implementations
/// over the same reports and fails on a single differing byte.
struct ReportCopyButtons: View {
    /// The report as Markdown.
    let markdown: String
    /// Prepended to the listening copy when the Markdown does not open with the title itself.
    var title: String?
    let accent: Color

    @State private var copied: Copied?

    private enum Copied: String, Identifiable {
        case withReferences, withoutReferences
        var id: String { rawValue }
    }

    /// One control with a menu, not two glyphs.
    ///
    /// The choice between the two copies is a real one and it cannot be drawn: `doc` and
    /// `doc.plaintext` differ by three lines inside the page icon and stand for the presence or
    /// absence of a bibliography. In a menu the two are sentences, which is the only form in
    /// which the difference is legible.
    var body: some View {
        Menu {
            Button {
                copy(.withReferences, text: markdown)
            } label: {
                NodusMenuLabel("Copy with references", systemImage: "doc.text")
            }
            Button {
                // Built on the tap rather than on every render: the listening copy is two
                // hundred lines of regular expressions over a twenty-page document, and a
                // report that is merely on screen has no reason to pay for it.
                copy(.withoutReferences, text: ReadingCopy.text(from: markdown, title: title))
            } label: {
                NodusMenuLabel("Copy without references", systemImage: "text.alignleft")
            }
        } label: {
            // Laid out for both words rather than for the one showing: "Copied" is the wider of
            // the two in every language, and a chip that grows when it is pressed is a chip
            // whose outline breaks while the row it sits in is placed again. See
            // `reportActionWidth`.
            chip(copied == nil ? "Copy" : "Copied", icon: copied == nil ? "doc.on.doc" : "checkmark")
                .reportActionWidth {
                    chip("Copy", icon: "doc.on.doc")
                    chip("Copied", icon: "checkmark")
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .reportActionSurface(accent: accent)
        }
        .accessibilityLabel("Copy the report")
        .animation(NodusMotion.quick, value: copied)
    }

    /// One state of the chip: what it says, and the glyph it says it with.
    private func chip(_ title: LocalizedStringKey, icon: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(accent.nodusReadable)
    }

    private func copy(_ kind: Copied, text: String) {
        UIPasteboard.general.string = text
        copied = kind
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copied == kind { copied = nil }
        }
    }
}
