import NodusKit
import NodusUI
import SwiftUI
import UIKit
import WebKit

struct ReaderInlineImage: View {
    let reference: ReaderImageSource.Reference
    let session: SpaceSession?
    let accent: Color
    @State private var content: ReaderImageSource.Content?
    @State private var issue: String?
    @State private var attempt = 0
    @State private var showingImage = false
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            if let content {
                Button { showingImage = true } label: {
                    visual(content).frame(maxWidth:.infinity)
                }.buttonStyle(.plain).accessibilityLabel(reference.alternative.isEmpty ? String(localized:"Open image"):reference.alternative)
            } else if let issue {
                NodusNotice(tone:.blocked,title:"Could not open image",message:LocalizedStringKey(issue))
                Button("Retry") { attempt += 1 }.frame(minHeight:44)
            } else { ProgressView().frame(maxWidth:.infinity,minHeight:72) }
        }
        .task(id:"\(reference.id)|\(attempt)") {
            do {
                let loaded = try await ReaderImageSource.load(reference.source,session:session)
                guard loaded.mime == "image/svg+xml" || UIImage(data:loaded.data) != nil else { throw DesktopBridgeError.malformedResponse }
                try Task.checkCancellation();content = loaded;issue = nil
            } catch is CancellationError { /* A disappeared reader must not replace its next image. */ }
            catch { issue = error.localizedDescription }
        }
        .nodusSheet(isPresented:$showingImage) {
            NavigationStack {
                if let content {
                    ScrollView([.horizontal,.vertical]) { visual(content).frame(minWidth:280).padding(16) }
                        .navigationTitle(reference.alternative.isEmpty ? String(localized:"Image"):reference.alternative)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Done") { showingImage = false } } }
                }
            }.tint(accent)
        }
    }
    @ViewBuilder private func visual(_ content: ReaderImageSource.Content) -> some View {
        if let image = UIImage(data:content.data) {
            Image(uiImage:image).resizable().scaledToFit().accessibilityLabel(reference.alternative)
        } else {
            ReaderVectorImage(content:content).frame(height:280).accessibilityLabel(reference.alternative)
        }
    }
}

/// SVG stays an image subresource. No source scripts, navigation, external
/// images/fonts or document access run inside the isolated renderer.
private struct ReaderVectorImage: UIViewRepresentable {
    let content: ReaderImageSource.Content
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame:.zero,configuration:config)
        view.isOpaque = false;view.backgroundColor = .clear;view.scrollView.isScrollEnabled = false
        let source = content.data.base64EncodedString()
        view.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'\"><style>html,body{margin:0;width:100%;height:100%;background:transparent}img{display:block;width:100%;height:100%;object-fit:contain}</style><img src='data:image/svg+xml;base64,\(source)' alt=''>",baseURL:nil)
        return view
    }
    func updateUIView(_ view: WKWebView,context: Context) {}
    static func dismantleUIView(_ view: WKWebView,coordinator: ()) { view.stopLoading() }
}
