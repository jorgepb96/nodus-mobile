import Foundation
import WebKit

/// A shared mobile typography/citation layer for the retained Desktop reader and rich prose.
enum LinkReaderPresentation {
    static func install(in configuration: WKWebViewConfiguration) {
        guard let url = Bundle.main.url(forResource: "link-presentation", withExtension: "css"),
              let css = try? String(contentsOf: url, encoding: .utf8),
              let bytes = try? JSONEncoder().encode(css), let literal = String(data: bytes, encoding: .utf8) else { return }
        let source = """
        (() => {
          const style = document.createElement('style');
          style.id = 'nodus-link-presentation'; style.textContent = \(literal);
          document.head.appendChild(style);
          document.documentElement.lang = \(languageLiteral);
        })();
        """
        configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }
    private static var languageLiteral: String {
        let language = Locale.preferredLanguages.first ?? "en"
        guard let data = try? JSONEncoder().encode(language), let literal = String(data: data, encoding: .utf8) else { return "\"en\"" }
        return literal
    }
}
