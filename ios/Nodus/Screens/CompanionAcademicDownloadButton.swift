import NodusKit
import SwiftUI

struct CompanionAcademicDownloadButton: View {
    let session: SpaceSession
    let request: JSONValue
    @State private var task: Task<Void, Never>?
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                Button("Guardar 7 días") { download(7) }
                Button("Guardar 30 días") { download(30) }
            } label: { Label(task == nil ? "Fuentes para llevar" : "Guardando fuentes…", systemImage: "arrow.down.circle") }
                .disabled(task != nil || session.connection.desktopPairingId == nil || session.isDemo)
            if task != nil { Button("Cancelar descarga") { task?.cancel() }.font(.caption) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func download(_ days: Int) {
        task = Task {
            defer { task = nil }
            do {
                try await CompanionAcademicGeneration.download(session: session, request: request, days: days)
                message = "Fuentes guardadas durante \(days) días. Puedes generar desde el móvil aunque el Mac esté desconectado."
            } catch where error.isCancellation { message = "Descarga cancelada." }
            catch { message = error.localizedDescription }
        }
    }
}
