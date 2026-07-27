// SPDX-License-Identifier: GPL-3.0-only

import Foundation

private struct SmokeCase {
    let fileName: String
    let regions: [OCRRegion]
    let expectedClipName: String
    let expectedRoll: String
    let expectedStartTimecode: String
}

@main
struct RunAsyncAnalyzerSmoke {
    static func main() async throws {
        try verifyParserRegressions()
        try verifyCandidateRanking()
        try verifyAdaptivePreprocessing()

        let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let samplesDirectory = projectRoot
            .appendingPathComponent("Aquarius", isDirectory: true)
            .appendingPathComponent("Samples", isDirectory: true)
        let cases = [
            SmokeCase(
                fileName: "qtake_A001_bottom_left_24fps.mov",
                regions: OCRRegion.qtakeLowerLeftPreset,
                expectedClipName: "A001_C003_0703AB",
                expectedRoll: "A001",
                expectedStartTimecode: "10:00:00:00"
            ),
            SmokeCase(
                fileName: "qtake_B014_upper_right_25fps.mov",
                regions: [
                    OCRRegion(id: "clip-name", label: "文件名", kind: .clipName, normalizedRect: CGRect(x: 0.540, y: 0.075, width: 0.430, height: 0.080)),
                    OCRRegion(id: "roll", label: "卷号", kind: .roll, normalizedRect: CGRect(x: 0.540, y: 0.145, width: 0.430, height: 0.065)),
                    OCRRegion(id: "timecode", label: "时间码", kind: .timecode, normalizedRect: CGRect(x: 0.540, y: 0.200, width: 0.430, height: 0.090))
                ],
                expectedClipName: "B014_C007_SC12TK03",
                expectedRoll: "B014",
                expectedStartTimecode: "01:23:45:10"
            ),
            SmokeCase(
                fileName: "qtake_C003_bottom_right_30fps.mov",
                regions: [
                    OCRRegion(id: "clip-name", label: "文件名", kind: .clipName, normalizedRect: CGRect(x: 0.650, y: 0.705, width: 0.315, height: 0.090)),
                    OCRRegion(id: "roll", label: "卷号", kind: .roll, normalizedRect: CGRect(x: 0.660, y: 0.775, width: 0.305, height: 0.065)),
                    OCRRegion(id: "timecode", label: "时间码", kind: .timecode, normalizedRect: CGRect(x: 0.735, y: 0.835, width: 0.230, height: 0.090))
                ],
                expectedClipName: "C003_C021_DAY02",
                expectedRoll: "C003",
                expectedStartTimecode: "13:45:10:00"
            ),
            SmokeCase(
                fileName: "qtake_D009_center_top_24fps.mov",
                regions: [
                    OCRRegion(id: "clip-name", label: "文件名", kind: .clipName, normalizedRect: CGRect(x: 0.270, y: 0.075, width: 0.460, height: 0.080)),
                    OCRRegion(id: "roll", label: "卷号", kind: .roll, normalizedRect: CGRect(x: 0.270, y: 0.145, width: 0.460, height: 0.065)),
                    OCRRegion(id: "timecode", label: "时间码", kind: .timecode, normalizedRect: CGRect(x: 0.270, y: 0.200, width: 0.460, height: 0.090))
                ],
                expectedClipName: "D009_C001_NIGHT",
                expectedRoll: "D009",
                expectedStartTimecode: "22:10:05:12"
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

            let mismatches = [
                result.clipName == testCase.expectedClipName ? nil : "clip expected \(testCase.expectedClipName), got \(clipNameText)",
                result.roll == testCase.expectedRoll ? nil : "roll expected \(testCase.expectedRoll), got \(rollText)",
                timecodeText == testCase.expectedStartTimecode ? nil : "TC expected \(testCase.expectedStartTimecode), got \(timecodeText)",
                result.confidence >= 0.82 ? nil : "confidence expected trusted, got \(String(format: "%.2f", result.confidence))"
            ].compactMap { $0 }

            if !mismatches.isEmpty {
                failures.append("\(testCase.fileName): \(mismatches.joined(separator: "; "))")
            }
        }

        if !failures.isEmpty {
            throw SmokeError.failedFiles(failures)
        }
    }

    private static func verifyParserRegressions() throws {
        let cases = [
            (raw: "A006C001", expected: "A006C001"),
            (raw: "A00GC00T", expected: "A006C001"),
            (raw: "A001_C003_0703AB", expected: "A001_C003_0703AB"),
            (raw: "D009 C001 NIGHT", expected: "D009_C001_NIGHT")
        ]

        let failures = cases.compactMap { testCase -> String? in
            let actual = OCRFieldParser.clipName(from: testCase.raw)
            return actual == testCase.expected
                ? nil
                : "parser input \(testCase.raw): expected \(testCase.expected), got \(actual ?? "nil")"
        }

        if !failures.isEmpty {
            throw SmokeError.failedFiles(failures)
        }
        print("OCR parser regression cases passed")
    }

    private static func verifyCandidateRanking() throws {
        let fileName = OCRCandidateRanker.bestCandidate(
            for: .clipName,
            candidates: [
                OCRTextCandidate(text: "LOOK 05", confidence: 1.0),
                OCRTextCandidate(text: "A006C001", confidence: 0.72)
            ]
        )
        let timecode = OCRCandidateRanker.bestCandidate(
            for: .timecode,
            candidates: [
                OCRTextCandidate(text: "10:04:02:99", confidence: 1.0),
                OCRTextCandidate(text: "10:04:02:06", confidence: 0.70)
            ]
        )

        let failures = [
            OCRFieldParser.clipName(from: fileName.text) == "A006C001"
                ? nil
                : "candidate ranker selected invalid file name \(fileName.text)",
            OCRFieldParser.timecode(from: timecode.text, fps: 24)?.description == "10:04:02:06"
                ? nil
                : "candidate ranker selected invalid timecode \(timecode.text)"
        ].compactMap { $0 }

        if !failures.isEmpty {
            throw SmokeError.failedFiles(failures)
        }
        print("OCR candidate ranking cases passed")
    }

    private static func verifyAdaptivePreprocessing() throws {
        let corrected = RecognizedTextCandidate(
            text: "A00GC00T",
            confidence: 1,
            formatScore: 1,
            candidateMargin: 0.4,
            preprocessingAgreement: 1
        )
        let clean = RecognizedTextCandidate(
            text: "A006C001",
            confidence: 1,
            formatScore: 1,
            candidateMargin: 0.4,
            preprocessingAgreement: 1
        )
        let qtakePrimary = RecognizedTextCandidate(
            text: "A001_C003_0703AB",
            confidence: 0.72,
            formatScore: 1,
            candidateMargin: 0.04,
            preprocessingAgreement: 1
        )
        let qtakeAlternative = RecognizedTextCandidate(
            text: "A001_C003_O703AB",
            confidence: 0.98,
            formatScore: 1,
            candidateMargin: 0.30,
            preprocessingAgreement: 1
        )
        let qtakeResolved = OCRPreprocessingResolver.resolve(
            kind: .clipName,
            candidates: [qtakePrimary, qtakeAlternative, qtakeAlternative]
        )
        let compactResolved = OCRPreprocessingResolver.resolve(
            kind: .clipName,
            candidates: [corrected, clean, clean]
        )

        let failures = [
            OCRPreprocessingResolver.shouldUseFallback(corrected, kind: .clipName)
                ? nil
                : "character-corrected file name should trigger preprocessing fallback",
            OCRPreprocessingResolver.shouldUseFallback(clean, kind: .clipName)
                ? "clean file name should remain on the primary preprocessing path"
                : nil,
            qtakeResolved.text == qtakePrimary.text
                ? nil
                : "equally valid preprocessing variants should preserve primary QTake text, got \(qtakeResolved.text)",
            compactResolved.text == clean.text
                ? nil
                : "clean compact file name should beat a character-corrected variant, got \(compactResolved.text)"
        ].compactMap { $0 }

        if !failures.isEmpty {
            throw SmokeError.failedFiles(failures)
        }
        print("Adaptive OCR preprocessing cases passed")
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
