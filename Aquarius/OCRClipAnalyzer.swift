// SPDX-License-Identifier: GPL-3.0-only

import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Vision

enum AVAssetFrameExtractionError: LocalizedError {
    case noImage

    nonisolated var errorDescription: String? {
        switch self {
        case .noImage:
            "无法从视频中生成预览帧"
        }
    }
}

extension AVAssetImageGenerator {
    nonisolated func ocrTimecodeCGImage(at requestedTime: CMTime) async throws -> (image: CGImage, actualTime: CMTime) {
        try await withCheckedThrowingContinuation { continuation in
            generateCGImageAsynchronously(for: requestedTime) { image, actualTime, error in
                if let image {
                    continuation.resume(returning: (image, actualTime))
                } else {
                    continuation.resume(throwing: error ?? AVAssetFrameExtractionError.noImage)
                }
            }
        }
    }
}

struct OCRClipAnalyzer {
    private let maximumSamplePointCount = 50
    private let denseSamplingDurationLimit = 10.0 * 60.0
    private let denseSamplesPerMinute = 5.0
    private let imageProcessor = ROIImageProcessor()
    private let recognizer = VisionTextRecognizer()

    nonisolated init() {}

    nonisolated func analyze(
        url: URL,
        regions: [OCRRegion],
        sourceTimecodeFrameRateSetting: SourceTimecodeFrameRateSetting
    ) async throws -> ClipOCRResult {
        let asset = AVURLAsset(url: url)
        let videoFrameRate = try await detectFrameRate(asset: asset)
        let duration = safeDuration(try await asset.load(.duration).seconds)
        let sampleTimes = buildBaseSampleTimes(duration: duration)
        let expectedKinds = Set(regions.map(\.kind))
        let generator = AVAssetImageGenerator(asset: asset)

        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.apertureMode = .encodedPixels

        var samples = await collectSamples(
            at: sampleTimes,
            generator: generator,
            regions: regions,
            videoFrameRate: videoFrameRate,
            duration: duration
        )
        var result = OCRConsensusResolver.resolve(
            videoName: url.lastPathComponent,
            videoFrameRate: videoFrameRate,
            sourceTimecodeFrameRateSetting: sourceTimecodeFrameRateSetting,
            duration: duration,
            samples: samples,
            expectedKinds: expectedKinds
        )

        let nearbySampleTimes = buildNearbySampleTimes(
            from: samples,
            result: result,
            duration: duration,
            existingTimes: sampleTimes,
            sourceTimecodeFrameRateSetting: sourceTimecodeFrameRateSetting
        )

        if !nearbySampleTimes.isEmpty {
            samples.append(
                contentsOf: await collectSamples(
                    at: nearbySampleTimes,
                    generator: generator,
                    regions: regions,
                    videoFrameRate: videoFrameRate,
                    duration: duration
                )
            )
            result = OCRConsensusResolver.resolve(
                videoName: url.lastPathComponent,
                videoFrameRate: videoFrameRate,
                sourceTimecodeFrameRateSetting: sourceTimecodeFrameRateSetting,
                duration: duration,
                samples: samples,
                expectedKinds: expectedKinds
            )
        }

        return result
    }

    nonisolated private func collectSamples(
        at sampleTimes: [Double],
        generator: AVAssetImageGenerator,
        regions: [OCRRegion],
        videoFrameRate: Double,
        duration: Double
    ) async -> [OCRSample] {
        var samples: [OCRSample] = []
        let timecodeRegions = regions.filter { $0.kind == .timecode }
        let frameDuration = rationalFrameDuration(for: videoFrameRate)

        for seconds in sampleTimes {
            let requestedTime = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let frameResult = try? await generator.ocrTimecodeCGImage(at: requestedTime) else {
                continue
            }
            let sequenceID = timecodeRegions.isEmpty ? nil : UUID()

            for region in regions {
                if let sample = makeSample(
                    from: frameResult,
                    requestedSeconds: seconds,
                    region: region,
                    sequenceID: region.kind == .timecode ? sequenceID : nil,
                    sequencePosition: region.kind == .timecode ? 0 : nil
                ) {
                    samples.append(sample)
                }
            }

            for position in [-1, 1] where !timecodeRegions.isEmpty {
                let adjacentTime = CMTimeAdd(
                    frameResult.actualTime,
                    CMTimeMultiply(frameDuration, multiplier: Int32(position))
                )
                let adjacentSeconds = adjacentTime.seconds
                guard adjacentSeconds >= 0, adjacentSeconds < duration,
                      let adjacentFrame = try? await generator.ocrTimecodeCGImage(at: adjacentTime) else {
                    continue
                }

                for region in timecodeRegions {
                    if let sample = makeSample(
                        from: adjacentFrame,
                        requestedSeconds: adjacentSeconds,
                        region: region,
                        sequenceID: sequenceID,
                        sequencePosition: position
                    ) {
                        samples.append(sample)
                    }
                }
            }
        }

        return samples
    }

    nonisolated private func makeSample(
        from frameResult: (image: CGImage, actualTime: CMTime),
        requestedSeconds: Double,
        region: OCRRegion,
        sequenceID: UUID?,
        sequencePosition: Int?
    ) -> OCRSample? {
        guard let candidate = recognize(frameResult.image, in: region) else {
            return nil
        }

        return OCRSample(
            region: region,
            requestedSeconds: requestedSeconds,
            actualSeconds: safeDuration(frameResult.actualTime.seconds, fallback: requestedSeconds),
            rawText: candidate.text,
            confidence: candidate.confidence,
            formatScore: candidate.formatScore,
            candidateMargin: candidate.candidateMargin,
            preprocessingAgreement: candidate.preprocessingAgreement,
            characterCorrectionCount: OCRCandidateRanker.positionCorrectionCount(
                kind: region.kind,
                text: candidate.text
            ),
            actualTimeValue: frameResult.actualTime.value,
            actualTimeTimescale: frameResult.actualTime.timescale,
            timecodeSequenceID: sequenceID,
            timecodeSequencePosition: sequencePosition
        )
    }

    nonisolated private func rationalFrameDuration(for frameRate: Double) -> CMTime {
        if abs(frameRate - 24_000.0 / 1_001.0) < 0.05 {
            return CMTime(value: 1_001, timescale: 24_000)
        }
        if abs(frameRate - 30_000.0 / 1_001.0) < 0.05 {
            return CMTime(value: 1_001, timescale: 30_000)
        }
        return CMTime(value: 1, timescale: Int32(max(1, round(frameRate))))
    }

    nonisolated private func recognize(_ frame: CGImage, in region: OCRRegion) -> RecognizedTextCandidate? {
        guard let expandedCrop = imageProcessor.crop(frame, to: region.normalizedRect, expanded: true),
              let primaryImage = imageProcessor.preprocess(expandedCrop, variant: .balanced),
              let primaryCandidate = try? recognizer.recognize(primaryImage, kind: region.kind) else {
            return nil
        }
        guard OCRPreprocessingResolver.shouldUseFallback(primaryCandidate, kind: region.kind) else {
            return primaryCandidate
        }

        let tightCrop = imageProcessor.crop(frame, to: region.normalizedRect, expanded: false)
        let fallbackImages = imageProcessor.fallbackVariants(
            expandedCrop: expandedCrop,
            tightCrop: tightCrop
        )
        let fallbackCandidates = fallbackImages.compactMap { image in
            try? recognizer.recognize(image, kind: region.kind)
        }

        return OCRPreprocessingResolver.resolve(
            kind: region.kind,
            candidates: [primaryCandidate] + fallbackCandidates
        )
    }

    nonisolated private func detectFrameRate(asset: AVAsset) async throws -> Double {
        let nominalFrameRate = try await asset.loadTracks(withMediaType: .video).first?.load(.nominalFrameRate) ?? 24
        let frameRate = Double(nominalFrameRate)
        guard frameRate.isFinite, frameRate > 0 else {
            return 24
        }
        return frameRate
    }

