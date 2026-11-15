import Foundation

/// Validate the saved Mac result before attaching its bytes to a device report.
public enum CompanionReportImage {
    public static func bytes(metadata: JSONValue, dataURL: JSONValue, reportId: String) throws -> (data: Data, mime: String) {
        guard let row = metadata.objectValue, row["entityKind"] == .string("deep_research"),
              row["entityId"] == .string(reportId), row["status"] == .string("ready"),
              let url = dataURL.stringValue, url.utf8.count <= 28_000_000,
              let comma = url.firstIndex(of: ",") else { throw DesktopBridgeError.malformedResponse }
        let header = String(url[..<comma])
        let mime: String
        switch header {
        case "data:image/png;base64": mime = "image/png"
        case "data:image/jpeg;base64": mime = "image/jpeg"
        case "data:image/webp;base64": mime = "image/webp"
        default: throw DesktopBridgeError.malformedResponse
        }
        guard let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
              !data.isEmpty, data.count <= 20_000_000 else { throw DesktopBridgeError.malformedResponse }
        return (data, mime)
    }
}
