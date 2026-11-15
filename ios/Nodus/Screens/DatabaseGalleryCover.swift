import NodusKit
import SwiftUI
import UIKit

/// Visible cards load their actual vault-owned file; disappearing cards release pixels.
struct DatabaseGalleryCover:View {
    let session:SpaceSession
    let kind:DesktopBridgeFileKind
    let id:String
    let fit:String
    let downloadedOnly:Bool
    @State private var image:UIImage?
    @State private var vector:ReaderImageSource.Content?
    @State private var issue:String?
    @State private var attempt = 0
    var body:some View {
        ZStack {
            session.accent.opacity(0.08)
            if let image {
                if fit == "contain" { Image(uiImage:image).resizable().scaledToFit() }
                else { Image(uiImage:image).resizable().scaledToFill() }
            } else if let vector { ReaderVectorImage(content:vector,fit:fit).allowsHitTesting(false) }
            else if let issue { VStack(spacing:6){Image(systemName:"photo.badge.exclamationmark");Text("Portada no disponible").font(.caption).multilineTextAlignment(.center)}.foregroundStyle(.secondary).accessibilityLabel(issue) }
            else { ProgressView().tint(session.accent) }
        }.clipped()
        .contextMenu { Button("Recargar portada",systemImage:"arrow.clockwise"){attempt += 1} }
        .task(id:"\(kind.rawValue):\(id):\(session.companionPublicationRevision):\(attempt)") {
            image=nil;vector=nil;issue=nil
            do {
                let copy=try await loadPrivateBridgeFile(session,kind:kind,id:id,downloadedOnly:downloadedOnly)
                guard ReaderImageSource.supported(copy.descriptor.mime),copy.descriptor.byteSize <= ReaderImageSource.maximumBytes else { throw DesktopBridgeError.malformedResponse }
                let bytes=try Data(contentsOf:copy.url);try Task.checkCancellation()
                let mime = copy.descriptor.mime.lowercased()
                if ["image/svg+xml","image/gif"].contains(mime) {
                    vector = .init(data:bytes,mime:mime)
                } else { image=try ReaderRasterImage.preview(bytes,maxPixelSize:512) }
            } catch where error.isCancellation {}
            catch { issue=error.localizedDescription }
        }
        .onDisappear{image=nil;vector=nil}
    }
}
