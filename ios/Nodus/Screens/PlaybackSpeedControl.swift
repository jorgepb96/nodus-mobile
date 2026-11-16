import NodusUI
import SwiftUI

/// Playback speed in 0.05× steps from 0.75× to 2×, with the quarter marks one tap away.
///
/// A menu of five fixed speeds made 1.1× or 1.35× impossible to choose, and those in-between
/// values are exactly what someone tuning a voice for listening wants. The minus and plus buttons
/// make the small change; the slider makes a large one; the milestone chips go straight back to
/// a round speed.
struct PlaybackSpeedControl: View {
    let rate: Float
    let accent: Color
    let onChange: (Float) -> Void

    static let range: ClosedRange<Float> = 0.75...2
    static let step: Float = 0.05
    static let milestones: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    /// Rounded to the nearest step and held inside the range.
    static func snapped(_ value: Float) -> Float {
        min(range.upperBound, max(range.lowerBound, (value * 20).rounded() / 20))
    }

    static func label(_ value: Float) -> String {
        value.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                stepButton("minus", delta: -Self.step, label: "Slower")
                VStack(spacing: 1) {
                    Text("Playback speed").font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: Self.label(rate))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText(value: Double(rate)))
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                stepButton("plus", delta: Self.step, label: "Faster")
            }

            Slider(
                value: Binding(get: { Double(rate) }, set: { change(to: Float($0)) }),
                in: Double(Self.range.lowerBound)...Double(Self.range.upperBound),
                step: Double(Self.step)
            )
            .accessibilityLabel("Playback speed")
            .accessibilityValue(Text(verbatim: Self.label(rate)))

            HStack(spacing: 6) {
                ForEach(Self.milestones, id: \.self) { milestone in
                    let selected = abs(rate - milestone) < 0.001
                    Button { change(to: milestone) } label: {
                        Text(verbatim: Self.label(milestone))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .foregroundStyle(selected ? accent.nodusReadable : Color.primary.opacity(0.75))
                            .background(selected ? accent.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(NodusMotion.press, value: rate)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("saved-audio-speed")
    }

    private func stepButton(_ image: String, delta: Float, label: LocalizedStringKey) -> some View {
        let next = Self.snapped(rate + delta)
        return Button { change(to: next) } label: {
            Image(systemName: image)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(accent.nodusReadable)
                .frame(width: 44, height: 44)
                .background(accent.opacity(0.16), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .disabled(next == rate)
        .opacity(next == rate ? 0.35 : 1)
        .accessibilityLabel(label)
    }

    private func change(to value: Float) {
        let snapped = Self.snapped(value)
        guard snapped != rate else { return }
        onChange(snapped)
    }
}
