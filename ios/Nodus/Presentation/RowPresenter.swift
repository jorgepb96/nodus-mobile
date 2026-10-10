import NodusKit
import SwiftUI

/// How a raw snapshot row becomes a row in a list.
///
/// The corpus endpoints return SQLite rows with no display metadata, and the schema behind them
/// is at migration 245. Hard-coding a struct per table would mean a new column breaks a screen;
/// hard-coding nothing would mean every list shows `global_id`. So each table declares which
/// columns carry its title, its supporting line and its detail, and anything unlisted falls
/// back to a generic search across the usual names.
struct RowPresenter {
    let collection: String
    let icon: String
    let title: (Row) -> String
    let subtitle: (Row) -> String?
    let detail: (Row) -> String?

    static func forTable(_ table: String) -> RowPresenter {
        switch table {
        case "works":
            return RowPresenter(collection: table, icon: "book.closed") { row in
                row.text("title") ?? "Untitled work"
            } subtitle: { row in
                let authors = authorList(row)
                let year = row.text("year")
                return [authors, year].compactMap { $0 }.joined(separator: " · ")
            } detail: { row in
                row.text("item_type")
            }

        case "ideas":
            return RowPresenter(collection: table, icon: "lightbulb") { row in
                row.text("label") ?? row.text("statement") ?? "Idea"
            } subtitle: { row in
                row.text("statement")
            } detail: { row in
                row.text("type")
            }

        case "themes":
            return RowPresenter(collection: table, icon: "number") { row in
                row.text("label") ?? "Theme"
            } subtitle: { _ in nil } detail: { row in
                row.bool("pinned") == true ? "Fijado" : nil
            }

        case "authors":
            return RowPresenter(collection: table, icon: "person") { row in
                row.text("display_name") ?? row.text("name") ?? "Author"
            } subtitle: { row in
                row.text("affiliation")
            } detail: { row in
                row.int("work_count").map { "\($0) obras" }
            }

        case "gaps":
            return RowPresenter(collection: table, icon: "questionmark.diamond") { row in
                row.text("statement") ?? row.text("label") ?? "Gap"
            } subtitle: { row in
                row.text("rationale")
            } detail: { row in
                row.text("kind").map(gapKindLabel)
            }

        case "passages":
            return RowPresenter(collection: table, icon: "text.quote") { row in
                row.text("text") ?? row.text("content") ?? "Passage"
            } subtitle: { row in
                row.text("section") ?? row.text("heading")
            } detail: { row in
                row.int("page").map { "p. \($0)" } ?? row.text("location")
            }

        case "persons":
            return RowPresenter(collection: table, icon: "person.crop.square") { row in
                row.text("display_name") ?? row.text("given_name") ?? "Person"
            } subtitle: { row in
                // Genealogy stores these as display strings ("c. 1850"), not as dates, because
                // that is what the sources say. Rendering them as dates would invent precision.
                let birth = row.text("birth_date")
                let death = row.text("death_date")
                guard birth != nil || death != nil else { return nil }
                return "\(birth ?? "?") – \(death ?? "?")"
            } detail: { row in
                row.text("sex")
            }

        case "places":
            return RowPresenter(collection: table, icon: "mappin.and.ellipse") { row in
                row.text("name") ?? "Place"
            } subtitle: { row in
                row.text("region") ?? row.text("country")
            } detail: { row in
                row.text("kind")
            }

        case "events":
            return RowPresenter(collection: table, icon: "calendar") { row in
                row.text("label") ?? row.text("kind") ?? "Event"
            } subtitle: { row in
                row.text("date") ?? row.text("date_display")
            } detail: { row in
                row.text("place_name")
            }

        case "relationships":
            // The column is `type`, not `kind` — the same rename that once made a person's
            // dossier report zero relations. Reading the wrong one gave a screen of rows that
            // all said the word "Relationship" and nothing else.
            return RowPresenter(collection: table, icon: "arrow.triangle.branch") { row in
                Self.kinship(row.text("type") ?? row.text("kind"))
            } subtitle: { row in
                row.text("notes")
            } detail: { row in
                row.text("subtype")
            }

        case "notes":
            return RowPresenter(collection: table, icon: "note.text") { row in
                row.text("title") ?? "Note"
            } subtitle: { row in
                row.text("snippet") ?? row.text("content")
            } detail: { row in
                row.text("kind")
            }

        case "db_databases":
            return RowPresenter(collection: table, icon: "tablecells") { row in
                row.text("name") ?? "Database"
            } subtitle: { row in
                row.text("description")
            } detail: { row in
                row.int("row_count").map { "\($0) filas" }
            }

        case "study_courses", "study_subjects", "study_topics":
            return RowPresenter(collection: table, icon: "graduationcap") { row in
                row.text("name") ?? row.text("title") ?? "Item"
            } subtitle: { row in
                row.text("description") ?? row.text("academic_year")
            } detail: { _ in nil }

        case "study_flashcards":
            return RowPresenter(collection: table, icon: "rectangle.on.rectangle") { row in
                row.text("front") ?? "Ficha"
            } subtitle: { row in
                row.text("back")
            } detail: { _ in nil }

        case "study_plans":
            return RowPresenter(collection: table, icon: "list.bullet.rectangle") { row in
                row.text("title") ?? "Plan"
            } subtitle: { row in
                row.text("description")
            } detail: { row in
                row.int("available_minutes").map { "\($0) min" }
            }

        case "study_plan_blocks":
            return RowPresenter(collection: table, icon: "timer") { row in
                row.text("title") ?? "Block"
            } subtitle: { row in
                row.text("notes")
            } detail: { row in
                row.text("status") ?? row.text("block_type")
            }

        case "study_goals":
            return RowPresenter(collection: table, icon: "target") { row in
                row.text("title") ?? "Goal"
            } subtitle: { row in
                // Two numbers and their unit — the goal *is* the ratio, and a subtitle that
                // repeats the title tells a reader nothing.
                guard let target = row.double("target_value") else { return nil }
                let current = row.double("current_value") ?? 0
                return "\(current.formatted()) / \(target.formatted()) \(row.text("unit") ?? "")"
            } detail: { row in
                row.text("period")
            }

        case "study_calendar_events":
            return RowPresenter(collection: table, icon: "calendar") { row in
                row.text("title") ?? "Event"
            } subtitle: { row in
                row.date("starts_at")?.formatted(date: .abbreviated, time: .shortened)
            } detail: { row in
                row.text("event_type")
            }

        case "teaching_exam_questions":
            return RowPresenter(collection: table, icon: "questionmark.square") { row in
                row.text("prompt") ?? "Question"
            } subtitle: { _ in nil } detail: { row in
                row.text("type")
            }

        case "study_questions", "teaching_exams", "teaching_rubrics":
            return RowPresenter(collection: table, icon: "checklist") { row in
                row.text("prompt") ?? row.text("title") ?? row.text("name") ?? "Item"
            } subtitle: { row in
                row.text("description") ?? row.text("explanation")
            } detail: { row in
                row.text("kind") ?? row.text("difficulty")
            }

        default:
            return .generic(table: table)
        }
    }

