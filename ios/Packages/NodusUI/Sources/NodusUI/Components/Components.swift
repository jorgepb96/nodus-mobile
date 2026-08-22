import SwiftUI

/// The desktop canvas: neutral, flat, and quiet enough for the vault accent to remain an accent.
public struct NodusBackdrop: View {
    public var accent: Color
    /// Kept for source compatibility. Nothing here moves any more — see below.
    public var animated: Bool

    @Environment(\.colorScheme) private var colorScheme

    public init(accent: Color, animated: Bool = true) {
        self.accent = accent
        self.animated = animated
    }

    public var body: some View {
        base
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// The page, which is the darker of the two in light mode and the lighter in dark.
    ///
    /// It matters that this is a shade *away* from `NodusSurface.base`: the cards are drawn in
    /// a translucent material, so whatever separation they have from the page is the difference
    /// between these two values seen through it. A page and a card three points apart is a page
    /// with faint outlines on it.
    private var base: Color {
        colorScheme == .dark ? Color(hex: "#09090b") : Color(hex: "#fafafa")
    }
}

public extension View {
    /// Installs the app's own second and third levels of text under this view.
    ///
    /// `.foregroundStyle(_:_:_:)` is what makes this one modifier rather than an edit at every
    /// call site: it redefines what `.secondary` and `.tertiary` *resolve to* for the whole
    /// subtree, so the two hundred places in the app that ask for "the second level" keep asking
    /// for it and start getting one that can be read over tinted glass.
    ///
    /// It goes on the page, beside the backdrop, because the two are the same decision: this is
    /// the text that has to work over that wash.
    func nodusTextHierarchy() -> some View {
        foregroundStyle(Color.primary, Color.nodusSecondaryText, Color.nodusTertiaryText)
    }

    /// The accent backdrop, behind one screen's content.
    ///
    /// It goes on the screen's *content*, and every screen has to ask for it. That is not an
    /// oversight — it is the only place it shows. Attached to the `NavigationStack`, or to the
    /// `TabView`, it was never visible at all: both containers paint their own opaque
    /// `systemBackground` — plain black in dark mode — over anything behind them. That is why
    /// the whole app sat on black with only the glass on top of it carrying any colour, and why
    /// scrolling looked like it "lost" the tint: there was never any tint underneath to lose.
    ///
    /// A pushed screen is a new view in the same container, so it needs its own.
    ///
    /// And since it is the one thing every screen in the app already says about itself, it is
    /// also where the screen reserves the height of the bottom bar — see
    /// `NodusBottomBarClearance`. The two are the same statement: this view is a page, it paints
    /// the wash, and it does not come to rest under the bar floating over it. Reserving it here
    /// rather than at each screen's own bottom is what covers the pushed destinations, which are
    /// exactly the screens nobody remembers to give an inset to.
    ///
    /// `reservesBottomBar: false` is for a backdrop behind a screen the shell has already made
    /// room for. There is one, and the parameter exists so that it can say so.
    func nodusPageBackdrop(accent: Color, reservesBottomBar: Bool = true) -> some View {
        background { NodusBackdrop(accent: accent).ignoresSafeArea() }
            .nodusTextHierarchy()
            .modifier(NodusBottomBarClearance(enabled: reservesBottomBar))
    }
}

public extension View {
    /// The fill under a text field or an inset control.
    ///
    /// `.quaternary` is the system's answer to this and it is a grey. Over the app's own tinted
    /// glass it reads as a dead rectangle somebody forgot to style — and in light mode it was
    /// the one grey on screens that have none, next to a card the specular had turned nearly
    /// white. This is the accent at low strength: the field reads as cut into the surface it
    /// sits on rather than pasted onto it, and it is the same colour in both schemes rather
    /// than two different greys.
    func nodusFieldSurface(accent: Color, cornerRadius: CGFloat = NodusRadius.control) -> some View {
        modifier(NodusFieldSurface(accent: accent, cornerRadius: cornerRadius))
    }
}

private struct NodusFieldSurface: ViewModifier {
    let accent: Color
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(accent.opacity(colorScheme == .dark ? 0.18 : 0.10)))
            // `allowsHitTesting(false)`, and it is not decoration. An overlay sits *over* the
            // content, and a `Shape` there takes the touch: the border made every text field
            // it was put on impossible to focus — tap it and nothing happened, no keyboard, no
            // caret. A background cannot do this, which is why the grey fill never could.
            .overlay(
                shape
                    .strokeBorder(accent.opacity(colorScheme == .dark ? 0.26 : 0.22), lineWidth: 0.8)
                    .allowsHitTesting(false)
            )
    }
}

