import SwiftUI

public extension View {
    /// A control that floats over a page: a 36-point disc of glass inside a 44-point target.
    ///
    /// The ring round it is the whole of this modifier, and it is not decoration. Glass takes its
    /// edge from the light rather than from the page: the bevel is white, bright where the light
    /// lands and nearly gone on the far corner, which is right for a card sitting *in* a layout
    /// and wrong for a button floating over the content. Over a report in light mode that white
    /// hairline is a white line on white paper — the reader was told there is a button there and
    /// could not see one — and in dark mode the far side of the same bevel goes to nothing
    /// against the dark page.
    ///
    /// So the disc is given an edge of its own: the vault's accent, taken to whichever shade
    /// reads against the surface the app is currently drawing. One hairline, dark in light mode
    /// and light in dark mode, and the vault's colour in both.
    func nodusFloatingCircle(accent: Color) -> some View {
        frame(width: 36, height: 36)
            .nodusGlass(NodusGlass(.regular, tint: accent, interactive: true), in: Circle())
            .overlay {
                // Nearly the full colour, and measured rather than guessed: at half strength the
                // ring came out at 1.8:1 against a light page, which is a line you can see once
                // you know it is there. This is as much contrast as the vault's own violet can
                // give without stopping being the vault's violet.
                Circle()
                    .strokeBorder(accent.nodusReadable.opacity(0.85), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            // The thumb's target, which is larger than the thing it can see. 44 is the smallest
            // square anybody should be asked to hit, and a floating control is hit blind — the
            // finger is coming from the edge of the screen rather than from the last thing read.
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }
}
