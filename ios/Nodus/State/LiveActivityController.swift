import Foundation
import NodusUI

#if canImport(ActivityKit)
import ActivityKit
#endif

/// Starts, updates and ends the Dynamic Island presentation for long jobs.
///
/// Everything here degrades quietly. Live Activities need iOS 16.2, need the user to have left
/// them enabled, and are refused outright when the system is busy — none of which should stop
/// a Deep Research run. So every call is best-effort: if the island never appears, the work
/// still happens and the in-app progress view is unaffected.
@MainActor
final class LiveActivityController {
    #if canImport(ActivityKit)
    /// ActivityKit hands back an opaque, non-Sendable handle whose mutators run off the main
    /// actor. Only the Sendable identifier is kept here; each mutation resolves a fresh handle
    /// inside the task that performs it, so no main-actor reference is sent to those methods.
    @available(iOS 16.2, *)
    private var activityId: String?
    /// Updates and the final dismissal share one chain, so the island can never be ended
    /// before the progress that was reported just before it.
    private var pending: Task<Void, Never>?
    private var finished = false
    #endif

    private let kindRawValue: String
    private let title: String
    private let accentHex: String
    private let spaceName: String

    init(kind: ActivityKind, title: String, accentHex: String, spaceName: String) {
        kindRawValue = kind.rawValue
        self.title = title
        self.accentHex = accentHex
        self.spaceName = spaceName
    }

    enum ActivityKind: String {
        case deepResearch, snapshotImport, mutationFlush, imageGeneration
    }

    func start() {
        #if canImport(ActivityKit) && os(iOS)
        guard #available(iOS 16.2, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let kind = NodusActivityAttributes.Kind(rawValue: kindRawValue) else { return }

        let attributes = NodusActivityAttributes(
            kind: kind,
            title: title,
            accentHex: accentHex,
            spaceName: spaceName
        )
        let state = NodusActivityAttributes.ContentState(phase: .queued)
        let requested = try? Activity.request(
            attributes: attributes,
            content: .init(state: state, staleDate: nil)
        )
        guard let requested else { return }
        activityId = requested.id
        pending = nil
        finished = false
        #endif
    }

    func update(
        phase: String,
        detail: String? = nil,
        fraction: Double? = nil,
        step: Int? = nil,
        stepCount: Int? = nil
    ) {
        #if canImport(ActivityKit) && os(iOS)
        guard #available(iOS 16.2, *), !finished, let activityId else { return }
        guard let phase = NodusActivityAttributes.Phase(rawValue: phase) else { return }
        let state = NodusActivityAttributes.ContentState(
            phase: phase,
            fraction: fraction,
            detail: detail,
            step: step,
            stepCount: stepCount
        )
        let previous = pending
        pending = Task.detached {
            await previous?.value
            guard let activity = Activity<NodusActivityAttributes>.activities.first(where: { $0.id == activityId }) else { return }
            await activity.update(.init(state: state, staleDate: nil))
        }
        #endif
    }

    /// Ends the activity. A failure keeps it on screen briefly rather than vanishing: a run
    /// that cost real money and then failed deserves to say so where the user is looking.
    func finish(failure: String? = nil) {
        #if canImport(ActivityKit) && os(iOS)
        guard #available(iOS 16.2, *), !finished, let activityId else { return }
        finished = true
        self.activityId = nil
        let state = NodusActivityAttributes.ContentState(
            phase: .done,
            fraction: failure == nil ? 1 : nil,
            detail: failure == nil ? "Finished" : nil,
            failure: failure
        )
        let dismissal: ActivityUIDismissalPolicy = failure == nil ? .after(.now + 4) : .after(.now + 30)
        let previous = pending
        pending = Task.detached {
            await previous?.value
            guard let activity = Activity<NodusActivityAttributes>.activities.first(where: { $0.id == activityId }) else { return }
            await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: dismissal)
        }
        #endif
    }
}
