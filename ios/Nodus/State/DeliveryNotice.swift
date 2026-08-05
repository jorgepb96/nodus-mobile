import Foundation
import NodusKit
import UserNotifications

/// Saying, once, that something you waited for reached its vault.
///
/// Only a Deep Research report earns this. A report is twenty minutes and a model call per
/// section, started on a phone and finished somewhere the author cannot see; a note is three
/// words they typed and watched appear in the queue. Notifying about both would teach people to
/// dismiss the one that matters, so the decision is made on `entity_kind` — the same value the
/// phone itself wrote into the row, and the same one the desktop's inbox records.
///
/// There is no push here and there will not be. A self-hosted server has no Apple certificate,
/// and a relay to give it one is a different product; what raises these is the check that runs
/// when the app comes back and the one the refresh task runs on its own.
enum DeliveryNotice {
    /// - Parameter mayAsk: whether this pass is allowed to ask for permission. Only true in the
    ///   foreground: `requestAuthorization` shows its prompt only to an app that is on screen,
    ///   and asking from a background window would spend the single prompt iOS ever gives on a
    ///   moment when nobody is there to answer it. A background pass that finds no permission
    ///   stays quiet and lets the next foreground one ask.
    static func announce(_ landings: [MutationDelivery.Landing], mayAsk: Bool) async {
        let worthSaying = landings.flatMap { landing in
            landing.items
                .filter { $0.entityKind == ReportDraft.entityKind }
                .map { (item: $0, spaceName: landing.connection.spaceName) }
        }
        guard !worthSaying.isEmpty else { return }

        let centre = UNUserNotificationCenter.current()
        switch await centre.notificationSettings().authorizationStatus {
        case .notDetermined:
            // Asked here rather than at launch, which is the difference between a question with
            // a reason behind it and one that arrives before the app has done anything.
            guard mayAsk, (try? await centre.requestAuthorization(options: [.alert])) == true else { return }
        case .denied:
            return
        default:
            break
        }

        for (item, spaceName) in worthSaying {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Your report is in the vault")
            // Precise on purpose. The desktop applying a change is not the desktop republishing
            // it, and until it republishes nobody reads the report back — its author included.
            content.body = String(localized: "“\(item.title)” reached \(spaceName). Nobody reads it back, you included, until its owner republishes.")
            // The mutation id, so the same delivery announced twice replaces its own notification
            // instead of stacking a second one.
            let request = UNNotificationRequest(identifier: "delivered.\(item.id)", content: content, trigger: nil)
            try? await centre.add(request)
        }
    }
}
