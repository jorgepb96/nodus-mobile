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
/// saved as a separate chat conversation. A submitted Mac request does have a durable job
/// receipt, so a lost acknowledgement cannot purchase the answer twice.
struct PageChatSubject: Identifiable, Equatable {
    /// The report this conversation belongs to. Two reports are two conversations.
    let id: String
    let title: String
    let session: SpaceSession

    @MainActor var storeKey: String { Self.storeKey(storageId: session.connection.storageId, reportId: id) }
    nonisolated static func storeKey(storageId: String, reportId: String) -> String {
        "\(storageId.utf8.count):\(storageId)\(reportId.utf8.count):\(reportId)"
    }

    static func == (lhs: PageChatSubject, rhs: PageChatSubject) -> Bool { lhs.id == rhs.id && lhs.session === rhs.session }
}

/// Opening a report's conversation from somewhere that is not the wheel.
///
/// The wheel's third seat opens the chat empty. This is the other door: words the reader selected
/// in the report itself, carried into the composer as a quotation so the question they then type
/// is already about something. Handed down the environment exactly like `PageSearch` and the
/// reading bookmark, and provided only by a page that really has a conversation — so prose
/// somewhere else keeps the plain selection menu rather than offering a control that does nothing.
@MainActor
@Observable
final class PageChatInvite {
    // This page-local @State has the same synchronous SwiftUI lifetime as
    // PageSearch. Avoid the inferred isolated-deinit runtime path (#88036).
#if compiler(>=6.2)
    nonisolated deinit {}
#endif

    /// The storage-scoped conversation key for this page (not the raw report ID).
    var reportId: String?
    /// Whether the modal is up. The page's own chat button sets it too, so there is one answer
    /// to "is the chat open" rather than two that can disagree.
    var isOpen = false

    /// Ask about a passage the reader selected.
    func ask(about selection: String) {
        guard !NodusLinkPolicy.readOnly else { return }
        guard let reportId else { return }
        PageChatStore.shared(for: reportId).quote(selection)
        isOpen = true
    }
}

/// One report's conversation, for as long as that report is open.
@MainActor
@Observable
final class PageChatStore {
    struct Turn: Identifiable {
        let id = UUID()
        let role: ChatMessage.Role
        var text: String
        /// The passage the reader selected before asking, when the question came from the report
        /// rather than from an empty composer.
        var quote: String?
        /// Token → the name the corpus gives that source, so a citation reads as a citation.
        var labels: [String: String] = [:]
        var warning: String?
        /// Which numbered passages of the report the answer actually used.
        var passages: [Int] = []
    }

    private(set) var turns: [Turn] = []
    var draft = ""
    /// A passage waiting under the composer, put there by selecting it in the report. Cleared by
    /// asking, and by the reader taking it back.
    var quoted: String?
    private(set) var isThinking = false
    var failure: String?

    private var running: Task<Void, Never>?
    private struct PendingMac {
        let id:String, vault:String, pairing:String, answerId:UUID
        let args:[JSONValue]
        let catalog:CitationCatalog
        let passageCount:Int
        var stream=PageChatLiveWire.Stream()
    }
    private var pendingMac:PendingMac?
    private var macSession:SpaceSession?
    private var macObservation=UUID()
    private(set) var isCancellingMac=false
    var canResumeMac:Bool { pendingMac != nil }

