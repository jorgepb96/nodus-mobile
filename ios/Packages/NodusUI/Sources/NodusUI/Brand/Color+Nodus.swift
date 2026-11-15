import SwiftUI

public extension Color {
    /// `#rrggbb` / `#rrggbbaa` / `#rgb`, the form every colour in `shared/vaultTypes.ts` is
    /// written in. An unparseable string yields clear rather than a crash: a palette typo
    /// should show as a missing tint, not take a screen down.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&value) else {
            self = .clear
            return
        }
        let r, g, b, a: Double
        switch cleaned.count {
        case 3:
            r = Double((value >> 8) & 0xF) / 15
            g = Double((value >> 4) & 0xF) / 15
            b = Double(value & 0xF) / 15
            a = 1
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        default:
            self = .clear
            return
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// The desktop's `shade(color, amount)` from `src/dockIcon.ts:38-52`: a positive amount
    /// mixes toward white, a negative one toward black, in the same proportion.
    ///
    /// Reproducing it here rather than eyeballing a lighter violet is what keeps the iOS mark
    /// and the macOS dock icon recognisably the same object.
    func shaded(by amount: Double) -> Color {
        let components = rgbaComponents
        let mix = min(1, abs(amount))
        let target: Double = amount >= 0 ? 1 : 0
        return Color(
            .sRGB,
            red: components.r + (target - components.r) * mix,
            green: components.g + (target - components.g) * mix,
            blue: components.b + (target - components.b) * mix,
            opacity: components.a
        )
    }

    var rgbaComponents: (r: Double, g: Double, b: Double, a: Double) {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #elseif canImport(AppKit)
        let converted = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return (
            Double(converted.redComponent),
            Double(converted.greenComponent),
            Double(converted.blueComponent),
            Double(converted.alphaComponent)
        )
        #else
        return (0, 0, 0, 1)
        #endif
    }

    /// A colour that is two colours: one for each interface style.
    ///
    /// Resolved by the system per trait collection rather than read from `@Environment`, so it
    /// works in a `UIKit` view, inside a `Shape`'s fill, and in a static constant — none of
    /// which can look at the environment.
    static func nodusDynamic(light: String, dark: String) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? Color(hex: dark) : Color(hex: light))
        })
        #else
        return Color(hex: dark)
        #endif
    }

    /// What a screen says about state, in one place.
    ///
    /// SwiftUI's own `.orange`, `.red` and `.green` are tuned for filled controls, not for text
    /// and hairlines over a pale surface: on white, system orange reads as decoration rather
    /// than as a warning, and system yellow barely reads at all. Every notice, badge and status
    /// line in the app used one of those raw — so the same meaning arrived in a different
    /// colour depending on which screen you were on, and half of them were illegible in light
    /// mode. These are the same hues, darkened for light and lightened for dark.
    static let nodusInfo = nodusDynamic(light: "#1d4ed8", dark: "#7ea6ff")
    static let nodusCaution = nodusDynamic(light: "#b45309", dark: "#fbbf24")
    static let nodusDanger = nodusDynamic(light: "#b91c1c", dark: "#fb7185")
    static let nodusSuccess = nodusDynamic(light: "#15803d", dark: "#4ade80")

    /// The second and third levels of text, stated rather than left to the system.
    ///
    /// SwiftUI's `.secondary` and `.tertiary` are the label colour at 60% and 30%, which is
    /// tuned for text on `systemBackground` — a flat white or a flat black. This app's surfaces
    /// are neither: tinted glass over an accent bloom, where 30% of the label colour is a grey
    /// that has most of the violet behind it showing through. Every description, count,
    /// placeholder and page number in the app was set in one of the two, and on a phone in
    /// daylight the third level was barely there at all.
    ///
    /// These are the same two levels, pulled toward the text rather than toward the background,
    /// and cool enough not to fight the violet. Both clear 4.5:1 against the surfaces they are
    /// actually used on, in both schemes. They are installed once — see `nodusTextHierarchy` —
    /// so `.secondary` at a call site keeps meaning "the second level" and now resolves to one
    /// that can be read.
    static let nodusSecondaryText = nodusDynamic(light: "#4a4459", dark: "#c8c3d8")
    static let nodusTertiaryText = nodusDynamic(light: "#6e6880", dark: "#9c96ae")

    /// A colour from the desktop's palette, made readable on both of this app's backgrounds.
    ///
    /// The relation and idea-type colours are shared with the desktop on purpose — green is
    /// support and red is opposition on both, and a reader who has used one should not have to
    /// relearn the other. But those hexes were picked against the desktop's single dark canvas:
    /// `#eab308` on this app's pale surface is a yellow nobody can read, and `#3b82f6` on its
    /// near-black one is only just there.
    ///
    /// So the hue is kept and the lightness is not. Each colour is walked toward black for the
    /// light scheme and toward white for the dark one until it clears 4.5:1 against that scheme's
    /// card surface — which is the same operation `nodusInfo` and its three siblings had done by
    /// hand, done arithmetically so a palette that gains a colour cannot gain an illegible one.
    /// Cached, because it is asked for inside a view body: an argument map is a hundred and
    /// sixty cards, each naming a relation and a type, and the walk below costs a `UIColor`
    /// round trip per step. There are twelve relations and six types in the whole vocabulary,
    /// so the second card onward pays a dictionary lookup.
    @MainActor
    static func nodusSemantic(_ hex: String) -> Color {
        if let known = semanticCache[hex] { return known }
        let made = computedSemantic(hex)
        semanticCache[hex] = made
        return made
    }

    @MainActor
    private static var semanticCache: [String: Color] = [:]

    private static func computedSemantic(_ hex: String) -> Color {
        let base = Color(hex: hex)
        guard base.rgbaComponents.a > 0 else { return base }
        let light = base.legible(onLuminance: Self.lightSurfaceLuminance, towardWhite: false)
        let dark = base.legible(onLuminance: Self.darkSurfaceLuminance, towardWhite: true)
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        return dark
        #endif
    }

    /// This colour, made to read on whichever surface the app is currently drawing.
    ///
    /// The vault accents come from `shared/vaultTypes.ts` and are chosen to look like a brand,
    /// not to be set in eleven-point type: `#6366f1` as a caption over a pale card is a violet
    /// smudge. Anywhere the accent carries *words* — a relation, a page reference, a section
    /// name — it goes through here, and anywhere it is a fill, a stripe or a mark it does not,
    /// because there the brand colour is exactly the right colour.
    @MainActor
    var nodusReadable: Color {
        let components = rgbaComponents
        guard components.a > 0 else { return self }
        let hex = String(
            format: "#%02x%02x%02x",
            Int((components.r * 255).rounded()),
            Int((components.g * 255).rounded()),
            Int((components.b * 255).rounded())
        )
        return Color.nodusSemantic(hex)
    }

    /// Allow for selected rows and tinted cards, which are darker than the light canvas and
    /// lighter than the dark canvas. Testing only the canvas leaves small accent labels below
    /// the contrast required for ordinary text once their selection background is drawn.
    private static let lightSurfaceLuminance = Color(hex: "#eeedf5").relativeLuminance
    private static let darkSurfaceLuminance = Color(hex: "#2c2a36").relativeLuminance

    /// The nearest shade of this colour that reads against a background of the given luminance.
    ///
    /// Walks in twentieths rather than solving for it: `shaded(by:)` mixes in sRGB and luminance
    /// is not linear in sRGB, so there is no closed form worth the arithmetic. Twenty steps is
    /// finer than the eye resolves and stops at the endpoint, so a colour that cannot reach the
    /// ratio at all comes back as black or white rather than as a loop.
    func legible(onLuminance background: Double, towardWhite: Bool, minimumRatio: Double = 4.5) -> Color {
        func ratio(_ colour: Color) -> Double {
            let a = colour.relativeLuminance, b = background
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
        guard ratio(self) < minimumRatio else { return self }
        for step in 1...20 {
            let candidate = shaded(by: (towardWhite ? 1 : -1) * Double(step) / 20)
            if ratio(candidate) >= minimumRatio { return candidate }
        }
        return shaded(by: towardWhite ? 1 : -1)
    }

    /// Relative luminance (WCAG), used to decide whether a tinted glass surface needs light
    /// or dark text on top of it.
    var relativeLuminance: Double {
        let components = rgbaComponents
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(components.r) + 0.7152 * channel(components.g) + 0.0722 * channel(components.b)
    }
}
