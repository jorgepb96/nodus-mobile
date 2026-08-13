import Testing
@testable import Nodus

@Suite("Workspace editor selection ribbon")
struct WorkspaceEditorTests {
    @Test func selectionRibbonUsesProfessionalSystemIcons() {
        #expect(WorkspaceAIAction.allCases.count == 5)
        for action in WorkspaceAIAction.allCases {
            #expect(!action.systemImage.isEmpty)
            #expect(action.systemImage.unicodeScalars.first(where: { $0.properties.isEmojiPresentation }) == nil)
        }
        #expect(WorkspaceAIAction.synonyms.systemImage == "character.book.closed")
    }

    @Test func AIReplacementDropsPresentationWrappers() {
        #expect(WorkspaceEditorPrompt.cleanedReplacement("```markdown\nTexto revisado.\n```") == "Texto revisado.")
        #expect(WorkspaceEditorPrompt.cleanedReplacement("“Texto revisado.”") == "Texto revisado.")
    }

    @Test func synonymPayloadIsDeduplicatedAndLimited() {
        let payload = #"{"alternatives":["preciso","riguroso","Preciso","exacto","cuidadoso","meticuloso","sobrante"]}"#
        #expect(WorkspaceEditorPrompt.synonyms(from: payload) == ["preciso", "riguroso", "exacto", "cuidadoso", "meticuloso"])
    }
}
