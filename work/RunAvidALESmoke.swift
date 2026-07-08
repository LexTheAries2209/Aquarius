// SPDX-License-Identifier: GPL-3.0-only

import Foundation

@main
struct RunAvidALESmoke {
    static func main() throws {
        let sourceURL = URL(fileURLWithPath: "/Volumes/40G4T_NTFS_D/Day02/A_0002_1COL/A_0002C001_260508_120757_p1COL.mxf")
        let metadata = ClipExportMetadata(
            duration: 3.68,
            clipName: "A_0002C001_260508_120757_p1COL",
            roll: "A_0002_1COL",
            cameraID: "A",
            startTimecode: Timecode(hours: 12, minutes: 8, seconds: 7, frames: 23, fps: 25)
        )

        let data = try AvidALEExporter.makeData(rows: [
            AvidALERow(videoURL: sourceURL, metadata: metadata)
        ])

        guard let ale = String(data: data, encoding: .utf8) else {
            throw SmokeError.encoding
        }

        try expect(ale.contains("Heading\n"), "missing Heading section")
        try expect(ale.contains("FIELD_DELIM\tTABS\n"), "missing tab delimiter heading")
        try expect(ale.contains("VIDEO_FORMAT\tPAL\n"), "missing PAL video format")
        try expect(ale.contains("FPS\t25\n"), "missing FPS heading")
        try expect(ale.contains("Column\n"), "missing Column section")
        try expect(ale.contains("Data\n"), "missing Data section")
        try expect(ale.contains("Name\tStart\tEnd\tDuration\tFPS\tFrame count"), "missing core columns")
        try expect(ale.contains("A_0002C001_260508_120757_p1COL\t12:08:07:23\t12:08:11:15\t00:00:03:17\t25\t92"), "missing timecode row values")
        try expect(ale.contains("A_0002_1COL\tA_0002_1COL\tA\tA_0002C001_260508_120757_p1COL.mxf"), "missing reel/camera/source values")
        try expect(ale.contains("/Volumes/40G4T_NTFS_D/Day02/A_0002_1COL/A_0002C001_260508_120757_p1COL.mxf\tmxf"), "missing path/filetype values")

        print(ale.split(separator: "\n").prefix(8).joined(separator: "\n"))
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
                "Avid ALE encoding failed"
            case .mismatch(let message):
                "Avid ALE mismatch: \(message)"
            }
        }
    }
}
