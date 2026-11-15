import NodusKit
import NodusUI
import SwiftUI

struct LinkDownloadIndicator: View {
    let status: LinkDownloads.Status
    var body: some View {
        ZStack {
            Circle().fill(status.color.opacity(0.12))
            Circle().strokeBorder(status.color.opacity(0.55), lineWidth: 1)
            if status == .downloading { ProgressView().controlSize(.small) }
            else { Image(systemName: status.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(status.color) }
        }
        .frame(width: 30, height: 30)
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .accessibilityLabel(Text(status.label))
    }
}

struct LinkSectionDownloadButton: View {
    let section: LinkDownloadSection
    @Environment(LinkDownloads.self) private var downloads: LinkDownloads?
    @State private var showingOptions = false

    var body: some View {
        if let downloads {
            Button {
                if downloads.status(section) == .updates { downloads.download(section) }
                else { showingOptions = true }
            } label: { LinkDownloadIndicator(status: downloads.status(section)) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("section-download-\(section.rawValue)")
            .accessibilityValue(Text(downloads.status(section).label))
            .popover(isPresented: $showingOptions, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(section.title).font(.headline)
                    Label { Text(downloads.status(section).label) } icon: { Image(systemName: downloads.status(section).symbol) }
                        .font(.subheadline).foregroundStyle(downloads.status(section).color)
                    if let copy = downloads.copies[section] {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(copy.pack.bytes), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Downloaded \(copy.pack.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(section == .podcast ? "Downloads the catalogue. Download audio separately for each episode." : "Keeps a local reading copy for 30 days. Original documents and audio are downloaded separately.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if downloads.status(section) == .downloading {
                        Button("Cancel download", role: .cancel) { Task { await downloads.cancel(section.rawValue) } }.frame(minHeight: 44)
                    } else {
                        Button(downloads.copies[section] == nil ? "Download section" : "Download changes", systemImage: "arrow.down.circle") {
                            downloads.download(section); showingOptions = false
                        }.frame(minHeight: 44).accessibilityIdentifier("section-download-start")
                        if downloads.copies[section] != nil {
                            Button("Remove local download", role: .destructive) {
                                showingOptions = false; Task { await downloads.remove(section) }
                            }.frame(minHeight: 44).accessibilityIdentifier("section-download-remove")
                        }
                    }
                    Text("Removing a download only affects this device. Your data in Nodus stays intact.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(20).frame(width: 290)
                .presentationCompactAdaptation(.popover)
            }
            .contextMenu {
                Button("Download changes", systemImage: "arrow.down.circle") { downloads.download(section) }
                if downloads.copies[section] != nil {
                    Button("Remove local download", role: .destructive) { Task { await downloads.remove(section) } }
                }
            }
        }
    }
}

struct LinkEpisodeDownloadButton: View {
    let id: String
    let title: String
    @Environment(LinkDownloads.self) private var downloads: LinkDownloads?
    var body: some View {
        if let downloads {
            if downloads.episodeStatus(id) == .updates {
                Button { downloads.downloadEpisode(id, title: title) } label: { LinkDownloadIndicator(status: .updates) }
                    .buttonStyle(.plain).accessibilityIdentifier("podcast-download-\(id)").accessibilityValue(Text(downloads.episodeStatus(id).label))
                    .contextMenu { Button("Remove local download", role: .destructive) { Task { await downloads.removeEpisode(id) } } }
            } else {
            Menu {
                Button(downloads.episodeCopies[id] == nil ? "Download podcast" : "Download changes", systemImage: "arrow.down.circle") {
                    downloads.downloadEpisode(id, title: title)
                }
                if downloads.episodeStatus(id) == .downloading {
                    Button("Cancel download", role: .cancel) { Task { await downloads.cancel("episode:" + id) } }
                }
                if downloads.episodeCopies[id] != nil {
                    Button("Remove local download", role: .destructive) { Task { await downloads.removeEpisode(id) } }
                }
            } label: { LinkDownloadIndicator(status: downloads.episodeStatus(id)) }
            .buttonStyle(.plain).accessibilityIdentifier("podcast-download-\(id)").accessibilityValue(Text(downloads.episodeStatus(id).label))
            }
        }
    }
}
