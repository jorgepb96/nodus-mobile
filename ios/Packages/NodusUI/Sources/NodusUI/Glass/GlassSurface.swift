import SwiftUI

/// Liquid Glass, with a fallback that does not look like a consolation prize.
///
/// On iOS 26 this is the system material — `glassEffect`, which really refracts what is behind
/// it and really merges with neighbouring glass. Before 26 there is no such primitive, and the
/// usual substitute (`.ultraThinMaterial` and nothing else) reads as frosted plastic: flat,
/// unlit, with a hard edge.
///
/// The fallback is four layers, and each one is doing a specific job the system material does
/// for free:
///
/// 1. the material itself, saturated back up, because a plain blur desaturates what it blurs
///    and glass does not;
/// 2. a specular highlight along the lit edge, whose angle follows the device — this is what
///    makes it read as a surface rather than a rectangle;
/// 3. a border that is bright where the light hits and nearly gone on the opposite corner,
///    which is the whole of how a real bevel announces itself;
/// 4. an ambient shadow tinted with the vault accent, so the panel sits above the page instead
///    of being painted onto it.
///
/// Both paths respond to Reduce Transparency by becoming opaque, and to Reduce Motion by
/// holding the highlight still.
///
/// The fallback is not only for old phones. `glassEffect` has a height ceiling it never
/// reports — see `SystemGlass` — so on iOS 26 too, a surface taller than the render target
/// allows is drawn by these four layers instead of by the system.
public struct NodusGlass: Sendable, Equatable {
    public enum Weight: Sendable, Equatable {
        /// Panels, cards, sheets.
        case regular
        /// Bars and anything that must not compete with the content behind it.
        case thin
        /// Controls the eye should land on first.
        case prominent
    }

    public var weight: Weight
    public var tint: Color?
    /// Whether the surface reacts to touch. Maps to `Glass.interactive()` on iOS 26 and to a
    /// press-scale on the fallback.
    ///
    /// It also decides whether the surface is *lit* — see `GlassSurfaceFill`. Every card in the
    /// app wore the same bright bevel and the same specular sweep, which meant a section tile
    /// you can press, a notice you cannot, and the paragraph of a report all announced
    /// themselves equally loudly. The glow is now what tells them apart, so it goes where the
    /// touch goes.
    public var interactive: Bool

    public init(_ weight: Weight = .regular, tint: Color? = nil, interactive: Bool = false) {
        self.weight = weight
        self.tint = tint
        self.interactive = interactive
    }

    public static let regular = NodusGlass(.regular)
    public static let thin = NodusGlass(.thin)
    public static let prominent = NodusGlass(.prominent)

    public func tinted(_ color: Color?) -> NodusGlass {
        NodusGlass(weight, tint: color, interactive: interactive)
    }

    public func interactive(_ value: Bool = true) -> NodusGlass {
        NodusGlass(weight, tint: tint, interactive: value)
    }
}

public extension View {
    /// The single entry point. Everything glass in this app goes through here, so the choice
    /// between the system material and the fallback is made once.
    func nodusGlass(
        _ glass: NodusGlass = .regular,
        in shape: some InsettableShape = NodusRadius.panelShape
    ) -> some View {
        modifier(NodusGlassModifier(glass: glass, shape: shape))
    }
}

private struct NodusGlassModifier<S: InsettableShape>: ViewModifier {
    let glass: NodusGlass
    let shape: S

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    /// Every path ends in `contentShape`, and that is the whole of why the app is tappable.
    ///
    /// A glass surface is a *background*. Backgrounds do not take touches, so a card's hit
    /// region was whatever its content happened to draw — the icon, the badge, the title — and
    /// the rest of it was a hole. On a 92-point tile with a 20-point icon and one line of text
    /// that is most of the card, which is exactly why tapping a section on Home usually did
    /// nothing and occasionally worked: the taps that worked landed on the words.
    ///
    /// The pre-26 fallback always had this; the iOS 26 branch never did, so the bug arrived
    /// with the phone the app was designed for.
    func body(content: Content) -> some View {
        if reduceTransparency {
            // Not a degraded glass — a deliberate opaque surface with the same geometry and
            // more contrast, which is what the setting is asking for.
            content
                .background(opaqueFill, in: shape)
                .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
                .contentShape(shape)
        } else {
            #if os(iOS)
            if #available(iOS 26.0, *) {
                content.modifier(SystemGlass(glass: glass, shape: shape))
            } else {
                content.modifier(GlassFallback(glass: glass, shape: shape))
            }
            #else
            content.modifier(GlassFallback(glass: glass, shape: shape))
            #endif
        }
    }

    private var opaqueFill: Color {
        let base = colorScheme == .dark ? Color(hex: "#16141f") : Color(hex: "#f4f3f8")
        guard let tint = glass.tint else { return base }
        return base.blended(with: tint, amount: 0.12)
    }

    private var borderColor: Color {
        colorScheme == .dark ? .white.opacity(0.22) : .black.opacity(0.16)
    }
}