    nonisolated private func buildBaseSampleTimes(duration: Double) -> [Double] {
        guard duration.isFinite, duration > 0.5 else {
            return [0.1]
        }

        let lastSafeTime = max(0.1, duration - 0.6)
        guard duration >= 6 else {
            return uniqueSampleTimes([0.4, duration * 0.5, lastSafeTime], lastSafeTime: lastSafeTime)
        }
        guard duration >= 60 else {
            return uniqueSampleTimes([1.0, duration * 0.40, duration * 0.68], lastSafeTime: lastSafeTime)
        }

        let targetCount = min(maximumSamplePointCount, dynamicSampleCount(for: duration))
        let firstSafeTime = min(max(1.0, duration * 0.01), lastSafeTime)

        if targetCount == 1 || lastSafeTime <= firstSafeTime {
            return [firstSafeTime]
        }

        let span = lastSafeTime - firstSafeTime
        let rawTimes = (0..<targetCount).map { index in
            firstSafeTime + span * Double(index) / Double(targetCount - 1)
        }

        return uniqueSampleTimes(rawTimes, lastSafeTime: lastSafeTime)
    }

    nonisolated private func buildNearbySampleTimes(
        from samples: [OCRSample],
        result: ClipOCRResult,
        duration: Double,
        existingTimes: [Double],
        sourceTimecodeFrameRateSetting: SourceTimecodeFrameRateSetting
    ) -> [Double] {
        guard duration.isFinite, duration > 2 else {
            return []
        }

        let weakTimes = weakSampleTimes(
            from: samples,
            sourceTimecodeFrameRateSetting: sourceTimecodeFrameRateSetting
        )
        guard !weakTimes.isEmpty || result.notes.contains(where: isSamplingRelevantNote) else {
            return []
        }

        let lastSafeTime = max(0.1, duration - 0.6)
        let sourceTimes = weakTimes.isEmpty ? existingTimes : weakTimes
        let offsets = [-1.0, 1.0, -2.0, 2.0]
        let remainingSamplePointCount = max(0, maximumSamplePointCount - existingTimes.count)
        let maximumAdditionalCount = min(max(existingTimes.count, 4), remainingSamplePointCount)
        guard maximumAdditionalCount > 0 else {
            return []
        }
        var allKnownTimes = existingTimes
        var nearbyTimes: [Double] = []

        for sourceTime in sourceTimes {
            for offset in offsets {
                let time = min(max(sourceTime + offset, 0.1), lastSafeTime)
                guard !allKnownTimes.contains(where: { abs($0 - time) < 0.25 }),
                      !nearbyTimes.contains(where: { abs($0 - time) < 0.25 }) else {
                    continue
                }
                nearbyTimes.append(time)
                allKnownTimes.append(time)

                if nearbyTimes.count >= maximumAdditionalCount {
                    return nearbyTimes.sorted()
                }
            }
        }

        return nearbyTimes.sorted()
    }

    nonisolated private func dynamicSampleCount(for duration: Double) -> Int {
        guard duration.isFinite, duration > 0 else {
            return 1
        }

        if duration > denseSamplingDurationLimit {
            return maximumSamplePointCount
        }

        return max(3, Int(ceil(duration / 60.0 * denseSamplesPerMinute)))
    }

    nonisolated private func weakSampleTimes(
        from samples: [OCRSample],
        sourceTimecodeFrameRateSetting: SourceTimecodeFrameRateSetting
    ) -> [Double] {
        samples
            .filter { sample in
                if sample.region.kind == .clipName {
                    return false
                }
                if sample.confidence < 0.50 || sample.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }

                switch sample.region.kind {
                case .clipName:
                    return OCRFieldParser.clipName(from: sample.rawText) == nil
                case .roll:
                    return OCRFieldParser.roll(from: sample.rawText) == nil
                case .timecode:
                    return !sourceTimecodeFrameRateSetting.candidateFrameRates.contains { fps in
                        OCRFieldParser.timecode(
                            from: sample.rawText,
                            fps: fps,
                            playbackFrameRate: sourceTimecodeFrameRateSetting == .automatic ? Double(fps) : sourceTimecodeFrameRateSetting.playbackFrameRate,
                            isDropFrame: sourceTimecodeFrameRateSetting != .automatic && sourceTimecodeFrameRateSetting.isDropFrame
                        ) != nil
                    }
                }
            }
            .map(\.actualSeconds)
            .reduce(into: [Double]()) { unique, time in
                if !unique.contains(where: { abs($0 - time) < 0.25 }) {
                    unique.append(time)
                }
            }
    }

    nonisolated private func isSamplingRelevantNote(_ note: String) -> Bool {
        note.contains("卷号") || note.contains("时间码") || note.contains("起始")
    }

    nonisolated private func uniqueSampleTimes(_ rawTimes: [Double], lastSafeTime: Double) -> [Double] {
        rawTimes
            .map { min(max(0.1, $0), lastSafeTime) }
            .reduce(into: [Double]()) { unique, time in
                if !unique.contains(where: { abs($0 - time) < 0.05 }) {
                    unique.append(time)
                }
            }
    }

    nonisolated private func safeDuration(_ value: Double, fallback: Double = 0) -> Double {
        value.isFinite ? value : fallback
    }
}

enum OCRImagePreprocessingVariant {
    case natural
    case balanced
    case inverted
    case threshold
}

private struct ROIImageProcessor {
    private let context = CIContext()

    nonisolated init() {}

    nonisolated func crop(
        _ image: CGImage,
        to normalizedRect: CGRect,
        expanded: Bool
    ) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let cropRect = expanded
            ? normalizedRect.insetBy(dx: -0.010, dy: -0.012)
            : normalizedRect
        let clamped = cropRect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

        let pixelRect = CGRect(
            x: clamped.minX * width,
            y: clamped.minY * height,
            width: clamped.width * width,
            height: clamped.height * height
        ).integral

        return image.cropping(to: pixelRect)
    }

    nonisolated func fallbackVariants(
        expandedCrop: CGImage,
        tightCrop: CGImage?
    ) -> [CGImage] {
        var images = [
            preprocess(expandedCrop, variant: .natural),
            preprocess(expandedCrop, variant: .inverted),
            preprocess(expandedCrop, variant: .threshold)
        ].compactMap { $0 }

        if let tightCrop,
           let tightBalanced = preprocess(tightCrop, variant: .balanced) {
            images.append(tightBalanced)
        }
        return images
    }

    nonisolated func preprocess(
        _ image: CGImage,
        variant: OCRImagePreprocessingVariant
    ) -> CGImage? {
        let scaled = CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(scaleX: 2.5, y: 2.5))
        let monochrome = scaled.applyingFilter(
            "CIColorControls",
            parameters: [kCIInputSaturationKey: 0]
        )
        let ciImage: CIImage

        switch variant {
        case .natural:
            ciImage = monochrome
        case .balanced:
            ciImage = balancedImage(monochrome)
        case .inverted:
            ciImage = balancedImage(monochrome).applyingFilter("CIColorInvert")
        case .threshold:
            if CIFilter(name: "CIColorThreshold") != nil {
                ciImage = monochrome.applyingFilter(
                    "CIColorThreshold",
                    parameters: ["inputThreshold": 0.5]
                )
            } else {
                ciImage = monochrome.applyingFilter(
                    "CIColorControls",
                    parameters: [kCIInputContrastKey: 2.4]
                )
            }
        }

        return context.createCGImage(ciImage, from: ciImage.extent)
    }

    nonisolated private func balancedImage(_ image: CIImage) -> CIImage {
        image
            .applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputContrastKey: 1.65,
                    kCIInputBrightnessKey: 0.03
                ]
            )
            .applyingFilter(
                "CISharpenLuminance",
                parameters: [kCIInputSharpnessKey: 0.75]
            )
    }
}

struct OCRTextCandidate: Sendable {
    let text: String
    let confidence: Double
}

struct RecognizedTextCandidate: Sendable {
    let text: String
    let confidence: Double
    let formatScore: Double
    let candidateMargin: Double
    let preprocessingAgreement: Double
}

protocol OCRTextRecognizing {
    nonisolated func recognize(_ image: CGImage, kind: OCRFieldKind) throws -> RecognizedTextCandidate
}

struct VisionTextRecognizer: OCRTextRecognizing {
    private struct PartialLineCandidate {
        let text: String
        let confidenceTotal: Double
        let count: Int

        nonisolated var averageConfidence: Double {
            confidenceTotal / Double(max(1, count))
        }
    }

