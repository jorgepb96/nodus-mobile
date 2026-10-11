import NodusUI
import SwiftUI

/// The canonical value and diagnostic stay together in every native inspector.
struct DatabaseComputedValue: View {
    let value: String
    let error: String?
    let color: String?

    var body: some View {
        if let error, !error.isEmpty {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(value.isEmpty ? String(localized: "Sin valor calculado") : value)
                .foregroundStyle(tint ?? .primary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var tint: Color? {
        guard let color else { return nil }
        if color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil { return Color(hex: color) }
        switch color.lowercased() {
        case "red": return Color(hex: "#ff0000")
        case "orange": return Color(hex: "#ffa500")
        case "yellow": return Color(hex: "#ffff00")
        case "green": return Color(hex: "#008000")
        case "blue": return Color(hex: "#0000ff")
        case "purple": return Color(hex: "#800080")
        case "pink": return Color(hex: "#ffc0cb")
        case "gray", "grey": return Color(hex: "#808080")
        default: return nil
        }
    }
}
