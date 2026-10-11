import NodusUI
import SwiftUI

/// Everything the vault has been asked, and what to do with it.
///
/// Archiving and deleting are kept apart on purpose. Archiving is tidying — the conversation
/// is still there, one tap away, and nothing is lost. Deleting is not, so it asks first: a
/// chat is a retrieval and a model call the user paid for, and a swipe is easy to make by
/// accident on a list you are scrolling.
struct ChatHistoryView: View {
    let store: ChatHistoryStore
    let accent: Color
    /// The conversation on screen, so the list can mark it.
    let currentId: String?
    let onOpen: (ChatHistoryStore.Conversation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var pendingDeletion: ChatHistoryStore.Conversation?
    @State private var pendingBulkDeletion: ChatHistoryStore.Scope?
    @State private var showsArchived = false
    @State private var mutationIssue: String?
    private func mutate(_ action: () throws -> Void) {
        do { try action();mutationIssue = nil } catch { mutationIssue = error.localizedDescription }
    }

    /// The tab's conversations before the filter — what "all" means on this screen.
    private var listedSource: [ChatHistoryStore.Conversation] {
        showsArchived ? store.archived : store.active
    }

    private var listed: [ChatHistoryStore.Conversation] {
        let source = listedSource
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return source }
        return source.filter {
            $0.title.lowercased().contains(needle)
                || $0.messages.contains { $0.text.lowercased().contains(needle) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let issue = mutationIssue ?? store.issue {
                    NodusNotice(tone:.blocked,title:"History needs attention",message:LocalizedStringKey(issue))
                        .listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
                Picker("", selection: $showsArchived) {
                    Text("Conversations").tag(false)
                    Text("Archived").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                ForEach(listed) { conversation in
                    Button {
                        onOpen(conversation)
                        dismiss()
                    } label: {
                        row(conversation)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingDeletion = conversation
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            mutate { try store.setArchived(!conversation.isArchived,for:conversation.id) }
                        } label: {
                            Label(
                                conversation.isArchived ? "Unarchive" : "Archive",
                                systemImage: conversation.isArchived ? "tray.and.arrow.up" : "archivebox"
                            )
                        }
                        .tint(accent)
                    }
                    // The same two actions on a long press. A swipe is the iOS way to reach
                    // them and it is also invisible: nothing on the row says it is there, and
                    // a list you only ever scroll never reveals it.
                    .contextMenu {
                        Button {
                            mutate { try store.setArchived(!conversation.isArchived,for:conversation.id) }
                        } label: {
                            Label(
                                conversation.isArchived ? "Unarchive" : "Archive",
                                systemImage: conversation.isArchived ? "tray.and.arrow.up" : "archivebox"
                            )
                        }
                        Button(role: .destructive) {
                            pendingDeletion = conversation
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }

                if listed.isEmpty {
                    ContentUnavailableView(
                        showsArchived ? "Nothing archived" : "No conversations yet",
                        systemImage: showsArchived ? "archivebox" : "bubble.left.and.text.bubble.right",
                        description: Text(showsArchived
                            ? "Archived conversations are kept here, out of the way."
                            : "Ask the vault something and the exchange is kept on this device.")
                    )
                    .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .nodusDismissesKeyboard()
            .listStyle(.plain)
            .safeAreaInset(edge: .top) {
                NodusSearchField(text: $query, prompt: "Filter conversations", accent: accent)
                    .padding(.horizontal, NodusSpace.page)
                    .padding(.bottom, 8)
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .nodusPageBackdrop(accent: accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if !listedSource.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            // Scoped to the tab on screen. "Delete all" while looking at the
                            // conversations should not take the archive with it — archiving is
                            // how you say "keep this out of the way", not "delete it later".
                            Button(role: .destructive) {
                                pendingBulkDeletion = showsArchived ? .archived : .active
                            } label: {
                                Label(
                                    showsArchived ? "Delete everything archived" : "Delete all conversations",
                                    systemImage: "trash"
                                )
                            }
                            if !showsArchived, !store.archived.isEmpty {
                                Button(role: .destructive) {
                                    pendingBulkDeletion = .everything
                                } label: {
                                    Label("Delete every conversation, archived included", systemImage: "trash.slash")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .alert(
                "Delete this conversation?",
                isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
            ) {
                Button("Delete", role: .destructive) {
                    if let pendingDeletion { mutate { try store.delete(pendingDeletion.id) } }
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("“\(pendingDeletion?.title ?? "")” is removed from this device. This cannot be undone.")
            }
            .alert(
                "Delete these conversations?",
                isPresented: Binding(get: { pendingBulkDeletion != nil }, set: { if !$0 { pendingBulkDeletion = nil } })
            ) {
                Button("Delete", role: .destructive) {
                    if let pendingBulkDeletion { mutate { try store.deleteAll(pendingBulkDeletion) } }
                    pendingBulkDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingBulkDeletion = nil }
            } message: {
                // The count is the whole point of the sentence: "delete all" is a different
                // decision at three conversations and at ninety.
                Text("\(store.count(pendingBulkDeletion ?? .active)) conversations are removed from this device. This cannot be undone.")
            }
        }
        .tint(accent)
        .onAppear { store.reload() }
    }

    private func row(_ conversation: ChatHistoryStore.Conversation) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: conversation.id == currentId ? "bubble.left.fill" : "bubble.left")
                .font(.footnote)
                .foregroundStyle(accent)
                .frame(width: 22, height: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                if !conversation.preview.isEmpty {
                    Text(conversation.preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("\(conversation.messages.count / 2) · \(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

/// The three dots the desktop shows while an answer is on its way.
///
/// Not a `ProgressView`: a spinner says "something is happening somewhere", and what is
/// happening here is a sentence arriving one token at a time. Three dots rising in turn is
/// what the desktop's assistant draws, and it reads as speech rather than as machinery.
struct TypingDots: View {
    var accent: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0

    private static let timer = Timer.publish(every: 0.28, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
                    .opacity(reduceMotion ? 0.6 : (phase == index ? 1 : 0.32))
                    .offset(y: reduceMotion ? 0 : (phase == index ? -3 : 0))
            }
        }
        .animation(NodusMotion.standard, value: phase)
        .onReceive(Self.timer) { _ in
            guard !reduceMotion else { return }
            phase = (phase + 1) % 3
        }
        .accessibilityLabel("Writing the answer")
    }
}