// MARK: - The system surface, and the height it cannot draw

#if os(iOS)
/// `glassEffect`, with the one case where it draws nothing handed to the fallback instead.
///
/// iOS 26 composes a glass surface through a single render target, and past roughly eight
/// thousand pixels of height that target is never produced: the panel does not appear at all —
/// no material, no tint, no bevel — while its content keeps drawing on the bare page. Measured
/// on an iPhone at @3x it survives a 2 628-point surface and vanishes at 2 728, which is the
/// whole of the reported "the purple boxes come and go as I scroll": a relations list of fifty
/// eight rows is far taller than that, and the surface behind it was simply never drawn.
///
/// The `.thinMaterial` fallback has no such ceiling — verified at 3 200 points — so above the
/// limit the pre-26 surface takes over. It is the same geometry, the same tint and the same lit
/// edge, which is why the swap reads as one design rather than two.
///
/// The substitute goes in a `background`, and the effect is switched off by handing it
/// `Glass.identity` rather than by wrapping the content in an `if/else`: the branch would give
/// the content a new identity the first time a measurement crossed the limit, and every piece of
/// state inside a card would be thrown away with it. A different argument to the same modifier
/// changes nothing.
///
/// ## Nothing opaque underneath
///
/// Below the ceiling there is no fill at all, and that is the whole of this file's fix. This
/// modifier used to paint `NodusSurface.base` — a slate at 52–74% opacity — under the effect, on
/// the reasoning that the glass needed "something of its own to refract". What it actually does
/// is leave the material nothing to refract *through*: Liquid Glass samples what is behind it,
/// and what was behind it was an opaque plate. Every card, bar and header in the app therefore
/// rendered on iOS 26 as a flat tinted slab — the material was applied and had no effect, which
/// is exactly what Apple's guidance warns against ("avoid placing solid fills behind a glass
/// view", "avoid adding `.background` on a `glassEffect`").
///
/// `Glass.regular` is adaptive: it dims and brightens against what it is over, which is the job
/// the plate was hired for and does better. What legibility still needs is a page worth
/// refracting, and `NodusBackdrop` is one.
@available(iOS 26.0, *)
struct SystemGlass<S: InsettableShape>: ViewModifier {
    let glass: NodusGlass
    let shape: S

    /// Pixels, not points: the ceiling belongs to the render target, so a 2x phone gets more
    /// points out of it than a 3x one. Set below the measured cliff rather than at it.
    private static var maximumHeightInPixels: CGFloat { 7680 }

    @Environment(\.displayScale) private var displayScale
    @State private var height: CGFloat = 0

    private var fitsInGlass: Bool {
        height * max(displayScale, 1) <= Self.maximumHeightInPixels
    }

    func body(content: Content) -> some View {
        content
            .background {
                // Only above the ceiling, where the system draws nothing and something has to.
                // Below it the material is left alone with the page — see the note above.
                if !fitsInGlass {
                    GlassSurfaceFill(glass: glass, shape: shape, expansive: true)
                }
            }
            // `Glass.identity` rather than a branch: it is the SDK's own "no effect", so the
            // modifier stays applied and the content keeps its identity across the swap.
            .glassEffect(fitsInGlass ? systemGlass : .identity, in: shape)
            .contentShape(shape)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
    }

    private var systemGlass: Glass {
        var value = Glass.regular
        if let tint = glass.tint {
            // `Glass.tint` takes the colour at face value, so handing it a saturated accent
            // produces a solid coloured slab rather than tinted glass. The strength lives here
            // instead of at every call site, which also keeps the fallback — where the wash is
            // an explicit overlay — reading the same at the same weight.
            value = value.tint(tint.opacity(tintStrength))
        }
        if glass.interactive { value = value.interactive() }
        return value
    }

    /// Weaker than it was, and weaker again when nothing is going to be pressed.
    ///
    /// Half the "everything is violet" of this app was here: an 18% accent tint on every card,
    /// on top of an accent-tinted page, under an accent-coloured heading. A card that is only
    /// holding text needs enough tint to belong to the vault and no more.
    ///
    /// Raised by about a third when the slate plate under the material went away: the tint used
    /// to be read against an opaque surface and is now read against whatever the page is doing,
    /// which is a fainter thing to tint. These are the numbers at which a card still says which
    /// vault it belongs to without the page turning violet again.
    private var tintStrength: Double {
        switch glass.weight {
        case .thin: return glass.interactive ? 0.14 : 0.09
        case .regular: return glass.interactive ? 0.20 : 0.13
        case .prominent: return 0.28
        }
    }
}
#endif

