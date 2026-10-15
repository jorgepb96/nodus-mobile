import Foundation
import NodusKit

/// The beta retains saved playback, but does not start or persist new narration.
enum MobileAudioBeta {
    static func requireAllowed(method: String) throws {
        let generationMethods: Set<String> = ["getAudioSegments", "saveAudioClip", "humeSynthesize", "generateAudio", "generateSpeech", "synthesizeAudio", "generateNarration"]
        guard BetaAIFeatures.audioGeneration || !generationMethods.contains(method) else {
            throw APIError(status: 409, code: "mobile_audio_generation_deferred", message: "Generar audio · Próximamente")
        }
    }
}
