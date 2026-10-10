import Foundation

/// Device-authored results are readable independently of a Mac acknowledgement.
/// Filters bind translations to the section which owns their source document.
public enum CompanionResultCatalogue {
    public static func contains(_ request: DesktopJobLedger.Request, in surface: String) -> Bool {
        guard let checkpoint = request.checkpoint?.objectValue else { return false }
        let original = checkpoint["request"]?.objectValue ?? [:]
        switch request.method {
        case "saveDictionaryGeneratedVersion":
            return surface == "dictionary" && !(checkpoint["definition"]?.objectValue?["contentMarkdown"]?.stringValue ?? "").isEmpty
        case "saveStudyImprovementFromMobile":
            return surface == "workspace" && !(checkpoint["preview"]?.objectValue?["text"]?.stringValue ?? "").isEmpty
        case "saveImmersionGeneratedSession":
            return surface == "immersion" && checkpoint["plan"]?.objectValue != nil
        case "saveContentTranslationFromMobile":
            guard !(checkpoint["markdown"]?.stringValue ?? "").isEmpty else { return false }
            switch original["entityKind"]?.stringValue {
            case "deep_research": return surface == "deepResearch"
            case "immersion": return surface == "immersion"
            case "study_document", "study_subject", "study_question", "study_transcript", "study_assistant": return surface == "workspace"
            default: return false
            }
        default: return false
        }
    }

    public static func title(_ request: DesktopJobLedger.Request) -> String {
        let checkpoint = request.checkpoint?.objectValue ?? [:]
        if let entry = checkpoint["context"]?.objectValue?["entry"]?.objectValue,
           let term = entry["name"]?.stringValue ?? entry["term"]?.stringValue ?? entry["title"]?.stringValue, !term.isEmpty { return term }
        if let title = checkpoint["request"]?.objectValue?["sourceTitle"]?.stringValue, !title.isEmpty { return title }
        if let title = checkpoint["plan"]?.objectValue?["title"]?.stringValue, !title.isEmpty { return title }
        return ["saveDictionaryGeneratedVersion": "Definición del diccionario", "saveContentTranslationFromMobile": "Traducción",
                "saveStudyImprovementFromMobile": "Asistencia de escritura", "saveImmersionGeneratedSession": "Inmersión"][request.method] ?? "Resultado guardado"
    }
}
