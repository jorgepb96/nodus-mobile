import NodusKit
import SwiftUI

/// Completed device content remains readable before the Mac acknowledges it.
/// These are durable authored results, independent of expiring read downloads.
struct CompanionGeneratedResultView: View {
    let session: SpaceSession
    let request: DesktopJobLedger.Request
    let checkpoint: JSONValue
    private var value: [String: JSONValue] { checkpoint.objectValue ?? [:] }
    private var input: [String: JSONValue] { value["request"]?.objectValue ?? [:] }
    private var markdown: String? {
        switch request.method {
        case "saveDictionaryGeneratedVersion": return value["definition"]?.objectValue?["contentMarkdown"]?.stringValue
        case "saveContentTranslationFromMobile": return value["markdown"]?.stringValue
        case "saveStudyImprovementFromMobile": return value["preview"]?.objectValue?["text"]?.stringValue ?? request.result?.objectValue?["text"]?.stringValue
        default: return nil
        }
    }
    private var title: String {
        if let entry = value["context"]?.objectValue?["entry"]?.objectValue,
           let term = entry["term"]?.stringValue ?? entry["title"]?.stringValue { return term }
        return input["sourceTitle"]?.stringValue ?? value["plan"]?.objectValue?["title"]?.stringValue ?? String(localized: "Resultado guardado")
    }
    var body: some View {
        Group {
            if request.method == "saveImmersionGeneratedSession", let plan = value["plan"],
               let itinerary = ImmersionPlan(Row(["plan": plan])) {
                ImmersionView(session: session, sessionId: request.id, title: title, localPlan: itinerary)
            } else if let markdown {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        ReportCopyButtons(markdown: markdown, title: title, accent: session.accent)
                        CorpusProse(markdown, accent: session.accent, session: session)
                    }.padding(16).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
                }.nodusPageFunctions(accent: session.accent)
            } else {
                ContentUnavailableView("No hay una vista previa disponible", systemImage: "doc.text")
            }
        }
        .navigationTitle("Resultado guardado").navigationBarTitleDisplayMode(.inline)
        .nodusPageBackdrop(accent: session.accent)
        .safeAreaInset(edge: .top, spacing: 0) {
            if request.state != "available" {
                Label(["failed", "interrupted", "cancelled"].contains(request.state)
                    ? "Resultado conservado · revisa la sincronización en Trabajos"
                    : "Guardado en este dispositivo · pendiente de sincronizar", systemImage: "iphone")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading).background(.thinMaterial)
            }
        }
        .accessibilityIdentifier("companion-generated-result-reader")
    }
}
