import NodusKit
import NodusUI
import SwiftUI

/// Addressed private sources use native reading controls on both size classes.
/// Selecting a citation never opens a right-hand Desktop inspector on iPhone.
struct PrivateCorpusSourceView: View {
    let session: SpaceSession
    let reference: PrivateCorpusReference
    @State private var copy: CompanionPrivateSourceCopy?
    @State private var offline = false
    @State private var issue: String?
    @State private var loading = true
    @State private var loaded = 0
    @State private var total = 0
    @State private var selectedGroup = ""
    @State private var selectedTranscript = ""
    @State private var retry = 0
    @State private var saving = false
    @State private var saved = false

    private var loadKey: String { "\(reference.recordKey):\(session.publishedRevision):\(session.companionDownloadRevision):\(retry)" }
    private var transcripts: [Row] {
        (copy?.rows["transcripts"] ?? []).sorted {
            if $0.int("version_no") != $1.int("version_no") { return ($0.int("version_no") ?? 0) > ($1.int("version_no") ?? 0) }
            return ($0.string("id") ?? "") < ($1.string("id") ?? "")
        }
    }
    private var transcript: Row? { transcripts.first { $0.string("id") == selectedTranscript } ?? transcripts.first }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if loading {
                        ProgressView(total > 0 ? "Cargando \(loaded) de \(total) registros…" : "Abriendo fuente…")
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else if let copy {
                        DesktopPageHeader(title: LocalizedStringKey(copy.source.title),
                            subtitle: reference.kind == .recording ? "Grabación y transcripciones" : "Dossier prosopográfico",
                            systemImage: reference.kind == .recording ? "waveform" : "person.text.rectangle", accent: session.accent)
                        if offline { Label("Copia descargada · los cambios del Mac se consultarán al reconectar", systemImage: "wifi.slash").font(.caption).foregroundStyle(.secondary) }
                        rootDetails(copy.source.root)
                        HStack {
                            Menu {
                                Button("Conservar 7 días") { save(days: 7) }
                                Button("Conservar 30 días") { save(days: 30) }
                            } label: {
                                if saving { ProgressView() }
                                else { Label(saved ? "Fuente descargada" : "Conservar fuente sin conexión", systemImage: saved ? "checkmark.circle.fill" : "arrow.down.circle") }
                            }.disabled(saving).frame(minHeight: 44)
                            Spacer(minLength: 0)
                        }
                        if reference.kind == .recording {
                            PrivateFileButton(session: session, kind: .studyRecording, id: reference.id, initialTimestamp: reference.timestamp)
                            recordingReader
                        } else {
                            Menu {
                                Picker("Contenido del dossier", selection: $selectedGroup) {
                                    ForEach(copy.source.groups) { group in Text("\(group.title) · \(group.total)").tag(group.key) }
                                }
                            } label: {
                                Label(copy.source.groups.first { $0.key == selectedGroup }?.title ?? "Contenido del dossier", systemImage: "line.3.horizontal.decrease")
                                    .frame(minHeight: 44)
                            }
                            let rows = copy.rows[selectedGroup] ?? []
                            if rows.isEmpty { Text("Esta sección no contiene registros.").foregroundStyle(.secondary) }
                            ForEach(rows, id: \.columns) { row in relatedRecord(row) }
                        }
                    }
                    if let issue { CorpusOpenFailure(message: issue) { retry += 1 } }
                }
                .padding(NodusSpace.page).frame(maxWidth: 900).frame(maxWidth: .infinity).nodusTopAnchor()
            }
            .onChange(of: copy?.source.revision) { _, _ in
                guard let timestamp = reference.timestamp,
                      let segment = (copy?.rows["segments"] ?? []).first(where: {
                          $0.string("transcript_id") == transcript?.string("id") && ($0.double("t_start") ?? .infinity) <= timestamp && ($0.double("t_end") ?? 0) >= timestamp
                      }), let id = segment.string("id") else { return }
                scroll.scrollTo(id, anchor: .center)
            }
        }
        .nodusPageBackdrop(accent: session.accent)
        .navigationTitle(reference.kind == .recording ? "Grabación" : "Fuente privada")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadKey) { await load() }
        .accessibilityIdentifier("private-corpus-source-\(reference.kind.rawValue)")
    }

    @ViewBuilder private func rootDetails(_ row: Row) -> some View {
        fields(row, keys: ["date_display", "citation", "repository", "reference_code", "description", "coverage_notes",
            "reliability_notes", "rights_notes", "summary", "context", "role_or_title", "birth_date", "death_date", "language"])
        if let url = row.text("url"), let address = URL(string: url), ["https", "http"].contains(address.scheme?.lowercased() ?? "") {
            Link("Abrir referencia original", destination: address).frame(minHeight: 44)
        }
    }

    @ViewBuilder private var recordingReader: some View {
        if transcripts.isEmpty { Text("Esta grabación no tiene transcripciones.").foregroundStyle(.secondary) }
        else {
            Picker("Transcripción", selection: $selectedTranscript) {
                ForEach(transcripts, id: \.columns) { row in
                    Text("\(row.text("kind") ?? "Transcripción") · v\(row.int("version_no") ?? 1) · \(row.text("language") ?? "")")
                        .tag(row.string("id") ?? "")
                }
            }.pickerStyle(.menu).frame(minHeight: 44)
            if let transcript {
                if let status = transcript.text("status"), status != "completed" {
                    Text("Estado: \(status)").font(.caption).foregroundStyle(.secondary)
                }
                if let failure = transcript.text("error_message"), !failure.isEmpty { Text(failure).foregroundStyle(Color.nodusDanger) }
                CorpusProse(transcript.text("content_markdown") ?? "", accent: session.accent, session: session)
                ForEach((copy?.rows["segments"] ?? []).filter { $0.string("transcript_id") == transcript.string("id") }
                    .sorted { ($0.double("t_start") ?? 0) < ($1.double("t_start") ?? 0) }, id: \.columns) { segment in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(time(segment.double("t_start") ?? 0)) · \(segment.text("speaker") ?? "")").font(.caption).foregroundStyle(.secondary)
                        CorpusProse(segment.text("text") ?? "", accent: session.accent, session: session)
                    }.id(segment.string("id") ?? "").desktopContentRow(accent: session.accent)
                }
            }
        }
        if let markers = copy?.rows["markers"], !markers.isEmpty {
            Text("Marcadores").font(.headline)
            ForEach(markers.sorted { ($0.double("t_seconds") ?? 0) < ($1.double("t_seconds") ?? 0) }, id: \.columns) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(time(row.double("t_seconds") ?? 0)) · \(row.text("label") ?? "")").font(.headline)
                    if let note = row.text("note"), !note.isEmpty { CorpusProse(note, accent: session.accent, session: session) }
                }.desktopContentRow(accent: session.accent)
            }
        }
    }

    private func relatedRecord(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = row.text("title") ?? row.text("display_name") ?? row.text("literal_name") { Text(title).font(.headline) }
            fields(row, keys: ["summary", "quoted_text", "locator_display", "citation", "description", "context", "role_or_title",
                "literal_value", "value_text", "value_date_display", "unit", "rationale", "scope_note", "representativeness_note",
                "known_bias_note", "preferred_name_basis", "identity_status", "review_status", "privacy_status", "reliability_status", "status"])
            if let number = row.double("value_number") { Text(number.formatted()) }
            if let boolean = row.int("value_boolean") { Text(boolean == 0 ? "No" : "Sí") }
            ForEach(relatedLinks(row), id: \.id) { link in
                NavigationLink { PrivateCorpusSourceView(session: session, reference: link.reference) }
                    label: { Label(link.title, systemImage: "arrow.up.right").frame(minHeight: 44) }
            }
        }.desktopContentRow(accent: session.accent)
    }
    private struct RelatedLink: Identifiable {
        let title: String, reference: PrivateCorpusReference
        var id: String { reference.recordKey }
    }
    private func relatedLinks(_ row: Row) -> [RelatedLink] {
        let fields = [("person_id", "person", "Abrir persona"), ("source_id", "source", "Abrir fuente"),
            ("factoid_id", "factoid", "Abrir observación"), ("attestation_id", "mention", "Abrir mención")]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return fields.compactMap { field in
            guard let id = row.string(field.0), let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed),
                  let url = URL(string: "nodus://prosop/\(field.1)/\(encoded)"), let target = PrivateCorpusReference(url),
                  target.recordKey != reference.recordKey else { return nil }
            return RelatedLink(title: field.2, reference: target)
        }
    }
    @ViewBuilder private func fields(_ row: Row, keys: [String]) -> some View {
        ForEach(keys, id: \.self) { key in
            if let text = row.text(key), !text.isEmpty { CorpusProse(text, accent: session.accent, session: session) }
        }
    }
    private func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds)); return "\(value / 60):\(String(format: "%02d", value % 60))"
    }
    @MainActor private func load() async {
        loading = true; issue = nil; copy = nil; saved = false
        defer { loading = false }
        do {
            let result = try await loadPrivateCorpusSource(session, reference: reference) { loaded = $0; total = $1 }
            try Task.checkCancellation()
            copy = result.0; offline = result.1
            selectedGroup = copy?.source.groups.first?.key ?? ""
            selectedTranscript = reference.transcriptId.flatMap { requested in transcripts.contains { $0.string("id") == requested } ? requested : nil }
                ?? transcripts.first?.string("id") ?? ""
        } catch is CancellationError { }
        catch { issue = error.localizedDescription }
    }
    private func save(days: Int) {
        guard let copy else { return }
        saving = true; issue = nil
        Task {
            defer { saving = false }
            do { try await savePrivateCorpusSource(session, reference: reference, copy: copy, days: days); saved = true }
            catch { issue = error.localizedDescription }
        }
    }
}
