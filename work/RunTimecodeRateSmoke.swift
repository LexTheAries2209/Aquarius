// SPDX-License-Identifier: GPL-3.0-only

import Foundation

@main
struct RunTimecodeRateSmoke {
    static func main() throws {
        try assertEqual(
            Timecode.parse(
                "01:00:00;00",
                fps: 30,
                playbackFrameRate: SourceTimecodeFrameRateSetting.fps2997DF.playbackFrameRate,
                isDropFrame: true
            )?.totalFrames,
            107_892,
            "29.97 DF 01:00:00;00 total frame"
        )

        try assertNil(
            Timecode.parse(
                "00:01:00;00",
                fps: 30,
                playbackFrameRate: SourceTimecodeFrameRateSetting.fps2997DF.playbackFrameRate,
                isDropFrame: true
            ),
            "29.97 DF should reject dropped ;00 label at minute 01"
        )

        let firstMinuteDF = Timecode.from(
            totalFrames: 1_800,
            fps: 30,
            playbackFrameRate: SourceTimecodeFrameRateSetting.fps2997DF.playbackFrameRate,
            isDropFrame: true
        )
        try assertEqual(firstMinuteDF.description, "00:01:00;02", "29.97 DF frame 1800 label")

        let tc23976 = try unwrap(
            Timecode.parse(
                "10:00:00:00",
                fps: 24,
                playbackFrameRate: SourceTimecodeFrameRateSetting.fps23976.playbackFrameRate
            ),
            "23.976 parse"
        )
        try assertEqual(tc23976.fps, 24, "23.976 nominal fps")
        try assertEqual(
            Int((tc23976.playbackFrameRate * 1_001).rounded()),
            24_000,
            "23.976 playback rate"
        )

        let csvURL = URL(fileURLWithPath: "/tmp/A001_23976.mov")
        let metadata = ClipExportMetadata(
            duration: 10.0,
            clipName: "A001_23976",
            roll: "A001",
            cameraID: "A",
            startTimecode: tc23976
        )
        let data = try DaVinciMetadataCSVExporter.makeData(rows: [
            DaVinciMetadataCSVRow(videoURL: csvURL, metadata: metadata)
        ])
        let csv = try unwrap(
            String(data: data.dropFirst(2), encoding: .utf16LittleEndian),
            "CSV UTF-16LE decode"
        )
        guard csv.contains("00:00:10:00") else {
            throw SmokeError.mismatch("Expected 23.976 10s duration to round to 240 frames / 00:00:10:00:\n\(csv)")
        }

        print("Timecode rate smoke passed")
    }

    private static func unwrap<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else {
            throw SmokeError.mismatch("\(label) was nil")
        }
        return value
    }

    private static func assertEqual<T: Equatable>(_ actual: T?, _ expected: T, _ label: String) throws {
        guard actual == expected else {
            throw SmokeError.mismatch("\(label): expected \(expected), got \(String(describing: actual))")
        }
    }

    private static func assertNil<T>(_ value: T?, _ label: String) throws {
        guard value == nil else {
            throw SmokeError.mismatch("\(label): expected nil, got \(String(describing: value))")
        }
    }
}

private enum SmokeError: Error, CustomStringConvertible {
    case mismatch(String)

    var description: String {
        switch self {
        case .mismatch(let message):
            message
        }
    }
}
