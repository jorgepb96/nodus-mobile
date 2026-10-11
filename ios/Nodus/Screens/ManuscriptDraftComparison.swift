import NodusUI
import SwiftUI

struct ManuscriptDraftComparison: View {
    let title: String
    let local: String
    let remote: String
    let accent: Color
    let useRemote: () -> Void
    let keepLocal: () -> Void
    @State private var version = 0
    private var text: String { version == 0 ? local : remote }

    var body: some View {
        VStack(spacing: 12) {
            Picker("Versión", selection: $version) {
                Text("Mi borrador").tag(0); Text("Nodus").tag(1)
            }.pickerStyle(.segmented).padding(.horizontal)
            ScrollView {
                Text(text.isEmpty ? "Texto vacío" : text)
                    .font(.system(.body, design: .serif)).lineSpacing(5).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            VStack(spacing: 10) {
                ShareLink(item: text) { Label("Compartir esta versión", systemImage: "square.and.arrow.up") }
                Button("Conservar mi borrador para guardarlo") { keepLocal() }
                    .buttonStyle(NodusPrimaryButtonStyle(accent: accent))
                Button("Usar el texto de Nodus") { useRemote() }
                    .buttonStyle(NodusGlassButtonStyle(accent: accent))
                Text("Elegir una versión prepara el editor. El guardado volverá a comprobar si la escena cambió en el Mac.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(.horizontal).padding(.bottom)
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}
