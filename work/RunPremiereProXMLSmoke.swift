// SPDX-License-Identifier: GPL-3.0-only

import Foundation

@main
struct RunPremiereProXMLSmoke {
    static func main() throws {
        let sourceURL = URL(fileURLWithPath: "/Volumes/40G4T_NTFS_D/Day02/A_0002_1COL/A_0002C001_260508_120757_p1COL.mxf")
        let metadata = ClipExportMetadata(
            duration: 3.68,
            clipName: "A_0002C001_260508_120757_p1COL",
            roll: "A_0002_1COL",
            cameraID: "A",
            startTimecode: Timecode(hours: 12, minutes: 8, seconds: 47, frames: 23, fps: 25)
        )

        let data = try PremiereProXMLExporter.makeData(rows: [
            PremiereProXMLRow(videoURL: sourceURL, metadata: metadata)
        ])

        guard let xml = String(data: data, encoding: .utf8) else {
            throw SmokeError.encoding
        }

        try expect(xml.contains("<!DOCTYPE xmeml>"), "missing xmeml doctype")
        try expect(xml.contains("<xmeml version=\"4\">"), "missing xmeml version")
        try expect(xml.contains("<name>A_0002_1COL</name>"), "missing roll bin name")
        try expect(xml.contains("<pathurl>file:///Volumes/40G4T_NTFS_D/Day02/A_0002_1COL/A_0002C001_260508_120757_p1COL.mxf</pathurl>"), "missing source pathurl")
        try expect(xml.contains("<frame>1093198</frame>"), "missing source timecode frame")
        try expect(xml.contains("<displayformat>NDF</displayformat>"), "missing NDF display format")
        try expect(xml.contains("<cameraroll>A_0002_1COL</cameraroll>"), "missing camera roll")

        print(xml.split(separator: "\n").prefix(12).joined(separator: "\n"))
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
                "Premiere XML encoding failed"
            case .mismatch(let message):
                "Premiere XML mismatch: \(message)"
            }
        }
    }
}
