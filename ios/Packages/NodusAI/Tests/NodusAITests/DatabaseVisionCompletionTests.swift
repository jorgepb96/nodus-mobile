import Foundation
import Testing
@testable import NodusAI

@Suite("Database downloaded vision transport") struct DatabaseVisionCompletionTests {
    @Test func compatibleRequestSendsActualTwoImagesAndSelectedModel()throws {
        let images=[DatabaseVisionCompletion.Image(data:Data([1,2,3]),mime:"image/png"),.init(data:Data([4,5,6]),mime:"image/jpeg")]
        let request=try DatabaseVisionCompletion.request(model:.init(provider:.gemini,model:"device-vision"),system:"Canonical system",prompt:"Canonical row prompt",images:images,key:"fixture")
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        let bytes=try #require(request.httpBody)
        let object=try JSONSerialization.jsonObject(with:bytes)
        let body=try #require(object as? [String:Any])
        #expect(body["model"] as? String == "device-vision")
        let messages=try #require(body["messages"] as? [[String:Any]]),parts=try #require(messages.last?["content"] as? [[String:Any]])
        #expect(parts.count==3)
        #expect((parts[1]["image_url"] as? [String:Any])?["url"] as? String == "data:image/png;base64,AQID")
        #expect((parts[2]["image_url"] as? [String:Any])?["url"] as? String == "data:image/jpeg;base64,BAUG")
        #expect(body["max_tokens"] as? Int == 1200)
        #expect(body["stream"] == nil)
    }
    @Test func anthropicUsesBinaryPartsAndRejectsThreeImages()throws {
        let image=DatabaseVisionCompletion.Image(data:Data([7]),mime:"image/webp")
        let request=try DatabaseVisionCompletion.request(model:.init(provider:.anthropic,model:"device-vision"),system:"Canonical system",prompt:"Row",images:[image],key:"fixture")
        let bytes=try #require(request.httpBody)
        let object=try JSONSerialization.jsonObject(with:bytes)
        let body=try #require(object as? [String:Any])
        let messages=try #require(body["messages"] as? [[String:Any]]),parts=try #require(messages.first?["content"] as? [[String:Any]])
        #expect((parts[1]["source"] as? [String:Any])?["data"] as? String == "Bw==")
        #expect(body["system"] as? String == "Canonical system")
        #expect(throws:ProviderError.self){try DatabaseVisionCompletion.request(model:.init(provider:.openai,model:"v"),system:"s",prompt:"p",images:[image,image,image],key:"fixture")}
    }
    @Test func truncatedAndMalformedResponsesRemainFailures()throws {
        let model=ModelRef(provider:.openai,model:"device-vision")
        #expect(throws:ProviderError.self){try DatabaseVisionCompletion.response(Data(#"{"choices":[{"finish_reason":"length","message":{"content":"partial"}}]}"#.utf8),model:model)}
        #expect(throws:ProviderError.self){try DatabaseVisionCompletion.response(Data(#"{"choices":[]}"#.utf8),model:model)}
        #expect(try DatabaseVisionCompletion.response(Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"Actual response"}}]}"#.utf8),model:model)=="Actual response")
    }
}
