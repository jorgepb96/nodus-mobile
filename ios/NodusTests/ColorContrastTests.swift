import NodusKit
import NodusUI
import SwiftUI
import Testing
import UIKit

@Suite("Native text contrast")
@MainActor
struct ColorContrastTests {
    private func luminance(_ colour: UIColor, traits: UITraitCollection) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
        colour.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &alpha)
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private func contrast(_ foreground: Color, background: String, style: UIUserInterfaceStyle) -> Double {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let a = luminance(UIColor(foreground), traits: traits)
        let b = luminance(UIColor(Color(hex: background)), traits: traits)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    @Test("all vault accents remain readable on selected rows and tinted cards in both themes")
    func vaultAccentLabels() {
        for vault in VaultType.allCases {
            let colour = Color.nodusSemantic(vault.accentHex)
            for (style, backgrounds) in [
                (UIUserInterfaceStyle.light, ["#eeedf5", "#f6f6f8", "#ffffff"]),
                (UIUserInterfaceStyle.dark, ["#2c2a36", "#1c1c2c", "#111111"])
            ] {
                for background in backgrounds {
                    #expect(contrast(colour, background: background, style: style) >= 4.5,
                            "\(vault.rawValue) labels on \(background)")
                }
            }
        }
    }

    @Test("dashboard descriptions and small counts preserve contrast on tinted surfaces")
    func secondaryLabels() {
        for colour in [Color.nodusSecondaryText, .nodusTertiaryText] {
            #expect(contrast(colour, background: "#eeedf5", style: .light) >= 4.5)
            #expect(contrast(colour, background: "#2c2a36", style: .dark) >= 4.5)
        }
    }
}
