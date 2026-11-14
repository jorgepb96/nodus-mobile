import NodusKit
import NodusUI
import SwiftUI

/// One bounded thumbnail cache for the two saved-media catalogues. No public image URLs.
@MainActor enum LinkMediaImages {
    enum Kind: String { case podcast, report }
    private static let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>(); cache.totalCostLimit = 20 * 1024 * 1024
        cache.countLimit = 80; return cache
    }()
    static func load(session: SpaceSession, kind: Kind, id: String, thumbnail: Bool = true) async throws -> Data? {
        guard !session.isDemo, session.connection.desktopPairingId != nil else { return nil }
        let key = "\(session.connection.storageId):\(kind.rawValue):\(id):\(thumbnail)" as NSString
        if let cached = cache.object(forKey: key) { return cached as Data }
        let (vault, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
        let client = DesktopBridgeClient(pairing: pairing, token: token)
        let result: JSONValue
        switch kind {
        case .podcast:
            result = try await client.operation(vaultId: vault, method: "podcastImageData", args: [.string(id), .int(0), .string(thumbnail ? "thumbnail" : "image")])
        case .report:
            result = try await client.operation(vaultId: vault, method: "getDecorativeImageDataUrl", args: [.string("deep_research"), .string(id), .bool(thumbnail)])
        }
        if result.stringValue == nil, thumbnail {
            let full = try await load(session: session, kind: kind, id: id, thumbnail: false)
            if let full { cache.setObject(full as NSData, forKey: key, cost: full.count) }
            return full
        }
        guard let url = result.stringValue, url.hasPrefix("data:image/"),
              let payload = url.split(separator: ",", maxSplits: 1).last,
              payload.utf8.count <= 12 * 1024 * 1024,
              let bytes = Data(base64Encoded: String(payload)), SavedAudioNowPlayingInfo.image(bytes) != nil else { return nil }
        try Task.checkCancellation()
        cache.setObject(bytes as NSData, forKey: key, cost: bytes.count)
        return bytes
    }
}

struct LinkMediaImage: View {
    let session: SpaceSession
    let kind: LinkMediaImages.Kind
    let id: String
    var thumbnail = true
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(session.accent.opacity(0.08))
            Image(systemName: kind == .podcast ? "headphones" : "doc.text.image")
                .font(.title2).foregroundStyle(session.accent.nodusReadable)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
        }.clipped().clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
            .task(id: "\(session.connection.id):\(kind.rawValue):\(id):\(thumbnail)") {
                image = nil
                do { if let data = try await LinkMediaImages.load(session: session, kind: kind, id: id, thumbnail: thumbnail) { image = SavedAudioNowPlayingInfo.image(data) } }
                catch { /* Missing/unavailable artwork never hides the saved text or audio. */ }
            }
    }
}

/// A report without a saved cover starts with its title, without an empty image block.
struct LinkReportHero: View {
    let session: SpaceSession
    let id: String
    let height: CGFloat
    @State private var image: UIImage?
    @State private var loading = true
    var body: some View {
        VStack(spacing: 0) {
            if let image {
                Image(uiImage: image).resizable().scaledToFill().frame(height: height).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("Report image").accessibilityIdentifier("link-report-cover")
            } else if loading { ProgressView().frame(height: 44).tint(session.accent) }
            else { Color.clear.frame(height: 0) }
        }.task(id: "\(session.connection.id):\(id)") {
            image = nil; loading = true
            defer { loading = false }
            do { if let data = try await LinkMediaImages.load(session: session, kind: .report, id: id, thumbnail: false) { image = SavedAudioNowPlayingInfo.image(data) } }
            catch { /* Text remains readable when optional cover artwork is unavailable. */ }
        }
    }
}
