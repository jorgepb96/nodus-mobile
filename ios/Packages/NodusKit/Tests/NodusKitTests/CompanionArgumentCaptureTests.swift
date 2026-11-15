import Foundation
import Testing
@testable import NodusKit

@Suite("Complete selected argument sources") @MainActor
struct CompanionArgumentCaptureTests {
    private var request: JSONValue { .object(["kind": .string("argument"), "seedIdeaId": .string("seed"), "language": .string("es")]) }
    private var academic: JSONValue { .object(["version": .int(1), "request": request, "revision": .string(String(repeating: "a", count: 64)),
        "source": .object(["seedIdeaId": .string("seed"), "ideas": .array([.object(["global_id": .string("seed")])]),
            "prompt": .object(["system": .string("Original"), "user": .string("Material")])])]) }
    private func map(_ stamp: String) -> JSONValue {
        .object(["generatedAt": .string(stamp), "root": .object(["id": .string(stamp), "ideaId": .string("seed"), "children": .array([
            .object(["id": .string("node-\(stamp)"), "ideaId": .string("outside"), "children": .array([])])])])])
    }
    private func read(_ method: String, _ args: [JSONValue], stamp: String = "presentation", evidence: String = "Original") -> JSONValue {
        switch method {
        case "getMobileAcademicSource": academic
        case "getMobileStructuralArgumentMap": map(stamp)
        case "getIdeaDetail": .object(["idea": .object(["global_id": args[0]]), "evidence": .array([.string(evidence)])])
        case "getIdeaEdges": .array([])
        default: .null
        }
    }
    @Test("Ideas outside the AI subset and every inspector dependency are rechecked")
    func allDetails() async throws {
        var requests: [(String, [JSONValue])] = [], mapReads = 0
        let records = try await CompanionArgumentDownload.capture(request: request, maximumBytes: 1_000_000) { method, args in
            requests.append((method, args)); if method == "getMobileStructuralArgumentMap" { mapReads += 1 }
            return read(method, args, stamp: "random-\(mapReads)")
        }
        #expect(records.count == 6); #expect(mapReads == 2)
        for id in ["outside", "seed"] { for method in ["getIdeaDetail", "getIdeaEdges"] {
            #expect(requests.filter { $0.0 == method && $0.1 == [.string(id)] }.count == 2)
        }}
        #expect(records.reduce(0) { $0 + $1.data.count } <= 1_000_000)
    }
    @Test("Evidence changes alone abort the capture even when the map and prompt remain unchanged")
    func changedEvidence() async {
        var outsideReads = 0
        await #expect(throws: APIError.self) {
            try await CompanionArgumentDownload.capture(request: request, maximumBytes: 1_000_000) { method, args in
                if method == "getIdeaDetail", args == [.string("outside")] { outsideReads += 1 }
                return read(method, args, evidence: outsideReads > 1 ? "Changed" : "Original")
            }
        }
    }
    @Test("The source and structural map both count against the selected budget")
    func budget() async {
        await #expect(throws: PrivateBridgeCache.ReadPackError.self) {
            try await CompanionArgumentDownload.capture(request: request, maximumBytes: 1) { read($0, $1) }
        }
        let first = try! JSONEncoder.nodus.encode(academic).count
        await #expect(throws: PrivateBridgeCache.ReadPackError.self) {
            try await CompanionArgumentDownload.capture(request: request, maximumBytes: first) { read($0, $1) }
        }
    }
}
