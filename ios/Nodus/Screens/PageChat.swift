import NodusAI
import NodusKit
import NodusUI
import SwiftUI

/// Asking about the report you are reading.
///
/// The chat tab asks the vault a question; this asks *this page* one, and the difference is the
/// whole point. The document on the screen goes into the payload numbered — every paragraph the
/// page registered with `PageSearch`, in reading order — so the model can answer "where does it
/// say that" with a number rather than a paraphrase, and a tap on that number takes the reader
/// to the paragraph and marks it for a moment. Beside the report goes the usual corpus material,
/// so an answer can relate what the report says to the ideas, themes and gaps around it, with
/// the same `nodus://` citations every other answer carries.
///
/// The conversation lives as long as the report does. Closing the modal keeps it; closing or
/// replacing the report — "New", a different report, leaving the screen — forgets it. Nothing is
/// written to disk: a conversation about a document that is still being written is not something
/// to come back to a week later.
struct PageChatSubject: Identifiable, Equatable {
    /// The report this conversation belongs to. Two reports are two conversations.
    let id: String
    let title: String
    let session: SpaceSession

    static func == (lhs: PageChatSubject, rhs: PageChatSubject) -> Bool { lhs.id == rhs.id }
}

/// One report's conversation, for as long as that report is open.
@MainActor
@Observable
final class PageChatStore {
    struct Turn: Identifiable {
        let id = UUID()
        let role: ChatMessage.Role
        var text: String
        /// Corpus sources that survived validation, so a citation reads as its label.
        var citations: [CitationCatalog.Entry] = []
        var warning: String?
        /// Which numbered passages of the report the answer actually used.
        var passages: [Int] = []
    }

    private(set) var turns: [Turn] = []
    var draft = ""
    private(set) var isThinking = false
    var failure: String?

    private var running: Task<Void, Never>?

    /// One store per report, kept alive by the registry rather than by any view, so closing the
    /// modal and opening it again lands back in the same conversation.
    private static var stores: [String: PageChatStore] = [:]

    static func shared(for reportId: String) -> PageChatStore {
        if let existing = stores[reportId] { return existing }
        let store = PageChatStore()
        stores[reportId] = store
        return store
    }

    /// Called when a report is closed or replaced. The conversation was about *that* document.
    static func forget(_ reportId: String) {
        stores.removeValue(forKey: reportId)?.cancel()
    }

    func cancel() {
        running?.cancel()
        running = nil
        isThinking = false
    }

    func clear() {
        cancel()
        turns = []
        failure = nil
    }

    // MARK: Asking

    /// `passages` is the document itself, numbered from one in reading order.
    func ask(
        _ question: String,
        passages: [PageChatPassage],
        subject: PageChatSubject,
        ai: AISettings
    ) {
        guard let model = ai.model(for: .chat) else {
            failure = String(localized: "Choose a chat model under Providers.")
            return
        }
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return }

        draft = ""
        failure = nil
        turns.append(Turn(role: .user, text: asked))
        let answer = turns.count
        turns.append(Turn(role: .assistant, text: ""))
        isThinking = true

        let session = subject.session
        let history = turns.dropLast(2).suffix(8).map { turn in
            ChatMessage(role: turn.role, content: turn.text)
        }

        running = Task {
            defer { isThinking = false }
            do {
                let retrieval = CorpusRetrieval(
                    client: session.client,
                    spaceId: session.connection.spaceId,
                    embeddings: EmbeddingService(keyProvider: ai.keyProvider),
                    identity: Self.semanticIdentity(for: session)
                )
                // The report is what the question is about, so the retrieval query carries the
                // report's own subject as well as the question: "and how does that relate to
                // the gaps" retrieves nothing on its own.
                let material = try? await retrieval.material(for: "\(subject.title)\n\(asked)")
                guard !Task.isCancelled else { return }

                let catalog = material?.catalog ?? CitationCatalog(entries: [])
                turns[answer].warning = material?.warning

                var messages: [ChatMessage] = [
                    ChatMessage(role: .system, content: PageChatPrompt.system(language: Prompts.interfaceLanguage)),
                ]
                messages.append(contentsOf: history)
                messages.append(ChatMessage(role: .user, content: PageChatPrompt.question(
                    asked,
                    title: subject.title,
                    passages: passages,
                    catalog: catalog
                )))

                let provider = ProviderClient(keyProvider: ai.keyProvider)
                var text = ""
                for try await delta in provider.stream(ChatRequest(model: model, messages: messages, temperature: 0.3)) {
                    guard !Task.isCancelled else { return }
                    if case .content(let chunk) = delta {
                        text += chunk
                        turns[answer].text = text
                    }
                }

                // The same guarantee the reports get: an invented corpus source never reaches
                // the screen. A passage number is checked here rather than there, because it
                // points at this page and not at the vault.
                let validated = CitationValidator.validate(prose: text, against: catalog)
                turns[answer].text = PageChatPrompt.dropUnknownReferences(validated.prose, count: passages.count)
                turns[answer].citations = validated.accepted.compactMap(catalog.entry(for:))
                turns[answer].passages = PageChatPrompt.referenced(in: turns[answer].text, count: passages.count)
            } catch is CancellationError {
                turns[answer].text += turns[answer].text.isEmpty ? String(localized: "Cancelled.") : "\n\n_\(String(localized: "Cancelled."))_"
            } catch {
                if case ProviderError.missingKey(let provider) = error { ai.markRejected(provider) }
                if case ProviderError.http(let status, let provider, _) = error, status == 401 || status == 403 {
                    ai.markRejected(provider)
                }
                turns.removeLast()
                failure = error.localizedDescription
            }
        }
    }

    private static func semanticIdentity(for session: SpaceSession) -> EmbeddingIdentity? {
        guard case .published(let identity) = session.embedding, session.embedding.isReachableFromPhone else { return nil }
        return identity
    }
}

