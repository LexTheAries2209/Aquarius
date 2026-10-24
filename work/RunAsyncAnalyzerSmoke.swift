// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
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
        try verifyStrictTimecodeParsing()
        try verifySelectionOverscan()
        try verifyTimecodeCropBoundary()
        try verifyCandidateRanking()
        try verifyAdaptivePreprocessing()
        try verifyAdjacentTimecodeSequences()
        try verifyConfidenceCalibration()
        try verifyRecognizedTimecodeOverridesRiskStatus()
        try verifySampleOrdering()
        try verifyFrameRateEvidence()

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
                zip(result.samples, result.samples.dropFirst()).allSatisfy { $0.actualSeconds <= $1.actualSeconds }
                    ? nil : "OCR results are not in video frame order",
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
        let labeledTimecode = OCRCandidateRanker.bestCandidate(
            for: .timecode,
            candidates: [OCRTextCandidate(text: "A 14:10:10:10", confidence: 1)]
        )
        let ambiguousTimecode = OCRCandidateRanker.bestCandidate(
            for: .timecode,
            candidates: [OCRTextCandidate(text: "14:10:10:10 15:10:10:10", confidence: 1)]
        )
        let correctedTimecode = OCRCandidateRanker.bestCandidate(
            for: .timecode,
            candidates: [OCRTextCandidate(text: "A I4:10:10:10", confidence: 1)]
        )

        let failures = [
            OCRFieldParser.clipName(from: fileName.text) == "A006C001"
                ? nil
                : "candidate ranker selected invalid file name \(fileName.text)",
            OCRFieldParser.timecode(from: timecode.text, fps: 24)?.description == "10:04:02:06"
                ? nil
                : "candidate ranker selected invalid timecode \(timecode.text)",
            labeledTimecode.text == "14:10:10:10"
                ? nil
                : "timecode candidate must contain only the SMPTE value, got \(labeledTimecode.text)",
            labeledTimecode.rawText == "A 14:10:10:10"
                ? nil
                : "original OCR text must remain available for review",
            ambiguousTimecode.formatScore < 1
                ? nil
                : "two distinct timecodes in one candidate must not be treated as unambiguous",
            correctedTimecode.text == "14:10:10:10"
                && OCRCandidateRanker.positionCorrectionCount(kind: .timecode, text: correctedTimecode.rawText) == 1
                && OCRPreprocessingResolver.shouldUseFallback(correctedTimecode, kind: .timecode)
                ? nil
                : "normalization must retain character-correction evidence",
            OCRFieldParser.timecode(from: "14:10:10:10 15:10:10:10", fps: 25) == nil
                ? nil : "the field parser must reject conflicting timecodes",
            OCRFieldParser.timecode(from: "114:10:10:10", fps: 25) == nil
                ? nil : "the field parser must not extract a partial numeric token",
            OCRFieldParser.timecode(from: "14:10:10:10:12", fps: 25) == nil
                ? nil : "the field parser must reject extra timecode components"
        ].compactMap { $0 }

        if !failures.isEmpty {
            throw SmokeError.failedFiles(failures)
        }
        print("OCR candidate ranking cases passed")
    }

    private static func verifyStrictTimecodeParsing() throws {
        let invalid = [
            "A 14:10:10:10", "A:14:10:10:10", "14:10:10:10:A",
            ":14:10:10:10", "14:10:10:10:", "14::10:10:10",
            "1:10:10:10", "14:1:10:10", "+1:10:10:10",
            "14;10:10:10", "14:10;10:10", "14: 10:10:10",
            "24:00:00:00", "14:60:10:10", "14:10:60:10", "14:10:10:25"
        ]
        var failures = invalid.compactMap { text -> String? in
            Timecode.parse(text, fps: 25) == nil ? nil : "strict parser accepted \(text)"
        }
        for text in ["00:00:00:00", "14:10:10:10", "23:59:59:24", " 14:10:10:10\n"] {
            if Timecode.parse(text, fps: 25) == nil {
                failures.append("strict parser rejected \(text)")
            }
        }
        if !failures.isEmpty {
            throw SmokeError.failedFiles(failures)
        }
        print("Strict SMPTE timecode parsing cases passed")
    }

    private static func verifySelectionOverscan() throws {
        let canvas = CGSize(width: 1020, height: 1020)
        let full = OCRSelectionGeometry.normalizedRect(
            from: .zero, to: CGPoint(x: 1020, y: 1020), in: canvas
        )
        let reverse = OCRSelectionGeometry.normalizedRect(
            from: CGPoint(x: 1020, y: 1020), to: .zero, in: canvas
        )
        let beyond = OCRSelectionGeometry.normalizedRect(
            from: CGPoint(x: -100, y: -100), to: CGPoint(x: 1200, y: 1200), in: canvas
        )
        let bottom = OCRSelectionGeometry.normalizedRect(
            from: CGPoint(x: 810, y: 970), to: CGPoint(x: 960, y: 1020), in: canvas
        )
        let zero = OCRSelectionGeometry.normalizedRect(
            from: .zero, to: .zero, in: .zero
        )
        let corner = OCRSelectionGeometry.normalizedRect(
            from: CGPoint(x: 1020, y: 1020), to: CGPoint(x: 1020, y: 1020), in: canvas
        )
        let fullOverlay = OCRSelectionGeometry.overlayRect(for: full, in: canvas)
        let videoOverlay = OCRSelectionGeometry.overlayRect(
            for: CGRect(x: 0, y: 0, width: 1, height: 1), in: canvas
        )
        guard rectMatches(full, CGRect(x: -0.01, y: -0.01, width: 1.02, height: 1.02)),
              rectMatches(reverse, full), rectMatches(beyond, full),
              rectMatches(bottom, CGRect(x: 0.8, y: 0.96, width: 0.15, height: 0.05)),
              rectMatches(fullOverlay, CGRect(origin: .zero, size: canvas)),
              rectMatches(videoOverlay, CGRect(x: 10, y: 10, width: 1000, height: 1000)),
              rectMatches(corner, CGRect(x: 0.998, y: 0.998, width: 0.012, height: 0.012)),
              zero == .zero else {
            throw SmokeError.failedFiles(["ROI gestures and overlays must share the full-video 1% overscan bounds"])
        }
        let region = OCRRegion(id: "edge-tc", label: "edge", kind: .timecode, normalizedRect: bottom)
        let preset = ROIPreset(name: "edge-test", regions: [region])
        let restored = try JSONDecoder().decode(ROIPreset.self, from: JSONEncoder().encode(preset))
        guard let saved = restored.ocrRegions.first, rectMatches(saved.normalizedRect, bottom) else {
            throw SmokeError.failedFiles(["ROI preset round-trip must preserve selection below the video"])
        }
        print("ROI 1% overscan geometry, reverse drags, bounds and preset round-trip passed")
    }

    private static func rectMatches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.000001 && abs(lhs.minY - rhs.minY) < 0.000001
            && abs(lhs.width - rhs.width) < 0.000001 && abs(lhs.height - rhs.height) < 0.000001
    }

    private static func verifyTimecodeCropBoundary() throws {
        let context = CGContext(
            data: nil, width: 1000, height: 1000, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 1000, height: 500))
        context?.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context?.fill(CGRect(x: 0, y: 500, width: 1000, height: 500))
        guard let image = context?.makeImage() else {
            throw SmokeError.failedFiles(["could not create crop fixture"])
        }
        let processor = ROIImageProcessor()
        let rect = CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.1)
        let tight = processor.crop(image, to: rect, kind: .timecode)
        let expanded = processor.crop(image, to: rect, kind: .clipName)
        let outside = processor.crop(image, to: CGRect(x: 2, y: 2, width: 1, height: 1), kind: .timecode)
        guard tight?.width == 200, tight?.height == 100,
              expanded?.width == 240, expanded?.height == 120,
              outside == nil else {
            throw SmokeError.failedFiles(["timecode crop must respect the selection; other fields retain their margin"])
        }
        let paddedCases: [(CGRect, CGPoint, CGPoint, CGPoint)] = [
            (CGRect(x: 0.8, y: 0.96, width: 0.15, height: 0.05),
             CGPoint(x: 850, y: 980), CGPoint(x: 50, y: 20), CGPoint(x: 50, y: 49)),
            (CGRect(x: 0.8, y: -0.01, width: 0.15, height: 0.05),
             CGPoint(x: 850, y: 20), CGPoint(x: 50, y: 30), CGPoint(x: 50, y: 0)),
            (CGRect(x: -0.01, y: 0.8, width: 0.05, height: 0.15),
             CGPoint(x: 20, y: 850), CGPoint(x: 30, y: 50), CGPoint(x: 0, y: 50)),
            (CGRect(x: 0.96, y: 0.8, width: 0.05, height: 0.15),
             CGPoint(x: 980, y: 850), CGPoint(x: 20, y: 50), CGPoint(x: 49, y: 50))
        ]
        for (rect, sourcePoint, cropPoint, paddingPoint) in paddedCases {
            guard let cropped = processor.crop(image, to: rect, kind: .timecode),
                  cropped.width == Int((rect.width * 1000).rounded()),
                  cropped.height == Int((rect.height * 1000).rounded()),
                  pixel(in: cropped, at: cropPoint) == pixel(in: image, at: sourcePoint),
                  pixel(in: cropped, at: paddingPoint) == [0, 0, 0, 255] else {
                throw SmokeError.failedFiles(["overscan crop must retain edge pixels in place with opaque black padding: \(rect)"])
            }
        }
        print("Timecode crop boundary and four-edge pixel/padding cases passed")
    }

    private static func pixel(in image: CGImage, at point: CGPoint) -> [UInt8] {
        guard let sample = image.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))) else {
            return []
        }
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            )
            context?.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
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

    private static func verifyAdjacentTimecodeSequences() throws {
        let settings: [SourceTimecodeFrameRateSetting] = [
            .fps23976,
            .fps24,
            .fps25,
            .fps2997NDF,
            .fps2997DF,
            .fps30
        ]
        var failures: [String] = []

        for setting in settings {
            guard let fps = setting.fps else {
                continue
            }
            let samples = makeTimecodeSequence(setting: setting, corruptNextFrame: false)
            let valid = TimecodeSequenceValidator.validate(
                samples: samples,
                fps: fps,
                playbackFrameRate: setting.playbackFrameRate,
                isDropFrame: setting.isDropFrame
            )
            if valid.completeSequenceCount != 1
                || valid.consistentSequenceCount != 1
                || valid.validatedSampleIDs.count != 3 {
                failures.append("\(setting.title) continuous sequence was not accepted")
            }

            let corrupted = TimecodeSequenceValidator.validate(
                samples: makeTimecodeSequence(setting: setting, corruptNextFrame: true),
                fps: fps,
                playbackFrameRate: setting.playbackFrameRate,
                isDropFrame: setting.isDropFrame
            )
            if corrupted.completeSequenceCount != 1
                || corrupted.consistentSequenceCount != 0
                || !corrupted.validatedSampleIDs.isEmpty {
                failures.append("\(setting.title) discontinuous sequence was not rejected")
            }
        }

        if !failures.isEmpty {
            throw SmokeError.failedFiles(failures)
        }
        print("Adjacent-frame timecode cases passed for 23.976/24/25/29.97 NDF/DF/30 fps")
    }

    private static func makeTimecodeSequence(
        setting: SourceTimecodeFrameRateSetting,
        corruptNextFrame: Bool
    ) -> [OCRSample] {
        let fps = setting.fps ?? 24
        let sequenceID = UUID()
        let region = OCRRegion(
            id: "timecode-sequence",
            label: "时间码",
            kind: .timecode,
            normalizedRect: .zero
        )
        let centerVideoFrame = fps
        let baseTimecode = Timecode(
            hours: 10,
            minutes: 0,
            seconds: 0,
            frames: 0,
            fps: fps,
            playbackFrameRate: setting.playbackFrameRate,
            isDropFrame: setting.isDropFrame
        )
        let timebase: (value: Int64, timescale: Int32)
        switch setting {
        case .fps23976:
            timebase = (1_001, 24_000)
        case .fps2997NDF, .fps2997DF:
            timebase = (1_001, 30_000)
        default:
            timebase = (1, Int32(fps))
        }

        return [-1, 0, 1].map { position in
            let videoFrame = centerVideoFrame + position
            let timestampValue = Int64(videoFrame) * timebase.value
            let timecodeOffset = position == 1 && corruptNextFrame ? position + 1 : position
            let timecode = Timecode.from(
                totalFrames: baseTimecode.totalFrames + timecodeOffset,
                fps: fps,
                playbackFrameRate: setting.playbackFrameRate,
                isDropFrame: setting.isDropFrame
            )
            return OCRSample(
                region: region,
                requestedSeconds: Double(timestampValue) / Double(timebase.timescale),
                actualSeconds: Double(timestampValue) / Double(timebase.timescale),
                rawText: timecode.description,
                confidence: 1,
                actualTimeValue: timestampValue,
                actualTimeTimescale: timebase.timescale,
                timecodeSequenceID: sequenceID,
                timecodeSequencePosition: position
            )
        }
    }

    private static func verifyConfidenceCalibration() throws {
        let idealEvidence = OCRConfidenceEvidence(
            fieldConsistency: 1,
            visionConfidence: 1,
            formatValidity: 1,
            candidateSeparation: 0.20,
            preprocessingAgreement: 1,
            temporalConsistency: 1,
            isLegal: true,
            usesCharacterCorrection: false,
            isTimecodeFrameRateUnique: true
        )
        let ideal = OCRConfidenceCalibrator.assess(idealEvidence)
        let corrected = OCRConfidenceCalibrator.assess(
            OCRConfidenceEvidence(
                fieldConsistency: 1,
                visionConfidence: 1,
                formatValidity: 1,
                candidateSeparation: 0.20,
                preprocessingAgreement: 1,
                temporalConsistency: 1,
                isLegal: true,
                usesCharacterCorrection: true,
                isTimecodeFrameRateUnique: true
            )
        )
        let ambiguous = OCRConfidenceCalibrator.assess(
            OCRConfidenceEvidence(
                fieldConsistency: 1,
                visionConfidence: 1,
                formatValidity: 1,
                candidateSeparation: 0.20,
                preprocessingAgreement: 1,
                temporalConsistency: 1,
                isLegal: true,
                usesCharacterCorrection: false,
                isTimecodeFrameRateUnique: false
            )
        )
        let correctedCharacterCount = OCRCandidateRanker.positionCorrectionCount(
            kind: .clipName,
            text: "A00GC00T"
        )
        let cleanCharacterCount = OCRCandidateRanker.positionCorrectionCount(
            kind: .clipName,
            text: "A006C001"
        )
        let failures = [
            ideal.confidence >= 0.82 && !ideal.requiresReview
                ? nil
                : "ideal evidence should remain trusted",
            corrected.confidence < 0.82 && corrected.requiresReview
                ? nil
                : "character-corrected evidence must require review",
            ambiguous.confidence < 0.82 && ambiguous.requiresReview
                ? nil
                : "ambiguous timecode frame rate must require review",
            correctedCharacterCount == 2
                ? nil
                : "A00GC00T should record two position corrections, got \(correctedCharacterCount)",
            cleanCharacterCount == 0
                ? nil
                : "A006C001 should not record position corrections"
        ].compactMap { $0 }

        if !failures.isEmpty {
            throw SmokeError.failedFiles(failures)
        }
        print("OCR confidence calibration cases passed")
    }

    private static func verifyRecognizedTimecodeOverridesRiskStatus() throws {
        let startTimecode = Timecode(hours: 14, minutes: 10, seconds: 10, frames: 10, fps: 25)
        for status in [TimecodeConsistencyStatus.highRisk, .driftSuspected] {
            let diagnostics = TimecodeDiagnostics(
                setting: .automatic,
                videoFrameRate: 25,
                sourceTimecodeFrameRate: 25,
                validSampleCount: 1,
                invalidSampleCount: 0,
                maxDeviationFrames: nil,
                driftFramesPerMinute: nil,
                isFrameRateCandidateUnique: false,
                status: status,
                notes: ["diagnostic-only risk"]
            )
            let result = ClipOCRResult(
                videoName: "risk-status",
                fps: 25,
                videoFrameRate: 25,
                sourceTimecodeFrameRateSetting: .automatic,
                duration: 1,
                clipName: nil,
                roll: nil,
                startTimecode: startTimecode,
                confidence: 0.40,
                samples: [],
                timecodeDiagnostics: diagnostics,
                notes: []
            )
            let failures = [
                result.statusTitle == "可信"
                    ? nil
                    : "a parsed start TC must be reported as successful",
                MediaAnalysisStatus.status(for: result) == .trusted
                    ? nil
                    : "a parsed start TC must mark the media item trusted",
                ClipExportMetadata(result: result).startTimecode == startTimecode
                    ? nil
                    : "a parsed start TC must remain exportable for burning"
            ].compactMap { $0 }
            if !failures.isEmpty {
                throw SmokeError.failedFiles(failures)
            }
        }
        print("Recognized timecode overrides diagnostic risk status")
    }

    private static func verifySampleOrdering() throws {
        func sample(_ kind: OCRFieldKind, _ frame: Int64, requested: Double = 50) -> OCRSample {
            OCRSample(
                region: OCRRegion(id: kind.rawValue, label: kind.title, kind: kind, normalizedRect: .zero),
                requestedSeconds: requested,
                // Deliberately round these values: ordering must use actual PTS.
                actualSeconds: Double(frame / 25),
                rawText: kind.rawValue, confidence: 1,
                actualTimeValue: frame * 3600, actualTimeTimescale: 90_000
            )
        }
        let current = sample(.timecode, 25)
        let previous = sample(.timecode, 24)
        let next = sample(.timecode, 26)
        let earlyRetry = sample(.timecode, 10, requested: 100)
        let clip = sample(.clipName, 25)
        let roll = sample(.roll, 25)
        let duplicate = sample(.timecode, 25)
        let input = [current, previous, next, earlyRetry, roll, clip, duplicate]
        let expected = [earlyRetry, previous, clip, roll, current, duplicate, next]
        let sorted = OCRSampleOrdering.sorted(input)
        guard sorted.map(\.id) == expected.map(\.id),
              OCRSampleOrdering.sorted(sorted).map(\.id) == sorted.map(\.id) else {
            throw SmokeError.failedFiles(["samples must sort by actual PTS, then field, with stable duplicate order"])
        }
        let fallback = OCRSample(
            region: current.region, requestedSeconds: 200, actualSeconds: 0.5,
            rawText: "fallback", confidence: 1
        )
        guard OCRSampleOrdering.sorted([current, fallback, previous]).map(\.id)
            == [fallback, previous, current].map(\.id) else {
            throw SmokeError.failedFiles(["samples without PTS must sort by actual seconds"])
        }
        print("Chronological sample ordering cases passed")
    }

    private static func verifyFrameRateEvidence() throws {
        let region = OCRRegion(id: "jitter-tc", label: "时间码", kind: .timecode, normalizedRect: .zero)
        let start = Timecode(hours: 13, minutes: 23, seconds: 19, frames: 15, fps: 25)
        var samples: [OCRSample] = []
        for center in [25, 259, 516] {
            let sequenceID = UUID()
            for position in [-1, 0, 1] {
                let frame = center + position
                let timecode = Timecode.from(
                    totalFrames: start.totalFrames + frame + (position == 1 ? 1 : 0), fps: 25
                )
                samples.append(OCRSample(
                    region: region, requestedSeconds: Double(frame) / 25,
                    actualSeconds: Double(frame) / 25, rawText: timecode.description,
                    confidence: 1, formatScore: 1, candidateMargin: 1, preprocessingAgreement: 1,
                    actualTimeValue: Int64(frame), actualTimeTimescale: 25,
                    timecodeSequenceID: sequenceID, timecodeSequencePosition: position
                ))
            }
        }
        let result = OCRConsensusResolver.resolve(
            videoName: "25fps-monitor-jitter", videoFrameRate: 25,
            sourceTimecodeFrameRateSetting: .automatic, duration: 22,
            samples: samples, expectedKinds: [.timecode]
        )
        guard result.fps == 25, result.startTimecode == nil,
              result.confidence < 0.82,
              result.samples.allSatisfy({ $0.timecodeSampleStatus == .invalid }) else {
            throw SmokeError.failedFiles([
                "whole-clip evidence must identify 25fps without accepting discontinuous triples; got \(result.fps)fps"
            ])
        }
        let ambiguous = OCRConsensusResolver.resolve(
            videoName: "ambiguous-monitor-rate", videoFrameRate: 25,
            sourceTimecodeFrameRateSetting: .automatic, duration: 2,
            samples: Array(samples.prefix(3)), expectedKinds: [.timecode]
        )
        guard ambiguous.fps == 25, ambiguous.confidence < 0.82,
              ambiguous.timecodeDiagnostics?.isFrameRateCandidateUnique == false else {
            throw SmokeError.failedFiles(["a provisional media-rate tie break must not become a confident inference"])
        }
        print("Whole-clip frame-rate inference preserves continuity rejection")
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
