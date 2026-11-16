import NodusUI
import SwiftUI

/// An icon-only choice between a few layouts (grid, list, table), drawn as one glass control.
///
/// A native segmented `Picker` with symbol images renders its unselected symbols in a dark
/// template colour that nearly disappears in dark mode, and it never matched the glass icon
/// buttons beside it. This control owns its colours: the selected segment carries the accent,
/// the others the primary colour at reduced strength, both legible in either appearance.
struct NodusIconSegmentedPicker<Value: Hashable>: View {
    struct Option {
        let value: Value
        let systemImage: String
        let label: LocalizedStringKey
    }

    @Binding var selection: Value
    let options: [Option]
    let accent: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button {
                    withAnimation(NodusMotion.press) { selection = option.value }
                } label: {
                    Image(systemName: option.systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(selected ? accent.nodusReadable : Color.primary.opacity(0.72))
                        .frame(width: 40, height: 38)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accent.opacity(0.2))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(height: 44)
        .nodusGlass(NodusGlass(.regular, tint: accent, interactive: true), in: NodusRadius.controlShape)
        .overlay {
            NodusRadius.controlShape
                .strokeBorder(accent.opacity(0.32), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }
}
