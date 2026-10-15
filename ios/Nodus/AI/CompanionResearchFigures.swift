import Foundation
import NodusKit
import NodusUI
import SwiftUI
import UIKit

/// Consults the exact authored figure receipts. No Mac request or provider is
/// involved, including when a figure is opened after publication or recovery.
struct CompanionResearchFigures: View {
    let session: SpaceSession
    let reportID: String
    @State private var figures: [JSONValue] = []
    @State private var receipts: [CompanionDocumentFigureAssets.Receipt] = []
    @State private var issue: String?
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            if let issue { NodusNotice(tone: .blocked, title: "Could not open image", message: LocalizedStringKey(issue)) }
            ForEach(Array(figures.enumerated()), id: \.offset) { index, figure in
                if let object = figure.objectValue {
                    VStack(alignment: .leading, spacing: 8) {
                        if let poster = object["poster"]?.stringValue,
                           let receipt = receipts.first(where: { poster == "nodus-image://chat/\($0.owner)/\($0.id.uuidString.lowercased())" }) {
                            CompanionResearchFigureImage(session: session, receipt: receipt, caption: object["caption"]?.stringValue ?? "")
                        } else if object["state"] != .string("ready") {
                            NodusNotice(tone: .blocked, title: "Figura pendiente", message: LocalizedStringKey(object["error"]?.stringValue ?? "La figura no tiene una imagen confirmada. Su estado permanece guardado en la investigación."))
                        } else { NodusNotice(tone: .blocked, title: "Could not open image", message: "Falta el recibo de esta figura. El informe no lo sustituirá por otra imagen.") }
                        Text("Figura \(index + 1). \(object["caption"]?.stringValue ?? "")").font(.caption).fixedSize(horizontal: false, vertical: true)
                        let sources = object["sources"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        if !sources.isEmpty {
                            CorpusProse(sources.enumerated().map { "[\($0.offset + 1)](\($0.element))" }.joined(separator: " · "), accent: session.accent, session: session)
                                .environment(\.authoredResearchReaderID, reportID)
                        }
                    }
                }
            }
        }
        .task(id: reportID) {
            figures = []; receipts = []; issue = nil
            do {
                guard let checkpoint = try await CompanionDeepResearchResult.checkpoint(session: session, id: reportID, publishedReceipt: !reportID.hasPrefix("mobile-dr-")),
                      let object = checkpoint.objectValue,
                      let values = object["report"]?.objectValue?["mobileVisuals"]?.objectValue?["manifest"]?.objectValue?["figures"]?.arrayValue,
                      let entity = object["entityKey"]?.stringValue, let generation = UUID(uuidString: object["id"]?.stringValue ?? "") else { return }
                let scope = try session.surfaceStorageScope(), cache = try PrivateBridgeCache(pairingId: scope.cacheId)
                let loaded = try await CompanionDocumentFigureAssets(cache: cache, vaultId: scope.recordVaultId).receipts(parentRecordId: CompanionGenerationPublication.recordId(kind: "deepResearch", entity: entity), generationId: generation)
                try Task.checkCancellation(); figures = values; receipts = loaded
            } catch is CancellationError { }
            catch { issue = error.localizedDescription }
        }
    }
}
private struct CompanionResearchFigureImage: View {
    let session: SpaceSession
    let receipt: CompanionDocumentFigureAssets.Receipt
    let caption: String
    @State private var content: ReaderImageSource.Content?
    @State private var preview: UIImage?
    @State private var issue: String?
    @State private var attempt = 0
    @State private var showing = false
    var body: some View {
        Group {
            if let preview {
                Button { showing = true } label: { Image(uiImage: preview).resizable().scaledToFit() }.buttonStyle(.plain).accessibilityLabel(caption)
            } else if let issue {
                VStack { NodusNotice(tone: .blocked, title: "Could not open image", message: LocalizedStringKey(issue)); Button("Retry") { attempt += 1 }.frame(minHeight: 44) }
            } else { ProgressView().frame(maxWidth: .infinity, minHeight: 80) }
        }
        .task(id: "\(receipt.id)|\(attempt)") {
            do {
                let scope = try session.surfaceStorageScope(), cache = try PrivateBridgeCache(pairingId: scope.cacheId)
                guard receipt.vaultId == scope.recordVaultId else { throw DesktopBridgeError.permissionDenied }
                let data = try await CompanionDocumentFigureAssets(cache: cache, vaultId: scope.recordVaultId).data(receipt)
                let image = try ReaderRasterImage.preview(data)
                try Task.checkCancellation(); content = .init(data: data, mime: receipt.mimeType); preview = image; issue = nil
            } catch is CancellationError { }
            catch { issue = error.localizedDescription }
        }
        .onDisappear { if !showing { content = nil; preview = nil } }
        .nodusSheet(isPresented: $showing) {
            if let content { ReaderImageViewer(content: content, image: preview, title: caption, accent: session.accent) }
        }
    }
}