    nonisolated init() {}

    nonisolated func recognize(_ image: CGImage, kind: OCRFieldKind) throws -> RecognizedTextCandidate {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = kind == .roll
        request.customWords = customWords(for: kind)
        request.minimumTextHeight = 0.02

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])

        let observations = request.results ?? []
        let candidates = lineCandidates(from: observations)
            + legacyCombinedCandidate(from: observations)

        return OCRCandidateRanker.bestCandidate(for: kind, candidates: candidates)
    }

    nonisolated private func customWords(for kind: OCRFieldKind) -> [String] {
        switch kind {
        case .clipName:
            ["A001", "B001", "C001", "QTAKE", "DAILIES"]
        case .roll:
            ["ROLL", "REEL", "A001", "B001", "C001", "QTAKE", "DAILIES"]
        case .timecode:
            ["10:00:00:00", "00:00:00:00"]
        }
    }

    nonisolated private func lineCandidates(
        from observations: [VNRecognizedTextObservation]
    ) -> [OCRTextCandidate] {
        var candidates: [OCRTextCandidate] = []

        for observations in observationLines(from: observations) {
            var partials = [PartialLineCandidate(text: "", confidenceTotal: 0, count: 0)]

            for observation in observations {
                let alternatives = observation.topCandidates(5)
                guard !alternatives.isEmpty else {
                    continue
                }

                var expanded: [PartialLineCandidate] = []
                for partial in partials {
                    for alternative in alternatives {
                        expanded.append(
                            PartialLineCandidate(
                                text: partial.text.isEmpty
                                    ? alternative.string
                                    : "\(partial.text) \(alternative.string)",
                                confidenceTotal: partial.confidenceTotal + Double(alternative.confidence),
                                count: partial.count + 1
                            )
                        )
                    }
                }

                let sorted = expanded.sorted { $0.averageConfidence > $1.averageConfidence }
                partials = Array(sorted.prefix(20))
            }

            candidates.append(contentsOf: partials.compactMap { partial in
                guard partial.count > 0 else {
                    return nil
                }
                return OCRTextCandidate(
                    text: partial.text,
                    confidence: partial.averageConfidence
                )
            })
        }

        return candidates
    }

    nonisolated private func legacyCombinedCandidate(
        from observations: [VNRecognizedTextObservation]
    ) -> [OCRTextCandidate] {
        let candidates = observations
            .sorted { lhs, rhs in
                if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) < 0.02 {
                    return lhs.boundingBox.minX < rhs.boundingBox.minX
                }
                return lhs.boundingBox.maxY > rhs.boundingBox.maxY
            }
            .compactMap { $0.topCandidates(1).first }
        guard !candidates.isEmpty else {
            return []
        }

        return [
            OCRTextCandidate(
                text: candidates.map(\.string).joined(separator: "\n"),
                confidence: candidates.map { Double($0.confidence) }.reduce(0, +) / Double(candidates.count)
            )
        ]
    }

    nonisolated private func observationLines(
        from observations: [VNRecognizedTextObservation]
    ) -> [[VNRecognizedTextObservation]] {
        let sorted = observations.sorted { lhs, rhs in
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) < 0.02 {
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            return lhs.boundingBox.midY > rhs.boundingBox.midY
        }
        var lines: [[VNRecognizedTextObservation]] = []

        for observation in sorted {
            if let index = lines.firstIndex(where: { line in
                guard let reference = line.first else {
                    return false
                }
                let tolerance = max(reference.boundingBox.height, observation.boundingBox.height) * 0.55
                return abs(reference.boundingBox.midY - observation.boundingBox.midY) <= tolerance
            }) {
                lines[index].append(observation)
            } else {
                lines.append([observation])
            }
        }

        return lines.map { $0.sorted { $0.boundingBox.minX < $1.boundingBox.minX } }
    }
}

enum OCRCandidateRanker {
    nonisolated static func bestCandidate(
        for kind: OCRFieldKind,
        candidates: [OCRTextCandidate]
    ) -> RecognizedTextCandidate {
        let scored = bestCandidateForCanonicalValue(kind: kind, candidates: candidates)
            .sorted { lhs, rhs in
                if abs(lhs.score - rhs.score) < 0.0001 {
                    return lhs.candidate.confidence > rhs.candidate.confidence
                }
                return lhs.score > rhs.score
            }
        guard let best = scored.first else {
            return RecognizedTextCandidate(
                text: "",
                confidence: 0,
                formatScore: 0,
                candidateMargin: 0,
                preprocessingAgreement: 0
            )
        }

        return RecognizedTextCandidate(
            text: best.candidate.text,
            confidence: best.candidate.confidence,
            formatScore: best.formatScore,
            candidateMargin: max(0, best.score - (scored.dropFirst().first?.score ?? 0)),
            preprocessingAgreement: 1
        )
    }

    nonisolated private static func bestCandidateForCanonicalValue(
        kind: OCRFieldKind,
        candidates: [OCRTextCandidate]
    ) -> [(candidate: OCRTextCandidate, formatScore: Double, score: Double)] {
        let scored = candidates.map { candidate in
            let formatScore = fieldFormatScore(kind: kind, text: candidate.text)
            return (
                candidate: candidate,
                formatScore: formatScore,
                score: formatScore * 0.65 + candidate.confidence * 0.35
            )
        }

        return Dictionary(grouping: scored, by: { canonicalValue(kind: kind, text: $0.candidate.text) })
            .compactMap { _, values in
                values.max { lhs, rhs in
                    if abs(lhs.score - rhs.score) < 0.0001 {
                        return lhs.candidate.confidence < rhs.candidate.confidence
                    }
                    return lhs.score < rhs.score
                }
            }
    }

    nonisolated static func fieldFormatScore(kind: OCRFieldKind, text: String) -> Double {
        switch kind {
        case .clipName:
            if OCRFieldParser.clipName(from: text) != nil {
                return 1
            }
        case .roll:
            if OCRFieldParser.roll(from: text) != nil {
                return 1
            }
        case .timecode:
            if [24, 25, 30].contains(where: { fps in
                OCRFieldParser.timecode(from: text, fps: fps) != nil
                    || (fps == 30 && OCRFieldParser.timecode(
                        from: text,
                        fps: fps,
                        playbackFrameRate: SourceTimecodeFrameRateSetting.fps2997DF.playbackFrameRate,
                        isDropFrame: true
                    ) != nil)
            }) {
                return 1
            }
        }

        let usefulCharacters = text.filter { $0.isLetter || $0.isNumber || "_:;-".contains($0) }
        return usefulCharacters.count >= 4 ? 0.2 : 0
    }

    nonisolated static func canonicalValue(kind: OCRFieldKind, text: String) -> String {
        switch kind {
        case .clipName:
            return OCRFieldParser.clipName(from: text) ?? normalizedWhitespace(text)
        case .roll:
            return OCRFieldParser.roll(from: text) ?? normalizedWhitespace(text)
        case .timecode:
            for fps in [24, 25, 30] {
                if let value = OCRFieldParser.timecode(from: text, fps: fps) {
                    return value.description
                }
                if fps == 30,
                   let value = OCRFieldParser.timecode(
                       from: text,
                       fps: fps,
                       playbackFrameRate: SourceTimecodeFrameRateSetting.fps2997DF.playbackFrameRate,
                       isDropFrame: true
                   ) {
                    return value.description
                }
            }
            return normalizedWhitespace(text)
        }
    }

    nonisolated static func characterCorrectionCount(kind: OCRFieldKind, text: String) -> Int {
        let rawCharacters = Array(text.uppercased().filter { $0.isLetter || $0.isNumber })
        let canonicalCharacters = Array(canonicalValue(kind: kind, text: text).filter { $0.isLetter || $0.isNumber })
        let sharedCount = min(rawCharacters.count, canonicalCharacters.count)
        let substitutions = zip(rawCharacters.prefix(sharedCount), canonicalCharacters.prefix(sharedCount))
            .filter { $0 != $1 }
            .count
        return substitutions + abs(rawCharacters.count - canonicalCharacters.count)
    }

