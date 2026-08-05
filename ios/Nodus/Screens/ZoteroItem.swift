import NodusKit
import NodusUI
import SwiftUI
import UIKit

/// The work, in Zotero.
///
/// Every work in a Nodus corpus came from a Zotero library and carries the key it has there.
/// Until now that key was a line of the record — `zotero_key: 8FMQ4T2J` — which is the one thing
/// on the screen a reader can do nothing with, while the app that holds the PDF, the notes and
/// the annotations sits on the same home screen.
///
/// The scheme is the one the desktop already uses (`shared/pageLocation.ts` in the Nodus
/// repository), including its spelling for an item in a group library, so a key that opens the
/// right item on a Mac opens the right item here. It is a contract with Zotero rather than
/// shared code, and `ZoteroItemTests` is what keeps the two spellings from drifting.
enum ZoteroItem {
    /// `zotero://select/library/items/KEY`, or the group form for a key the desktop wrote as
    /// `groups:<id>:<key>`.
    ///
    /// Nil for a key that is blank or that no percent-encoding can make into a URL, because a
    /// control that opens nothing is worse than no control.
    static func selectURL(key: String) -> URL? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: "zotero://select/\(target(for: trimmed))")
    }

    private static func target(for key: String) -> String {
        // `groups:12345:8FMQ4T2J` — a work from a shared library. Split on the first two colons
        // only: a key is alphanumeric, but the desktop's own parser is written this way and the
        // two have to agree about a malformed one as much as about a well-formed one.
        let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        if parts.count == 3, parts[0] == "groups", !parts[1].isEmpty, !parts[2].isEmpty {
            return "groups/\(escaped(String(parts[1])))/items/\(escaped(String(parts[2])))"
        }
        return "library/items/\(escaped(key))"
    }

    private static func escaped(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? component
    }
}

/// The control that opens it.
///
/// Shown wherever a row carries a Zotero key — a work, and anything else the corpus publishes one
/// for. It replaces the raw field rather than sitting beside it: the key is still there, as the
/// control's own subtitle, because a reader who has to type it into a desktop still needs to read
/// it.
struct ZoteroItemLink: View {
    let key: String
    let accent: Color

    @State private var failed = false
    @Environment(\.openURL) private var openURL

    private var url: URL? { ZoteroItem.selectURL(key: key) }

    var body: some View {
        if let url {
            VStack(alignment: .leading, spacing: 9) {
                NodusSectionLabel("Zotero")
                Button {
                    open(url)
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(accent.nodusReadable)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open in Zotero").font(.callout.weight(.medium))
                            // The key itself, in the type the rest of the app gives an
                            // identifier. It is what a reader copies when they are at a desk
                            // rather than on the phone.
                            Text(key)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.forward.app")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(NodusSpace.cardPadding)
                    .nodusGlass(NodusGlass(.regular, tint: accent))
                }
                .buttonStyle(NodusCardButtonStyle())

                // Said only once it has actually failed, rather than as a warning under a
                // control that would have worked. `canOpenURL` answers for the moment it is
                // asked, and a reader who installs Zotero and comes back should find a button
                // that simply works — not a screen that decided hours ago that it would not.
                if failed {
                    NodusNotice(
                        tone: .caution,
                        title: "Zotero did not open",
                        message: "Install Zotero for iPhone and iPad, and open this library in it, to follow a work back to its item.",
                        systemImage: "books.vertical"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// `UIApplication.open` rather than the environment's `openURL`, for its completion: the
    /// environment action returns nothing, so a `zotero://` that nothing on the device handles
    /// is indistinguishable from one that worked.
    private func open(_ url: URL) {
        UIApplication.shared.open(url, options: [:]) { opened in
            MainActor.assumeIsolated { failed = !opened }
        }
    }
}