// MARK: - The pre-26 surface

struct GlassFallback<S: InsettableShape>: ViewModifier {
    let glass: NodusGlass
    let shape: S

    func body(content: Content) -> some View {
        content
            .background { GlassSurfaceFill(glass: glass, shape: shape) }
            .contentShape(shape)
    }
}

/// The four layers described at the top of the file, as a view of its own so both the pre-26
/// path and the too-tall-for-glass path draw exactly the same surface.
struct GlassSurfaceFill<S: InsettableShape>: View {
    let glass: NodusGlass
    let shape: S
    /// A panel several screens tall rather than a card.
    ///
    /// The specular sweep runs corner to corner, which is a highlight on something the size of
    /// a card and a wash over the whole page on something eight screens long — the top third of
    /// a 3 200-point panel sits in the bright end of the gradient and reads as a lilac slab.
    /// A surface that big has no lit edge to suggest, so it does without one.
    var expansive = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nodusTilt) private var tilt

    /// Lit surfaces are the ones you can press.
    ///
    /// The specular sweep and the bright bevel are what make a rectangle read as a raised
    /// object, and an app where every rectangle is raised has no foreground. A card that only
    /// holds text keeps the material, the floor and a hairline; the highlight is spent on the
    /// things that do something.
    private var lit: Bool { glass.interactive && !expansive }

    var body: some View {
        shape
            // Under the material, not instead of it: the blur still blurs what is behind the
            // panel, it simply no longer blurs it all the way down to the page.
            .fill(NodusSurface.base(colorScheme, tint: glass.tint, weight: glass.weight))
            .overlay { shape.fill(material) }
            // A blur desaturates what it blurs; glass does not. Pushing saturation back up is
            // most of the difference between "frosted" and "glass" — but 1.55 over an accent
            // bloom was pushing the violet past where the palette put it, which is the single
            // biggest reason the app read as more saturated than its own colours.
            .saturation(1.2)
            .overlay { shape.fill(tintWash) }
            .overlay { if lit { specular } }
            .overlay { shape.strokeBorder(bevel, lineWidth: lit ? 0.66 : 0.5) }
            .compositingGroup()
            .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowRadius * 0.4)
    }

    private var material: Material {
        switch glass.weight {
        case .thin: return .ultraThinMaterial
        case .regular: return .thinMaterial
        case .prominent: return .regularMaterial
        }
    }

    private var tintWash: LinearGradient {
        let tint = glass.tint ?? .clear
        let strength: Double
        switch glass.weight {
        case .prominent: strength = 0.20
        case .regular: strength = lit ? 0.13 : 0.08
        case .thin: strength = lit ? 0.10 : 0.06
        }
        return LinearGradient(
            colors: [tint.opacity(strength), tint.opacity(strength * 0.35)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// The lit edge. Its angle follows the device unless Reduce Motion is on, in which case it
    /// stays at the resting top-left — still a lit edge, just not a moving one.
    private var specular: some View {
        let angle = reduceMotion ? UnitPoint(x: 0.16, y: 0) : tilt.highlightOrigin
        return shape
            .fill(
                LinearGradient(
                    stops: [
                        // White under `plusLighter` has nowhere to go on a pale surface: it
                        // clips, and the lit corner stops being a highlight and becomes a
                        // white blob with the rest of the card fading out of it. Dark mode has
                        // the room for it and light mode does not, so light mode keeps barely
                        // enough to round the corner and leaves the edge to the bevel.
                        .init(color: .white.opacity(colorScheme == .dark ? 0.26 : 0.10), location: 0),
                        .init(color: .white.opacity(colorScheme == .dark ? 0.05 : 0.03), location: 0.34),
                        .init(color: .clear, location: 0.62),
                    ],
                    startPoint: angle,
                    endPoint: UnitPoint(x: 1 - angle.x, y: 1 - angle.y)
                )
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }

    /// A bevel on a lit surface, and a hairline on everything else.
    ///
    /// The bevel is bright where the light lands and nearly gone on the far corner, which is the
    /// whole of how a real edge announces itself. A card that is not raised has no such edge to
    /// announce, so it gets a plain, even, quiet line — enough to separate it from the panel
    /// behind it and not enough to claim anything.
    private var bevel: LinearGradient {
        guard lit else {
            let quiet = colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10)
            return LinearGradient(colors: [quiet, quiet], startPoint: .top, endPoint: .bottom)
        }
        // Same reasoning as the specular: a white hairline at 0.85 over a pale surface is a
        // white outline, and every card wore one.
        let bright = colorScheme == .dark ? 0.44 : 0.55
        let dim = colorScheme == .dark ? 0.05 : 0.12
        let origin = reduceMotion ? UnitPoint(x: 0.16, y: 0) : tilt.highlightOrigin
        return LinearGradient(
            colors: [.white.opacity(bright), .white.opacity(dim)],
            startPoint: origin,
            endPoint: UnitPoint(x: 1 - origin.x, y: 1 - origin.y)
        )
    }

    /// Neutral unless the surface is one you press.
    ///
    /// An accent-tinted shadow under every card is an accent halo under every card, and stacked
    /// down a scrolling page that is a violet glow the content sits in rather than on.
    private var shadowColor: Color {
        let base = colorScheme == .dark ? Color.black : Color(hex: "#2a2340")
        let tint = lit ? (glass.tint ?? base) : base
        return tint.opacity(colorScheme == .dark ? (lit ? 0.26 : 0.22) : (lit ? 0.12 : 0.08))
    }

    private var shadowRadius: CGFloat {
        switch glass.weight {
        case .thin: return 8
        case .regular: return lit ? 14 : 10
        case .prominent: return 20
        }
    }
}

/// The floor under every glass surface in the app.
///
/// One neutral slate, mixed a little toward the vault's accent so a panel still belongs to the
/// space it is in, and no more than a little — the tint wash above it is where the accent is
/// meant to show. Blue-grey rather than violet on purpose: it is what gives the saturated accent
/// something to be saturated *against*.
enum NodusSurface {
    /// A card is always *away* from the page, and which direction that is depends on the scheme.
    ///
    /// In dark mode a raised surface is lighter than what it sits on; in light mode it is
    /// whiter. The first version of this used one cool grey for both, which in light mode was a
    /// shade *darker* than the page — so every card read as a dent rather than as paper, and the
    /// only thing separating a card from its background was the hairline round it.
    static func base(_ scheme: ColorScheme, tint: Color?, weight: NodusGlass.Weight) -> Color {
        let raised = scheme == .dark ? Color(hex: "#15141d") : Color(hex: "#fdfcff")
        let mixed = tint.map { raised.blended(with: $0, amount: scheme == .dark ? 0.14 : 0.07) } ?? raised
        return mixed.opacity(opacity(scheme, weight: weight))
    }

    /// How much of the page a panel is allowed to let through. A bar has to stay out of the
    /// content's way and so stays thinner than a card; a prominent surface is the one the eye is
    /// meant to land on and is nearly solid.
    private static func opacity(_ scheme: ColorScheme, weight: NodusGlass.Weight) -> Double {
        switch weight {
        case .thin: return scheme == .dark ? 0.34 : 0.40
        case .regular: return scheme == .dark ? 0.52 : 0.60
        case .prominent: return scheme == .dark ? 0.66 : 0.74
        }
    }
}

// MARK: - Container

/// Groups neighbouring glass so it merges instead of stacking.
///
/// On iOS 26 this is `GlassEffectContainer`, which lets two nearby surfaces flow into one
/// shape as they approach. Before 26 nothing of the sort exists, so it is a plain passthrough
/// — the surfaces simply stay separate, which looks intentional rather than broken.
public struct NodusGlassContainer<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

// MARK: - The travelling lozenge

public extension View {
    /// One bead of glass that says *which one*, and is meant to be moved rather than replaced.
    ///
    /// This is the piece of Liquid Glass a person actually recognises: the selected thing wears
    /// a lozenge of glass, and choosing another one does not cross-fade two lozenges — the one
    /// lozenge travels. Which is why this modifier takes no notion of "selected": there is a
    /// single lozenge in the bar and its *position* is the state. The alternative, a capsule per
    /// cell switched on and off with `glassEffectID`, morphs between two ends and cannot follow
    /// a finger, because a finger is not at either end.
    ///
    /// Put it inside a `NodusGlassContainer`. That is what lets the system treat it and the
    /// surface it is riding on as one body of glass rather than as two sheets stacked.
    ///
    /// Before iOS 26 it is a flat tinted capsule: it still travels, it simply does not refract
    /// anything on the way.
    @ViewBuilder
    func nodusGlassLozenge(tint: Color) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            // `interactive()` is what makes it feel picked up: the glass gives under the touch
            // that is dragging it and springs back when the finger lifts.
            glassEffect(Glass.regular.tint(tint.opacity(0.42)).interactive(), in: .capsule)
        } else {
            background { Capsule().fill(tint.opacity(0.18)) }
        }
        #else
        background { Capsule().fill(tint.opacity(0.18)) }
        #endif
    }
}

extension Color {
    func blended(with other: Color, amount: Double) -> Color {
        let a = rgbaComponents
        let b = other.rgbaComponents
        let mix = max(0, min(1, amount))
        return Color(
            .sRGB,
            red: a.r + (b.r - a.r) * mix,
            green: a.g + (b.g - a.g) * mix,
            blue: a.b + (b.b - a.b) * mix,
            opacity: a.a
        )
    }
}