    nonisolated static func positionCorrectionCount(kind: OCRFieldKind, text: String) -> Int {
        let rawCharacters = Array(text.uppercased().filter { $0.isLetter || $0.isNumber })
        let canonicalCharacters = Array(canonicalValue(kind: kind, text: text).filter { $0.isLetter || $0.isNumber })
        guard rawCharacters.count == canonicalCharacters.count else {
            return 0
        }
        return zip(rawCharacters, canonicalCharacters).filter { $0 != $1 }.count
    }

    nonisolated private static func normalizedWhitespace(_ text: String) -> String {
        text
            .uppercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

enum OCRPreprocessingResolver {
    nonisolated static func shouldUseFallback(
        _ candidate: RecognizedTextCandidate,
        kind: OCRFieldKind
    ) -> Bool {
        candidate.text.isEmpty
            || candidate.formatScore < 1
            || candidate.confidence < 0.78
            || candidate.candidateMargin < 0.05
            || usesCharacterCorrection(kind: kind, text: candidate.text)
    }

    nonisolated static func resolve(
        kind: OCRFieldKind,
        candidates: [RecognizedTextCandidate]
    ) -> RecognizedTextCandidate {
        let nonEmpty = candidates.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let primary = nonEmpty.first else {
            return OCRCandidateRanker.bestCandidate(for: kind, candidates: [])
        }

        let grouped = Dictionary(grouping: nonEmpty) {
            OCRCandidateRanker.canonicalValue(kind: kind, text: $0.text)
        }
        let primaryCanonical = OCRCandidateRanker.canonicalValue(kind: kind, text: primary.text)
        let selectedCanonical: String

        if primary.formatScore == 1 {
            let primaryCorrectionCount = OCRCandidateRanker.characterCorrectionCount(
                kind: kind,
                text: primary.text
            )
            let cleanerGroups = grouped.filter { _, values in
                values.contains {
                    OCRCandidateRanker.characterCorrectionCount(kind: kind, text: $0.text) < primaryCorrectionCount
                }
            }

            selectedCanonical = cleanerGroups
                .max(by: isWeakerGroup(kind: kind))?
                .key
                ?? primaryCanonical
        } else {
            selectedCanonical = grouped.max(by: isWeakerGroup(kind: kind))?.key ?? primaryCanonical
        }

        let selectedGroup = grouped[selectedCanonical] ?? [primary]
        let selected = selectedGroup.min { lhs, rhs in
            let lhsCorrectionCount = OCRCandidateRanker.characterCorrectionCount(kind: kind, text: lhs.text)
            let rhsCorrectionCount = OCRCandidateRanker.characterCorrectionCount(kind: kind, text: rhs.text)
            if lhsCorrectionCount != rhsCorrectionCount {
                return lhsCorrectionCount < rhsCorrectionCount
            }
            return lhs.confidence > rhs.confidence
        } ?? primary
        let agreementCount = nonEmpty.filter {
            OCRCandidateRanker.canonicalValue(kind: kind, text: $0.text) == selectedCanonical
        }.count

        return RecognizedTextCandidate(
            text: selected.text,
            confidence: selected.confidence,
            formatScore: selected.formatScore,
            candidateMargin: selected.candidateMargin,
            preprocessingAgreement: Double(agreementCount) / Double(nonEmpty.count)
        )
    }

    nonisolated private static func isWeakerGroup(
        kind: OCRFieldKind
    ) -> ((key: String, value: [RecognizedTextCandidate]), (key: String, value: [RecognizedTextCandidate])) -> Bool {
        { lhs, rhs in
            if lhs.value.count != rhs.value.count {
                return lhs.value.count < rhs.value.count
            }

            let lhsBest = lhs.value.map {
                OCRCandidateRanker.characterCorrectionCount(kind: kind, text: $0.text)
            }.min() ?? Int.max
            let rhsBest = rhs.value.map {
                OCRCandidateRanker.characterCorrectionCount(kind: kind, text: $0.text)
            }.min() ?? Int.max
            if lhsBest != rhsBest {
                return lhsBest > rhsBest
            }

            let lhsConfidence = lhs.value.map(\.confidence).reduce(0, +) / Double(lhs.value.count)
            let rhsConfidence = rhs.value.map(\.confidence).reduce(0, +) / Double(rhs.value.count)
            return lhsConfidence < rhsConfidence
        }
    }

    nonisolated private static func usesCharacterCorrection(kind: OCRFieldKind, text: String) -> Bool {
        OCRCandidateRanker.characterCorrectionCount(kind: kind, text: text) > 0
    }
}

struct TimecodeSequenceValidation: Sendable {
    let completeSequenceCount: Int
    let consistentSequenceCount: Int
    let validatedSampleIDs: Set<UUID>
}

enum TimecodeSequenceValidator {
    nonisolated static func validate(
        samples: [OCRSample],
        fps: Int,
        playbackFrameRate: Double,
        isDropFrame: Bool
    ) -> TimecodeSequenceValidation {
        let grouped = Dictionary(grouping: samples.compactMap { sample -> (UUID, OCRSample)? in
            guard let sequenceID = sample.timecodeSequenceID,
                  sample.timecodeSequencePosition != nil else {
                return nil
            }
            return (sequenceID, sample)
        }, by: { $0.0 })
        var completeSequenceCount = 0
        var consistentSequenceCount = 0
        var validatedSampleIDs = Set<UUID>()

        for entries in grouped.values {
            let samplesByPosition = entries.reduce(into: [Int: OCRSample]()) { result, entry in
                guard let position = entry.1.timecodeSequencePosition,
                      result[position] == nil else {
                    return
                }
                result[position] = entry.1
            }
            guard let previous = samplesByPosition[-1],
                  let current = samplesByPosition[0],
                  let next = samplesByPosition[1] else {
                continue
            }
            completeSequenceCount += 1

            let orderedSamples = [previous, current, next]
            let parsed = orderedSamples.compactMap { sample in
                OCRFieldParser.timecode(
                    from: sample.rawText,
                    fps: fps,
                    playbackFrameRate: playbackFrameRate,
                    isDropFrame: isDropFrame
                )
            }
            guard parsed.count == orderedSamples.count,
                  isContinuous(
                    samples: orderedSamples,
                    timecodes: parsed,
                    fps: fps,
                    playbackFrameRate: playbackFrameRate,
                    isDropFrame: isDropFrame
                  ) else {
                continue
            }

            consistentSequenceCount += 1
            validatedSampleIDs.formUnion(orderedSamples.map(\.id))
        }

        return TimecodeSequenceValidation(
            completeSequenceCount: completeSequenceCount,
            consistentSequenceCount: consistentSequenceCount,
            validatedSampleIDs: validatedSampleIDs
        )
    }

    nonisolated private static func isContinuous(
        samples: [OCRSample],
        timecodes: [Timecode],
        fps: Int,
        playbackFrameRate: Double,
        isDropFrame: Bool
    ) -> Bool {
        for index in 1..<samples.count {
            guard let earlierTime = actualTime(for: samples[index - 1]),
                  let laterTime = actualTime(for: samples[index]) else {
                return false
            }
            let elapsedSeconds = CMTimeSubtract(laterTime, earlierTime).seconds
            let expectedFrameDelta = Int((elapsedSeconds * playbackFrameRate).rounded())
            let actualFrameDelta = forwardFrameDelta(
                from: timecodes[index - 1].totalFrames,
                to: timecodes[index].totalFrames,
                framesPerDay: framesPerDay(fps: fps, playbackFrameRate: playbackFrameRate, isDropFrame: isDropFrame)
            )
            guard expectedFrameDelta > 0, actualFrameDelta == expectedFrameDelta else {
                return false
            }
        }
        return true
    }

    nonisolated private static func actualTime(for sample: OCRSample) -> CMTime? {
        guard let value = sample.actualTimeValue,
              let timescale = sample.actualTimeTimescale,
              timescale > 0 else {
            return nil
        }
        return CMTime(value: value, timescale: timescale)
    }

    nonisolated private static func framesPerDay(
        fps: Int,
        playbackFrameRate: Double,
        isDropFrame: Bool
    ) -> Int {
        Timecode(
            hours: 23,
            minutes: 59,
            seconds: 59,
            frames: fps - 1,
            fps: fps,
            playbackFrameRate: playbackFrameRate,
            isDropFrame: isDropFrame
        ).totalFrames + 1
    }

    nonisolated private static func forwardFrameDelta(
        from earlier: Int,
        to later: Int,
        framesPerDay: Int
    ) -> Int {
        let delta = later - earlier
        return delta >= 0 ? delta : delta + framesPerDay
    }
}

struct OCRConfidenceEvidence: Sendable {
    let fieldConsistency: Double
    let visionConfidence: Double
    let formatValidity: Double
    let candidateSeparation: Double
    let preprocessingAgreement: Double
    let temporalConsistency: Double
    let isLegal: Bool
    let usesCharacterCorrection: Bool
    let isTimecodeFrameRateUnique: Bool
}

struct OCRConfidenceAssessment: Sendable {
    let confidence: Double
    let requiresReview: Bool
}

enum OCRConfidenceCalibrator {
    nonisolated static func assess(_ evidence: OCRConfidenceEvidence) -> OCRConfidenceAssessment {
        let candidateSeparationScore = min(1, max(0, evidence.candidateSeparation / 0.20))
        let weightedScore = clamp(evidence.fieldConsistency) * 0.40
            + clamp(evidence.visionConfidence) * 0.15
            + clamp(evidence.formatValidity) * 0.15
            + candidateSeparationScore * 0.05
            + clamp(evidence.preprocessingAgreement) * 0.15
            + clamp(evidence.temporalConsistency) * 0.10
        var confidence = clamp(weightedScore)
        var requiresReview = false

        if !evidence.isLegal {
            confidence = min(confidence, 0.44)
            requiresReview = true
        }
        if evidence.usesCharacterCorrection || !evidence.isTimecodeFrameRateUnique {
            confidence = min(confidence, 0.79)
            requiresReview = true
        }

        return OCRConfidenceAssessment(
            confidence: confidence,
            requiresReview: requiresReview
        )
    }

    nonisolated private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 0))
    }
}

