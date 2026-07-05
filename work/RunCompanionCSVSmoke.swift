import Foundation

@main
struct RunCompanionCSVSmoke {
    static func main() throws {
        let renamedURL = URL(fileURLWithPath: "/tmp/A001_C003_RENAMED.mov")
        let metadata = ClipExportMetadata(
            duration: 8.0,
            clipName: "A001_C003_RENAMED",
            roll: "A001",
            cameraID: "A",
            startTimecode: Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 24)
        )
        let data = try DaVinciMetadataCSVExporter.makeData(rows: [
            DaVinciMetadataCSVRow(videoURL: renamedURL, metadata: metadata)
        ])

        guard data.starts(with: [0xff, 0xfe]),
              let csv = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) else {
            throw SmokeError.encoding
        }
        guard csv.contains("A001_C003_RENAMED.mov"),
              !csv.contains("qtake_A001_bottom_left_24fps.mov") else {
            throw SmokeError.fileNameMismatch(csv)
        }

        print(csv.split(separator: "\n").prefix(2).joined(separator: "\n"))
    }
}

private enum SmokeError: Error, CustomStringConvertible {
    case encoding
    case fileNameMismatch(String)

    var description: String {
        switch self {
        case .encoding:
            "Companion CSV encoding failed"
        case .fileNameMismatch(let csv):
            "Companion CSV file name mismatch:\n\(csv)"
        }
    }
}