/// One numbered paragraph of the page, and where it is.
struct PageChatPassage: Identifiable, Hashable {
    /// One-based, because it is shown to a reader and written by a model.
    let number: Int
    let path: PageSearch.Path
    let text: String

    var id: Int { number }
}

// MARK: - What the model is told

nonisolated enum PageChatPrompt {
    static func system(language: String) -> String {
        """
        Eres un ayudante de lectura. El usuario está leyendo un documento concreto y te pregunta \
        sobre él. Responde en \(language == "es" ? "español" : "inglés") y no inventes nada.

        Tienes dos fuentes y se citan de formas distintas:
        - EL DOCUMENTO que el usuario tiene abierto, dividido en pasajes numerados. Cuando una \
        afirmación tuya venga de un pasaje, cítalo escribiendo su número entre corchetes, así: [3]. \
        Puedes citar varios: [3][7]. No inventes números que no existan.
        - EL CORPUS del que salió el documento (ideas, temas, huecos, obras). Se cita con el token \
        nodus:// exacto del catálogo, entre paréntesis, igual que en un informe.

        Sé breve y concreto. Si el documento no dice algo, dilo en lugar de rellenarlo, y usa el \
        corpus para relacionarlo con ideas, huecos o temas cuando aporte.
        """
    }

    /// The question, the document under it, and the corpus catalogue under that.
    ///
    /// The document is capped at a budget rather than sent whole: a twenty-page report is well
    /// past what most context windows are worth paying for, and the passages that matter are the
    /// ones the reader can see and ask about. It is cut from the end, and the answer says so.
    static func question(
        _ question: String,
        title: String,
        passages: [PageChatPassage],
        catalog: CitationCatalog,
        budget: Int = 48_000
    ) -> String {
        var document = ""
        var included = 0
        for passage in passages {
            let block = "[\(passage.number)] \(passage.text)\n\n"
            if document.count + block.count > budget { break }
            document += block
            included += 1
        }

        let truncated = included < passages.count
            ? "\n(El documento continúa; solo se incluyen los \(included) primeros pasajes.)"
            : ""

        return """
        PREGUNTA
        \(question)

        DOCUMENTO ABIERTO: \(title)
        \(document)\(truncated)

        \(catalog.isEmpty ? "" : Prompts.citationPolicy(catalog: catalog))
        """
    }

    /// The passage numbers an answer really cites, in the order they appear.
    static func referenced(in prose: String, count: Int) -> [Int] {
        var seen: Set<Int> = []
        var order: [Int] = []
        for match in matches(in: prose) where match.number >= 1 && match.number <= count {
            if seen.insert(match.number).inserted { order.append(match.number) }
        }
        return order
    }

    /// A number the document does not have is struck out rather than left to be tapped.
    ///
    /// The prompt asks for real numbers and mostly gets them; this is the half that makes it
    /// true, and it is the same bargain the corpus citations strike with `CitationValidator`.
    static func dropUnknownReferences(_ prose: String, count: Int) -> String {
        var output = prose
        for match in matches(in: prose).reversed() where match.number < 1 || match.number > count {
            guard let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: "")
        }
        return output
    }

    /// Turns `[3]` into a link the prose renderer can hand back on tap.
    static func linkifyReferences(_ prose: String, count: Int) -> String {
        var output = prose
        for match in matches(in: prose).reversed() where match.number >= 1 && match.number <= count {
            guard let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: "[\(match.number)](\(PageChatReference.scheme)://\(match.number))")
        }
        return output
    }

    private struct Reference {
        let number: Int
        let range: NSRange
    }

    /// `[3]`, and never `[label](url)` — a Markdown link opens with the same bracket and must
    /// come out of this untouched.
    private static func matches(in prose: String) -> [Reference] {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d{1,3})\](?!\()"#) else { return [] }
        let range = NSRange(prose.startIndex..<prose.endIndex, in: prose)
        return regex.matches(in: prose, range: range).compactMap { match in
            guard let numberRange = Range(match.range(at: 1), in: prose),
                  let number = Int(prose[numberRange])
            else { return nil }
            return Reference(number: number, range: match.range)
        }
    }
}

/// The scheme a numbered reference is carried in, so a tap can be told apart from a citation.
nonisolated enum PageChatReference {
    static let scheme = "nodusref"

    /// The passage number in a `nodusref://7` link, if it is one.
    static func number(in url: URL) -> Int? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        return Int(url.host ?? "")
    }
}

