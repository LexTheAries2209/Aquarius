// SPDX-License-Identifier: GPL-3.0-only

import Foundation

@main
struct RunFinalCutXMLSmoke {
    static func main() throws {
        let sourceURL = URL(fileURLWithPath: "/Volumes/40G4T_NTFS_D/Day02/A_0002_1COL/A_0002C001_260508_120757_p1COL.mxf")
        let metadata = ClipExportMetadata(
            duration: 3.68,
            clipName: "A_0002C001_260508_120757_p1COL",
            roll: "A_0002_1COL",
            cameraID: "A",
            startTimecode: Timecode(hours: 12, minutes: 8, seconds: 47, frames: 23, fps: 25)
        )
        let row = FinalCutMetadataXMLRow(videoURL: sourceURL, metadata: metadata)

        let fcp7XML = try decode(try FinalCutPro7XMLExporter.makeData(rows: [row]))
        try expect(fcp7XML.contains("<!DOCTYPE xmeml>"), "missing FCP7 xmeml doctype")
        try expect(fcp7XML.contains("<xmeml version=\"4\">"), "missing FCP7 xmeml version")
        try expect(fcp7XML.contains("<updatebehavior>add</updatebehavior>"), "missing FCP7 update behavior")
        try expect(fcp7XML.contains("<pathurl>file:///Volumes/40G4T_NTFS_D/Day02/A_0002_1COL/A_0002C001_260508_120757_p1COL.mxf</pathurl>"), "missing FCP7 pathurl")
        try expect(fcp7XML.contains("<frame>1093198</frame>"), "missing FCP7 source timecode frame")
        try expect(fcp7XML.contains("<displayformat>NDF</displayformat>"), "missing FCP7 display format")
        try expect(fcp7XML.contains("<reel>") && fcp7XML.contains("<name>A_0002_1COL</name>"), "missing FCP7 reel")

        let fcpXML = try decode(try FinalCutProXMLExporter.makeData(rows: [row]))
        try expect(fcpXML.contains("<!DOCTYPE fcpxml>"), "missing FCPXML doctype")
        try expect(fcpXML.contains("<fcpxml version=\"1.9\">"), "missing FCPXML version")
        try expect(fcpXML.contains("<asset id=\"r1\" name=\"A_0002C001_260508_120757_p1COL\" format=\"f1\" hasVideo=\"1\" duration=\"92/25s\" start=\"1093198/25s\">"), "missing FCPXML asset timing")
        try expect(fcpXML.contains("<media-rep kind=\"original-media\" src=\"file:///Volumes/40G4T_NTFS_D/Day02/A_0002_1COL/A_0002C001_260508_120757_p1COL.mxf\"/>"), "missing FCPXML media-rep")
        try expect(fcpXML.contains("<md key=\"com.apple.proapps.studio.reel\" value=\"A_0002_1COL\"/>"), "missing FCPXML reel metadata")
        try expect(fcpXML.contains("<md key=\"com.apple.proapps.mio.cameraName\" value=\"A\"/>"), "missing FCPXML camera metadata")

        print(fcp7XML.split(separator: "\n").prefix(8).joined(separator: "\n"))
        print("---")
        print(fcpXML.split(separator: "\n").prefix(12).joined(separator: "\n"))
    }

    private static func decode(_ data: Data) throws -> String {
        guard let xml = String(data: data, encoding: .utf8) else {
            throw SmokeError.encoding
        }
        return xml
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw SmokeError.mismatch(message)
        }
    }

    enum SmokeError: LocalizedError {
        case encoding
        case mismatch(String)

        var errorDescription: String? {
            switch self {
            case .encoding:
                "Final Cut XML encoding failed"
            case .mismatch(let message):
                "Final Cut XML mismatch: \(message)"
            }
        }
    }
}
