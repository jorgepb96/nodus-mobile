import NodusAI
import NodusKit
import NodusUI
import SwiftUI
import UIKit

// MARK: - Chat

struct ChatScreen: View {
    @Environment(AISettings.self) private var ai
    /// Optional for the same reason `ScrollToTopModifier`'s is: a non-optional `@Environment`
    /// for an `@Observable` is a crash where it is missing, and this screen is previewable
    /// outside the shell that provides one.
    @Environment(NodusChrome.self) private var chrome: NodusChrome?
    /// Read only to know when a fetch from iCloud has landed. Optional for the same reason the
    /// chrome above is.
    @Environment(CloudBackup.self) private var cloud: CloudBackup?
    let session: SpaceSession
    /// Opens the key and model screen. The chat cannot present it itself — `ChatTab` owns that
    /// sheet — and the model menu needs somewhere to send a reader with nothing to choose from.
    var openProviders: (() -> Void)?

    init(session: SpaceSession, openProviders: (() -> Void)? = nil) {
        self.session = session
        self.openProviders = openProviders
        _history = State(initialValue: ChatHistoryStore.shared(spaceId: session.connection.storageId))
        _liveOptions = State(initialValue:NativeLiveChatOptions(spaceId:session.connection.storageId))
    }

    struct Turn: Identifiable {
        var id = UUID()
        let role: ChatMessage.Role
        var text: String
        var citations: [CitationCatalog.Entry] = []
        var mode: CorpusRetrieval.Mode?
        var warning: String?
        var delivery: ChatHistoryStore.Message.Delivery?
        var studyCitations: [JSONValue] = []
        var studyEvidence: JSONValue?
        var worldFacts: JSONValue?
        var createdAt: Date? = Date()
        var desktopRecord:JSONValue?
        var reasoning:String?
        var liveActivities:[JSONValue] = []
        /// The material the answer was built from, grouped by kind — ideas, temas, huecos —
        /// so it can be read beside the answer instead of taken on trust.
        var sections: [CorpusRetrieval.MaterialSection] = []
    }