    /// For a table nobody has described yet — a new one from a later migration, or a
    /// worldbuilding table read out of the mirror. It shows something useful rather than an id.
    static func generic(table: String) -> RowPresenter {
        RowPresenter(collection: table, icon: "square.stack.3d.up") { row in
            firstText(row, ["title", "label", "name", "display_name", "statement", "prompt", "front", "text"])
                ?? "Untitled"
        } subtitle: { row in
            firstText(row, ["description", "summary", "statement", "content", "snippet", "back", "notes"])
        } detail: { row in
            firstText(row, ["kind", "type", "status", "category"])
        }
    }

    private static func firstText(_ row: Row, _ keys: [String]) -> String? {
        for key in keys {
            if let value = row.text(key) { return value }
        }
        return nil
    }

    /// `authors_json` is a JSON array stored as text — CSL-style objects with `family`/`given`,
    /// or plain strings depending on what Zotero gave the desktop.
    private static func authorList(_ row: Row) -> String? {
        guard let value = row.embeddedJSON("authors_json"), let array = value.arrayValue else {
            return row.text("authors")
        }
        let names = array.compactMap { entry -> String? in
            if let string = entry.stringValue, entry.objectValue == nil { return string }
            guard let object = entry.objectValue else { return nil }
            if let literal = object["literal"]?.stringValue { return literal }
            let family = object["family"]?.stringValue
            let given = object["given"]?.stringValue
            return [family, given].compactMap { $0 }.joined(separator: ", ").isEmpty
                ? nil
                : [family, given].compactMap { $0 }.joined(separator: ", ")
        }
        guard !names.isEmpty else { return nil }
        return names.count > 2 ? "\(names[0]) et al." : names.joined(separator: "; ")
    }

