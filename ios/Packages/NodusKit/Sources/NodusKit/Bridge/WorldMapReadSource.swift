import Foundation

/// Real Desktop map DTOs. A cached map cannot borrow another vault, map's
/// layers, or marker identity when the devices reconnect.
public struct WorldMapReadSource: Sendable {
    public let value: JSONValue
    public let map: Row
    public let layers: [Row]
    public let markers: [Row]
    public let scenes: [Row]
    public let presences: [Row]
    public let ancestry: [Row]
    public let children: [Row]
    public var imageSource: String? {
        guard let id = map.string("imageId"), !id.isEmpty else { return nil }
        var url = URLComponents(); url.scheme = "nodus-image"; url.host = "map"; url.path = "/" + id
        return url.url?.absoluteString
    }

    public init(_ value: JSONValue, vault: String, mapId: String) throws {
        guard let object = value.objectValue, object["version"] == .int(1), object["vaultId"] == .string(vault),
              let map = object["map"]?.objectValue, map["mapId"] == .string(mapId), !mapId.isEmpty,
              let width = Row(map).double("widthPx"), width.isFinite, width >= 0,
              let height = Row(map).double("heightPx"), height.isFinite, height >= 0,
              map["imageId"] == .null || map["imageId"] == nil || (width > 0 && height > 0),
              try JSONEncoder.nodus.encode(value).count <= 16 * 1024 * 1024 else { throw DesktopBridgeError.malformedResponse }
        func rows(_ key: String, _ idField: String?) throws -> [Row] {
            guard let values = object[key]?.arrayValue, values.allSatisfy({ $0.objectValue != nil }) else { throw DesktopBridgeError.malformedResponse }
            let rows = values.map { Row($0.objectValue!) }
            if let idField {
                let ids = rows.compactMap { $0.string(idField) }
                guard ids.count == rows.count, ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == rows.count else { throw DesktopBridgeError.malformedResponse }
            }
            return rows
        }
        let layers = try rows("layers", "layerId"), markers = try rows("markers", "markerId")
        let layerIds = Set(layers.compactMap { $0.string("layerId") })
        guard layers.allSatisfy({ $0.string("mapId") == mapId && $0.bool("visible") != nil }),
              markers.allSatisfy({ marker in
                  guard marker.string("mapId") == mapId, let x = marker.double("x"), let y = marker.double("y"),
                        x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
                        ["point", "circle", "polygon", "path"].contains(marker.string("geometryKind") ?? "") else { return false }
                  return marker.string("layerId").map { layerIds.contains($0) } ?? true
              }), object["calendar"]?.objectValue?["eras"]?.arrayValue != nil,
              object["calendar"]?.objectValue?["months"]?.arrayValue != nil else { throw DesktopBridgeError.malformedResponse }
        let ancestry = try rows("ancestry", "mapId"), children = try rows("children", "mapId")
        guard ancestry.first?.string("mapId") == mapId, children.allSatisfy({ $0.string("parentMapId") == mapId }) else { throw DesktopBridgeError.malformedResponse }
        self.scenes = try rows("scenes", "sceneId")
        self.presences = try rows("presences", nil)
        _ = try rows("travelModes", "modeId")
        self.value = value; self.map = Row(map); self.layers = layers; self.markers = markers; self.ancestry = ancestry; self.children = children
    }
    public static func validate(_ value: JSONValue, vault: String, mapId: String) throws { _ = try Self(value, vault: vault, mapId: mapId) }
}