    @State private var turns: [Turn] = []
    @State private var draft = ""
    @State private var draftLoaded = false
    @State private var draftIssue: String?
    @State private var isThinking = false
    @State private var error: String?
    @State private var running: Task<Void, Never>?
    @State private var generationId: UUID?
    /// The two controls the header draws — which corpus layers a question carries, and the way
    /// into the conversation list. Held as an object rather than as `@State` values so the
    /// header can read and write the same ones the screen does.
    @State private var controls = ChatControls()
    /// The conversations on this device, built with the screen rather than after it.
    ///
    /// It used to be an optional filled in from `.task`, and the sheet that shows it read
    /// `if let history` — so opening the list before that task had run presented a sheet with
    /// nothing in it at all. Nothing about a store that reads one small file justifies the
    /// window in which it does not exist.
    @State private var history: ChatHistoryStore
    @State private var liveOptions:NativeLiveChatOptions
    @State private var showingLiveOptions=false
    /// The conversation these turns belong to. Nil until the first question is asked, so an
    /// opened-and-abandoned tab leaves nothing behind.
    @State private var conversationId: String?
    @State private var conversationTitle = ""
    @State private var conversationCreatedAt = Date()
    @State private var showingHistory = false
    @State private var showingDatabases = false
    @State private var databaseIds: [String] = []
    @State private var showingStudyOptions = false
    @State private var studyOptions = CompanionStudyChatOptions()
    @State private var worldOptions = CompanionWorldChatOptions()
    @State private var showingWorldOptions = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            modelBar

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if turns.isEmpty { emptyState }
                        ForEach(turns) { turn in
                            TurnBubble(turn: turn, accent: session.accent, session: session, conversationId:conversationId,
                                       regenerate: canRegenerate && turn.id == turns.last?.id ? { ask(regenerating: true) } : nil)
                                .id(turn.id)
                        }
                        if let pending=conversationId.flatMap({id in history.conversations.first(where:{$0.id == id})?.pendingLive }) {
                            NativeLiveChatProgressView(activities:pending.activities ?? [],reasoning:pending.reasoning,concilium:pending.concilium,accent:session.accent)
                        }
                        // Only while nothing has arrived: once the first token lands the
                        // prose itself is the progress, and two indicators is one too many.
                        if isThinking, turns.last?.text.isEmpty ?? false {
                            TypingDots(accent: session.accent)
                                .padding(.leading, 2)
                                .id("typing")
                        }
                        if let error {
                            NodusNotice(tone: .blocked, title: "The query failed", message: LocalizedStringKey(error))
                                .accessibilityIdentifier("nodus-chat-error")
                        }
                        if let draftIssue {
                            NodusNotice(tone: .caution, title: "Borrador del chat", message: LocalizedStringKey(draftIssue))
                                .accessibilityIdentifier("nodus-chat-draft-error")
                        }
                    }
                    .padding(16)
                }
                // Two ways out of the keyboard, because a long answer is read by dragging and
                // a short one by looking: the drag closes it on the way, and a tap anywhere in
                // the conversation closes it outright. `simultaneousGesture` rather than
                // `onTapGesture` so a tap that lands on a citation still opens it.
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
                .onChange(of: turns.count) { _, _ in
                    withAnimation { proxy.scrollTo(turns.last?.id, anchor: .bottom) }
                }
            }

            composer
        }
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
        .nodusSheet(isPresented: $showingHistory) {
            ChatHistoryView(
                store: history,
                accent: session.accent,
                currentId: conversationId,
                session: session,
                onOpen: open
            )
            .nodusModalClose(accent: session.accent)
        }
        .nodusSheet(isPresented:$showingDatabases) {
            ChatDatabaseSelectionView(session:session,selection:$databaseIds).environment(ai)
        }
        .nodusSheet(isPresented:$showingStudyOptions) { ChatStudyOptionsView(session:session,options:$studyOptions) }
        .nodusSheet(isPresented:$showingWorldOptions) { ChatWorldOptionsView(session:session,options:$worldOptions) }
        .nodusSheet(isPresented:$showingLiveOptions) { NativeLiveChatOptionsView(session:session,options:liveOptions,conversationId:conversationId) }
        .task {
            if !draftLoaded {
                do { if draft.isEmpty { draft = try history.loadComposerDraft() } }
                catch { draftIssue = error.localizedDescription }
                draftLoaded = true
            }
            // Lent to the chrome, not copied into it: the header ticks layers on and off in the
            // very object the next question is built from.
            controls.openHistory = openHistory
            chrome?.chat = controls
            if session.connection.desktopPairingId != nil,session.connection.role.canSendChanges {
                do { try history.bind(kind:CompanionChatKind(vaultType:session.vaultType)) } catch { self.error = error.localizedDescription }
            }
            if session.aiExecutionMode == .live {
                await liveOptions.load(session:session,conversationId:conversationId)
                if let id=conversationId,history.conversations.first(where:{$0.id == id})?.pendingLive != nil { observeLive(id) }
                else if turns.isEmpty,let pending=history.active.first(where:{$0.pendingLive != nil}) { open(pending) }
            }
        }
        // A fetch from iCloud writes conversation files underneath this store, which would
        // otherwise keep showing the list it read when the screen opened.
        .onChange(of: cloud?.lastFetchedAt) { _, _ in history.reload() }
        .onChange(of: draft) { _, value in
            guard draftLoaded else { return }
            do { try history.saveComposerDraft(value); draftIssue = nil }
            catch { draftIssue = error.localizedDescription }
        }
        .onChange(of:conversationId.flatMap { id in history.conversations.first(where:{$0.id == id})?.updatedAt }) { _,_ in
            if let id=conversationId,history.conversations.first(where:{$0.id == id})?.pendingLive != nil || isThinking && session.aiExecutionMode == .live { refreshLive(id) }
        }
        .onDisappear {
            // Only if they are still ours. On iPad the detail column really does swap screens,
            // and a chat that has been replaced should not leave its controls on the header.
            if chrome?.chat === controls { chrome?.chat = nil }
            stopCurrentConversation()
        }
    }

    // MARK: - Controls

    /// The strip under the header, and the one thing on it.
    ///
    /// It used to carry a history button, the conversation's name and a corpus-layer filter on a
    /// band of grey system material — two controls that never change while you read, drawn in a
    /// material that belongs to no part of this app, immediately under a header made of glass.
    /// Both controls are in the header now (`SpaceShell.header`), and what is left is the page's
    /// own colour with the one control on it you genuinely reach for mid-conversation: which
    /// model is answering.
    ///
    /// The menu is centred by being *laid out* centred and the compose button overlaid on top of
    /// it, the same trick the header uses for the mark: in an `HStack` the pill would sit
    /// wherever the button beside it left room, and would move every time a model with a longer
    /// name was chosen.
    private var modelBar: some View {
        VStack(spacing: 2) {
            Group {
                if session.aiExecutionMode == .live {
                    Button { composerFocused=false;showingLiveOptions=true } label: {
                        Label(liveOptions.modelName(liveOptions.effectiveModel),systemImage:"desktopcomputer")
                            .font(.caption).lineLimit(1).truncationMode(.middle).frame(minHeight:44).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(session.accent).disabled(isThinking).accessibilityIdentifier("nodus-chat-live-options")
                } else { ChatModelMenu(accent: session.accent, openProviders: openProviders) }
            }
                // Room at both ends for the compose button overlaid at the trailing edge, taken
                // symmetrically so a long model name is truncated rather than drawn under it —
                // and so the pill stays on the centre line whatever it is naming.
                .padding(.horizontal, 48)
                .frame(maxWidth: .infinity)
                .overlay(alignment:.leading) {
                    Button(action:openHistory) { Image(systemName:"clock.arrow.circlepath").frame(width:44,height:44).contentShape(Rectangle()) }
                        .buttonStyle(.plain).foregroundStyle(session.accent).accessibilityLabel("Conversation history").accessibilityIdentifier("nodus-chat-history")
                }
                .overlay(alignment: .trailing) {
                    if !turns.isEmpty {
                        Button {
                            composerFocused = false
                            startNewConversation()
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.callout)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(session.accent)
                        .accessibilityLabel("New conversation")
                        .accessibilityIdentifier("nodus-chat-new")
                    }
                }

            if session.vaultType == .databases {
                Button { composerFocused = false;showingDatabases = true } label: {
                    Label("\(databaseIds.count) databases",systemImage:"tablecells").font(.caption).lineLimit(1).padding(.horizontal,12).frame(minHeight:44)
                }.buttonStyle(.plain).foregroundStyle(session.accent).disabled(isThinking)
            } else if isStudy {
                Button { composerFocused = false;showingStudyOptions = true } label: {
                    Label("Fuentes y opciones de estudio",systemImage:"books.vertical").font(.caption).padding(.horizontal,12).frame(minHeight:44)
                }.buttonStyle(.plain).foregroundStyle(session.accent).disabled(isThinking)
            } else if session.vaultType == .worldbuilding {
                Button { composerFocused = false;showingWorldOptions = true } label: {
                    Label(worldOptions.focus.isEmpty ? "Contexto del mundo":worldOptions.focus.map(\.title).joined(separator:" · "),systemImage:"globe").font(.caption).lineLimit(1).padding(.horizontal,12).frame(minHeight:44)
                }.buttonStyle(.plain).foregroundStyle(session.accent).disabled(isThinking)
            } else if session.aiExecutionMode == .live {
                Button { composerFocused=false;showingLiveOptions=true } label: {
                    Label("Contexto y opciones",systemImage:"square.3.layers.3d").font(.caption).frame(minHeight:44)
                }.buttonStyle(.plain).foregroundStyle(session.accent).disabled(isThinking)
            } else {
                Menu {
                    ForEach(ContextSectionKind.allCases,id:\.self) { kind in
                        Toggle(contextLabel(kind),isOn:Binding(get:{controls.include.contains(kind)},set:{ enabled in if enabled { controls.include.insert(kind) } else { controls.include.remove(kind) } }))
                    }
                } label: {
                    Label("Context",systemImage:"square.3.layers.3d").font(.caption).frame(minHeight:44)
                }.foregroundStyle(session.accent).disabled(isThinking)
            }

            // Which conversation this is, when it is one that has a name. A new conversation
            // says nothing here rather than saying "New conversation", because an empty screen
            // with a composer under it has already said that.
            if !conversationTitle.isEmpty {
                Text(conversationTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 52)
            }
            if let pending=conversationId.flatMap({ id in history.conversations.first(where:{$0.id == id})?.pendingLive }),let issue=pending.issue {
                Text(issue).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Button("Recuperar respuesta del Mac") { if let id=conversationId { observeLive(id) } }.font(.caption).frame(minHeight:44)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private func openHistory() {
        composerFocused = false
        showingHistory = true
    }
    private func contextLabel(_ kind: ContextSectionKind) -> LocalizedStringKey {
        switch kind { case .ideas:"Ideas";case .passages:"Passages";case .themes:"Themes";case .gaps:"Research gaps";case .works:"Works";case .sources:"Sources" }
    }
    private var isStudy: Bool { session.vaultType == .estudio || session.vaultType == .docencia }

    // MARK: - Conversations

    private func startNewConversation() {
        stopCurrentConversation()
        turns = []
        error = nil
        conversationId = nil
        conversationTitle = ""
        databaseIds = []
        studyOptions = CompanionStudyChatOptions()
        worldOptions = CompanionWorldChatOptions()
        liveOptions.preferences.attachmentIds=[]
        liveOptions.preferences.systemPromptId=nil;liveOptions.preferences.useMacPrompt=true
    }

    private func open(_ conversation: ChatHistoryStore.Conversation) {
        stopCurrentConversation()
        displayConversation(conversation)
        if conversation.pendingLive != nil { observeLive(conversation.id) }
    }
    private func displayConversation(_ conversation:ChatHistoryStore.Conversation) {
        error = nil
        conversationId = conversation.id
        conversationTitle = conversation.title
        conversationCreatedAt = conversation.createdAt
        databaseIds = conversation.databaseIds ?? []
        studyOptions = conversation.study ?? CompanionStudyChatOptions()
        worldOptions = conversation.world ?? CompanionWorldChatOptions()
        if let generation=conversation.pendingLive?.request.generation.objectValue {
            liveOptions.preferences.model=generation["model"]
            liveOptions.preferences.thinkingEffort=generation["thinkingEffort"]?.stringValue ?? "standard"
            if let selection=generation["selection"] { liveOptions.preferences.selection=selection }
        } else { liveOptions.adoptConversation(conversation.desktop?.baseline) }
        // The retrieved material is not kept — see `ChatHistoryStore` — so a re-opened
        // conversation shows what was said and what it cited, and does not pretend to still
        // hold the corpus rows the answer was built from.
        turns = conversation.messages.map { message in
            Turn(
                id: message.id,
                role: message.role == .user ? .user : .assistant,
                text: message.text,
                citations: message.citations,
                mode: message.wasSemantic.map { $0 ? .semantic : .lexical },
                warning: message.delivery == .streaming && conversation.pendingLive == nil ? String(localized:"This reply was interrupted. The received text is kept here."):message.warning,
                delivery: message.delivery,
                studyCitations:message.studyCitations ?? [],
                studyEvidence:message.studyEvidence,
                worldFacts:message.worldFacts,
                createdAt:message.createdAt,
                desktopRecord:message.desktopRecord,
                reasoning:message.reasoning,
                liveActivities:message.liveActivities ?? []
            )
        }
    }

    /// Save the accepted question, periodic received text and terminal state.
    private func persist() throws {
        guard !turns.isEmpty else { return }
        try history.save(conversationForSaving())
    }
    private func conversationForSaving() -> ChatHistoryStore.Conversation {
        let id = conversationId ?? UUID().uuidString
        conversationId = id
        if conversationTitle.isEmpty {
            conversationTitle = ChatHistoryStore.title(from: turns.first?.text ?? "")
        }
        return ChatHistoryStore.Conversation(
            id: id,
            title: history.conversations.first(where:{$0.id == id})?.title ?? conversationTitle,
            messages: turns.map { turn in
                ChatHistoryStore.Message(
                    id: turn.id,
                    role: turn.role == .user ? .user : .assistant,
                    text: turn.text,
                    citations: turn.citations,
                    wasSemantic: turn.mode.map { $0 == .semantic },
                    warning: turn.warning,
                    delivery: turn.delivery,
                    desktopRecord:turn.desktopRecord,
                    studyCitations:turn.studyCitations.isEmpty ? nil:turn.studyCitations,
                    studyEvidence:turn.studyEvidence,
                    worldFacts:turn.worldFacts,
                    createdAt:turn.createdAt,
                    reasoning:turn.reasoning,
                    liveActivities:turn.liveActivities.isEmpty ? nil:turn.liveActivities
                )
            },
            createdAt: conversationCreatedAt,
            updatedAt: Date(),
            isArchived: history.conversations.first(where:{$0.id == id})?.isArchived ?? false,
            databaseIds: session.vaultType == .databases ? databaseIds:nil,
            study:isStudy ? studyOptions:nil,
            world:session.vaultType == .worldbuilding ? worldOptions:nil
        )
    }
    private func stopCurrentConversation(cancelMac:Bool = false) {
        if let id=conversationId,history.conversations.first(where:{$0.id == id})?.pendingLive != nil {
            generationId=nil;running?.cancel();running=nil
            if cancelMac {
                isThinking=true
                running=Task {
                    do { _=try await NativeLiveChat.step(id:id,session:session,cancel:true) }
                    catch { NativeLiveChat.recordIssue(id:id,session:session,error:error) }
                    if conversationId == id { refreshLive(id) }
                }
            } else { isThinking=false }
            return
        }
        if isThinking {
            if let index = turns.indices.last,turns[index].role == .assistant { turns[index].delivery = .cancelled;turns[index].warning = String(localized:"Cancelled.") }
            do { try persist() } catch { self.error = error.localizedDescription }
        }
        generationId = nil;running?.cancel();running = nil;isThinking = false
    }
    private func refreshLive(_ id:String) {
        guard conversationId == id,let conversation=history.conversations.first(where:{$0.id == id}) else { return }
        displayConversation(conversation);isThinking=conversation.pendingLive != nil
    }
    private func observeLive(_ id:String) {
        running?.cancel();isThinking=true
        let identity=UUID();generationId=identity
        running=Task {
            await NativeLiveChat.observe(id:id,session:session) {
                if generationId == identity { refreshLive(id) }
            }
            if generationId == identity { running=nil;refreshLive(id) }
        }
    }
    private var canRegenerate: Bool {
        !isThinking && session.connection.role.canSendChanges && turns.count >= 2 &&
        turns.last?.role == .assistant && turns[turns.count - 2].role == .user
    }
    private func askLive(regenerating: Bool = false) {
        guard !isThinking,session.aiExecutionMode == .live else { return }
        if regenerating && !canRegenerate { return }
        guard let pairing=session.connection.desktopPairingId,session.connection.role.canSendChanges else { error="Vincula Nodus con tu Mac para generar en modo live.";return }
        let question=(regenerating ? turns[turns.count - 2].text : draft).trimmingCharacters(in:.whitespacesAndNewlines);guard !question.isEmpty else { return }
        if session.vaultType == .databases,databaseIds.isEmpty { error="Elige al menos una base de datos.";showingDatabases=true;return }
        if isStudy {
            let selection=studyOptions.selection
            if selection.scope == "manual" && selection.sourceKeys.isEmpty || selection.scope == "course" && selection.courseId == nil || selection.scope == "subject" && selection.subjectId == nil || selection.scope == "topic" && selection.topicId == nil {
                error="Elige las fuentes o el alcance de esta pregunta.";showingStudyOptions=true;return
            }
        }
        if session.vaultType == .worldbuilding,worldOptions.selection.scope == "manual",worldOptions.selection.entryKeys.isEmpty { error="Elige los elementos del mundo para esta pregunta.";showingWorldOptions=true;return }
        let prior=turns,priorId=conversationId,priorTitle=conversationTitle,priorDate=conversationCreatedAt
        do {
            let kind=CompanionChatKind(vaultType:session.vaultType)
            try history.bind(kind:kind)
            let generation=try liveOptions.generation(kind:kind)
            if regenerating { turns.removeLast() }
            else { turns.append(Turn(role:.user,text:question)) }
            if conversationId == nil { conversationCreatedAt=Date() }
            let proposal=conversationForSaving(),answerId=UUID()
            _=try history.beginLive(proposal,pairingId:pairing,generation:generation,answerId:answerId)
            if !regenerating { draft="" }
            error=nil;composerFocused=false
            refreshLive(proposal.id);observeLive(proposal.id)
        } catch {
            turns=prior;conversationId=priorId;conversationTitle=priorTitle;conversationCreatedAt=priorDate
            self.error=error.localizedDescription
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask \(session.connection.spaceName)")
                .font(.headline)
            Text("Every answer rests on real corpus rows. Citations are checked against the catalogue: if the model invents a source, it is removed.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .nodusGlass(NodusGlass(.thin, tint: session.accent))
    }

    /// Where the question is typed.
    ///
    /// Two things were wrong with it and they were the same thing. The bar was a slab of grey
    /// `.ultraThinMaterial` — the system's own material, not this app's glass, sitting between a
    /// glass header and a glass tab bar — and the field on it was an accent wash at 18%, which
    /// over that grey is very nearly the grey. So the one control on the screen that has to look
    /// like somewhere to type looked like a seam between two bars.
    ///
    /// The bar keeps the page's colour, which is what it is standing on, and the field is the
    /// app's own glass capsule — the same surface `NodusSearchField` uses, because it is the
    /// same object: a place to put words.
    ///
    /// `fixedSize` vertically, because in a `VStack` under a `ScrollView` the greedy sibling
    /// wins ties: the composer was being compressed to a fraction of its height and the capsule
    /// with it. A row that states its own height cannot be squeezed by the conversation above.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("", text: $draft, prompt: placeholder, axis: .vertical)
                .accessibilityIdentifier("nodus-chat-composer")
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .frame(minHeight: 44)
                .nodusGlass(NodusGlass(.regular, tint: session.accent), in: Capsule())

            Button {
                if isThinking { stopCurrentConversation(cancelMac:true) } else { ask() }
            } label: {
                Image(systemName: isThinking ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(session.accent)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!isThinking && draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel(isThinking ? "Stop" : "Send").accessibilityIdentifier("nodus-chat-send")
            .accessibilityValue(isThinking ? "running" : "idle")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, NodusSpace.page)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    /// The placeholder, said loudly enough to be read — the same reasoning as
    /// `NodusSearchField`'s: a `TextField`'s own prompt is drawn at about a quarter of the label
    /// colour, which over tinted glass is the faintest thing on the screen.
    private var placeholder: Text {
        Text("Ask a question").foregroundColor(.nodusTertiaryText)
    }

    private func ask(regenerating: Bool = false) {
        if session.aiExecutionMode == .live { askLive(regenerating: regenerating);return }
        guard !isThinking,session.aiExecutionMode == .autonomous else { return }
        if regenerating && !canRegenerate { return }
        guard let model = ai.model(for: .chat) else {
            error = String(localized: "Choose a chat model under Providers.")
            return
        }
        let question = (regenerating ? turns[turns.count - 2].text : draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        if session.vaultType == .databases,databaseIds.isEmpty { error = String(localized:"Choose at least one database for this question.");showingDatabases = true;return }
        if isStudy {
            let selection = studyOptions.selection
            if selection.scope == "manual" && selection.sourceKeys.isEmpty || selection.scope == "course" && selection.courseId == nil || selection.scope == "subject" && selection.subjectId == nil || selection.scope == "topic" && selection.topicId == nil {
                error = "Elige las fuentes o el alcance de esta pregunta.";showingStudyOptions = true;return
            }
        }
        if session.vaultType == .worldbuilding,worldOptions.selection.scope == "manual",worldOptions.selection.entryKeys.isEmpty { error = "Elige los elementos del mundo para esta pregunta.";showingWorldOptions = true;return }
        let selectedDatabases = databaseIds
        let selectedStudy = studyOptions
        let selectedWorld = worldOptions
        let selectedProject = conversationId.flatMap { id in history.conversations.first(where:{$0.id == id})?.placement?.projectId }
        let previousTurns = turns, previousDraft = draft
        if regenerating { turns.removeLast() }
        let contextTurns = regenerating ? Array(turns.dropLast()) : turns
        let prior = contextTurns.map { ChatMessage(role:$0.role,content:$0.text) }

        if !regenerating { draft = "" }
        error = nil
        if !regenerating { turns.append(Turn(role: .user, text: question)) }
        let answerIndex = turns.count
        turns.append(Turn(role: .assistant, text: "",delivery:.streaming))
        if conversationId == nil { conversationCreatedAt = Date() }
        do { try persist() } catch { turns = previousTurns; draft = previousDraft; self.error = error.localizedDescription;return }
        let identity = UUID(),answerId = turns[answerIndex].id
        generationId = identity;isThinking = true
        func ownsAnswer() -> Bool { generationId == identity && turns.indices.contains(answerIndex) && turns[answerIndex].id == answerId }
        running = Task {
            defer {
                // Saved on every ending — finished, cancelled or failed. A turn that cost a
                // retrieval and a model call should not depend on how it stopped.
                if ownsAnswer() {
                    isThinking = false;running = nil;generationId = nil
                    do { try persist() } catch { self.error = error.localizedDescription }
                }
            }
            do {
                let material: CorpusRetrieval.Result?
                var request: ChatRequest
                var studyContext: CompanionChatContext.StudyPrepared?
                var worldContext: CompanionChatContext.WorldPrepared?
                if session.vaultType == .databases {
                    let context = try await CompanionChatContext.database(session:session,settings:ai,ids:selectedDatabases,question:question,history:prior)
                    guard !Task.isCancelled,ownsAnswer() else { return }
                    material = nil
                    request = ChatRequest(model:model,messages:[.init(role:.system,content:context.system),.init(role:.user,content:context.user)],temperature:context.temperature,maxTokens:context.maxTokens)
                } else if isStudy {
                    let context = try await CompanionChatContext.study(session:session,options:selectedStudy,question:question,history:prior)
                    guard !Task.isCancelled,ownsAnswer() else { return }
                    material = nil;studyContext = context
                    turns[answerIndex].mode = .lexical
                    turns[answerIndex].studyCitations = context.citations
                    turns[answerIndex].studyEvidence = context.evidence
                    if context.truncated { turns[answerIndex].warning = "Las fuentes completas siguen disponibles; esta respuesta utiliza los fragmentos que caben en el contexto." }
                    if let immediate = context.immediateAnswer {
                        turns[answerIndex].text = immediate;turns[answerIndex].delivery = .completed;return
                    }
                    request = ChatRequest(model:model,messages:[.init(role:.system,content:context.system),.init(role:.user,content:context.user)],temperature:context.temperature,maxTokens:context.maxTokens)
                } else if session.vaultType == .worldbuilding {
                    let context = try await CompanionChatContext.world(session:session,options:selectedWorld,question:question,history:prior)
                    guard !Task.isCancelled,ownsAnswer() else { return }
                    material = nil;worldContext = context;worldOptions.focus = context.focus;turns[answerIndex].worldFacts = context.facts
                    if context.noMaterial { turns[answerIndex].text = "No he encontrado material para esta pregunta en las fuentes disponibles. Nombra un personaje, lugar, escena o regla, o elige el foco de la pregunta.";turns[answerIndex].delivery = .completed;return }
                    request = ChatRequest(model:model,messages:[.init(role:.system,content:context.system),.init(role:.user,content:context.user)],temperature:context.temperature,maxTokens:context.maxTokens)
                } else {
                    let retrieval = CorpusRetrieval(
                        client:session.client,
                        spaceId:session.connection.spaceId,
                        embeddings:EmbeddingService(keyProvider:ai.keyProvider),
                        identity:semanticIdentity
                    )
                    let retrieved = try await retrieval.material(
                        for:question,
                        include:ContextSectionKind.allCases.filter(controls.include.contains)
                    )
                    guard !Task.isCancelled,ownsAnswer() else { return }
                    material = retrieved
                    turns[answerIndex].mode = retrieved.mode
                    turns[answerIndex].warning = retrieved.warning
                    turns[answerIndex].sections = retrieved.sections
                    let context = NativeChatPrompt.make(history:prior,system:Prompts.system(language:Prompts.interfaceLanguage),question:question,citations:Prompts.citationPolicy(catalog:retrieved.catalog))
                    if context.omittedTurns > 0 {
                        let warning = String(localized:"Earlier turns remain in history but do not fit in this question's context.")
                        turns[answerIndex].warning = [retrieved.warning,warning].compactMap{$0}.joined(separator:" ")
                    }
                    request = ChatRequest(model:model,messages:context.messages,temperature:0.4)
                }
                if let selectedProject {
                    let project = try await history.projectPreferences(selectedProject,session:session)
                    guard let index = request.messages.firstIndex(where:{$0.role == .system}) else { throw DesktopBridgeError.malformedResponse }
                    let system = try await CompanionChatContext.projectSystem(request.messages[index].content,project:project)
                    request.messages[index] = .init(role:.system,content:system)
                }
                guard ownsAnswer(),!Task.isCancelled else { return }
                let provider = ProviderClient(keyProvider: ai.keyProvider)

                var text = ""
                var savedAt = Date()
                for try await delta in provider.stream(request) {
                    guard !Task.isCancelled,ownsAnswer() else { return }
                    if case .content(let chunk) = delta {
                        text += chunk
                        turns[answerIndex].text = text
                        if Date().timeIntervalSince(savedAt) >= 1 { try persist();savedAt = Date() }
                    }
                }

                // The same guarantee the reports get: an invented source never reaches the
                // screen, and what survived is listed so the user can open it.
                guard ownsAnswer(),!Task.isCancelled else { return }
                if let studyContext {
                    let validated = try await CompanionChatContext.validateStudyAnswer(text,citations:studyContext.citations)
                    guard ownsAnswer(),!Task.isCancelled else { return }
                    turns[answerIndex].text = validated.answer;turns[answerIndex].studyCitations = validated.citations
                    if validated.citationWarning { turns[answerIndex].warning = "La respuesta no incluyó referencias a los fragmentos seleccionados." }
                } else if let worldContext {
                    let validated = try await CompanionChatContext.validateWorldAnswer(text,citable:worldContext.citable)
                    guard ownsAnswer(),!Task.isCancelled else { return };turns[answerIndex].text = validated
                } else if let material {
                    let validated = CitationValidator.validate(prose:text,against:material.catalog)
                    turns[answerIndex].text = validated.prose
                    turns[answerIndex].citations = validated.accepted.compactMap(material.catalog.entry(for:))
                } else {
                    // Numerical data is grounded by the exact Desktop profile;
                    // unrelated corpus URLs are never accepted as evidence.
                    turns[answerIndex].text = CitationValidator.validate(prose:text,against:CitationCatalog(entries:[])).prose
                }
                turns[answerIndex].delivery = .completed
            } catch is CancellationError {
                if ownsAnswer() { turns[answerIndex].delivery = .cancelled;turns[answerIndex].text += "\n\n_" + String(localized:"Cancelled.") + "_" }
            } catch {
                guard ownsAnswer() else { return }
                if case ProviderError.missingKey(let provider) = error { ai.markRejected(provider) }
                if case ProviderError.http(let status, let provider, _) = error, status == 401 || status == 403 {
                    ai.markRejected(provider)
                }
                turns[answerIndex].warning = error.localizedDescription
                turns[answerIndex].delivery = .failed
                self.error = error.localizedDescription
            }
        }
    }

    private var semanticIdentity: EmbeddingIdentity? {
        guard case .published(let identity) = session.embedding, session.embedding.isReachableFromPhone else { return nil }
        return identity
    }
}

/// Changing the model without leaving the conversation.
///
/// The model is the one setting that belongs *on* the chat rather than in a settings screen: it
/// is chosen per question, not per app — a cheap fast model for "what does this vault have on
/// X", a careful one for the answer you are going to quote. Reaching it used to mean Providers,
/// then the chat model row, then a list of several hundred, then back.
///
/// What it offers is the pinned models and nothing else. A menu is not a catalogue: OpenRouter
/// alone publishes hundreds, and a dropdown of hundreds is the screen this is meant to save you
/// from. The order is the same one `ModelPickerView` uses — alphabetical by provider, then by
/// model — so a model is in the same place here as it is there.
struct ChatModelMenu: View {
    @Environment(AISettings.self) private var settings
    let accent: Color
    var openProviders: (() -> Void)?

    /// The pinned models, plus whatever is currently answering.
    ///
    /// The current model is included even when it is not pinned, because a menu that cannot show
    /// the state it controls is a menu that lies: unpin the model you are using and the pill
    /// would name a model the list does not contain.
    private var featured: [ModelRef] {
        var models = settings.pinnedModels
        if let current = settings.model(for: .chat), !models.contains(current) {
            models.append(current)
        }
        return models.sorted {
            $0.provider.label == $1.provider.label
                ? $0.model.localizedStandardCompare($1.model) == .orderedAscending
                : $0.provider.label < $1.provider.label
        }
    }

    private var current: ModelRef? { settings.model(for: .chat) }

    var body: some View {
        Menu {
            ForEach(featured, id: \.self) { model in
                Button {
                    settings.setModel(model, for: .chat)
                } label: {
                    // Two `Text`s, which a menu draws as a title and a subtitle under it. The
                    // provider is not decoration — two of them serve `gpt-4o-mini`, and the name
                    // alone does not say which one is about to be billed — but joined into one
                    // string it was what got truncated on the long ids, so the answer to "which
                    // provider" disappeared exactly where the question was hardest.
                    Text(verbatim: model.model)
                    Text(verbatim: model.provider.label)
                    if model == current { Image(systemName: "checkmark") }
                }
            }
            if !featured.isEmpty { Divider() }
            Button {
                openProviders?()
            } label: {
                Label(featured.isEmpty ? "Choose a model" : "All models", systemImage: "slider.horizontal.3")
            }
        } label: {
            HStack(spacing: 5) {
                // `verbatim` for the model's own id, which is a name and not a phrase to be
                // translated; the key for the case where there is nothing to name yet.
                if let current {
                    Text(verbatim: current.model)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Choose a model").lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(accent.nodusReadable)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            // A control, so it is lit: this is the one thing on the strip that acts, and the
            // strip itself is now the page's own colour.
            .nodusGlass(NodusGlass(.thin, tint: accent, interactive: true), in: Capsule())
        }
        .accessibilityLabel("Model")
        .accessibilityValue(current.map { "\($0.model), \($0.provider.label)" } ?? "")
    }
}

private struct TurnBubble: View {
    let turn: ChatScreen.Turn
    let accent: Color
    let session: SpaceSession
    let conversationId:String?
    var regenerate: (() -> Void)?
    @State private var studyCitation: JSONValue?
    @State private var showingStudyCitation = false
    @State private var showingWorldFacts = false
    @State private var worldSourceKey: String?
    @State private var showingWorldSource = false
    @State private var showingRichAnswer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if turn.role == .user {
                Text(turn.text)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .nodusGlass(NodusGlass(.regular, tint: accent))
                if hasSavedDetails { Button { showingRichAnswer=true } label: { Label("Ver adjuntos y detalles",systemImage:"paperclip").frame(minHeight:44) }.buttonStyle(.plain).foregroundStyle(accent) }
                if let warning=turn.warning { NodusNotice(tone:.caution,title:"Estado de la solicitud",message:LocalizedStringKey(warning)) }
            } else {
                if let warning = turn.warning {
                    NodusNotice(tone: .caution, title: turn.mode == .lexical ? "Lexical retrieval":"Estado de la respuesta", message: LocalizedStringKey(warning))
                }
                if turn.text.isEmpty {
                    Text("…").frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // The same citations the report gets, in the same shape: the source's name,
                    // and a tap opens it.
                    CorpusProse(
                        bubbleProse,
                        accent: accent,
                        session: session,
                        labels: Dictionary(turn.citations.map { ($0.token, $0.label) }, uniquingKeysWith: { first, _ in first }),
                        onCitation: { url in
                            if session.vaultType == .worldbuilding,url.scheme == "nodus",url.host == "world",url.pathComponents.count == 3 {
                                worldSourceKey = "\(url.pathComponents[1]):\(url.pathComponents[2])";showingWorldSource = true;return true
                            }
                            guard url.scheme == "nodus",url.host == "study",url.pathComponents.count == 3,url.pathComponents[1] == "evidence",let citation = turn.studyCitations.first(where:{$0.objectValue?["id"]?.stringValue == url.lastPathComponent}) else { return false }
                            studyCitation = citation;showingStudyCitation = true;return true
                        }
                    )
                    if hasRichContent || hasSavedDetails {
                        Button { showingRichAnswer=true } label: {
                            Label("Leer respuesta completa",systemImage:"doc.richtext").font(.body.weight(.medium)).frame(minHeight:44)
                        }.buttonStyle(.plain).foregroundStyle(accent)
                    }
                }

                if !turn.studyCitations.isEmpty {
                    VStack(alignment:.leading,spacing:4) {
                        Text("Fuentes de estudio").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(turn.studyCitations,id:\.self) { citation in
                            Button { studyCitation = citation;showingStudyCitation = true } label: {
                                Label("\(citation.objectValue?["id"]?.stringValue ?? "") · \(citation.objectValue?["title"]?.stringValue ?? "Fuente")",systemImage:"text.quote").font(.caption).multilineTextAlignment(.leading).frame(minHeight:44)
                            }.buttonStyle(.plain).foregroundStyle(accent)
                        }
                    }
                }
                if turn.worldFacts != nil { Button { showingWorldFacts = true } label: { Label("Ver hechos y fuentes del mundo",systemImage:"checkmark.seal").font(.caption).frame(minHeight:44) }.buttonStyle(.plain).foregroundStyle(accent) }

                if !turn.citations.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Sources").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Array(Set(turn.citations.map(\.token))).sorted(), id: \.self) { token in
                            if let entry = turn.citations.first(where: { $0.token == token }) {
                                HStack(spacing: 6) {
                                    Image(systemName: icon(entry.kind)).font(.caption2).foregroundStyle(accent)
                                    Text(entry.label).font(.caption).lineLimit(2)
                                }
                            }
                        }
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }

                if !turn.sections.isEmpty {
                    MaterialBrowser(sections: turn.sections, accent: accent, session: session)
                }
                NativeLiveChatProgressView(activities:turn.liveActivities,reasoning:turn.reasoning,concilium:nil,accent:accent)

                if !turn.text.isEmpty {
                    HStack(spacing: 8) {
                        if let mode = turn.mode {
                            Text(mode == .semantic ? "Semantic retrieval" : "Lexical retrieval")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        if let regenerate {
                            Button(action: regenerate) { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44).contentShape(Rectangle()) }
                                .buttonStyle(.plain).foregroundStyle(accent)
                                .accessibilityLabel("Regenerar respuesta").accessibilityIdentifier("nodus-chat-regenerate")
                        }
                        AnswerCopyButton(markdown: turn.text, accent: accent)
                    }
                }
            }
        }.accessibilityElement(children: .contain)
            .accessibilityIdentifier(turn.role == .user ? "nodus-chat-question" : "nodus-chat-answer")
            .nodusSheet(isPresented:$showingStudyCitation) { if let studyCitation { StudyChatEvidenceView(citation:studyCitation,session:session) } }
            .nodusSheet(isPresented:$showingWorldFacts) { if let facts = turn.worldFacts { WorldChatFactsView(facts:facts,session:session) } }
            .nodusSheet(isPresented:$showingWorldSource) { if let key = worldSourceKey { WorldChatSourceView(key:key,session:session) } }
            .nodusSheet(isPresented:$showingRichAnswer) { RichChatAnswerView(session:session,content:turn.text,conversationId:conversationId,studyCitations:turn.studyCitations,desktopRecord:turn.desktopRecord) }
    }

    private var hasRichContent:Bool {
        turn.text.contains("```") || turn.text.contains("$$") || turn.text.contains("\\[") || turn.text.contains("<svg") || turn.text.contains("<img") || turn.text.contains("|---") || turn.text.contains("| ---") || turn.text.range(of:#"\$[^$\n]+\$"#,options:.regularExpression) != nil
    }
    private var hasSavedDetails:Bool {
        guard let record=turn.desktopRecord?.objectValue else { return false }
        return !(record["attachments"]?.arrayValue ?? []).isEmpty || record["concilium"]?.objectValue != nil || !(record["skills"]?.arrayValue ?? []).isEmpty
    }
    private var bubbleProse:String {
        guard hasRichContent else { return turn.text }
        // A compact native entry opens the full ordered document, rather than
        // exposing JSON fences or squeezing an interactive result into a bubble.
        let prose=turn.text.components(separatedBy:"```").first ?? ""
        return prose.isEmpty ? String(localized:"Respuesta con contenido enriquecido"):String(prose.prefix(1200))
    }

    private func icon(_ kind: String) -> String {
        switch kind {
        case "idea": return "lightbulb"
        case "passage": return "text.quote"
        case "work": return "book.closed"
        default: return "doc"
        }
    }
}

/// Take the answer with you.
///
/// A tap copies the prose, and the citations do not come with it. That is the deliberate
/// choice: a chat answer cites by writing the token itself — `(nodus://idea/g-8969)` — which
/// is a door on this screen and line noise in a message, an email or a paper. `ReadingCopy`
/// is the same rule the reports' second copy button runs, parity-tested against the desktop.
///
/// The links are one long press away for the case that wants them: pasting an answer back
/// into Nodus, where they resolve.
private struct AnswerCopyButton: View {
    let markdown: String
    let accent: Color

    @State private var copied = false

    var body: some View {
        Button {
            copy(ReadingCopy.text(from: markdown))
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent)
        .accessibilityLabel("Copy the answer")
        .accessibilityIdentifier("nodus-chat-copy")
        .contextMenu {
            Button {
                copy(ReadingCopy.text(from: markdown))
            } label: {
                Label("Copy the answer", systemImage: "doc.on.doc")
            }
            Button {
                copy(markdown)
            } label: {
                Label("Copy with citation links", systemImage: "link")
            }
        }
        .animation(NodusMotion.quick, value: copied)
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}


/// The corpus the answer was built from, browsable.
///
/// The desktop shows the assistant's context as named sections — ideas generadas, temas
/// principales, huecos de investigación — and that is more than decoration: an answer is only
/// as good as what it was given, and a reader who can see the material can tell the difference
/// between a thin retrieval and a thin corpus.
private struct MaterialBrowser: View {
    let sections: [CorpusRetrieval.MaterialSection]
    let accent: Color
    let session: SpaceSession

    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Retrieved material")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(sections) { section in
                sectionGroup(section)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nodusGlass(NodusGlass(.thin, tint: accent), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func binding(for section: CorpusRetrieval.MaterialSection) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(section.id) },
            set: { isOpen in
                if isOpen { expanded.insert(section.id) } else { expanded.remove(section.id) }
            }
        )
    }

    private func sectionGroup(_ section: CorpusRetrieval.MaterialSection) -> some View {
        DisclosureGroup(isExpanded: binding(for: section)) {
            sectionBody(section)
        } label: {
            sectionLabel(section)
        }
        .tint(accent)
    }

    private func sectionBody(_ section: CorpusRetrieval.MaterialSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(section.rows.prefix(20).enumerated()), id: \.offset) { _, row in
                materialRow(row, kind: section.kind)
            }
            if section.rows.count > 20 {
                Text("and \(section.rows.count - 20) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 6)
    }

    private func sectionLabel(_ section: CorpusRetrieval.MaterialSection) -> some View {
        HStack(spacing: 6) {
            Image(systemName: section.icon).font(.caption2).foregroundStyle(accent)
            Text(LocalizedStringKey(section.label)).font(.caption)
            Spacer()
            Text("\(section.rows.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// Which collection a retrieved row belongs to, so it can be opened.
    private static func collection(for kind: ContextSectionKind) -> CollectionDescriptor? {
        switch kind {
        case .ideas: return Collections["ideas"]
        case .works: return Collections["works"]
        case .themes: return Collections["themes"]
        case .gaps: return Collections["gaps"]
        case .passages, .sources: return nil
        }
    }

    @ViewBuilder
    private func materialRow(_ row: Row, kind: ContextSectionKind) -> some View {
        let collection = Self.collection(for: kind)
        if kind == .sources, let token = row.string("citation"), let url = URL(string: token), let reference = CorpusReference(url) {
            NavigationLink { CorpusReferenceView(session: session, reference: reference) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.text("label") ?? "Fuente").font(.headline)
                    Text(row.text("text") ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }.frame(minHeight: 44)
            }.buttonStyle(.plain)
        } else if let collection, row.string(collection.idField) != nil {
            NavigationLink {
                RowDetailView(session: session, collection: collection, row: row)
            } label: {
                RowCell(row: row, presenter: collection.presenter, accent: accent)
            }
            .buttonStyle(.plain)
        } else {
            // A passage has no page of its own; it is read here, as the quotation it is.
            Text(row.text("text") ?? row.text("statement") ?? row.text("label") ?? "—")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle().fill(accent.opacity(0.4)).frame(width: 2)
                }
        }
    }
}
