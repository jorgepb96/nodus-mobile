import Foundation
import NodusAI
import NodusKit
import Testing
@testable import Nodus

/// The report chat's one hard rule: a number a reader can tap has to point at a paragraph that
/// exists. The model is asked for that in the prompt; these are what make it true.
@Suite("Report chat")
struct PageChatTests {
    @Test("Mac payload keeps eight turns and page instructions without mobile model selection")
    @MainActor func macPayload() throws {
        let history=(0..<10).map { JSONValue.object(["role":.string("user"),"content":.string("turn-\($0)")]) }
        let prompt=PageChatPrompt.system(language:"es")+"\n[1] Texto del informe"
        let value=PageChatLiveWire.payload(history:history,prompt:prompt,selection:NativeLiveChatOptions.defaultSelection)
        let object=try #require(value.objectValue),messages=try #require(object["messages"]?.arrayValue)
        #expect(messages.count == 9)
        #expect(messages.first?.objectValue?["content"] == .string("turn-2"))
        #expect(messages.last?.objectValue?["content"] == .string(prompt))
        #expect(messages.allSatisfy{$0.objectValue?["role"] != .string("system")})
        #expect(object["model"] == nil && object["systemPromptId"] == nil)
        #expect(object["webSearch"] == .string("off"))
        #expect(object["selection"]?.objectValue?["documents"] == .bool(true))
    }
    @Test("Mac cursor replays do not append duplicate text and replace is authoritative")
    @MainActor func macEventReplay() throws {
        let id=UUID().uuidString
        func event(_ sequence:Int,_ channel:String,_ request:String,_ text:String)throws->DesktopBridgeJob.Event {
            try JSONDecoder.nodus.decode(DesktopBridgeJob.Event.self,from:JSONEncoder.nodus.encode(JSONValue.object(["sequence":.int(Int64(sequence)),"channel":.string(channel),"args":.array([.string(request),.string(text)])])))
        }
        var stream=PageChatLiveWire.Stream()
        let first=try event(1,"research:chatStream:delta",id,"Texto ")
        stream.apply(first,requestId:id);stream.apply(first,requestId:id)
        stream.apply(try event(2,"research:chatStream:delta",id,"parcial"),requestId:id)
        #expect(stream.text == "Texto parcial")
        stream.apply(try event(3,"research:chatStream:replace",id,"Texto validado [1]"),requestId:id)
        stream.apply(try event(4,"research:chatStream:delta",UUID().uuidString,"ajeno"),requestId:id)
        #expect(stream.text == "Texto validado [1]")
        #expect(stream.sequence == 4)
    }