private enum OCRConsensusResolver {
    nonisolated static func resolve(
        videoName: String,
        videoFrameRate: Double,
        sourceTimecodeFrameRateSetting: SourceTimecodeFrameRateSetting,
        duration: Double,
        samples: [OCRSample],
        expectedKinds: Set<OCRFieldKind>
    ) -> ClipOCRResult {
        let expectsClipName = expectedKinds.contains(.clipName)
        let expectsRoll = expectedKinds.contains(.roll)
        let expectsTimecode = expectedKinds.contains(.timecode)

        let clipNameCandidates = samples
            .filter { $0.region.kind == .clipName }
            .compactMap { OCRFieldParser.clipName(from: $0.rawText) }

        let clipName = expectsClipName ? mostCommon(clipNameCandidates) : nil
        let rollFromClip = expectsRoll ? clipName.flatMap(OCRFieldParser.rollFromClipName) : nil
        let rollSamples = samples.filter { $0.region.kind == .roll }
        let explicitRollCandidates = rollSamples.compactMap { OCRFieldParser.roll(from: $0.rawText) }
        let invalidRollSampleCount = expectsRoll ? rollSamples
            .filter { !$0.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { OCRFieldParser.roll(from: $0.rawText) == nil }
            .count : 0
        let explicitRoll = expectsRoll ? mostCommon(explicitRollCandidates) : nil
        let roll = expectsRoll ? (rollFromClip ?? explicitRoll) : nil

        let timecodeSamples = samples.filter { $0.region.kind == .timecode }
        let timecodeAnalysis = expectsTimecode
            ? analyzeTimecodes(
                samples: timecodeSamples,
                allSamples: samples,
                videoFrameRate: videoFrameRate,
                setting: sourceTimecodeFrameRateSetting
            )
            : nil
        let invalidTimecodeSampleCount = timecodeAnalysis?.invalidSampleCount ?? 0
        let sourceFps = timecodeAnalysis?.sourceFrameRate
            ?? sourceTimecodeFrameRateSetting.fps
            ?? max(1, Int(round(videoFrameRate)))
        let startTimecode = timecodeAnalysis.flatMap { analysis in
            analysis.bestStartFrame.map {
                Timecode.from(
                    totalFrames: $0,
                    fps: analysis.sourceFrameRate,
                    playbackFrameRate: analysis.playbackFrameRate,
                    isDropFrame: analysis.isDropFrame
                )
            }
        }

        var notes: [String] = []
        if expectsClipName && clipName == nil {
            notes.append("未稳定识别文件名")
        }
        if expectsRoll && roll == nil {
            notes.append("未稳定识别卷号")
        }
        if expectsRoll && invalidRollSampleCount > 0 {
            notes.append("卷号格式不合法：需类似 A001 或 A_0001_12SQ")
        }
        if expectsTimecode && startTimecode == nil {
            notes.append("未稳定识别起始时间码")
        }
        if expectsTimecode && invalidTimecodeSampleCount > 0 {
            notes.append("时间码格式不合法：需为 HH:MM:SS:FF 且帧号小于源 TC 帧率")
        }
        if let diagnosticNotes = timecodeAnalysis?.diagnostics.notes {
            notes.append(contentsOf: diagnosticNotes)
        }

        let clipScore = score(hasValue: clipName != nil, candidateCount: clipNameCandidates.count)
        let rollScore = score(hasValue: roll != nil, candidateCount: roll == rollFromClip ? clipNameCandidates.count : explicitRollCandidates.count)
        let timecodeScore = timecodeAnalysis.map {
            Double($0.clusteredSampleCount) / Double(max(1, $0.validSampleCount))
        } ?? 0
        let enabledFieldScores = [
            expectsClipName ? clipScore : nil,
            expectsRoll ? rollScore : nil,
            expectsTimecode ? timecodeScore : nil
        ].compactMap(\.self)
        let fieldScore = enabledFieldScores.isEmpty
            ? 0
            : enabledFieldScores.reduce(0, +) / Double(enabledFieldScores.count)
        let ocrScore = average(samples.map(\.confidence))
        let formatScore = average(samples.map(\.formatScore))
        let candidateMargin = average(samples.map(\.candidateMargin))
        let preprocessingAgreement = average(samples.map(\.preprocessingAgreement))
        let usesCharacterCorrection = samples.contains { $0.characterCorrectionCount > 0 }
        let hasHighRiskTimecode = timecodeAnalysis?.diagnostics.status == .highRisk
            || timecodeAnalysis?.diagnostics.status == .driftSuspected
        let hasAllExpectedValues = (!expectsClipName || clipName != nil)
            && (!expectsRoll || roll != nil)
            && (!expectsTimecode || startTimecode != nil)
        let isLegal = hasAllExpectedValues
            && invalidRollSampleCount == 0
            && invalidTimecodeSampleCount == 0
            && !hasHighRiskTimecode
        let isTimecodeFrameRateUnique = !expectsTimecode
            || (timecodeAnalysis?.diagnostics.isFrameRateCandidateUnique == true)
        let assessment = OCRConfidenceCalibrator.assess(
            OCRConfidenceEvidence(
                fieldConsistency: fieldScore,
                visionConfidence: ocrScore,
                formatValidity: formatScore,
                candidateSeparation: candidateMargin,
                preprocessingAgreement: preprocessingAgreement,
                temporalConsistency: expectsTimecode ? timecodeScore : 1,
                isLegal: isLegal,
                usesCharacterCorrection: usesCharacterCorrection,
                isTimecodeFrameRateUnique: isTimecodeFrameRateUnique
            )
        )
        if usesCharacterCorrection {
            notes.append("识别结果包含位置约束字符纠错，已降级为需复核")
        }
        if !isTimecodeFrameRateUnique {
            notes.append("源 TC 帧率候选无法唯一确定，已降级为需复核")
        }

        return ClipOCRResult(
            videoName: videoName,
            fps: sourceFps,
            videoFrameRate: videoFrameRate,
            sourceTimecodeFrameRateSetting: sourceTimecodeFrameRateSetting,
            duration: duration,
            clipName: clipName,
            roll: roll,
            startTimecode: startTimecode,
            confidence: assessment.confidence,
            samples: timecodeAnalysis?.annotatedSamples ?? samples,
            timecodeDiagnostics: timecodeAnalysis?.diagnostics,
            notes: notes
        )
    }

    private struct TimecodeReading {
        let sample: OCRSample
        let timecode: Timecode
        let startFrame: Int
    }

    private struct TimecodeAnalysis {
        let sourceFrameRate: Int
        let playbackFrameRate: Double
        let isDropFrame: Bool
        let validSampleCount: Int
        let invalidSampleCount: Int
        let clusteredSampleCount: Int
        let bestStartFrame: Int?
        let annotatedSamples: [OCRSample]
        let diagnostics: TimecodeDiagnostics
    }

    nonisolated private static func analyzeTimecodes(
        samples: [OCRSample],
        allSamples: [OCRSample],
        videoFrameRate: Double,
        setting: SourceTimecodeFrameRateSetting
    ) -> TimecodeAnalysis {
        let candidates = setting.candidateFrameRates.map { fps in
            analyzeCandidate(
                fps: fps,
                samples: samples,
                allSamples: allSamples,
                videoFrameRate: videoFrameRate,
                setting: setting
            )
        }

        guard let best = candidates.max(by: isWorseCandidate) else {
            let diagnostics = TimecodeDiagnostics(
                setting: setting,
                videoFrameRate: videoFrameRate,
                sourceTimecodeFrameRate: setting.fps,
                validSampleCount: 0,
                invalidSampleCount: samples.count,
                maxDeviationFrames: nil,
                driftFramesPerMinute: nil,
                isFrameRateCandidateUnique: false,
                status: .highRisk,
                notes: ["时间码样本不足，无法检测源 TC 帧率"]
            )
            return TimecodeAnalysis(
                sourceFrameRate: setting.fps ?? max(1, Int(round(videoFrameRate))),
                playbackFrameRate: setting == .automatic ? max(1.0, videoFrameRate.rounded()) : setting.playbackFrameRate,
                isDropFrame: setting != .automatic && setting.isDropFrame,
                validSampleCount: 0,
                invalidSampleCount: samples.count,
                clusteredSampleCount: 0,
                bestStartFrame: nil,
                annotatedSamples: annotateInvalidTimecodeSamples(allSamples),
                diagnostics: diagnostics
            )
        }

        let matchingCandidates = candidates.filter { hasEquivalentEvidence($0, best) }
        let isUnique = matchingCandidates.count == 1
        let notes = isUnique
            ? best.diagnostics.notes
            : best.diagnostics.notes + ["多个源 TC 帧率候选同样成立，需人工确认帧率"]
        let diagnostics = TimecodeDiagnostics(
            setting: best.diagnostics.setting,
            videoFrameRate: best.diagnostics.videoFrameRate,
            sourceTimecodeFrameRate: best.diagnostics.sourceTimecodeFrameRate,
            validSampleCount: best.diagnostics.validSampleCount,
            invalidSampleCount: best.diagnostics.invalidSampleCount,
            maxDeviationFrames: best.diagnostics.maxDeviationFrames,
            driftFramesPerMinute: best.diagnostics.driftFramesPerMinute,
            isFrameRateCandidateUnique: isUnique,
            status: best.diagnostics.status,
            notes: notes
        )
        return TimecodeAnalysis(
            sourceFrameRate: best.sourceFrameRate,
            playbackFrameRate: best.playbackFrameRate,
            isDropFrame: best.isDropFrame,
            validSampleCount: best.validSampleCount,
            invalidSampleCount: best.invalidSampleCount,
            clusteredSampleCount: best.clusteredSampleCount,
            bestStartFrame: best.bestStartFrame,
            annotatedSamples: best.annotatedSamples,
            diagnostics: diagnostics
        )
    }

    nonisolated private static func analyzeCandidate(
        fps: Int,
        samples: [OCRSample],
        allSamples: [OCRSample],
        videoFrameRate: Double,
        setting: SourceTimecodeFrameRateSetting
    ) -> TimecodeAnalysis {
        let playbackFrameRate = setting == .automatic ? Double(fps) : setting.playbackFrameRate
        let isDropFrame = setting != .automatic && setting.isDropFrame
        let nonEmptyTimecodeSampleCount = samples
            .filter { !$0.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
        let parsedReadings: [TimecodeReading] = samples.compactMap { sample in
            guard let timecode = OCRFieldParser.timecode(
                from: sample.rawText,
                fps: fps,
                playbackFrameRate: playbackFrameRate,
                isDropFrame: isDropFrame
            ) else {
                return nil
            }
            let startFrame = timecode.totalFrames - mediaFrameOffset(
                for: sample,
                playbackFrameRate: playbackFrameRate
            )
            return TimecodeReading(sample: sample, timecode: timecode, startFrame: startFrame)
        }
        let sequenceValidation = TimecodeSequenceValidator.validate(
            samples: samples,
            fps: fps,
            playbackFrameRate: playbackFrameRate,
            isDropFrame: isDropFrame
        )
        let readings = sequenceValidation.completeSequenceCount > 0
            ? parsedReadings.filter { sequenceValidation.validatedSampleIDs.contains($0.sample.id) }
            : parsedReadings
        let invalidCount = max(0, nonEmptyTimecodeSampleCount - readings.count)
        let bestFrameCluster = bestFrameCluster(readings.map(\.startFrame))
        let bestStartFrame = bestFrameCluster?.frame
        let deviations = bestStartFrame.map { bestFrame in
            readings.map { $0.startFrame - bestFrame }
        } ?? []
        let maxDeviation = deviations.map { abs($0) }.max()
        let drift = driftFramesPerMinute(from: readings)
        let status = consistencyStatus(
            videoFrameRate: videoFrameRate,
            playbackFrameRate: playbackFrameRate,
            validSampleCount: readings.count,
            invalidSampleCount: invalidCount,
            clusteredSampleCount: bestFrameCluster?.count ?? 0,
            maxDeviationFrames: maxDeviation,
            driftFramesPerMinute: drift
        )
        let notes = diagnosticNotes(
            setting: setting,
            fps: fps,
            samples: samples,
            validSampleCount: readings.count,
            invalidSampleCount: invalidCount,
            maxDeviationFrames: maxDeviation,
            driftFramesPerMinute: drift,
            status: status,
            sequenceValidation: sequenceValidation
        )

        let diagnostics = TimecodeDiagnostics(
            setting: setting,
            videoFrameRate: videoFrameRate,
            sourceTimecodeFrameRate: readings.isEmpty ? nil : fps,
            validSampleCount: readings.count,
            invalidSampleCount: invalidCount,
            maxDeviationFrames: maxDeviation,
            driftFramesPerMinute: drift,
            isFrameRateCandidateUnique: true,
            status: status,
            notes: notes
        )

        return TimecodeAnalysis(
            sourceFrameRate: fps,
            playbackFrameRate: playbackFrameRate,
            isDropFrame: isDropFrame,
            validSampleCount: readings.count,
            invalidSampleCount: invalidCount,
            clusteredSampleCount: bestFrameCluster?.count ?? 0,
            bestStartFrame: bestStartFrame,
            annotatedSamples: annotateSamples(allSamples, readings: readings, bestStartFrame: bestStartFrame),
            diagnostics: diagnostics
        )
    }

    nonisolated private static func isWorseCandidate(_ lhs: TimecodeAnalysis, _ rhs: TimecodeAnalysis) -> Bool {
        if lhs.clusteredSampleCount != rhs.clusteredSampleCount {
            return lhs.clusteredSampleCount < rhs.clusteredSampleCount
        }
        if lhs.validSampleCount != rhs.validSampleCount {
            return lhs.validSampleCount < rhs.validSampleCount
        }

        let lhsStatusRank = consistencyRank(lhs.diagnostics.status)
        let rhsStatusRank = consistencyRank(rhs.diagnostics.status)
        if lhsStatusRank != rhsStatusRank {
            return lhsStatusRank < rhsStatusRank
        }

        let lhsDeviation = lhs.diagnostics.maxDeviationFrames ?? Int.max
        let rhsDeviation = rhs.diagnostics.maxDeviationFrames ?? Int.max
        if lhsDeviation != rhsDeviation {
            return lhsDeviation > rhsDeviation
        }

        let lhsDrift = lhs.diagnostics.driftFramesPerMinute ?? .greatestFiniteMagnitude
        let rhsDrift = rhs.diagnostics.driftFramesPerMinute ?? .greatestFiniteMagnitude
        if abs(lhsDrift - rhsDrift) > 0.001 {
            return lhsDrift > rhsDrift
        }

        // Prefer 24 in exact ties; it is the most common camera TC base for this workflow.
        return lhs.sourceFrameRate > rhs.sourceFrameRate
    }

    nonisolated private static func hasEquivalentEvidence(
        _ lhs: TimecodeAnalysis,
        _ rhs: TimecodeAnalysis
    ) -> Bool {
        lhs.clusteredSampleCount == rhs.clusteredSampleCount
            && lhs.validSampleCount == rhs.validSampleCount
            && consistencyRank(lhs.diagnostics.status) == consistencyRank(rhs.diagnostics.status)
            && lhs.diagnostics.maxDeviationFrames == rhs.diagnostics.maxDeviationFrames
            && driftValuesMatch(
                lhs.diagnostics.driftFramesPerMinute,
                rhs.diagnostics.driftFramesPerMinute
            )
    }

    nonisolated private static func driftValuesMatch(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            true
        case let (.some(lhs), .some(rhs)):
            abs(lhs - rhs) < 0.001
        default:
            false
        }
    }

    nonisolated private static func consistencyRank(_ status: TimecodeConsistencyStatus) -> Int {
        switch status {
        case .consistent:
            4
        case .frameRateMismatchStable:
            3
        case .notChecked:
            2
        case .driftSuspected:
            1
        case .highRisk:
            0
        }
    }

    nonisolated private static func consistencyStatus(
        videoFrameRate: Double,
        playbackFrameRate: Double,
        validSampleCount: Int,
        invalidSampleCount: Int,
        clusteredSampleCount: Int,
        maxDeviationFrames: Int?,
        driftFramesPerMinute: Double?
    ) -> TimecodeConsistencyStatus {
        guard validSampleCount > 0, clusteredSampleCount > 0 else {
            return .highRisk
        }

        if invalidSampleCount > validSampleCount {
            return .highRisk
        }

        if (maxDeviationFrames ?? 0) > 2 || (driftFramesPerMinute ?? 0) > 1.0 {
            return .driftSuspected
        }

        let frameRatesMatch = abs(videoFrameRate - playbackFrameRate) <= 0.05
        return frameRatesMatch ? .consistent : .frameRateMismatchStable
    }

    nonisolated private static func diagnosticNotes(
        setting: SourceTimecodeFrameRateSetting,
        fps: Int,
        samples: [OCRSample],
        validSampleCount: Int,
        invalidSampleCount: Int,
        maxDeviationFrames: Int?,
        driftFramesPerMinute: Double?,
        status: TimecodeConsistencyStatus,
        sequenceValidation: TimecodeSequenceValidation
    ) -> [String] {
        var notes: [String] = []

        if validSampleCount == 1 {
            notes.append("时间码样本只有 1 个，无法判断长片漂移")
        }
        if setting != .automatic, invalidSampleCount > 0 {
            notes.append("当前源 TC 帧率可能不匹配，部分时间码帧号超出范围")
        }
        if status == .driftSuspected {
            let driftText = driftFramesPerMinute.map { String(format: "%.1f", $0) } ?? "未知"
            notes.append("多点时间码疑似漂移：最大偏差 \(maxDeviationFrames ?? 0) 帧，约 \(driftText) 帧/分钟")
        }
        if status == .frameRateMismatchStable {
            notes.append("视频帧率与源 TC 帧率不一致，长片回套需复核")
        }
        if status == .highRisk, validSampleCount == 0, !samples.isEmpty {
            notes.append("未能用 \(fps)fps 解析稳定时间码")
        }
        if sequenceValidation.completeSequenceCount > sequenceValidation.consistentSequenceCount {
            notes.append("相邻帧时间码不连续，相关候选已排除")
        }
        if sequenceValidation.completeSequenceCount == 0, !samples.isEmpty {
            notes.append("相邻帧样本不足，时间码序列未经三帧验证")
        }

        return notes
    }

    nonisolated private static func driftFramesPerMinute(from readings: [TimecodeReading]) -> Double? {
        let sortedReadings = readings.sorted { $0.sample.actualSeconds < $1.sample.actualSeconds }
        guard let first = sortedReadings.first,
              let last = sortedReadings.last,
              last.sample.actualSeconds > first.sample.actualSeconds else {
            return nil
        }

        let minutes = (last.sample.actualSeconds - first.sample.actualSeconds) / 60.0
        guard minutes > 0 else {
            return nil
        }

        return abs(Double(last.startFrame - first.startFrame)) / minutes
    }

    nonisolated private static func mediaFrameOffset(
        for sample: OCRSample,
        playbackFrameRate: Double
    ) -> Int {
        guard let value = sample.actualTimeValue,
              let timescale = sample.actualTimeTimescale,
              timescale > 0 else {
            return Int((sample.actualSeconds * playbackFrameRate).rounded())
        }
        return Int((Double(value) * playbackFrameRate / Double(timescale)).rounded())
    }

    nonisolated private static func annotateSamples(
        _ samples: [OCRSample],
        readings: [TimecodeReading],
        bestStartFrame: Int?
    ) -> [OCRSample] {
        let readingBySampleID = Dictionary(uniqueKeysWithValues: readings.map { ($0.sample.id, $0) })

        return samples.map { sample in
            guard sample.region.kind == .timecode else {
                return sample
            }

            guard let reading = readingBySampleID[sample.id], let bestStartFrame else {
                return annotatedSample(sample, offset: nil, status: .invalid)
            }

            let offset = reading.startFrame - bestStartFrame
            let status: TimecodeSampleStatus
            if abs(offset) <= 1 {
                status = .clustered
            } else if abs(offset) <= 2 {
                status = .deviated
            } else {
                status = .jump
            }

            return annotatedSample(sample, offset: offset, status: status)
        }
    }

    nonisolated private static func annotateInvalidTimecodeSamples(_ samples: [OCRSample]) -> [OCRSample] {
        samples.map { sample in
            sample.region.kind == .timecode
                ? annotatedSample(sample, offset: nil, status: .invalid)
                : sample
        }
    }

    nonisolated private static func annotatedSample(
        _ sample: OCRSample,
        offset: Int?,
        status: TimecodeSampleStatus
    ) -> OCRSample {
        OCRSample(
            id: sample.id,
            region: sample.region,
            requestedSeconds: sample.requestedSeconds,
            actualSeconds: sample.actualSeconds,
            rawText: sample.rawText,
            confidence: sample.confidence,
            formatScore: sample.formatScore,
            candidateMargin: sample.candidateMargin,
            preprocessingAgreement: sample.preprocessingAgreement,
            characterCorrectionCount: sample.characterCorrectionCount,
            actualTimeValue: sample.actualTimeValue,
            actualTimeTimescale: sample.actualTimeTimescale,
            timecodeSequenceID: sample.timecodeSequenceID,
            timecodeSequencePosition: sample.timecodeSequencePosition,
            timecodeFrameOffset: offset,
            timecodeSampleStatus: status
        )
    }

    nonisolated private static func mostCommon(_ values: [String]) -> String? {
        let grouped = Dictionary(grouping: values, by: { $0 })
        return grouped
            .max {
                if $0.value.count == $1.value.count {
                    return $0.key.count < $1.key.count
                }
                return $0.value.count < $1.value.count
            }?
            .key
    }

    nonisolated private static func bestFrameCluster(_ frames: [Int]) -> (frame: Int, count: Int)? {
        guard !frames.isEmpty else {
            return nil
        }

        return frames
            .map { candidate in
                let neighbors = frames.filter { abs($0 - candidate) <= 1 }
                let average = Int(round(Double(neighbors.reduce(0, +)) / Double(neighbors.count)))
                return (frame: average, count: neighbors.count)
            }
            .max { $0.count < $1.count }
    }

    nonisolated private static func score(hasValue: Bool, candidateCount: Int) -> Double {
        guard hasValue else {
            return 0
        }
        return min(1, 0.55 + Double(candidateCount) * 0.15)
    }

    nonisolated private static func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}

enum OCRFieldParser {
    nonisolated static func clipName(from rawText: String) -> String? {
        let upper = rawText
            .uppercased()
            .replacingOccurrences(of: "\n", with: " ")

        if let compactCameraClip = firstMatch(
            in: upper,
            pattern: #"\b[A-Z0-9]{8}\b"#
        ).flatMap(normalizedCompactCameraClip) {
            return compactCameraClip
        }

        if let separated = firstMatch(
            in: upper,
            pattern: #"[A-Z]\d{3}[_-][A-Z0-9]+(?:[_-][A-Z0-9]+)+"#
        ) {
            return separated.replacingOccurrences(of: "-", with: "_")
        }

        if let spaced = firstMatch(
            in: upper,
            pattern: #"\b[A-Z]\d{3}\s+[A-Z]\d{3}\s+[A-Z0-9]{4,}\b"#
        ) {
            return normalizeClipTokens(spaced.split(whereSeparator: \.isWhitespace).map(String.init))
        }

        let compact = upper.filter { $0.isLetter || $0.isNumber }
        if let compactMatch = firstMatch(
            in: String(compact),
            pattern: #"[A-Z]\d{3}[A-Z]\d{3}[A-Z0-9]{4,}"#
        ), compactMatch.count > 8 {
            let first = compactMatch.prefix(4)
            let middleStart = compactMatch.index(compactMatch.startIndex, offsetBy: 4)
            let middleEnd = compactMatch.index(compactMatch.startIndex, offsetBy: 8)
            let middle = compactMatch[middleStart..<middleEnd]
            let tail = compactMatch[middleEnd...]
            return "\(first)_\(middle)_\(tail)"
        }

        let looseTokens = upper
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        for index in looseTokens.indices.dropLast(2) {
            let window = Array(looseTokens[index...(index + 2)])
            if let normalized = normalizeClipTokens(window) {
                return normalized
            }
        }

        return nil
    }

