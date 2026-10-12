import Foundation

/// Device-authored results are readable independently of a Mac acknowledgement.
/// Filters bind translations to the section which owns their source document.
public enum CompanionResultCatalogue {
    public static func contains(_ request: DesktopJobLedger.Request, in surface: String) -> Bool {
        guard let checkpoint = request.checkpoint?.objectValue else { return false }
        let original = checkpoint["request"]?.objectValue ?? [:]
        switch request.method {
        case "saveMobileAcademicResult", "localAcademicGeneration":
            guard checkpoint["preview"]?.objectValue != nil else { return false }
            switch original["source"]?.objectValue?["kind"]?.stringValue {
            case "author", "matrix": return surface == "authors"
            case "prose": return surface == "manuscript"
            case "argument": return surface == "argument"
            default: return false
            }
        case "saveDictionaryGeneratedVersion":
            return surface == "dictionary" && !(checkpoint["definition"]?.objectValue?["contentMarkdown"]?.stringValue ?? "").isEmpty
        case "saveStudyImprovementFromMobile":
            return surface == "workspace" && !(checkpoint["preview"]?.objectValue?["text"]?.stringValue ?? "").isEmpty
        case "saveMobileDatabaseResearchReport":
            return surface == "databaseResearch" && !(checkpoint["detail"]?.objectValue?["report"]?.objectValue?["markdown"]?.stringValue ?? "").isEmpty
        case "localWorkshopGeneration":
            return surface == "writingWorkshop" && !(checkpoint["raw"]?.stringValue ?? "").isEmpty
        case "saveWritingWorkshopFromMobile":
            return surface == "writingWorkshop" && !(checkpoint["preview"]?.objectValue?["draftMarkdown"]?.stringValue ?? "").isEmpty
        case "saveImmersionGeneratedSession":
            return surface == "immersion" && checkpoint["plan"]?.objectValue != nil
        case "saveContentTranslationFromMobile":
            guard !(checkpoint["markdown"]?.stringValue ?? "").isEmpty else { return false }
            switch original["entityKind"]?.stringValue {
            case "deep_research": return surface == "deepResearch"
            case "immersion": return surface == "immersion"
            case "study_document", "study_subject", "study_question", "study_transcript", "study_assistant": return surface == "workspace" || surface == "studyDocument"
            default: return false
            }
        default: return false
        }
    }

    public static func title(_ request: DesktopJobLedger.Request) -> String {
        let checkpoint = request.checkpoint?.objectValue ?? [:]
        if request.method == "runMobileSpaceAction", let kind = request.args.first?.objectValue?["kind"]?.stringValue {
            return ["author.synthesis.generate": "Síntesis de autor", "authors.matrix.generate": "Síntesis de autor y tema", "worldbuilding.proseReview": "Revisión de escena", "argumentMap.generate": "Mapa de argumentos", "writing.generate": "Asistencia de escritura", "idea.saveToNotes": "Nota de una idea", "deepResearch.saveToNotes": "Nota de investigación", "hypothesis.saveToNotes": "Nota de hipótesis", "projects.create": "Proyecto creado", "projects.update": "Proyecto guardado", "pages.restoreRevision": "Versión restaurada", "databases.importCSV": "Importación de CSV"][kind] ?? "Resultado de contenido"
        }
        if ["saveMobileAcademicResult", "localAcademicGeneration"].contains(request.method) {
            switch checkpoint["request"]?.objectValue?["source"]?.objectValue?["kind"]?.stringValue {
            case "author": return "Síntesis de autor"
            case "matrix": return "Síntesis de autor y tema"
            case "prose": return "Revisión de escena"
            case "argument": return "Mapa de argumentos"
            default: return "Resultado de investigación"
            }
        }
        if request.method == "saveMobileDatabaseResearchReport",let title = checkpoint["detail"]?.objectValue?["report"]?.objectValue?["title"]?.stringValue,!title.isEmpty { return title }
        if request.method == "saveWritingWorkshopFromMobile",
           let title = checkpoint["preview"]?.objectValue?["title"]?.stringValue, !title.isEmpty { return title }
        if let entry = checkpoint["context"]?.objectValue?["entry"]?.objectValue,
           let term = entry["name"]?.stringValue ?? entry["term"]?.stringValue ?? entry["title"]?.stringValue, !term.isEmpty { return term }
        if let title = checkpoint["request"]?.objectValue?["sourceTitle"]?.stringValue, !title.isEmpty { return title }
        if let title = checkpoint["plan"]?.objectValue?["title"]?.stringValue, !title.isEmpty { return title }
        return ["saveDictionaryGeneratedVersion": "Definición del diccionario", "saveContentTranslationFromMobile": "Traducción",
                "saveStudyImprovementFromMobile": "Asistencia de escritura", "saveImmersionGeneratedSession": "Inmersión", "saveWritingWorkshopFromMobile": "Taller de escritura", "localWorkshopGeneration": "Respuesta anterior del taller"][request.method] ?? "Resultado guardado"
    }
}
