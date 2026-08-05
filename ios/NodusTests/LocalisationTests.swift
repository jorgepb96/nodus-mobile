import Foundation
import Testing
@testable import Nodus

/// Whether the app really speaks Spanish, asked of the built bundle rather than of the source.
///
/// A string catalogue with a translation in it proves nothing on its own: `Text(someString)`
/// does not localise, only a literal does, so a computed label can be perfectly translated in
/// the catalogue and still ship in one language. These read the compiled `es.lproj`, which is
/// what a phone set to Spanish actually consults.
@Suite("Localisation")
struct LocalisationTests {
    private var spanish: Bundle {
        get throws {
            let path = try #require(Bundle.main.path(forResource: "es", ofType: "lproj"),
                                    "the app ships no Spanish bundle at all")
            return try #require(Bundle(path: path))
        }
    }

    private func translated(_ key: String, table: String? = nil) throws -> String {
        let sentinel = "⟪missing⟫"
        let value = try spanish.localizedString(forKey: key, value: sentinel, table: table)
        #expect(value != sentinel, "“\(key)” has no Spanish translation")
        #expect(value != key, "“\(key)” is untranslated — the Spanish is the English")
        return value
    }

    // The four headings and the subtitle that were Spanish literals in Swift. They were right on
    // a Spanish phone by accident and wrong on every other one.
    @Test("the headings a view computes are translated, not hardcoded")
    func computedHeadings() throws {
        #expect(try translated("Kinship") == "Parentesco")
        #expect(try translated("Study") == "Estudiar")
        #expect(try translated("Teaching") == "Docencia")
        #expect(try translated("Tools") == "Herramientas")
        #expect(try translated("Not published") == "Sin publicar")
    }

    @Test("everything the lock says has Spanish")
    func lockStrings() throws {
        _ = try translated("Require Face ID")
        _ = try translated("Require the device passcode")
        _ = try translated("Nodus is locked")
        _ = try translated("Unlock with Face ID")
        _ = try translated("This device has no passcode set, so there is nothing to lock with.")
    }

    /// The teaching and study screens are the ones a Spanish-speaking teacher opens on a
    /// Spanish phone, so an English word here is not a rough edge — it is the whole screen.
    @Test("the exam, the agenda and the goals speak Spanish")
    func teachingStrings() throws {
        // "Agenda" is deliberately not asked for here: it is the same word in both languages,
        // and `translated` reads Spanish-that-equals-English as a missing translation. That
        // rule catches far more than it costs, so the cognate goes untested rather than the
        // rule going soft.
        #expect(try translated("Answer key") == "Solucionario")
        #expect(try translated("What is coming") == "Lo que viene")
        #expect(try translated("Today") == "Hoy")
        #expect(try translated("All day") == "Todo el día")
        #expect(try translated("Goals") == "Objetivos")
        #expect(try translated("Study plans") == "Planes de estudio")
        _ = try translated("Show the answer key")
        _ = try translated("This exam was published without any question in it.")
        _ = try translated("No event or planned block in the next two months.")
        _ = try translated("In progress")
        _ = try translated("Blocks")
    }

    /// The find bar is read while reading, which is the one moment a reader is least willing to
    /// translate a control in their head. Its placeholder is the whole of its instructions.
    @Test("the page's own tools and its find bar speak Spanish")
    func pageFunctionStrings() throws {
        _ = try translated("Find on this page")
        _ = try translated("Page tools")
        _ = try translated("Close the page tools")
        _ = try translated("Ask about this page")
        _ = try translated("Previous match")
        _ = try translated("Next match")
        _ = try translated("Close the search")
        _ = try translated("Back to top")
        _ = try translated("No matches")
    }

    /// The report chat is a modal a reader opens mid-page, and everything in it — what it is
    /// for, what it promises about the conversation, and how it fails — is read in that moment.
    @Test("the report chat speaks Spanish")
    func reportChatStrings() throws {
        _ = try translated("Ask about this report")
        _ = try translated("Ask about what you are reading")
        _ = try translated("The conversation lasts as long as this report is open. Nothing is saved.")
        _ = try translated("The question failed")
        _ = try translated("Go to passage %lld")
        _ = try translated("Choose a chat model under Providers.")
        _ = try translated("Cancelled.")
    }

    @Test("everything the new search and writing paths say has Spanish")
    func searchAndWritingStrings() throws {
        _ = try translated("Ranked by meaning")
        _ = try translated("Indexed with %@. Add that key under Providers to search by meaning.")
        _ = try translated("Send to the vault")
        _ = try translated("Sent — waiting for the owner")
        _ = try translated("Queued on this device")
        _ = try translated("Edit note")
    }

    // Sending a report puts a document in somebody's corpus. Every word between the button and
    // that consequence — the question, its two answers, the promise about when it lands, and
    // each way it can fail — has to be in the reader's language, or the one irreversible act on
    // this screen is the one that asks for consent in a language they did not choose.
    @Test("everything said between pressing send and the report landing has Spanish")
    func reportSendingStrings() throws {
        _ = try translated("Send")
        _ = try translated("Sent")
        _ = try translated("Send again")
        _ = try translated("Send to Nodus desktop?")
        _ = try translated("Send this report again?")
        _ = try translated("It travels to the server now. It joins the vault when whoever owns it next opens Nodus desktop and republishes.")
        _ = try translated("It replaces the copy already in the vault rather than adding a second one.")
        _ = try translated("Sent to the desktop")
        _ = try translated("Could not send the report")
        _ = try translated("The report could not be queued on this device.")
        _ = try translated("Choose a model under Providers before sending this report.")
        // Set by `sendReport` and rendered through `LocalizedStringKey`, so it is looked up at
        // draw time and belongs to this screen as much as to the queue.
        _ = try translated("Your access to this space is read only.")
        // Spoken, never seen. A screen reader is the one place where a control labelled with a
        // single word has to say what it does.
        _ = try translated("Send the report to the vault")
        _ = try translated("Send the report again")
    }

    // The queue's counts, which are the only strings in the app that have to agree with a
    // number. The button used to read `"Send \(n) change\(n == 1 ? "" : "s")"` — an English
    // plural built by hand, inside an interpolated key, and an interpolated key matches nothing
    // in the catalogue. So the busiest control on the screen was English on every phone and
    // wrong in Spanish twice over. Asserted through `String(localized:)` rather than a bare
    // lookup because the plural rule lives in the compiled variations, not in the strings table.
    @Test("the queue counts agree with their number, in Spanish")
    func queueCountsInflect() throws {
        let bundle = try spanish
        #expect(String(localized: "^[Send \(1) change](inflect: true)", bundle: bundle) == "Enviar 1 cambio")
        #expect(String(localized: "^[Send \(5) change](inflect: true)", bundle: bundle) == "Enviar 5 cambios")
        #expect(String(localized: "^[\(1) change](inflect: true) to send", bundle: bundle) == "1 cambio por enviar")
        #expect(String(localized: "^[\(3) change](inflect: true) to send", bundle: bundle) == "3 cambios por enviar")
        #expect(String(localized: "^[\(1) change](inflect: true) waiting for its vault", bundle: bundle)
                == "1 cambio esperando a su vault")
        #expect(String(localized: "^[\(2) change](inflect: true) waiting for its vault", bundle: bundle)
                == "2 cambios esperando a su vault")
        #expect(String(localized: "^[\(1) change](inflect: true) in the vault", bundle: bundle)
                == "1 cambio en el vault")
        #expect(String(localized: "^[\(4) change](inflect: true) in the vault", bundle: bundle)
                == "4 cambios en el vault")
    }

    @Test("everything the send queue says has Spanish")
    func sendQueueStrings() throws {
        _ = try translated("Send queue")
        _ = try translated("How this reaches the vault")
        _ = try translated("The server keeps your changes in a ledger. They join the vault when its owner opens Nodus desktop and republishes. Until then nobody sees them, you included.")
        _ = try translated("Nothing queued")
        _ = try translated("Notes you write and reports you send appear here before they travel.")
        _ = try translated("Not sent")
        _ = try translated("On the server")
        _ = try translated("Rejected")
        _ = try translated("Saved on this device.")
        _ = try translated("Waiting for the owner to republish.")
        _ = try translated("The server rejected it.")
        _ = try translated("Remove")
    }

    /// The end of the journey, which is the one part of it the app could never say before. The
    /// distinction it draws — the owner has your change, and has not yet published it — is the
    /// whole reason the state exists, so its sentence is worth as much in Spanish as the badge.
    @Test("everything about a change reaching the vault has Spanish")
    func deliveredStrings() throws {
        _ = try translated("In the vault")
        _ = try translated("In the owner's Nodus. It joins the published copy when they republish.")
        // Read on a lock screen, hours after the app was last open, and the only words that
        // will be read at all if the report is never opened again.
        _ = try translated("Your report is in the vault")
        // Asked through the interpolation the notification really builds rather than by
        // looking the key up: two `%@` in a sentence is exactly the shape that ships in English
        // when the catalogue holds a key nothing generates.
        let bundle = try spanish
        #expect(
            String(
                localized: "“\("El comercio atlántico")” reached \("Mi vault"). Nobody reads it back, you included, until its owner republishes.",
                bundle: bundle
            ) == "«El comercio atlántico» ha llegado a Mi vault. Nadie lo lee, tú incluido, hasta que su propietario vuelva a publicar."
        )
    }

    /// A key that has run out stops a queue without explaining itself. These are the sentences
    /// that turn "sending failed" into something with a next step in it.
    @Test("what the queue says about a key that is running out has Spanish")
    func credentialStrings() throws {
        _ = try translated("Sign in again soon")
        _ = try translated("This device's key for “%@” stops working on %@.")
        _ = try translated("The server no longer accepts this device's key for “%@”. Nothing queued is lost; it travels once you have signed in again.")
    }

    // These are read by iOS, not by the app, and a plist string on its own is shown verbatim in
    // every language — which is how both of them were Spanish-only for everybody.
    @Test("the permission prompts iOS shows are localised too")
    func infoPlistStrings() throws {
        let faceID = try translated("NSFaceIDUsageDescription", table: "InfoPlist")
        #expect(faceID.contains("Face ID"))
        #expect(faceID.contains("claves"), "the Spanish should be Spanish")

        let network = try translated("NSLocalNetworkUsageDescription", table: "InfoPlist")
        #expect(network.contains("red local"))
    }

    /// The base language is English. A Spanish literal left in the source would make the
    /// *English* bundle Spanish, which no catalogue entry can fix.
    @Test("the base language is English")
    func baseIsEnglish() throws {
        #expect(Bundle.main.developmentLocalization == "en")
        let localisations = Set(Bundle.main.localizations)
        #expect(localisations.contains("en"))
        #expect(localisations.contains("es"))
    }
}
