import NodusKit
import NodusUI
import SwiftUI

/// Presenting a private source uses a native navigation bar; nested references
/// keep the same stack and its Back control instead of opening another sidebar.
struct PrivateCorpusSourceSheet: View {
    let session: SpaceSession
    let reference: PrivateCorpusReference
    var downloadedOnly = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            PrivateCorpusSourceView(session: session, reference: reference, downloadedOnly: downloadedOnly)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cerrar") { dismiss() }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("private-source-close")
                    }
                }
        }.presentationDetents([.large])
    }
}

/// Addressed private sources use native reading controls on both size classes.
/// Selecting a citation never opens a right-hand Desktop inspector on iPhone.
struct PrivateCorpusSourceView: View {
    let session: SpaceSession
    let reference: PrivateCorpusReference
    var downloadedOnly = false
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

    private var loadKey: String { "\(reference.recordKey):\(reference.timestamp ?? 0):\(reference.transcriptId ?? ""):\(reference.sessionId ?? ""):\(reference.annotationId ?? ""):\(session.publishedRevision):\(session.companionDownloadRevision):\(retry)" }
    private var transcripts: [Row] {
        (reference.kind == .testimonyTranscript ? copy.map { [$0.source.root] } ?? [] : copy?.rows["transcripts"] ?? []).sorted {
            if $0.int("version_no") != $1.int("version_no") { return ($0.int("version_no") ?? 0) > ($1.int("version_no") ?? 0) }
            return ($0.string("id") ?? "") < ($1.string("id") ?? "")
        }
    }
    private var transcript: Row? { transcripts.first { $0.string("id") == selectedTranscript } ?? transcripts.first }
    private var isTestimony: Bool { reference.kind.domain == .testimonies }
    private var subtitle: LocalizedStringKey {
        switch reference.kind {
        case .recording: "Grabación y transcripciones"
        case .participant: "Participante de testimonios"
        case .interview: "Entrevista y sesiones"
        case .testimonyTranscript: "Versión de transcripción"
        case .contrast: "Contraste de testimonios"
        default: "Dossier prosopográfico"
        }
    }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if loading {
                        ProgressView(total > 0 ? "Cargando \(loaded) de \(total) registros…" : "Abriendo fuente…")
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else if let copy {
                        DesktopPageHeader(title: LocalizedStringKey(copy.source.title),
                            subtitle: subtitle,
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
                            PrivateFileButton(session: session, kind: .studyRecording, id: reference.id, initialTimestamp: reference.timestamp, downloadedOnly: downloadedOnly)
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
                            .accessibilityIdentifier("private-source-group-picker")
                            if selectedGroup == "transcripts" || (reference.kind == .testimonyTranscript && selectedGroup == "segments") {
                                recordingReader
                            } else {
                                let rows = copy.rows[selectedGroup] ?? []
                                if rows.isEmpty { Text("Esta sección no contiene registros.").foregroundStyle(.secondary) }
                                ForEach(rows, id: \.columns) { row in relatedRecord(row).id(row.string("id") ?? row.string("annotation_id") ?? "row:\(row.columns.hashValue)") }
                            }
                        }
                    }
                    if let issue { CorpusOpenFailure(message: issue) { retry += 1 } }
                }
                .padding(NodusSpace.page).frame(maxWidth: 900).frame(maxWidth: .infinity).nodusTopAnchor()
            }
            .onChange(of: copy?.source.revision) { _, _ in
                if let annotation = reference.annotationId { scroll.scrollTo(annotation, anchor: .center); return }
                guard let timestamp = reference.timestamp,
                      let segment = (copy?.rows["segments"] ?? []).first(where: {
                          $0.string("transcript_id") == transcript?.string("id") && ($0.double("t_start") ?? .infinity) <= timestamp && ($0.double("t_end") ?? 0) >= timestamp
                      }), let id = segment.string("id") else { return }
                scroll.scrollTo(id, anchor: .center)
            }
        }
        .nodusPageBackdrop(accent: session.accent)
        .navigationTitle(reference.kind == .recording ? "Grabación" : reference.kind == .participant ? "Participante" : "Fuente privada")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadKey) { await load() }
        .accessibilityIdentifier("private-corpus-source-\(reference.kind.rawValue)")
    }

    @ViewBuilder private func rootDetails(_ row: Row) -> some View {
        if reference.kind == .participant, let working = row.text("display_name"),
           let publicName = row.text("public_name"), !publicName.isEmpty, working != publicName {
            LabeledContent("Working identity", value: working).textSelection(.enabled)
        }
        fields(row, keys: ["date_display", "citation", "repository", "reference_code", "description", "coverage_notes",
            "reliability_notes", "rights_notes", "summary", "context", "role_or_title", "birth_date", "death_date", "language", "notes", "biography",
            "abstract", "objective", "context_markdown", "guide_markdown", "memo_markdown", "workflow_status", "conducted_at", "location_text", "repository_name", "accession_id"])
        if let url = row.text("url"), let address = URL(string: url), ["https", "http"].contains(address.scheme?.lowercased() ?? "") {
            Link("Abrir referencia original", destination: address).frame(minHeight: 44)
        }
        ForEach(relatedLinks(row), id: \.id) { link in
            NavigationLink { PrivateCorpusSourceView(session: session, reference: link.reference, downloadedOnly: downloadedOnly) }
                label: { Label(link.title, systemImage: "arrow.up.right").frame(minHeight: 44) }
        }
    }

    @ViewBuilder private var recordingReader: some View {
        if transcripts.isEmpty { Text("Esta grabación no tiene transcripciones.").foregroundStyle(.secondary) }
        else {
            Picker("Transcripción", selection: $selectedTranscript) {
                ForEach(transcripts, id: \.columns) { row in
                    Text("\(row.text("file_name") ?? "") · \(row.text("kind") ?? "Transcripción") · v\(row.int("version_no") ?? 1) · \(row.text("language") ?? "")")
                        .tag(row.string("id") ?? "")
                }
            }.pickerStyle(.menu).frame(minHeight: 44)
            if let transcript {
                if isTestimony, let media = transcript.string("media_id") {
                    PrivateFileButton(session: session, kind: .testimonyMedia, id: media, initialTimestamp: reference.timestamp, downloadedOnly: downloadedOnly)
                }
                if let status = transcript.text("status"), status != "completed" {
                    Text("Estado: \(status)").font(.caption).foregroundStyle(.secondary)
                }
                if let failure = transcript.text("error_message"), !failure.isEmpty { Text(failure).foregroundStyle(Color.nodusDanger) }
                CorpusProse(transcript.text("content_markdown") ?? "", accent: session.accent, session: session)
                ForEach((copy?.rows["segments"] ?? []).filter { $0.string("transcript_id") == transcript.string("id") }
                    .sorted { ($0.double("t_start") ?? 0) < ($1.double("t_start") ?? 0) }, id: \.columns) { segment in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(time(segment.double("t_start") ?? 0)) · \(segment.text("speaker") ?? segment.text("speaker_label") ?? "")").font(.caption).foregroundStyle(.secondary)
                        CorpusProse(segment.text("text") ?? "", accent: session.accent, session: session)
                        if isTestimony { ForEach(relatedLinks(segment), id: \.id) { link in
                            NavigationLink { PrivateCorpusSourceView(session: session, reference: link.reference, downloadedOnly: downloadedOnly) }
                                label: { Label(link.title, systemImage: "person.crop.circle").frame(minHeight: 44) }
                        } }
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
            if let title = row.text("title") ?? row.text("interview_title") ?? row.text("display_name") ?? row.text("literal_name") { Text(title).font(.headline) }
            if reference.kind == .person, selectedGroup == "profile" {
                ForEach([("identity_status", "Identity status"), ("review_status", "Review status"),
                    ("privacy_status", "Privacy"), ("preferred_name_basis", "Preferred name basis")], id: \.0) { key, title in
                    if let value = row.text(key), !value.isEmpty {
                        LabeledContent(LocalizedStringKey(title), value: value)
                    }
                }
            }
            if reference.kind == .person, selectedGroup == "authorities" {
                if let scheme = row.text("scheme"), let identifier = row.text("external_id") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(scheme).font(.caption).foregroundStyle(.secondary)
                        Text(identifier).font(.body.monospaced())
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            fields(row, keys: ["summary", "quoted_text", "locator_display", "citation", "description", "context", "role_or_title",
                "literal_value", "value_text", "value_date_display", "unit", "rationale", "scope_note", "representativeness_note",
                "known_bias_note", "preferred_name_basis", "identity_status", "review_status", "privacy_status", "reliability_status", "status",
                "public_name", "identity_mode", "pronunciation", "biographical_note", "attribution_note", "role", "speaker_label",
                "field_notes", "scheduled_at", "recorded_at", "language", "location_text", "file_name", "media_kind", "mime_type",
                "text", "quote_snapshot", "memo", "note", "label", "link_status", "access_level", "embargo_until", "attribution_mode",
                "restrictions_markdown", "narrator_review_notes", "narrator_review_status", "documented_at"].filter { key in
                    reference.kind != .person || selectedGroup != "profile" ||
                        !["preferred_name_basis", "identity_status", "review_status", "privacy_status"].contains(key)
                })
            if isTestimony {
                if let start = row.double("t_start") { Text("\(time(start)) – \(time(row.double("t_end") ?? start))").font(.caption).foregroundStyle(.secondary) }
                if let version = row.int("version_no") { Text("Versión \(version)").font(.caption).foregroundStyle(.secondary) }
                if let media = selectedGroup == "media" ? row.string("id") : row.string("document_media_id") {
                    if row.text("deleted_at") == nil { PrivateFileButton(session: session, kind: .testimonyMedia, id: media, downloadedOnly: downloadedOnly) }
                    else { Text("Archivo retirado").font(.caption).foregroundStyle(.secondary) }
                }
                if let note = row.string("note_id") { NavigationLink("Abrir nota vinculada") { NoteByIdView(session: session, noteId: note) }.frame(minHeight: 44) }
                if let values = row.string("allowed_uses_json"), let data = values.data(using: .utf8), let uses = try? JSONDecoder().decode([String].self, from: data) {
                    Text("Usos documentados: \(uses.isEmpty ? "ninguno" : uses.joined(separator: ", "))").font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                if let code = row.string("code_id"), let label = copy?.rows["codes"]?.first(where: { $0.string("id") == code })?.text("label") { Text(label).font(.headline) }
            }
            if let number = row.double("value_number") { Text(number.formatted()) }
            if let boolean = row.int("value_boolean") { Text(boolean == 0 ? "No" : "Sí") }
            ForEach(relatedLinks(row), id: \.id) { link in
                NavigationLink { PrivateCorpusSourceView(session: session, reference: link.reference, downloadedOnly: downloadedOnly) }
                    label: { Label(link.title, systemImage: "arrow.up.right").frame(minHeight: 44) }
            }
        }.desktopContentRow(accent: session.accent)
    }
    private struct RelatedLink: Identifiable {
        let title: String, reference: PrivateCorpusReference
        var id: String { "\(reference.recordKey):\(reference.timestamp ?? 0):\(reference.transcriptId ?? ""):\(reference.annotationId ?? "")" }
    }
    private func relatedLinks(_ row: Row) -> [RelatedLink] {
        if isTestimony {
            var links: [RelatedLink] = []
            for key in ["person_id", "speaker_person_id"] {
                if let id = row.string(key), let target = try? PrivateCorpusReference(kind: .participant, id: id), target != reference {
                    links.append(.init(title: "Abrir participante", reference: target))
                }
            }
            if let id = row.string("interview_id"), let target = try? PrivateCorpusReference(kind: .interview, id: id,
                timestamp: row.double("t_start"), transcriptId: row.string("transcript_id"), sessionId: selectedGroup == "sessions" ? row.string("id") : row.string("session_id"),
                annotationId: selectedGroup == "annotations" ? row.string("id") : row.string("annotation_id")), target != reference {
                links.append(.init(title: "Abrir entrevista y fragmento", reference: target))
            }
            return links
        }
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
            let result = try await loadPrivateCorpusSource(session, reference: reference, downloadedOnly: downloadedOnly) { loaded = $0; total = $1 }
            try Task.checkCancellation()
            copy = result.0; offline = result.1
            let candidates = transcripts.filter { reference.sessionId == nil || $0.string("session_id") == reference.sessionId }
            if let requested = reference.transcriptId, !candidates.contains(where: { $0.string("id") == requested }) { throw PrivateSourceLocatorFailure.missing }
            if let requested = reference.sessionId, !((copy?.rows["sessions"] ?? []).contains { $0.string("id") == requested }), copy?.source.root.string("session_id") != requested { throw PrivateSourceLocatorFailure.missing }
            if let requested = reference.annotationId, !((copy?.rows["annotations"] ?? []).contains { $0.string("id") == requested }) { throw PrivateSourceLocatorFailure.missing }
            selectedTranscript = reference.transcriptId ?? candidates.first?.string("id") ?? ""
            selectedGroup = reference.annotationId != nil ? "annotations" : reference.kind == .testimonyTranscript ? "segments" : reference.transcriptId != nil || reference.timestamp != nil ? "transcripts" : reference.sessionId != nil ? "sessions" : copy?.source.groups.first?.key ?? ""
        } catch is CancellationError { }
        catch { copy = nil; issue = error.localizedDescription }
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

private enum PrivateSourceLocatorFailure: LocalizedError {
    case missing
    var errorDescription: String? { "El fragmento, la sesión o la versión citada ya no está disponible en esta fuente. No se ha sustituido por otra versión." }
}