    @Test("cancel reuses the complete stream request identity before any late submission")
    @MainActor func macCancelWire() async throws {
        let id=UUID().uuidString,args:[JSONValue]=[.string(id),PageChatLiveWire.payload(history:[],prompt:"[1] source",selection:NativeLiveChatOptions.defaultSelection)]
        let cancelled=try JSONDecoder.nodus.decode(DesktopBridgeJob.self,from:JSONEncoder.nodus.encode(JSONValue.object(["id":.string(UUID().uuidString),"vaultId":.string("fixture"),"method":.string("researchChatStream"),"state":.string("cancelled"),"nextSequence":.int(0),"events":.array([]),"result":.null])))
        var sent:[[JSONValue]]=[]
        for _ in 0..<2 {
            _=try await PageChatLiveWire.cancelRequest(vaultId:"fixture",args:args,id:id) { vault,method,actual,key in
                #expect(vault == "fixture" && method == "researchChatStream" && key == id)
                sent.append(actual);return cancelled
            }
        }
        #expect(sent == [args,args], "Lost acknowledgement retries retain the same body and tombstone identity")
        do {
            _=try await PageChatLiveWire.cancelRequest(vaultId:"fixture",args:args,id:UUID().uuidString) { _,_,_,_ in
                Issue.record("A different request must never be canceled");return cancelled
            }
            Issue.record("Expected the mismatched identity to reject")
        } catch {}
    }
    @Test("missing Mac preflight leaves the page question and quotation untouched")
    @MainActor func macPreflightKeepsDraft() throws {
        let root=URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let connection=AppModel.Connection(origin:"https://page-chat-preflight.test",spaceId:UUID().uuidString,spaceName:"Fixture",serverName:"Mac",role:.owner)
        let session=SpaceSession(connection:connection,client:NodusClient(address:ServerAddress(trusted:connection.origin),token:"fixture",cache:ResponseCache(directory:root)),mirrorDirectory:root)
        defer {UserDefaults.standard.removeObject(forKey:"ai-execution-mode:\(connection.id)")}
        let id=UUID().uuidString,subject=PageChatSubject(id:id,title:"Fixture",session:session)
        let store=PageChatStore.shared(for:subject.storeKey)
        defer {PageChatStore.forget(subject.storeKey)}
        store.draft="Pregunta conservada";store.quote("Cita conservada")
        store.ask(store.draft,passages:[],subject:subject,ai:AISettings())
        #expect(store.draft == "Pregunta conservada" && store.quoted == "Cita conservada")
        #expect(store.turns.isEmpty && !store.isThinking && !store.canResumeMac)
        #expect(store.failure == BetaAIFeatures.macRequiredMessage)
    }
    @Test("Mac corpus citations survive without a matching local catalog while invalid page anchors are removed")
    func macCitationsRemainAuthoritative() {
        let text = "Mac evidence (nodus://idea/mac-only-source), page [1] and [999]."
        let local = CitationCatalog(entries: [])
        #expect(!CitationValidator.validate(prose: text, against: local).rejected.isEmpty)
        let answer = PageChatLiveWire.validatedMacAnswer(text, passageCount: 2)
        #expect(answer.contains("nodus://idea/mac-only-source"))
        #expect(answer.contains("[1]"))
        #expect(!answer.contains("[999]"))
    }

    @Test("conversation keys separate owning storage and report identities without delimiter collisions")
    func conversationScopeKeys() {
        let a = PageChatSubject.storeKey(storageId: "vault-a", reportId: "same-report")
        #expect(a != PageChatSubject.storeKey(storageId: "vault-b", reportId: "same-report"))
        #expect(a != PageChatSubject.storeKey(storageId: "vault-a", reportId: "other-report"))
        #expect(PageChatSubject.storeKey(storageId: "a:b", reportId: "c") != PageChatSubject.storeKey(storageId: "a", reportId: "b:c"))
        #expect(a == PageChatSubject.storeKey(storageId: "vault-a", reportId: "same-report"))
    }

    @Test("the passages an answer cites come back in the order they were used")
    func referencedInOrder() {
        let prose = "It says so in [3], and again in [1]. Also [3] once more."
        #expect(PageChatPrompt.referenced(in: prose, count: 5) == [3, 1])
    }

    /// A model that cites passage 40 of a nine-passage report has invented a door. It is taken
    /// out rather than drawn, which is the same bargain `CitationValidator` strikes with corpus
    /// tokens: the prompt gets it right most of the time, this makes it true.
    @Test("a number the document does not have is struck out")
    func unknownReferencesGo() {
        let prose = "As [2] argues, unlike [40]."
        let cleaned = PageChatPrompt.dropUnknownReferences(prose, count: 9)
        #expect(cleaned == "As [2] argues, unlike .")
        #expect(PageChatPrompt.referenced(in: cleaned, count: 9) == [2])
    }

    @Test("a reference becomes a link the prose can hand back on tap")
    func linkified() {
        let linked = PageChatPrompt.linkifyReferences("See [2].", count: 4)
        #expect(linked == "See [2](nodusref://2).")
        let url = try? #require(URL(string: "nodusref://2"))
        #expect(PageChatReference.number(in: url ?? URL(fileURLWithPath: "/")) == 2)
    }

