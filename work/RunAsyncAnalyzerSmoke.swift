// SPDX-License-Identifier: GPL-3.0-only

import Foundation

private struct SmokeCase {
    let fileName: String
    let regions: [OCRRegion]
}

@main
struct RunAsyncAnalyzerSmoke {
    static func main() async throws {
        let samplesDirectory = URL(fileURLWithPath: "/Users/lex./Desktop/XcodeProjects/OCRTimecode/OCRTimecode/Samples", isDirectory: true)
        let cases = [
            SmokeCase(
                fileName: "qtake_A001_bottom_left_24fps.mov",
                regions: OCRRegion.qtakeLowerLeftPreset
            ),
            SmokeCase(
                fileName: "qtake_B014_upper_right_25fps.mov",
                regions: [
                    OCRRegion(id: "clip-name", label: "文件名", kind: .clipName, normalizedRect: CGRect(x: 0.540, y: 0.075, width: 0.430, height: 0.080)),
                    OCRRegion(id: "roll", label: "卷号", kind: .roll, normalizedRect: CGRect(x: 0.540, y: 0.145, width: 0.430, height: 0.065)),
                    OCRRegion(id: "timecode", label: "时间码", kind: .timecode, normalizedRect: CGRect(x: 0.540, y: 0.200, width: 0.430, height: 0.090))
                ]
            ),
            SmokeCase(
                fileName: "qtake_C003_bottom_right_30fps.mov",
                regions: [
                    OCRRegion(id: "clip-name", label: "文件名", kind: .clipName, normalizedRect: CGRect(x: 0.650, y: 0.705, width: 0.315, height: 0.090)),
                    OCRRegion(id: "roll", label: "卷号", kind: .roll, normalizedRect: CGRect(x: 0.660, y: 0.775, width: 0.305, height: 0.065)),
                    OCRRegion(id: "timecode", label: "时间码", kind: .timecode, normalizedRect: CGRect(x: 0.735, y: 0.835, width: 0.230, height: 0.090))
                ]
            ),
            SmokeCase(
                fileName: "qtake_D009_center_top_24fps.mov",
                regions: [
                    OCRRegion(id: "clip-name", label: "文件名", kind: .clipName, normalizedRect: CGRect(x: 0.270, y: 0.075, width: 0.460, height: 0.080)),
                    OCRRegion(id: "roll", label: "卷号", kind: .roll, normalizedRect: CGRect(x: 0.270, y: 0.145, width: 0.460, height: 0.065)),
                    OCRRegion(id: "timecode", label: "时间码", kind: .timecode, normalizedRect: CGRect(x: 0.270, y: 0.200, width: 0.460, height: 0.090))
                ]
            )
        ]

        var failures: [String] = []
        for testCase in cases {
            let url = samplesDirectory.appendingPathComponent(testCase.fileName)
            let result = try await OCRClipAnalyzer().analyze(
                url: url,
                regions: testCase.regions,
                sourceTimecodeFrameRateSetting: .automatic
            )

            let timecodeText = result.startTimecode?.description ?? "nil"
            let rollText = result.roll ?? "nil"
            let clipNameText = result.clipName ?? "nil"
            print("\(testCase.fileName): \(result.statusTitle), confidence \(String(format: "%.2f", result.confidence)), TC \(timecodeText), roll \(rollText), clip \(clipNameText)")

            if result.startTimecode == nil || result.roll == nil || result.confidence < 0.75 {
                failures.append(testCase.fileName)
            }
        }

        if !failures.isEmpty {
            throw SmokeError.failedFiles(failures)
        }
    }
}

private enum SmokeError: Error, CustomStringConvertible {
    case failedFiles([String])

    var description: String {
        switch self {
        case .failedFiles(let files):
            "Smoke failed for: \(files.joined(separator: ", "))"
        }
    }
}