    nonisolated static func rollFromClipName(_ clipName: String) -> String? {
        if let arriRoll = normalizedARRIRollToken(clipName) {
            return arriRoll
        }

        guard let firstComponent = clipName.split(separator: "_").first else {
            return nil
        }

        let token = String(firstComponent)
        return normalizedRollToken(token)
    }

    nonisolated static func roll(from rawText: String) -> String? {
        let upper = rawText.uppercased()
        if let arriRoll = firstMatch(
            in: upper,
            pattern: #"\b[A-Z]_\d{4}(?:_[A-Z0-9]{2,})?\b"#
        ).flatMap(normalizedARRIRollToken) {
            return arriRoll
        }

        let tokens = upper
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        for index in tokens.indices where tokens[index] == "ROLL" || tokens[index] == "REEL" {
            guard let nextIndex = tokens.index(index, offsetBy: 1, limitedBy: tokens.endIndex),
                  nextIndex < tokens.endIndex else {
                return nil
            }
            if let arriRoll = normalizedARRIRollTokens(Array(tokens[nextIndex...].prefix(3))) {
                return arriRoll
            }
            return normalizedRollToken(tokens[nextIndex])
        }

        let compact = upper.filter { $0.isLetter || $0.isNumber }
        for label in ["ROLL", "REEL"] {
            if let labelRange = compact.range(of: label) {
                let tokenStart = labelRange.upperBound
                guard let tokenEnd = compact.index(tokenStart, offsetBy: 4, limitedBy: compact.endIndex) else {
                    return nil
                }
                return normalizedRollToken(String(compact[tokenStart..<tokenEnd]))
            }
        }

        for token in tokens {
            if let normalized = normalizedRollToken(token) {
                return normalized
            }
        }

        for index in tokens.indices.dropLast() {
            if let arriRoll = normalizedARRIRollTokens(Array(tokens[index...].prefix(3))) {
                return arriRoll
            }
        }

        return nil
    }