// MARK: - The modal

/// The chat itself, presented over the page it is about.
struct PageChatSheet: View {
    let subject: PageChatSubject
    let passages: [PageChatPassage]
    let accent: Color
    /// Called with a passage number when the reader taps a reference. The sheet closes first:
    /// the point of the tap is to see the paragraph.
    let onReveal: (PageChatPassage) -> Void

    @Environment(AISettings.self) private var ai
    @Environment(\.dismiss) private var dismiss
    @State private var store: PageChatStore
    @State private var showingProviders = false
    @FocusState private var composerFocused: Bool

    init(
        subject: PageChatSubject,
        passages: [PageChatPassage],
        accent: Color,
        onReveal: @escaping (PageChatPassage) -> Void
    ) {
        self.subject = subject
        self.passages = passages
        self.accent = accent
        self.onReveal = onReveal
        _store = State(initialValue: PageChatStore.shared(for: subject.id))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ChatModelMenu(accent: accent, openProviders: { showingProviders = true })
                    .padding(.top, 4)
                    .padding(.bottom, 6)

                conversation
                composer
            }
            .background(Color.clear)
            .nodusPageBackdrop(accent: accent)
            .navigationTitle("Ask about this report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.turns.isEmpty {
                        Button {
                            store.clear()
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .tint(accent)
                        .accessibilityLabel("New conversation")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .nodusSheet(isPresented: $showingProviders) {
                ProviderSettingsView(accent: accent)
            }
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if store.turns.isEmpty { emptyState }
                    ForEach(store.turns) { turn in
                        PageChatBubble(
                            turn: turn,
                            accent: accent,
                            session: subject.session,
                            passageCount: passages.count,
                            onReference: reveal
                        )
                        .id(turn.id)
                    }
                    if store.isThinking, store.turns.last?.text.isEmpty ?? false {
                        TypingDots(accent: accent).padding(.leading, 2).id("typing")
                    }
                    if let failure = store.failure {
                        NodusNotice(tone: .blocked, title: "The question failed", message: LocalizedStringKey(failure))
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
            .onChange(of: store.turns.count) { _, _ in
                withAnimation { proxy.scrollTo(store.turns.last?.id, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about what you are reading")
                .font(.headline)
            Text("The whole report is in front of the model, numbered. When an answer rests on a passage it says which one, and tapping the number takes you there. Corpus citations work as they do everywhere else.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("The conversation lasts as long as this report is open. Nothing is saved.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .nodusGlass(NodusGlass(.thin, tint: accent))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(
                "",
                text: Binding(get: { store.draft }, set: { store.draft = $0 }),
                prompt: Text("Ask about this report").foregroundColor(.nodusTertiaryText),
                axis: .vertical
            )
            .lineLimit(1...5)
            .textFieldStyle(.plain)
            .focused($composerFocused)
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .frame(minHeight: 42)
            .nodusGlass(NodusGlass(.regular, tint: accent), in: Capsule())

            Button {
                if store.isThinking {
                    store.cancel()
                } else {
                    store.ask(store.draft, passages: passages, subject: subject, ai: ai)
                }
            } label: {
                Image(systemName: store.isThinking ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(accent)
                    .frame(width: 42, height: 42)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!store.isThinking && store.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel(store.isThinking ? "Stop" : "Send")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, NodusSpace.page)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func reveal(_ number: Int) {
        guard let passage = passages.first(where: { $0.number == number }) else { return }
        dismiss()
        onReveal(passage)
    }
}

/// One turn of the report's conversation.
private struct PageChatBubble: View {
    let turn: PageChatStore.Turn
    let accent: Color
    let session: SpaceSession
    let passageCount: Int
    let onReference: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if turn.role == .user {
                Text(turn.text)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .nodusGlass(NodusGlass(.regular, tint: accent))
            } else {
                if let warning = turn.warning {
                    NodusNotice(tone: .caution, title: "Lexical retrieval", message: LocalizedStringKey(warning))
                }
                if turn.text.isEmpty {
                    Text("…").frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    CorpusProse(
                        PageChatPrompt.linkifyReferences(turn.text, count: passageCount),
                        accent: accent,
                        session: session,
                        labels: Dictionary(turn.citations.map { ($0.token, $0.label) }, uniquingKeysWith: { first, _ in first }),
                        onReference: onReference
                    )
                }

                if !turn.passages.isEmpty {
                    // The numbers again, as buttons. A reference inside a sentence is easy to
                    // miss and hard to hit; this row is the same doors at a size a thumb can use.
                    HStack(spacing: 6) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.caption2).foregroundStyle(.secondary)
                        ForEach(turn.passages, id: \.self) { number in
                            Button {
                                onReference(number)
                            } label: {
                                Text(verbatim: "\(number)")
                                    .font(.caption.weight(.medium).monospacedDigit())
                                    .frame(minWidth: 28, minHeight: 28)
                                    .background(accent.opacity(0.16), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(accent.nodusReadable)
                            .accessibilityLabel(Text("Go to passage \(number)"))
                        }
                    }
                }
            }
        }
    }
}
