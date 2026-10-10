import Foundation
import SwiftUI
import Testing
@testable import Nodus

/// The A⁺/A⁻ control, and the crash it shipped with.
///
/// The property clamped itself inside its own `didSet`. On a plain stored property that is
/// legal and does nothing surprising; on an `@Observable` one the macro has rewritten the
/// property as computed, so the assignment calls the setter again — the app went down the stack
/// the first time anybody enlarged a report. These are cheap, and the first of them does not
/// fail if that comes back: it hangs and then dies, which is exactly what the app did.
@Suite("Reading size")
struct ReadingSizeTests {
    /// `cloud: nil` throughout: these are about the control, not about the sync, and a real
    /// ubiquitous store would make them depend on whether the machine running them is signed
    /// into iCloud.
    private func preferences(_ name: String) -> AppPreferences {
        let defaults = UserDefaults(suiteName: "nodus.tests.\(name)")!
        defaults.removePersistentDomain(forName: "nodus.tests.\(name)")
        return AppPreferences(store: SyncedDefaults(defaults: defaults, cloud: nil))
    }

    @Test("one step up is one step, and it comes back")
    func stepping() {
        let prefs = preferences("stepping")
        #expect(prefs.readingScale == 1)

        prefs.adjustReading(by: AppPreferences.readingScaleStep)
        #expect(abs(prefs.readingScale - (1 + AppPreferences.readingScaleStep)) < 0.0001)

        prefs.adjustReading(by: -AppPreferences.readingScaleStep)
        #expect(abs(prefs.readingScale - 1) < 0.0001)
    }

    @Test("holding either end stops there rather than running off it")
    func clamping() {
        let prefs = preferences("clamping")
        for _ in 0..<40 { prefs.adjustReading(by: AppPreferences.readingScaleStep) }
        #expect(prefs.readingScale == AppPreferences.maxReadingScale)
        #expect(!prefs.canEnlargeReading)
        #expect(prefs.canShrinkReading)

        for _ in 0..<40 { prefs.adjustReading(by: -AppPreferences.readingScaleStep) }
        #expect(prefs.readingScale == AppPreferences.minReadingScale)
        #expect(!prefs.canShrinkReading)
        #expect(prefs.canEnlargeReading)
    }

    @Test("the size outlives the report it was chosen in")
    func persisted() {
        let name = "persisted"
        let prefs = preferences(name)
        prefs.adjustReading(by: AppPreferences.readingScaleStep)
        let chosen = prefs.readingScale

        let reopened = AppPreferences(
            store: SyncedDefaults(defaults: UserDefaults(suiteName: "nodus.tests.\(name)")!, cloud: nil)
        )
        #expect(abs(reopened.readingScale - chosen) < 0.0001)
    }

    /// The style is a multiplier over Dynamic Type, not a replacement for it: at 1 it must hand
    /// back exactly the size the rest of the app is set in.
    @Test("scale 1 is the system's own size")
    func neutralScale() {
        #expect(ReadingStyle.plain.scale == 1)
        #expect(!ReadingStyle.plain.document)
        #expect(ReadingStyle(scale: 2).size(.body) == ReadingStyle.plain.size(.body) * 2)
    }

    @Test("an overridden accessible size enlarges native prose and preserves reader zoom")
    func accessibleEnvironmentSize() {
        let plain = ReadingStyle.plain
        let normal = plain.size(.callout, dynamicTypeSize: .large)
        let accessible = plain.size(.callout, dynamicTypeSize: .accessibility3)
        #expect(accessible > normal * 1.8)
        #expect(plain.uiFont(.callout, dynamicTypeSize: .accessibility3).pointSize == accessible)
        #expect(ReadingStyle(scale: 1.5).size(.callout, dynamicTypeSize: .accessibility3) == accessible * 1.5)
        let sizes = DynamicTypeSize.allCases.map { plain.size(.callout, dynamicTypeSize: $0) }
        #expect(zip(sizes, sizes.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("shared components preserve every system text size without an accessibility cap")
    func sharedSurfaceDynamicType() {
        #expect(ReadingStyle.sharedSurfaceScale(for: .large) == 1)
        #expect(ReadingStyle.sharedSurfaceScale(for: .accessibility3) > 1.8)
        let sizes = DynamicTypeSize.allCases.map { ReadingStyle.sharedSurfaceScale(for: $0) }
        #expect(zip(sizes, sizes.dropFirst()).allSatisfy { $0 < $1 })
        #expect(sizes.allSatisfy { $0.isFinite && $0 > 0 })
    }
}
