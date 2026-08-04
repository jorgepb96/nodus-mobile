import CoreGraphics
import Foundation
import Testing
@testable import Nodus

/// When a touch on a cited report counts as choosing a citation.
///
/// The reported symptom: scrolling a Deep Research report opened whatever citation the finger
/// happened to pass over. A `UITextView` acts on a link at touch-up, and touch-up is also how a
/// drag ends and how the tap that stops a still-gliding page ends. All three looked identical to
/// UIKit, so a reader who touched the screen to slow it down got a sheet instead.
///
/// The rule is small enough to state as data, which is why it is a value type rather than
/// something buried in a gesture recognizer: the recognizer only records, and this decides.
@Suite("Tap intent")
struct TapIntentTests {
    @Test("a still touch on a still page opens the citation")
    func deliberateTapOpens() {
        #expect(TapIntent().opensCitation)
    }

    @Test("a touch that lands on a moving page is a brake, not a choice")
    func brakingDoesNotOpen() {
        // The one that could not be decided at the end. Tapping a decelerating scroll view stops
        // it, so by the time UIKit asks what to do about the link, nothing is decelerating and
        // the touch is indistinguishable from a deliberate tap. It has to be caught on the way in.
        #expect(!TapIntent(beganWhileScrolling: true).opensCitation)
    }

    @Test("a finger that travels was scrolling, however it ended")
    func draggingDoesNotOpen() {
        #expect(!TapIntent(movedTooFar: true).opensCitation)
        #expect(!TapIntent(beganWhileScrolling: true, movedTooFar: true).opensCitation)
    }

    @Test("the slop is wide enough for a thumb and narrower than a scroll")
    func slopIsHumanSized() {
        // A thumb reaching across a phone drifts a few points on the way down without meaning
        // anything by it, so too tight a threshold refuses taps a reader did intend. A scroll
        // moves far more than this before the finger lifts.
        #expect(TapIntent.slop >= 10)
        #expect(TapIntent.slop <= 20)
    }
}
