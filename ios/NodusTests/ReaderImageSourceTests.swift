import Foundation
import Testing
import NodusKit
@testable import Nodus

@Suite("Native reader image identity and transport")
@MainActor
struct ReaderImageSourceTests {
    @Test("Internal and inline image identities survive Unicode labels; code examples never fetch")
    func imageReferences() {
        let source = "nodus-image://world/fixture?v=revision"
        let text = """
        Texto ![Mapa 🌊](\(source)) y otra imagen ![Foto](<nodus-library://attachment/document/asset> "Fuente").
        ![Repetida](\(source))
        `![Código](https://example.invalid/inline.png)`
        ```markdown
        ![Ejemplo](https://example.invalid/fenced.png)
        ```
            ![Indentado](https://example.invalid/indented.png)
        \\![Escapado](https://example.invalid/escaped.png)
        """
        let values = ReaderImageSource.references(in:text)
        #expect(values.count == 2)
        #expect(values[0].source == source);#expect(values[0].alternative == "Mapa 🌊")
        #expect(values[1].source == "nodus-library://attachment/document/asset")
        #expect(values.map(\.id) == ReaderImageSource.references(in:text).map(\.id))
    }
    @Test("Authored image bytes are exact and unsupported or insecure URLs are rejected")
    func dataImages() async throws {
        let bytes = Data([0,1,2,255]),source = "data:image/png;base64," + bytes.base64EncodedString()
        let loaded = try await ReaderImageSource.load(source,session:nil)
        #expect(loaded.data == bytes);#expect(loaded.mime == "image/png")
        for value in ["file:///private/fixture.png","http://example.invalid/photo.png","data:text/html;base64,\(bytes.base64EncodedString())","data:image/png;base64,broken!"] {
            await #expect(throws:(any Error).self) { try await ReaderImageSource.load(value,session:nil) }
        }
    }
    @Test("HTML figures share the Markdown identity and literal code never becomes a resource")
    func htmlFigures() {
        let text = """
        <img alt='Mapa &quot;local&quot;' src="https://example.invalid/figure.png?a=1&amp;b=2" width="200">
        <IMG SRC='nodus-library://attachment/document/asset' ALT='Archivo'>
        ![Duplicada](nodus-library://attachment/document/asset)
        `<img src="https://example.invalid/inline.png">`
        ~~~html
        <img src="https://example.invalid/fenced.png">
        ~~~
            <img src="https://example.invalid/indented.png">
        """
        let values = ReaderImageSource.references(in: text)
        #expect(values.count == 2)
        #expect(values.first(where: { $0.source.hasPrefix("https") })?.source == "https://example.invalid/figure.png?a=1&b=2")
        #expect(values.first(where: { $0.source.hasPrefix("https") })?.alternative == "Mapa \"local\"")
        #expect(values.contains(where: { $0.source == "nodus-library://attachment/document/asset" }))
    }
    @Test("Private image identities cannot bypass their owning paired vault")
    func privateImagesNeedGrant() async {
        for value in ["nodus-image://world/fixture","nodus-library://original/fixture","nodus-archive://file/fixture"] {
            await #expect(throws:DesktopBridgeError.permissionDenied) { try await ReaderImageSource.load(value,session:nil) }
        }
    }
}