    /// The three kinship types the vault stores (`shared/types.ts:1873`), in the reader's words.
    ///
    /// `String(localized:)` rather than a literal, because the result is handed to `Text` as a
    /// value by the presenter and a value is never looked up in the catalogue.
    private static func kinship(_ type: String?) -> String {
        switch type?.lowercased() {
        case "parent": return String(localized: "Parent")
        case "spouse": return String(localized: "Spouse")
        case "sibling": return String(localized: "Sibling")
        case let other?: return other
        case nil: return String(localized: "Relationship")
        }
    }

    private static func gapKindLabel(_ kind: String) -> String {
        switch kind {
        case "future_work": return String(localized: "Future work")
        case "limitation": return String(localized: "Limitation")
        case "open_question": return String(localized: "Open question")
        case "unresolved_contradiction": return String(localized: "Unresolved contradiction")
        default: return kind
        }
    }
}

extension CollectionDescriptor {
    var presenter: RowPresenter { RowPresenter.forTable(table) }

    /// The menu label. Spanish, matching the desktop's own vocabulary.
    var label: String {
        switch path {
        case "works": return String(localized: "Library")
        case "ideas": return String(localized: "Ideas")
        case "themes": return String(localized: "Themes")
        case "gaps": return String(localized: "Gaps")
        case "authors": return String(localized: "Authors")
        case "passages": return String(localized: "Passages")
        case "dictionary": return String(localized: "Diccionario")
        case "persons": return String(localized: "People")
        case "places": return String(localized: "Places")
        case "events": return String(localized: "Timeline")
        case "relationships": return String(localized: "Relationships")
        case "world-groups": return String(localized: "Grupos")
        case "world-scenes": return String(localized: "Escenas")
        case "world-articles": return String(localized: "Enciclopedia")
        case "world-maps": return String(localized: "Mapas")
        case "world-threads": return String(localized: "Tramas")
        case "world-rules": return String(localized: "Reglas")
        case "world-questions": return String(localized: "Preguntas")
        case "world-secrets": return String(localized: "Secretos")
        case "study-subjects": return String(localized: "Subjects")
        case "study-courses": return String(localized: "Courses")
        case "study-topics": return String(localized: "Study topics")
        case "study-docs": return String(localized: "Documents")
        case "study-materials": return String(localized: "Materials")
        case "study-flashcards": return String(localized: "Flashcards")
        case "study-questions": return String(localized: "Question bank")
        case "study-ideas": return String(localized: "Ideas de estudio")
        case "study-plans": return String(localized: "Study plans")
        case "study-schedule": return String(localized: "Horario")
        case "study-goals": return String(localized: "Goals")
        case "study-calendar": return String(localized: "Calendar")
        case "teaching-exams": return String(localized: "Exams")
        case "teaching-rubrics": return String(localized: "Rubrics")
        case "archive-items": return String(localized: "Fuentes primarias")
        case "archive-repositories": return String(localized: "Repositorios")
        case "archive-units": return String(localized: "Unidades descriptivas")
        case "archive-excerpts": return String(localized: "Extractos")
        case "source-analyses": return String(localized: "Análisis de fuentes")
        case "testimony-interviews": return String(localized: "Entrevistas")
        case "testimony-transcripts": return String(localized: "Transcripciones")
        case "testimony-codes": return String(localized: "Códigos")
        case "testimony-contrasts": return String(localized: "Contrastes")
        case "prosopography-public-population": return String(localized: "Población publicada")
        case "prosopography-public-variables": return String(localized: "Variables publicadas")
        case "prosopography-public-sources": return String(localized: "Fuentes publicadas")
        case "prosopography-public-analysis": return String(localized: "Análisis publicado")
        case "prosopography-public-networks": return String(localized: "Redes publicadas")
        case "databases": return String(localized: "Databases")
        case "database-pages": return String(localized: "Páginas")
        default: return path.capitalized
        }
    }

    var icon: String { presenter.icon }
}