    /// The corpus, asked what the sources of this conversation are called.
    ///
    /// Held for as long as the conversation is, rather than built per question: the actor
    /// remembers every work it has looked up, and a reader asking five questions about one
    /// report cites the same handful of books in all five answers.
    private var naming: CorpusCitations?

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
        guard !isCancellingMac else {return}
        macObservation=UUID()
        running?.cancel();running=nil
        guard let pending=pendingMac,let session=macSession else {isThinking=false;return}
        isCancellingMac=true;isThinking=true
        Task { @MainActor in
            defer {isCancellingMac=false;isThinking=false}
            do {
                let (_,pairing,token)=try privateBridgeConnection(session,domain:.researchGeneration)
                guard pairing.id == pending.pairing else {throw DesktopBridgeError.permissionDenied}
                let ledger=try await DesktopJobLedgers.shared.ledger(pairingId:pairing.id,vaultId:pending.vault)
                try await ledger.requestCancellation(id:pending.id)
                // The request tombstone is atomic even if the original POST arrives late.
                let client=DesktopBridgeClient(pairing:pairing,token:token)
                let stopped=try await PageChatLiveWire.cancelRequest(vaultId:pending.vault,args:pending.args,id:pending.id) { vault,method,args,id in
                    try await client.cancelJobRequest(vaultId:vault,method:method,args:args,idempotencyKey:id)
                }
                try await ledger.update(id:pending.id,job:stopped)
                if pendingMac?.id == pending.id {pendingMac=nil}
            } catch {failure=error.localizedDescription}
        }
    }

    func clear() {
        cancel()
        pendingMac=nil
        turns = []
        failure = nil
        quoted = nil
    }

    /// Put a passage of the report under the composer. Selections arrive with whatever whitespace
    /// the finger caught, and a quotation broken across the lines of a justified paragraph is not
    /// what the reader pointed at.
    func quote(_ selection: String) {
        let text = selection
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        quoted = text.isEmpty ? nil : text
    }

    // MARK: Asking

    /// `passages` is the document itself, numbered from one in reading order.
    func ask(
        _ question: String,
        passages: [PageChatPassage],
        subject: PageChatSubject,
        ai: AISettings
    ) {
        do { try NodusLinkPolicy.requireAuthoring() } catch { failure = error.localizedDescription; return }
        if subject.session.aiExecutionMode == .live { askMac(question,passages:passages,subject:subject,ai:ai);return }
        do {try BetaAIFeatures.requireAutonomousGeneration()} catch {failure=error.localizedDescription;return}
        guard let model = ai.model(for: .chat) else {
            failure = String(localized: "Choose a chat model under Providers.")
            return
        }
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return }

        // The quotation belongs to this question and to no other. Taken before the turn is built
        // so a second question asked straight afterwards starts from an empty composer.
        let quotation = quoted
        quoted = nil

        draft = ""
        failure = nil
        turns.append(Turn(role: .user, text: asked, quote: quotation))
        let answer = turns.count
        turns.append(Turn(role: .assistant, text: ""))
        isThinking = true

        let session = subject.session
        let history = turns.dropLast(2).suffix(8).map { turn in
            // The quotation goes into the history as part of what was asked, because two turns
            // later "and what does it rest on?" means nothing without it.
            ChatMessage(role: turn.role, content: PageChatPrompt.asked(turn.text, quoting: turn.quote))
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
                    catalog: catalog,
                    quote: quotation
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
                turns[answer].passages = PageChatPrompt.referenced(in: turns[answer].text, count: passages.count)

                // What the corpus calls each source, rather than the material its catalogue
                // entry carries. An idea's entry is its whole statement and a passage's is the
                // first hundred and sixty characters of the quotation — set in the middle of a
                // sentence, either one is a paragraph of link where the reader expects
                // `Allcock, J., 1988, p. 42`. So the same lookup the reports make, which means
                // a source is named identically whether a report cited it or a question about
                // one did. A citation the corpus cannot name keeps its token: an empty label
                // would be a link with nothing to press.
                let cited = validated.accepted.compactMap(catalog.entry(for:))
                guard !cited.isEmpty, !Task.isCancelled else { return }
                let named = await namer(for: session).labelling(for: cited)
                guard !Task.isCancelled else { return }
                turns[answer].labels = named.inline.filter { !$0.value.isEmpty }
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

    /// The existing Mac stream job owns provider execution. The page keeps only its own
    /// temporary turns; the durable ledger preserves the exact request after a lost ACK.
    private func askMac(_ question:String,passages:[PageChatPassage],subject:PageChatSubject,ai:AISettings) {
        guard !isThinking else {return}
        let session=subject.session,asked=question.trimmingCharacters(in:.whitespacesAndNewlines)
        guard pendingMac != nil || !asked.isEmpty else {return}
        guard session.connection.desktopPairingId != nil,session.canAuthor else {failure=BetaAIFeatures.macRequiredMessage;return}
        macSession=session;isThinking=true;failure=nil
        let observation=UUID();macObservation=observation
        running=Task { @MainActor in
            defer {if macObservation == observation {isThinking=false}}
            do {
                let (vault,pairing,token)=try privateBridgeConnection(session,domain:.researchGeneration)
                guard pairing.domains.contains(.corpus) else {throw DesktopBridgeError.permissionDenied}
                let client=DesktopBridgeClient(pairing:pairing,token:token)
                let capabilities=try await client.liveCapabilities()
                guard capabilities.operations.contains("researchChatStream") else {throw APIError(status:426,code:"page_chat_mac_upgrade_required",message:"Actualiza Nodus en el Mac para conversar sobre este informe.")}
                try Task.checkCancellation()
                if pendingMac == nil {
                    let retrieval=CorpusRetrieval(client:session.client,spaceId:session.connection.spaceId,embeddings:EmbeddingService(keyProvider:ai.keyProvider),identity:nil)
                    let material=try? await retrieval.material(for:"\(subject.title)\n\(asked)")
                    try Task.checkCancellation()
                    let catalog=material?.catalog ?? CitationCatalog(entries:[])
                    let configuration=try await client.operation(vaultId:vault,method:"getMobileLiveChatConfiguration",args:[.string("research")])
                    try Task.checkCancellation()
                    let selection=configuration.objectValue?["selection"] ?? NativeLiveChatOptions.defaultSelection
                    let history=turns.suffix(8).map {JSONValue.object(["role":.string($0.role == .assistant ? "assistant":"user"),"content":.string(PageChatPrompt.asked($0.text,quoting:$0.quote))])}
                    let prompt=PageChatPrompt.system(language:Prompts.interfaceLanguage)+"\n\n"+PageChatPrompt.question(asked,title:subject.title,passages:passages,catalog:catalog,quote:quoted)
                    let id=UUID().uuidString,args:[JSONValue]=[.string(id),PageChatLiveWire.payload(history:history,prompt:prompt,selection:selection)]
                    let ledger=try await DesktopJobLedgers.shared.ledger(pairingId:pairing.id,vaultId:vault)
                    _=try await ledger.prepare(id:id,method:"researchChatStream",args:args)
                    try Task.checkCancellation()
                    let answer=Turn(role:.assistant,text:"")
                    pendingMac=PendingMac(id:id,vault:vault,pairing:pairing.id,answerId:answer.id,args:args,catalog:catalog,passageCount:passages.count)
                    turns.append(Turn(role:.user,text:asked,quote:quoted));turns.append(answer)
                    draft="";quoted=nil
                    if let index=turns.firstIndex(where:{$0.id == answer.id}) {turns[index].warning=material?.warning}
                }
                guard let pending=pendingMac,pending.vault == vault,pending.pairing == pairing.id else {throw DesktopBridgeError.permissionDenied}
                let ledger=try await DesktopJobLedgers.shared.ledger(pairingId:pairing.id,vaultId:vault)
                _=try await ledger.prepare(id:pending.id,method:"researchChatStream",args:pending.args)
                let known=await ledger.all().first(where:{$0.id == pending.id})
                try Task.checkCancellation()
                var job:DesktopBridgeJob
                if known?.cancellationRequested == true {job=try await client.cancelJobRequest(vaultId:vault,method:"researchChatStream",args:pending.args,idempotencyKey:pending.id)}
                else if let jobId=known?.jobId {job=try await client.readJob(vaultId:vault,id:jobId,cursor:pending.stream.sequence)}
                else if let found=try await client.jobForRequest(vaultId:vault,requestId:pending.id) {job=found}
                else {job=try await client.submitJob(vaultId:vault,method:"researchChatStream",args:pending.args,idempotencyKey:pending.id)}
                while true {
                    try Task.checkCancellation()
                    try await ledger.update(id:pending.id,job:job)
                    try Task.checkCancellation()
                    guard macObservation == observation else {return}
                    guard var current=pendingMac,current.id == pending.id else {return}
                    for event in job.events {current.stream.apply(event,requestId:pending.id)}
                    pendingMac=current
                    if let index=turns.firstIndex(where:{$0.id == pending.answerId}) {turns[index].text=current.stream.text}
                    switch job.state {
                    case .available:
                        guard let text=job.result.objectValue?["answer"]?.stringValue else {throw DesktopBridgeError.malformedResponse}
                        let checked=CitationValidator.validate(prose:text,against:pending.catalog)
                        if let index=turns.firstIndex(where:{$0.id == pending.answerId}) {
                            turns[index].text=PageChatLiveWire.validatedMacAnswer(text,passageCount:pending.passageCount)
                            turns[index].passages=PageChatPrompt.referenced(in:turns[index].text,count:pending.passageCount)
                            let cited=checked.accepted.compactMap(pending.catalog.entry(for:))
                            if !cited.isEmpty {
                                let labels=await namer(for:session).labelling(for:cited).inline.filter{!$0.value.isEmpty}
                                try Task.checkCancellation()
                                guard macObservation == observation,pendingMac?.id == pending.id else {return}
                                if let currentIndex=turns.firstIndex(where:{$0.id == pending.answerId}) {turns[currentIndex].labels=labels}
                            }
                        }
                        pendingMac=nil;return
                    case .failed,.interrupted,.cancelled:
                        pendingMac=nil
                        throw APIError(status:409,code:job.state.rawValue,message:job.error ?? "La respuesta se detuvo en el Mac. Se conserva el texto recibido.")
                    case .accepted,.running,.saved:break
                    }
                    try await Task.sleep(for:.milliseconds(700))
                    job=try await client.readJob(vaultId:vault,id:job.id,cursor:current.stream.sequence)
                }
            } catch {
                guard macObservation == observation else {return}
                if let pending=pendingMac,let ledger=try? await DesktopJobLedgers.shared.ledger(pairingId:pending.pairing,vaultId:pending.vault) {try? await ledger.disconnected(id:pending.id,issue:error.localizedDescription)}
                if error.isCancellation {failure="Se ha detenido la observación. El trabajo del Mac conserva su identidad."}
                else if isPrivateBridgeOffline(error) {failure=BetaAIFeatures.macRequiredMessage}
                else {failure=error.localizedDescription}
            }
        }
    }

    private func namer(for session: SpaceSession) -> CorpusCitations {
        if let naming { return naming }
        let made = CorpusCitations(client: session.client, spaceId: session.connection.spaceId)
        naming = made
        return made
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

    /// What the reader asked, with the passage they selected in front of it when there was one.
    ///
    /// One place, so the history and the question the model is handed now say the same thing.
    static func asked(_ question: String, quoting quote: String?) -> String {
        guard let quote, !quote.isEmpty else { return question }
        return """
        Sobre este fragmento del documento:
        «\(quote)»

        \(question)
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
        quote: String? = nil,
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
        \(asked(question, quoting: quote))

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
        _store = State(initialValue: PageChatStore.shared(for: subject.storeKey))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if subject.session.aiExecutionMode == .live {
                    Label("Modelo del Mac conectado", systemImage: "desktopcomputer")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("page-chat-mac-model")
                } else if BetaAIFeatures.autonomousGeneration {
                    ChatModelMenu(accent: accent, openProviders: { showingProviders = true })
                        .padding(.top, 4)
                        .padding(.bottom, 6)
                }

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
                    .nodusModalClose(accent: accent)
            }
            // Opened from a selection, the passage is already there and the question is what is
            // missing — so the keyboard comes up. Opened from the wheel there is nothing to say
            // yet, and a keyboard over the empty state would only hide what it explains.
            .onAppear { composerFocused = store.quoted != nil }
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
            Text("La conversación pertenece a este informe. El trabajo enviado al Mac conserva su identidad para evitar solicitudes duplicadas.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .nodusGlass(NodusGlass(.thin, tint: accent))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            quotation
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
                .frame(minHeight: 44)
                .clipped()
                .nodusGlass(NodusGlass(.regular, tint: accent), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

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
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.isThinking ? "Detener respuesta" : store.canResumeMac ? "Retomar respuesta del Mac" : "Enviar pregunta")
                .disabled(!store.isThinking && !store.canResumeMac && store.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, NodusSpace.page)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .animation(NodusMotion.quick, value: store.quoted)
    }

    /// The passage the reader selected in the report, waiting above the composer.
    ///
    /// Above the field rather than inside it, and that is the point of doing it this way at all:
    /// dropping the words into the text field would leave the reader deleting a paragraph to
    /// write a question. Here the quotation is what the question is *about*, it is visibly
    /// attached, and one press takes it back.
    @ViewBuilder
    private var quotation: some View {
        if let quoted = store.quoted {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "text.quote")
                    .font(.caption)
                    .foregroundStyle(accent.nodusReadable)
                Text(quoted)
                    .font(.caption)
                    .foregroundStyle(Color.nodusSecondaryText)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    store.quoted = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.nodusTertiaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove the quotation")
            }
            .padding(.leading, 13)
            .padding(.trailing, 2)
            .padding(.vertical, 6)
            .nodusGlass(NodusGlass(.thin, tint: accent))
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
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
                VStack(alignment: .leading, spacing: 8) {
                    // The passage this question was asked about, set as a quotation: a rule down
                    // its left edge and the report's own words in the secondary colour, so the
                    // turn reads as "about this, I asked that" rather than as one long message.
                    if let quote = turn.quote {
                        Text(quote)
                            .font(.caption)
                            .italic()
                            .foregroundStyle(Color.nodusSecondaryText)
                            .padding(.leading, 10)
                            .overlay(alignment: .leading) {
                                Capsule().fill(accent.opacity(0.5)).frame(width: 2.5)
                            }
                    }
                    Text(turn.text)
                }
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
                        labels: turn.labels,
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

/// Only the existing research stream wire shape; no provider or prompt ID is invented.
enum PageChatLiveWire {
    /// Corpus tokens are already validated against the Mac retrieval context.
    /// The local catalog enriches labels only; it cannot invalidate Mac sources.
    nonisolated static func validatedMacAnswer(_ text: String, passageCount: Int) -> String {
        PageChatPrompt.dropUnknownReferences(text, count: passageCount)
    }
    @MainActor static func cancelRequest(vaultId:String,args:[JSONValue],id:String,send:(String,String,[JSONValue],String) async throws -> DesktopBridgeJob) async throws -> DesktopBridgeJob {
        guard args.count == 2,args[0] == .string(id),UUID(uuidString:id) != nil else {throw DesktopBridgeError.malformedResponse}
        return try await send(vaultId,"researchChatStream",args,id)
    }
    nonisolated static func payload(history:[JSONValue],prompt:String,selection:JSONValue)->JSONValue {
        .object(["messages":.array(Array(history.suffix(8))+[.object(["role":.string("user"),"content":.string(prompt)])]),"selection":selection,"webSearch":.string("off")])
    }
    struct Stream {
        var sequence=0
        var text=""
        mutating func apply(_ event:DesktopBridgeJob.Event,requestId:String) {
            guard event.sequence > sequence else {return};sequence=event.sequence
            guard event.args.first == .string(requestId),event.args.count >= 2,let content=event.args[1].stringValue else {return}
            if event.channel == "research:chatStream:delta" {text+=content}
            else if event.channel == "research:chatStream:replace" {text=content}
        }
    }
}
