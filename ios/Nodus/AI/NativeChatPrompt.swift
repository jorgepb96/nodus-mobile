import Foundation
import NodusAI

enum NativeChatPrompt {
    struct Context {
        let messages: [ChatMessage]
        let omittedTurns: Int
    }
    static func make(history: [ChatMessage],system: String,question: String,citations: String,maxHistoryBytes: Int = 200_000) -> Context {
        let eligible = history.filter { $0.role != .system && !$0.content.isEmpty }
        var kept: [ChatMessage] = [],used = 0
        for message in eligible.reversed() {
            let size = message.content.utf8.count
            guard kept.count < 32,size <= max(0,maxHistoryBytes - used) else { break }
            kept.append(message);used += size
        }
        kept.reverse()
        while kept.first?.role == .assistant { kept.removeFirst() }
        return .init(messages:[.init(role:.system,content:system)] + kept + [.init(role:.user,content:"\(question)\n\n\(citations)")],omittedTurns:eligible.count - kept.count)
    }
}
