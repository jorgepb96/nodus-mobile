import Foundation

/// How a generated illustration should look.
///
/// A transcription of `DECORATIVE_IMAGE_STYLES` (`shared/imageStyles.ts`), which the desktop
/// calls "one canonical style registry shared by Settings, Inmersión and Deep Research". The ids
/// are that file's ids and the prompt fragments are its prompt fragments, verbatim: a report
/// illustrated on the phone and the same report illustrated on the desktop should not be
/// recognisably different objects.
///
/// The labels are in English here because this app's base language is English and its Spanish
/// lives in the string catalogue; the prompts are in English in both, because that is the
/// language the image models were trained to read.
public enum DecorativeImageStyle: String, Sendable, Codable, CaseIterable, Hashable {
    case antiqueBook = "antique_book"
    case coloredEngraving = "colored_engraving"
    case classicScientific = "classic_scientific"
    case watercolor
    case historicalCollage = "historical_collage"
    case modernistPoster = "modernist_poster"
    case contemporaryEditorial = "contemporary_editorial"
    case realisticPhoto = "realistic_photo"
    case vintagePhotograph = "vintage_photograph"
    case blackAndWhite = "black_and_white"
    case cinematic
    case oilPainting = "oil_painting"

    public static let fallback: DecorativeImageStyle = .antiqueBook

    public var label: String {
        switch self {
        case .antiqueBook: return "Antique book illustration"
        case .coloredEngraving: return "Coloured engraving"
        case .classicScientific: return "Classic scientific plate"
        case .watercolor: return "Watercolour"
        case .historicalCollage: return "Historical collage"
        case .modernistPoster: return "Modernist poster"
        case .contemporaryEditorial: return "Contemporary editorial"
        case .realisticPhoto: return "Photograph"
        case .vintagePhotograph: return "Archival photograph"
        case .blackAndWhite: return "Black and white"
        case .cinematic: return "Cinematic"
        case .oilPainting: return "Oil painting"
        }
    }

    public var prompt: String {
        switch self {
        case .antiqueBook:
            return "powerful antique book illustration, richly colored pigments, dramatic composition, aged paper texture"
        case .coloredEngraving:
            return "finely detailed hand-colored engraving, vivid restrained palette, engraved linework, aged paper"
        case .classicScientific:
            return "classic scientific plate, precise naturalist detail, elegant composition, saturated archival colors"
        case .watercolor:
            return "expressive watercolor illustration, luminous layered washes, organic edges, strong color accents"
        case .historicalCollage:
            return "historical collage illustration, archival paper fragments and imagery, bold layered color composition"
        case .modernistPoster:
            return "modernist poster illustration, geometric rhythm, bold flat colors, elegant period print texture"
        case .contemporaryEditorial:
            return "contemporary editorial illustration, conceptually striking, clean shapes, sophisticated vivid palette"
        case .realisticPhoto:
            return "photorealistic photograph, natural lighting, lifelike detail, shallow depth of field, high dynamic range"
        case .vintagePhotograph:
            return "vintage archival photograph, authentic period detail, aged film grain, faded tones, documentary realism"
        case .blackAndWhite:
            return "dramatic black and white photograph, rich tonal contrast, fine grain, timeless monochrome composition"
        case .cinematic:
            return "cinematic film still, dramatic lighting, atmospheric depth, moody color grade, widescreen composition"
        case .oilPainting:
            return "classical oil painting, expressive brushwork, layered impasto texture, rich chiaroscuro, museum quality"
        }
    }

    /// Style, scene, and the list of things a decorative image must not contain.
    ///
    /// Deliberately compact, for the reason `buildDecorativeImagePrompt` gives: the money spent
    /// on an image should go to pixels, not to a verbose prompt.
    public func imagePrompt(scene: String) -> String {
        let clean = String(
            scene.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(260)
        )
        return String(
            [
                prompt,
                clean,
                "single decorative landscape image, no text, no letters, no numbers, no logos, no watermark",
            ]
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
            .prefix(640)
        )
    }
}
