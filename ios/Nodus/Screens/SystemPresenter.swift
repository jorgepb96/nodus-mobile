import UIKit

/// Presents UIKit's own sheets (share, Open In) from whatever is frontmost.
///
/// `ShareLink` inside the resident route stacks could fail silently: the hosting controller
/// it presents from is not always the one on screen, and the report's PDF button then did
/// nothing at all. Presenting from the top-most controller of the active window is the path
/// that always has a window to present in.
@MainActor
enum SystemPresenter {
    /// Kept alive for as long as its menu is up; UIKit holds it only weakly.
    private static var documentController: UIDocumentInteractionController?

    static func share(_ items: [Any]) {
        guard let top = topController() else { return }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        anchor(controller.popoverPresentationController, in: top.view)
        top.present(controller, animated: true)
    }

    /// The system's "Open in…" list for one file. Returns false when no installed app
    /// declares the file's type.
    @discardableResult
    static func openIn(_ url: URL, uti: String? = nil) -> Bool {
        guard let view = topController()?.view else { return false }
        let controller = UIDocumentInteractionController(url: url)
        if let uti { controller.uti = uti }
        documentController = controller
        let rect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        return controller.presentOpenInMenu(from: rect, in: view, animated: true)
    }

    private static func anchor(_ popover: UIPopoverPresentationController?, in view: UIView) {
        guard let popover else { return }
        popover.sourceView = view
        popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        popover.permittedArrowDirections = []
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}
