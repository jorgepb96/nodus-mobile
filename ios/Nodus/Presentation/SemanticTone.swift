import NodusKit
import NodusUI
import SwiftUI

/// One colour per meaning, everywhere in the app.
///
/// The vocabulary and its colours already existed and already agreed with the desktop —
/// `ArgumentRelation.accentHex` and `ArgumentBlock.typeAccentHex` are ports of
/// `ArgumentMapView.tsx` and `ui.tsx`, so support is green, opposition is red, a claim is blue
/// and a construct is amber on both. The problem was that only the argument map used them. A
/// dossier drew every relation in the vault's accent, so "supports" and "contradicts" were the
/// same violet; a search result's kind was the accent too. The same word meant a different
/// colour depending on which screen you read it on, which is worse than no colour at all.
///
/// So the tables live here, one lookup for the whole app, and everything goes through
/// `nodusSemantic` — which keeps the hue the desktop chose and moves the lightness until it can
/// be read on this app's pale card and its near-black one. `#f59e0b` on white is a construct
/// nobody can see; darkened until it clears 4:1 it is the same amber, legible.
///
/// The extra names below are relations the corpus stores that the argument map's enum does not
/// carry. They are grouped by what they do to an argument, not invented: something that depends
/// on a claim supports it, and something that responds to one is neither for nor against.
@MainActor
enum SemanticTone {
    /// An edge, coloured by what it does to the idea at the other end.
    static func relation(_ raw: String, fallback: Color) -> Color {
        if let known = ArgumentRelation(rawValue: raw), known != .related {
            return Color.nodusSemantic(known.accentHex)
        }
        switch raw {
        // Support, in the same green `supports` gets.
        case "depends_on", "exemplifies", "applies": return Color.nodusSemantic("#22c55e")
        // Neither for nor against: the blue `extends` uses.
        case "compares", "responds_to": return Color.nodusSemantic("#3b82f6")
        case "related", "": return fallback.nodusReadable
        default: return fallback.nodusReadable
        }
    }

    /// An idea's own kind — claim, finding, construct, method, framework, theme.
    static func ideaType(_ raw: String, fallback: Color) -> Color {
        let hex = ArgumentBlock.typeAccentHex(for: raw)
        // The palette's own "no idea what this is" grey reads as a disabled control. An unknown
        // type falls back to the vault's accent instead, which says "this belongs here and has
        // no meaning of its own" rather than "this is switched off".
        return hex == nil ? fallback.nodusReadable : Color.nodusSemantic(hex!)
    }
}

extension ArgumentBlock {
    /// The type palette, asked without needing a block to ask it of.
    ///
    /// `typeAccentHex` is an instance property on a block, and the dossier and the search
    /// results have a type string and no block. nil means "not in the vocabulary", which the
    /// instance property spells as its grey.
    static func typeAccentHex(for type: String) -> String? {
        switch type {
        case "theme": return "#f97316"
        case "claim": return "#6366f1"
        case "finding": return "#10b981"
        case "construct": return "#f59e0b"
        case "method": return "#ec4899"
        case "framework": return "#06b6d4"
        default: return nil
        }
    }
}
