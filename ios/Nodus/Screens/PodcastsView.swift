import Foundation
import NodusKit
import NodusUI
import SwiftUI

struct LinkPodcast: Decodable, Identifiable {
    let id: String
    let title: String
    let objective: String
    let durationS: Double
    let createdAt: String
    let audioBytes: Int
    let listenedPositionS: Double
    var script: Script?
    var timeline: Timeline?
    var sources: [Source]?
    struct Script: Decodable { let turns: [Turn] }
    struct Turn: Decodable, Identifiable { let id: String; let speaker: String; let text: String }
    struct Timeline: Decodable { let chapters: [Chapter] }
    struct Chapter: Decodable { let index: Int; let title: String; let startS: Double }
    struct Source: Decodable, Identifiable { let id: String; let title: String; let excerpt: String; var link: String?; var url: String? }
}

struct PodcastsView: View {
    let session: SpaceSession
    @Environment(\.scenePhase) private var phase
    @Environment(\.nodusResidentRouteActive) private var routeActive
    @State private var episodes: [LinkPodcast] = []
    @State private var query = ""
    @State private var loading = false
    @State private var issue: String?
    @State private var selected: LinkPodcast?
    @State private var openPlayerAfterDismiss = false
    @State private var opening = false
    @State private var cover: Data?
    @State private var openingRevision = UUID()

    private var filtered: [LinkPodcast] {
        query.isEmpty ? episodes : episodes.filter { ($0.title + " " + $0.objective).localizedStandardContains(query) }
    }
    var body: some View {
        VStack(spacing: 0) {
            DesktopPageHeader(title: "Podcasts", subtitle: "Escucha los episodios guardados en tu ordenador", systemImage: "headphones", accent: session.accent)
                .padding(16)
            NodusSearchField(text: $query, prompt: "Buscar podcast", accent: session.accent).padding(.horizontal, 16).padding(.bottom, 12)
            if let issue {
                Text(issue).foregroundStyle(Color.nodusDanger).padding().accessibilityIdentifier("podcasts-error")
                Button("Reintentar") { Task { await load() } }.disabled(loading).frame(minHeight: 44)
            }
            if loading { ProgressView().accessibilityIdentifier("podcasts-loading") }
            List {
                ForEach(filtered) { episode in
                    Button { Task { await open(episode) } } label: {
                        HStack(spacing: 14) {
                            LinkMediaImage(session: session, kind: .podcast, id: episode.id).frame(width: 76, height: 76)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(episode.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(3)
                                Text(episode.objective).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Text("\(Int(max(0, episode.durationS) / 60)) min").font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(minHeight: 64)
                    }.accessibilityIdentifier("podcast-\(episode.id)")
                }
                if !loading && issue == nil && filtered.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No hay podcasts guardados" : "Sin resultados", systemImage: "headphones", description: Text("Los episodios que crees en Nodus Desktop aparecerán aquí."))
                }
            }.listStyle(.plain)
                .refreshable { await load() }
        }
        .task(id: routeActive && phase == .active) {
            guard routeActive && phase == .active else { return }
            while !Task.isCancelled {
                await load()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
        .sheet(item: $selected, onDismiss: {
            if openPlayerAfterDismiss { openPlayerAfterDismiss = false; session.podcastPlayback.showingPlayer = true }
        }) { episode in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let image = SavedAudioNowPlayingInfo.image(cover) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 16)) }
                        Text(episode.title).font(.title2.bold())
                        Text(episode.objective).foregroundStyle(.secondary)
                        Button { Task { await play(episode, at: nil) } } label: {
                            Label(opening ? "Preparando audio…" : "Escuchar", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.borderedProminent).disabled(opening || episode.audioBytes <= 0).accessibilityIdentifier("podcast-listen")
                        if let issue { Text(issue).foregroundStyle(Color.nodusDanger) }
                        ForEach(episode.timeline?.chapters ?? [], id: \.index) { chapter in
                            Button { Task { await play(episode, at: chapter.startS) } } label: {
                                Label(chapter.title, systemImage: "play.circle").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }.disabled(opening || episode.audioBytes <= 0)
                        }
                        DisclosureGroup("Transcripción") {
                            ForEach(episode.script?.turns ?? []) { turn in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(turn.speaker).font(.caption.bold()).foregroundStyle(.secondary)
                                    Text(turn.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }.padding(.vertical, 6)
                            }
                        }
                        DisclosureGroup("Fuentes") {
                            ForEach(episode.sources ?? []) { source in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(source.title).font(.headline)
                                    CorpusProse(source.excerpt, accent: session.accent, session: session)
                                    if let link = source.link ?? source.url { CorpusProse("[Ver fuente](\(link))", accent: session.accent, session: session) }
                                }.padding(.vertical, 8)
                            }
                        }
                    }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
                }.navigationTitle("Podcast").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Cerrar") { selected = nil } } }

            }
        }
    }
    private func read<T: Decodable>(_ method: String, args: [JSONValue] = []) async throws -> T {
        let (vault, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
        let bridge = DesktopBridgeClient(pairing: pairing, token: token)
        let capabilities = try await bridge.liveCapabilities()
        guard capabilities.operations.contains(method) else {
            throw APIError(status: 426, code: "nodus_link_upgrade_required", message: "Actualiza Nodus Desktop con una versión compatible con Nodus Link para consultar los podcasts.")
        }
        let value = try await bridge.operation(vaultId: vault, method: method, args: args)
        return try JSONDecoder.nodus.decode(T.self, from: JSONEncoder.nodus.encode(value))
    }
    private func load() async {
        guard !session.isDemo else { episodes = []; issue = nil; return }
        guard !loading else { return }; loading = true; defer { loading = false }
        do { episodes = try await read("podcastEpisodes"); issue = nil }
        catch { issue = error.localizedDescription }
    }
    private func open(_ episode: LinkPodcast) async {
        let revision = UUID(); openingRevision = revision
        do {
            let detail: LinkPodcast? = try await read("podcastEpisode", args: [.string(episode.id)])
            guard revision == openingRevision else { return }
            guard let detail else { throw APIError(status: 404, code: "podcast_not_found", message: "Este episodio ya no está disponible.") }
            issue = nil; cover = nil; selected = detail
            let image = await loadCover(episode.id)
            if selected?.id == episode.id { cover = image }
        } catch { if revision == openingRevision { issue = error.localizedDescription } }
    }
    private func play(_ episode: LinkPodcast, at timestamp: Double?) async {
        guard !opening else { return }; opening = true; defer { opening = false }
        do {
            let copy = try await loadPrivateBridgeFile(session, kind: .podcastAudio, id: episode.id)
            if cover == nil { cover = await loadCover(episode.id) }
            let target = SavedAudioTarget(id: episode.id, label: episode.title, copy: copy, initialTimestamp: timestamp, resumeKey: "podcast-position:\(session.connection.storageId):\(episode.id)", backgroundPlayback: true, artworkData: cover)
            try await session.podcastPlayback.start(target)
            openPlayerAfterDismiss = true; selected = nil
            issue = nil
        } catch { issue = error.localizedDescription }
    }
    private func loadCover(_ episodeId: String) async -> Data? {
        for variant in ["thumbnail", "image"] {
            let image: String? = try? await read("podcastImageData", args: [.string(episodeId), .int(0), .string(variant)])
            if let image, let encoded = image.split(separator: ",", maxSplits: 1).last,
               let data = Data(base64Encoded: String(encoded)), SavedAudioNowPlayingInfo.image(data) != nil { return data }
        }
        return nil
    }
}