    nonisolated static func timecode(
        from rawText: String,
        fps: Int,
        playbackFrameRate: Double? = nil,
        isDropFrame: Bool = false
    ) -> Timecode? {
        let normalized = rawText
            .uppercased()
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "L", with: "1")
            .replacingOccurrences(of: "S", with: "5")

        guard let match = firstMatch(
            in: normalized,
            pattern: #"\b([0-2]\d):([0-5]\d):([0-5]\d)[:;]([0-9]{2})\b"#
        ) else {
            return nil
        }

        return Timecode.parse(
            match,
            fps: fps,
            playbackFrameRate: playbackFrameRate,
            isDropFrame: isDropFrame
        )
    }

    nonisolated private static func normalizedRollToken(_ token: String) -> String? {
        let upper = token.uppercased()
        guard upper.count == 4,
              let first = upper.first,
              first.isLetter,
              first != "O",
              first != "I",
              first != "L",
              first != "R" else {
            return nil
        }

        let digits = upper.dropFirst().map { character -> Character in
            switch character {
            case "O":
                "0"
            case "I", "L":
                "1"
            case "S":
                "5"
            case "B":
                "8"
            default:
                character
            }
        }

        guard digits.allSatisfy(\.isNumber) else {
            return nil
        }

        return "\(first)\(String(digits))"
    }

