import Foundation
import Testing
@testable import NodusAI

/// What the model picker offers, and what it finds when somebody types.
///
/// Both halves are the same failure seen twice: a list of several hundred ids is only usable
/// if the app narrows it, and the two ways it failed to were matching literally against
/// punctuation nobody types, and offering every model a provider has for a task that can use
/// four of them.
@Suite("Model picking")
struct ModelPickingTests {
    // MARK: - Search

    @Test("a separator is a gap, in whichever direction it is typed")
    func separatorsAreGaps() {
        // The report: "gemini flash" typed, `gemini-flash` listed, nothing found.
        #expect(ModelSearch.matches(query: "gemini flash", candidate: "gemini-flash"))
        #expect(ModelSearch.matches(query: "gemini-flash", candidate: "gemini flash"))
        #expect(ModelSearch.matches(query: "gemini.flash", candidate: "gemini_flash"))
        // And with the version number the real id carries between the two words.
        #expect(ModelSearch.matches(query: "gemini flash", candidate: "gemini-2.5-flash"))
        #expect(ModelSearch.matches(query: "gpt mini", candidate: "gpt-4o-mini"))
        #expect(ModelSearch.matches(query: "claude sonnet", candidate: "anthropic/claude-sonnet-4.5"))
    }

    @Test("word order is not the user's problem either")
    func orderDoesNotMatter() {
        #expect(ModelSearch.matches(query: "flash gemini", candidate: "gemini-2.5-flash"))
        #expect(ModelSearch.matches(query: "mini gpt 4o", candidate: "gpt-4o-mini"))
    }

    @Test("a query glued into one word still lands")
    func gluedQueries() {
        #expect(ModelSearch.matches(query: "geminiflash", candidate: "gemini-flash"))
        #expect(ModelSearch.matches(query: "gpt4o", candidate: "gpt-4o"))
        #expect(ModelSearch.matches(query: "25flash", candidate: "gemini-2.5-flash"))
    }

    @Test("narrowing still narrows")
    func matchingIsNotJustPermissive() {
        #expect(!ModelSearch.matches(query: "gemini flash", candidate: "gpt-4o-mini"))
        #expect(!ModelSearch.matches(query: "claude opus", candidate: "claude-sonnet-4.5"))
        // Every word has to be there, not just one of them.
        #expect(!ModelSearch.matches(query: "gemini embedding", candidate: "gemini-2.5-flash"))
    }

    @Test("an empty query is not a filter")
    func emptyQueryMatchesEverything() {
        #expect(ModelSearch.matches(query: "", candidate: "gemini-2.5-flash"))
        #expect(ModelSearch.matches(query: "   ", candidate: "gemini-2.5-flash"))
        #expect(ModelSearch.matches(query: "-", candidate: "gemini-2.5-flash"))
    }

    @Test("the provider's name is searchable with the id, so one provider can be isolated")
    func providerNameIsSearchable() {
        #expect(ModelSearch.matches(query: "openrouter claude", candidate: "anthropic/claude-sonnet-4.5 OpenRouter"))
        #expect(!ModelSearch.matches(query: "openrouter claude", candidate: "claude-sonnet-4.5 Anthropic"))
        // Case and accents are folded, because a phone keyboard supplies both uninvited.
        #expect(ModelSearch.matches(query: "GEMINI Flash", candidate: "gemini-2.5-flash Google Gemini"))
    }

    // MARK: - Image models

    @Test("only the three providers that can draw are offered for images")
    func imageCapableProviders() {
        #expect(AIProvider.openai.supportsImageGeneration)
        #expect(AIProvider.gemini.supportsImageGeneration)
        #expect(AIProvider.openrouter.supportsImageGeneration)
        #expect(!AIProvider.anthropic.supportsImageGeneration)
        #expect(!AIProvider.groq.supportsImageGeneration)
        #expect(!AIProvider.deepseek.supportsImageGeneration)
        #expect(!AIProvider.cerebras.supportsImageGeneration)
        #expect(!AIProvider.xiaomi.supportsImageGeneration)
        #expect(AIProvider.imageCapable.count == 3)
    }

    @Test("the models that draw are recognised, at both providers that name them rather than declare them")
    func imageModelsAreRecognised() {
        for id in [
            "gpt-image-1", "gpt-image-1-mini", "gpt-image-1.5", "gpt-image-2",
            "dall-e-2", "dall-e-3",
            "gemini-2.5-flash-image", "gemini-3-pro-image", "gemini-3.1-flash-image-preview",
            "imagen-3.0-generate-002", "imagen-4.0-generate-001",
        ] {
            #expect(RequestShaping.isImageModel(id), "\(id) should be offered under Images")
        }
    }

    @Test("the chat catalogue does not arrive in the image picker")
    func chatModelsAreNotImageModels() {
        for id in [
            "gpt-4o", "gpt-4o-mini", "o3", "gemini-2.5-flash", "gemini-3-pro",
            "claude-sonnet-4.5", "deepseek-chat", "llama-3.3-70b-versatile",
            "text-embedding-3-small", "whisper-1", "tts-1", "omni-moderation-latest",
        ] {
            #expect(!RequestShaping.isImageModel(id), "\(id) should not be offered under Images")
        }
    }

    /// The two filters are opposites, and the way that breaks is both of them claiming the
    /// same model — a picker that offers `gpt-image-1` for chat and `gpt-4o` for images.
    @Test("no model is both a chat model and an image model")
    func theTwoFiltersDoNotOverlap() {
        let catalogue = [
            "gpt-4o", "gpt-4o-mini", "gpt-image-1", "dall-e-3", "o3-mini",
            "gemini-2.5-flash", "gemini-2.5-flash-image", "imagen-4.0-generate-001",
            "claude-opus-4.5", "deepseek-reasoner", "text-embedding-3-large",
        ]
        for id in catalogue {
            #expect(
                !(RequestShaping.isChatModel(id) && RequestShaping.isImageModel(id)),
                "\(id) is claimed by both filters"
            )
        }
    }

    @Test("a vision model reads pictures and does not draw them")
    func visionIsNotGeneration() {
        #expect(!RequestShaping.isImageModel("llama-3.2-11b-vision-preview"))
        #expect(!RequestShaping.isImageModel("qwen2-vl-7b-image-captioning"))
    }
}
