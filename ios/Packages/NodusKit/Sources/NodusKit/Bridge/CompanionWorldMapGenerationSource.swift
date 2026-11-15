import Foundation

/// Prompts are built by the canonical Desktop builder when this source is
/// captured. Extra direction is inserted at that builder's exact position.
public struct CompanionWorldMapGenerationSource: Sendable {
    public let value: JSONValue
    public let mapId: String
    public let revision: String
    public let imageSource: String?
    public let style: String
    private let placeholder: String
    private let prompts: [String: JSONValue]
    public init(_ value: JSONValue, mapId: String) throws {
        guard let object = value.objectValue, object["version"] == .int(1), object["mapId"] == .string(mapId),
              !mapId.isEmpty, let revision = object["revision"]?.stringValue, revision.count == 64,
              revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let style = object["style"]?.stringValue, Self.styles.contains(style),
              let placeholder = object["placeholder"]?.stringValue, placeholder == "NODUS_MAP_EXTRA_DIRECTION_3DC849",
              let prompts = object["prompts"]?.objectValue, prompts.count == 70,
              try JSONEncoder.nodus.encode(value).count <= 1_000_000 else { throw DesktopBridgeError.malformedResponse }
        for (key, prompt) in prompts {
            let parts = key.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, Self.styles.contains(String(parts[1])),
                  ["create","restyle","variant","expand"].contains(String(parts[0])),
                  (parts[0] == "expand" ? ["north","south","east","west"].contains(String(parts[2])) : parts[2].isEmpty),
                  let text = prompt.stringValue, text.count <= 12_000,
                  text.components(separatedBy: placeholder).count == 2 else { throw DesktopBridgeError.malformedResponse }
        }
        let imageSource = object["imageSource"]?.stringValue
        if let imageSource { guard CompanionCorpusImage.validSource(imageSource), URL(string: imageSource)?.host == "map" else { throw DesktopBridgeError.malformedResponse } }
        else { guard object["imageSource"] == .null else { throw DesktopBridgeError.malformedResponse } }
        self.value = value; self.mapId = mapId; self.revision = revision; self.imageSource = imageSource
        self.style = style; self.placeholder = placeholder; self.prompts = prompts
    }
    public static let styles = ["parchment","inked_atlas","painted_fantasy","watercolour","satellite","blueprint","isometric","hand_drawn","dark_grimoire","nautical_chart"]
    public func prompt(request: JSONValue) throws -> String {
        guard let request = request.objectValue, request["mapId"] == .string(mapId), let mode = request["mode"]?.stringValue,
              let extra = request["extra"]?.stringValue, extra.utf16.count <= 300,
              Set(request.keys).isSubset(of: ["mapId","mode","style","extra","edge","fraction"]) else { throw DesktopBridgeError.malformedResponse }
        let selectedStyle = mode == "expand" ? style : request["style"]?.stringValue ?? style
        let edge = mode == "expand" ? request["edge"]?.stringValue ?? "north" : ""
        if mode == "expand" { guard request["style"] == nil, let fraction = request["fraction"]?.doubleValue, fraction.isFinite, fraction > 0, fraction <= 2 else { throw DesktopBridgeError.malformedResponse } }
        else { guard request["edge"] == nil, request["fraction"] == nil else { throw DesktopBridgeError.malformedResponse } }
        guard let template = prompts["\(mode):\(selectedStyle):\(edge)"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
        let cleaned = extra.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return template.replacingOccurrences(of: placeholder, with: cleaned).replacingOccurrences(of: "  ", with: " ")
    }
}
