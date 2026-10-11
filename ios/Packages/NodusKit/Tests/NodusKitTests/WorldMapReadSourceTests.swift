import Foundation
import Testing
@testable import NodusKit

@Suite("Atlas read source ownership")
struct WorldMapReadSourceTests {
    private var source: [String: JSONValue] {
        ["version": .int(1), "vaultId": .string("vault-a"),
         "map": .object(["mapId": .string("map-a"), "imageId": .string("image-a"), "widthPx": .int(1600), "heightPx": .int(800)]),
         "ancestry": .array([.object(["mapId": .string("map-a")]), .object(["mapId": .string("root")])]),
         "children": .array([.object(["mapId": .string("child"), "parentMapId": .string("map-a")])]),
         "layers": .array([.object(["layerId": .string("layer-a"), "mapId": .string("map-a"), "visible": .bool(false)])]),
         "markers": .array([.object(["markerId": .string("marker-a"), "mapId": .string("map-a"), "layerId": .string("layer-a"), "x": .double(0.25), "y": .double(0.5), "geometryKind": .string("point")])]),
         "scenes": .array([]), "presences": .array([]), "travelModes": .array([]), "calendar": .object(["eras": .array([]), "months": .array([])])]
    }
    @Test("The map owns its original image and nearest-first ancestry")
    func originalIdentity() throws {
        let value = try WorldMapReadSource(.object(source), vault: "vault-a", mapId: "map-a")
        #expect(value.imageSource == "nodus-image://map/image-a")
        #expect(value.ancestry.first?.string("mapId") == "map-a")
        #expect(value.layers.first?.bool("visible") == false)
    }
    @Test("An unillustrated map keeps Desktop's empty-image canvas")
    func emptyImage() throws {
        var value = source
        value["map"] = .object(["mapId": .string("map-a"), "imageId": .null, "widthPx": .int(0), "heightPx": .int(0)])
        #expect(try WorldMapReadSource(.object(value), vault: "vault-a", mapId: "map-a").imageSource == nil)
    }
    @Test("Foreign vault, map, child, layer and marker identities fail before rendering")
    func ownership() throws {
        #expect(throws: DesktopBridgeError.self) { try WorldMapReadSource(.object(source), vault: "vault-b", mapId: "map-a") }
        #expect(throws: DesktopBridgeError.self) { try WorldMapReadSource(.object(source), vault: "vault-a", mapId: "map-b") }
        for key in ["children", "layers", "markers"] {
            var foreign = source
            var record = try #require(foreign[key]?.arrayValue?.first?.objectValue)
            record[key == "children" ? "parentMapId" : "mapId"] = .string("map-b")
            foreign[key] = .array([.object(record)])
            #expect(throws: DesktopBridgeError.self) { try WorldMapReadSource(.object(foreign), vault: "vault-a", mapId: "map-a") }
        }
    }
}
