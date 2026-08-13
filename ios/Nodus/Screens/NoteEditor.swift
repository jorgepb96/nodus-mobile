import NodusKit
import NodusUI
import SwiftUI

/// One note being written, new or edited.
///
/// The same sheet serves both because they are the same act to the queue: an edit is an upsert
/// under the id the note already has. What changes is only what the fields start with.
struct NoteEditor: View {
    @Environment(\.dismiss) private var dismiss

    let accent: Color
    /// Nil for a new note.
    let note: EditableNote?
    let onSave: (_ title: String, _ body: String) async -> Void

    @State private var title = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NodusSpace.block) {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Title", systemImage: "textformat")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("Note title", text: $title, axis: .vertical)
                            .font(.title3.weight(.semibold)).textFieldStyle(.plain)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(Color(uiColor: .secondarySystemBackground).opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(accent.opacity(0.2), lineWidth: 1))
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Label("Content", systemImage: "doc.richtext")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Label("Select text for writing tools", systemImage: "text.cursor")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        WorkspaceEditorSurface(text: $text, accent: accent, minHeight: 320)
                    }
                }
                .padding(NodusSpace.page)
            }
            .navigationTitle(note == nil ? "New note" : "Edit note")
            .navigationBarTitleDisplayMode(.inline)
            .nodusPageBackdrop(accent: accent)
            .tint(accent)
            .nodusDismissesKeyboard()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await onSave(title, text)
                            dismiss()
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty
                        && text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task {
                guard let note else { return }
                title = note.title
                text = note.content
            }
        }
    }
}

/// A published note, in the shape an editor needs.
///
/// `Row` is not `Identifiable` — it is a bag of columns and has no idea which of them is a key —
/// so a note being edited is lifted into this rather than a sheet being handed a row it cannot
/// identify.
struct EditableNote: Identifiable, Hashable {
    let id: String
    let title: String
    let content: String
    let folderId: String?
    /// Carried so an edit does not rewrite it. A note that reports itself as newly written
    /// every time it is touched is a note that has lost its own history.
    let createdAt: String?

    init?(_ row: Row) {
        guard let id = row.string("id") else { return nil }
        self.id = id
        title = row.text("title") ?? ""
        content = row.text("content") ?? row.text("body") ?? ""
        folderId = row.string("folder_id")
        createdAt = row.string("created_at")
    }
}
