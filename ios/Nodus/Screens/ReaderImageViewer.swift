import ImageIO
import NodusKit
import NodusUI
import SwiftUI
import UIKit

enum ReaderRasterImage {
    /// Decode once at a bounded display size. The original encoded bytes stay
    /// intact for sharing; very large source images do not allocate full pixels.
    static func preview(_ data: Data,maxPixelSize: Int = 2048) throws -> UIImage {
        guard maxPixelSize > 0,maxPixelSize <= 4096,let source = CGImageSourceCreateWithData(data as CFData,nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:maxPixelSize,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { throw DesktopBridgeError.malformedResponse }
        return UIImage(cgImage:image)
    }
}

struct ReaderImageViewer: View {
    let content: ReaderImageSource.Content
    let image: UIImage?
    let title: String
    let accent: Color
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var lease: PrivateBridgeFileLease?
    @State private var showingShare = false
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                if let image { ReaderZoomImage(image:image,zoom:$zoom).accessibilityLabel(title) }
                else { ReaderVectorImage(content:content,allowsZoom:true).accessibilityLabel(title) }
                if let issue { NodusNotice(tone:.blocked,title:"No se ha podido compartir la imagen",message:LocalizedStringKey(issue)).padding() }
                if image != nil {
                    HStack {
                        Button { zoom = max(1,zoom - 0.5) } label: { Image(systemName:"minus.magnifyingglass").frame(width:44,height:44) }.disabled(zoom <= 1).accessibilityLabel("Reducir")
                        Button { zoom = 1 } label: { Text("\(Int(zoom * 100)) %").monospacedDigit().frame(minWidth:60,minHeight:44) }.accessibilityLabel("Ajustar a pantalla")
                        Button { zoom = min(5,zoom + 0.5) } label: { Image(systemName:"plus.magnifyingglass").frame(width:44,height:44) }.disabled(zoom >= 5).accessibilityLabel("Ampliar")
                    }.buttonStyle(.plain)
                }
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("Listo") { dismiss() } }
                    ToolbarItem(placement:.primaryAction) { Button(action:share) { Image(systemName:"square.and.arrow.up").frame(minWidth:44,minHeight:44) }.accessibilityLabel("Compartir imagen original") }
                }
                .sheet(isPresented:$showingShare,onDismiss:{ lease = nil }) { if let lease { ReaderImageShareSheet(lease:lease) } }
        }.tint(accent)
    }
    private func share() {
        do {
            let suffix = ["image/png":"png","image/jpeg":"jpg","image/gif":"gif","image/webp":"webp","image/avif":"avif","image/svg+xml":"svg"][content.mime]
            guard let suffix else { throw DesktopBridgeError.malformedResponse }
            guard content.data.count <= ReaderImageSource.maximumBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            lease = try PrivateBridgeFileLease.write(content.data,filename:"Nodus-image.\(suffix)")
            showingShare = true;issue = nil
        } catch { issue = error.localizedDescription }
    }
}

private struct ReaderImageShareSheet: UIViewControllerRepresentable {
    let lease: PrivateBridgeFileLease
    final class Coordinator { let lease: PrivateBridgeFileLease;init(_ lease: PrivateBridgeFileLease) { self.lease = lease } }
    func makeCoordinator() -> Coordinator { Coordinator(lease) }
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems:[lease.url],applicationActivities:nil) }
    func updateUIViewController(_ view: UIActivityViewController,context: Context) {}
}

private struct ReaderZoomImage: UIViewRepresentable {
    let image: UIImage
    @Binding var zoom: CGFloat
    func makeCoordinator() -> Coordinator { Coordinator($zoom) }
    func makeUIView(context: Context) -> ImageScrollView {
        let view = ImageScrollView(image:image);view.delegate = context.coordinator
        let tap = UITapGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.doubleTap(_:)));tap.numberOfTapsRequired = 2;view.addGestureRecognizer(tap)
        return view
    }
    func updateUIView(_ view: ImageScrollView,context: Context) {
        context.coordinator.zoom = $zoom
        if abs(view.zoomScale - zoom) > 0.01 { view.setZoomScale(zoom,animated:true) }
    }
    final class Coordinator: NSObject,UIScrollViewDelegate {
        var zoom: Binding<CGFloat>
        init(_ zoom: Binding<CGFloat>) { self.zoom = zoom }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? ImageScrollView)?.imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { (scrollView as? ImageScrollView)?.centerImage();if abs(zoom.wrappedValue - scrollView.zoomScale) > 0.01 { zoom.wrappedValue = scrollView.zoomScale } }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? ImageScrollView else { return }
            if view.zoomScale > 1.1 { view.setZoomScale(1,animated:true);return }
            let point = gesture.location(in:view.imageView),scale: CGFloat = 2.5
            let rect = CGRect(x:point.x-view.bounds.width/(2*scale),y:point.y-view.bounds.height/(2*scale),width:view.bounds.width/scale,height:view.bounds.height/scale)
            view.zoom(to:rect,animated:true)
        }
    }
    final class ImageScrollView: UIScrollView {
        let imageView: UIImageView
        private var lastSize: CGSize = .zero
        init(image: UIImage) {
            imageView = UIImageView(image:image);super.init(frame:.zero)
            minimumZoomScale = 1;maximumZoomScale = 5;contentInsetAdjustmentBehavior = .never
            showsHorizontalScrollIndicator = false;showsVerticalScrollIndicator = false;bouncesZoom = true
            imageView.contentMode = .scaleAspectFit;addSubview(imageView)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != lastSize,bounds.width > 0,bounds.height > 0,let size = imageView.image?.size,size.width > 0,size.height > 0 {
                lastSize = bounds.size;setZoomScale(1,animated:false)
                let ratio = min(bounds.width/size.width,bounds.height/size.height)
                imageView.frame = CGRect(origin:.zero,size:CGSize(width:size.width*ratio,height:size.height*ratio));contentSize = imageView.bounds.size
            }
            centerImage()
        }
        func centerImage() { imageView.center = CGPoint(x:max(contentSize.width,bounds.width)/2,y:max(contentSize.height,bounds.height)/2) }
    }
}
