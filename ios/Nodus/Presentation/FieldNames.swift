import Foundation

/// What a column is called on screen.
///
/// The generic renderer had no vocabulary at all: it took the SQLite column name, swapped
/// underscores for spaces and set it in capitals. So a Spanish reader opening an idea was shown
/// `LABEL`, `STATEMENT`, `TYPE` and `GLOBAL ID` — four English words in a screen of Spanish, in
/// a typographic style used nowhere else in the app — and a genealogy vault answered with
/// `BIRTH DATE` and `DEATH DATE`.
///
/// This is the vocabulary the desktop and the schema share, in the reader's language. It cannot
/// be complete and is not meant to be: the corpus is at migration 245 and a later one will add a
/// column nobody here has heard of. What it can do is name everything a reader is likely to meet
/// and leave the rest legible — an unknown column comes back as words with a capital at the
/// front rather than as a shout.
///
/// `String(localized:)` per case rather than a `LocalizedStringKey`: the key is a runtime value,
/// and a value handed to `Text` is never looked up in the catalogue. That is the same trap
/// `RowPresenter.kinship` documents.
enum FieldNames {
    static func label(for column: String) -> String {
        switch column {
        // The idea vocabulary — the four the reader complained about, and their neighbours.
        case "label": return String(localized: "Label")
        case "statement": return String(localized: "Statement")
        case "type": return String(localized: "Type")
        case "global_id": return String(localized: "Global ID")
        case "confidence": return String(localized: "Confidence")
        case "rationale": return String(localized: "Rationale")
        case "relation": return String(localized: "Relation")
        case "theme_id": return String(localized: "Theme")

        // Works and citations.
        case "title": return String(localized: "Title")
        case "authors", "authors_json": return String(localized: "Authors")
        case "year": return String(localized: "Year")
        case "item_type": return String(localized: "Kind of work")
        case "publisher": return String(localized: "Publisher")
        case "journal", "publication": return String(localized: "Publication")
        case "doi": return String(localized: "DOI")
        case "isbn": return String(localized: "ISBN")
        case "url": return String(localized: "Link")
        case "abstract": return String(localized: "Abstract")
        case "language": return String(localized: "Language")
        case "nodus_id": return String(localized: "Work")
        case "citation_key": return String(localized: "Citation key")

        // Passages.
        case "text", "content": return String(localized: "Text")
        case "page": return String(localized: "Page")
        case "location": return String(localized: "Location")
        case "section": return String(localized: "Section")
        case "heading": return String(localized: "Heading")
        case "chunk_index": return String(localized: "Fragment")
        case "passage_id": return String(localized: "Passage")

        // Authors and people.
        case "name": return String(localized: "Name")
        case "display_name": return String(localized: "Name shown")
        case "given_name": return String(localized: "Given name")
        case "family_name", "surname": return String(localized: "Family name")
        case "affiliation": return String(localized: "Affiliation")
        case "work_count": return String(localized: "Works")
        case "author_id": return String(localized: "Author")
        case "person_id": return String(localized: "Person")
        case "birth_date": return String(localized: "Born")
        case "death_date": return String(localized: "Died")
        case "sex": return String(localized: "Sex")
        case "subtype": return String(localized: "Subtype")

        // Places and events.
        case "region": return String(localized: "Region")
        case "country": return String(localized: "Country")
        case "place_name": return String(localized: "Place")
        case "date", "date_display": return String(localized: "Date")
        case "starts_at": return String(localized: "Starts")
        case "ends_at": return String(localized: "Ends")

        // Everything shared across the vault types.
        case "kind": return String(localized: "Kind")
        case "description": return String(localized: "Description")
        case "summary": return String(localized: "Summary")
        case "notes": return String(localized: "Notes")
        case "snippet": return String(localized: "Extract")
        case "status": return String(localized: "Status")
        case "role": return String(localized: "Role")
        case "category": return String(localized: "Category")
        case "weight": return String(localized: "Weight")
        case "development": return String(localized: "Development")
        case "pinned": return String(localized: "Pinned")
        case "archived": return String(localized: "Archived")

        // Study and teaching.
        case "front": return String(localized: "Front")
        case "back": return String(localized: "Back")
        case "prompt": return String(localized: "Question")
        case "answer": return String(localized: "Answer")
        case "explanation": return String(localized: "Explanation")
        case "difficulty": return String(localized: "Difficulty")
        case "unit": return String(localized: "Unit")
        case "period": return String(localized: "Period")
        case "target_value": return String(localized: "Target")
        case "current_value": return String(localized: "Progress")
        case "duration_minutes": return String(localized: "Minutes")
        case "available_minutes": return String(localized: "Minutes available")
        case "block_type": return String(localized: "Kind of block")
        case "event_type": return String(localized: "Kind of event")
        case "academic_year": return String(localized: "Academic year")
        case "row_count": return String(localized: "Rows")

        default: return humanised(column)
        }
    }

    /// A column nobody has named: underscores out, first letter up, and nothing else invented.
    static func humanised(_ column: String) -> String {
        let words = column.replacingOccurrences(of: "_", with: " ")
        guard let first = words.first else { return words }
        return String(first).localizedUppercase + words.dropFirst()
    }
}
