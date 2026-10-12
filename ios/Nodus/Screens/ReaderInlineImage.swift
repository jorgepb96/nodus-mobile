import NodusKit
import NodusUI
import SwiftUI
import UIKit
import WebKit

struct ReaderInlineImage: View {
    let reference: ReaderImageSource.Reference
    let session: SpaceSession?
    let accent: Color
    var downloadedOnly = false
    @Environment(\.downloadedReaderOnly) private var inheritedDownloadedOnly
    private var selectedReaderOnly: Bool { downloadedOnly || inheritedDownloadedOnly }
    @State private var content: ReaderImageSource.Content?
    @State private var loadedDownloadedOnly: Bool?
    @State private var preview: UIImage?
    @State private var issue: String?
    @State private var attempt = 0
    @State private var showingImage = false
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            if let content, loadedDownloadedOnly == selectedReaderOnly {
                Button { showingImage = true } label: {
                    visual(content).frame(maxWidth:.infinity)
                }.buttonStyle(.plain).accessibilityLabel(reference.alternative.isEmpty ? String(localized:"Open image"):reference.alternative)
            } else if let issue {
                NodusNotice(tone:.blocked,title:"Could not open image",message:LocalizedStringKey(issue))
                Button("Retry") { attempt += 1 }.frame(minHeight:44)
            } else { ProgressView().frame(maxWidth:.infinity,minHeight:72) }
        }
        .task(id:"\(reference.id)|\(selectedReaderOnly)|\(attempt)") {
            content = nil;preview = nil;issue = nil;loadedDownloadedOnly = nil
            do {
                let loaded = try await ReaderImageSource.load(reference.source,session:session,downloadedOnly:selectedReaderOnly)
                guard ReaderImageSource.supported(loaded.mime) else { throw DesktopBridgeError.malformedResponse }
                let decoded = loaded.mime == "image/svg+xml" ? nil:try ReaderRasterImage.preview(loaded.data)
                let image = loaded.mime == "image/gif" ? nil:decoded
                try Task.checkCancellation();preview = image;content = loaded;issue = nil;loadedDownloadedOnly = selectedReaderOnly
            } catch is CancellationError { /* A disappeared reader must not replace its next image. */ }
            catch { issue = error.localizedDescription }
        }
        .nodusSheet(isPresented:$showingImage) {
            if let content, loadedDownloadedOnly == selectedReaderOnly { ReaderImageViewer(content:content,image:preview,title:reference.alternative.isEmpty ? String(localized:"Image"):reference.alternative,accent:accent) }
            else { ContentUnavailableView("Image not downloaded", systemImage: "arrow.down.circle") }
        }
    }
    @ViewBuilder private func visual(_ content: ReaderImageSource.Content) -> some View {
        if let image = preview {
            Image(uiImage:image).resizable().scaledToFit().accessibilityLabel(reference.alternative)
        } else {
            ReaderVectorImage(content:content).frame(height:280).accessibilityLabel(reference.alternative)
        }
    }
}

/// SVG stays an image subresource. No source scripts, navigation, external
/// images/fonts or document access run inside the isolated renderer.
struct ReaderVectorImage: UIViewRepresentable {
    let content: ReaderImageSource.Content
    var allowsZoom = false
    var fit = "contain"
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame:.zero,configuration:config)
        view.isOpaque = false;view.backgroundColor = .clear;view.scrollView.isScrollEnabled = allowsZoom
        let source = content.data.base64EncodedString()
        let imageFit=fit == "cover" ? "cover":"contain"
        view.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1,maximum-scale=5'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'\"><style>html,body{margin:0;width:100%;height:100%;background:transparent}img{display:block;width:100%;height:100%;object-fit:\(imageFit)}</style><img src='data:\(content.mime);base64,\(source)' alt=''>",baseURL:nil)
        return view
    }
    func updateUIView(_ view: WKWebView,context: Context) {}
    static func dismantleUIView(_ view: WKWebView,coordinator: ()) { view.stopLoading() }
}