    nonisolated private static func normalizedCompactCameraClip(_ token: String) -> String? {
        let characters = Array(token.uppercased())
        guard characters.count == 8,
              let firstLetter = normalizedLetter(characters[0]),
              let secondLetter = normalizedLetter(characters[4]) else {
            return nil
        }

        let digitIndexes = [1, 2, 3, 5, 6, 7]
        var normalized = characters
        normalized[0] = firstLetter
        normalized[4] = secondLetter

        for index in digitIndexes {
            guard let digit = normalizedDigit(characters[index]) else {
                return nil
            }
            normalized[index] = digit
        }

        return String(normalized)
    }

    nonisolated private static func normalizedLetter(_ character: Character) -> Character? {
        if character.isLetter {
            return character
        }

        switch character {
        case "0":
            return "O"
        case "1":
            return "I"
        case "2":
            return "Z"
        case "5":
            return "S"
        case "6":
            return "G"
        case "8":
            return "B"
        default:
            return nil
        }
    }

    nonisolated private static func normalizedDigit(_ character: Character) -> Character? {
        if character.isNumber {
            return character
        }

        switch character {
        case "O":
            return "0"
        case "I", "L", "T":
            return "1"
        case "Z":
            return "2"
        case "S":
            return "5"
        case "G":
            return "6"
        case "B":
            return "8"
        default:
            return nil
        }
    }

    nonisolated private static func normalizedARRIRollToken(_ token: String) -> String? {
        let components = token
            .uppercased()
            .components(separatedBy: "_")
            .filter { !$0.isEmpty }
        return normalizedARRIRollTokens(components)
    }

    nonisolated private static func normalizedARRIRollTokens(_ tokens: [String]) -> String? {
        guard tokens.count >= 2,
              tokens[0].count == 1,
              let camera = tokens[0].first,
              camera.isLetter else {
            return nil
        }

        let rollNumber = tokens[1].map { character -> Character in
            switch character {
            case "O":
                "0"
            case "I", "L":
                "1"
            case "S":
                "5"
            case "B":
                "8"
            default:
                character
            }
        }
        guard rollNumber.count == 4, rollNumber.allSatisfy(\.isNumber) else {
            return nil
        }

        guard let suffix = tokens.dropFirst(2).first else {
            return "\(camera)_\(String(rollNumber))"
        }

        let normalizedSuffix = suffix.uppercased().filter { $0.isLetter || $0.isNumber }
        guard normalizedSuffix.count >= 2 else {
            return "\(camera)_\(String(rollNumber))"
        }

        return "\(camera)_\(String(rollNumber))_\(normalizedSuffix)"
    }

    nonisolated private static func normalizeClipTokens(_ tokens: [String]) -> String? {
        guard tokens.count >= 3,
              let first = normalizedRollToken(tokens[0]),
              let second = normalizedRollToken(tokens[1]) else {
            return nil
        }

        let tail = tokens.dropFirst(2)
            .joined(separator: "_")
            .map { character -> Character in
                switch character {
                case "O":
                    "0"
                default:
                    character
                }
            }

        guard tail.count >= 4 else {
            return nil
        }

        return "\(first)_\(second)_\(String(tail))"
    }

    nonisolated private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }

        return String(text[matchRange])
    }
}