/// The one filled button in the app.
public struct NodusPrimaryButtonStyle: ButtonStyle {
    public var accent: Color
    @Environment(\.isEnabled) private var isEnabled

    public init(accent: Color) { self.accent = accent }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(accent.relativeLuminance > 0.5 ? Color.black : Color.white)
            .padding(.vertical, 13)
            .padding(.horizontal, 18)
            .background {
                NodusRadius.controlShape
                    .fill(
                        LinearGradient(
                            colors: [accent.shaded(by: 0.18), accent.shaded(by: -0.16)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        NodusRadius.controlShape
                            .strokeBorder(.white.opacity(0.28), lineWidth: 0.66)
                    }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(NodusMotion.press, value: configuration.isPressed)
    }
}

/// A glass button for secondary actions.
///
/// It has to look pressable, and for a while it did not. The map's "Unfold a level" and
/// "Collapse" sat inside the same glass card as the counts above them, in the same weight, with
/// a border no stronger than the card's own — so they read as two more lines of that card rather
/// than as the two controls on the screen. A button is the one place the accent is allowed to
/// carry: a tinted fill under it, a border in the accent rather than in white, and the lit edge
/// that ordinary cards have given up.
public struct NodusGlassButtonStyle: ButtonStyle {
    public var accent: Color
    @Environment(\.isEnabled) private var isEnabled

    public init(accent: Color) { self.accent = accent }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(accent)
            .padding(.vertical, 11)
            .padding(.horizontal, 16)
            // The tint belongs to the glass, not to a plate under it.
            //
            // This used to add `accent.opacity(0.12)` as a `background` *inside* the glass —
            // which puts an opaque wash between the material and the label, the one place
            // Apple's guidance says a fill must never go. On iOS 26 it was most of why a
            // secondary button read as a coloured rectangle rather than as glass. The colour is
            // now carried by `Glass.tint`, which is the supported way to say it, and the rim is
            // quiet enough to be an edge rather than an outline.
            .nodusGlass(
                NodusGlass(.regular, tint: accent, interactive: true),
                in: NodusRadius.controlShape
            )
            .overlay {
                NodusRadius.controlShape
                    .strokeBorder(accent.opacity(0.32), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(NodusMotion.press, value: configuration.isPressed)
    }
}

/// The name of a group of things, and the one style it is set in.
///
/// "Write" and "Analyse" on Home, "Passages that support it" and "Relationships" on a dossier,
/// "On this device" over the reports — the same job on four screens, in four different sizes and
/// two different colours, one of them heavier than the titles it was labelling. Small, in the
/// second level of text, letters a little open, with the count beside it rather than glued into
/// the same string: a label on the group rather than a member of it.
public struct NodusSectionLabel: View {
    private let title: LocalizedStringKey
    private let count: Int?

    public init(_ title: LocalizedStringKey, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    public var body: some View {
        HStack(spacing: 5) {
            Text(title)
            if let count {
                // A separate `Text`, because interpolating the count into the title makes the
                // whole line the catalogue key and nothing matches it.
                Text(verbatim: "· \(count.formatted())").monospacedDigit()
            }
        }
        .font(.footnote.weight(.semibold))
        .tracking(0.5)
        .foregroundStyle(.secondary)
        .padding(.leading, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A card that happens to be tappable.
///
/// Home is a board of navigation tiles and a dossier is a stack of rows that open things, so
/// "can this be pressed" cannot be what decides which surfaces glow — on those screens the
/// answer is everything, which is how the app ended up with no foreground. What separates a tile
/// from a control is that a control *acts* and a tile *goes*: the chevron already says a tile
/// goes, so the tile keeps the quiet surface and says the rest by giving under the thumb.
public struct NodusCardButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(NodusMotion.press, value: configuration.isPressed)
    }
}

/// A small tinted count, the shape the desktop uses beside every section name.
public struct CountBadge: View {
    public var count: Int
    public var accent: Color

    public init(count: Int, accent: Color) {
        self.count = count
        self.accent = accent
    }

    public var body: some View {
        Text(count.formatted())
            .font(NodusChip.font.monospacedDigit())
            .foregroundStyle(accent)
            .padding(.horizontal, NodusChip.horizontalPadding)
            .padding(.vertical, NodusChip.verticalPadding)
            .background(accent.opacity(0.16), in: Capsule())
    }
}

/// A labelled tag: an idea's type, a relation, a role, a kind.
///
/// There were five of these and no two were alike. The argument map set a type in
/// `caption2.medium` with 6 points of padding inside a capsule; a dossier's detail line used
/// `caption.medium` with 8; the theme chips used `caption` with 9; the count badge used 7. Some
/// arrived capitalised from the catalogue and some — `claim`, `constructo`, `apoya` — did not,
/// because they are the corpus's own lowercase vocabulary passed straight through.
///
/// One shape, one type size, one padding, and sentence case applied here rather than hoped for
/// in the catalogue, so a screen showing a type beside a relation shows two of the same thing.
public struct NodusChip: View {
    static let font: Font = .caption2.weight(.semibold)
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 3

    private let text: String
    private let tint: Color
    private let systemImage: String?
    private let capitalises: Bool

    /// `text` is already in the reader's language. Its case is not trusted by default: the
    /// corpus spells its vocabulary lowercase and the catalogue translates it that way, which is
    /// right in the middle of a sentence and wrong on a tag.
    ///
    /// `capitalises: false` for a value the corpus wrote rather than a word from the vocabulary
    /// — a page reference is "p. 40" and turning it into "P. 40" is editing somebody's data to
    /// make a chip look tidy.
    public init(_ text: String, tint: Color, systemImage: String? = nil, capitalises: Bool = true) {
        self.text = text
        self.tint = tint
        self.systemImage = systemImage
        self.capitalises = capitalises
    }

    /// A key the catalogue holds but the source cannot spell as a literal — an idea's `type` as
    /// the row carries it. `LocalizedStringKey` cannot do this: it localises literals, and a
    /// value handed to one is looked up as "%@".
    public init(key: String, tint: Color, systemImage: String? = nil) {
        self.init(
            Bundle.main.localizedString(forKey: key, value: key, table: nil),
            tint: tint,
            systemImage: systemImage
        )
    }

    public var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).font(Self.font)
            }
            Text(capitalises ? Self.sentenceCased(text) : text)
                .font(Self.font)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .background(tint.opacity(0.16), in: Capsule())
        // A tag is a label on something, so it never grows past the thing it labels.
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The first letter up and the rest left alone. `localizedCapitalized` would give "Comparte
    /// Método", which is a title, not a tag.
    public static func sentenceCased(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return String(first).localizedUppercase + text.dropFirst()
    }
}

/// A notice the app is required to show rather than allowed to.
///
/// Used where the honest answer is a caveat: a search that fell back to lexical, a change that
/// will not be visible until the owner republishes, a space that has never been published.
/// Making it a component means those cases cannot quietly become an empty list.
public struct NodusNotice: View {
    public enum Tone: Sendable { case info, caution, blocked }

    public var tone: Tone
    /// `LocalizedStringKey`, not `String`. Every notice in the app passes a literal here, and a
    /// `String` parameter meant `Text` received a value rather than a key — so not one notice
    /// was ever translated, however complete the catalogue was.
    public var title: LocalizedStringKey
    /// Also a key, so a literal is translated. A runtime value — a server's warning, an error's
    /// description — is wrapped by the caller as `LocalizedStringKey(text)`, which finds no
    /// entry and renders the text as it is.
    public var message: LocalizedStringKey?
    public var systemImage: String?

    public init(tone: Tone = .info, title: LocalizedStringKey, message: LocalizedStringKey? = nil, systemImage: String? = nil) {
        self.tone = tone
        self.title = title
        self.message = message
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage ?? defaultIcon)
                .font(.callout)
                .foregroundStyle(colour)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.footnote.weight(.medium))
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nodusGlass(NodusGlass(.thin, tint: colour), in: NodusRadius.panelShape)
    }

    private var colour: Color {
        switch tone {
        case .info: return .nodusInfo
        case .caution: return .nodusCaution
        case .blocked: return .nodusDanger
        }
    }

    private var defaultIcon: String {
        switch tone {
        case .info: return "info.circle"
        case .caution: return "exclamationmark.triangle"
        case .blocked: return "xmark.octagon"
        }
    }
}
