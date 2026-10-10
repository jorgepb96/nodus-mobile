import CryptoKit
import NodusKit
import QuickLook
import SwiftUI

/// File bytes are fetched through the selected grant, verified, and protected before preview.
struct PrivateFileButton: View {
    let session: SpaceSession
    let kind: DesktopBridgeFileKind
    let id: String
    @State private var preview: URL?
    @State private var downloading = false
    @State private var issue: String?
    @State private var offline = false
    @State private var copy: PrivateBridgeFileCopy?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await open() }
            } label: {
                if downloading { ProgressView() }
                else { Label("Open file", systemImage: "arrow.down.doc") }
            }
            .disabled(downloading)
            .accessibilityIdentifier("bridge-file-\(kind.rawValue)-\(id)")
            if let issue { Text(issue).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if offline { Label("Downloaded copy", systemImage: "wifi.slash").font(.caption).foregroundStyle(.secondary) }
            if let copy { CompanionFileDownloadButton(session: session, copy: copy) }
        }
        .quickLookPreview($preview)
    }
    @MainActor private func open() async {
        downloading = true; issue = nil; offline = false
        defer { downloading = false }
        do {
            let copy = try await loadPrivateBridgeFile(session, kind: kind, id: id)
            self.copy = copy
            preview = copy.url; offline = copy.offline
        } catch { issue = error.localizedDescription }
    }
}