    /// The prose also carries `[label](nodus://idea/g-1)` citations, and a Markdown link opens
    /// with the same bracket. Turning one of those into a reference would break every corpus
    /// citation in the answer.
    @Test("a corpus citation is not mistaken for a passage number")
    func markdownLinksSurvive() {
        let prose = "[Arco Blanco (2020)](nodus://idea/g-8969) and [2] agree."
        let linked = PageChatPrompt.linkifyReferences(prose, count: 3)
        #expect(linked.contains("[Arco Blanco (2020)](nodus://idea/g-8969)"))
        #expect(linked.contains("[2](nodusref://2)"))
        #expect(PageChatPrompt.dropUnknownReferences(prose, count: 3) == prose)
    }

    @Test("a link that is not a reference is not read as one")
    func otherSchemes() throws {
        let idea = try #require(URL(string: "nodus://idea/g-8969"))
        #expect(PageChatReference.number(in: idea) == nil)
        let malformed = try #require(URL(string: "nodusref://north"))
        #expect(PageChatReference.number(in: malformed) == nil)
    }

    /// The document goes into the payload numbered and in reading order — that is the whole
    /// contract between what the model is shown and what a tap can reach.
    @Test("the document reaches the model numbered, in reading order, under its budget")
    func questionCarriesTheDocument() {
        let passages = [
            PageChatPassage(number: 1, path: [0], text: "The registers open in 1876."),
            PageChatPassage(number: 2, path: [1, 0], text: "The correspondence disagrees."),
        ]
        let prompt = PageChatPrompt.question(
            "What do they disagree about?",
            title: "The parish registers",
            passages: passages,
            catalog: CitationCatalog(entries: [])
        )
        #expect(prompt.contains("[1] The registers open in 1876."))
        #expect(prompt.contains("[2] The correspondence disagrees."))
        let first = try? #require(prompt.range(of: "[1] The"))
        let second = try? #require(prompt.range(of: "[2] The"))
        if let first, let second { #expect(first.lowerBound < second.lowerBound) }
    }

    @Test("a document past the budget is cut, and the cut is admitted")
    func budgetIsHonest() {
        let passages = (1...50).map {
            PageChatPassage(number: $0, path: [$0], text: String(repeating: "palabra ", count: 40))
        }
        let prompt = PageChatPrompt.question(
            "…", title: "Long", passages: passages, catalog: CitationCatalog(entries: []), budget: 1_000
        )
        #expect(prompt.contains("El documento continúa"))
        #expect(!prompt.contains("[50]"))
    }

    @MainActor
    @Test("revealing a passage scrolls to it and marks it, and only if it is on the page")
    func revealing() {
        let search = PageSearch()
        search.register([2], text: "A paragraph long enough to be a passage worth citing.")
        search.register([1], text: "An earlier paragraph, also long enough to be worth citing.")

        // Numbered in reading order, not in registration order.
        #expect(search.passages().map(\.path) == [[1], [2]])

        search.reveal([2])
        #expect(search.revealed == [2])
        #expect(search.scrollTarget?.path == [2])

        // A path the page never registered points nowhere, and says so by doing nothing.
        search.reveal([9])
        #expect(search.revealed == [2])
    }

    @MainActor
    @Test("a label too short to be a passage is not offered as one")
    func shortEntriesAreNotPassages() {
        let search = PageSearch()
        search.register([0], text: "Sources")
        search.register([1], text: "A paragraph long enough to be worth pointing at by number.")
        #expect(search.passages().map(\.path) == [[1]])
    }

    /// The conversation belongs to the report, and to that report alone.
    @MainActor
    @Test("each report has its own conversation, and closing it forgets it")
    func storesAreKeyedByReport() {
        let first = PageChatStore.shared(for: "report-a")
        #expect(PageChatStore.shared(for: "report-a") === first)
        #expect(PageChatStore.shared(for: "report-b") !== first)

        first.draft = "half-written"
        PageChatStore.forget("report-a")
        #expect(PageChatStore.shared(for: "report-a").draft.isEmpty)
    }
}
