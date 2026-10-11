import NodusKit
import NodusUI
import SwiftUI

/// Completed device content remains readable before the Mac acknowledges it.
/// These are durable authored results, independent of expiring read downloads.
struct CompanionGeneratedResultView: View {
    let session: SpaceSession
    let request: DesktopJobLedger.Request
    let checkpoint: JSONValue
    @State private var synchronizedRequest: DesktopJobLedger.Request?
    private var current: DesktopJobLedger.Request { synchronizedRequest ?? request }
    private var value: [String: JSONValue] { (current.checkpoint ?? checkpoint).objectValue ?? [:] }
    private var markdown: String? {
        switch current.method {
        case "localAcademicGeneration": return value["raw"]?.stringValue
        case "saveMobileAcademicResult", "runMobileSpaceAction":
            guard let preview = (current.method == "runMobileSpaceAction" ? current.result : value["preview"])?.objectValue else { return nil }
            if let thesis = preview["thesis"]?.stringValue {
                return ([thesis] + (preview["remember"]?.arrayValue ?? []).compactMap(\.stringValue).map { "- \($0)" } + [preview["positioning"]?.stringValue ?? ""]).joined(separator: "\n\n")
            }
            if let stance = preview["stance"]?.stringValue { return stance }
            if let beats = preview["beats"]?.arrayValue {
                if beats.isEmpty, preview["noMaterial"] == .bool(true) { return "La revisión necesita texto escrito y latidos declarados en la escena." }
                return beats.compactMap { value in
                    guard let row = value.objectValue, let title = row["threadTitle"]?.stringValue else { return nil }
                    let symbol = row["present"] == .null ? "·" : row["present"]?.boolValue == true ? "✓" : "✗"
                    return "\(symbol) \(title) — \(row["mark"]?.stringValue ?? "")\n\n\(row["note"]?.stringValue ?? "")"
                }.joined(separator: "\n\n")
            }
            if let draft = preview["draft"]?.objectValue?["draftMarkdown"]?.stringValue { return draft }
            return nil
        case "saveDictionaryGeneratedVersion": return value["definition"]?.objectValue?["contentMarkdown"]?.stringValue
        case "saveContentTranslationFromMobile": return value["markdown"]?.stringValue
        case "saveStudyImprovementFromMobile": return value["preview"]?.objectValue?["text"]?.stringValue ?? current.result?.objectValue?["text"]?.stringValue
        case "saveWritingWorkshopFromMobile": return current.result?.objectValue?["draft"]?.objectValue?["draftMarkdown"]?.stringValue
            ?? value["preview"]?.objectValue?["draftMarkdown"]?.stringValue
        default: return nil
        }
    }
    private var title: String { CompanionResultCatalogue.title(current) }
    private var argumentMap: JSONValue? {
        if current.method == "buildArgumentMap" { return current.result }
        if current.method == "runMobileSpaceAction", current.args.first?.objectValue?["kind"] == .string("argumentMap.generate") { return current.result }
        guard ["saveMobileAcademicResult", "localAcademicGeneration"].contains(current.method),
              value["request"]?.objectValue?["source"]?.objectValue?["kind"] == .string("argument") else { return nil }
        return current.result?.objectValue?["root"] != nil ? current.result : value["preview"]
    }
    var body: some View {
        Group {
            if let map = argumentMap {
                SharedDesktopSurface(session: session, surface: .argument, initialArgumentMap: map)
            } else if current.method == "saveMobileDatabaseResearchReport",let id = current.result?.objectValue?["id"]?.stringValue ?? value["detail"]?.objectValue?["report"]?.objectValue?["id"]?.stringValue {
                SharedDesktopSurface(session:session,surface:.databaseResearch,initialDatabaseReportId:id)
            } else if current.method == "saveImmersionGeneratedSession", let plan = value["plan"],
               let itinerary = ImmersionPlan(Row(["plan": plan])) {
                ImmersionView(session: session, sessionId: request.id, title: title, localPlan: itinerary, publicationId: current.id)
            } else if let markdown {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        ReportCopyButtons(markdown: markdown, title: title, accent: session.accent)
                        CorpusProse(markdown, accent: session.accent, session: session)
                        if current.method == "saveWritingWorkshopFromMobile",
                           let draft = current.result?.objectValue?["draft"] ?? value["preview"] {
                            WorkshopDraftSections(draft: draft, session: session)
                        }
                    }.padding(16).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
                }.nodusPageFunctions(accent: session.accent)
            } else if current.method == "runMobileSpaceAction", current.state == "available" {
                ContentUnavailableView("Cambios guardados en Nodus", systemImage: "checkmark.circle", description: Text("Puedes consultarlos en la sección donde los creaste."))
            } else {
                ContentUnavailableView("No hay una vista previa disponible", systemImage: "doc.text")
            }
        }
        .navigationTitle("Resultado guardado").navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .safeAreaInset(edge: .top, spacing: 0) {
            if current.state != "available" {
                Label(["failed", "interrupted", "cancelled"].contains(current.state)
                    ? "Resultado conservado · revisa la sincronización en Trabajos"
                    : "Guardado en este dispositivo · pendiente de sincronizar", systemImage: "iphone")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading).background(.thinMaterial)
            }
        }
        .task(id: session.companionPublicationRevision) {
            if let pairing = session.connection.desktopPairingId, let vault = session.vaultId,
               let ledger = try? await DesktopJobLedgers.shared.ledger(pairingId: pairing, vaultId: vault) {
                synchronizedRequest = await ledger.all().first { $0.id == request.id }
            }
        }
        .accessibilityIdentifier("companion-generated-result-reader")
    }
}
